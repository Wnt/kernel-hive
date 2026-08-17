# The VICE fork, pinned — `3.10.0` + both patch planes, re-verified

**Status 2026-08-16: the pin is CLEAN.** Both spike branches rebased from the
mirror's moving `main` (3.10-dev) onto the **`3.10.0` release tag** with **zero
conflicts and zero content changes**, and all four planes — frames, keys, audio,
checkpoints — plus the gating covenant were re-proven on labhost against a
**freshly built** `--enable-headlessui` binary of the rebased, integrated tree.

This closes open item 1 of [`vice-input-plane.md`](vice-input-plane.md) §8 and
the "pin the fork" precondition in
[`../DEBRIDGE-HANDOVER.md`](../DEBRIDGE-HANDOVER.md) §"In flight: the VICE wave".
The remaining preconditions before vic20 are the submodule itself and
`scripts/dev/vice-keymap.py`.

---

## 1. The pin

The fork is `github.com/Wnt/vice` (a fork of `VICE-Team/svn-mirror`, matching the
`mame-irix` / QEMU fork convention).

| | |
|---|---|
| Upstream tag | **`3.10.0`** — note there is **no `v` prefix**; the mirror tags releases `3.6.0`…`3.10.0` and tags every SVN revision as `rNNNNN` |
| Tag commit | `4d283a2e7dd59b7e378524878e81ecc7826b700c` |
| Tag date / subject | 2025-12-24 — *"if nothing goes wrong, this is the 3.10.0 release :) - merry xmas"* |
| Relationship to `main` | the tag **is** an ancestor of `main`; `main` (`223e31ac76`, where both spikes were developed) is **5 279 commits** past it |

The tag is present on the fork remote (`refs/tags/3.10.0` →
`4d283a2e7d`), so a submodule can pin it directly.

### The three branches on the fork

| Branch | Head | Contents |
|---|---|---|
| `kernel-hive/shmfb` | `84a5c66a044687b2a6bae2d3f659b3a13ab82888` | frame plane, 2 commits on `3.10.0` |
| `kernel-hive/vicectl` | `f3e19575a9e6b904df051558dd6773968621b90c` | input plane, 2 commits on `3.10.0` (renamed from the spike's `kernel-hive-vicectl` to the `kernel-hive/` prefix) |
| `kernel-hive/integrated` | `75646dfab6787c225e75c1aec1c790f4a9b984c3` | **both** patch sets, 4 commits on `3.10.0` — **this is what the submodule pins** |

`kernel-hive/integrated`, oldest first:

```
52819c3b60ffddc79e51941cb5543634c1b3abfe  headless: a shared-memory framebuffer publisher (VICE_SHM_PATH)
84a5c66a044687b2a6bae2d3f659b3a13ab82888  headless: publish from video_canvas_refresh(), the one video seam
17752db87e94ad7487f7238ab054c75a74c0a200  vicectl: a unix control socket for headless VICE
75646dfab6787c225e75c1aec1c790f4a9b984c3  headless: give the headless UI a keymap, so keysyms resolve
```

No branch that this work did not create was touched; nothing was force-pushed.

## 2. The rebase — what changed, and what did not

**Nothing changed.** Both rebases (`git rebase --onto 3.10.0 223e31ac76 …`)
applied without a single conflict, and the resulting patches were diffed against
the originals:

* **`kernel-hive/shmfb` — byte-identical patch.** `git diff 223e31ac76
  kernel-hive-shmfb-orig` and `git diff 3.10.0 kernel-hive/shmfb` are the *same
  bytes*. `vice/src/arch/headless/` has **zero** upstream drift between `3.10.0`
  and `main` — the headless port's stubs really are old and stable, as the frame
  spike predicted.
* **`kernel-hive/vicectl` — semantically identical patch.** The only differences
  between the two diffs are **blob hashes and hunk line offsets** (36 diff-of-diff
  lines, all `index …` or `@@ … @@`). The three files with real upstream drift —
  `src/main.c` (+160 lines upstream), `src/vsync.c` (+30), `src/Makefile.am` —
  all took the hunk at the same *semantic* position; verified by reading the
  applied context, e.g. `vicectl_init()` still sits immediately after
  `init_main()` and before `#ifdef USE_VICE_THREAD`, exactly as on `main`.
* **`kernel-hive/integrated`** was built by cherry-picking the two vicectl
  commits onto `kernel-hive/shmfb`. The one overlap,
  `src/arch/headless/Makefile.am`, **auto-merged** (shmfb adds `shmfb.c` to
  `libarch_a_SOURCES` and `shmfb.h` to `EXTRA_DIST`; vicectl adds
  `x11keysyms.h` to `EXTRA_DIST`) — different lines, no conflict.

**Conflicts resolved: none. Hunks dropped: none. Code edited during the rebase:
none.** Anything else in the two spike documents therefore still describes the
pinned tree exactly.

### One thing NOT to trust from the spike docs

`vice-video-plane.md` §1 says the mirror "tags every SVN revision, so no tag
fetch" and used a `--depth 1` clone. The pin needs the *release* tag, which is a
plain annotated-style tag named `3.10.0` in the same namespace. A shallow clone
will not have it — clone full, or fetch `refs/tags/3.10.0` explicitly.

## 3. Building the pinned tree

Host-native on labhost (trixie, gcc 14.2), rig `/data/vms/sandbox/vice-pin/`,
out-of-tree, `--enable-headlessui`, `make -j12`, **`make rc=0`**. The two build
tools the box does not have are still the frame spike's rig-local pair
(`dos2unix` sed shim, `xa65` unpacked from a `.deb` into the rig's own `bin/`,
never installed) — plus one addition:

* **`xa65` ships its assembler as `bin/xa`.** A `ln -sf xa bin/xa65` in the rig's
  `bin/` costs nothing and removes the question. `configure` succeeded either
  way here, but the builder script should make the symlink.

Warnings from the whole build: **5**, four of them pre-existing upstream
(`resid/filter8580new.cc`, two `6510core.c` `#warning`s, a curl attribute
warning). The fifth is ours and pre-dates the rebase:

```
src/vicectl.c:273:40: warning: '%s' directive output may be truncated
                      writing up to 511 bytes into a region of size between 508 and 509
                      [-Wformat-truncation=]
```

`reply_ok()`'s `snprintf` into `char buf[512]` — safe (snprintf truncates), but
it is the one warning the fork adds and should be silenced before the wave, not
inherited into a builder that greps for "zero warnings added".

### The landmine that actually cost time: `$HOME/.local/state/vice`

**A headless VICE whose stdout is not a terminal SEGFAULTS in `vice_banner()`
unless its log file can be opened.** Backtrace:

```
#1 log_archdep (pretxt=0x0, logtxt=0x0) at src/log.c:615
#2 log_helper (level=128, format=" ")   at src/log.c:767
#3 log_message (log=-1, format=" ")     at src/log.c:819
#4 vice_banner ()                       at src/main.c:142
```

`log_helper()` computes the colour-stripped strings **only** when
`log_to_file || !log_colorize`. With colour on, stdout not a tty, and no log
file open, it then passes those NULL pointers to `log_archdep()`, which
`strlen()`s them. Confirmed:

* it reproduces **identically on the 3.10-dev binary** from the frame spike's own
  rig, so it is **not** introduced by the rebase or the pin;
* `-logfile <path>` does **not** save you — `vice_banner()` runs before that
  resource is live;
* `log.c` is essentially unchanged between `3.10.0` and `main` (one `fflush`
  reorder, one cast), so upstream has not fixed it;
* the cure is one line: **`mkdir -p "$HOME/.local/state/vice"`** before launch.
  VICE creates `$HOME/.cache` and `$HOME/.config` itself but **not**
  `$HOME/.local/state`, so a launcher that sets `HOME` to a fresh per-station
  dir — which every converted station does — walks straight into this.

This is the same shape as the fleet's inherited "VICE 3.9 segfaults when stdout
is not a terminal" note. That note is **right about the symptom and wrong about
the cause**, and `vice-video-plane.md` §1's "did not reproduce in 3.10" was luck
of a pre-existing `HOME`. Record it in the vic20 runbook as a *launcher*
requirement, not a version quirk.

## 4. Verification — all four planes, on the rebased tree

Everything below ran on the `kernel-hive/integrated` build, headless, **no X, no
`DISPLAY`**, rig `/data/vms/sandbox/vice-pin/`, port `47251` claimed with a
loud preflight (`ss -lntH` + a `/proc/<pid>/exe` sweep that refuses to start if
any binary under the rig path is alive).

### 4.1 Frames — byte-exact, and pixel-exact against VICE's own renderer

| Check | Result |
|---|---|
| default (2× CRT) mapping size | **1 671 232 B** = `64 + 768·544·4` ✓ |
| `+VICIIdsize -VICIIfilter 0` | **417 856 B** = `64 + 384·272·4` ✓ |
| read back by the **unmodified** IRIX-era consumer `shmpng.py` (md5 `87b075929c097d35240ebca30bb65f8b`) | ✓ renders the C64 boot screen |
| `frame-compare.py --frame` on the 2× frame | 89 colours, entropy 2.8328 bits, 298 609/417 792 non-dominant — **FLOOR PASS** |
| published 1× mapping **vs** VICE's own `-exitscreenshot` from the same run | **`UNCHANGED — not one pixel differs`**, 0 of 104 448, max channel delta 0 |

The 1× numbers (entropy **0.9727** bits, **42 090** of 104 448 non-dominant) are
*identical to the pre-rebase spike's*, which is the strongest single statement
that the rebase changed nothing. Human identity judgement: the frame shows
`**** COMMODORE 64 BASIC V2 ****` / `64K RAM SYSTEM 38911 BASIC BYTES FREE` /
`READY.` in light blue on dark blue with a light blue border.

### 4.2 Keys — on the framebuffer, never from a log

`vicectl` banner on the pinned build:
`vicectl/1 machine=C64SC rows=16 cols=8 keys=129`, `KEYDUMP` anchors
`lshift=1,7 rshift=6,4 lcbm=7,5 lctrl=7,2` — matching `vice-input-plane.md` §5
exactly.

One burst of **66 edges** (`10 PRINT "HELLO KERNEL HIVE"` + `run`), written to
the socket in a single `write`, `VICE_CTL_KEY_EXCL=1`:

* **all 66 acked in 3.91 s**, `coalesced=0 err=0` — the spike measured 3.91 s;
* the **shm mapping** (not the module's own `SHOT`, so the frame and key planes
  prove each other) then contains `10 PRINT "HELLO KERNEL HIVE"` / `RUN` /
  `HELLO KERNEL HIVE` / `READY.`

**Negative control, same burst, `VICE_CTL_KEY_EXCL=0`:** acked in **0.43 s**, and
the framebuffer shows `, N L I` — garbage, as documented. `VICE_CTL_KEY_EXCL=1`
is mandatory on the pinned tree too.

### 4.3 Audio — `wav` → FIFO, and the guest stays the clock

`-sounddev wav -soundarg <fifo> -soundrate 48000 -soundoutput 2`, resident
`O_RDWR` holder fd (`sleep 900 3<>fifo`), paced reader at 3840 B / 20 ms:

| | |
|---|---|
| cold-boot floor | **rms 0.0**, peak 0, five consecutive 5 s windows |
| sustained SID tone (typed in over `vicectl`) | **rms 2020.8**, peak ~3776, steady across four windows |
| throughput | ~**188 000 B/s** (940 800 B per 5 s window) against the 192 000 B/s contract |
| guest speed, from the KERNAL jiffy clock ($A0–$A2) | 442 → 1623 jiffies (**19.68 guest s**) over **20.10 wall s** = **97.9 %** |

97.9 % is the `wav` shape, not the MAME `sdl`+disk shape (24 %). The first 5 s
window reads `rms 241.8 peak 28006` — that is the 44-byte RIFF header plus the
documented open-time garbage, and it is why the floor must be read from window 2
onward.

### 4.4 Checkpoints — `dump`/`undump` and restore-at-startup

Over `-binarymonitor` (`ip4://127.0.0.1:47251`; the text `-remotemonitor` is
dead in a headless build):

* **`dump`** → `type=0x41 err=0x00`, a 193 261 B `.vsf`;
* **restore at startup**, `-moncommands <file>` + `-initbreak ready`, **no
  monitor client attached**: the machine comes up already showing the
  checkpointed screen, and its jiffy clock reads **71.55 guest seconds** — the
  checkpoint's clock, restored, not a fresh boot;
* **`reset=0`** clears it back to the bare boot screen;
* **`undump` on the same live process** restores it again, `type=0x42 err=0x00`.

Both the screen-RAM read and the **shm framebuffer** agree at every step. The
restored scene is **silent** (rms 0.0), which is the documented "never bake a
checkpoint inside music" caveat behaving exactly as predicted.

### 4.5 The gating covenant — indistinguishable from stock

Stock `3.10.0` was **built separately** in the same rig
(`build-stock/`, from a clean `3.10.0` checkout) so the comparison is against a
real binary, not an assertion. With `VICE_SHM_PATH` and `VICE_CTL_SOCK` both
unset, same command line, same `-exitscreenshot`:

```
3f91057a6e973bd21b1ae0c177ca7bc5  cov-stock.png     (stock 3.10.0)
3f91057a6e973bd21b1ae0c177ca7bc5  cov-patched.png   (kernel-hive/integrated)
```

Byte-identical — **and the same md5 both spikes recorded on 3.10-dev**. The
patched run's log contains **zero** `shmfb`/`vicectl`/`Keymap` lines, and writes
no socket and no mapping. The only log differences are the rig paths and the
`VIC-II: VSP Bug: safe channels` line, which is seeded from the run's random
seed and differs between two runs of the *same* binary.

## 5. What was not verified

* `kernel-hive/shmfb` and `kernel-hive/vicectl` were **not built standalone** —
  only `kernel-hive/integrated` was, which is what the submodule pins and which
  compiles every line of both. A standalone build of either is ~5 min if wanted.
* Only `x64sc` was exercised on the pinned tree. The spikes proved `xvic`,
  `xplus4`, `xpet` (2001 and 8032), `xcbm2` and `x128` on 3.10-dev, and the
  rebase changed no code, so nothing suggests a per-machine regression — but the
  vic20 conversion should re-run its own `xvic` proof as step one anyway.
* Key **pacing** is still the spike's 60/60 ms default. It must be re-bisected
  against this engine before the wave (`vice-input-plane.md` §4), not inherited
  from the bridged 40/60/80.

## 6. Teardown

Rig `/data/vms/sandbox/vice-pin/` (406 MB: the pinned source, the integrated
build, the stock-3.10.0 build, and the evidence) left in place for the vic20
work; **nothing live was touched** — no station, no `/data/vms/streamhost/`, no
package installed on labhost, no display, tap, VMID or iptables chain claimed.

Released, and the check that proved it:

* **Every emulator this session started is dead.** A `/proc` sweep resolving
  `/proc/<pid>/exe` (never a cmdline grep) for anything under `vice-pin`, and a
  second sweep for `x64sc|xvic|xpet|xplus4|xcbm2|x128` **anywhere on the box**,
  both return empty. Every recorded pidfile resolves to `GONE`. Each kill was
  gated on `readlink /proc/<pid>/exe` matching the rig path first.
* **Port 47251 released** — `ss -lntH | grep ':47251 '` → not bound.
* **`run/ctl.sock` and `run/audio.fifo` unlinked** — both `ls` as
  *No such file or directory*.
* The launchers use `( exec … ) &` / `setsid … &` with the real pid recorded, so
  no subshell-orphan of the 2026-08-12 kind was created (the sweep above is the
  proof).

## 7. What this unblocks, and what it does not

**Unblocked:** create `third_party/vice-kernel-hive` as a submodule of
`github.com/Wnt/vice` at `kernel-hive/integrated`
(`75646dfab6787c225e75c1aec1c790f4a9b984c3`, four commits on tag `3.10.0`), and
start the vic20 conversion.

**Carry into the vic20 runbook:**

1. `mkdir -p "$HOME/.local/state/vice"` in the launcher, or the emulator
   segfaults before it prints anything (§3).
2. `ln -sf xa bin/xa65` in the builder alongside the `dos2unix` shim.
3. `VICE_CTL_KEY_EXCL=1` is mandatory (§4.2), and pacing must be re-bisected.
4. Fix or silence the `vicectl.c:273` format-truncation warning before the
   builder starts asserting a clean build.
5. `-binarymonitor`, never `-remotemonitor`.
