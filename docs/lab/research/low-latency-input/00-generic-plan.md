# Low-latency guest input — generic architecture plan

Status: **RESEARCH / PLANNING (2026-07-15)** — this doc is the shared baseline; per-OS-family
deep plans are sibling files in this directory (`win9x.md`, `win16.md`, `os2.md`, `solaris.md`,
`9front.md`, `templeos.md`), plus cross-cutting `qemu-transport.md` and `measurement-and-host.md`.

## Goal
Cut host→guest **input latency and jitter to the practical minimum** for the six warpd stations
(solariscde, ninefront, win95, win311, os2warp, templeos). Pointer positioning is the
latency-critical realtime path; keyboard is second; **command-exec is NOT latency-critical** and may
stay on a simpler/slower channel. The old guests have poor preemptive scheduling, so a usermode
agent competing for CPU is a major, load-dependent jitter source — we want input handled in kernel
space where it preempts everything.

## Why the current design is slow (latency budget of today's warpd)
Today: host → (TCP over SLIRP user-net **or** emulated UART serial) → guest **usermode** agent
(`warpd.py`/`.c`/`.HC`, ASCII protocol) → guest pointer API. Latency/jitter sources, worst first:
1. **Guest usermode scheduling** — the agent must be *scheduled* to read the socket/serial and act.
   On cooperative/weak-preemptive OSes (Win16/9x, OS/2, old Solaris) this stalls behind other work.
2. **Transport stack** — SLIRP has a full userspace TCP/IP stack in QEMU + the guest's TCP stack +
   NIC emulation; serial is byte-serialized UART emulation + the guest UART driver. Both traverse
   deep, non-realtime driver paths.
3. **ASCII parse** — minor, but non-zero and branchy.

## Target architecture (the straw-man every per-OS plan designs against)
Replace the realtime path with a **paravirtual shared-memory input device + a tiny guest kernel
driver** that injects events in an interrupt handler:

```
streamhost (Rust, host)                QEMU device model                 guest
   produce input event  ── backend ──► write into shared-mem ring ──► [PCI BAR mapped]
                                        raise INTx/MSI doorbell    ──► guest ISR drains ring
                                                                        └► inject ABSOLUTE pointer/
                                                                           buttons/keys at the lowest
                                                                           kernel layer (preempts usermode)
```

Key properties:
- **No network stack, no usermode reader.** The guest side is a kernel driver; its ISR runs at
  interrupt priority and injects directly into the OS pointer/keyboard subsystem.
- **Shared-memory ring, not MMIO-per-read.** The event ring lives in memory the guest maps
  *cacheably* (ivshmem-style BAR, or guest-RAM the device DMAs into) so the driver reads its own RAM,
  not trap-heavy MMIO. A doorbell **interrupt** (INTx for ancient OSes; MSI only if supported) wakes
  the driver; between doorbells the driver does nothing (no polling burn).
- **Binary, fixed-layout protocol** — zero parsing.

### Straw-man device + protocol (qemu-transport.md finalizes)
Two transport options to evaluate (T1): **(A)** QEMU's existing **`ivshmem`** (shared-mem BAR +
doorbell IRQ — less QEMU code) vs **(B)** a **custom minimal PCI device** (`gallery-hid`, vendor
`0x1b36`, a new device id — full control, DMA ring). Straw-man record (16 B, little-endian):

| off | field | notes |
|----|--------|-------|
| 0  | u8 type | 1=ptr-abs, 2=button, 3=wheel, 4=key, 5=exec-chunk |
| 1  | u8 flags | |
| 2  | u16 seq | loss/ordering detection |
| 4  | i16 x | absolute, normalized 0..32767 → guest maps to current display res |
| 6  | i16 y | absolute |
| 8  | u8 buttons | bitmask (L/R/M/…) |
| 9  | i8 wheel | |
| 10 | u32 aux | timestamp / keycode / exec length |
| 14 | u16 rsvd | |

Ring: producer index (host-written, guest-RO), consumer index (guest-written), N fixed slots.
Host enqueues via a QEMU backend (QMP command **or** a dedicated unix-socket the device reads —
T1 decides), writes the record, bumps producer, raises the doorbell. Guest ISR drains
consumer→producer, injects each, acks. **Absolute coordinates** sidestep the relative-mouse-
acceleration mangling that made the emulated-tablet path unreliable in the first place.

### Language policy (honor the preference order, but be realistic)
Use the **highest-preference language the target toolchain actually supports**:
- **Host / streamhost binding → Rust** (streamhost is already Rust).
- **QEMU device model → C** (QEMU idiom); *evaluate QEMU's experimental Rust device framework* (T1).
- **Guest kernel drivers → almost certainly C (+ asm hot paths)**: no Rust target/ABI exists for
  Win9x/Win16/OS-2/old-Solaris-x86/Plan 9 kernels. Each per-OS plan must **confirm** its toolchain
  and pick C or asm accordingly; TempleOS is **HolyC** (ring-0 native). Only claim Rust for a guest
  driver if you can show a real, loadable target — do not hand-wave it.

## Integration with the existing capture/checkpoint flow
The device is part of the station's **pinned device set**, and the guest driver is **captured into the
checkpoint** (auto-loads on boot), exactly like today's warpd agents. Adding a `-device` is a device-set
change → it lands with a **checkpoint recapture** (we already recapture checkpoints this migration). loadvm golden
must bring the guest back with the device present and the driver loaded + armed. Keep the emitted
launcher = the device-set ledger (AGENTS.md rule).

## Measurement & success criteria (measurement-and-host.md defines the harness)
- **End-to-end input latency**: host enqueues a pointer move at T0 → first framebuffer frame in which
  the cursor pixel changed (via QEMU `dbus`/screendump timestamps). Report p50/p95/p99.
- **Jitter under load**: same, while the guest runs a CPU-bound task (the realistic "competing
  threads" case) — this is where the kernel-ISR path should crush the usermode agent.
- **Baseline** the *current* warpd (TCP + serial) per station first, then target the new path.
- Success = a large, measured reduction in p95/p99 latency and jitter vs baseline; go/no-go **per OS**
  (some OSes may not beat warpd enough to justify the driver — record that honestly and keep warpd).

## Risk register (per-OS plans expand their own)
- **Driver loadability** varies hugely: TempleOS trivial (ring-0), 9front clean, Solaris/OS2 have real
  DDKs, Win9x/Win16 are the hardest (VxD/VMM-era). Some may be infeasible → fallback = keep warpd.
- **Absolute-pointer injection** on relative-mouse-era OSes (Win9x/16) may require injecting at the
  display-driver/cursor layer, not the mouse driver — research the exact lowest-latency injection point.
- **IRQ support**: ancient OSes → INTx (shared PCI IRQ) not MSI; confirm the guest can take our IRQ.
- **PCI enumeration** from the driver in each OS (config-space access, BAR mapping).
- **QEMU maintenance**: a custom device is ours to carry across QEMU bumps (like the fast-poll patch);
  ivshmem is upstream and cheaper — weigh in T1.
- **Effort vs payoff**: exec channel stays as-is unless cheap; focus effort on pointer/keyboard.

## Per-OS research-question template (every per-OS plan answers ALL of these)
1. **Driver model & toolchain**: what kind of kernel driver loads on this OS, built with what (name
   the exact toolchain on/for labhost), and in what language (Rust→C→asm, justified)?
2. **Transport binding**: how does the driver enumerate the PCI device, map the BAR/shared ring, and
   register + service the IRQ (INTx/MSI) on this OS?
3. **Injection point**: the *lowest-latency kernel path* to inject an ABSOLUTE pointer position +
   buttons + wheel (and keys) so the cursor/UI reacts — name the exact API/queue/subsystem, and how
   absolute coords map to the guest's display resolution.
4. **Auto-start & capture**: how the driver is installed + auto-loaded, and how it's captured into the
   checkpoint so it's armed after `loadvm golden`.
5. **Language decision** per the preference order, with the concrete reason.
6. **Effort, risks, fallback** (keep warpd if…), and a **phased implementation plan** (spike → driver →
   capture → measure).
7. **References**: driver-model docs, DDK/toolchain, example drivers, PCI/IRQ specifics for this OS.

## Workstream map (parallel research agents)
- **T1 `qemu-transport`** — device/transport decision (ivshmem vs custom PCI), the finalized binary
  protocol + ring/doorbell, host↔device backend, QEMU-C vs QEMU-Rust, checkpoint/device-set impact.
- **T2 `measurement-and-host`** — the latency/jitter benchmark harness, current-warpd baselines, the
  Rust streamhost integration + event source, success criteria/targets.
- **G-win9x** (win95/98), **G-win16** (win311), **G-os2** (os2warp), **G-solaris** (solariscde),
  **G-9front** (ninefront), **G-templeos** (templeos) — each answers the template above and writes a
  phased plan. Out of scope: the SSH stations (alpine/tinycore/haiku) — different model.
