# VICE de-bridging — audio plane, checkpoint plane, and the seven-station survey

**Status 2026-08-16: research complete, nothing converted.** This is the VICE
wave's answer to two of the three questions the MAME campaign already answered
for its nine (`docs/lab/DEBRIDGE-CONVERSION-BRIEF.md` §1): **how a host-native
VICE feeds the daemon audio**, and **whether it can be made instant-ready**
(launch restored-to-checkpoint and PAUSED — `docs/GLOSSARY.md`). The video and
input planes are separate work.

Everything below was measured on labhost in a namespaced rig,
`/data/vms/soltest/vice-aud/` (tag `vice-aud`), against **VICE 3.9 built
host-native**, not inferred from documentation. Teardown is recorded in §6.

---

## 1. Headline

| Question | Answer |
|---|---|
| Can VICE write the daemon's FIFO contract (48 kHz, stereo, s16le, 192 000 B/s)? | **Yes**, with `-sounddev wav -soundarg <fifo> -soundrate 48000 -soundoutput 2`. Measured: `channels=2 rate=48000 byterate=192000 bits=16`, sustained SID tone RMS **2050.2**, cold-boot floor **0.0**. |
| Does the obvious route — SDL's disk driver, the proven MAME path — work? | **No. It runs the emulator at 25 % speed.** VICE's `sdl` sound device is flagged `is_timing_source = true`; the disk backend's buffer accounting then governs emulation. Measured 4.77 guest s per 20.18 wall s. Do not use it. |
| Can VICE save/restore a checkpoint? | **Yes**, `dump`/`undump` (monitor) — first-class, machine-wide, loud on mismatch. Round-tripped on **all seven** binaries. |
| Can it restore at startup from the command line? | **Yes**, `-moncommands <file>` + `-initbreak ready` — the VICE equivalent of `-loadvm golden`. No socket client needed. |
| Is a VICE snapshot trustworthy (the MAME `MACHINE_SUPPORTS_SAVE` question)? | **Yes, with one honest caveat** — see §3.4. Nothing like MAME's silent garbage: VICE gates on machine name and per-module version and fails **loudly**, and the binary monitor returns a non-zero error code you can assert on. |

---

## 2. GOAL A — the audio recipe

### 2.1 The contract being satisfied

From `streamhost/streamhost/src/audio.rs` (`SH_AUDIO_SOURCE=fifo`): the daemon
is the clock, reading one Opus frame — `FIFO_TICK_BYTES` = 3840 B of s16le
stereo @ 48 kHz — per 20 ms tick, i.e. exactly **192 000 B/s**, with the pipe
shrunk to 16 KiB (`F_SETPIPE_SZ`, ≈85 ms of standing latency). The launcher's
side of that contract is `streamhost/stations/mame-native/x11-runtime.sh`
(resident FIFO holder + `SDL_DISKAUDIOFILE`) and
`streamhost/stations/irix/x11-runtime.sh` `audio_up()`.

### 2.2 The recipe

```bash
# in the station launcher, before starting the emulator
[ -p "$AFIFO" ] || { rm -f -- "$AFIFO" && mkfifo "$AFIFO"; }
# resident O_RDWR holder: the emulator's open() must succeed whichever side
# comes up first, and a daemon restart must never SIGPIPE the exhibit
exec {AUDIO_FD}<>"$AFIFO"

exec "$VICE_BIN" "$@" \
  -sounddev wav -soundarg "$AFIFO" \
  -soundrate 48000 -soundoutput 2
```

`-soundoutput 2` is "always stereo" — **not 3**; VICE 3.9's modes are
`0 system / 1 mono / 2 stereo`, and passing 3 is a hard
`Error parsing command-line options, bailing out`.

`wav` is registered in `src/sound.c` as a *record* device, but the
`SoundDeviceName` lookup accepts it as playback, and that is the whole trick:
its device struct (`src/arch/shared/sounddrv/soundwav.c`) is
`max_channels = 2`, **`is_timing_source = false`**, blocking `fwrite`, no
`bufferspace` callback. VICE therefore keeps its own vsync clock and the FIFO is
a pure sink whose backpressure paces the writer — exactly the shape the daemon
wants.

> **SUPERSEDED 2026-08-17 — the header was audible and the blocking write was
> worse.** The fork now has `soundfifo.c` (`-sounddev fifo`): raw stereo PCM,
> no header, `is_timing_source=false`, and **non-blocking** — a full pipe drops
> samples instead of stalling the emulator, which is what a station with no
> visitor connected always is. See `docs/lab/DEBRIDGE-HANDOVER.md` §The restore
> moment. The paragraph below is kept as the reasoning that chose `wav` first.

**The 44-byte RIFF header.** `wav_init` writes a header before the PCM. It is
4-byte aligned, so stereo s16 framing is preserved; the daemon consumes it as 11
frames of garbage at open (measured peak 28 006 in the first window, then clean).
`wav_close` fseeks to patch the header, which fails harmlessly on a pipe. If that
header is judged unacceptable, the tidy alternative is a ~40-line
`soundfifo.c` modelled on `soundfs.c` but with `max_channels = 2` and
`is_timing_source = false` — a smaller patch than any the MAME wave carries.
`fs` itself is unusable as-is: `fs_init` hard-codes `*channels = 1`.

### 2.3 The measurements

A real SID tone (`petcat`-built BASIC that pokes 54272-54296 and loops):

| condition | RMS | peak | byte rate |
|---|---|---|---|
| cold-booted C64, idle | **0.0** | 0 | 192 000 B/s of digital silence |
| sustained SID tone, last 3 s of a 10 s file capture | **2050.2** | 3565 | header says `channels=2 rate=48000 byterate=192000 bits=16` |
| pulsing SID tone (gate toggled in BASIC) | 1390 | 4150 | ~188 000 B/s through the paced reader |
| the same tone restored from a checkpoint at startup | 1390.7 | 4145 | ~188 000 B/s |

The reader was a deliberate stand-in for the daemon: 3840 B per 20 ms deadline
tick with `F_SETPIPE_SZ` 16 KiB (`/data/vms/soltest/vice-aud/run/reader2.py`).
Its "starved ticks" (≈1.5 %) are an artefact of its own 15 ms give-up cap; the
daemon does a blocking read of a whole tick and tolerates lateness up to
`FIFO_STALL` (250 ms), so those become jitter, not gaps.

Emulator speed was measured from **the guest's own clock**, not from logs: the
KERNAL jiffy counter at `$A0-$A2` (+60/s) read twice over the binary monitor.

| transport | guest seconds per 20 wall seconds | verdict |
|---|---|---|
| `-sounddev dummy` (baseline) | 20.08 | 100 % |
| `-sounddev wav -soundarg <fifo>` | 19.70 | **98 %, use this** |
| `-sounddev sdl` + `SDL_AUDIODRIVER=disk`, `SDL_DISKAUDIODELAY=0`, 16 KiB pipe | 4.77 | 24 % |
| the same with SDL's default delay | 9.87 | 49 % |
| the same with a 64 KiB pipe | 4.77 | 24 % |
| `-sounddev dummy -soundrecdev wav -soundrecarg <fifo>` | 20.08 | 100 % speed but **zero bytes** — the record channel never started |

### 2.4 Landmines found in the audio plane

- **The MAME recipe does not port.** `-sound sdl -audiodriver disk` is right for
  MAME because MAME's disk driver is a dumb sink. VICE's `sdl` device is a
  declared timing source; aiming it at a pipe makes the pipe the emulator's
  clock and it loses three quarters of its speed. Copying the irix/mame-native
  audio stanza verbatim into a VICE launcher is the single most likely way this
  wave ships a station that runs at quarter speed with correct-looking audio.
- **A stalled VICE services nothing.** With any blocking sink, if the reader
  stops the emulator stops: measured 1 % CPU, `SDLAudioP1` in `anon_pipe_write`,
  main thread in `hrtimer_nanosleep` — and *the binary monitor stops answering
  too*. Two consequences: the daemon must be draining before the launcher issues
  any control command, and a stalled emulator still **holds its monitor port**,
  so a stale rig silently steals the port from the next one. (This rig lost
  about an hour to exactly that: ten stale `x64sc` processes, every monitor read
  after them a lie. Every VICE launcher and probe must claim its monitor port
  atomically and fail loudly, per `AGENTS.md`.)
- **No reader at all, and no holder fd, kills the audio silently.** When the
  last reader closed and the holder had expired, the writer took EPIPE, the
  stream died for good, and *nothing was logged*. The irix `audio_up()` holder
  fd is not optional.
- **`F_SETPIPE_SZ` fails with `EBUSY` if the pipe is already fuller than the new
  size.** Shrinking to 16 KiB only works if the reader attaches before the
  producer has filled the default 64 KiB (≈340 ms). Start-order matters: the
  daemon should attach first, or accept ~340 ms of standing latency.
- **VICE 3.9 has no `-soundsync`;** the knobs are `-soundbufsize` (ms) and
  `-soundfragsize` (0-4). Neither rescues the `sdl` path (tested: 200 ms buffer,
  fragsize 4, `-speed 100` — all still ~25 %).

---

## 3. GOAL B — the checkpoint verdict

### 3.1 Save and load

VICE's monitor has `dump "<file>"` (write snapshot) and `undump "<file>"`
(read snapshot) — `src/monitor/mon_command.c`. They are reachable three ways:

| channel | works headless? | notes |
|---|---|---|
| `-moncommands <file>` (+ `-initbreak ready`) | **yes** — measured | The startup restore. Log shows `Monitor playback command: undump "…"`. **The first `x` ends playback**, so one command block per file. |
| `-binarymonitor -binarymonitoraddress ip4://127.0.0.1:<port>` | **yes** — measured | `MON_CMD_DUMP 0x41`, `MON_CMD_UNDUMP 0x42`, plus `RESET 0xcc`, `KEYBOARD_FEED 0x72`, `DISPLAY_GET 0x84`, `MEM_GET 0x01`. Returns an error byte you can assert on. Client used here: `/data/vms/soltest/vice-aud/run/vicemon.py`. |
| `-remotemonitor` (text) | **NO** in a headless build | `src/arch/headless/uimon.c:uimon_get_in()` returns `NULL`, so the interactive monitor never reads a line. The socket listens and answers nothing — which looks exactly like a hung emulator. |

`-loadsnapshot` does not exist; **`-moncommands` + `-initbreak ready` is the
`-loadvm golden` equivalent**, and it costs the ~2 s of cold boot it takes to
reach the `ready` break before the state is swapped in.

### 3.2 What was proven

- Checkpoint captured mid-scene with `dump`, emulator killed, a **fresh process**
  restored it at startup through `-moncommands` alone (no client attached): the
  screen came back byte-for-byte (screen-RAM read over `MEM_GET`, and the
  DISPLAY_GET histogram identical across independent restores — 61261/52797/43187),
  and the restored program was **still running and still making sound**.
- `undump` on an already-running process works too, and repeatedly: that is the
  cheap **reset = restore-in-place**, with no relaunch and no cold boot.
- Round-tripped `dump` + `undump` (error code 0x00 both ways) on **all seven
  binaries**: `x64sc` (193 KB), `x128` (427 KB), `xvic` (1 052 KB),
  `xplus4` (272 KB), `xpet -model 2001` (123 KB), `xpet -model 8032` (240 KB),
  `xcbm2 -model 610` (341 KB).

### 3.3 Reset semantics

`MON_CMD_RESET 0xcc` takes one byte: **`0x00` reset system**, **`0x01` power
cycle**, `0x08-0x0b` reset drives 8-11. Neither is what an exhibit's "reset"
button should do — the fleet contract is restore-to-checkpoint, which
`undump` does directly and instantly. Keep the resets for building a checkpoint,
not for serving one.

### 3.4 The honest caveat — sound does not survive the restore

A checkpoint captured while a **sustained** SID note was sounding restored
**silent**: screen, memory and CPU all correct, the BASIC program still looping,
but the tone gone (RMS 9.1 — the DC floor of a SID left at volume 15 — instead of
2050). The same checkpoint taken of a program that **re-writes** the SID every
few frames restored fully audible (RMS 1390). Read: the snapshot carries the
machine, but the sound engine restarts, and a guest that never touches the sound
chip again never gets its note back.

This does not hurt any of the seven as they stand — every station's documented
scene is a silent `READY.` prompt (c64's is the GEOS deskTop, also silent). It
does mean: **never bake a checkpoint mid-sound and expect the sound back**, and
if a future VICE exhibit's scene is musical, the checkpoint must sit before the
music starts, not inside it.

### 3.5 Why this is not the MAME situation

MAME's failure was silent: drivers without `MACHINE_SUPPORTS_SAVE` restored
garbage — `bbcb` died outright, `kc85_4` restored to a black screen
(`DEBRIDGE-CONVERSION-BRIEF.md`; `MAME_NATIVE_CHECKPOINT=0` exists for them).
VICE's snapshot is machine-wide and version-gated: `src/snapshot.c` checks the
machine name (`SNAPSHOT_MACHINE_MISMATCH_ERROR`) and each module's version
(`SNAPSHOT_MODULE_HIGHER_VERSION` / `MODULE_INCOMPATIBLE`), and the binary
monitor turns a failure into `e_MON_ERR_CMD_FAILURE`. **A converted station can
assert its restore succeeded, and must** — the frame is still the proof, but
here there is also a machine-readable one.

Two operational consequences: a checkpoint belongs to **one machine type and one
VICE build**, so any rebuild of the emulator must re-run the restore assertion
before the station is served; and `dump` writes **no ROMs** into the snapshot,
so the ROM tree must be identical at restore time (which is the same discipline
the builders' `repair_*_roms()` + assert blocks already enforce).

---

## 4. GOAL C — the seven stations

Sources: `registry/stations/<id>.json`, `streamhost/stations/<id>/station.env.fixture`,
`scripts/build-guests/tiles/<id>.sh`, `scripts/build-guests/lib/bridge-base.sh`,
`docs/guests/<id>.md`.

### 4.1 What they share today

One VICE 3.9 source build inside the kiosk guest serves all seven binaries
(`bridge-base.sh:165,392,395`: `./configure --enable-sdl2ui --disable-html-docs
--without-oss --without-pulse --enable-ethernet=no --disable-rs232`). **Never
apt** — bookworm has no package at all, and trixie's `vice 3.9+dfsg-1` is the
GTK3 build with PulseAudio, wrong for a kiosk with no WM (`bridge-base.sh:54-63`).
Every station: `-sounddev alsa` → AC97 → dbus, `SDL_VIDEODRIVER=x11`,
`SDL_RENDER_DRIVER=software`, an `xrandr` root resize, `SH_RESET_MODE=loadvm`,
`SH_GOLDEN_SNAPSHOT=golden` (a qcow2 internal snapshot), production launchers
carrying `-loadvm golden -S`.

### 4.2 The table

| # | Station | Binary + model | Kiosk window / X root | Pacing | Keymap quirks | Demo / scene | Golden | The landmines that matter to a conversion |
|---|---|---|---|---|---|---|---|---|
| 1 | `vic20` | `xvic -pal -VICdsize -VICborders 0` | ~568×568 / 800×600 | 80/80, `perCharMs 170` | none; registry `letterCase: upper-only` (a shifted letter is a graphics glyph); profile family `c64` | `10 print chr$(147)` … `50 goto 20` random-character rain, `run` | untouched cold boot, `**** CBM BASIC V2 ****` | The canonical two: **VICE 3.9 segfaults when stdout is not a terminal** (`vice_banner()` → `strlen(NULL)`, gdb backtrace in `docs/guests/vic20.md:104-110`; the symptom is X dying and getty looping, nothing points at VICE) and **`make install` skips ROM data files** → segfault with no output. Pacing bisect on record: 40/40 → 1 corruption in 22, 60/60 → 0/14, 80/80 → 0/22, and the cause is host scheduling, not frame quantisation. |
| 2 | `plus4` | `xplus4 -pal -TEDdsize -TEDborders 0` | fills 800×600 | 80/80 (driver 120/120, 0.30 s modifier lead) | **C= is Tab, and the symbolic keymap leaks a literal `c` with every C=+C chord — 0 clean chords out of 11 at both 0.30 s and 0.50 s leads** (`plus4.sh:55-61,71-79`) | none; scene is `COMMODORE BASIC V3.5 … 3-PLUS-1 ON KEY F1` | untouched cold boot | *The plus4 lesson*, quoted by four other builders: an earlier golden rested **inside** the 3-Plus-1 spreadsheet and was wrong on the floor — "a visitor arrived in the middle of one application, with no idea what it was, how it got there or how to leave" (`plus4.sh:39-46`). Also: the C= prompt is one-shot, and "a proof that cannot fail is not a proof" (`plus4.sh:460-464`). |
| 3 | `pet2001` | `xpet -model 2001 -CRTCdsize` | 768×532 / 800×600 | 80/80, `perCharMs 180` | `letterCase: upper-only`, letters sent **unshifted**; **Backspace deliberately absent** — INST/DEL is unreachable through the symbolic graphics keymap | `10 print chr$(147)` … `40 goto 20` poking $8000, `run` | untouched cold boot, `*** COMMODORE BASIC ***` | Readiness must be **band + geometry**: GRUB's own text screen measures 2067 lit pixels, inside the 1200-4000 banner band, and the first bake captured *that*; only the 800×600-vs-720×400 geometry separates them (`pet2001.sh:351-368`). Model proof `RamSize=8 Crtc=0 VideoSize=40 KeyboardType=4`, palette `2001-blueish.vpl` — the base's `.bin`-only ROM copy misses `.vpl`/`.vrs`. |
| 4 | `cbm8032` | `xpet -model 8032 -CRTCdsize` | 1408×1064 / **1600×1200** | 80/80, `perCharMs 170`, +0.6 s settle per line | none; `sdl_buuk_sym.vkm`, and unlike the VIC-20 this machine is **not** upper-case-only | times-table across all 80 columns, `run` | untouched cold boot, `*** commodore basic 4.0 ***` | **The ready screen is the *sparse* one**: at power-on the PET's uninitialised screen RAM paints 375 726 green pixels of garbage against the banner's 1597, and a "there is green" predicate bakes the garbage (`cbm8032.sh:74-80`). `-CRTCborders` does not exist and **exits the emulator** if passed. An unresized root clips the 1064-tall window — "the single most likely way this station ships broken". |
| 5 | `cbm2` | `xcbm2 -model 610 -pal` (native, no dsize) | 704×528 / 800×600 | 80/80 | none; profile family `generic` — no Commodore key exists on a CBM-II | none; `*** commodore basic 128, v4.0 ***` | untouched cold boot | Readiness is **position**, not count: green ≥ 250 **and** row/column bounds, because the count barely moves (456 → 454) when the cursor blinks. Clipping here is invisible to the eye (black screen on a black root) — recon measured it with `xsetroot -solid magenta`. Near-duplicate of cbm8032 by design and by risk. |
| 6 | `c128` | `x128 -pal -80col -remotemonitor` | 789×576 / 800×600 | 80/80 | none (VICE's default SDL symbolic keymap) | none; 80-column `COMMODORE BASIC V7.0` with the CP/M disk in drive 8 **unbooted** | cold boot, readiness by **colour** (cyan > 2500 AND magenta < 100) | The CP/M disk is deliberately **not** passed as `-8 <path>`: the KERNAL boots drive 8 at every reset, and the station once came up mid-`BOOTING CP/M PLUS` (`c128.sh:57-63`). `-dualwindow`/`+hidevdcwindow` are traps with no WM. `GO64` cannot ship: C64 mode paints the VIC-II while the visible canvas is the VDC — two screendumps 10 s apart were byte-identical. Already carries a `-remotemonitor` and a background attach helper. |
| 7 | `c64` | `x64sc -mouse -controlport1device 1351 -drive8truedrive -autostart-handle-tde -VICIIdsize -autostart GEOS-1351.D64` | 719×544 / 800×600 | none — this is the fleet's one **pointer** VICE station (`SH_POINTER=rel`, `SH_ABS_PACE_MS=30`) | mouse, not keys: browser absolute → PS/2 **relative** (no tablet, `vmport=off`) | GEOS 2.0 deskTop | **in-application** golden, baked manually | `-drive8truedrive` is required or GEOS hangs (and there is no global `-truedrive` in 3.9). `-VICIIfull` renders BLACK under std-VGA capture. `make install` skips the C64 BASIC ROM → segfault with no output. A missing AC97 makes VICE pop a **modal** "Sound: initialization failed" dialog and block — the original "black screen" mystery. |

### 4.3 What de-bridging deletes for free

Four of the seven landmine families are *artefacts of the kiosk* and vanish with
it: the fixed SDL window and the black real-fullscreen (no X root to fit any
more — the emulator's surface becomes the published surface), the `xrandr`
root-size dance including cbm8032's 1600×1200, the modal ALSA-failure dialog
(no ALSA, no AC97, no dbus), and the "stdout must be a terminal" segfault *as a
kiosk-profile constraint* — though the segfault itself is a property of the
binary and the host-native launcher must still either keep a pty or carry the
one-line `log.c` fix. Assume nothing: the seven builders' geometry tables were
all measured, and the new ones must be too.

### 4.4 Recommended conversion order

1. **`vic20` — the template.** Plainest shape of the seven: one binary, no
   external media, cold-boot golden, keyboard-only, and a registry
   `demoProgram` that exercises the input plane end to end. Its two landmines
   are the family's canonical ones, so writing them up once here covers
   everybody. Convert alone; the write-up becomes the VICE playbook, exactly as
   `dragon32` was for MAME.
2. **`plus4`.** Same shape, no media, and it forces the wave to confront the
   **C=+C chord leak** early: that is a property of VICE's symbolic keymap, not
   of QEMU's `send-key`, so it will survive the conversion and the input plane
   must be measured against it rather than assumed fixed.
3. **`pet2001` + `cbm8032`, batched.** One binary (`xpet`), two models, two
   `repair_pet_roms()` assertions, and both readiness predicates
   (band+geometry, sparse-not-solid) have to be re-expressed against a
   framebuffer that is now the emulator's own. cbm8032 also retires the
   1600×1200 X root, which is the wave's biggest single simplification.
4. **`cbm2`.** Mechanical after the pair above — same `-CRTC` family, native
   704×528, no media — but keep its **position-based** readiness gate; a count
   gate would pass on a clipped or blank screen.
5. **`c128`.** First station with a second moving part: the CP/M disk and its
   background attach helper. Checkpoint-restore actually *improves* it — restore
   never re-runs the KERNAL's drive-8 autoboot, which is the failure the
   deliberate no-`-8` design exists to dodge. Its existing `-remotemonitor` must
   become `-binarymonitor`; the text monitor is dead in a headless build.
6. **`c64` — last, hardest.** The only pointer station (1351 via the joyport),
   the only in-application golden, the only external media (`GEOS-1351.D64`),
   plus true-drive emulation. Nothing about it is mechanical, and it should not
   be attempted until the pointer path a sibling wave lands is proven on a
   keyboard-only station first.

Batch 1-4 are five stations whose entire per-station delta is a binary name, a
model flag and a readiness predicate; 5 and 6 are one-offs.

---

## 5. Reproducing this

Build (labhost, from the upstream 3.9 tarball — Debian's `vice 3.9+dfsg-1` has
its ROMs stripped and is the GTK3 build):

```bash
./configure --enable-headlessui --disable-pdf-docs \
            --without-oss --without-pulse --without-alsa --prefix=<prefix>
make -j12 && make install
```

`--with-sdlsound` is **not** needed — the `wav` sink is core. Two build-time
gotchas: `configure` aborts without **`dos2unix`** and without the **`xa`**
assembler (`xa65` in Debian). Contrary to the guest builders' warning,
`make install` on this configuration copied **every** ROM (`C64 10/10, C128
17/17, VIC20 6/6, PET 28/28, PLUS4 8/8, CBM-II 8/8, DRIVES 14/14`) — the
builders' `repair_*_roms()` + assert blocks should still be carried over, since
the assertion is what makes a future incomplete tree fail loudly.

Rig scripts (kept, read-only reference): `/data/vms/soltest/vice-aud/run/` —
`reader2.py` (the daemon-clock stand-in), `vicemon.py` (binary-monitor client),
`screen.py` / `jiffy.py` / `shot.py` (screen RAM, guest clock, DISPLAY_GET),
`final.sh` (preflight + cold/restore/resets/speed), `fleet.sh` (all seven
binaries).

## 6. Teardown

Every emulator started by this rig was killed through its pidfile with a
`/proc/<pid>/exe` identity check, and the residue was then swept by a `/proc`
scan for any executable under `vice-aud` (that sweep is how the ten stale
`x64sc` processes were found). Final state, verified: **no `vice-aud`
executable running**, no `reader2.py` drain and no FIFO holder alive, ports
`47231-47239` free (`ss -lntH`), 260 MB of build + rig artefacts left in place
under `/data/vms/soltest/vice-aud/`. No live station was started, stopped,
read-modified or otherwise touched; nothing outside `/data/vms/soltest/vice-aud/`
was created.
