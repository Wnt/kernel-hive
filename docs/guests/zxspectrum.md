# zxspectrum — Sinclair ZX Spectrum 48K (1982)

**Status: LIVE production streamhost tile** (slot 127, UDP 54127, VMID 230,
bridge SSH 5830). Emulator-in-captured-Linux **bridge** tile in the family of
c64 / apple2 / atarist / amiga / mpf2 / vic20 / plus4 — see
[`streamhost/docs/BRIDGE.md`](../../streamhost/docs/BRIDGE.md).

Builder: [`scripts/build-guests/tiles/zxspectrum.sh`](../../scripts/build-guests/zxspectrum.sh)
(`--force` rebuilds the overlay from scratch; the whole thing is automated).

## What the exhibit is

A captured Debian 12 kiosk running **Debian's own MAME 0.251** (`spectrum`
driver, `-bios en`) emulating a 48K ZX Spectrum. streamhost captures the Linux
framebuffer and the AC97 audio, exactly like every other bridge tile. The tile
rests on the machine's untouched power-on screen: the whole raster in the
Spectrum's non-bright white, with `© 1982 Sinclair Research Ltd` in black along
the bottom, and no cursor until a key is pressed.

| | |
|---|---|
| Machine | Zilog Z80A @ 3.5 MHz, 48 KB RAM, 16 KB ROM, Ferranti ULA |
| Raster | 352×296 including border, 50.080128 Hz (MAME `-listxml spectrum`) |
| Sound | 1-bit beeper → ALSA → AC97 → streamhost |
| Input | keyboard only; **no pointing device was ever made for this machine** |
| Reset | `loadvm` of the internal `golden` snapshot |

## Media, and why it may be fetched

| Artifact | Pin |
|---|---|
| `spectrum-roms_20081224-5_all.deb` | sha256 `8d25dd300a0c86b4459e152de3bc657dca894b167e6a6419eb195d9669bfe950`, 202 748 B, from `deb.debian.org/debian/pool/non-free/s/spectrum-roms/` |
| `48.rom` extracted from it | sha1 `5ea7c2b824672e914525d1d5c419d71b84a426a2`, sha256 `d55daa439b673b0e3f5897f99ac37ecb45f974d1862b4dadb85dec34af99cb42`, 16 384 B |
| MAME | `mame 0.251+dfsg.1-1`, installed with apt inside the guest |

`usr/share/doc/spectrum-roms/copyright` inside that package quotes Cliff Lawson
of Amstrad plc's 1999 posting verbatim: *"Amstrad are happy for emulator writers
to include images of our copyrighted code as long as the (c)opyright messages
are not altered"*, with the conditions that nobody charges for the ROM code and
that it is used with an emulator rather than real hardware. This exhibit
satisfies both, and honours the first one visibly: the idle screen **is** the
unaltered copyright message. Licence class **freely-fetchable-pinned**;
`48.rom` is byte-identical to MAME's `spectrum.rom`. **The bits are never
committed** — only the URL and the hashes, in
[`docs/lab/ASSETS-MANIFEST.md`](../lab/ASSETS-MANIFEST.md) and
[`check-assets.sh`](../../scripts/build-guests/check-assets.sh).

## Traps this add paid for

### 1. `-verifyroms` says the romset is bad, and it is lying

```
$ mame -rompath /opt/zxspectrum/roms -verifyroms spectrum
spectrum    : 48e.rom (16384 bytes) - NOT FOUND
… 30 more …
romset spectrum is bad
```

The `spectrum` driver declares **thirty-one alternative BIOS entries** —
Spanish, prototype, DiagROM, BusySoft, GOSH Wonderful and so on — and
`-verifyroms` demands every one. The tile pins exactly one (`-bios en`), so the
gate in the builder is the **sha1 of that entry, read out of `mame -listxml
spectrum` from the binary being shipped**. A MAME upgrade that renames or
re-hashes the ROM fails the build instead of passing quietly.

### 2. Keyword entry: the exhibit, and the reason a naive type-in is garbage

At the start of a BASIC line the cursor is in **K mode**, where one keypress
enters an entire token. Typing `p`,`r`,`i`,`n`,`t` gives `PRINT RINT`, not
`PRINT`. The registry `demoProgram` is therefore written as the **keystrokes a
person actually presses**, which is why its lines look like `10 b1` — that
produces `10 BORDER 1` on the screen. Proven by framebuffer: `10 b2` typed
through QMP renders `10 BORDER 2`.

### 3. The 40-key matrix has no punctuation at all

Every symbol on a Spectrum is SYMBOL SHIFT plus a letter or digit (`"` is
SYMBOL SHIFT + P, `;` is + O, `=` is + L …), every editing key is CAPS SHIFT
plus a digit, and the cursor arrows live on 5/6/7/8. MAME maps CAPS SHIFT to
host **left** shift and SYMBOL SHIFT to host **right** shift, while the SPA's
`typeText()` only ever sends US scancodes with left shift. So no type-in can
ever produce a quote on this machine. The affordance is the SPA's `zxspectrum`
keyboard profile
([`spa/src/ui/keyboard/keyboardProfiles.ts`](../../spa/src/ui/keyboard/keyboardProfiles.ts)),
which carries both shifts as latches plus the symbol chords, EXTENDED MODE
(both shifts at once) and the four real cursor keys.

**MAME's `-natural` was measured as the alternative and rejected.** It does
synthesise the SYMBOL SHIFT chords — `10 p"hello"` came out as
`10 PRINT "helo"` — but it merges repeated characters: the doubled `l`
disappeared at 150/150 ms pacing and only survived at 250/250. A silently
missing letter is a worse exhibit than a missing quote, and the on-screen
keyboard solves the quote properly.

### 4. A kiosk MAME can be born DEAF, and a golden can capture it

The first golden of this tile was pixel-perfect and completely unusable: after
`loadvm`, the emulated machine ignored every key. What was measured:

- `xev -id <MAME's window>` **received** the KeyPress/KeyRelease pairs, X's
  input focus was MAME's window, and the guest's `i8042` interrupt count in
  `/proc/interrupts` rose by exactly two per key — so QEMU, the guest kernel and
  X were all fine;
- MAME ignored its own UI too (`scroll_lock` + `Tab` produced no menu), while
  burning 143% CPU;
- restarting the kiosk (`systemctl restart getty@tty1`) cured it instantly —
  `10 b2` then rendered `10 BORDER 2`;
- `savevm`/`loadvm` is **not** the cause and **not** a cure: an instance proved
  live before `savevm` was still live after `loadvm` (typing `0` appended to
  `10 BORDER 2` → `10 BORDER 20`), and a deaf one stayed deaf across the same
  round trip.

It is a start-up race in the SDL/X focus handshake and it appears in no log. The
builder therefore gates the bake on a **behavioural** predicate, not a pixel
one: type, require the frame to move, then MAME-soft-reset back to a
**byte-identical** power-on screen and only then `savevm`. The soft reset is
`scroll_lock, F3, scroll_lock` (MAME disables UI keys while emulating a full
keyboard, hence the toggle sandwich); on this machine the ROM re-enters at
0x0000 and runs NEW, so the frame afterwards hashes identically to a cold boot —
unlike mpf2, where F3 is warm enough that the Apple-family ROM skips its banner.
After the bake the builder types into the **restored** fixture as well, because
"restores a picture" and "restores a machine you can type on" are different
claims and this tile has already failed the second one once.

### 5. Key pacing: 200/200, not the frame-derived 40/40

The frame period is 19.97 ms, so the playbook's two-frame floor would be 40/40.
Both of the following push it far higher, measured 2026-08-09:

- **MAME does not reach real time in this guest.** `-video none -sound none
  -str 10` reported **91.7%** with nothing else running, **68.9%** with the
  kiosk also up, and only 148% unthrottled. Wall milliseconds buy fewer emulated
  frames than the arithmetic assumes, and the shortfall tracks host load (the
  box was at load 77 on 16 cores during these runs).
- **Repeated characters are the worst case**, and Spectrum listings are full of
  them. The ROM's LAST-K debounce only accepts the same key twice if it sees a
  "no key pressed" scan in between, so the *release* has to survive a frame.
  Typing `1122334455` with explicit QMP press/release pairs:

  | hold/gap | of 10 characters |
  |---|---|
  | 80/80 | 2 of the 5 doubles collapsed |
  | 120/120 | 7 |
  | 160/160 | 8 |
  | 200/200 | 9–10 |
  | 250/250 | 10, repeatedly |

  A non-repeating 20-character line lost 1 character at 80/80 and none at
  200/200.

Re-measured properly on a **soltest clone of this tile's own golden** with
[`scripts/dev/emu-key-pacing-bisect.py`](../../scripts/dev/emu-key-pacing-bisect.py)
(this add added its `PACE_GRID` and `PACE_SETTLE_S` knobs, and fixed its
relative-`out_dir` bug — `screendump` runs in QEMU's cwd, not the harness's).
Line: `1122334455667788 abcdefghijklmnopqrstuvw`, eight doubled digits and
twenty-three distinct letters, three trials per pacing, box at load ~40–55:

| hold/gap | corrupted lines | what was lost |
|---|---|---|
| 80/80 | 3 of 3 | 7 of the 8 doubles collapsed; **all 23 letters landed** |
| 120/120 | 3 of 3 | |
| 200/200 | 1 of 3 | one doubled digit |
| 250/250 | 2 of 3 | one doubled digit |

**The curve flattens after ~200 ms and never reaches zero.** The residual loss
is a host-scheduling stall, not frame quantisation, so another 100 ms per key
buys nothing measurable and makes every type-in half as fast again. Hence
200/200 — and the registry `demoProgram` is written with **no repeated
character in any line**, so the exhibit's own listing never depends on the one
case that can still drop a keystroke.

Shipped: `SH_KEY_MIN_HOLD_MS=200`, `SH_KEY_MIN_GAP_MS=200`, and
`demoProgram.perCharMs=400` to match (`validate_demo_pacing` enforces the
relation).

### 6. Cold boot can take three minutes under load

On the first boot of a fresh overlay, `xinit` sat in *"waiting for X server to
begin accepting connections"* for about three minutes before the kiosk appeared.
The readiness predicate polls for 180 s and the builder tolerates it; do not
mistake it for a dead tile.

## Verification

Framebuffer evidence lives in `/data/vms/streamhost/tiles/zxspectrum/evidence/`:
`pristine-attempt1.png` (cold boot), `keyboard-keyword-border.png` (one keypress
→ `BORDER`), `ready-before-golden.png` (byte-identical pristine screen that was
baked), `golden-restored.png`, `keyboard-after-restore.png`, and
`golden-restored-after-keyboard.png`.

```bash
ssh lab 'labctl shot zxspectrum /tmp/zxspectrum.png'
ssh lab 'labctl exec zxspectrum "free -m; pgrep -a mame"'
curl -ksS -X POST https://192.0.2.10:8443/restore/zxspectrum
```

Guest memory with the kiosk up: **~320 MB MemAvailable of 708 MB** — the tile
runs on `-m 768`, the smallest of any bridge tile.

## Rollback

The golden lives *inside* `overlay.qcow2`; never delete or recreate that file by
hand. To rebuild from the frozen base:
`ssh lab 'systemctl stop streamhost@zxspectrum && bash /path/to/zxspectrum.sh --force'`.
Any change to the launcher, to the X geometry or to the MAME argv invalidates
the golden and requires a re-bake.
