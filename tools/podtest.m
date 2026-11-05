// Hardware check for the USB engine: streams for a few seconds, plays a quiet
// 440 Hz tone the way the HAL would (writing ahead of the USB read position),
// and asserts the clock and counters behave. Exit code 0 means pass.
#import <Foundation/Foundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include "../src/pod.h"

int main(int argc, char **argv) {
  double secs = argc > 1 ? atof(argv[1]) : 5;
  if (!pod_start()) { puts("FAIL: could not start (pedal missing or busy?)"); return 1; }
  uint64_t written = pod_out_count() + 256, start_in = pod_in_count(), t0 = mach_absolute_time();
  double phase = 0, peak = 0;
  mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  while ((mach_absolute_time() - t0) * tb.numer / tb.denom < secs * 1e9) {
    uint64_t target = pod_out_count() + 512;  // stay ahead of USB like the HAL's safety offset
    for (; written < target; written++) {
      float v = (float)sin(phase) * 0.1f; phase = fmod(phase + 2 * M_PI * 440 / POD_RATE, 2 * M_PI);
      int32_t q = (int32_t)lrint(v * 8388607.0);
      uint8_t *f = &pod_out_ring[(written & (POD_RING - 1)) * POD_FRAME];
      for (int ch = 0; ch < 2; ch++) { f[ch * 3] = q; f[ch * 3 + 1] = q >> 8; f[ch * 3 + 2] = q >> 16; }
    }
    uint64_t n = pod_in_count();
    for (uint64_t s = n > 256 ? n - 256 : 0; s < n; s++) {
      const uint8_t *p = &pod_in_ring[(s & (POD_RING - 1)) * POD_FRAME];
      int32_t q = (int32_t)((uint32_t)p[0] << 8 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 24) >> 8;
      peak = fmax(peak, fabs(q / 8388608.0));
    }
    usleep(2000);
  }
  pod_clock_t c = pod_clock();
  uint64_t got = pod_in_count() - start_in;
  double elapsed = (mach_absolute_time() - t0) * (double)tb.numer / tb.denom / 1e9;
  double rate = 1e9 / (c.ticks_per_frame * tb.numer / tb.denom);
  // Where the clock model says "now" is, versus frames actually received.
  double model_now = c.anchor_sample + (mach_absolute_time() - c.anchor_host) / c.ticks_per_frame;
  long lag = (long)(model_now - pod_in_count());
  pod_stop();

  printf("frames in %llu over %.2fs (%.1f Hz), clock %.2f Hz, out-in %lld, model-now minus received %ld, errors %u, input peak %.1f dBFS\n",
         got, elapsed, got / elapsed, rate, (long long)(pod_out_count() - pod_in_count()), lag, pod_errors(), 20 * log10(peak + 1e-9));
  int fail = 0;
  if (fabs(got / elapsed - POD_RATE) > POD_RATE * 0.01) { puts("FAIL: capture rate off by >1%"); fail = 1; }
  if (fabs(rate - POD_RATE) > POD_RATE * 0.001) { puts("FAIL: clock model off by >0.1%"); fail = 1; }
  if (labs(lag) > 96) { puts("FAIL: clock model drifted from received frames"); fail = 1; }
  if (pod_errors() > 10) { puts("FAIL: USB errors"); fail = 1; }
  puts(fail ? "FAIL" : "PASS");
  return fail;
}
