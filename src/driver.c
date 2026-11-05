// Core Audio AudioServerPlugIn for the POD HD500 family. Publishes one device
// with a stereo input and a stereo output stream at 48 kHz. Audio moves
// through the rings in pod.h; the USB engine in usb.m keeps them fed.
#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include "pod.h"

enum { kPlugIn = kAudioObjectPlugInObject, kDevice = 2, kStreamIn = 3, kStreamOut = 4, kVolume = 5 };

// The HAL reads input this many frames behind "now" and writes output this far
// ahead. The output side has to cover the USB requests already queued (NT = 8 ms
// in usb.m) plus one request of slack.
// Raise these if you hear clicks under load.
#define SAFETY_IN 96
#define SAFETY_OUT 480

// Latency outside the buffer and safety offsets: the pedal's converters and processing and the USB
// transfer. tools/latency.c measured 140 frames (2.9 ms) round trip on a POD HD Desktop, within 8
// frames from one start to the next; it is split evenly, since DAWs add the two to line up recordings.
#define LATENCY_IN 70
#define LATENCY_OUT 70

static AudioServerPlugInHostRef host;

// Output volume, applied to the samples on their way to the pedal: the macOS volume slider and keys.
// The scalar maps linearly to VOL_MIN_DB...0 dB; 0 is silence.
#define VOL_MIN_DB -64.0f
static _Atomic float volume = 1.0f;
static float scalar_to_db(float s) { return s <= 0 ? VOL_MIN_DB : VOL_MIN_DB * (1 - (s > 1 ? 1 : s)); }
static float db_to_scalar(float db) { return db <= VOL_MIN_DB ? 0 : db >= 0 ? 1 : 1 - db / VOL_MIN_DB; }
static float volume_gain(void) { float s = volume; return s <= 0 ? 0 : powf(10, scalar_to_db(s) / 20); }
// The gain the last mix ended with. A volume change ramps from it across one IO buffer instead of
// jumping, which clicks. The IO thread uses it; StartIO sets it before IO runs.
static float mix_gain = 1;
static _Atomic int io_clients;
static _Atomic UInt32 refcount = 1;

// Apps see 32-bit float (the virtual format); the pedal works in 24-bit integer (the physical format).
// The IO buffers are in the physical format, and Core Audio converts between the two.
static const AudioStreamBasicDescription kFormat = {
  .mSampleRate = POD_RATE, .mFormatID = kAudioFormatLinearPCM,
  .mFormatFlags = kAudioFormatFlagsNativeFloatPacked, .mBytesPerPacket = 8, .mFramesPerPacket = 1,
  .mBytesPerFrame = 8, .mChannelsPerFrame = POD_CHANNELS, .mBitsPerChannel = 32,
};
static const AudioStreamBasicDescription kPhysical = {
  .mSampleRate = POD_RATE, .mFormatID = kAudioFormatLinearPCM,
  .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
  .mBytesPerPacket = POD_FRAME, .mFramesPerPacket = 1, .mBytesPerFrame = POD_FRAME,
  .mChannelsPerFrame = POD_CHANNELS, .mBitsPerChannel = 24,
};

// One UID per model, so macOS keeps separate settings for each pedal type. macOS remembers the
// chosen input and output by this UID, so changing it makes users pick the device again.
// The device's icon in Audio MIDI Setup and in apps that show one, from the driver bundle.
static CFURLRef icon_url(void) {
  CFBundleRef b = CFBundleGetBundleWithIdentifier(CFSTR("dev.cuza.kidneyhd-audio.driver"));
  return b ? CFBundleCopyResourceURL(b, CFSTR("KidneyHDAudio"), CFSTR("icns"), NULL) : NULL;
}

static CFStringRef device_uid(void) { return CFStringCreateWithFormat(NULL, NULL, CFSTR("KidneyHDAudio:0e41:%04x"), pod_pid()); }

static void presence_changed(bool present) {
  if (!host) return;
  AudioObjectPropertyAddress a[] = {
    { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    { kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
  };
  host->PropertiesChanged(host, kPlugIn, 2, a);
}

// One function answers every property. With out == NULL it only reports the size,
// which also drives HasProperty and GetPropertyDataSize.
#define VAL(type, v) do { if (out) { if (in_size < sizeof(type)) return kAudioHardwareBadPropertySizeError; *(type *)out = (v); } \
                          *out_size = sizeof(type); return 0; } while (0)
#define STR(s) VAL(CFStringRef, (CFStringRef)CFRetain(s))

static OSStatus ids(const AudioObjectID *list, UInt32 n, UInt32 in_size, UInt32 *out_size, void *out) {
  if (out && n > in_size / sizeof(AudioObjectID)) n = in_size / sizeof(AudioObjectID);
  if (out && n) memcpy(out, list, n * sizeof(AudioObjectID));
  *out_size = n * sizeof(AudioObjectID);
  return 0;
}

static OSStatus get(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qual_size, const void *qual,
                    UInt32 in_size, UInt32 *out_size, void *out) {
  AudioObjectPropertyScope scope = a->mScope;
  switch (obj) {
  case kPlugIn:
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: VAL(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: VAL(AudioClassID, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner: VAL(AudioObjectID, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer: STR(CFSTR("KidneyHD Audio"));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: {
      AudioObjectID d = kDevice;
      return ids(&d, pod_present() ? 1 : 0, in_size, out_size, out);
    }
    case kAudioPlugInPropertyTranslateUIDToDevice: {
      CFStringRef uid = device_uid();
      bool match = qual_size == sizeof(CFStringRef) && qual && CFEqual(*(CFStringRef *)qual, uid) && pod_present();
      CFRelease(uid);
      VAL(AudioObjectID, match ? kDevice : kAudioObjectUnknown);
    }
    case kAudioPlugInPropertyResourceBundle: STR(CFSTR(""));
    }
    break;

  case kDevice:
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: VAL(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: VAL(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: VAL(AudioObjectID, kPlugIn);
    case kAudioObjectPropertyName: VAL(CFStringRef, CFStringCreateWithCString(NULL, pod_name(), kCFStringEncodingUTF8));
    case kAudioObjectPropertyManufacturer: STR(CFSTR("Line 6"));
    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID: VAL(CFStringRef, device_uid());
    case kAudioDevicePropertyIcon: VAL(CFURLRef, icon_url());
    case kAudioDevicePropertyTransportType: VAL(UInt32, kAudioDeviceTransportTypeUSB);
    case kAudioDevicePropertyClockDomain: VAL(UInt32, 0);
    case kAudioDevicePropertyDeviceIsAlive: VAL(UInt32, pod_present());
    case kAudioDevicePropertyDeviceIsRunning: VAL(UInt32, io_clients > 0);
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: VAL(UInt32, 1);
    case kAudioDevicePropertyLatency: VAL(UInt32, scope == kAudioObjectPropertyScopeInput ? LATENCY_IN : LATENCY_OUT);
    case kAudioDevicePropertySafetyOffset: VAL(UInt32, scope == kAudioObjectPropertyScopeInput ? SAFETY_IN : SAFETY_OUT);
    case kAudioDevicePropertyNominalSampleRate: VAL(Float64, POD_RATE);
    case kAudioDevicePropertyAvailableNominalSampleRates: VAL(AudioValueRange, ((AudioValueRange){ POD_RATE, POD_RATE }));
    case kAudioDevicePropertyIsHidden: VAL(UInt32, 0);
    case kAudioDevicePropertyZeroTimeStampPeriod: VAL(UInt32, POD_RING);
    case kAudioDevicePropertyRelatedDevices: { AudioObjectID d = kDevice; return ids(&d, 1, in_size, out_size, out); }
    case kAudioObjectPropertyControlList: { AudioObjectID v = kVolume; return ids(&v, 1, in_size, out_size, out); }
    case kAudioDevicePropertyPreferredChannelsForStereo: {
      if (out && in_size < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
      if (out) { ((UInt32 *)out)[0] = 1; ((UInt32 *)out)[1] = 2; }
      *out_size = 2 * sizeof(UInt32);
      return 0;
    }
    case kAudioObjectPropertyOwnedObjects:
      if (scope == kAudioObjectPropertyScopeGlobal) {
        AudioObjectID all[] = { kStreamIn, kStreamOut, kVolume };
        return ids(all, 3, in_size, out_size, out);
      }
      // fall through: the scoped lists are the streams
    case kAudioDevicePropertyStreams: {
      AudioObjectID both[] = { kStreamIn, kStreamOut };
      if (scope == kAudioObjectPropertyScopeInput) return ids(&both[0], 1, in_size, out_size, out);
      if (scope == kAudioObjectPropertyScopeOutput) return ids(&both[1], 1, in_size, out_size, out);
      return ids(both, 2, in_size, out_size, out);
    }
    }
    break;

  case kStreamIn:
  case kStreamOut:
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: VAL(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: VAL(AudioClassID, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: VAL(AudioObjectID, kDevice);
    case kAudioObjectPropertyOwnedObjects: return ids(NULL, 0, in_size, out_size, out);
    case kAudioStreamPropertyIsActive: VAL(UInt32, 1);
    case kAudioStreamPropertyDirection: VAL(UInt32, obj == kStreamIn);
    case kAudioStreamPropertyTerminalType: VAL(UInt32, kAudioStreamTerminalTypeLine);
    case kAudioStreamPropertyStartingChannel: VAL(UInt32, 1);
    case kAudioStreamPropertyLatency: VAL(UInt32, 0);
    case kAudioStreamPropertyVirtualFormat: VAL(AudioStreamBasicDescription, kFormat);
    case kAudioStreamPropertyPhysicalFormat: VAL(AudioStreamBasicDescription, kPhysical);
    case kAudioStreamPropertyAvailableVirtualFormats:
      VAL(AudioStreamRangedDescription, ((AudioStreamRangedDescription){ kFormat, { POD_RATE, POD_RATE } }));
    case kAudioStreamPropertyAvailablePhysicalFormats:
      VAL(AudioStreamRangedDescription, ((AudioStreamRangedDescription){ kPhysical, { POD_RATE, POD_RATE } }));
    }
    break;

  case kVolume:
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: VAL(AudioClassID, kAudioLevelControlClassID);
    case kAudioObjectPropertyClass: VAL(AudioClassID, kAudioVolumeControlClassID);
    case kAudioObjectPropertyOwner: VAL(AudioObjectID, kDevice);
    case kAudioObjectPropertyOwnedObjects: return ids(NULL, 0, in_size, out_size, out);
    case kAudioControlPropertyScope: VAL(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
    case kAudioControlPropertyElement: VAL(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
    case kAudioLevelControlPropertyScalarValue: VAL(Float32, volume);
    case kAudioLevelControlPropertyDecibelValue: VAL(Float32, scalar_to_db(volume));
    case kAudioLevelControlPropertyDecibelRange: VAL(AudioValueRange, ((AudioValueRange){ VOL_MIN_DB, 0 }));
    // The value to convert arrives in the same buffer the answer goes into.
    case kAudioLevelControlPropertyConvertScalarToDecibels: VAL(Float32, out ? scalar_to_db(*(Float32 *)out) : 0);
    case kAudioLevelControlPropertyConvertDecibelsToScalar: VAL(Float32, out ? db_to_scalar(*(Float32 *)out) : 0);
    }
    break;
  }
  return kAudioHardwareUnknownPropertyError;
}

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a) {
  UInt32 size;
  return get(obj, a, 0, NULL, 0, &size, NULL) == 0;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid,
                                   const AudioObjectPropertyAddress *a, Boolean *out) {
  UInt32 size;
  OSStatus e = get(obj, a, 0, NULL, 0, &size, NULL);
  // Fixed format and rate; only the volume changes.
  if (!e) *out = obj == kVolume && (a->mSelector == kAudioLevelControlPropertyScalarValue ||
                                    a->mSelector == kAudioLevelControlPropertyDecibelValue);
  return e;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                    UInt32 qs, const void *q, UInt32 *out) {
  return get(obj, a, qs, q, 0, out, NULL);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                UInt32 qs, const void *q, UInt32 in_size, UInt32 *out_size, void *out) {
  return get(obj, a, qs, q, in_size, out_size, out);
}

// Apps sometimes "set" the only rate or format we have; accept that as a no-op.
static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                UInt32 qs, const void *q, UInt32 size, const void *data) {
  if (obj == kVolume && size == sizeof(Float32) &&
      (a->mSelector == kAudioLevelControlPropertyScalarValue || a->mSelector == kAudioLevelControlPropertyDecibelValue)) {
    Float32 v = *(const Float32 *)data;
    if (a->mSelector == kAudioLevelControlPropertyDecibelValue) v = db_to_scalar(v);
    volume = v < 0 ? 0 : v > 1 ? 1 : v;
    if (host) {
      Float32 saved = volume;
      CFNumberRef n = CFNumberCreate(NULL, kCFNumberFloat32Type, &saved);
      host->WriteToStorage(host, CFSTR("volume"), n);
      CFRelease(n);
      AudioObjectPropertyAddress changed[] = {
        { kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
      };
      host->PropertiesChanged(host, kVolume, 2, changed);
    }
    return 0;
  }
  if (a->mSelector == kAudioDevicePropertyNominalSampleRate && size == sizeof(Float64) && *(const Float64 *)data == POD_RATE) return 0;
  if ((a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat) &&
      size == sizeof(AudioStreamBasicDescription) && ((const AudioStreamBasicDescription *)data)->mSampleRate == POD_RATE &&
      ((const AudioStreamBasicDescription *)data)->mChannelsPerFrame == POD_CHANNELS) return 0;
  return kAudioHardwareUnsupportedOperationError;
}

// The HAL calls StartIO/StopIO once per client, possibly from different threads.
// One lock keeps the count and the USB start/stop in the same order.
static pthread_mutex_t io_lock = PTHREAD_MUTEX_INITIALIZER;
static double z_sample = -1;  // last zero time stamp handed out; -1 = none yet
static UInt64 z_host;

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
  OSStatus e = 0;
  pthread_mutex_lock(&io_lock);
  if (io_clients == 0) {
    if (pod_start()) { z_sample = -1; mix_gain = volume_gain(); } else e = kAudioHardwareNotRunningError;
  }
  if (!e) io_clients++;
  pthread_mutex_unlock(&io_lock);
  return e;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
  OSStatus e = 0;
  pthread_mutex_lock(&io_lock);
  if (io_clients == 0) e = kAudioHardwareIllegalOperationError;
  else if (--io_clients == 0) pod_stop();
  pthread_mutex_unlock(&io_lock);
  return e;
}

// Each zero time stamp is computed once and then only moves forward by whole
// periods, like Apple's NullAudio sample. Recomputing it on every call from the
// moving clock model looked like jitter to the HAL and made it resync.
static os_unfair_lock z_lock = OS_UNFAIR_LOCK_INIT;
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client,
                                 Float64 *sample, UInt64 *host_time, UInt64 *seed) {
  pod_clock_t c = pod_clock();
  double now = (double)mach_absolute_time();
  os_unfair_lock_lock(&z_lock);
  if (z_sample < 0 && c.ticks_per_frame > 0) {
    z_sample = floor((c.anchor_sample + (now - c.anchor_host) / c.ticks_per_frame) / POD_RING) * POD_RING;
    z_host = (UInt64)(c.anchor_host + (z_sample - c.anchor_sample) * c.ticks_per_frame);
  }
  for (double next; c.ticks_per_frame > 0 &&
       (next = c.anchor_host + (z_sample + POD_RING - c.anchor_sample) * c.ticks_per_frame) <= now; ) {
    z_sample += POD_RING;
    z_host = (UInt64)next;
  }
  *sample = z_sample < 0 ? 0 : z_sample;
  *host_time = z_host;
  *seed = 1;
  os_unfair_lock_unlock(&z_lock);
  return 0;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op,
                                  Boolean *will, Boolean *in_place) {
  // The volume is applied to the mix while it is still float (ProcessMix), before Core Audio converts it.
  // The HAL asks once when IO starts, so ProcessMix is always taken and does nothing at full volume.
  *will = op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix ||
          op == kAudioServerPlugInIOOperationProcessMix;
  *in_place = true;
  return 0;
}

static OSStatus BeginEndIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames,
                           const AudioServerPlugInIOCycleInfo *info) {
  return 0;
}

// Copies between an IO buffer and a ring, wrapping at POD_RING.
static void ring_copy(uint8_t *ring, uint64_t start, uint8_t *buf, UInt32 frames, bool to_ring) {
  while (frames) {
    uint64_t i = start & (POD_RING - 1);
    UInt32 n = (UInt32)(POD_RING - i) < frames ? (UInt32)(POD_RING - i) : frames;
    uint8_t *r = ring + i * POD_FRAME;
    if (to_ring) memcpy(r, buf, n * POD_FRAME); else memcpy(buf, r, n * POD_FRAME);
    buf += n * POD_FRAME; start += n; frames -= n;
  }
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectID stream, UInt32 client, UInt32 op,
                              UInt32 frames, const AudioServerPlugInIOCycleInfo *info, void *main, void *secondary) {
  if (op == kAudioServerPlugInIOOperationReadInput) {
    int64_t s = (int64_t)info->mInputTime.mSampleTime;
    int64_t ok = (int64_t)pod_in_count() - s;  // frames already captured; zero the rest instead of replaying old audio
    ok = s < 0 || ok < 0 ? 0 : ok > frames ? frames : ok;
    if (ok) ring_copy(pod_in_ring, (uint64_t)s, main, (UInt32)ok, false);
    memset((uint8_t *)main + ok * POD_FRAME, 0, (frames - ok) * POD_FRAME);
  } else if (op == kAudioServerPlugInIOOperationProcessMix) {
    float from = mix_gain, to = volume_gain();
    mix_gain = to;
    if (from != 1 || to != 1) {
      float *x = main;
      for (UInt32 f = 0; f < frames; f++) {
        float g = from + (to - from) * (float)(f + 1) / (float)frames;
        for (UInt32 c = 0; c < POD_CHANNELS; c++) x[f * POD_CHANNELS + c] *= g;
      }
    }
  } else if (op == kAudioServerPlugInIOOperationWriteMix) {
    int64_t s = (int64_t)info->mOutputTime.mSampleTime;
    int64_t late = (int64_t)pod_out_count() - s;  // frames USB already sent
    if (late > 0) pod_note_late_write();
    // Late audio would land in slots that already played and pop out one ring later; drop it.
    if (s < 0 || late >= (int64_t)frames) return 0;
    if (late > 0) { main = (uint8_t *)main + late * POD_FRAME; s += late; frames -= (UInt32)late; }
    ring_copy(pod_out_ring, (uint64_t)s, main, frames, true);
  }
  return 0;
}

static OSStatus Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef h) {
  host = h;
  CFPropertyListRef saved = NULL;
  if (host->CopyFromStorage(host, CFSTR("volume"), &saved) == 0 && saved) {
    Float32 v;
    if (CFGetTypeID(saved) == CFNumberGetTypeID() && CFNumberGetValue(saved, kCFNumberFloat32Type, &v)) volume = v < 0 ? 0 : v > 1 ? 1 : v;
    CFRelease(saved);
  }
  pod_watch(presence_changed);
  return 0;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *ci, AudioObjectID *out) {
  return kAudioHardwareUnsupportedOperationError;
}
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID dev) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus DeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo *ci) { return 0; }
static OSStatus ConfigChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void *info) { return 0; }

static HRESULT QueryInterface(void *d, REFIID iid, LPVOID *out);
static ULONG AddRef(void *d) { return ++refcount; }
static ULONG Release(void *d) { return --refcount; }

static AudioServerPlugInDriverInterface vtable = {
  NULL, QueryInterface, AddRef, Release,
  Initialize, CreateDevice, DestroyDevice, DeviceClient, DeviceClient, ConfigChange, ConfigChange,
  HasProperty, IsPropertySettable, GetPropertyDataSize, GetPropertyData, SetPropertyData,
  StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation, BeginEndIO, DoIOOperation, BeginEndIO,
};
static AudioServerPlugInDriverInterface *vtable_ptr = &vtable;
static AudioServerPlugInDriverRef driver = &vtable_ptr;

static HRESULT QueryInterface(void *d, REFIID iid, LPVOID *out) {
  CFUUIDRef want = CFUUIDCreateFromUUIDBytes(NULL, iid);
  bool ok = CFEqual(want, IUnknownUUID) || CFEqual(want, kAudioServerPlugInDriverInterfaceUUID);
  CFRelease(want);
  if (!ok) { *out = NULL; return E_NOINTERFACE; }
  AddRef(d);
  *out = driver;
  return S_OK;
}

// Factory named in Info.plist (CFPlugInFactories).
__attribute__((visibility("default"))) void *KidneyHDAudio_Create(CFAllocatorRef alloc, CFUUIDRef type) {
  return CFEqual(type, kAudioServerPlugInTypeUUID) ? driver : NULL;
}
