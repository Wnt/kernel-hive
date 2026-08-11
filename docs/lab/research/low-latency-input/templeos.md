# TempleOS low-latency input plan

Status: **RESEARCH / PLAN — 2026-07-15**  
Scope: TempleOS V5.03 station only; no driver, QEMU, checkpoint, or live-labhost changes were made.

## Verdict

**GO for a bounded spike; promote only if measurement justifies it.** The guest implementation is
high-confidence and unusually small: TempleOS is a 64-bit, ring-0-only, single-address-space system,
and its built-in HolyC compiler can install an interrupt function directly into the IDT. There is no
kernel-module ABI, privilege transition, linker, DDK, or user/kernel copy to solve. A realistic guest
port is about **250–400 lines of HolyC and 4–6 engineer-days** after the common QEMU device/protocol
exists (0.5–1 day spike, 1.5–2.5 driver, 0.5–1 bake, 1–1.5 measure/harden).

The performance case is less dramatic than for the other warpd guests. The existing `WS()` task also
runs in ring 0 and normally wakes within one 1 ms jiffy, so this change removes serial delivery,
poll-wake, and ASCII-parse variance, not a usermode scheduling barrier. Expect the PCI ISR portion to
be tens to low hundreds of microseconds under KVM, but do **not** promise a comparable end-to-photon
number: TempleOS's window manager is nominally 29.97 Hz, imposing a 0–33.37 ms phase wait before the
cursor can appear, and the tile streams at 30 fps. The spike is worthwhile because it is cheap and
the transport jitter should fall; a full bake is a no-go if p95/p99 end-to-frame does not improve
materially against serial warpd under both idle and CPU load.

The required guest language is **HolyC**, with a few inline x86-64 instructions only for memory
barriers if the finalized protocol needs them. Rust and hosted C/C++ are not loadable TempleOS kernel
targets. The lowest-latency absolute pointer injection point is an interrupt-safe integer-only helper
modeled on `MsUpdate`: update `ms.presnap`, `ms.pos`, `ms.pos_text`, `ms.lb`/`ms.rb`, wheel `ms.pos.z`,
mouse bits in `kbd.scan_code`, and the timestamp in the ISR. Do not feed `MsHardHndlr`; it is a
relative PS/2 packet decoder.

## Ground truth in this checkout

The shared baseline and 16-byte record/ring straw man are in the
[generic plan](./00-generic-plan.md). The current guest path is
[`warpd.HC`](../../../../streamhost/guest-agents/templeos/warpd.HC): a spawned HolyC task polls COM1's
16550 registers, parses ASCII `M/P/R/B` lines, and writes `ms.pos.x/y` and `ms.lb/rb`. Its checked-in
[README](../../../../streamhost/guest-agents/templeos/README.md) records framebuffer verification of
absolute motion and real clicks after `savevm`/`loadvm`.

The authoritative
[launcher](../../../../streamhost/stations/templeos/qemu-streamhost.sh) currently pins:

- QEMU `pc`, KVM, host CPU, 1 GiB RAM, one vCPU, std VGA, RTC local time;
- TempleOS V5.03 ISO plus an IDE qcow2 used only for `savevm golden`;
- COM1 backed by `serial.sock`, QMP, and D-Bus display;
- conditional `-loadvm golden`, a 4 ms QEMU D-Bus display poll, and no explicit NIC option.

A read-only check of CT950 on 2026-07-15 found QEMU 11.0.2 and confirmed the tile active on warpd.
QMP `query-pci` also exposed an important implicit device not obvious in the launcher: QEMU supplied
an e1000 at slot 3, INT A, IRQ 11. TempleOS has no networking and does not use it. The migration must
therefore add **`-nic none`** and pin the gallery device explicitly (proposed `bus=pci.0,addr=0x3`) so
the emitted launcher really is the device-set ledger and a legacy IRQ is not needlessly shared. That
is a device-set change and requires a cold checkpoint recapture.

There is another reproducibility gap to fix during the bake phase: the checked-in
[`golden-bake.sh`](../../../../streamhost/stations/templeos/golden-bake.sh) performs the desktop cleanup
and snapshot, but it does not currently define or spawn `warpd.HC`; the README describes an older
manual step. The new capture must explicitly compile and install the PCI driver before `savevm golden`.

## 1. Driver model and exact toolchain

TempleOS has no separable kernel-driver model. All tasks and dynamically compiled HolyC functions
share the kernel's address space and ring 0. Scheduling is cooperative between tasks, although
hardware interrupts still run immediately; the source describes an identity-mapped address space and
tasks running until they yield ([TempleOS scheduler source](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/Sched.HC#L1-L25)).

The deliverable is consequently a resident HolyC program, `gallery_input.HC`, not a `.ko`, VxD, or
ELF module. It will define packed-protocol accessors, the PCI probe/install routine, an `interrupt U0`
ISR, mouse/keyboard injection helpers, counters, and a diagnostic uninstall function. Installation
calls `IntEntrySet`, unmasks the selected PIC line, and leaves the compiled code resident. The checkpoint
RAM snapshot is the persistence mechanism.

Build and load it with the **TempleOS V5.03 in-guest HolyC JIT/AOT compiler at the `T:/Home>` REPL**.
The final-snapshot repository states that the source can only be compiled by the compiler present on
the booted CD and is HolyC plus assembly
([final TempleOS repository and toolchain note](https://github.com/cia-foundation/TempleOS/tree/c26482bb6ad3f80106d28504ec5db3c6a360732c)).
There is no separate DDK. Source remains vendored in `streamhost/guest-agents/templeos/`; the bake
automation types/loads that source into the live compiler, invokes `GalleryInputInstall`, validates
its counters, then snapshots the compiled code and IDT state.

No full OS or ISO rebuild is required. Rebuilding the pinned ISO just to add this driver would expand
scope and weaken reproducibility; the existing snapshot-resident model is both the smallest change
and already proven by warpd.

## 2. Transport binding

### Device choice and contract with the common transport workstream

TempleOS requires the custom minimal PCI device, provisionally `gallery-hid`, with **legacy INTx**.
Upstream `ivshmem-doorbell` is not an adequate interrupt transport: its BAR1 and peer doorbells use
MSI-X, while BAR2 is the shared-memory object
([QEMU ivshmem guest-interface specification](https://gitlab.com/qemu-project/qemu/-/blob/7425b6277f12e82952cede1f531bfc689bf77fb1/docs/specs/ivshmem-spec.rst)).
TempleOS V5.03 has neither an MSI/MSI-X subsystem nor an example that configures those capabilities.
`ivshmem-plain` plus polling is acceptable only as a BAR-mapping diagnostic; it fails the target
architecture's interrupt/no-polling requirement. Adding INTx to ivshmem would itself be custom QEMU
maintenance, with a less purpose-built interface than `gallery-hid`.

The TempleOS-compatible device profile should be deliberately old-PC-friendly:

- PCI vendor `0x1b36` and the device ID finalized by T1, conventional PCI header, INT A;
- **BAR0:** 4 KiB, 32-bit, non-prefetchable MMIO control/status/IRQ registers;
- **BAR2:** 4 or 64 KiB, 32-bit, prefetchable, QEMU RAM-backed shared ring;
- no 64-bit BAR requirement, PCIe requirement, bus mastering, DMA, MSI, or MSI-X;
- a level-triggered INTx cause bit which remains asserted until the guest drains and acknowledges it;
- migratable/resettable ring state and a generation/epoch handshake so `loadvm golden` cannot consume
  stale records from a host backend.

Keep control MMIO and ring RAM in different BARs. TempleOS provides an uncached alias for the lowest
4 GiB specifically for devices
([`UncachedAliasAlloc`](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/Mem/MemPhysical.HC#L138-L151));
BAR0 should use that alias, while BAR2 must use the ordinary identity mapping to request cacheable
ring reads. The page-table initializer maps physical space directly and reserves the additional 4 GiB
alias window
([page-table source](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/Mem/PageTables.HC#L5-L53)).
The spike must still verify the effective KVM/MTRR cache type; a default-WB page-table entry does not
by itself prove that a PCI-hole address is effectively WB. This split is the intended route to the
generic plan's “shared RAM, not trap-per-record MMIO” requirement, not an assumption that it worked.

### PCI enumeration and BAR mapping

At install time, scan `bus=0..sys_pci_busses-1`, device `0..31`, function `0..7` using
`PCIReadU16(bus,dev,fun,0)` and `PCIReadU16(...,2)` until the exact vendor/device pair is found. This
matches TempleOS's own PCI report loop
([`PCILookUpDevs`](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Adam/DevInfo.HC#L121-L149)).
The V5.03 kernel exports PCI BIOS-backed `PCIReadU8/U16/U32` and `PCIWriteU8/U16/U32`; the config
helpers serialize the non-reentrant 32-bit PCI BIOS call themselves
([PCI config access source](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/PCIBIOS.HC#L163-L263)).

Then:

1. Reject zero, all-ones, I/O, or 64-bit BAR values. This port deliberately requires two 32-bit MMIO
   BARs assigned below 4 GiB by SeaBIOS/QEMU.
2. Mask BAR0/BAR2 attribute bits with `& ~0xF`; read the PCI command word and set Memory Space Enable
   if firmware has not already done so. Do not set Bus Master—the guest only performs CPU loads/stores.
3. Validate BAR0 `MAGIC`, ABI major/minor, feature bits, ring size, record size 16, and generation
   before touching indexes. Fail closed to serial warpd on any mismatch.
4. Set `ctrl = dev.uncached_alias + bar0_phys`; set `ring = bar2_phys` using the identity-mapped
   pointer. Never use the uncached alias for the shared records.
5. Read PCI config offset `0x3D` and require interrupt pin A, then read `0x3C` for the BIOS-routed
   interrupt line. With `-nic none` and the proposed fixed slot, IRQ 11 is expected, but the driver
   must discover and range-check it rather than hardcode it.

BAR sizing by writing all ones is unnecessary and can perturb a live device; the ABI reports its own
ring size, and QEMU fixes the BAR sizes. Log the discovered BDF, BARs, pin, line, version, and
generation once during install, never from the ISR.

### IRQ registration and service

Use **legacy INTx**, not MSI. The primary path on the pinned i440FX/PIIX `pc` machine is the PIIX PIRQ
route to an 8259 IRQ; QEMU's PIIX model maps enabled PIRQ routes to PIC IRQs
([QEMU PIIX3 routing source](https://gitlab.com/qemu-project/qemu/-/blob/fdee2c96923dfd38aa7a264abb7de6d403f81c4d/hw/isa/piix3.c)).
For a discovered line 0–15, the vector is `0x20 + irq`.
Install `interrupt U0 GalleryInputIRQ()` with `IntEntrySet(vector,&GalleryInputIRQ,IDTET_IRQ)` and save
the old vector for diagnostic uninstall. TempleOS's API directly edits the IDT with interrupts masked
([`IntEntrySet` implementation](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/KInts.HC#L96-L133)).
Its keyboard and mouse drivers demonstrate `interrupt U0`, `CLD`, PIC EOI, IDT install, and mask
management
([keyboard IRQ](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/SerialDev/Keyboard.HC#L411-L439),
[mouse IRQ](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/SerialDev/Mouse.HC#L84-L104)).

For IRQ 8–15, clear its bit in PIC2 mask port `0xA1`; the master cascade is already enabled. For IRQ
0–7, clear the corresponding PIC1 bit at `0x21`. Preserve all unrelated mask bits. Initialization
order is: mask device IRQ in BAR0, install IDT entry, clear pending status, unmask PIC, enable BAR0 IRQ,
then request/resynchronize the current producer generation.

The ISR must:

1. `CLD`, read BAR0 interrupt status, and immediately return through the normal EOI path if the cause
   is not `RING_READY` (a defensive shared-line check).
2. Read producer with an acquire boundary, validate `producer-consumer <= N`, and drain no more than
   `N` fixed 16-byte records. Use explicit byte offsets instead of a HolyC class whose padding could
   silently change the wire layout.
3. Apply pointer records directly with the integer-only mouse helper; sum wheel deltas; preserve every
   button/key edge. Consecutive pure moves may be coalesced to the last position, but button, wheel,
   and key records must never be coalesced.
4. Publish consumer with a release boundary, acknowledge the BAR0 cause so QEMU deasserts INTx, then
   send EOI to PIC2 (`OutU8(0xA0,0x20)`) when applicable and PIC1 (`OutU8(0x20,0x20)`). Acknowledge the
   level device before the PIC to avoid immediate retrigger.

The finalized host/device protocol must define release/acquire ordering. HolyC has no portable C11
atomic model; use small inline x86-64 `MFENCE` helpers around producer/consumer publication if T1 does
not make stronger architectural guarantees. The tile is intentionally `-smp 1`, so the ISR cannot
race another guest CPU, but it can interrupt the window manager; update all mouse fields before
acknowledging. The ISR must not allocate, print, call PCI BIOS, sleep/yield, or invoke floating-point
code. Keep counters (`irq`, records by type, overflow, bad record, last sequence) in resident memory
for post-test inspection.

TempleOS includes a `PCIInterrupts.HC` lecture that installs user vectors and programs IOAPIC
redirection
([example](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Demo/Lectures/PCIInterrupts.HC#L1-L74)),
but it is a demonstration, not a PCI IRQ allocator and not proof that QEMU's PIRQ route works for this
new device. The spike must validate the BIOS interrupt-line byte, PIC mask/ELCR state, actual vector,
assert/deassert/EOI order, and repeated interrupts under KVM. If no reliable dedicated INTx route can
be established, inspect whether QEMU delivered the pin through an IOAPIC input. The only acceptable
IOAPIC alternative is a verified, pinned GSI using the lecture's pattern: install a user vector,
program that redirection entry to CPU 0, acknowledge with LAPIC EOI, and bake the exact machine/slot
route. TempleOS has no general PIRQ-to-GSI allocator, so an ambiguous or drifting route is a no-go;
MSI is not a credible fallback for V5.03.

## 3. Lowest-latency injection point

### Absolute pointer, buttons, and wheel

`MsHardHndlr` is **not** the injection point. It removes bytes from the PS/2 FIFO, decodes relative
`dx/dy/dz`, and mutates `ms_hard`
([relative handler source](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/SerialDev/Mouse.HC#L233-L270)).
Synthesizing PS/2 packets would reintroduce relative acceleration/scaling and extra queues.

TempleOS's canonical absolute setter is public `MsSet`; it validates coordinates, calls `MsUpdate`,
and synchronizes the hard-mouse shadow
([`MsUpdate` and `MsSet`](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/SerialDev/Mouse.HC#L9-L61)).
Calling `MsSet` directly in an arbitrary interrupt is nevertheless the wrong implementation because
the path uses `F64` scale math and hard-mouse bookkeeping. Existing hardware ISRs only capture bytes;
they do not call it.

Implement `GalleryMsInjectAbs` as the ISR-safe, already-scaled subset of `MsUpdate`:

- clamp final pixels and assign both `ms.presnap.x/y` and `ms.pos.x/y`;
- derive `ms.pos_text.x = x/FONT_WIDTH` and `.y = y/FONT_HEIGHT`, with the same text bounds as
  `MsUpdate`;
- set `ms.lb` and `ms.rb`, mirror `SCf_MS_L_DOWN`/`SCf_MS_R_DOWN` into `kbd.scan_code` with `LBEqu`,
  and set `ms.timestamp=GetTSC`;
- accumulate wheel into `ms.presnap.z` and `ms.pos.z`; set both `ms.has_wheel` and
  `ms_hard.has_wheel` so `WinMsUpdate` does not clear wheel capability on the next frame;
- do not modify `ms_hard.evt`, which would cause `WinMsUpdate` to replay/overwrite the direct state.

This is the lowest layer that still maintains the invariants consumed by the window manager. In
particular, motion message generation compares `old_ms.presnap` with `ms.presnap`; the current warpd
agent updates only `ms.pos`, which is sufficient to draw but is not a complete injection
([window-manager message path](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Adam/WinMgr.HC#L27-L185)).
TempleOS's state structures expose only left/right buttons in `ms`; the five-button array exists only
in `ms_hard`
([mouse/keyboard state definitions](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/KernelA.HH#L2958-L3021)).
Therefore v1 supports left/right and wheel. Middle/extra buttons are explicitly unsupported unless a
TempleOS UI semantic is found and tested; do not silently map middle to right as current warpd does.

Map the generic normalized coordinates without division overflow:

```text
x_px = clamp((U32(x_norm) * (GR_WIDTH  - 1) + 16383) / 32767, 0, GR_WIDTH  - 1)
y_px = clamp((U32(y_norm) * (GR_HEIGHT - 1) + 16383) / 32767, 0, GR_HEIGHT - 1)
```

For this tile `GR_WIDTH=640` and `GR_HEIGHT=480`, so endpoints are exactly `(0,0)` and `(639,479)`.
Use integer arithmetic only. The device must reject negative values even though the straw-man fields
are signed `i16`.

There is a sampling caveat: the window manager detects button transitions from global current/last
state. A press and release both completed before it runs can collapse into “up.” Raise INTx promptly
for each edge, never coalesce edges, and test short clicks. If real browser click durations still
collapse under load, v1 is not complete: either add a small edge queue integrated into the window
manager or keep serial warpd. Calling `TaskMsg` from the ISR without proving its locking/allocation
behavior is not acceptable.

### Keyboard

Keyboard is phase two and uses the existing scan-code queue, not direct `TaskMsg`. Convert the common
key record to the TempleOS/QEMU-compatible set-2 raw sequence, insert complete bytes into `kbd.fifo2`,
and run the same state transition logic as `KbdHndlr` (prefer a tiny factored helper if safely possible).
`KbdHndlr` updates the merged/unmerged down bitmaps and enqueues the 64-bit TempleOS scan code; the
window manager later drains `kbd.scan_code_fifo`
([keyboard handler and queue](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/SerialDev/Keyboard.HC#L441-L480)).
Do not call it with a lone `0xE0`; enqueue a complete make/break sequence first. Preserve the existing
PS/2 keyboard as rollback and as the source for keys not yet mapped. Command execution stays on the
serial path; it is explicitly not latency-critical.

### UI wake-up and hard latency floor

`WinMgrSleep` queues keyboard/mouse messages and then updates/draws on its periodic schedule; the
period constant is `1001/30000.0`
([window-manager period](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/KernelA.HH#L1479),
[sleep/update path](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Adam/WinMgr.HC#L220-L310)).
The spike should test setting `sys_winmgr_task->wake_jiffy=cnts.jiffies` after draining a pointer IRQ,
mirroring what `Refresh(force=TRUE)` does, but only keep it if source review and measurement show no
reentrancy or frame-pacing regression. It can wake a sleeping task; it cannot force a cooperatively
running task to yield. Report transport-to-state and host-to-frame separately so the 30 Hz display
floor is not misattributed to the PCI device.

## 4. Auto-start and checkpoint capture

There is no persistent installed system: TempleOS boots from the pinned ISO and the qcow2 holds a
full-RAM/device `golden` snapshot. The driver therefore auto-starts by being compiled, installed, and
armed **before** the checkpoint snapshot. `loadvm golden` restores its code, globals, IDT entry, PIC mask,
and task/kernel state. No polling task is required.

Proposed reproducible capture:

1. Land the common QEMU device first. Update the launcher in one change to add `-nic none`, the
   finalized shared-memory/backend objects, and `-device gallery-hid,bus=pci.0,addr=0x3,...`; keep the
   serial chardev for fallback/commands. Explicitly preserve all existing machine/CPU/RAM/VGA/IDE
   arguments.
2. Delete only the `golden` internal snapshot in the controlled recapture workflow, never the pinned
   ISO and never live labhost during development. Cold boot with the new exact device set.
3. Extend `golden-bake.sh` to feed the vendored `gallery_input.HC` through `sk.py`, compile it using
   the in-guest HolyC compiler, and call `GalleryInputInstall`. Generate one comment-free, physical
   REPL line per top-level definition (the existing typer cannot enter source newlines), press Enter
   after each complete definition, and fail on a compiler error. Avoid an undocumented manual step.
4. Before snapshot: assert one device found, expected ABI, two valid BARs, one routed INTx, a passing
   ring self-test, `irq_count>0`, correct absolute corners/center, left/right clicks, wheel, and key
   make/break. Capture the diagnostic line and a framebuffer proof.
5. Quiesce the ring, perform the device generation/reset handshake, clear pending interrupt status,
   and `savevm golden`. The custom QEMU device must have migration state for its BAR RAM, indexes,
   generation, mask, and INTx level; otherwise this phase is blocked.
6. Quit QEMU completely, launch a fresh process with `-loadvm golden`, reconnect the backend, require
   a new generation handshake, and repeat center/corner/click/key tests. This process-boundary test is
   mandatory; an in-process `loadvm` alone does not prove the backend can reconnect safely.
7. Keep `SH_POINTER=warpd` until the new path passes measurement. Promotion changes streamhost to the
   new backend but retains COM1 and `warpd.HC` as the one-flag rollback for at least one release.

A restored driver may have captured a stale host generation. It must not trust snapshot-era producer
indexes until BAR0 reports the current generation; reset consumer to the device-provided baseline,
ack stale causes, then arm. This handshake is part of the device ABI, not optional TempleOS polish.

## 5. Language decision (Rust -> C/C++ -> asm)

| Preference | Decision | Concrete reason |
|---|---|---|
| Rust | Reject for guest | No TempleOS Rust target, runtime, object loader, kernel ABI, or demonstrated way to load a Rust artifact into the V5.03 kernel. |
| C/C++ | Reject hosted C/C++; select **HolyC** | TempleOS's native compiler and kernel are HolyC. Standard C ABIs/toolchains do not produce a loadable TempleOS driver. HolyC is the only demonstrated, snapshot-resident ring-0 target. |
| Assembly | Small helpers only | HolyC supports inline x86-64; use it only for protocol memory fences or an unavoidable IRQ hot-path primitive. Writing the whole driver in assembly would increase risk with no credible latency gain. |

This complies with the policy's intent: choose the highest-level language that is actually loadable
on the target. Host streamhost remains Rust and the QEMU device remains C under their common plans;
those are outside this guest deliverable.

## 6. Effort, risks, fallback, and decision gates

Estimate assumes T1 has delivered a tested `gallery-hid` device, socket/backend, ring ABI, and QEMU
11.0.2 build. It excludes that cross-cutting work.

| Phase | TempleOS effort | Exit condition |
|---|---:|---|
| Spike | 0.5–1.0 day | PCI ID/BARs read, cacheable ring pattern validated, 1,000 INTx notifications delivered/acked with no storm or loss under KVM. |
| Driver | 1.5–2.5 days | Absolute motion, L/R, wheel, sequence/overflow handling, counters, then keyboard make/break; no allocation/FPU in ISR. |
| Capture | 0.5–1.0 day | Automated cold capture and fresh-process `loadvm golden` pass with backend re-handshake. |
| Measure/harden | 1.0–1.5 days | Idle/load distributions, short-click and overflow stress, rollback test, written go/no-go. |
| **Total** | **4–6 days** | Excludes common host/QEMU transport. |

Principal risks, in order:

1. **INTx/PIRQ correctness is the largest feasibility risk.** TempleOS has primitives and a lecture
   demo, not a resource-managing PCI driver framework. BIOS IRQ-line assignment, PIIX routing, PIC
   trigger mode, device deassert-before-EOI, and sharing must all work under the pinned QEMU/KVM
   machine. Removing the unused implicit e1000 and pinning the slot reduces but does not eliminate it.
2. **Benefit may be too small.** There is no user/kernel boundary today, and the 29.97 Hz guest UI plus
   30 fps stream can dominate. A technically successful driver is still a no-go if p95/p99 does not
   materially beat serial warpd.
3. **Snapshot/backend coherence.** External shared memory, indexes, interrupt level, and generation
   can diverge across `loadvm`. Missing QEMU VMState or a weak epoch protocol can cause stale input or
   an interrupt storm immediately after reset.
4. **Button edge collapse.** TempleOS samples mouse globals. Press+release inside one window-manager
   interval may vanish; stress this explicitly and do not claim completion from motion alone.
5. **Cache/order bugs.** Using the uncached alias for BAR2 destroys the transport advantage; using the
   cached identity map for BAR0 can hide device state. Protocol fences and separate BARs are required.
6. **ISR safety.** Calling `MsSet`, printing, allocating, using PCI BIOS, or doing floating-point work
   from the interrupt risks state corruption or long interrupt masking. Keep the handler bounded and
   integer-only.
7. **Device-set drift.** Checkpoints are tied to exact QEMU devices. The launcher, capture script, snapshot,
   and deployment must change atomically.

Fallback is the checked-in serial `warpd.HC` plus the existing COM1 Unix socket. Keep it if the PCI
device is not enumerated, BAR/ABI validation fails, INTx is unreliable, short clicks are lost, snapshot
restore is not clean, or the measured p95/p99 win is not worth the maintenance. A diagnostic
`ivshmem-plain` poll can isolate BAR/cache problems during the spike, but it is not an acceptable
production fallback; production falls back to known-good warpd.

## Phased implementation and measurement plan

### Phase A — spike

- Clone the station and checkpoint; never experiment on CT950's live state or `/mnt/poc`.
- Add `-nic none` and a fixed-slot prototype custom PCI device to the clone's exact launcher.
- In a small REPL HolyC probe, enumerate by ID, validate both BARs, read/write a scratch cacheable ring
  word, and report BDF/BAR/pin/line.
- Install a minimal ISR that only increments a counter, clears the device cause, and EOIs the PIC.
  Generate 1,000 paced and burst doorbells; verify exact count, no storm, no stuck line, and correct
  behavior while a CPU-bound HolyC task runs.
- Gate: no reliable INTx means **no-go** for the kernel/device path; do not expand into MSI work.

### Phase B — driver

- Freeze the T1 ABI version and implement header/index validation, acquire/release helpers, bounded
  drain, sequence/overflow counters, and reset generation.
- Add integer absolute motion first; verify `(0,0)`, `(639,479)`, center, and random normalized points
  by framebuffer cursor localization. Compare `ms.presnap`, `ms.pos`, and `ms.pos_text` in diagnostics.
- Add L/R and wheel without edge coalescing; test menus, drag, double-click, scroll control, and very
  short clicks. Add keyboard last through the scan-code FIFO/state path.
- Retain serial for command execution and rollback. Do not delete or overwrite the known-good agent.

### Phase C — capture

- Make launcher device additions/removals explicit and update `golden-bake.sh` to compile/install the
  source reproducibly.
- Cold recapture with the new device set, run pre-snapshot self-tests, save, quit, fresh-launch, reload,
  reconnect, and rerun all tests.
- Prove reset repeatedly (at least 25 `loadvm golden` cycles) with no stale event, missed first event,
  stuck INTx, or backend leak.

### Phase D — measure and decide

Follow the common measurement plan and report raw distributions, not selected screenshots:

- baseline the **current serial warpd** first, idle and with a non-yielding/CPU-bound guest workload;
- for both transports, measure host enqueue T0 to (a) ISR/state timestamp where available and (b) first
  framebuffer containing the changed cursor; report p50/p95/p99/max and misses over at least 1,000
  randomized moves per condition;
- record ring occupancy, sequence loss, IRQ count, records/IRQ, ISR cycles, D-Bus 4 ms poll, guest
  29.97 Hz frame phase, and stream 30 fps so transport and rendering costs remain separable;
- stress bursts, move+button ordering, drags, 5–20 ms clicks, wheel bursts, keyboard chords, ring full,
  malformed records, backend disconnect/reconnect, and repeated checkpoint restore;
- compare optional window-manager wake enabled/disabled. Keep it only if it improves tails without
  increasing CPU, tearing, or frame instability.

Promotion criteria: zero crashes/storms/stale-after-reset events; zero lost button/key edges in the
supported test envelope; exact endpoint mapping; no sequence loss below defined overload; and a
predeclared meaningful improvement—proposed **at least 25% lower p95 or 50% lower p99 host-to-frame
under load**, with idle not regressing. Because the current ring-0 serial agent is already efficient,
these are decision thresholds, not predicted results. If they are missed, record a clean no-go and
keep warpd.

## References

Primary/authoritative sources used for this plan:

- [TempleOS final snapshot repository and in-guest compiler note](https://github.com/cia-foundation/TempleOS/tree/c26482bb6ad3f80106d28504ec5db3c6a360732c)
- [TempleOS PCI BIOS config-space implementation](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/PCIBIOS.HC#L163-L263)
- [TempleOS PCI enumeration example](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Adam/DevInfo.HC#L121-L169)
- [TempleOS IDT/PIC implementation](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/KInts.HC#L96-L148)
- [TempleOS PCI interrupt lecture/example](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Demo/Lectures/PCIInterrupts.HC#L1-L74)
- [TempleOS mouse state, absolute update, and PS/2 driver](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/SerialDev/Mouse.HC)
- [TempleOS window-manager mouse update](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Adam/Win.HC#L219-L239) and [message/sleep path](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Adam/WinMgr.HC#L27-L310)
- [TempleOS keyboard IRQ, handler, and scan-code queue](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/SerialDev/Keyboard.HC#L411-L480)
- [TempleOS device-memory mappings](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/Mem/MemPhysical.HC#L1-L151) and [page tables](https://github.com/cia-foundation/TempleOS/blob/c26482bb6ad3f80106d28504ec5db3c6a360732c/Kernel/Mem/PageTables.HC#L1-L171)
- [QEMU ivshmem guest-interface specification](https://gitlab.com/qemu-project/qemu/-/blob/7425b6277f12e82952cede1f531bfc689bf77fb1/docs/specs/ivshmem-spec.rst)
- [QEMU PIIX3 INTx/PIRQ routing implementation](https://gitlab.com/qemu-project/qemu/-/blob/fdee2c96923dfd38aa7a264abb7de6d403f81c4d/hw/isa/piix3.c)
- [QEMU PCI test-device specification](https://www.qemu.org/docs/master/specs/pci-testdev.html) (BAR-discovery behavior and a useful model for a minimal test endpoint, not the production input device)
