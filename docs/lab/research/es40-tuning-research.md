# es40 tuning research digest — 2026-08-11

Two research passes (GitHub ecosystem + web/manuals) on making es40 and its
W2K-AXP guest fast. Condensed here; every claim carries its source. Items
already **APPLIED** or **VERIFIED** on our rig are marked.

## Emulator-side (es40 config / build)

- **JIT large pages — VERIFIED ACTIVE on our box.** Linux path is
  `mmap` + `madvise(MADV_HUGEPAGE)` (`src/jit/jitengine.cpp` `big_alloc()`),
  needs no privilege; requires THP mode `always` or `madvise`. Box is
  `madvise`; startup log shows `block cache 38 MB (large pages), trace
  cache 7 MB (large pages)`. Nothing to do.
- **`cpuN.idle_nap = true`** (upstream PR #148, merged 2026-07-23 — check
  whether our fork base includes it): naps the host thread on guest
  `CALL_PAL WTINT`; measured 100%→~5% host CPU on an idle OpenVMS guest.
  Caveats: no-op on multi-CPU configs; whether W2K AXP's HAL issues WTINT
  is UNVERIFIED anywhere — needs a 5-minute experiment. Note the operator
  declared idle-sleep a non-goal for the station (pauses when unwatched), so
  this is optional polish. github.com/ES40-Emu/es40/pull/148
- **Remove `ali_usb` from the config for W2K guests.** Two independent
  reports (issues #114, #169): W2K's System process pegs a CPU polling the
  emulated USB controller; removing the device made the guest idle
  properly. Our guest idles at ~9% guest-CPU — worth the experiment.
  Device-set change: do it BEFORE any checkpoint is captured.
  github.com/ES40-Emu/es40/issues/114, /issues/169
- **Keep `ali_ide` present even if empty; use SCSI for disks; define both
  serials or neither** — maintainer guidance, issue #169.
- **`cpuN.speed` is cosmetic** (reported to guest, not a throttle). PR #148.
- **`dec21143 { crc = false; queue = 1024; }`** are already the good
  defaults (FCS skip; RX queue depth fixed after issue #125).
- **JIT cache sizes are compile-time** (`jitengine.h`: block 38MB/CPU
  kCacheBits=18, trace kTraceBits=12) — not cfg-tunable.
- **Do not enable JIT_TRACES** (measured −26% dhrystone, 2026-06, recorded
  in `config_debug.h`) nor JIT_VERIFY/JIT_STATS/JIT_DISASM in production
  builds; JIT_STATS is the right tool for a dedicated measurement build.
- **AXPbox has `skip_memtest_hack`** (cfg-level SRM memtest skip) — our
  tree has compile-time `SKIP_SRM_MEMTEST` already on; AXPbox's variant is
  a possible reference if SRM time ever matters again.
  github.com/lenticularis39/axpbox
- **Savestate facts** (from source reading, `src/System.cpp` + component
  files): format = magic `0xa1fae540` + version 2.1 + per-component raw
  `fwrite(&state, sizeof(state))` dumps; mismatched magic/version refuses
  to load (no partial restore); **states are tied to exact struct layout —
  same-build (or layout-identical build) restore only**; the JIT cache is
  deliberately NOT saved — blocks revalidate against memory on lookup, so
  restore-then-recompile is safe by design. Only entry point: serial-console
  break menu option 3/4 → `autosave.axp` (hardcoded name). No savestate
  bugs on the tracker.
- **Fork network reviewed** (21 forks): everything interesting
  (idle_nap/WTINT, NT5 keyboard fix, FP fixes) already merged upstream;
  nothing unmerged worth pulling.

## Firmware (AlphaBIOS / SRM)

- **APPLIED 2026-08-11: `Auto Start Count` 30s → 5s** (F2 → CMOS Setup) and
  **`Power-up Memory Test: Full → Disabled`** (F6 Advanced) on the live
  rig; saved via F10, `flash.rom` persisted 02:47:51. Bench-validated on a
  cold boot: kernel 118.7→82.8s, desktop 179.5→140.4s. Not set to 0s so the
  bench's `arc` reference frame stays detectable at 2s polling. Source for
  menu paths: Compaq AlphaServer ES40 User Interface Guide (EK-ES240-UI.A01)
  §3.6.1–3.6.2.
- `SCSI BIOS Emulation` could in principle be disabled to skip probing, but
  we boot from SCSI — left Enabled.
- SRM-side: `set memory_test none` exists (§2.24.16) but our build already
  skips SRM memtest at compile time; SRM phase is ~65s of the boot.

## Guest OS (W2K build 2128) — to apply once a telnet channel exists

Operator direction 2026-08-11: before OS-level load scenarios, set up
**guest networking + the built-in W2K Telnet Server** so guest work is
driven/validated over text, not screenshots and emulated keystrokes.

De-bloat list for a museum guest (kiosk canon: joecutting.com/setupcomputer.php):
- Display Properties → Effects → uncheck menu/tooltip transition effects.
- Screensaver: none; power scheme: Always On.
- Services: stop/disable Indexing Service, Task Scheduler, Server (+
  Alerter/Messenger) if no file sharing needed.
- AutoAdminLogon: already active on our install.
- Leave the pagefile alone (disabling it is a known non-win).
- No Alpha HAL timer-rate tuning exists (x86-only lever) — dead end.

## Dead ends (do not re-research)

Upstream `doc/` is empty; the GH wiki is broken/stub; SourceForge pages are
2007-era stale; no savestate issues exist on the tracker; no SDL display
rate-limit knob exists; `icache = true` cfg option is dead (always on);
`palcode.vms.nohle` is VMS-only and moot under JIT; `arc_year_compat`
effect on NT is unknown (test both if clock weirdness ever appears).
