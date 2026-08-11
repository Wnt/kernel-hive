# Dragon 32 (PAL) — gallery station notes (udp/54130)

Live streamhost **kiosk**: a captured Debian 13 (trixie) X kiosk runs MAME's
`dragon32` driver, and streamhost captures the Linux framebuffer + AC97 audio
exactly as it does for every other station. Reset is `loadvm golden` on an
INTERNAL qcow2 snapshot inside a thin overlay on the frozen shared bridge seed.

| | |
|---|---|
| station dir / UI id | `dragon32` (no alias) |
| VMID label / UDP | 233 / 54130 |
| ssh (host-side) | `127.0.0.1:5833`, key `/data/vms/bridge/bridge_key` |
| guest RAM | 768 MB |
| X root | 1024×768 (bridge seed stock) |
| emulator | MAME 0.289, `SUBTARGET=dragon`, `/opt/dragon32/mame/dragon` |
| builder | `scripts/build-guests/tiles/dragon32.sh` (+ `build-mame-dragon32.sh`) |
| pointer | none — keyboard-only exhibit |

## The trap: `-ext ""` is the exhibit

`mame dragon32` with no slot options does **not** boot Microsoft BASIC. The
driver's `ext` slot defaults to `dragon_fdc`, so the machine comes up in
DragonDOS and paints two lines:

```
DRAGONDOS 1.0
OK
```

That is a disk operating system for hardware this exhibit does not have. With
the slot emptied it paints the screen the machine is remembered for:

```
(C) 1982 DRAGON DATA LTD
16K BASIC INTERPRETER 1.0
(C) 1982 BY MICROSOFT

OK
```

**`-verifyroms` points the wrong way here, and this is the part worth
remembering.** It verifies the DEFAULT slot configuration, so it fails with
`ddos10.rom NOT FOUND (tried in dragon_fdc dragon32)` — it demands the very ROM
that produces the wrong screen, and a romset that satisfies it is a romset that
boots wrong. Measured on labhost 2026-08-09, identically under MAME 0.276 and
the shipped 0.289:

| invocation | result |
|---|---|
| `mame dragon32` | `ddos10.rom NOT FOUND`, machine cannot run |
| `mame dragon32 -ext ""` | the Microsoft BASIC banner, exit 0 |

So the romset is gated on the sha1 of the ROM entries this configuration pins,
read back from the **shipped** binary's own `-listxml dragon32`, and never on
`-verifyroms`. The `-ext ""` lives in the guest's `/etc/bridge/launch.sh`; the
host-side `qemu-streamhost.sh` cannot see it, which is why it carries a comment
saying so.

## Asserting the screen: two tests, neither of which is a histogram

The two candidate screens are the *same two greens* and differ only in how much
text is on them, so a whole-frame pixel histogram is not a discriminator. Every
capture (cold boot, pre-capture, post-restore) must pass both of these.

**1. OCR.**

```
convert <dump>.ppm -colorspace Gray -threshold 40% -negate ocr.png
tesseract ocr.png - --psm 6
```

must contain `MICROSOFT`, `DATA` and `1.0`, and must not contain `DRAGONDOS`.
The first two alone already exclude the DragonDOS screen, which reads
`DRAGONDOS 1.0 / OK`.

The **40 %** is measured, not guessed: the MC6847's page sits at luma 138 in
QEMU's dump and its text at 73 (the border is 42), so 40 % of full scale
separates them; at 50 % the page is swallowed too and tesseract reads nothing at
all. The token list is short for a harder reason — tesseract mangles this blocky
font *differently between MAME builds*. Observed on the same scene: `16K` →
`16E` and `LTD` → `LTO` under 0.251, `BASIC` → `EFASIC`,
`INTERPRETER` → `INTERFRETER` and even `DRAGON` → `DRAGOHW` under 0.289. A gate
resting on a glyph tesseract happens to read today fails a correct exhibit
tomorrow, so only the words that have never moved are required.

**2. Structure**, which no OCR touches: count text-coloured pixels
(RGB 0,124,0) in a 1024×230 band across the top of the frame. The BASIC banner
puts 71 characters in three rows and measures **6376** px (~90 px per
character); DragonDOS puts 13 characters in one row, about 1170. The gate is
3000.

**The digit whitelist is not optional in the keyboard proof.** `PRINT 3*7`
answers `21`, and a free-alphabet OCR of that dump reads it as `el`; the same
dump with `-c tessedit_char_whitelist=0123456789` reads `21`. The proof requires
a line that is *exactly* `21`, because the typed line above it comes back as
`347` (tesseract reads this font's `*` as a `4`) and a substring match would
therefore be no assertion at all.

## Media and license

One 16 KB ROM: `d32.rom`, sha1 `f2dab125673e653995a83bf6b793e3390ec7f65a`,
sha256 `fc0e900bfec6b52f0f80ba1e65a4712808d2a411b5b00496639ef1a2152351f1`. It
holds the machine's monitor and Microsoft 16K Extended Color BASIC 1.0 — the
whole ROM of a Dragon 32.

**MAME re-split it between the two versions this add touched, which is why the
builder assembles by SHA1 and never by filename.** 0.276 declares one 16 KB
`d32.rom`; 0.289 declares the same bits as two 8 KB halves named after their
chips — `dragon_data_ltd_1-0.ic18` (sha1 `9fbba512…`, offset 0) and
`dragon_data_ltd_1-1.ic17` (sha1 `7088d759…`, offset 0x2000). The staged blob
`dd`-splits into exactly those two, verified; a romset built under the older
name loads in neither. Staged at `/data/assets-staging/dragon32/d32.rom`;
row in `docs/lab/ASSETS-MANIFEST.md` and `check-assets.sh`. Preservation source:
Dragon Data Ltd has been gone since 1984 and the BASIC lineage is Microsoft's.
Never committed, never served.

The rest of a merged `dragon32.zip` (the Dragon 64 / 200 / Alpha clone ROMs and
`ddos10.rom`) is deliberately **not** staged — none of it is loaded with the
`ext` slot empty.

## MAME binary provenance

Neither the guest suite's packaged MAME nor labhost's 0.276 is a pin anyone
chose, and a romset is only meaningful against one binary. `build-mame-dragon32.sh`
builds MAME **0.289** (`SUBTARGET=dragon SOURCES=src/mame/trs/dragon.cpp`) in the
**trixie** chroot at commit `f34f02505e32c1993c6a782b6814232cbfc74e36` — the same
commit the mpf2 station ships, so the gallery runs one MAME version across both of
its MAME exhibits rather than two that drift.

Unlike mpf2's, this binary is **pristine upstream**. mpf2 needs
`mame-irix-skip-warnings.patch` because its driver is marked imperfect and MAME
raises a full-screen red "THIS SYSTEM DOESN'T WORK" panel that `-skip_gameinfo`
does not suppress. `dragon32` is `<driver status="good" emulation="good"
savestate="unsupported">`, checked in `-listxml` before the build and never
observed nagging in any captured frame, so no patch is applied. The build
asserts the tree is clean at the pin before compiling, so that claim stays true.

The distro `mame` package is still installed in the overlay, for its SDL2/X11
runtime libraries only; its 0.251 binary is never launched. The builder asserts
`ldd` on the shipped binary reports nothing missing.

## Geometry

The Dragon draws 372×293 at 49.97 Hz (MC6847 PAL, including its overscan
border). MAME runs fullscreen with `-keepaspect -prescale 2 -nofilter -video
soft` on the bridge seed's stock 1024×768 root. 1024×768 is 4:3, so the picture
fills the whole root and the dark surround a visitor sees is the **Dragon's own
border**, not letterboxing. Do not pin `-resolution 372x293`: that is the pixel
count, not the picture's shape, and it strands a small strip in a black root —
the mistake mpf2 made first.

Any change to the launcher or the X geometry invalidates the checkpoint. Recapture it.

## Keyboard

**The Dragon's matrix does not agree with a US PC keyboard**, and untranslated
the disagreement reads as dropped keystrokes rather than as a layout fault.
Derived from the driver's own `PORT_CHAR` pairs with
`scripts/dev/mame-keymap.py` on `src/mame/trs/dragon.cpp` (`INPUT_PORTS
dragon_keyboard`, lines 332–399):

| Dragon character | host key to press | note |
|---|---|---|
| `"` | `@` (Shift+2) | `"` is Shift+2 on a Dragon |
| `&` | `^` (Shift+6) | shifted number row is offset from 6 upward |
| `'` | `&` (Shift+7) | |
| `(` | `*` (Shift+8) | |
| `)` | `(` (Shift+9) | |
| `:` | `-` | `:`/`*` share the key a PC labels `-` |
| `*` | `_` (Shift+-) | |
| `+` | `:` (Shift+;) | `;`/`+` share the `;` key |
| `-` | `=` | `-`/`=` share the `=` key |
| `=` | `+` (Shift+=) | |
| `@` | `[` | |

Letters are **unshifted capitals** (`keyboard.letterCase: "upper-only"` in the
registry): Shift+letter is the Dragon's lower case, which the MC6847 can only
render as inverse video. The map is declared once in the registry entry's
`keyboard.charMap`; `SH_KEY_MAP` in `station.env.fixture` is the same map joined,
because labctl drives QMP directly and cannot read the registry.

Two encoding details that bit during the add:

- **`:` has no literal spelling in the wire format.** `SH_KEY_MAP` is
  `guest:host` pairs joined by commas, so the Dragon's `:`-on-the-`-`-key pair
  would render as `::-`, and `labctl`'s `split(":", 1)` returns an empty guest
  and **silently drops it** — one missing character, not an error. `%`, `,` and
  `:` are therefore percent-encoded (`keymap_escape` in
  `scripts/stations-registry.py`, `keymap_unescape` in `scripts/labctl`), so the
  shipped value reads `…,%3A:-,*:_,+:%3A,…`. The KC 85/4 add hit the same wall
  from the German side in the same wave; this station adopts that mechanism rather
  than inventing a second one.
- **`SH_KEY_MAP` must not *begin* with a quote** — systemd's `EnvironmentFile`
  parser would read the value as a quoted string. `@:[` therefore leads the map.
  Verified with `systemd-run -p EnvironmentFile=…` that the whole value, `"`
  included, survives intact, and again against `/proc/<MainPID>/environ` on the
  live station.

## Keyboard pacing

49.97 Hz → a 20.01 ms frame, so the frame-derived two-frame floor is 40/40. The
floor is not the answer: the residual loss labhost shows is a **host
scheduling** stall rather than frame quantisation, and it does not scale with
the frame period (the vic20 add established this the hard way).

Bisected on a namespaced clone of this station with
`scripts/dev/emu-key-pacing-bisect.py`, 10 trials of a 40-character line at each
pacing, 2026-08-09 — **under heavy contention** (labhost load average ~75, a MAME
compile and several sibling station builds in flight), which makes the numbers a
conservative worst case rather than a quiet-labhost best case:

| hold / gap | lines corrupted (of 10, 40 chars each) |
|---|---|
| 0 / 0 | **10 / 10** — the negative control (see below) |
| 32 / 32 | 10 / 10 |
| 40 / 40 (the two-frame floor) | 9 / 10 |
| **80 / 80** | **0 / 10** |

**Run the negative control, every time.** The first pass of this bisect
reported 0/10 corrupted at *0 ms* pacing, which is impossible — and the reason
was not the instrument. The clone's X server had been started from an ssh
session rather than from tty1, so it owned vt1's *scanout* but not its
*keyboard*: the captured framebuffer showed a flawless exhibit while every
keystroke was discarded before it reached MAME, and a comparison of "before"
against "after" therefore matched perfectly. A frame compare that never reports
a mismatch is indistinguishable from a machine that never drops a key. The
`PACE_PAIRS` environment variable added to
`scripts/dev/emu-key-pacing-bisect.py` during this add exists so a 0:0 row can
always be included; it is what caught this.

Two other things moved the numbers, and both are worth knowing:

- **The shipped binary is much cheaper than Debian's.** Measured in the kiosk on
  the same frame, MAME 0.251 from the distro burns ~110 % of a vCPU and 322 MB
  RSS; the pinned 0.289 `SUBTARGET=dragon` build burns ~48 % and 170 MB. Under
  0.251 even 80/80 lost characters in 7 lines of 10. Key loss on this station is a
  CPU-starvation symptom, so making the emulator cheaper is a real fix and not
  only a tidiness one.
- **`-prescale 2` is load-bearing, not cosmetic.** Removing it (i.e. MAME's
  default prescale of 1) leaves MAME running and drawing while the captured X
  root goes entirely BLACK. It stays.

Shipped: `SH_KEY_MIN_HOLD_MS=80`, `SH_KEY_MIN_GAP_MS=80`, matching
vic20/plus4/c128. The registry declares `demoProgram.perCharMs: 170`, above the
160 ms drain rate those two knobs impose; `validate_demo_pacing` in
`scripts/stations-registry.py` fails the build if they ever disagree.

## Checkpoint scene

`resetMode: loadvm`, snapshot `golden`, inside `overlay.qcow2`. It holds X
(`-nocursor`) plus MAME at the Dragon's **untouched power-on screen**. The
picture fills the root: the frame the MC6847 draws is 372×293 *including* its
overscan border, so at this scale the 256×192 text page is about 700×505 and
everything around it is the machine's own border colour, not letterbox black. Nothing
is curated and nothing is typed before the capture, and there are no post-restore
keys.

That is deliberate and it is the Plus/4's lesson applied before it could be
repeated: a checkpoint captured inside an application was rejected on the exhibit floor
because a visitor arrived in the middle of something with no idea what it was or
how to leave. Affordances belong in the UI's on-screen keyboard around an
honest idle screen — here, a BREAK and a CLEAR button and a type-in listing.

The keyboard proof runs **after** the capture, against the restored scene, so
nothing it types can reach the checkpoint: it sends `PRINT 3*7` and requires `21`
on the screen. That also proves the shifted matrix, since `*` is Shift+the key a
PC labels `-`; an assertion on "the framebuffer changed" would have passed with
every shifted key wrong.

## Verification (2026-08-09)

All on labhost, MAME 0.289, station `dragon32`, in the order the builder runs them.
Framebuffer dumps are in `/data/vms/streamhost/stations/dragon32/evidence/`.

| check | result |
|---|---|
| romset gated against the shipped binary | `dragon_data_ltd_1-0.ic18` + `dragon_data_ltd_1-1.ic17` sha1-matched to the driver's own `-listxml` |
| `-verifyroms dragon32` | `romset dragon32 is bad` — `ddos10.rom NOT FOUND`. Recorded, **not** used as a gate |
| cold boot → banner | `evidence/ready-before-golden.png`, OCR + banner-ink verified |
| `savevm golden` | snapshot present in `overlay.qcow2` |
| `loadvm golden` → banner | `evidence/golden-restored.png`, identical scene |
| keyboard, after the capture | `PRINT 3*7` → `21` (`evidence/keyboard-print-3x7.png`) |
| restore after the keyboard proof | `evidence/golden-restored-after-keyboard.png` |
| service | `streamhost@dragon32` active; `LISTENING udp/54130 tile=dragon32 audio=true`; first frame 1024x768 |
| pacing env reached the daemon | `SH_KEY_MIN_HOLD_MS=80`, `SH_KEY_MIN_GAP_MS=80`, `SH_KEY_MAP=@:[,":@,…` all present in `/proc/<MainPID>/environ` |
| daemon binary implements the knob | `/usr/local/lib/streamhost/stations/dragon32/current` → `streamhost-bca88a2…`, the same pacing build vic20/plus4/c128 run |
| memory | host QEMU RSS 740 MB (of `-m 768`), streamhost RSS 76 MB, guest `MemAvailable` 407 MB of 725 MB, MAME RSS 183 MB |

## Cold boot and rollback

Cold boot reaches the same screen the checkpoint holds, so a boot clip would hand
off cleanly; `scripts/coldboot/dragon32-zero-input-prep.md` and the `dragon32)`
arm in `bootrec-tiles.conf` record the audit. No clip is published and
`spa.bootVideo` is unset.

Rollback: the overlay is a thin file on the frozen shared base and the checkpoint
lives inside it. To rebuild from scratch, stop `streamhost@dragon32`, run
`scripts/build-guests/tiles/dragon32.sh --force` (which stops only this station, replaces
the overlay and recaptures), then re-emit. Nothing outside
`/data/vms/streamhost/stations/dragon32/` and `/data/assets-staging/dragon32/` is
touched.
