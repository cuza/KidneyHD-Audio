// End-to-end check through Core Audio: finds the POD device, plays a quiet 440 Hz
// tone for a few seconds, records the input, and reports IO cycles and overloads.
// Exit code 0 means the device ran without overloads.
#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static double phase, peak;
static float tone_level = 0.1f;  // 0 with the "silent" argument
static unsigned cycles, overloads;

static OSStatus io(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *in_t,
                   AudioBufferList *out, const AudioTimeStamp *out_t, void *ctx) {
  cycles++;
  for (UInt32 b = 0; b < in->mNumberBuffers; b++) {
    const float *p = in->mBuffers[b].mData;
    for (UInt32 i = 0; i < in->mBuffers[b].mDataByteSize / sizeof(float); i++) peak = fmax(peak, fabs(p[i]));
  }
  for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
    float *p = out->mBuffers[b].mData;
    UInt32 ch = out->mBuffers[b].mNumberChannels, n = out->mBuffers[b].mDataByteSize / sizeof(float) / ch;
    for (UInt32 f = 0; f < n; f++) {
      float v = (float)sin(phase) * tone_level; phase = fmod(phase + 2 * M_PI * 440 / 48000, 2 * M_PI);
      for (UInt32 c = 0; c < ch; c++) p[f * ch + c] = v;
    }
  }
  return 0;
}

static OSStatus on_overload(AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress *a, void *ctx) {
  overloads++;
  return 0;
}

int main(int argc, char **argv) {
  double secs = argc > 1 ? atof(argv[1]) : 5;
  if (argc > 2 && !strcmp(argv[2], "silent")) tone_level = 0;
  AudioObjectPropertyAddress a = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
  UInt32 size = 0;
  AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size);
  AudioObjectID devs[64], pod = 0;
  AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, devs);
  for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) {
    CFStringRef uid = NULL; UInt32 s = sizeof uid;
    AudioObjectPropertyAddress u = { kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(devs[i], &u, 0, NULL, &s, &uid) || !uid) continue;
    if (CFStringHasPrefix(uid, CFSTR("KidneyHDAudio:"))) pod = devs[i];
    CFRelease(uid);
  }
  if (!pod) { puts("FAIL: no POD device in Core Audio"); return 1; }

  AudioObjectPropertyAddress ov = { kAudioDeviceProcessorOverload, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
  AudioObjectAddPropertyListener(pod, &ov, on_overload, NULL);
  AudioDeviceIOProcID proc;
  if (AudioDeviceCreateIOProcID(pod, io, NULL, &proc) || AudioDeviceStart(pod, proc)) { puts("FAIL: could not start IO"); return 1; }
  usleep((useconds_t)(secs * 1e6));
  AudioDeviceStop(pod, proc);
  AudioDeviceDestroyIOProcID(pod, proc);

  UInt32 buf = 0; size = sizeof buf;
  AudioObjectPropertyAddress bs = { kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
  AudioObjectGetPropertyData(pod, &bs, 0, NULL, &size, &buf);
  double expected = secs * 48000 / buf;
  printf("buffer %u frames, IO cycles %u (expected about %.0f), overloads %u, input peak %.1f dBFS\n",
         buf, cycles, expected, overloads, 20 * log10(peak + 1e-9));
  int fail = overloads > 0 || fabs(cycles - expected) > expected * 0.05;
  puts(fail ? "FAIL" : "PASS");
  return fail;
}
