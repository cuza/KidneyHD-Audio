// make unit: checks that the daemon keeps each editor's messages whole.
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../daemon/arbiter.h"

// The packets of a message of `bytes` bytes (a multiple of 4), 60 data bytes per packet.
static int packets(int bytes, uint8_t out[][64], int *lens) {
  int n = 0;
  for (int off = 0; off < bytes; off += 60, n++) {
    int len = bytes - off < 60 ? bytes - off : 60;
    memset(out[n], 0, 64);
    out[n][0] = (uint8_t)len;
    out[n][2] = off == 0 ? 1 : 4;
    if (off == 0) { out[n][4] = (uint8_t)(bytes / 4 - 1); out[n][5] = (uint8_t)((bytes / 4 - 1) >> 8); }
    lens[n] = len + 4;
  }
  return n;
}

int main(void) {
  arbiter_t a = {0};
  uint8_t preset[69][64], query[1][64];
  int plen[69], qlen[1];
  int np = packets(4108, preset, plen);   // a preset write
  int nq = packets(12, query, qlen);      // a one-packet query
  assert(np == 69 && nq == 1);

  // A one-packet message leaves nothing open.
  assert(arbiter_offer(&a, 2, query[0], qlen[0]) && a.owner == 0);

  // Editor 1 starts a preset; editor 2 waits until its last packet.
  assert(arbiter_offer(&a, 1, preset[0], plen[0]) && a.owner == 1);
  for (int i = 1; i < np; i++) {
    assert(!arbiter_offer(&a, 2, query[0], qlen[0]));
    assert(arbiter_offer(&a, 1, preset[i], plen[i]));
  }
  assert(a.owner == 0 && a.remaining == 0);
  assert(arbiter_offer(&a, 2, query[0], qlen[0]));

  // An editor that leaves mid-message is released, and the others go on.
  assert(arbiter_offer(&a, 1, preset[0], plen[0]) && a.owner == 1);
  assert(!arbiter_offer(&a, 2, query[0], qlen[0]));
  arbiter_release(&a);
  assert(arbiter_offer(&a, 2, query[0], qlen[0]) && a.owner == 0);

  // A stray continuation with no message open passes and opens nothing.
  assert(arbiter_offer(&a, 3, preset[5], plen[5]) && a.owner == 0);

  puts("arbiter: all checks passed");
  return 0;
}
