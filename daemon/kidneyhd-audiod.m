// kidneyhd-audiod: owns the POD HD control channel (interface 1, bulk 0x01 out / 0x81 in)
// and shares it with editors over a Unix socket and XPC.
//
// Why a daemon: the pedal plays USB audio only while the host keeps reads pending
// on 0x81, and only one process can own interface 1.
//
// Socket protocol, both directions: [length byte][one USB packet of that length].
// Editor packets go to the pedal; every pedal packet goes to every connected client.
#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <os/log.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <xpc/xpc.h>

#define LOG(...) os_log(OS_LOG_DEFAULT, "kidneyhd-audiod: %{public}s", [[NSString stringWithFormat:__VA_ARGS__] UTF8String])
#define READS 16  // same as Line 6's kext

static NSArray *pids(void) { return @[ @0x4156, @0x414D, @0x4159, @0x4157, @0x415A ]; }  // HD Desktop, 500, 500X, Pro, Pro X

static dispatch_queue_t q;
static IOUSBHostInterface *ctl;
static int64_t pedal_pid;  // USB product ID of the pedal whose control channel is open
static NSString *pedal_serial;   // serial number text
static int64_t pedal_usb_fw;     // USB firmware word, 0x1040 for version 1.04; 0 when unknown
static NSData *pedal_licenses;   // 8 bytes at 0xf000: model pack license bits, a cleared bit is a licensed pack
static IOUSBHostPipe *in_pipe, *out_pipe;
static NSMutableSet<NSNumber *> *clients;  // socket fds
static NSMutableArray *xpc_peers;          // XPC connections from sandboxed editors

// Sandboxed apps (Kidney, including its App Store build) can't reach the Unix socket, but may
// look up Mach services named after one of their App Groups. Only apps signed by this team connect.
#define XPC_SERVICE "ECKB9WN282.dev.cuza.kidney.audiod"
#define XPC_PEER_REQUIREMENT "anchor apple generic and certificate leaf[subject.OU] = \"ECKB9WN282\""
#define SOCKET_PATH "/var/run/kidneyhd-audiod.sock"

static io_service_t find(NSNumber *ifnum) {
  CFMutableDictionaryRef m = ifnum
    ? [IOUSBHostInterface createMatchingDictionaryWithVendorID:@0x0e41 productID:nil bcdDevice:nil interfaceNumber:ifnum
                                            configurationValue:@1 interfaceClass:nil interfaceSubclass:nil interfaceProtocol:nil
                                                         speed:nil productIDArray:pids()]
    : [IOUSBHostDevice createMatchingDictionaryWithVendorID:@0x0e41 productID:nil bcdDevice:nil deviceClass:nil
                                             deviceSubclass:nil deviceProtocol:nil speed:nil productIDArray:pids()];
  return IOServiceGetMatchingService(kIOMainPortDefault, m);
}

static void send_to_pedal(const uint8_t *p, size_t n) {
  if (!out_pipe || !n || n > 64) return;
  NSMutableData *d = [ctl ioDataWithCapacity:n error:nil];  // fixed length = n
  if (!d) return;
  memcpy(d.mutableBytes, p, n);
  NSError *err;
  IOUSBHostPipe *pipe = out_pipe;
  if (![pipe enqueueIORequestWithData:d completionTimeout:2.0 error:&err
                    completionHandler:^(IOReturn st, NSUInteger done) {
    if (st == kIOReturnSuccess || st == kIOReturnAborted) return;
    LOG(@"write to pedal failed: 0x%x", st);
    // Any error but a timeout halts the endpoint, and later writes fail until the stall is cleared.
    if (st != kIOReturnTimeout && pipe == out_pipe) [pipe clearStallWithError:nil];
  }]) LOG(@"write to pedal: %@", err);
}

static void broadcast(const uint8_t *p, size_t n) {
  uint8_t frame[65] = { (uint8_t)n };
  memcpy(frame + 1, p, n);
  for (NSNumber *fd in clients.allObjects)
    // A client that stops reading is dropped. Its read source sees EOF and closes the fd.
    if (write(fd.intValue, frame, n + 1) != (ssize_t)(n + 1)) shutdown(fd.intValue, SHUT_RDWR);
  for (xpc_connection_t peer in xpc_peers) {
    xpc_object_t m = xpc_dictionary_create_empty();
    xpc_dictionary_set_data(m, "pkt", p, n);
    xpc_connection_send_message(peer, m);
  }
}

static void close_pedal(void);
static void recover_reads(void);
static int read_failures;  // recoveries since the last good read

static void read_pedal(NSMutableData *buf) {
  if (!buf) return;
  [in_pipe enqueueIORequestWithData:buf completionTimeout:0 error:nil completionHandler:^(IOReturn st, NSUInteger n) {
    if (!ctl) return;
    if (st == kIOReturnSuccess) read_failures = 0;
    if (st == kIOReturnSuccess && n) broadcast(buf.bytes, n);
    if (st == kIOReturnSuccess || st == kIOReturnTimeout || st == kIOReturnUnderrun) read_pedal(buf);
    else if (st != kIOReturnAborted) recover_reads();
  }];
}

// Any bulk error other than a timeout halts the endpoint, and every later read fails until the stall
// is cleared; with no reads left the pedal mutes playback. Clearing the stall also aborts the reads
// still queued, so a fresh set follows. Each retry waits 100 ms longer. After 5 retries without a good
// read, the interface is closed and the retry timer opens it again.
static void recover_reads(void) {
  static bool scheduled;
  if (scheduled) return;
  scheduled = true;
  IOUSBHostInterface *c = ctl;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ++read_failures * (int64_t)NSEC_PER_SEC / 10), q, ^{
    scheduled = false;
    if (ctl != c) return;  // closed or reopened meanwhile
    NSError *err;
    if (read_failures > 5 || ![in_pipe clearStallWithError:&err]) {
      LOG(@"pedal reads keep failing, reopening the control channel: %@", err);
      close_pedal();
      return;
    }
    for (int i = 0; i < READS; i++) read_pedal([ctl ioDataWithCapacity:64 error:nil]);
  });
}

static void close_pedal(void) {
  if (!ctl) return;
  IOUSBHostInterface *c = ctl;
  ctl = nil;
  [in_pipe abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
  [out_pipe abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
  [c destroy];
  in_pipe = out_pipe = nil;
  LOG(@"pedal released");
}

// Line 6 vendor request 0x67 on the whole device (as the Linux line6 driver sends it). IN when `len` > 0.
static NSData *vendor(IOUSBHostDevice *dev, bool in, uint16_t value, uint16_t index, uint16_t len) {
  IOUSBDeviceRequest r = { .bmRequestType = (uint8_t)((in ? 0x80 : 0x00) | (2 << 5)), .bRequest = 0x67,
                           .wValue = value, .wIndex = index, .wLength = len };
  NSMutableData *d = len ? [NSMutableData dataWithLength:len] : nil;
  NSUInteger got = 0;
  if (![dev sendDeviceRequest:r data:d bytesTransferred:&got completionTimeout:1.0 error:nil]) return nil;
  return d ? [d subdataWithRange:NSMakeRange(0, got)] : [NSData data];
}

// line6_read_data: set the address, wait while the status byte is 0xff, then read.
static NSData *read_data(IOUSBHostDevice *dev, uint16_t address, uint8_t len) {
  if (!vendor(dev, false, (uint16_t)((len << 8) | 0x21), address, 0)) return nil;
  for (int i = 0; i < 20; i++) {
    NSData *s = vendor(dev, true, 0x12, 0, 1);
    if (!s.length) return nil;
    if (((const uint8_t *)s.bytes)[0] != 0xff) break;
    usleep(10000);
  }
  return vendor(dev, true, 0x13, 0, len);
}

// Reads the USB firmware version (request 0x11) and the serial number text (stored at 0x822c) once per
// connection, for the editor's hello. Neither touches the audio or control interfaces.
static void read_device_info(void) {
  pedal_serial = nil;
  pedal_usb_fw = 0;
  pedal_licenses = nil;
  io_service_t d = find(nil);
  if (!d) return;
  IOUSBHostDevice *dev = [[IOUSBHostDevice alloc] initWithIOService:d options:0 queue:nil error:nil interestHandler:nil];
  IOObjectRelease(d);
  if (!dev) return;
  NSData *fw = vendor(dev, true, 0x11, 0, 3);
  if (fw.length >= 2) { const uint8_t *b = fw.bytes; pedal_usb_fw = b[0] | b[1] << 8; }
  NSMutableData *text = [NSMutableData data];
  for (uint16_t a = 0x822c; a < 0x822c + 32; a += 8) {
    NSData *chunk = read_data(dev, a, 8);
    if (!chunk) break;
    [text appendData:chunk];
    if (memchr(chunk.bytes, 0, chunk.length)) break;
  }
  const char *c = text.bytes;
  size_t n = strnlen(c ? c : "", text.length);
  bool printable = n > 0;
  for (size_t i = 0; i < n; i++) if (c[i] < 0x20 || c[i] > 0x7e) printable = false;
  if (printable) pedal_serial = [[NSString alloc] initWithBytes:c length:n encoding:NSASCIIStringEncoding];
  // Model pack licenses: pack n is licensed when bit (0x80 >> n % 8) of byte n / 8 is clear.
  NSData *bits = read_data(dev, 0xf000, 8);
  if (bits.length == 8) pedal_licenses = bits;
  [dev destroy];
  LOG(@"pedal USB firmware 0x%llx, serial number %s", (long long)pedal_usb_fw, pedal_serial ? "read" : "unknown");
}

static void open_pedal(void) {
  if (ctl) return;
  io_service_t s = find(@1);
  if (!s) {  // the pedal enumerates unconfigured; interfaces appear after SET_CONFIGURATION 1
    io_service_t d = find(nil);
    if (!d) return;
    IOUSBHostDevice *dev = [[IOUSBHostDevice alloc] initWithIOService:d options:0 queue:q error:nil interestHandler:nil];
    IOObjectRelease(d);
    [dev configureWithValue:1 matchInterfaces:YES error:nil];
    [dev destroy];
    for (int i = 0; i < 100 && !(s = find(@1)); i++) usleep(10000);
    if (!s) { LOG(@"control interface did not appear"); return; }
  }
  NSError *err;
  ctl = [[IOUSBHostInterface alloc] initWithIOService:s options:0 queue:q error:&err
                                      interestHandler:^(IOUSBHostObject *o, uint32_t type, void *arg) {
    if (type == kIOMessageServiceIsTerminated) close_pedal();
  }];
  CFNumberRef pid = IORegistryEntrySearchCFProperty(s, kIOServicePlane, CFSTR("idProduct"), NULL,
                                                   kIORegistryIterateRecursively | kIORegistryIterateParents);
  if (pid) { CFNumberGetValue(pid, kCFNumberSInt64Type, &pedal_pid); CFRelease(pid); }
  IOObjectRelease(s);
  if (!ctl || !(in_pipe = [ctl copyPipeWithAddress:0x81 error:&err]) || !(out_pipe = [ctl copyPipeWithAddress:0x01 error:&err])) {
    static bool told;
    if (!told) LOG(@"cannot open control interface (another program has it?), retrying: %@", err);
    told = true;
    ctl = nil; in_pipe = out_pipe = nil;
    return;
  }
  read_failures = 0;
  for (int i = 0; i < READS; i++) read_pedal([ctl ioDataWithCapacity:64 error:nil]);
  // Monitor level 1.0 (the USB playback level), as Line 6's driver sends at startup.
  float gain = 1.0f;
  uint8_t msg[16] = { 0x0c, 0, 0x01, 0, 0x02, 0, 0x04, 0x41, 0x04, 0, 0x13, 0 };
  memcpy(msg + 12, &gain, 4);
  send_to_pedal(msg, sizeof msg);
  read_device_info();
  LOG(@"pedal control channel open");
}

static void on_usb(void *ref, io_iterator_t it) {
  io_service_t s; bool any = false;
  while ((s = IOIteratorNext(it))) { any = true; IOObjectRelease(s); }
  if (any && ref) open_pedal();
  if (any && !ref) close_pedal();
}

static void serve_client(int fd) {
  fcntl(fd, F_SETFL, O_NONBLOCK);  // a stalled editor must not block the pedal's reads
  [clients addObject:@(fd)];
  LOG(@"editor connected (%lu)", (unsigned long)clients.count);
  dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, q);
  NSMutableData *acc = [NSMutableData data];
  dispatch_source_set_event_handler(src, ^{
    uint8_t buf[4096];
    ssize_t n = read(fd, buf, sizeof buf);
    if (n < 0 && errno == EAGAIN) return;
    if (n <= 0) { dispatch_source_cancel(src); return; }
    [acc appendBytes:buf length:n];
    const uint8_t *p = acc.bytes; size_t len = acc.length, off = 0;
    while (off < len && len - off > p[off]) { send_to_pedal(p + off + 1, p[off]); off += 1 + p[off]; }
    [acc replaceBytesInRange:NSMakeRange(0, off) withBytes:NULL length:0];
  });
  dispatch_source_set_cancel_handler(src, ^{
    [clients removeObject:@(fd)];
    close(fd);
    LOG(@"editor disconnected (%lu)", (unsigned long)clients.count);
  });
  dispatch_resume(src);
}

// XPC protocol, both directions: a dictionary with "pkt" = one raw USB packet (up to 64 bytes).
static xpc_connection_t listener;  // must outlive serve_xpc: under ARC a local would be released and the service closed
static void serve_xpc(void) {
  listener = xpc_connection_create_mach_service(XPC_SERVICE, q, XPC_CONNECTION_MACH_SERVICE_LISTENER);
  xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
    if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
    if (xpc_connection_set_peer_code_signing_requirement(peer, XPC_PEER_REQUIREMENT) != 0) {
      LOG(@"XPC: could not set the signing requirement, refusing the client");
      xpc_connection_cancel(peer);
      return;
    }
    xpc_connection_set_target_queue(peer, q);
    xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
      if (xpc_get_type(msg) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_bool(msg, "hello")) {
        // Handshake: lets the editor tell "no daemon" and "no pedal" apart from a silent pedal.
        xpc_object_t reply = xpc_dictionary_create_reply(msg);
        if (reply) {
          xpc_dictionary_set_bool(reply, "pedal", ctl != nil);
          xpc_dictionary_set_int64(reply, "pid", ctl ? pedal_pid : 0);
          if (ctl && pedal_serial) xpc_dictionary_set_string(reply, "serial", pedal_serial.UTF8String);
          if (ctl && pedal_usb_fw) xpc_dictionary_set_int64(reply, "usbfw", pedal_usb_fw);
          if (ctl && pedal_licenses) xpc_dictionary_set_data(reply, "licenses", pedal_licenses.bytes, pedal_licenses.length);
          xpc_connection_send_message(peer, reply);
        }
      } else if (xpc_get_type(msg) == XPC_TYPE_DICTIONARY) {
        size_t n = 0;
        const void *bytes = xpc_dictionary_get_data(msg, "pkt", &n);
        if (bytes) send_to_pedal(bytes, n);
      } else {  // invalidated, interrupted, or refused by the signing requirement
        [xpc_peers removeObject:peer];
        LOG(@"XPC editor disconnected (%lu)", (unsigned long)xpc_peers.count);
      }
    });
    [xpc_peers addObject:peer];
    xpc_connection_activate(peer);
    LOG(@"XPC editor connected (%lu)", (unsigned long)xpc_peers.count);
  });
  xpc_connection_activate(listener);
}

int main(void) {
  @autoreleasepool {
    q = dispatch_queue_create("kidneyhd-audiod", DISPATCH_QUEUE_SERIAL);
    clients = [NSMutableSet set];
    xpc_peers = [NSMutableArray array];
    signal(SIGPIPE, SIG_IGN);

    int ls = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = { .sun_family = AF_UNIX, .sun_path = SOCKET_PATH };
    unlink(SOCKET_PATH);
    if (ls < 0 || bind(ls, (struct sockaddr *)&a, sizeof a) || listen(ls, 8)) { LOG(@"cannot listen on %s: %s", SOCKET_PATH, strerror(errno)); return 1; }
    // Editors run as the logged-in user. Local user accounts are in the staff group; other accounts get no access.
    struct group *staff = getgrnam("staff");
    if (staff) chown(SOCKET_PATH, 0, staff->gr_gid);
    chmod(SOCKET_PATH, staff ? 0660 : 0600);
    dispatch_source_t acc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, ls, 0, q);
    dispatch_source_set_event_handler(acc, ^{
      int fd = accept(ls, NULL, NULL);
      if (fd >= 0) { serve_client(fd); return; }
      if (errno != EMFILE && errno != ENFILE) return;
      // Out of file descriptors: the socket stays readable, so this handler would run again at once and
      // spin. Pause accepting for a second instead; the waiting editor connects then.
      LOG(@"out of file descriptors, pausing new editor connections");
      dispatch_suspend(acc);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), q, ^{ dispatch_resume(acc); });
    });
    dispatch_resume(acc);

    // If another program holds the control interface, keep trying every 2 s.
    dispatch_source_t retry = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(retry, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(retry, ^{
      if (ctl) return;
      io_service_t d = find(nil);
      if (!d) return;
      IOObjectRelease(d);
      open_pedal();
    });
    dispatch_resume(retry);

    dispatch_async(q, ^{
      IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
      IONotificationPortSetDispatchQueue(port, q);
      CFMutableDictionaryRef m = [IOUSBHostDevice createMatchingDictionaryWithVendorID:@0x0e41 productID:nil bcdDevice:nil
                                    deviceClass:nil deviceSubclass:nil deviceProtocol:nil speed:nil productIDArray:pids()];
      CFRetain(m);  // each registration consumes one reference
      io_iterator_t on, off;
      IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, m, on_usb, (void *)1, &on);
      IOServiceAddMatchingNotification(port, kIOTerminatedNotification, m, on_usb, NULL, &off);
      on_usb((void *)1, on);
      on_usb(NULL, off);
    });
    LOG(@"listening on %s and %s", SOCKET_PATH, XPC_SERVICE);
    serve_xpc();
    dispatch_main();
  }
}
