# nextstep guest-daemon angle — PAUSED partial (2026-08-09)

Branch: agent/nextstep-guest-daemon

## Verdict so far: BLOCKED on toolchain (mechanism is sound)

### THE TOOLCHAIN ANSWER (the load-bearing finding)
There is **NO usable in-guest compiler** on the shipped NeXTSTEP 3.3 golden, and
no interpreter either. Evidence, from loop-mounting the guest's own disk image
(`/opt/bridge/media/nextstep/NS33_2GB.dd`, copied to the clone, mounted
`ufstype=nextstep` at byte offset 163840 — the NeXT `dlV3` disklabel's `a`
partition):
  * full-disk `find` for cc/gcc/cc1/cc1obj/as/ld/cpp/ranlib -> **nothing**.
  * `NextDeveloper/` contains only `Demos` (no `bin`, no Developer.pkg).
  * `/usr/include` **does not exist**; total `*.h` on the whole disk = 21, all
    TeX/doc noise. No SDK headers, no dpsclient/wraps, no bsd/dev.
  * no perl/tcl/python (only a `python.tiff` dictionary image).
So a compiled artifact CANNOT be produced in-guest from this golden. This also
sinks native-tablet's plan to write an in-guest pointing-device driver: same
missing toolchain. Any in-guest binary on this tile requires EITHER installing
the NeXTSTEP 3.3 Developer package into the golden (external media + full
re-bake) OR a cross `m68k-next-nextstep3` gcc PLUS the NeXTSTEP SDK
(headers + pswrap + crt/link stubs), none of which are on the golden.

### The cursor API DOES exist (so the angle is technically sound, just unbuildable here)
`strings` on the shipped `/usr/shlib/libNeXT_s.C.shlib` shows `_PSsetmouse`,
the DPS `setmouse` operator, and `__NXSetMouse`; `libsys_s.B.shlib` has
`_NXEventSystemInfo`; `/usr/lib/NextStep/WindowServer` is present. `setmouse`
places the cursor at an absolute SCREEN coordinate and bypasses the acceleration
curve (which only transforms relative hardware deltas) — exactly the warpd
pattern. A ~40-line DPS client calling `PSsetmouse(x,y)` would be the daemon.
NOT PROVEN to move the cursor (no way to run code in-guest yet).

### Host->guest channel: EXISTS, no emulator patch needed
Previous's SLIRP publishes fixed inbound redirs (src/enet_slirp.c):
kiosk 42320-3 -> NeXT 20/21/22/23, 42380 -> 80. FTP into NeXTSTEP works:
banner "previous FTP server (Version 5.1 (NeXT 1.0) ... 1994)". Telnet (42323)
reaches `login:`. **Both `root` and `me` have EMPTY passwords** (from the
mounted `/etc/passwd`: `root::0:1`, `me::20:20`). FTP refuses empty-password
logins (530) and root is in `/etc/ftpusers`; telnet login handshake was not yet
completed (guest slow / line-ending negotiation — the shell echo never came back
after sending the username). Closing this is the next concrete step. Once a
shell is in hand, a hostfwd `127.0.0.1:15939 -> guest :7777` (already in the
clone launcher) is the natural daemon channel, reusing SH_INPUT_BACKEND=warpd.

### Locator (validated instrument)
`nsctl.py` template-matches the 7x7 NeXT arrow. NeXTSTEP draws submenu arrows
with the IDENTICAL glyph (9 perfect matches on the golden frame), so the locator
subtracts a cursor-free reference frame (`decoys.json`) and REQUIRES a unique
survivor — an ambiguous frame raises, never guesses. Confirmed cursor at
(297,149) on the golden.

## NEXT STEP IF RESUMED
Decide the toolchain route (Developer.pkg into golden vs cross+SDK). Until one
exists, criterion 4 (compiled artifact) cannot be met and the 24-target sweep
cannot be run through a real daemon. Cheapest proof-of-mechanism: install
Developer, compile a PSsetmouse client, run it from a telnet shell, screendump.
