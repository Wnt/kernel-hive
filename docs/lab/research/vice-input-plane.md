# The VICE input plane — how a headless host-native VICE takes keys

Research spike for the de-bridging campaign's VICE wave
([`DEBRIDGE-CONVERSION-BRIEF.md`](../DEBRIDGE-CONVERSION-BRIEF.md) §3 lists the
nine MAME kiosks; the seven VICE stations — `c64`, `c128`, `vic20`, `plus4`,
`pet2001`, `cbm8032`, `cbm2` — are the wave after). It answers one question:
**with no X server and no XTEST, how does the streamhost daemon put a keystroke
into a host-native VICE?**

Rig: `/data/vms/soltest/vice-in/` on labhost, tag `vice-in`. Fork commits live
in `/data/vms/soltest/vice-in/vice-src` on branch `kernel-hive-vicectl`, off the
VICE-Team `svn-mirror` `main` (3.10-dev, `223e31a`). No live station was
touched.

---

## 0. The verdict, in one paragraph

**Patch a `vicectl` control socket into VICE (option b), and make its key verb
carry an X11 KEYSYM, not a matrix cell and not a scancode.** VICE already
resolves keysym → matrix through the machine's own `.vkm` keymap — the very
file the bridged kiosk used — so a de-bridged station reproduces the kiosk's
character behaviour *by construction*, including virtual shift, deshift,
shift-lock and the C128 alternative set. The daemon supplies one host-layout
table (`scancode` + shift level → keysym) shared by all seven stations; it needs
no per-station matrix map at all. VICE's existing binary remote monitor
(option a) cannot do this job: its only keyboard facility is
`kbdbuf_feed()`, a PETSCII text poke into the KERNAL buffer with no key-down
/key-up, no held keys and no effect on anything that scans the matrix itself —
which includes the `c64` station's GEOS deskTop.

Proven on the framebuffer, headless, no X, no XTEST: `10 PRINT "HELLO KERNEL
HIVE"` followed by `run`, typed through the socket as ONE burst, screenshot
taken by the module's own `SHOT` verb, `HELLO KERNEL HIVE` on the C64 screen.
The PNGs are rig artefacts (§7), not repo files — `lab:/tmp/vice-in-final.png`.

---

## 1. How VICE takes a key, in source

`src/keyboard.c`, `src/keymap.c`. Four levels, outermost first:

| Level | Entry point | What it does |
|---|---|---|
| host key | `keyboard_key_pressed(sym, mod)` | looks `sym` up in `keyconvmap` (the parsed `.vkm`), applies shift/CBM/CTRL logic, pushes onto an **8-deep** `kbd_queue` drained by a CPU alarm at a randomised ~1-frame cadence |
| matrix + modifiers | `keyboard_key_matrix_pressed(row, col, shift, pressed)` | static; the virtual-modifier bookkeeping |
| matrix latch | `keyboard_set_keyarr(row, col, val)` / `_any()` | sets one latch bit and latches immediately; no keymap, no queue |
| the matrix | `keyarr[16]` / `rev_keyarr[8]` | read by the CIA/PIA emulation |

Two facts shape everything downstream:

- **`kbd_queue` is 8 entries and DROPS when full** (`kbd_queue_pushkey`
  returns 0 and only retriggers the alarm). A browser delivers a typed line as
  one burst — 30-odd edges — so anything feeding `keyboard_key_pressed` without
  its own pacing loses keys. This is the same failure the MAME campaign hit from
  the other side.
- **`keyconvmap` is per machine and per machine *variant***, and is parsed at
  runtime from a data file, not compiled in.

The `.vkm` format (`data/C64/gtk3_sym.vkm` and friends) is
`keysym-name row column shiftflags`, plus `!LSHIFT/!RSHIFT/!LCBM/!LCTRL/!VSHIFT`
anchors. Symbolic maps (`*_sym.vkm`, the default `KeymapIndex 0`) key on what
the host character *means*; positional maps (`*_pos.vkm`) on where the key
*sits*.

**The headless build has none of this.** `keymap_resources_init()` returns 0
immediately under `USE_HEADLESSUI`, `kbd_arch_keyname_to_keynum()` returns -1,
`KBD_PORT_PREFIX` is `"headless"` and no `headless_*.vkm` exists — and
`data/*/Makefile.am` installs no keymap at all for a headless build. A stock
`--enable-headlessui` VICE has an empty `keyconvmap` and cannot resolve any key.

---

## 2. The options, and what each costs a fast-typing visitor

### (a) The binary remote monitor — **rejected**

`-binarymonitor` (`src/monitor/monitor_binary.c`). The whole keyboard surface is
one command, `MON_CMD_KEYBOARD_FEED = 0x72`, and it is three lines long: it
calls `kbdbuf_feed()`, which queues PETSCII text into the KERNAL keyboard buffer
at `$0277`.

- No key-down/key-up. No held key, no chord, no RUN/STOP+RESTORE, no F-keys as
  edges, no joystick-ish holds. The exhibits' `typeDemoProgram` pacing model has
  nothing to attach to.
- **It bypasses the hardware entirely.** Anything that scans the matrix instead
  of calling the KERNAL sees nothing — that is most games and demos, and it is
  the `c64` station's GEOS 2.0 deskTop, whose fixture is the whole exhibit.
- Under a fast burst it is actually the *best* behaved of the three (the buffer
  drains at KERNAL pace), but it is answering a different question.
- Cost of adoption is also non-trivial: a TCP binary framing protocol, and the
  monitor can stop the CPU.

Keep it in mind for exactly one thing: a fast, lossless *autotype* for baking a
checkpoint. Not for visitors.

### (b) A patched-in control socket, ctlsock-style — **recommended**

What this spike built. Details in §3. Costs under a burst: the module holds the
whole burst in its own unbounded queue and releases it at a rate the guest can
actually absorb, acking each edge, so nothing is dropped and the daemon's ack
liveness stays meaningful. Measured on x64sc: a 14-character line
(28 edges) lands in **1.64 s**; a 33-character two-line burst (66 edges) in
**3.91 s**, zero errors, zero coalesced. That is ~8.5 keys/s, which is the
guest's own ceiling (§4), not the transport's.

### (c) Matrix-level injection only (`keyboard_set_keyarr`, `MKEY`) — **kept as an escape hatch, rejected as the main path**

Technically the simplest verb, and it is what MAME's ctlsock does (`KEY <0|1>
<port> <field>` sets an ioport field). But for VICE it throws away the machine's
`.vkm`, and with it the *symbolic* mapping that the seven live stations were
calibrated under. The evidence that this matters is in the repo already:
`spa/src/data/keyboards.ts` gives `bbcmicro`, `armeval`, `dragon32`, `kc854`,
`mpf2` hand-written `charMap`s — and gives the VICE stations **none**, because
VICE's symbolic keymap already did that translation inside the emulator. Going
positional would mean authoring seven new charMaps by hand, which is precisely
the "hand-guessed keymap" failure the MAME Phase 0 work existed to end.

Retained as the `MKEY` verb for what no keymap names: RESTORE (`KBD_ROW_RESTORE
_1`, a negative row), the C128 40/80 and CAPS switches, and the joyport keypad.

### (d) Feed the keysym, let VICE map it — **the recommendation, and it is (b)'s KEY verb**

`keyboard_key_pressed(sym, mod)` with an X11 keysym. Requires teaching the
headless build to load a keymap at all (§3.2), which is a contained patch, and
buys exact behavioural parity with the kiosk being replaced.

**The host layout must be applied BEFORE the wire, and this is not a detail.**
Measured, on the C64, in one screenshot: sending keysym `at` (0x40) produced
`@`; sending `Shift_L` held plus keysym `2` produced `"`. The bridged station
today produces `@` for the visitor's Shift+2, because X applied the US layout
before VICE saw it. So the daemon's map is
`scancode → (plain keysym, shifted keysym)` and it *substitutes*, rather than
forwarding, the shift level for character keys. One table, US layout, shared by
all seven stations; `Shift_L` still goes on the wire as itself so that `.vkm`
entries flagged `MAP_MOD_SHIFT` keep working.

---

## 3. What was built

Branch `kernel-hive-vicectl`, two commits, in
`/data/vms/soltest/vice-in/vice-src`.

### 3.1 `vicectl` — `src/vicectl.c`, `src/vicectl.h` (commit 1)

Deliberately the same shape as our MAME fork's
`src/osd/modules/ctlsock/ctlsock.cpp`, so the daemon side is the same state
machine:

```
request  <seq> VERB args
reply    <seq> OK [detail] | <seq> ERR <code> <text> | <seq> DATA <text>
banner   vicectl/1 machine=C64SC rows=16 cols=8 keys=129
```

| Verb | Meaning |
|---|---|
| `KEY <0|1> <keysym>` | host-key edge; `keyboard_key_pressed/_released`, paced |
| `MKEY <0|1> <row> <col>` | raw matrix bit; `keyboard_set_keyarr_any`, paced on the same queue |
| `KEYCLEAR` | `keyboard_key_clear()` + drop all pacing state (reconnect resync) |
| `KEYDUMP` | the machine's own keymap, anchors and geometry (§5) |
| `SHOT <path>` | `screenshot_save("PNG", …)` — the framebuffer, from inside |
| `RESET <0|1>` | CPU reset / power cycle |
| `SAVEST` / `LOADST` | `machine_write_snapshot` / `machine_read_snapshot` |
| `STAT`, `PING`, `EXIT` | counters, liveness, orderly exit |

**Threading** follows the inherited one rule: the socket thread parses and
enqueues, the emulation thread applies. The emulation-thread drain is
`vicectl_frame()`, called once per emulated frame from `vsync_do_vsync()`.
Unlike the MAME port there is no sub-frame timer and none is wanted: every CBM
machine scans its matrix from a raster IRQ, so an edge landing mid-frame is
indistinguishable from one landing at the frame boundary.

**No savestate covenant.** The MAME module had to allocate exactly one
persistent timer with a frozen name because MAME's savestate signature is a CRC
over registered entries. VICE snapshots are explicit, per-module, versioned
blocks; `vicectl` writes none, so it changes no snapshot format and no golden
needs rebaking on its account. This is a real simplification over the MAME wave
and should be stated in the conversion runbook.

**Env, all optional but the gate:**

| Var | Default | Meaning |
|---|---|---|
| `VICE_CTL_SOCK` | unset | listener path; **unset ⇒ this file does nothing at all** |
| `VICE_CTL_KEY_HOLD` | 60 ms | press → its own release dwell |
| `VICE_CTL_KEY_GAP` | 60 ms | release → its own re-press dwell |
| `VICE_CTL_KEY_EXCL` | 0 | 1 ⇒ serialize non-modifier presses (**set it**, §4) |
| `VICE_CTL_TRACE` | 0 | one stderr line per applied edge |

Pacing is enforced in *frames* (the dwell converted via
`machine_get_cycles_per_second/_per_frame`), per key, never globally — the
global-slot design is the ~6 keys/s ceiling the MAME campaign had to remove.
Redundant edges coalesce against the *queued* state, because browser auto-repeat
resends keydown with no keyup and the KERNAL does its own repeat from the held
matrix bit.

### 3.2 Headless gets a keymap (commit 2)

- **`KBD_KEYMAP_PREFIX`** (new, one line per arch header): which shipped `.vkm`
  family a build's keysym numbers match. `gtk3` and `sdl` name their own;
  headless has no keysyms of its own and borrows X11's — which *is* the gtk3
  numbering — so it reads `data/*/gtk3_*.vkm` unchanged. `KBD_PORT_PREFIX` is
  left alone, so joymap filenames do not move.
- **`src/arch/headless/x11keysyms.h`**, generated by the committed
  `x11keysyms.sh` from `/usr/include/X11/keysymdef.h` (2 110 names). Mechanical,
  never hand-edited — the same rule as `gdkkeysyms.sh` next door. No X11 headers
  or libraries are needed at build or run time; the table is baked in.
- **`keymap.c`** now compiles its subsystem in every build; only the runtime
  bring-up stays conditional, and under `USE_HEADLESSUI` that condition is
  `vicectl_enabled()`.
- **`data/*/Makefile.am`** install the gtk3 keymaps in a headless build too
  (C64, C128, C64DTV, CBM-II, PET, PLUS4, SCPU64, VIC20). Without this the
  binary is correct and finds nothing; that cost this spike an hour.

### 3.3 The gate is real

Patched binary, `VICE_CTL_SOCK` unset, `-limitcycles 20000000
-exitscreenshot`: the PNG is **byte-identical** (`md5 3f91057a…`) to the same
run on the pristine pre-patch build, and the log contains **zero** `Keymap:`
lines. No socket, no thread, no keymap, no resources, no cmdline options.

---

## 4. Fast typing, and why `VICE_CTL_KEY_EXCL=1` is mandatory

The 2026-08-12 lesson reproduces on VICE exactly as the brief predicted, and
this is the cheapest demonstration of it anywhere in the lab:

| Run | `VICE_CTL_KEY_EXCL` | Burst | Wall time | Result on screen |
|---|---|---|---|---|
| A | 1 | `10 PRINT "HI"` ⏎ `run` ⏎ (36 edges) | 1.6 s / 3.9 s | the program, and `HI` |
| B | 0 | the same 36 edges | **0.20 s** | `N ''N` |

With per-key pacing alone, distinct keys are free to be down in the same frame —
which is correct for a real keyboard and fatal for a burst, because the KERNAL
scan sees an ambiguous matrix and resolves it to whichever cell it finds first.
`EXCL` makes a non-modifier press wait until no other non-modifier key is down
plus one gap; modifiers are exempt **by matrix position** (`key_is_modifier()`
against the `.vkm`'s own `!LSHIFT/!RSHIFT/!LCBM/!LCTRL` anchors), because a held
shift is a level, not a keystroke.

The resulting ceiling is ~1 key per `HOLD+GAP` — 8.3 keys/s at the 60/60 ms
default, and that is the *guest's* ceiling, not the transport's. The daemon must
size its ordered queue and its ack deadline for it, exactly as `mame_sock.rs`
already does (5 s + 200 ms per outstanding paced verb). Note the existing
`scripts/dev/emu-key-pacing-bisect.py` already records "the VICE tiles' 40/60/80"
from the bridged path; those numbers should be re-bisected against this engine
before the wave, not assumed.

---

## 5. Do the C64/VIC-20/PET/CBM matrices need per-station maps? Yes — and `KEYDUMP` generates them

`KEYDUMP` walks the running machine's parsed `keyconvmap` and its resolved
anchors. Measured, one line per station family:

| Binary / model | Station | keys | LSHIFT | RSHIFT | LCBM | LCTRL | `a` | `q` | `1` | Return |
|---|---|---|---|---|---|---|---|---|---|---|
| `x64sc` | `c64` | 129 | 1,7 | 6,4 | 7,5 | 7,2 | 1,2 | 7,6 | 7,0 | 0,1 |
| `x128` | `c128` | 148 | 1,7 | 6,4 | 7,5 | 7,2 | 1,2 | 7,6 | 7,0 | 0,1 |
| `xvic` | `vic20` | 132 | 1,3 | 6,4 | 0,5 | 0,2 | 1,2 | 0,6 | 0,0 | 7,1 |
| `xplus4` | `plus4` | 129 | 1,7 | **1,7** | 7,5 | 7,2 | 1,2 | 7,6 | 7,0 | 0,1 |
| `xpet -model 2001` | `pet2001` | 149 | 8,0 | 8,5 | — | — | 4,0 | 2,0 | 6,6 | 6,5 |
| `xpet -model 8032` | `cbm8032` | 137 | 6,0 | 6,6 | — | — | 3,0 | 5,0 | 1,0 | 3,4 |
| `xcbm2 -model 610` | `cbm2` | 161 | 8,4 | **8,4** | 3,4 | 8,5 | 9,3 | 9,2 | 9,1 | 2,4 |

Three things fall out of that table:

1. **Every family is different**, and not by a permutation — the PET puts `1` at
   row 6 and the CBM-II at row 9; the CBM-II uses rows up to 14.
2. **`pet2001` and `cbm8032` are the same binary** (`xpet`) with different
   `-model`, and their keyboards share *nothing*: 149 keys vs 137, different
   anchors, different cells for every sampled key. A keymap keyed on the
   *binary* would be wrong for one of them. This is the argument for dumping
   from the running, fully-configured machine rather than from a data file.
3. **`plus4` and `cbm2` report LSHIFT == RSHIFT** — one physical shift key —
   which changes shift-lock semantics, and `pet2001`/`cbm8032` have no CBM and
   no CTRL key at all (`-1,-1`). Any "press shift for the visitor" logic that
   assumes the C64's two-shift layout is wrong on four of the seven stations.
   The module reads the anchors instead of assuming.

**What the daemon actually needs**, given the keysym-level verb, is *not* this
table: it is one host-layout table, `scancode → (plain keysym, shifted keysym)`,
identical for all seven stations. `KEYDUMP` is then the **validator**: intersect
its keysym list with the station's UI keyboard profile
(`spa/src/data/keyboards.ts` / `registry/stations/*.json`) and fail loudly on any
key the exhibit offers that the machine does not name. That is the same
acceptance bar Phase 0 set for MAME — "the list the exhibit needs, not every
field the emulator exposes" — with the map generated and the *gap* reported,
never guessed.

Suggested next artefact: `scripts/dev/vice-keymap.py <ctl.sock>` — connect,
`KEYDUMP`, emit `SH_VICESOCK_KEYMAP` rows plus a loud unmatched list. It should
reuse `scripts/dev/mame-keymap.py`'s `XT_KEYS` table for the scancode side.

---

## 6. Daemon-side shape (recommendation, not built here)

`mame_sock.rs` is 90 % reusable. Concretely:

- **New sink `vice_sock.rs`**, same architecture: `try_lock`-and-offer on the
  browser path; connect / banner / write / ack-read / reconnect in one
  background task; bounded ordered queue; drop-and-resync on breach.
- **Wire line**: `KEY <0|1> <keysym>` instead of `KEY <0|1> <port> <field>`.
  Pointer verbs are not needed — all seven stations are keyboard-only, same as
  the nine MAME ones.
- **`SH_VICESOCK_KEYMAP`**: the existing `KeyMap` loader in `mame_input.rs`
  already parses `code<TAB>a<TAB>b` with `a`/`b` as opaque strings, so a
  `scancode-hex<TAB>plain-keysym<TAB>shifted-keysym` file loads with **no
  change to the parser**. The sink picks column 2 or 3 from its own tracked
  shift state and forwards `Shift_L` as itself. Keep the fail-closed rule: a
  declared-but-broken map disables the keyboard rather than falling back.
- **Ack budget**: 5 s + 200 ms per outstanding paced verb is already right for a
  ~120 ms/key engine; `SAVEST`/`LOADST` need the long timeout as on MAME.
- **Single-injector rule** carries over: a station launched with
  `VICE_CTL_SOCK` must not also be driven through the monitor.

## 7. Rig, artefacts, teardown

Everything under `/data/vms/soltest/vice-in/`, tag `vice-in`:

- `vice-src/` — the fork clone, branch `kernel-hive-vicectl`, 2 commits.
  Untracked autotools output (`configure`, `Makefile.in`, `autom4te.cache/`)
  is build residue and is not committed.
- `build/`, `inst/` — out-of-tree build and its `--prefix`.
- `run.sh`, `type.py`, `dump.sh`, `shifttest.py` — the rig's own harness.
- `/tmp/vice-in-{base,unset,typed,noexcl,shift,final}.png` — the framebuffer
  evidence quoted above.

Teardown at the end of the session: every `x64sc`/`xvic`/`xpet`/`xcbm2`/
`xplus4`/`x128` this spike started was resolved through `/proc/<pid>/exe` and
killed (never `pkill -f`, which matches the driving ssh command line); the
listener sockets `ctl.sock` and `dump.sock` are unlinked by the module's own
shutdown path. No live station, no shared display, no tap, no port was claimed —
the control channel is a unix socket inside the rig directory.

## 8. Open items for the wave

1. **Pin the fork.** This spike sits on `svn-mirror` `main` (3.10-dev). The
   stations run Debian's 3.9. Pick the mirror revision tag matching the shipped
   release, rebase these two commits onto it, and make it
   `third_party/vice-kernel-hive` beside `third_party/mame-irix`.
2. **`scripts/dev/vice-keymap.py`** and the `SH_VICESOCK_KEYMAP` file format
   (§5, §6).
3. **Re-bisect the pacing** (§4) rather than inheriting 40/60/80 from the
   bridged path.
4. **Frames and audio** are the sibling agents' rigs (`vice-vid`, `vice-aud`);
   this spike's `SHOT` verb is a standalone proof channel and should stay in the
   fork regardless, because it is how a checkpoint's ACCEPT frame gets captured
   without a display.
5. **`x128` has two canvases** (VDC and VICII). `SHOT` takes canvas 0, which is
   the VDC — the `c128` station is the 80-column one, so that is right, but it
   must be stated in the runbook, not rediscovered.
