# Low-latency guest input — research index

Investigation into cutting host→guest pointer/keyboard latency for the six
"warpd" stations (solariscde, ninefront, win95/win98se, win311, os2warp,
templeos), which at the time relied on a usermode TCP/ASCII input agent
competing for CPU inside old, poorly-preemptive guests. Dated 2026-07-15/16;
research/planning only — no live-lab change is made by these documents
themselves (later work landed some of it; see `docs/guests/*.md` and
`streamhost/docs/` for what shipped).

**Start here:** [`00-generic-plan.md`](00-generic-plan.md) — the shared
architecture and latency-budget analysis every other file in this directory
applies to one OS or one cross-cutting concern.

## Cross-cutting

- [`qemu-transport.md`](qemu-transport.md) — the authoritative QEMU device
  (`gallery-hid-pci`) and transport contract all per-OS plans bind to.
  Verdict: **design complete, implementation GO, fleet rollout conditional.**
- [`measurement-and-host.md`](measurement-and-host.md) — the measurement
  harness and streamhost-side integration plan. Verdict: **GO** for the
  harness, **conditional per station** for the new device path.

## Per-OS plans

| File | Guest | Verdict |
|---|---|---|
| [`solaris.md`](solaris.md) | Solaris 10 x86/CDE | conditional GO, bounded spike |
| [`spike-solaris-runbook.md`](spike-solaris-runbook.md) | Solaris | reproducible runbook — stages A-C **PASS**, stage D **PARTIAL** |
| [`qnx.md`](qnx.md) | QNX Neutrino / Photon | step-1 hard GO; PCI driver partial/blocked on licensed toolchain |
| [`9front.md`](9front.md) | 9front (Plan 9) | GO, gated by a short interrupt/ring spike |
| [`os2.md`](os2.md) | OS/2 Warp 4 | GO for a time-boxed spike; conditional for production |
| [`templeos.md`](templeos.md) | TempleOS | GO for a bounded spike; promote only if measurement justifies it |
| [`win16.md`](win16.md) | Windows 3.11 | conditional GO, bounded VxD spike; not yet production GO |
| [`win9x.md`](win9x.md) | Windows 95/98 | conditional GO, bounded VxD spike; no unconditional production GO |

None of these per-OS documents claim a shipped fleet-wide result; where a spike
was later promoted to production, the current state lives in the corresponding
`docs/guests/<os>.md` file, not here.
