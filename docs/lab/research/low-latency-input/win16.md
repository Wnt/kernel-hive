# Windows 3.11 (Win16) low-latency input plan

Status: **RESEARCH / CONDITIONAL GO FOR A BOUNDED SPIKE (2026-07-15)**

This plan covers the `win311` station: Windows for Workgroups 3.11 on DOS, running in
386 Enhanced mode under VMM. It answers every question in the
[generic per-OS template](00-generic-plan.md) and does not propose modifying the live lab during
research.

## Verdict

**Conditional go for a time-boxed VxD + Win16 mouse-driver spike; not yet a production go.** A
loadable solution is technically credible, not speculative: Windows 3.x has a ring-0 VxD model,
the mouse-driver callback ABI has native normalized absolute coordinates, Open Watcom can emit both
Win16 drivers and VxDs, and Win3.11-tested VirtualBox/VMware absolute `MOUSE.DRV` implementations
exist. The production design should be:

1. a static 386-Enhanced-mode `GALLHID.386` VxD that binds a deliberately simple custom PCI device,
   receives its legacy INTx, drains a ring in fixed/cacheable guest RAM, and owns all realtime state;
2. a small `GALMOUSE.DRV` replacement that registers USER's `Enable(lpEventProc)` callback with the
   VxD and reports `SF_ABSOLUTE` positions and button transitions; and
3. `VKD_Force_Keys` for ring-delivered scan codes, with the existing QEMU PS/2 keyboard retained as
   the operational fallback.

The **single lowest-latency in-Windows injection point** is USER's mouse event procedure passed to
the Win16 mouse driver's `Enable` entry point—not `SetCursorPos`, `mouse_event`, `PostMessage`, or a
DOS `INT 33h` TSR. The spike must prove that calling this path from an interrupt-originated VxD
callback is stable. If it is not, or if p95/p99 fails to beat the serial agent materially, stop and
keep warpd.

The literal generic ideal—calling into the whole GUI input stack inside the raw PCI ISR—is not safe
to assume on VMM, which is single-threaded and non-reentrant. The buildable default therefore drains
and acknowledges the ring in the ISR, then uses a boosted VMM priority event to enter the fixed
Win16 callback safely. That residual wait on the System VM/critical section is why this is a
conditional rather than unconditional go.

This is deliberately not a recommendation for a VxD-only call to an assumed `VMOUSE` absolute API.
The similarly named `VMD_Post_Absolute_Pointer_Message` is documented for Windows 95 and even has a
known Windows 95 bug; it is not evidence of a Windows 3.11 VMD service. The documented Win3.x
`MOUSE.DRV` callback is the defensible interface.

## 0. Actual station and baseline

The current path is:

```text
streamhost warpd -> Unix serial.sock -> QEMU COM1 -> Win16 AGENT.EXE message queue
               move -> SetCursorPos
             button -> delayed QEMU PS/2 button (preferred), or window PostMessage
```

Repository facts:

- [`agent.c`](../../../../streamhost/guest-agents/win311/agent.c) is a 16-bit Windows application,
  not a driver. It drains COM1 on `WM_COMMNOTIFY`, with a roughly 55 ms timer fallback. It already
  has to coalesce moves because the Win16 COM/message-loop path accumulates stale positions.
- [`README.md`](../../../../streamhost/guest-agents/win311/README.md) records that Win16
  `mouse_event` is a no-op on this guest. The working movement path is `SetCursorPos`; direct
  `WM_*BUTTON*` posting fails for menus and non-client operations, so production currently delays
  QEMU PS/2 buttons behind serial motion.
- [`stations-manifest.sh`](../../../../streamhost/stations-manifest.sh) pins an 8 ms warpd pace and an
  **80 ms button delay** to close the two-channel motion/button race. Removing that race is a large
  potential tail-latency win independent of the raw serial byte cost.
- [`qemu-streamhost.sh`](../../../../streamhost/stations/win311/qemu-streamhost.sh) currently pins
  QEMU 11 `qemu-system-i386`, `pc-i440fx-11.0`, TCG, one Pentium CPU, 64 MiB RAM, Cirrus VGA, two IDE
  disks, NE2000 PCI, SB16, and COM1. It conditionally restores the in-qcow2 `golden` vmstate.
- A read-only QMP `query-pci` on 2026-07-15 showed the NE2000 at `00:03.0`, INTA, IRQ 11. The new
  device's slot/pin must be selected on a scratch boot so SeaBIOS routes it to a usable legacy IRQ;
  IRQ 9 or 10 is preferable to sharing IRQ 11 with the NIC.
- A read-only host check found the pinned **Open Watcom 1.9** at `/root/watcom`, including
  `binl/{wcc,wcc386,wasm,wlink}`. No Windows 3.1 DDK headers/samples were found there, so those are a
  separately staged build input, not something to pretend the current Watcom tree contains.

The replacement is scoped first to the **in-Windows GUI**. Full-screen DOS programs have distinct
VMD/`INT 33h` ownership semantics; the PS/2 path must remain available for them and for rollback.
Command execution remains on its existing non-realtime path.

## 1. Driver model and exact toolchain

### Driver model

Use two cooperating drivers:

| Component | Binary/model | Responsibility |
|---|---|---|
| `GALLHID.386` | static 32-bit VxD, LE/VxD image, loaded by VMM in 386 Enhanced mode | PCI BIOS discovery, BAR/control mapping, fixed DMA ring allocation, INTx through VPICD, ring drain, event coalescing, keyboard injection, VxD API |
| `GALMOUSE.DRV` | 16-bit NE Windows mouse driver/DLL | implement `Inquire`, `Enable`, `Disable`, `MouseGetIntVect`; register the USER callback with `GALLHID`; translate pending state into the documented mouse callback ABI |

The DDK describes VxDs as code linked with VMM when Enhanced Windows starts, with real-mode init,
protected-mode init, locked code/data, a device control procedure, and optional protected-mode API
entry point. It also describes ordinary Windows device drivers such as `MOUSE.DRV` as DLLs above a
VxD. That split is exactly what is needed here: hardware ownership at ring 0 and the documented
Win16 input ABI at the top.

A **DOS TSR + `mouse.drv` stub is fallback architecture B, not the primary design**. Windows does
not use a DOS mouse driver for its GUI for performance reasons, and under Enhanced mode VMD owns and
virtualizes the mouse interrupt. A TSR would either poll, fight VMM interrupt ownership, or still
need a VxD bridge; it therefore adds complexity without reaching a lower Windows injection layer.
It becomes relevant only if an existing DOS absolute driver can provide full-screen DOS integration
cheaply after the in-Windows goal is met.

### Toolchain

Use labhost's pinned Open Watcom 1.9 from `/root/watcom`:

- `wcc386` for a freestanding 386 C core;
- `wasm` for the VxD declaration/control-dispatch, VMM/VPICD service-call glue, interrupt entry, and
  16:16/ring-0 thunk where C cannot express the ABI safely;
- `wlink FORMAT WINDOWS VXD` (omit the optional `DYNAMIC`, yielding the static form) to produce the
  Windows 3.x `.386` VxD;
- `wcc`/`wcl` in 16-bit Windows DLL mode plus `wlink` for `GALMOUSE.DRV`; and
- `wmake` for a reproducible host-side build.

Stage the Windows 3.1 DDK sample sources and at least `VMM.INC`, `VPICD.INC`, and `VKD.INC` as
versioned build inputs with provenance/checksums. Start from the DDK's simplest static VxD sample
and mouse sample structure. Do not mix Windows 95 DDK service ordinals or headers into the build.
Open Watcom's VxD linker support is real, but successful linking is not proof of Win3.11 ABI
compatibility; the first spike gate is a minimal `.386` that loads and logs without an invalid
dynamic-link call.

There is a real assembler compatibility risk: DDK 3.1 samples are heavily shaped around MASM 5.1
macros. First try the small VxD skeleton with `wasm`; if it cannot assemble the unmodified DDK macro
layer reliably, use a provenance-pinned MASM 5.1-compatible `MASM 5.NT.02` for assembly glue while
retaining Open Watcom 1.9 for C/link/resource work. Do not estimate a wholesale mechanical port of
large DDK assembly sources as free work.

### Language decision (Rust -> C -> assembly)

- **Guest driver: C plus small x86 assembly.** There is no demonstrated Rust target/runtime that
  emits a Windows 3.11 VxD with its DDB, VMM service-call convention, locked sections, 16:16 callback
  transitions, and LE loader requirements. Claiming Rust here would be fiction. C is suitable for
  ring parsing and state machines; assembly is mandatory only at VxD service/interrupt/thunk ABI
  boundaries.
- **Mouse shim: 16-bit C plus tiny assembly/pragmas.** The Win3.11-tested `vbmouse` implementation
  demonstrates a mostly-C Open Watcom `MOUSE.DRV`; use assembly only for the event-procedure register
  convention and atomic far-pointer/thunk mechanics.
- **Host binding remains Rust; QEMU device remains C** under the generic plan. Those components are
  outside this guest-driver deliverable.

## 2. Transport binding: PCI, shared ring, and interrupt

### Device choice

For Win3.11, prefer a **custom minimal `gallery-hid` conventional PCI device with a 32-bit BAR and
legacy INTx** over current ivshmem:

- `ivshmem-plain` provides BAR2 shared memory but no wakeup interrupt.
- Current revision-1 `ivshmem-doorbell` exposes its MSI-X table/PBA in BAR1. Its documented legacy
  INTx behavior belongs to old revision-0 devices without MSI-X. Windows 3.11 has no MSI/MSI-X
  subsystem, and polling defeats the goal.
- A custom device can expose one small 32-bit control BAR, a level-triggered status/ack register,
  conventional INTA-D routing, and a guest-RAM DMA-ring address. That is simpler for this OS than a
  large/possibly 64-bit shared-memory BAR.

Use the generic plan's QEMU vendor ID `0x1b36` plus a T1-assigned, repository-registered device ID;
the driver matches both values and protocol revision, never PCI class alone.

The Win16-specific preference is **guest-RAM DMA**, which is one of the generic plan's allowed
shared-ring forms:

```text
BAR0: magic/version/features, ring physical address/size, producer mirror/status,
      interrupt status/mask/ack, device ready/reset

one 4 KiB PG_SYS page allocated PageFixed|PageUseAlign|PageContig:
      ring header + fixed 16-byte records
```

This keeps hot reads in ordinary cacheable guest RAM and confines trap-prone MMIO to setup and one
status/ack operation per batch. `MapPhysToLinear` of a shared-memory BAR remains a transport-spike
fallback, but it must win a measured microbenchmark; do not assume Windows 3.11 maps a PCI memory
BAR with useful cache attributes.

### PCI enumeration and setup

WfW 3.11 has no Windows 95 Configuration Manager/PnP PCI bus driver to enumerate for us. During
VxD initialization, use the PCI BIOS through a nested V86 BIOS call:

1. save the client state, `Begin_Nest_V86_Exec`, execute INT 1Ah with `AX=B101h` (installation
   check), and verify carry clear, `AH=0`, and the `EDX=0x20494350` (`"PCI "`) signature;
2. `AX=B102h` to find the agreed vendor/device ID, instance zero, yielding bus/device/function in
   `BX`;
3. `B108h/B109h/B10Ah` to read configuration byte/word/dword values: command/status, BAR0,
   interrupt line at `0x3c`, and interrupt pin at `0x3d`;
4. reject a missing/unassigned BAR, 64-bit BAR, IRQ `0xff`, pin zero, protocol-version mismatch, or
   duplicate device; enable memory decoding and bus mastering only if firmware did not; and
5. leave nested execution and restore the client state before allocating/virtualizing resources.

Do not scan CF8/CFC as the normal path. Direct mechanism-1 access can be a diagnostic fallback only
if the PCI BIOS is absent, and absence should fail closed in production because the launcher is
under our control. A Win3.11-tested Open Watcom mouse driver already demonstrates `INT 1Ah` PCI BIOS
find/read calls from this environment.

### Ring allocation and BAR mapping

At device initialization:

1. call VMM `_PageAllocate` for one `PG_SYS` page with `PageZeroInit | PageFixed |
   PageUseAlign | PageContig`; request 4 KiB alignment and capture both the ring-0 linear address and
   physical address;
2. use `_MapPhysToLinear(BAR0 & ~0x0f, BAR0_size, 0)` for the small register BAR;
3. program the page's physical address, ring size, protocol version, and interrupt mask into BAR0;
4. use `volatile` fields plus explicit compiler barriers. Keep producer host-owned and consumer
   guest-owned. On x86/QEMU the producer record must be complete before producer advances and INTx
   asserts; consumer must advance before the guest ack; and
5. refuse to arm if the page allocation, physical address, mapping, or device feature negotiation
   fails. Leave PS/2/serial fallback intact.

The generic 16-byte records carry normalized `0..32767` pointer coordinates. The ring is a FIFO for
button/key transitions, but movement is replaceable: the host and driver may coalesce consecutive
move-only records to the newest sequence number. They must never coalesce across a button/key edge.
Track sequence gaps, malformed types, ring overrun, IRQ count, max drain depth, and callback count in
VxD counters exposed read-only through its protected-mode API.

### INTx registration and ISR

MSI/MSI-X is **no-go**. Read the firmware-assigned legacy IRQ from PCI config space and register a
`VPICD_IRQ_Descriptor` with `VPICD_Virtualize_IRQ`, a `VID_Hw_Int_Proc`, and `Can_Share`. VPICD can
share an IRQ only when every owner declares it shareable, so prefer a scratch-validated slot/pin
that routes to otherwise free IRQ 9 or 10. Never hardcode IRQ 11 merely because the current NE2000
uses it.

The hardware interrupt procedure, entered with interrupts disabled, must be bounded:

1. read the device interrupt-status register first; if its pending bit is clear, set carry and
   return so another shared handler can claim it;
2. snapshot producer, drain at most a defined budget (for example 32 records), validate sequence and
   types, update the latest pointer/button state and key scan-code staging buffer;
3. advance consumer; ack/deassert the device's **level** INTx; call `VPICD_Phys_EOI` with the IRQ
   handle; and return carry clear;
4. call `VKD_Force_Keys` for staged make/break scan codes at the first legal event-processing point,
   not from code that invokes an unsafe VMM service at hardware-interrupt reentry; and
5. request at most one outstanding mouse callback. If the ring still has work after the budget,
   arrange a global/priority event or let the still-pending level interrupt retrigger after EOI.

Device status and ack must make shared-IRQ attribution unambiguous. An interrupt storm, failure to
deassert, or a `VPICD_Virtualize_IRQ` failure is a hard disable of the PV path, not a reason to keep
running partially initialized ring-0 code.

## 3. Lowest-latency absolute-pointer injection point

### Exact endpoint

`GALMOUSE.DRV` implements the documented Win16 mouse-driver contract:

- `Inquire(MOUSEINFO*)`: `msExist=1`, `msRelative=0`, button count (start with two; gate a third on
  explicit testing), and a rate at least as high as the host's coalesced delivery target;
- `Enable(lpEventProc)`: lock/store USER's far callback pointer, get the `GALLHID.386` protected-mode
  API entry with `INT 2Fh, AX=1684h, BX=<collision-checked private device-id>`, reject `ES=0`,
  and register a fixed callback
  shim plus the System VM handle with the VxD;
- `Disable()`: atomically unregister before invalidating the callback; and
- `MouseGetIntVect`: return the PS/2 interrupt vector (`0x74`) and retain a small, tested PS/2
  fallback handler derived from the DDK/Win3.11-tested `vbmouse` design, so stock `*vmd` can continue
  to manage DOS-box mouse ownership. Validate this coexistence explicitly rather than inventing a
  new VMD service.

For a movement callback:

```text
AX = SF_MOVEMENT | SF_ABSOLUTE | any button transition bits
BX = normalized absolute X, 0..65535
CX = normalized absolute Y, 0..65535
DX = button count
DI = SI = 0
call USER lpEventProc
```

Convert the generic protocol without consulting the current VGA mode:

```text
x16 = round(clamp(x15, 0, 32767) * 65535 / 32767)
y16 = round(clamp(y15, 0, 32767) * 65535 / 32767)
```

USER maps the normalized values onto the display surface. Equivalently, for validation at the
current 640x480 fixture, the expected pixel is
`round(x15 * 639 / 32767), round(y15 * 479 / 32767)`. This remains correct if the checkpoint's display
resolution changes and avoids pointer acceleration and accumulated relative error.

The callback's button-transition bits enter USER's system input queue, so menus, title bars,
capture, drag, double-click logic, and client/non-client routing are handled once by Windows. This
eliminates the current `SetCursorPos` + delayed PS/2 race and the semantically incomplete
`PostMessage` path.

### VxD-to-Win16 bridge

Use the same final `lpEventProc` endpoint in both cases:

1. **Required, documented bridge:** from the ISR, coalesce one `Call_Priority_VM_Event` to the System VM with
   `PEF_Wait_ForSTI | PEF_Wait_Not_Crit` and a device priority boost; at the callback, use
   `Begin_Nest_Exec`, a simulated far call to the fixed `GALMOUSE.DRV` shim, `Resume_Exec`, and
   `End_Nest_Exec`. The DDK explicitly permits priority events from interrupt handlers and documents
   this callback pattern. It can be delayed by a USER/VMM critical section, so measure its tail
   before accepting it.
2. **Optional latency experiment, not the default:** Windows 3.1-era VPICD literature describes a
   direct ring-0 16-bit callback/thunk technique. It requires correct ring-0 aliases for locked
   16-bit code/data, stack and DS setup, and a proven way to reach USER's callback without an illegal
   privilege transition. Explore it only after the priority-event path is stable. Promote it only
   if code review and stress testing prove selector, paging, reentrancy, and unregister safety as
   well as a material tail-latency win.

Do not execute arbitrary USER code directly in the raw `VID_Hw_Int_Proc`. The ISR may drain and
acknowledge hardware; the callback bridge must obey VMM's reentrancy rules.

### Buttons, wheel, and keys

- **Left/right buttons:** deliver transition bits in the same absolute mouse callback. Preserve
  ordering with their associated position; keep current button state so a dropped packet can be
  reconciled without a stuck button.
- **Middle button:** the DDK describes a variable button count, but the stock/sample ABI and public
  Win3.x absolute-driver examples are best proven for two. Test the conventional next transition
  bits and `DX=3` against Program Manager, Notepad, and capture/drag behavior. If USER 3.11 does not
  process it consistently, retain the current PS/2 middle-button fallback; do not use per-window
  posting as if it were equivalent.
- **Wheel:** Windows 3.11 predates a system wheel message/standard. There is no honest kernel
  injection point that gives universal wheel semantics. Optional compatibility may translate a
  wheel tick to `WM_VSCROLL` for the window under the pointer (as the VMware driver experiment does)
  or to configured PageUp/PageDown scan codes, but label that as application-specific emulation.
  Wheel support is not a production-go gate for this OS.
- **Keys:** translate protocol keycodes to Set-1 make/break scan-code sequences, including `E0`
  prefixes, and use VxD `VKD_Force_Keys`. The documented service makes them appear physically typed
  in the keyboard focus VM. Preserve order, modifiers, and key-up records; on VKD buffer overflow,
  retry remaining codes from a deferred event. Keep QEMU's existing PS/2 keyboard enabled for
  rollback and full-screen DOS compatibility.

## 4. Auto-start and checkpoint capture

Installation is an offline, reversible checkpoint-image operation:

1. build and fingerprint `GALLHID.386` and `GALMOUSE.DRV`; verify the former as the intended VxD/LE
   image and the latter as a Win16 NE driver;
2. with the VM stopped, back up both station qcow2s, mount the C: FAT16 image, copy the drivers to
   `C:\WINDOWS\SYSTEM`, and preserve the original `SYSTEM.INI`;
3. add `device=GALLHID.386` under `[386Enh]`, set `[boot] mouse.drv=GALMOUSE.DRV`, and retain the
   stock `mouse=*vmd`/PS/2 configuration until the DOS-box tests say otherwise;
4. leave `C:\AGENT.EXE`, its `WIN.INI load=` entry, COM1, and `serial.sock` present for the first
   rollout. The agent may sit idle while the host selects PV input; rollback then requires only a
   launcher/env switch plus the known-good checkpoint, not emergency disk surgery;
5. add the custom PCI device at an explicit, scratch-validated `pci.0` address/pin to the verbatim
   station launcher. The launcher is the device-set ledger; do not rely on QEMU auto-placement;
6. cold boot—never load the old vmstate with a changed device set—verify VxD initialization, PCI
   IDs/BAR/IRQ, mouse callback registration, pointer/buttons/keys, and clean Windows exit/restart;
7. with an empty ring, INTx deasserted, both buttons/keys up, and the driver armed, delete/recreate
   the `golden` snapshot. Snapshot both disks as the existing flow requires; and
8. repeatedly `loadvm golden` and verify that QEMU's device VMState, guest RAM ring, VxD state, and
   reconnected host backend resume coherently without re-running driver initialization.

The QEMU device must migrate/save at least negotiated features, ring physical address/size,
producer state, interrupt mask/status, and backend connection-independent state. A restored stale
pending interrupt or producer index is a capture blocker. The external Unix socket may reconnect after
restore, but the device must not discard the guest-programmed DMA address.

Rollback artifacts must include the pre-driver qcow2s and launcher. Never attach `qemu-nbd` or mount
a live station disk.

## 5. Effort, risks, fallback, and gates

### Estimate

Guest-specific effort, assuming T1 supplies a minimal custom PCI device/backend and T2 supplies the
measurement harness:

| Phase | Estimate | Exit condition |
|---|---:|---|
| spike | 5-8 engineer-days | loadable VxD; PCI BIOS/BAR/INTx proven; synthetic absolute callback moves and clicks correctly |
| production driver | 10-15 engineer-days | bounded ring/ISR, stable priority-event callback bridge, buttons and VKD keys, diagnostics, stress/rollback |
| capture/integration | 2-3 engineer-days | deterministic offline install, pinned device slot, rebuilt checkpoint, 20+ clean restores |
| measure/tune | 3-5 engineer-days | serial/PS2/PV p50/p95/p99 idle+load data and documented go/no-go |
| **total** | **20-31 engineer-days (about 4-6 weeks)** | excludes shared QEMU/host implementation |

The estimate is intentionally larger than a modern input driver. Most cost is validating obscure
cross-privilege and callback behavior, not parsing 16-byte records.

### Principal risks

| Risk | Why it matters | Mitigation / stop condition |
|---|---|---|
| VxD-to-16-bit callback reentrancy/paging | one bad selector, stack, unload race, or callback during a critical section can hang all of Enhanced Windows | fixed code/data; unregister handshake; make the documented priority-event bridge stable first; treat direct thunking only as an optional measured optimization; stop after repeatable hangs |
| PCI INTx routing/sharing | current NE2000 already uses IRQ11; VPICD shares only when all owners opt in | explicit slot/pin; scratch-query PCI line; target free IRQ9/10; status-first ISR; do not remove networking without a separate product decision |
| MMIO/shared-memory cache behavior | a BAR-backed ring may trap or be uncached, erasing the latency win | prefer a PageFixed contiguous guest-RAM DMA ring; benchmark BAR mapping only as fallback |
| snapshot coherence | `loadvm` restores RAM and device state without driver re-init | empty-ring checkpoint invariant; complete QEMU VMState; 20+ restore loops with sequence/IRQ counters |
| cursor is not in QMP screendumps | the current golden manifest marks Win3.11 mouse pixel verification as skipped because its hardware cursor overlay is uncaptured | use QEMU D-Bus cursor-position metadata/composited streamhost output if T2 exposes it; otherwise use a Win16 test surface that repaints a marker on `WM_MOUSEMOVE`, and report that this measures UI reaction rather than raw cursor overlay |
| Win16 USER remains serialized | even priority callbacks can wait behind USER/VMM critical sections; a VxD cannot make cooperative USER reentrant | compare direct thunk and priority event under CPU/UI load; require tail improvement, not merely lower transport time |
| semantic gaps | third button, wheel, and full-screen DOS are not as clean as in-Windows two-button input | keep PS/2 and warpd; scope first release honestly; never substitute `PostMessage` and call it hardware input |
| tool/source reproducibility | `/root/watcom` lacks DDK 3.1 macros/samples | checksum/provenance the DDK input; pin OW 1.9; save map/symbol files and exact commands |
| old-OS debugging | a VxD fault can freeze or triple-fault the guest with little diagnosis | scratch clone only, WDEB386/debug VMM if available, port/serial debug codes, one feature per boot |

### Production go/no-go criteria

Proceed to bake only if all are true:

- 100 cold boots and 1,000 reset/restore cycles in a scratch fixture without VxD load errors, stuck
  INTx, ring corruption, stuck buttons/keys, or cursor drift;
- exact absolute landing at corners, center, and randomized positions, including after display mode
  switches that the fixture supports;
- menus, title-bar drag, capture, double-click, and simultaneous move+button ordering work through
  the mouse callback without the current 80 ms delay;
- CPU-load and Win16-UI-load tests show a material p95/p99 improvement over serial warpd. Proposed
  acceptance: at least 2x lower p95 and p99, and no worse p50, using T2's end-to-end cursor-pixel
  harness; and
- QEMU PS/2/serial fallback remains immediately selectable.

**No-go and retain warpd** if the callback bridge is unstable, the PCI IRQ cannot be routed/shared
without sacrificing required devices, the safe priority-event path still stalls behind USER enough
to miss the tail target, or the measurement cannot observe a large end-to-end win. The existing
coalesced serial agent is imperfect but known and baked; replacing it with fragile ring-0 code for a
small median-only gain would be a regression in engineering quality.

## 6. Phased implementation plan

### Phase A — spike (5-8 days)

1. Reproduce the toolchain in a disposable build directory: pin `/root/watcom` 1.9, stage DDK 3.1
   inputs, and build the untouched simplest VxD and mouse-driver samples. Record commands, hashes,
   `file`/header inspection, map files, and warnings.
2. Build a minimal `GALLHID.386` that only loads, reports VMM version/debug milestones, exports a PM
   API, and unloads/exits cleanly. Test solely in a qcow2 clone.
3. With T1's device stub, perform PCI BIOS installation/find/config reads via nested V86 execution;
   log BDF, BAR, pin, and line. Try explicit PCI slots/pins until a non-conflicting IRQ is assigned;
   document whether sharing with NE2000 is avoidable.
4. Map BAR0; allocate the PageFixed contiguous page; program DMA; have the host write a sequence and
   assert INTx. Prove status attribution, VPICD claim/share behavior, ack/deassert, EOI, and repeated
   interrupts before touching USER.
5. Adapt a minimal mostly-C absolute `GALMOUSE.DRV` from the DDK/vbmouse ABI. First drive its USER
   callback from a controlled synthetic source and verify exact normalized movement plus left/right
   transitions.
6. Connect VxD to the shim through the priority-VM-event nested far-call path and make that stable
   first. Only then spike the direct ring-0 callback as an optional optimization. Stress each with
   rapid moves, menus, drags, CPU load, and repeated Enable/Disable/Windows exit.
7. **Spike gate:** choose the stable bridge with the best p95/p99. Stop if neither survives or if the
   callback cannot provide correct native button semantics.

### Phase B — production driver (10-15 days)

1. Implement final protocol/version negotiation, fixed ring header/records, producer/consumer
   ownership, movement coalescing, transition ordering, sequence/overrun handling, reset, and
   diagnostics.
2. Make the ISR bounded and shared-safe. Test spurious interrupts, malformed records, ring full,
   wraparound, backend disconnect/reconnect, interrupt during init/disable, and forced missed ack.
3. Complete `GALMOUSE.DRV`: fixed segments, atomic callback registration/unregistration, normalized
   conversion, left/right state reconciliation, third-button experiment, and PS/2/VMD coexistence.
4. Add Set-1 key translation and `VKD_Force_Keys` in deferred legal context; test modifiers,
   extended keys, autorepeat policy, focus changes, buffer overflow, and key-up recovery.
5. Add read-only driver counters/status through the PM API. No usermode polling process belongs on
   the input path; a tiny diagnostic utility is acceptable only for test queries.
6. Fuzz device records from the host and run long GUI/CPU/DOS-box stress. Fail closed to PS/2/serial
   on initialization errors.

### Phase C — capture (2-3 days)

1. Turn build/install steps into reproducible, offline scripts operating on stopped scratch images;
   preserve CRLF and original INI files.
2. Pin the custom device's ID, BAR contract, explicit PCI address/pin, backend socket, and all
   relevant properties in the emitted launcher. Retain COM1 during rollout.
3. Cold boot the modified clone; validate driver diagnostics and every input semantic; create a new
   empty-ring/deasserted-INTx checkpoint.
4. Run at least 20 pre-promotion `loadvm golden` loops plus cold boots. Then follow the larger
   100/1,000 stability gate before declaring production.
5. Produce a one-command rollback to the pre-driver launcher/checkpoint and retain warpd configuration.

### Phase D — measure and decide (3-5 days)

1. Baseline current serial motion plus delayed PS/2 buttons. Because the Win3.11 hardware cursor is
   absent from current QMP screendumps, use T2's D-Bus cursor metadata/composited-output timestamp if
   available; otherwise focus a purpose-built Win16 test surface that repaints a marker on
   `WM_MOUSEMOVE`. Record the exact observable used, then p50/p95/p99 at idle, under a CPU-bound task,
   and during a busy Win16 repaint.
2. Measure separately: raw device interrupt-to-callback counters, priority-event versus direct-thunk
   bridge, and full end-to-end PV input. This distinguishes transport gains from USER serialization.
3. Test move bursts, move+down ordering, drag, menu open, double-click, and key echo. Include ring
   wrap and host reconnect immediately after `loadvm`.
4. Compare against the explicit production gates. Promote only on a large tail-latency win with no
   semantic/stability regression; otherwise archive the spike data and leave warpd active.

## 7. References

Primary/period documentation and specifications:

- [Microsoft Windows 3.1 DDK Installation and Update Guide](https://www.bitsavers.org/pdf/microsoft/windows_3.1/Microsoft_Windows_3.1_SDK_1992/PC29131-0392_Windows_3.1_Device_Driver_Kit_Installation_Mar92.pdf) — contents, sample drivers/VxDs, tools, and DDK workflow.
- [Windows 3.1 Device Drivers Overview (DDAG31QH help transcription)](https://dos-help.soulsphere.org/ddag31qh.hlp/Windows_Drivers_Overview.html) — Windows 3.1 device-driver architecture, SYSTEM.INI selection of `MOUSE.DRV`, and USER's event callback into the mouse driver.
- [Microsoft Windows 3.0 DDK Device Driver Adaptation Guide (searchable transcription)](https://www.pcjs.org/documents/books/mspl13/win/w3ddkadp/) — detailed `MOUSE.DRV` DLL model, `Inquire`/`Enable`/`Disable`, `MOUSEINFO.msRelative`, callback registers, absolute-device support, and `MouseGetIntVect`; the retained Win3.x ABI is corroborated on Windows 3.1 by the preceding 3.1 help and the tested drivers below.
- [Microsoft Windows 3.0 DDK Virtual Device Adaptation Guide (searchable transcription)](https://www.pcjs.org/documents/books/mspl13/win/w3ddkvxd/) — detailed VxD/DDB model, nested VM execution, PM APIs and INT 2Fh/1684h, `_PageAllocate`, `MapPhysToLinear`, priority VM events, `VKD_Force_Keys`, and VPICD IRQ virtualization/EOI/sharing; use it as the Win3.x service baseline, not as proof of a Windows 3.1-only feature.
- [Writing Windows Virtual Device Drivers, Thielen](https://www.bitsavers.org/pdf/microsoft/windows_3.1/Thielen_-_Writing_Windows_Virtual_Device_Drivers_1993.pdf) — Windows 3.1 direct ring-0 callbacks to 16-bit driver/TSR code and VxD construction/debugging.
- [PCI-SIG PCI BIOS Specification 2.1 landing page](https://pcisig.com/PCIConventional/Specs/Firmware/Bios_2.1) — firmware-independent PCI BIOS interface specification.
- [QEMU ivshmem device specification](https://www.qemu.org/docs/master/specs/ivshmem-spec.html) — BAR layout, revision-1 MSI-X design, and legacy INTx only for old revision-0/no-MSI-X operation.

Toolchain and working examples:

- [Open Watcom 1.9 C/C++ Getting Started](https://open-watcom.github.io/open-watcom-1.9/c_readme.html) — supported Windows 3.x and 32-bit targets.
- [Open Watcom linker guide, WinVxD format](https://ftp.openwatcom.org/ftp/manuals/1.5/lguide.pdf) — `FORMAT WINDOWS VXD [DYNAMIC]` and VxD image layout in a release predating the pinned 1.9 toolchain.
- [OS/2 Museum: Win16 Retro Development](https://www.os2museum.com/wp/win16-retro-development/) — a modern Windows 3.1 DDK build using MASM 5.NT.02 with Open Watcom 1.9 `wmake`, `wlink`, and `wrc`, and a warning about the DDK samples' MASM dependence.
- [VBMouse: VirtualBox Mouse Driver for Windows 3.x in C](https://git.javispedro.com/cgit/vbmouse.git/tree/README.md) and its [source tree](https://git.javispedro.com/cgit/vbmouse.git/tree/) — tested on Windows 3.11 Enhanced mode; mostly-C Open Watcom `MOUSE.DRV`; absolute callback, PCI BIOS, physical buffer/VDS, VMD, and installation examples.
- [VMware mouse driver for Windows 3.1](https://github.com/NattyNarwhal/vmwmouse) — DDK-sample-derived `SF_ABSOLUTE` implementation, normalized `BX/CX`, QEMU testing, button limitations, and experimental wheel-to-scroll emulation.
- [Microsoft KB Q74572: How Windows Uses an MS-DOS Mouse Driver](https://jeffpar.github.io/kbarchive/kb/074/Q74572/) — Windows GUI uses its own `MOUSE.DRV`; VMD manages mouse hardware ownership in Enhanced mode.
- [Microsoft KB Q120079: INT 2Fh/1684h may return ES=0 with DI nonzero](https://jeffpar.github.io/kbarchive/kb/120/Q120079/) — required PM API failure check for the Win16 shim.
- [Microsoft KB Q139292: `VMD_Post_Absolute_Pointer_Message` bug](https://www.betaarchive.com/wiki/index.php?title=Microsoft_KB_Archive%2F139292) — applies to Windows 95 and is a warning not to import a Win95 VMOUSE assumption into this Win3.11 design.
