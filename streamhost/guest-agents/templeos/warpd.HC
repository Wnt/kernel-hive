/* warpd.HC — in-guest absolute-pointer agent for TempleOS (tile `templeos`).
 *
 * TempleOS has NO USB stack (usb-tablet is impossible) and only a PS/2 relative
 * mouse, so the daemon's abs->rel homing bridge cannot track 1:1. This tiny HolyC
 * task gives true absolute positioning instead: it speaks the streamhost warpd
 * M/P/R/B protocol (the same one warpd.rs streams to the Solaris/9front/Win agents)
 * over COM1, and applies it directly to the TempleOS global mouse state.
 *
 * Transport: a QEMU serial chardev backed by a unix socket
 *   -chardev socket,id=ser0,path=.../serial.sock,server=on,wait=off -serial chardev:ser0
 * The daemon (SH_POINTER=warpd, SH_WARPD_ADDR=unix:.../serial.sock) connects as the
 * client and writes bytes straight to the guest's 16550 UART. TempleOS runs ring-0
 * with a single address space, so HolyC can poll the UART registers directly via the
 * InU8/OutU8 primitives — no serial driver, no interrupt handler needed.
 *   COM1 base 0x3F8; LSR = base+5 (0x3FD), bit0 = Data Ready; RBR = base+0 (0x3F8).
 *
 * Protocol lines (newline-terminated, decimal ints; buttons are 1-based from the
 * daemon: 1=left, 2=middle, 3=right):
 *   M x y          move cursor to (x,y)           -> ms.pos.x=x; ms.pos.y=y
 *   P n x y        press button n at (x,y)        -> ms.pos + (n==1?ms.lb:ms.rb)=1
 *   R n x y        release button n at (x,y)      -> ms.pos + (n==1?ms.lb:ms.rb)=0
 *   B n x y        wheel click (ignored here)
 * Setting ms.lb / ms.rb is enough for real clicks: the TempleOS window manager
 * samples those globals and generates the click messages (verified: a synthetic
 * P/R at the top menu bar pulls down the File menu). ms.pos is only overwritten by
 * the PS/2 IRQ handler on real hardware packets — none arrive under SH_POINTER=warpd
 * (the daemon injects no PS/2 motion), so our writes persist.
 *
 * BAKING (TempleOS is ISO/RAM-only — no persistent OS disk): define WS() and
 * Spawn(&WS) at the T:/Home> REPL, then `savevm golden` (the state.qcow2 scratch disk
 * holds the snapshot). The running task is captured in the RAM snapshot, so every
 * `loadvm golden` comes up with WS already polling COM1; it reconnects transparently
 * when the daemon (re)connects to the socket. The whole program fits on one physical
 * line for REPL entry (HolyC ignores newlines); it is written out here for clarity.
 * Numeric char codes (48/57/10/13/32, 77/80/82='M'/'P'/'R') avoid char-literal
 * quoting when the source is typed in via QMP send-key / HMP sendkey.
 */

U0 WS()
{
  U8 c, k = 0;                 // k = current command char (0 = awaiting one)
  I64 a[4], n = 0, v = 0, h = 0;   // a[]=parsed ints, n=count, v=accum, h=have-digit
  while (1) {
    if (InU8(0x3FD) & 1) {           // LSR: Data Ready?
      c = InU8(0x3F8);               // read one byte from RBR
      if (c >= 48 && c <= 57) {      // '0'..'9'
        v = v * 10 + c - 48;
        h = 1;
      } else {
        if (h) {                     // flush a completed integer field
          if (n < 4) a[n] = v;
          n++;
          v = 0;
          h = 0;
        }
        if (c == 10 || c == 13) {    // end of line -> dispatch
          if (k == 77 && n >= 2) {           // 'M' x y
            ms.pos.x = a[0];
            ms.pos.y = a[1];
          } else if (n >= 3) {                // 'P'/'R' n x y
            ms.pos.x = a[1];
            ms.pos.y = a[2];
            if (k == 80) {                    // 'P' press
              if (a[0] == 1) ms.lb = 1;
              else ms.rb = 1;
            } else if (k == 82) {             // 'R' release
              if (a[0] == 1) ms.lb = 0;
              else ms.rb = 0;
            }
          }
          k = 0;
          n = 0;
        } else if (c > 32 && !k) {   // first non-space, non-digit char = command
          k = c;
        }
      }
    } else {
      Sleep(1);                      // idle: ~1 kHz poll, negligible CPU
    }
  }
}
