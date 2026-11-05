// USB engine for the Line 6 POD HD500 family (HD Desktop, HD500, HD500X,
// HD Pro, HD Pro X), shared by the Core Audio plug-in and the CLI test.
// Only the HD Desktop has been tested on hardware; the others use the same
// layout according to the Linux driver and Line 6's old kext.
//
// Wire format (from the Linux line6 driver, confirmed on hardware):
// interface 0 alt 1, iso OUT 0x02 / iso IN 0x86, one packet per 125 us
// microframe, 48 kHz, 2 channels, signed 24-bit little-endian packed, no
// headers. The pedal is the clock master: each OUT packet carries as many
// frames as the latest IN packet did. Capture only runs while playback does.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#define POD_VID 0x0e41
#define POD_RATE 48000.0
#define POD_CHANNELS 2
#define POD_RING 16384  // frames per ring buffer, power of two

#define POD_FRAME 6     // bytes per frame: 2 channels of signed 24-bit little-endian, as on USB
// Rings indexed by sample time modulo POD_RING, in the pedal's own format. Core Audio converts
// to and from float itself, so no sample is changed on the way.
extern uint8_t pod_in_ring[POD_RING * POD_FRAME];
extern uint8_t pod_out_ring[POD_RING * POD_FRAME];

// Starts streaming. Returns false when the pedal is missing or busy.
bool pod_start(void);
void pod_stop(void);
bool pod_running(void);

// Clock model: host time (mach ticks) of sample time `s` is
// anchor_host + (s - anchor_sample) * ticks_per_frame.
typedef struct { double anchor_host, anchor_sample, ticks_per_frame; } pod_clock_t;
pod_clock_t pod_clock(void);

// Frames captured so far (the newest valid input sample time is this - 1).
uint64_t pod_in_count(void);
uint64_t pod_out_count(void);
uint32_t pod_errors(void);
// The plug-in reports output that arrived after USB already sent those frames.
void pod_note_late_write(void);

// Called on attach (true) and detach (false), from a private queue.
void pod_watch(void (*cb)(bool present));
bool pod_present(void);
// Product ID and model name of the attached pedal (0 and "POD HD" when none).
uint16_t pod_pid(void);
const char *pod_name(void);
