// Keeps each editor's messages whole on the way to the pedal.
//
// A message to the pedal spans several USB packets: [n][0][t][0] followed by n data bytes, t = 1 for the first
// packet and 4 for the rest. The first packet's data starts with a little-endian u16 holding the message size in
// 32-bit words minus one. The pedal never restarts a message that is cut off, so a packet from another editor in
// the middle of one would corrupt both and can leave the pedal ignoring everything until it is power cycled.
// While one editor is partway through a message, packets from the others wait.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
  intptr_t owner;   // the editor partway through a message; 0 when none
  long remaining;   // data bytes still to come in that message
} arbiter_t;

// Whether `editor` (any nonzero id) may send `pkt` now. When it may, the arbiter records the packet; when it may
// not, the caller keeps the packet and offers it again after the current message ends.
static inline bool arbiter_offer(arbiter_t *a, intptr_t editor, const uint8_t *pkt, size_t len) {
  if (a->owner && a->owner != editor) return false;
  if (len < 4) return true;  // not a framed packet; the pedal ignores it
  long data = pkt[0] < len - 4 ? pkt[0] : (long)len - 4;
  if (pkt[2] == 1 && data >= 2) {
    a->remaining = ((long)(pkt[4] | pkt[5] << 8) + 1) * 4 - data;
  } else if (a->owner == editor) {
    a->remaining -= data;
  } else {
    return true;  // a continuation with no message open: the pedal drops it
  }
  a->owner = a->remaining > 0 ? editor : 0;
  if (!a->owner) a->remaining = 0;
  return true;
}

// The current message's editor went away or stalled: let the others through.
static inline void arbiter_release(arbiter_t *a) {
  a->owner = 0;
  a->remaining = 0;
}
