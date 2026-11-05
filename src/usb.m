// USB streaming for the POD HD500 family via IOUSBHost. See pod.h for the wire format.
#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/lock.h>
#include <os/log.h>
#include <stdatomic.h>
#include "pod.h"

// NSLog output from the Core Audio driver sandbox doesn't show up; os_log does.
// Read with: log stream --predicate 'eventMessage BEGINSWITH "KidneyHD Audio"'
#define LOG(...) os_log(OS_LOG_DEFAULT, "KidneyHD Audio: %{public}s", [[NSString stringWithFormat:__VA_ARGS__] UTF8String])

// Requests in flight per direction; output latency is about NT ms. If the
// completion queue stalls longer than this, the controller skips a 1 ms slot
// and you hear a click (4 is too few; Line 6's kext used 50).
#define NT 8
#define NP 8        // transactions (microframes) per request = one 1 ms frame
#define BPF POD_FRAME  // bytes per frame on the wire, the same as in the rings
#define NOMINAL 6   // frames per microframe at 48 kHz

static const struct { uint16_t pid; const char *name; } models[] = {
  { 0x4156, "POD HD Desktop" }, { 0x414D, "POD HD500" }, { 0x4159, "POD HD500X" },
  { 0x4157, "POD HD Pro" }, { 0x415A, "POD HD Pro X" },
};
static NSArray *model_pids(void) {
  NSMutableArray *a = [NSMutableArray array];
  for (size_t i = 0; i < sizeof models / sizeof *models; i++) [a addObject:@(models[i].pid)];
  return a;
}
static _Atomic uint16_t cur_pid;
uint16_t pod_pid(void) { return cur_pid; }
const char *pod_name(void) {
  for (size_t i = 0; i < sizeof models / sizeof *models; i++) if (models[i].pid == cur_pid) return models[i].name;
  return "POD HD";
}

uint8_t pod_in_ring[POD_RING * POD_FRAME] __attribute__((aligned(16)));
uint8_t pod_out_ring[POD_RING * POD_FRAME] __attribute__((aligned(16)));

typedef struct {
  NSMutableData *data;
  IOUSBHostIsochronousTransaction tx[NP];
} req_t;

static dispatch_queue_t q;              // all USB work and completions run here
static IOUSBHostInterface *iface;
static IOUSBHostPipe *in_pipe, *out_pipe;
static req_t in_req[NT], out_req[NT];
static uint32_t in_pkt, out_pkt;      // wMaxPacketSize of each iso endpoint
static bool wanted, streaming;          // wanted: the HAL asked for IO; streaming: USB is up
static _Atomic uint64_t in_count, out_count;
static _Atomic uint32_t errors;
// Health check: logged only when something audible went wrong in the last 2 seconds.
static _Atomic uint32_t late_writes;
static uint32_t stat_ticks, errors_seen;
static int64_t drift_seen = INT64_MIN;
void pod_note_late_write(void) { late_writes++; }
static uint8_t fifo[1024]; static uint32_t fifo_w, fifo_r;  // IN frame counts feed OUT sizes

// One lock guards the clock model, which the HAL IO thread reads. Switch to a seqlock if it contends.
static os_unfair_lock clock_lock = OS_UNFAIR_LOCK_INIT;
static pod_clock_t clk;
static bool clock_valid;

static double nominal_tpf(void) {
  mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  return 1e9 / POD_RATE * tb.denom / tb.numer;
}

pod_clock_t pod_clock(void) {
  os_unfair_lock_lock(&clock_lock);
  pod_clock_t c = clk;
  os_unfair_lock_unlock(&clock_lock);
  return c;
}
uint64_t pod_in_count(void) { return in_count; }
uint64_t pod_out_count(void) { return out_count; }
uint32_t pod_errors(void) { return errors; }
bool pod_running(void) { return streaming; }

// Delay-locked loop: smooths jittery completion times into a clean sample clock.
// Bandwidth 1 Hz at 1 kHz updates. Raise DLL_BW if the clock locks too slowly after start.
#define DLL_BW 1.0
static void clock_update(double s, double t) {
  const double w = 2 * M_PI * DLL_BW / 1000.0, b = M_SQRT2 * w, c = w * w;
  os_unfair_lock_lock(&clock_lock);
  double pred = clk.anchor_host + (s - clk.anchor_sample) * clk.ticks_per_frame;
  double e = t - pred;
  clk.anchor_host = pred + b * e;
  clk.anchor_sample = s;
  clk.ticks_per_frame += c * e / (NP * NOMINAL);
  os_unfair_lock_unlock(&clock_lock);
}

static void submit_in(req_t *r);
static void submit_out(req_t *r);
static void restart_later(void);
static _Atomic bool present;

static void fill_out(req_t *r) {
  uint8_t *buf = r->data.mutableBytes;
  uint32_t off = 0;
  for (int i = 0; i < NP; i++) {
    uint32_t n = fifo_r != fifo_w ? fifo[fifo_r++ % sizeof fifo] : NOMINAL;
    if (n * BPF > out_pkt) n = out_pkt / BPF;
    uint64_t s = out_count;
    for (uint32_t f = 0; f < n; f++, s++) {
      uint8_t *src = &pod_out_ring[(s & (POD_RING - 1)) * POD_FRAME];
      memcpy(buf + off + f * BPF, src, BPF);
      memset(src, 0, BPF);
    }
    out_count = s;
    r->tx[i] = (IOUSBHostIsochronousTransaction){ .requestCount = n * BPF, .offset = off };
    off += n * BPF;
  }
}

static void on_in(req_t *r, IOReturn st) {
  if (!streaming) return;  // teardown clears it before aborting, so its own aborts end here
  if (st == kIOReturnAborted) { restart_later(); return; }
  if (st != kIOReturnSuccess && st != kIOReturnUnderrun) errors++;
  uint64_t s = in_count;
  const uint8_t *buf = r->data.bytes;
  for (int i = 0; i < NP; i++) {
    IOUSBHostIsochronousTransaction *t = &r->tx[i];
    bool ok = t->status == kIOReturnSuccess || t->status == kIOReturnUnderrun;  // short packets are normal
    uint32_t n = ok ? t->completeCount / BPF : 0;
    if (!ok) errors++;
    for (uint32_t f = 0; f < n; f++, s++) {
      memcpy(&pod_in_ring[(s & (POD_RING - 1)) * POD_FRAME], buf + t->offset + f * BPF, BPF);
    }
    if (fifo_w - fifo_r < sizeof fifo) fifo[fifo_w++ % sizeof fifo] = n;
  }
  in_count = s;
  if (++stat_ticks == 2000) {  // every 2 s
    // Output minus input stays constant while streaming; a drop of 48 frames is a 1 ms hole.
    int64_t drift = (int64_t)(out_count - in_count);
    if (errors != errors_seen || late_writes || (drift_seen != INT64_MIN && drift != drift_seen))
      LOG(@"audio glitch: %u USB errors, %u late writes from Core Audio, output drifted %lld frames",
          errors - errors_seen, (uint32_t)late_writes, drift_seen == INT64_MIN ? 0 : (long long)(drift - drift_seen));
    errors_seen = errors; drift_seen = drift; late_writes = 0; stat_ticks = 0;
  }
  uint64_t ts = r->tx[NP - 1].timeStamp;
  clock_update((double)s, (double)(ts ? ts : mach_absolute_time()));
  submit_in(r);
}

static void on_out(req_t *r, IOReturn st) {
  if (!streaming) return;
  if (st == kIOReturnAborted) { restart_later(); return; }
  if (st != kIOReturnSuccess) errors++;
  fill_out(r);
  submit_out(r);
}

static void submit_in(req_t *r) {
  for (int i = 0; i < NP; i++) r->tx[i] = (IOUSBHostIsochronousTransaction){ .requestCount = in_pkt, .offset = i * in_pkt };
  NSError *err;
  if (![in_pipe enqueueIORequestWithData:r->data transactionList:r->tx transactionListCount:NP
                        firstFrameNumber:0 options:IOUSBHostIsochronousTransferOptionsNone error:&err
                       completionHandler:^(IOReturn st, IOUSBHostIsochronousTransaction *l) { on_in(r, st); }])
    { errors++; LOG(@"in enqueue: %@", err); restart_later(); }
}

static void submit_out(req_t *r) {
  NSError *err;
  if (![out_pipe enqueueIORequestWithData:r->data transactionList:r->tx transactionListCount:NP
                         firstFrameNumber:0 options:IOUSBHostIsochronousTransferOptionsNone error:&err
                        completionHandler:^(IOReturn st, IOUSBHostIsochronousTransaction *l) { on_out(r, st); }])
    { errors++; LOG(@"out enqueue: %@", err); restart_later(); }
}

static io_service_t find_service(NSNumber *ifnum) {
  CFMutableDictionaryRef m = ifnum
    ? [IOUSBHostInterface createMatchingDictionaryWithVendorID:@POD_VID productID:nil bcdDevice:nil
                                               interfaceNumber:ifnum configurationValue:@1 interfaceClass:nil
                                             interfaceSubclass:nil interfaceProtocol:nil speed:nil productIDArray:model_pids()]
    : [IOUSBHostDevice createMatchingDictionaryWithVendorID:@POD_VID productID:nil bcdDevice:nil
                                              deviceClass:nil deviceSubclass:nil deviceProtocol:nil speed:nil productIDArray:model_pids()];
  return IOServiceGetMatchingService(kIOMainPortDefault, m);  // consumes m
}

// The pedal enumerates unconfigured on macOS; interface 0 only exists after SET_CONFIGURATION 1.
static io_service_t audio_interface(void) {
  io_service_t s = find_service(@0);
  if (s) return s;
  io_service_t d = find_service(nil);
  if (!d) return 0;
  NSError *err;
  IOUSBHostDevice *dev = [[IOUSBHostDevice alloc] initWithIOService:d options:IOUSBHostObjectInitOptionsNone
                                                              queue:q error:&err interestHandler:nil];
  IOObjectRelease(d);
  if (!dev) { LOG(@"open device: %@", err); return 0; }
  if (![dev configureWithValue:1 matchInterfaces:YES error:&err]) LOG(@"configure: %@", err);
  [dev destroy];  // release the device so editors can open it
  for (int i = 0; i < 100 && !(s = find_service(@0)); i++) usleep(10000);
  return s;
}

static void ctl_close(void);
static void teardown(void) {
  if (streaming) LOG(@"streaming stopped");
  streaming = false;
  ctl_close();
  if (iface) {
    [in_pipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
    [out_pipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
    [iface selectAlternateSetting:0 error:nil];
    [iface destroy];
  }
  iface = nil; in_pipe = out_pipe = nil;
}

// Control channel (interface 1, bulk 0x01 out / 0x81 in). The pedal plays USB
// audio only while the host keeps reads pending on 0x81: with none it mutes within
// seconds (Linux keeps one read queued, Line 6's kext 16). Like the kext we also send
// the monitor level (SetOnboardMonitorGain, 1.0), which sets the USB playback level.
// This path only runs without the control daemon; when the daemon is installed it
// owns interface 1, does the same, and shares the channel with editors.
#define CTL_READS 16  // same as the kext
static IOUSBHostInterface *ctl;
static IOUSBHostPipe *ctl_in, *ctl_out;
static int ctl_failures;  // recoveries since the last good read
static void ctl_recover(void);

static void ctl_read(NSMutableData *buf) {
  if (!buf) return;
  IOUSBHostInterface *c = ctl;
  if (![ctl_in enqueueIORequestWithData:buf completionTimeout:0 error:nil
                      completionHandler:^(IOReturn st, NSUInteger n) {
    if (ctl != c) return;  // closed or reopened meanwhile
    if (st == kIOReturnSuccess) ctl_failures = 0;
    if (st == kIOReturnSuccess || st == kIOReturnTimeout || st == kIOReturnUnderrun) ctl_read(buf);  // replies are ignored
    else if (st != kIOReturnAborted) ctl_recover();
  }]) ctl_recover();
}

// The same recovery as the control service's. Any bulk error but a timeout halts the endpoint, and
// with no reads pending the pedal mutes playback. Clearing the stall also aborts the reads still
// queued, so a fresh set follows. Each try waits 100 ms longer. After 5 tries without a good read,
// streaming restarts, which reopens the control channel.
static void ctl_recover(void) {
  static bool scheduled;
  if (scheduled || !ctl) return;
  scheduled = true;
  IOUSBHostInterface *c = ctl;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ++ctl_failures * (int64_t)NSEC_PER_SEC / 10), q, ^{
    scheduled = false;
    if (ctl != c) return;
    NSError *err;
    if (ctl_failures > 5 || ![ctl_in clearStallWithError:&err]) {
      LOG(@"control reads keep failing, restarting streaming: %@", err);
      restart_later();
      return;
    }
    for (int i = 0; i < CTL_READS; i++) ctl_read([ctl ioDataWithCapacity:64 error:nil]);
  });
}

static void ctl_close(void) {
  IOUSBHostInterface *c = ctl;
  ctl = nil;  // stops resubmission
  [ctl_in abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
  [ctl_out abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
  [c destroy];
  ctl_in = ctl_out = nil;
}

static void ctl_open(void) {
  // Right after SET_CONFIGURATION, interface 1 registers a little after interface 0.
  io_service_t s = 0;
  for (int i = 0; i < 100 && !(s = find_service(@1)); i++) usleep(10000);
  if (!s) { LOG(@"control interface not found; playback will stay muted"); return; }
  NSError *err;
  ctl = [[IOUSBHostInterface alloc] initWithIOService:s options:IOUSBHostObjectInitOptionsNone queue:q error:&err interestHandler:nil];
  IOObjectRelease(s);
  if (!ctl || !(ctl_in = [ctl copyPipeWithAddress:0x81 error:&err]) || !(ctl_out = [ctl copyPipeWithAddress:0x01 error:&err])) {
    LOG(@"control interface in use, normally by kidneyhd-audiod: %@", err);
    ctl_close();
    return;
  }
  ctl_failures = 0;
  for (int i = 0; i < CTL_READS; i++) ctl_read([ctl ioDataWithCapacity:64 error:nil]);

  float gain = 1.0f;  // monitor level, 0.0 to 1.0, little-endian float
  uint8_t bytes[16] = { 0x0c, 0, 0x01, 0, 0x02, 0, 0x04, 0x41, 0x04, 0, 0x13, 0 };
  memcpy(bytes + 12, &gain, 4);
  NSMutableData *msg = [ctl ioDataWithCapacity:16 error:nil];  // ioData buffers have a fixed length
  if (!msg) return;
  memcpy(msg.mutableBytes, bytes, 16);
  [ctl_out enqueueIORequestWithData:msg completionTimeout:1.0 error:&err completionHandler:^(IOReturn st, NSUInteger n) {
    if (st != kIOReturnSuccess) LOG(@"monitor level message failed: 0x%x", st);
  }];
}

static uint32_t stream_gen;  // counts starts, so a scheduled restart can tell its stream is gone

// Runs on q.
static bool start_locked(void) {
  if (streaming) return true;
  stream_gen++;
  io_service_t s = audio_interface();
  if (!s) return false;
  NSError *err;
  iface = [[IOUSBHostInterface alloc] initWithIOService:s options:IOUSBHostObjectInitOptionsNone queue:q error:&err
                                        interestHandler:^(IOUSBHostObject *o, uint32_t type, void *arg) {
    if (type == kIOMessageServiceIsTerminated) teardown();
  }];
  IOObjectRelease(s);
  if (!iface) { LOG(@"open interface 0: %@", err); return false; }
  if (![iface selectAlternateSetting:1 error:&err] ||
      !(in_pipe = [iface copyPipeWithAddress:0x86 error:&err]) ||
      !(out_pipe = [iface copyPipeWithAddress:0x02 error:&err])) {
    LOG(@"set up streaming: %@", err);
    teardown();
    return false;
  }
  in_pkt = in_pipe.originalDescriptors->descriptor.wMaxPacketSize & 0x7ff;
  out_pkt = out_pipe.originalDescriptors->descriptor.wMaxPacketSize & 0x7ff;

  // Keep sample time continuous across restarts (replug, USB reset) so the HAL sees no jump.
  double start_host = mach_absolute_time();
  os_unfair_lock_lock(&clock_lock);
  if (!clock_valid) clk = (pod_clock_t){ start_host, 0, nominal_tpf() };
  double s0 = clk.anchor_sample + (start_host - clk.anchor_host) / clk.ticks_per_frame;
  if (s0 < clk.anchor_sample) s0 = clk.anchor_sample;
  clk.anchor_host = start_host; clk.anchor_sample = floor(s0);
  clock_valid = true;
  os_unfair_lock_unlock(&clock_lock);
  in_count = out_count = (uint64_t)floor(s0);
  fifo_r = fifo_w = 0; drift_seen = INT64_MIN; errors_seen = errors;

  streaming = true;
  for (int i = 0; i < NT; i++) {
    in_req[i].data = [iface ioDataWithCapacity:NP * in_pkt error:nil];  // buffers belong to this interface handle
    out_req[i].data = [iface ioDataWithCapacity:NP * out_pkt error:nil];
    if (!in_req[i].data || !out_req[i].data) {  // the pedal went away during setup
      LOG(@"cannot allocate USB buffers");
      teardown();
      return false;
    }
    submit_in(&in_req[i]);
    fill_out(&out_req[i]);
    submit_out(&out_req[i]);
  }
  ctl_open();
  LOG(@"streaming started at sample %llu", in_count);
  return true;
}

// USB stopped streaming under us: a transfer was aborted that we didn't abort (a bus reset, for
// example), a pipe refused a request, or the control reads keep failing. Restart, once per stream,
// waiting longer after each restart that didn't last.
static void restart_later(void) {
  static uint32_t scheduled_gen, restarts;
  static uint64_t last_restart;
  if (!streaming || scheduled_gen == stream_gen) return;
  uint32_t gen = scheduled_gen = stream_gen;
  uint64_t now = mach_absolute_time();
  if (last_restart && (now - last_restart) / nominal_tpf() > 10 * POD_RATE) restarts = 0;  // the last one lasted 10 s
  last_restart = now;
  uint32_t wait_ms = 200 * (restarts < 10 ? ++restarts : restarts);
  LOG(@"USB stopped streaming, restarting in %u ms", wait_ms);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, wait_ms * NSEC_PER_MSEC), q, ^{
    if (gen != stream_gen || !streaming) return;  // stopped or restarted meanwhile
    teardown();
    if (wanted && present) start_locked();
  });
}

static void ensure_queue(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    q = dispatch_queue_create("KidneyHD Audio.usb", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, -1));
  });
}

// Stopping and restarting the pedal is audible, and apps stop IO on every pause.
// So after the last client stops, keep streaming silence for a while first.
#define LINGER_SEC 3
static uint32_t stop_gen;

bool pod_start(void) {
  ensure_queue();
  __block bool ok;
  dispatch_sync(q, ^{
    wanted = true; stop_gen++;
    if (!streaming) {  // fresh start: don't replay audio left from the last session
      memset(pod_in_ring, 0, sizeof pod_in_ring);
      memset(pod_out_ring, 0, sizeof pod_out_ring);
    }
    ok = start_locked();
  });
  return ok;
}

void pod_stop(void) {
  ensure_queue();
  dispatch_sync(q, ^{
    wanted = false;
    uint32_t gen = ++stop_gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, LINGER_SEC * NSEC_PER_SEC), q, ^{
      if (!wanted && gen == stop_gen) { teardown(); clock_valid = false; }
    });
  });
}

// Hot-plug. Streaming restarts by itself when the pedal comes back while IO is wanted.
static void (*watch_cb)(bool);
bool pod_present(void) { return present; }

static void drain(void *arrived, io_iterator_t it) {
  io_service_t s; bool any = false;
  while ((s = IOIteratorNext(it))) {
    any = true;
    CFNumberRef pid = IORegistryEntryCreateCFProperty(s, CFSTR("idProduct"), NULL, 0);
    uint16_t v = 0;
    if (pid) { CFNumberGetValue(pid, kCFNumberSInt16Type, &v); CFRelease(pid); }
    if (arrived) cur_pid = v;
    IOObjectRelease(s);
  }
  if (!any) return;
  bool now = arrived != NULL, changed = now != present;
  LOG(@"pedal %s (pid %04x)%s", now ? "attached" : "detached", cur_pid, changed ? "" : ", no change");
  present = now;
  if (present && wanted) start_locked();
  if (!present) teardown();  // keep cur_pid: the HAL may still read the old name and UID while releasing the device
  // Only tell Core Audio about real changes, and not from this queue: StartIO may be waiting on it.
  void (*cb)(bool) = watch_cb;
  if (changed && cb) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ cb(now); });
}

void pod_watch(void (*cb)(bool)) {
  ensure_queue();
  watch_cb = cb;
  dispatch_async(q, ^{
    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    IONotificationPortSetDispatchQueue(port, q);
    io_iterator_t a, t;
    CFMutableDictionaryRef m = [IOUSBHostDevice createMatchingDictionaryWithVendorID:@POD_VID productID:nil bcdDevice:nil
                                    deviceClass:nil deviceSubclass:nil deviceProtocol:nil speed:nil productIDArray:model_pids()];
    CFRetain(m);  // each call consumes one reference
    IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, m, drain, (void *)1, &a);
    IOServiceAddMatchingNotification(port, kIOTerminatedNotification, m, drain, NULL, &t);
    drain((void *)1, a);
    drain(NULL, t);
  });
}
