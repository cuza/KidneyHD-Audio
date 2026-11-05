// Measures the round-trip latency beyond the buffer and safety offsets, which the driver reports as
// kAudioDevicePropertyLatency (LATENCY_IN and LATENCY_OUT in src/driver.c). Needs a cable from one of the
// pedal's outputs back into its input, and a preset that passes the signal through (no amp, no
// effects). Plays a short click every half second and finds each one in the input.
//
// Core Audio stamps the IO buffers with the buffer and the safety offsets already counted, but not the
// latency a driver reports, which only apps such as DAWs add. So the gap measured here is the latency
// the driver should report, whatever it reports now. It varies by a few frames from one start to the
// next, so run it a few times.
#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define PERIOD 24000  // a click every 0.5 s at 48 kHz
#define BURST 24      // click length in frames
#define MAX 64

static double clicks[MAX], hits[MAX];
static int nclicks, nhits;
static double last_hit = -1e12;
static float threshold = 0.02f;

static OSStatus io(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *in_t,
                   AudioBufferList *out, const AudioTimeStamp *out_t, void *ctx) {
  for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
    float *p = out->mBuffers[b].mData;
    UInt32 ch = out->mBuffers[b].mNumberChannels, n = out->mBuffers[b].mDataByteSize / sizeof(float) / ch;
    for (UInt32 f = 0; f < n; f++) {
      long long t = (long long)out_t->mSampleTime + f;
      int phase = (int)(t % PERIOD);
      if (b == 0 && phase == 0 && nclicks < MAX) clicks[nclicks++] = t;
      for (UInt32 c = 0; c < ch; c++) p[f * ch + c] = phase < BURST ? 0.5f : 0;
    }
  }
  for (UInt32 b = 0; b < in->mNumberBuffers && b < 1; b++) {
    const float *p = in->mBuffers[b].mData;
    UInt32 ch = in->mBuffers[b].mNumberChannels, n = in->mBuffers[b].mDataByteSize / sizeof(float) / ch;
    for (UInt32 f = 0; f < n; f++) {
      double t = in_t->mSampleTime + f;
      if (fabsf(p[f * ch]) > threshold && t - last_hit > PERIOD / 2 && nhits < MAX) hits[nhits++] = last_hit = t;
    }
  }
  return 0;
}

static UInt32 get_u32(AudioObjectID o, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
  AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain };
  UInt32 v = 0, s = sizeof v;
  AudioObjectGetPropertyData(o, &a, 0, NULL, &s, &v);
  return v;
}

static int cmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return (x > y) - (x < y); }

int main(int argc, char **argv) {
  double secs = argc > 1 ? atof(argv[1]) : 6;
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

  AudioDeviceIOProcID proc;
  if (AudioDeviceCreateIOProcID(pod, io, NULL, &proc) || AudioDeviceStart(pod, proc)) { puts("FAIL: could not start IO"); return 1; }
  usleep((useconds_t)(secs * 1e6));
  AudioDeviceStop(pod, proc);
  AudioDeviceDestroyIOProcID(pod, proc);

  printf("reported: buffer %u, safety offset in %u / out %u, latency in %u / out %u frames\n",
         get_u32(pod, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal),
         get_u32(pod, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput),
         get_u32(pod, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput),
         get_u32(pod, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput),
         get_u32(pod, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput));

  // Pair each hit with the latest click played before it.
  double delays[MAX]; int n = 0;
  for (int h = 0; h < nhits; h++) {
    double best = -1;
    for (int c = 0; c < nclicks; c++) if (clicks[c] <= hits[h] && hits[h] - clicks[c] < PERIOD / 2) best = clicks[c];
    if (best >= 0) delays[n++] = hits[h] - best;
  }
  if (n < 3) { printf("FAIL: heard %d of %d clicks. Check the loopback cable, the preset and the volume.\n", n, nclicks); return 1; }
  qsort(delays, n, sizeof *delays, cmp);
  double med = delays[n / 2];
  printf("round trip beyond the safety offsets: %.0f frames (%.2f ms), median of %d clicks, spread %.0f frames\n",
         med, med / 48.0, n, delays[n - 1] - delays[0]);
  return 0;
}
