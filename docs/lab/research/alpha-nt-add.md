# Adding Windows NT / 2000 on DEC Alpha

Status: **OS INSTALLED, 2026-08-10 — see §9.** The §7 experiment ran to
completion: Windows 2000 RC2 Alpha reaches a desktop, survives an unattended
cold boot with the clock pinned, and the timebomb is quantified. No registry
entry exists yet; station integration is the remaining work. §§1–8 below are the
original 2026-08-09 feasibility study, kept as written.

**Verdict: FEASIBLE-WITH-CAVEATS, Tier 3. One station — `w2kalpha`, Windows 2000
RC2 for Alpha.** The emulator question is settled affirmatively *by experiment on
labhost*: the backend was built, ARC/AlphaBIOS flashed, and Windows 2000 RC2
driven into its file-copy phase, every step framebuffer-proven. The caveats are
a slow install, a pre-release **timebomb**, and a permanently busy core.

---

## 1. Two prior beliefs this study overturned

**(a) "The Virtual OS Museum has no Alpha NT, so it must be very hard."** That
inference — recorded in [`vom-reference.md`](vom-reference.md) — was reasonable
and is now **superseded by direct experiment**. VOM's Alpha exhibit runs OpenVMS
and Tru64 because its emulator (**AlphaVM Free**) *cannot* run Windows, not
because Windows on Alpha is intractable. Absence from a catalogue is evidence
about that catalogue's toolchain, not about the world.

**(b) The AlphaVM Free lead was wrong.** EmuVM's own FAQ: *"AlphaVM does not
support a graphic controller (VGA)"*, supported guests *"OpenVMS and
Tru64/Digital Unix"* only. SRM, no ARC — so it can never boot NT, which needs
ARC. It was also **discontinued in 2015** and survives only on third-party
mirrors. VOM's `run_x11` is host-side X with the guest connecting out, i.e.
**no framebuffer to capture at all** — strictly unusable for this gallery.

## 2. The emulator: ES40-Emu/es40, built and driven here

[`ES40-Emu/es40`](https://github.com/ES40-Emu/es40) (GPL-2.0, active through
July 2026; changelog `4/30/26 - Windows NT support`).

**Builds clean on Debian 13, first try** — `./autogen.sh && ./configure &&
make -j6`, no patches. Deps: SDL3 (trixie has 3.2.10), libpcap, and pipewire's
`.pc` (SDL3's pkg-config wants it). All extracted into a private tree; nothing
installed on the host.

What ran, with a PNG for each step:

1. **SRM console with real emulated S3 Trio64 graphics** — `AlphaServer ES40
   Console V7.3-1`, `bus 0, slot 2 -- vga -- S3 Trio64/Trio32`, `P00>>>`.
2. **Keyboard works** through the SDL window; `show device` listed the disks.
3. **ARC/AlphaBIOS flashes** from the v7.3 firmware CD: `boot dqb0` → LFU →
   `update` → `Abios Updating to v5.71... PASSED / SRM v7.3-1... PASSED / srom
   V2.22-G... PASSED`. It persists to a 2 MiB `flash.rom` on clean exit
   (`%FLS-I-SAVEST`) — **a one-time, bakeable step.**
4. **AlphaBIOS runs graphically** — COMPAQ AlphaServer splash, `AlphaBIOS
   5.71-R1`, `System: AlphaServer ES40 / Processor: Digital Alpha 21264,
   800 MHz`, menu item `Install Windows NT`.
5. **Windows 2000 Alpha setup runs** — Express Hard Disk Setup made the FAT
   system partition, `SETUPLDR` loaded off the RC2 ISO, EULA, partition list
   (`4095 MB Disk 0 at Id 0 on bus 0 on atapi`), `Setup is copying files… 12%`.

Stopped at 12% deliberately — see cost.

### QEMU is closed, verified rather than assumed

`hw/alpha/dp264.c` has exactly one machine (`clipper`), loads an ELF PALcode
written for the emulator, comments `/* VGA setup. Don't bother loading the
bios. */`, and boots only via `-kernel`. Running it: `-M help` lists only
`clipper` and `none`; with no kernel the PALcode drops to a **stub** `>>>` that
answers every command with `got: <cmd>` and does nothing — no SRM command set,
no disk boot, no ARC; the 720×400 framebuffer stays blank forever. An
out-of-tree fork (`TheBrokenPipe/qemu`, branch `alphafix`) reportedly boots
64-bit Alpha NT build 2210 — **UNVERIFIED**, and irrelevant to 32-bit builds.

### Ruled out

| Emulator | NT? | Why |
|---|---|---|
| **FreeAXP / Avanti** | No | Windows-hosted; OpenVMS/Tru64 only, and **deliberately omits ARC** |
| **Personal Alpha / Alpha+** | No | SRM lineage, discontinued, unobtainable; the "reportedly ran NT" claim has no source |
| **Stromasys CHARON-AXP** | No | Commercial; OpenVMS/Tru64 only |
| **AXPbox** | Maybe | Claims the ES40-Emu ARC/S3 work is backported; its own wiki says "Windows NT: Untested" and its README concedes active development is at ES40-Emu |
| **SIMH / open-simh** | No | Alpha simulator unfinished — "requires ARC/VGA (not implemented)" |
| **AlphaVM Free** | **No** | No VGA at all (§1b) |

## 3. Media — all obtainable, publicly, today

**Firmware was not the blocker.** On real Alphas ARC is the classic trap; here
the v7.3 CD is a public HTTP fetch and the flash worked first time.

| Item | Size | sha256 (measured) | Class |
|---|---|---|---|
| Win2000 RC2 b2128 Alpha Pro (`W2PAS_EN.iso`, archive.org `w-2-pas-en`) | 400 334 848 | `d2a6e100…f23a26` | **leaked pre-release** |
| Alpha Firmware Update CD v7.3 (carries AlphaBIOS 5.71) | 341 374 976 | `47c32c4b…b08a3e` | vendor firmware, no redistribution grant |
| ES40 SRM bootstrap `cl67srmrom.exe` | 693 248 | `392546cd…2fc885` | vendor firmware |
| S3 Trio64 VGA BIOS `86c764x1.bin` (86Box roms) | 32 768 | `8f50988a…203ecd` | vendor ROM dump |

Also located, not fetched: NT 4.0 Workstation retail ISO — and note **NT retail
CDs are multi-architecture**, carrying `\ALPHA` beside `\I386`, so there is no
separate "NT 4.0 for Alpha" SKU to hunt. NT 4.0 SP6a `[DEC Alpha]` and Win2000
RC1 b2072 Alpha also exist on archive.org.

**Two traps worth writing down:**

- **The corrupt-ISO trap is real.** An incomplete RC2 dump with a truncated
  `SETUP.EXE` has circulated from BetaArchive since 2011 and will not install.
  The 2023-06-26 archive.org upload above is the fixed one — and this run proves
  that copy's `SETUP` works.
- **RC2 is timebombed.** Setup's own first screen says so: *"an Evaluation
  version … which contains a time limited expiration"*. That is an operational
  hazard for a permanent exhibit, not a licence footnote. Mitigation is cheap —
  es40's config has a `time = "YYYY-MM-DD"` knob pinning the guest TOY clock at
  launch, so a tile would set late 1999 every start. **UNVERIFIED** that the
  timebomb is satisfied by clock pinning rather than an install-date-relative
  check.

**Licence posture.** Unlike `winxp`, this is **not blocked on operator-supplied
licensed media** — no purchased disc, and setup never asked for a key before the
run stopped (**UNVERIFIED** whether the GUI phase does). But the class is worse
in a different direction: RC2 is a *leaked pre-release Microsoft build*. Record
URL + hash + class in `ASSETS-MANIFEST.md`, commit no bits. The genuinely
operator-local decision is whether the gallery is comfortable exhibiting a leaked
build at all — the existing OS/2, Win9x and Kickstart stance covers
preservation-class material, and this is a step beyond it.

## 4. One station, not two

**`w2kalpha` (Windows 2000 RC2 for Alpha).**

- The museum story is unique to it: **the last Alpha build Microsoft ever
  released**, a shipped product that never shipped. NT 4.0 Alpha is "NT 4, but
  Alpha" — a fact the placard states and the screen does not.
- Both would need separate checkpoints but share device set, backend, ARC firmware
  and boot path. With `nt4` and `win2000` already on the wall, adding both Alpha
  versions puts **four near-identical NT-family desktops** in the lineup.
- **NT 4.0 is the safer fallback, not the primary:** es40 rates NT4 as plainly
  working "with graphics" while Win2K RCs need "some effort", NT4 has **no
  timebomb**, and SP6a Alpha exists so it can reach a defensible final state.

## 5. What the exhibit shows — and the design decision that decides it

This is **not** a re-skin of `nt4`/`win2000`, but the reason is the **boot path**,
not the desktop.

Visibly Alpha, screenshot-proven: the `AlphaServer ES40 Console V7.3-1` SRM
banner and `P00>>>` prompt with a PCI probe listing `S3 Trio64/Trio32` and
`Acer Labs M1543C IDE` — a DEC minicomputer console nothing else in the lineup
has; **AlphaBIOS 5.71-R1** with the red COMPAQ AlphaServer logo, reporting the
`Digital Alpha 21264, 800 MHz`, its menu reading `Install Windows NT`, its About
box crediting `ARC Multiboot` and `X86 BIOS Emulation`; and the Alpha-specific
install shape where AlphaBIOS *itself* partitions the disk and demands a FAT
system partition before handing off to `SETUPLDR`. Nothing on the x86 wall does
that.

The **desktop** is probably indistinguishable from `win2000` (**UNVERIFIED** —
the run stopped before it). Expect `winver` → `5.00.2128` and System Properties
naming the 21264 as the only in-desktop tell.

**So the exhibit's value is in the first 60 seconds, not the desktop** — which is
awkward, because a station's idle screen is a *steady state*. Hence the one design
decision that determines whether this station is worth building:

> **Capture the checkpoint at the AlphaBIOS screen**, not the desktop. Then `reset`
> returns a visitor to the COMPAQ AlphaServer splash and the exhibit carries
> itself. This is exactly the `plus4` move (`10ae428`, "bake the golden at the
> machine's power-on screen") — and note it is *not* the pattern the operator
> rejected there, which was capturing **inside an application**. A firmware screen
> is the machine's own power-on state.

## 6. Cost

- **Tier 3**, bridge/captured-X shape: the es40 SDL3 window inside a Debian-X
  kiosk, built into the station overlay (the `amiga.sh`/FS-UAE precedent) because
  es40 is not in the frozen `bridge-base.qcow2`. It needs **SDL3, which bookworm
  lacks** — the bridge seed's Debian version must be checked. **UNVERIFIED.**
- **~330–390 MB RSS for es40 and ~101 % CPU — one core saturated
  continuously.** It does not idle down the way a QEMU guest does. With the
  kiosk, expect ~1.3–1.8 GB total: in line with other kiosks, but with a
  **permanently busy core**. That is the real capacity cost and the strongest
  argument for keeping this to one station.
- **Install time 4–10 hours, not the ~20 minutes upstream claims.** Measured
  2 % → 8 % → 12 % over ~35 min and decelerating. Three fixable causes: **ASMJIT
  was off** (es40's autoconf/cmake path defaults it off; changelog claims ~2.5×),
  the CD was on **ALi IDE/ATAPI** where upstream uses Symbios SCSI, and the host
  carried load 12–17 from other lab work.
- **Reset:** the kiosk qcow2's `loadvm golden` works as for other kiosks;
  es40's `flash.rom` and disk image live inside that snapshot, so visitor writes
  and any dirty-shutdown chkdsk vanish on reset.
- **Input:** keyboard proven. Pointer untested — es40 has a mouse with a
  `mouse.speed` knob; the §5.1 frame-sampling pacing trap may apply since SDL
  polls per frame. **UNVERIFIED.**
- **Effort:** ~2–4 sessions. Build trivial (proven), ARC flash ~15 min of
  scripted keystrokes (proven). The install is the cost.

## 7. Biggest risk, and the experiment that retires it

**Risk:** the install completes but the station is not viable in steady state —
the timebomb refuses to boot on a wall in 2026, the GUI phase stalls on a key or
driver, or the desktop is indistinguishable from `win2000` and the exhibit
collapses to a placard.

**One unattended session, ~4 h wall clock, no babysitting:** rebuild es40 **with
ASMJIT enabled**, move the CD to the **Symbios SCSI** controller, set
`time = "1999-11-01"`, and run the install to completion on quiesced labhost.
Screenshot three things: the finished desktop, `winver`, and a **fresh cold boot
with the clock pinned**. Those three frames answer the timebomb, the GUI phase
and the "is it visibly Alpha" question at once — and if the last answer is "no",
the fix costs nothing, because the AlphaBIOS screen is already proven.

## 8. The fallback if Alpha is declined

**Windows NT 4.0 on MIPS**, from the *same* retail ISO's `\MIPS` tree. QEMU has
a stock, in-tree, maintained `mips-magnum`/Jazz machine **with ARC firmware** —
the exact firmware family NT needs — so it would be a Tier 2–3 tile in the
gallery's normal QEMU shape with a genuinely different boot screen. **UNVERIFIED
and reputedly finicky**, but it is the obvious next study, and the Virtual OS
Museum does catalogue **NT 4 for MIPS** as a working installation
([`vom-reference.md`](vom-reference.md)). PowerPC NT (PReP) is the third option
and the least supported anywhere.

Evidence: `/data/vms/soltest/ALPHA-nt/` on labhost (1.1 GB, inert) — es40
source and binaries, the four media files, the flashed `rom/flash.rom`, the
partial install image, and screenshots `shot1`–`shot39`.

## 9. Install session, 2026-08-10 — the §7 experiment, completed

Every UNVERIFIED from the study above is now resolved. Evidence:
`/data/vms/soltest/ALPHA-nt/` (`run/` live rig, `milestones/m2-desktop/` the
clean installed pair, `run/perf-shot*.png` + `gui-*.png` + `boot-*.png` +
`cold-*.png` the framebuffer record).

### What changed vs the feasibility run, and what each change bought

| Change | Why | Result |
|---|---|---|
| `--enable-asmjit` (needs `git submodule update --init third_party/asmjit`; a stray partial tree blocks the clone — delete it first) | changelog claims ~2.5× | text-mode file copy **35+ min for 12% → 100% in ~3 min** (with the two changes below) |
| Both disks on `sym53c810` (system `disk0.0`, CD `disk0.4`); `ali_ide` left implicit with no drives | upstream #169: "IDE does not see much love" | matches upstream's reference layout in the zx.net.nz guide |
| **`ali_usb` removed** | upstream #114: makes the NT System process spin at 100% | the feasibility run's crawl explained |
| `time = "1999-11-01"` + `arc_year_compat = true` | RC2 timebomb | winver: "Expires **1/18/2001** 1:06 AM" — expiry is fixed at install time; the pinned TOY keeps every boot ~14 months inside the window |
| **`memory.bits = 29` (512 MB)** | GUI setup died at 256 MB: *"The security subsystem could not be initialized"*, `LsaOpenPolicy returned c0000205` (=STATUS_INSUFF_SERVER_RESOURCES) | GUI phase completes; winver sees 524,160 KB |

### The knowledge that was nowhere in our logs

- **SRM → AlphaBIOS is the `arc` command** at `P00>>>`. `set os_type nt` does
  not exist on ES40 firmware (real hardware included — Compaq never supported
  NT on ES40). Sources: zx.net.nz es40 guide; virtuallyfun "Flashing the ES40".
- **Unattended entry**: `edit nvram` → `10 show dev` / `20 arc` → Ctrl+Z
  ("13 bytes written"). SRM runs the script at every power-up. **Proven**: a
  cold es40 start reached the Windows desktop with zero input.
- A *warm* restart (setup reboot, Windows restart) keeps ARC resident — only a
  cold es40 start passes through SRM.
- es40 serial ports block startup until BOTH have a client; `run/start.sh` +
  `run/pumps.py` handle the ordering (the pumps retry until the port opens).
- The es40 binary needs `LD_LIBRARY_PATH` to the extracted-debs tree —
  RUNPATH only covers direct deps, and `libpipewire` is SDL3's dep, not ours.

### Install answers (for the future builder / re-install)

NTFS on C:, D: (6 MB FAT ARC partition) untouched. Name `Kernel Hive`,
machine `W2KALPHA`, blank Administrator password, **auto-logon** accepted from
the Network Identification Wizard's default. "Show this screen at startup"
unticked. **No product key was ever asked** — text or GUI phase. US
locale/keyboard. Total wall time SRM→desktop ≈ 75 min on a loaded host
(~load 8), dominated by the GUI phase's single-core stretches (COM+
registration alone ~15 min).

### Re-install = restore, not re-run

`milestones/m2-desktop/{nt.img,flash.rom}` is the cleanly-shut-down installed
pair (sha256 `4929bc06…` / `10ef3791…`). The tile builder should consume this
pair as a cached asset (the `win2000.sh` philosophy — its header explains why
unattended re-install is the wrong tool). The Alpha answer-file path
(`OSLOADOPTIONS /unattend`) is untested on es40 and stays unexplored.

### Still open for tile integration

- Pointer: **verified working 2026-08-11, see §10** — including the
  `mouse.absolute` fork patch any absolute-pointer transport will need.
- The permanently-busy-core cost stands; `kleinmatic/es40:wtint-idle` is the
  only known idle-detection work (WIP, unreviewed) — see the 2026-08-10 GH
  ecosystem scan in the session transcript.
- Fork exists: **github.com/Wnt/es40**, pinned at upstream tip `a9bda96` +
  asmjit `0bd5787`. Zero source patches so far — everything above is config.
  Source edits go onto the fork as commits (operator: no .patch files).
- Kiosk/bridge wrapping, SDL3-on-trixie base check (§6), checkpoint capture at the
  AlphaBIOS screen (§5) — unchanged, still the plan.

## 10. Optimization session, 2026-08-11 — profiling, benchmark harness, input

Goal: make the emulator fast enough that the 75-minute install feel never
reaches a visitor. Method: measure first. All numbers below on a loaded host
(load 8–13) — relative distributions are trustworthy, absolute times are not.

### The boot benchmark harness (built, validated)

`/data/vms/soltest/ALPHA-nt/bench/bench.sh <name> [--binary PATH]
[--until CKPT] [--timeout S] [--interval S] [--record-all] [--keep]
[--hold-secs S]` — boots a throwaway ZFS-clone of the `m2-desktop` pair under
a private Xvfb and framebuffer-detects checkpoints against
`bench/refs/` (RMSE vs reference frames, thresholds in `manifest.json`):

| checkpoint | means | validated first-hit |
|---|---|---|
| `serial` | es40 alive (serial banner) | 0.2 s |
| `srm` | SRM console idle at `P00>>>` | (only hit when autoboot is absent) |
| `arc` | AlphaBIOS first screen | 158.9 s |
| `kernel` | W2K splash + progress bar | 202.2 s |
| `desktop` | icons + taskbar | 307.3 s |

Up to 4 concurrent runs (atomic slot claim → display `:80+N`, serial
`22004+10N`); teardown via `clone-guard kill-pidfile`; per-run `results.json`
+ append to `bench/results.log`; `ES40_EXTRA_ENV` injects env (SDL hints)
into es40. `--until kernel` is the fast A/B loop (~3.5 min); `--hold-secs`
keeps the guest alive after the target checkpoint for interactive tests.

**Boot anatomy:** 189 s of the 307 s is firmware — SRM memory test ~155 s +
a 30 s AlphaBIOS OS-chooser countdown (shrinkable in AlphaBIOS setup; guest
NVRAM change, not done). Windows itself: ~105 s.

**Trap found:** `milestones/m2-desktop/flash.rom` predates the §9 nvram
autoboot script — a guest restored from the milestone pair parks at `P00>>>`
forever. The live rig's `run/rom/flash.rom` (persisted 23:00) has the script;
the bench copies that one. A restore consumer must do the same or re-enter
the script.

### Where the time goes (perf, 400 Hz dwarf call-graphs)

**Idle at desktop** (`/tmp/es40-idle.perf.data`): the CPU thread spins at
100% executing the guest's idle loop. Self time: ~35% dispatch
(`CAlphaCPU::execute` + `jit_run`), ~21% JIT-emitted code, 9%
`jit_hw_mtpr` (PAL traffic from the NT idle loop), ~15% software TLB
(`FindTBEntry` + `virt2phys` + `get_icache`), ~3% VGA repaint. JIT codegen is
NOT the bottleneck — the C++ around it is. (Idle-sleep itself is a non-goal
for the station: the exhibit pauses when unwatched; operator 2026-08-11.)

**During boot** (`/tmp/es40-boot.perf.data`, SRM phase): ~30% of samples in
the media-hotswap polling machinery — `CFloppyController::check_state()`
runs in the main loop and, per iteration, takes the controller recursive
mutex, then per drive takes another mutex and constructs+destroys a
`std::deque` (`service_pending_media_actions` → `take_pending_actions`),
just to find the mailbox empty. `pthread_mutex_lock` 9% + `cfree` 9% +
`malloc` 6.7% + deque `_M_initialize_map` 3.3% all trace here.

### Optimization queue (each to be A/B'd with the bench)

**Priority reframe (operator, 2026-08-11):** the gallery station will sit in
instant-ready (desktop visible, `loadvm golden` restore < 5 s), so visitors
never watch it boot. Boot-phase wins are *operator velocity* (bench A/B
loops, checkpoint recaptures); the visitor-facing metric is **interactive
responsiveness at the desktop** — weight the idle profile (#2, #3) over the
boot profile.

1. ~~**Mailbox fast-flag**~~ **DONE, −24.7%** — see A/B №1 below.
2. **Dispatch overhead**: why is `execute()` still 35% with ASMJIT on.
   `config_debug.h` records the 2026-06 finding that the trace tier is a NET
   LOSS (92 vs 120 VUPS, left dormant) and names the real lever:
   poly-successor direct chaining + register allocation in the block JIT.
3. **Software TLB fast path**: small direct-mapped host-side cache in front
   of `FindTBEntry` (its fallback is a linear scan over the whole TB).
4. **Build flags**: autoconf default is `-g -O2 -mavx2 -mfma`; try `-O3`,
   LTO, PGO on a boot profile.
5. VGA/llvmpipe: only ~3% — last.

### A/B №1 — media-mailbox fast-flag (2026-08-11): −24.7% to kernel

Fork commit `6a525d1`: `std::atomic<bool> actions_pending` on the mailbox,
set/cleared under the mailbox mutex, read lock-free. Empty-mailbox poll =
one acquire load; `CDiskFile::check_state` / `service_pending_media_actions`
bail before the recursive mutex and the deque (which heap-allocated even
when empty); `CFloppyController::check_state` bails before
`controller_mutex` via a new `CDisk::has_pending_media_actions()` virtual.
The poll tax is a *boot-phase* cost: `SingleStep()`'s tight loop (ROM
decompress + SRM) sweeps `check_state` per instruction batch, while
steady-state `Run()` sweeps only every 100 ms — so the win lands exactly
where `--until kernel` measures.

Bench: 3 interleaved runs per arm, control = `es40.652f7c2`
(`a2a21bde…`, the pre-change build preserved next to `es40.baseline`),
flag = `3745cfb2…`; every run's `binary.sha256` verified. Loaded host
(load 7–9); per-run es40 CPU time sampled from `/proc/<pid>/stat`
(`bench/ab-flagfix.cpu`, driver `bench/ab-flagfix.sh`, log
`bench/ab-flagfix.log`).

| metric (kernel ckpt) | ctrl ×3 | flag ×3 | delta |
|---|---|---|---|
| wall-clock | 199.6 / 197.2 / 199.2 (198.7) | 149.8 / 149.6 / 149.4 (149.6) | **−49.1 s, −24.7%** |
| es40 CPU s | 208.4 / 205.5 / 204.9 (206.3) | 156.8 / 156.2 / 154.0 (155.6) | **−50.6 s, −24.6%** |

Wall and CPU deltas agree, so this is removed work, not host-noise luck.
(`arc` first-hit on flag3 read 86.8 s vs ~106.5 s on flag1/2 — arc RMSE
detection variance; the kernel checkpoint, spread 0.4 s, is the metric.)
Vtable note: the new virtual on `CDisk` means incremental builds against
stale objects are ABI-broken — clean rebuild after pulling this commit.

### A/B №2 — `-O3` (2026-08-11): +2.4%, adopted

3 interleaved `--until desktop` runs per arm vs the fast-flag `-O2` build,
pre-pause epoch, binary-sha-verified. Kernel 151.0→147.3 s (zero overlap
between arms), desktop −2.3%, es40 CPU −2.8%. Adopted: configure on labhost
now bakes `-O3` (`CXXFLAGS="-g -O3"` at configure time). LTO/PGO remain
open as separate experiments.

### A/B №3 — TLB per-page hint (2026-08-11): NULL, reverted

Verified hint cache in front of `FindTBEntry`'s linear scan. Boot A/B (3
**concurrent pairs**, post-pause epoch): paired CPU deltas +0.6/−0.3/−0.5 s
on ~200 s — noise. Paired 60 s idle-at-desktop perf profiles: FindTBEntry
absent above 1% in both arms, `virt2phys` identical 3.7% — with `-O3`
inlining the scan is no longer a measurable cost. Patch parked on fork
branch `tlb-hint-experimental` with the null result in the commit message.
Fresh idle shape (the real #2 target): `execute` ~21%, `jit_run` ~14%,
`jit_hw_mtpr` ~9%, `jit_read` ~8–10%.

### Epochs, pause, and the AlphaBIOS NVRAM fix (2026-08-11)

labhost paused on operator's order (52 station units stopped, debridge
experiment + openvms killed; restore list
`bench/../quiesced-units-20260811.txt`; k3s untouched). Quiet labhost + turbo
moved desktop runs 250→180 s on identical binaries — **bench numbers are
epoch-bound; only compare within an epoch** (governor already
`performance`, turbo on). A/B arms now run as concurrent slot pairs to
share conditions.

AlphaBIOS CMOS changes applied on the live rig via `DISPLAY=:64 xdotool`
(F2 setup → Auto Start Count 30→5 s; F6 Advanced → Power-up Memory Test
Full→Disabled; F10 save; `flash.rom` persisted 02:47:51, bench inherits it):
cold-boot **kernel 118.7→82.8 s, desktop 179.5→140.4 s**. A desktop bench
run is now ~3 min, `--until kernel` ~1.5 min. Bench refs unchanged (`arc`
still detected at 65.9 s; 5 s countdown chosen over 0 so the chooser frame
stays catchable at the 2 s poll).

### The 24h mission (2026-08-11, operator offline): 2× GOAL ACHIEVED

Operator-set goal: a heavy scripted UI interaction (Computer Management
launch — MMC + snap-ins, disk IO + CPU) in HALF the baseline time,
framebuffer-timed, repeatable. Result: **24.4 s (n=7 baseline) → 10.30 s
± 0.25 (n=8) = 2.37×**, fork commit `0e22e9f`, every iteration a full
cold boot from the identical m4-warm seed disk.

The road there (all measured, `uibench/` harness + JIT_STATS builds):

1. **Savestate fixed end-to-end** (`ab75e70`, `d73e4dc`): restore hang
   (get_primes(0)), BAR re-registration, S3 video state + VRAM, SDL
   texture loss (S3 thread now pauses, never recreates). New: menu-5
   atomic save-and-exit, `ES40_RESTORE` instant resume (desktop in
   seconds, skips all firmware). Known residue: an instant-resumed guest
   wedges under heavy load (CM freezes mid-load; cold boots fine) —
   suspected unrestored wall-clock timer baselines; restore-benching
   parked, cold mode used throughout.
2. **PGO +10% / LTO null** on the launch metric (PGO re-applies as a
   packaging step; iteration loop stays plain -O3).
3. **JIT_STATS revealed the gate storm**: compiled 53% / interp 22% /
   dispatch 25%; 3.9M chain exits per 100M instr, 100% "gate" —
   check_int kicked by every NT IRQL write (IER rewrite per spinlock),
   check_timers gating natives through ~100 interpreted instructions per
   delayed IRQ. Fixes: deliverability-gated kicks (pending AND enabled,
   the delivery poll's exact predicate) + chain-granular countdown
   drains. Idle throughput 140 → ~300 MIPS, compiled 98.5%. Launch time:
   UNMOVED — which exposed:
4. **The launch is a cold-code event**: slow intervals showed ~390k
   first-sight block compilations per 100M instr (29 MIPS, dispatch
   66%) — run-once DLL/registry init code paying full compile cost for
   zero reuse. Fix: `m_cold_seen` — compile only on second encounter
   (16K direct-mapped phys-tag filter). Launch: 24.4 → 10.3 s.

Measurement discipline notes: CM-launch noise is ±2.5 s — n=3 arms
cannot resolve <10% effects (the PGO/gatekick early reads were
noise-dominated); the JIT_STATS time-split was the reliable compass.
uibench detection is crop-based (taskbar strip + MMC tree pane) after
whole-screen RMSE broke on the guest's Active Desktop Recovery
background (cosmetic damage from hard kills; consistent across
iterations, A/B-valid; clean up at next guest session).

Emulator/guest tuning research digested in
[`es40-tuning-research.md`](es40-tuning-research.md) — headline items:
JIT large pages already active on labhost (THP `madvise`); remove
`ali_usb` for W2K guests (known System-process USB-poll burn); `idle_nap`
exists upstream for WTINT; savestate format is same-build-only raw struct
dumps with the JIT cache deliberately excluded (restore-then-recompile is
safe by design); W2K's built-in Telnet Server is the planned guest command
channel for load scenarios (operator direction).

### Input: pointer verified, VNC operator access, `mouse.absolute`

- **PS/2 pointer works in the guest** (§9 UNVERIFIED closed): click-to-
  capture, Ctrl+F10 releases; injected deltas land ~2× (W2K "fast" pointer
  acceleration).
- **Operator VNC**: `alpha-nt-vnc64.service` = x11vnc on `:64`, port 5964,
  `-rfbauth run/vncpass`. macOS Screen Sharing (a) refuses passwordless VNC
  at session init, and (b) composes Option+letter into a glyph keysym, so
  Alt-combos never arrive — use TigerVNC viewer for those; Ctrl-combos fine.
- **Corner-dive, root-caused**: SDL relative mode re-centers the hidden
  pointer every event, so an absolute XTEST stream (x11vnc) becomes
  center-relative deltas → cursor pins in a corner. With
  `SDL_MOUSE_RELATIVE_MODE_CENTER=0` absolute injections are dropped
  entirely (relative injections work 1:1). Neither mode suits VNC.
- **Fix = first fork commit** `652f7c2` (pushed to github.com/Wnt/es40):
  `gui { mouse.absolute = true; }` skips SDL relative mode on capture and
  derives PS/2 deltas by differencing successive window positions; baseline
  resets on capture toggle/focus loss. Default off. The live rig adopts it
  on its next es40 restart (cfg edit staged); the bench template already
  carries it.
