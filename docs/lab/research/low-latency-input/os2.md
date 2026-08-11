# OS/2 Warp 4 low-latency input plan

Status: **research/design, 2026-07-15**. Scope: `os2warp` only. This document applies the
[generic plan](00-generic-plan.md) to the actual Warp 4 GA guest; it does not authorize a driver,
QEMU, golden-image, or live-lab change.

## Verdict

**GO for a time-boxed kernel-driver spike; conditional GO for production.** OS/2 has an unusually
good documented endpoint for this job: a hardware-dependent mouse PDD can pass a zero-based
absolute event directly to the system `MOUSE$` driver's `Process_Absolute` IDC at interrupt time.
That is lower and more correct than the current PM process, and it should fix both acceleration
drift and the current best-effort click behavior. The OS also has documented PCI-BIOS access,
Resource Manager calls, persistent physical mappings, and shared legacy-IRQ support.

Production remains conditional because this is a 16-bit segmented ring-0 driver for a 1996 kernel,
the mouse IDC is non-reentrant, and Warp 4 GA's PCI/IRQ-sharing behavior must be proven on this
exact QEMU machine. Stop after the spike and retain `WARPD.EXE` if the driver cannot (1) map and
read the ring without polling, (2) claim and repeatedly service INTx without traps or lost EOI, and
(3) make genuine WPS drag/double-click sequences through `MOUSE$`. This is not a case for
claiming that source documentation alone guarantees a stable driver.

## Actual baseline and constraints

The current source is [`streamhost/guest-agents/os2/warpd_os2.c`](../../../../streamhost/guest-agents/os2/warpd_os2.c).
It is a 32-bit PM executable which:

- reads newline-delimited ASCII from `COM1` using `DosRead`;
- sleeps 15 ms whenever no byte is returned;
- calls `WinSetPointerPos(HWND_DESKTOP, x, screen_height - 1 - y)` for movement; and
- posts `WM_BUTTON*` to the window under the pointer because PM's set-pointer position is
  decoupled from the PS/2 mouse position.

That path moves accurately, but scheduling, the explicit sleep, UART delivery, parsing, and PM
message posting all add latency or semantic risk. WPS click actuation is explicitly still partial.
There is also a concrete wheel bug: protocol buttons 4 and 5 enter `pt_click()` and its final
`else`, so both become `WM_BUTTON3DOWN/UP` (a middle click). The replacement must never encode a
wheel notch as button 3.

The emitted launcher is [`streamhost/stations/os2warp/qemu-streamhost.sh`](../../../../streamhost/stations/os2warp/qemu-streamhost.sh).
Its pinned machine is one TCG Pentium CPU, 128 MiB, `pc,acpi=off,usb=off`, Cirrus VGA, SB16,
PCnet, IDE, and the default COM1 serial device. It conditionally restores `-loadvm golden`.
Adding the input PCI function is therefore a **device-set change** and requires a new checkpoint; an
old RAM snapshot must never be restored against the new device set.

## 1. Driver model and exact toolchain

### Driver shape

Build `GWPMOU.SYS` as a boot-loadable, 16-bit, device-dependent **Physical Device Driver (PDD)** with
an eight-byte character-device name such as `GWPMOU$` (space padded). It supplies:

- the mandatory request-packet strategy entry point;
- the device-dependent mouse IDC required by `MOUSE.SYS`: `Query_Config`, `Read_Enable`,
  `Read_Disable`, `Enable_Device`, and `Disable_Device`;
- a PCI INTx ISR; and
- an optional diagnostic IOCtl surface, compiled out or disabled for the checkpoint.

The IBM PDD model is 16:16 protected mode. A strategy routine and device header are mandatory;
the interrupt and IDC handlers are optional driver components, and the ISR reports interrupt
ownership in carry. For this design, load the PDD with **`BASEDEV=GWPMOU.SYS`**, not `DEVICE=`.
A normal loadable PDD's INIT executes at ring 3; IBM states that such a driver cannot call a ring-0
IDC from INIT, whereas a base driver's INIT executes at ring 0. PCI discovery through `OEMHLP$`
must finish before the later `MOUSE.SYS` `Query_Config`, so a combined base PDD is the coherent
one-module design. Proving that GA `MOUSE.SYS TYPE=GWPMOU$` attaches to the named IDC exposed by
this base PDD is an explicit Phase-1 gate; if it does not, the fallback design is a tiny PCI
`BASEDEV` plus a conventional mouse `DEVICE` joined by a private IDC, at the cost of a second
ring-0 module.
[IBM Physical Device Driver Reference](https://www.edm2.com/index.php/PDDREF%3APhysical_Device_Driver_Architecture_and_Structure)
[DevHelp_AttachDD context restrictions](https://www.edm2.com/index.php/DevHelp_AttachDD)

This PDD is the hardware-dependent half of the normal pointing stack, not a second independent
mouse and not a PM filter. `MOUSE.SYS` accepts a `TYPE=` override naming a device-dependent
driver, which must load first. IBM documents relative and absolute device classes and the complete
IDC contract, including the `MOUSE$` name and the `Process_Absolute` entry.
[IBM mouse-driver reference](https://www.edm2.com/index.php/Input/Output_Device_Driver_Reference/Mouse_Device_Driver)

### Is a VDD needed?

**No custom VDD for the first implementation.** Native OS/2 and PM consume the normal
`MOUSE.SYS` path. The existing `C:\OS2\MDOS\VMOUSE.SYS` remains responsible for virtual DOS and
WIN-OS/2 sessions. IBM's touch/mouse design says the absolute-to-mouse conversion occurs at the
device-dependent/device-independent junction and is then indistinguishable at the MOUSE IOCtl,
`Mou*`, and INT 33h interfaces. A custom VDD is justified only if a later acceptance test proves
that the stock `VMOUSE.SYS` does not forward this device's events into a required DOS or WIN-OS/2
mode; it is not needed for the gallery's native WPS target.
[IBM touch-driver mouse emulation](https://www.edm2.com/index.php/Input/Output_Device_Driver_Reference/Touch_Display_Device_Driver)

### Build environment

Use the project's pinned **OpenWatcom 1.9 only**, cross-built on the host from `/root/watcom` with the
existing environment (`WATCOM=/root/watcom`, `PATH=$WATCOM/binl:$PATH`, and the appropriate OS/2
include paths). The current `WARPD.EXE` is proven with `wcl386`, but that does **not** prove the
PDD toolchain. The PDD uses:

- `wcc` (16-bit C), not `wcc386`;
- `wasm` for the small entry/calling-convention modules;
- `wlink` with an OS/2 driver DEF/link response that fixes the first data/code segments and marks
  IOPL/permanent segments correctly; and
- the IBM Developer Connection DDK for OS/2 headers, `DHCALLS`, mouse `familyg`/touch sample,
  `RMBASE.H`, and `RMCALLS.LIB`.

OpenWatcom 1.9 explicitly supports both 16- and 32-bit OS/2 targets.
[OpenWatcom 1.9 getting started](https://open-watcom.github.io/open-watcom-1.9/c_readme.html)
IBM's PDD reference recommends starting from the Developer Connection DDK sample, and IBM's mouse
reference identifies `\DDK_X86\SRC\DEV\MOUSE\FAMILYG` as the device-dependent sample. The first
spike deliverable is therefore a reproducible `make` target that builds and loads an inert PDD;
do not treat the existing PM executable recipe as reusable proof. Modern Arca Noae guidance also
identifies OpenWatcom plus the IBM DDK as the driver-development prerequisites.
[Arca Noae developer information](https://www.arcanoae.com/wiki/information-for-developers/)

## 2. Transport binding: PCI enumeration, BAR/ring mapping, and IRQ

### Required device profile

For OS/2, T1 should select the custom `gallery-hid` PCI function, not current
`ivshmem-doorbell`. Require this OS-facing profile:

- fixed vendor/device IDs and PCI revision;
- PCI 2.x conventional function on the existing `pc` machine;
- one **32-bit, non-prefetchable memory BAR below 4 GiB**, no 64-bit BAR;
- BAR size no greater than 64 KiB so one 16-bit GDT selector spans it;
- ring/control page layout versioned with magic, ABI version, record size, capacity, producer,
  consumer/ack, interrupt-status, and interrupt-mask fields;
- one level-triggered, shareable **legacy INTx** line; no MSI or MSI-X dependency; and
- interrupt status that remains asserted until the guest acknowledges all pending work.

QEMU's current `ivshmem-plain` has no interrupt path, while `ivshmem-doorbell` requires the server
and uses an MSI-X table in BAR1. The only documented legacy INTx behavior belongs to old revision-0
ivshmem without MSI-X. Depending on that historical mode would add server/protocol and revision
compatibility risk solely to avoid a small device model.
[QEMU ivshmem documentation](https://www.qemu.org/docs/master/system/devices/ivshmem.html),
[QEMU ivshmem PCI specification](https://gitlab.com/qemu-project/qemu/-/blob/master/docs/specs/ivshmem-spec.rst)

The desired BAR is QEMU RAM-backed shared memory, not a callback for every ring load. Control
registers may occupy a separate small I/O/MMIO BAR if T1 prefers; one trapped acknowledge per
drained batch is acceptable, but per-record trapped MMIO is not. If OS/2 cannot reliably write the
RAM BAR through the fabricated GDT segment, make the ring guest-read-only and acknowledge the
consumer index through that control BAR. Do not silently fall back to ISR polling.

### Enumeration and resource ownership

At the base PDD's ring-0 INIT:

1. Attach to the kernel-resident `OEMHLP$` IDC and use its documented PCI subfunctions to
   query PCI BIOS presence, find the fixed vendor/device ID, and read configuration space. Reject
   zero or multiple matches unless an explicit BDF option selects one. Record BDF, command,
   BAR, BAR size/profile, and interrupt-line byte. The PCI path through `OEMHLP$` is established
   OS/2 practice; PCI.EXE itself reports that it searches through that driver.
   [OS/2 PCI.EXE description](https://www.os2world.com/wiki/index.php/PCI.EXE%3A_A_powerful_sniffing_utility)
   The exact parameter packets and error codes come from Appendix D, "OEMHLP$ Supported IOCtl
   Calls / PCI Subfunctions," in Mastrianni's driver book; copy them from the DDK/book rather than
   recreating BIOS calls ad hoc.
   [Writing OS/2 Warp Device Drivers in C](https://www.os2.kr/komh/os2books/pdf/thirded.pdf)
2. Validate a 32-bit memory BAR below 4 GiB and an IRQ 0..15. Enable PCI Memory Space, but not Bus
   Mastering unless T1 changes the design to DMA into guest RAM. Preserve all unrelated PCI command
   bits.
3. Become RM-aware: link the DDK's `RMCALLS.LIB`, initialize its `Device_Help` variables, call
   `RMCreateDriver`, create a PCI child node, and `RMAllocResource` the memory range and IRQ as
   shared where appropriate. Resource Manager centrally tracks memory regions and IRQs; it does
   not replace PCI discovery or `DevHelp_SetIRQ`.
   [IBM Resource Manager architecture](https://www.edm2.com/index.php/PDDREF%3AResource_Management),
   [IBM RMCALLS linkage and API list](https://www.edm2.com/index.php/PDDREF%3ALinking_Resource_Manager_Services)
4. Fail closed with a clear boot message if discovery, BAR ABI validation, resource claiming, or
   mapping fails. Do not leave `MOUSE.SYS` attached to a driver that will never report input.

### BAR mapping

Allocate one GDT selector during INIT with `DevHelp_AllocGDTSelector`, then map the BAR physical
base and exact length with `DevHelp_PhysToGDTSelector`. Unlike `PhysToVirt`, whose temporary
mapping is invalidated by yielding or another helper call, the GDT selector remains valid until it
is explicitly remapped and is documented for task- and interrupt-time buffers.
[DevHelp_AllocGDTSelector](https://www.edm2.com/index.php/DevHelp_AllocGDTSelector),
[DevHelp_PhysToGDTSelector](https://www.edm2.com/index.php/DevHelp_PhysToGDTSelector),
[temporary PhysToVirt caveats](https://www.edm2.com/index.php/DevHelp_PhysToVirt)

Keep the ring under 64 KiB, use packed fixed-width little-endian structures and compile-time size
checks, and never let C's 16-bit `int` or structure padding define the wire ABI. Treat producer and
consumer fields as volatile; on x86, read producer only after status, copy/validate a complete
record, and publish the consumer before ack. Enforce capacity and sequence checks. On malformed
indices, mask the device interrupt, reset the ring using the negotiated control operation, count an
error, and do not walk outside the BAR.

### INTx service

Register the PCI interrupt with `DevHelp_SetIRQ(isr, irq, 1)` and register bounded stack usage.
The OS service accepts IRQ 0..15 and explicitly supports the shared flag, subject to platform
support and existing ownership.
[DevHelp_SetIRQ](https://www.edm2.com/index.php/DevHelp_SetIRQ)

The ISR must:

1. read the device interrupt-status/producer and set carry if this function is not the source;
2. mask/ack the device source as specified by T1;
3. coalesce superseded consecutive pointer-motion records, but never cross a button/key/wheel
   transition;
4. drain only a strict budget (for example 32 records) to cap interrupt residence time;
5. inject records through the already-enabled mouse/keyboard IDCs;
6. write the consumer/ack, re-check producer to close the lost-wakeup race, and re-arm; and
7. call `DevHelp_EOI(irq)`, clear carry to claim the IRQ, and far-return.

OS/2 requires the handler to use carry to report ownership. `DevHelp_EOI` handles the master/slave
8259 pair and is required for upward compatibility.
[PDD ISR contract](https://www.edm2.com/index.php/PDDREF%3APhysical_Device_Driver_Architecture_and_Structure),
[DevHelp_EOI](https://www.edm2.com/index.php/DevHelp_EOI)

Do not use a context hook for the latency-critical pointer path: the IBM reference says it waits
until an application-level thread would be dispatched. If the ring remains nonempty after the ISR
budget, leave/reassert INTx so another ISR pass drains it; verify this does not starve OS/2's single
CPU.

MSI/MSI-X are out of scope for Warp 4 GA. INTx sharing failure is a spike stop condition, not a
reason to poke the PIC or hard-code an IRQ behind Resource Manager.

## 3. Lowest-latency injection points

### Absolute pointer and buttons: `MOUSE$` `Process_Absolute`

This is the chosen endpoint. `MOUSE.SYS` exposes IDC function `0003h`, `Process_Absolute`, for a
device-dependent PDD. The PDD fills the common event buffer supplied by `Read_Enable`:

```text
Event, Row_Pos, Col_Pos, Row_Size, Col_Size   (all 16-bit)
```

Then it calls the attached `MOUSE$` far IDC with AX=0003h. `MOUSE.SYS` maps the event into the
current display mode and delivers it as a real system mouse event. The interface is non-reentrant
and valid only while enabled, so the driver must serialize it, honor `Read_Disable` /
`Disable_Device`, and never call it before `Read_Enable` supplies the common buffer. Obtain the
far IDC address and target DS with `DevHelp_AttachDD("MOUSE$", ...)` exactly as IBM specifies.
[DevHelp_AttachDD](https://www.edm2.com/index.php/DevHelp_AttachDD)

Coordinate mapping is deliberately simple and contains **no PM Y flip**:

```text
Col_Pos  = clamp(record.x, 0, 32767)
Row_Pos  = clamp(record.y, 0, 32767)
Col_Size = 32767
Row_Size = 32767
```

The IDC contract defines `(0,0)` as upper-left and all values as zero-based; `MOUSE.SYS` performs
the resolution mapping. Thus the 16-byte generic normalized record remains independent of the
current 640x480 Cirrus mode and future mode changes. Do not first map to pixels and do not use
`WinSetPointerPos`.

For buttons, keep a driver-side current bitmask and emit only changed left/right/middle states in
the absolute event's documented `Event` word, at the record's position. Import the event-bit
constants and calling shim from the IBM `familyg`/touch DDK sample; do not infer them from PM's
`WM_BUTTON` constants. Test down, drag, up as separate records. This is expected to fix today's
stale-PS/2-position and `WinPostMsg` limitations, including genuine WPS drag and double-click, but
that expectation is an explicit acceptance test rather than a promise.

`POINTDD.SYS` remains installed: it is pointer-draw support, not the hardware event producer.
IBM's Warp documentation distinguishes `POINTDD.SYS` pointer drawing from `MOUSE.SYS` input.
[IBM OS/2 control-program documentation](https://bitsavers.org/pdf/ibm/pc/os2/OS2_2.x/redbooks/GG24-3730-00_OS2_V2.0_Vol_1_Control_Program_199204.pdf)

### Wheel: fix the known bug without inventing a native event

Warp 4 GA's documented `Process_Absolute` buffer has X/Y and a button-event word but **no Z/wheel
field**. The same reference says the device-dependent IDC can represent up to five buttons while
stock OS/2 supplies specific support only for two- and three-button devices. Therefore it is not
honest to label button 4/5 as a universally supported native wheel path.

Use this staged policy:

1. **Required, deterministic default:** consume ring type 3 separately—never pass it to the
   mouse button encoder—and translate each signed notch into a make+break PageUp/PageDown key pair
   through the keyboard DI IDC described below. Accumulate high-resolution deltas until one notch;
   cap repeats per ISR and carry the remainder. This gives focused-window coarse scrolling and,
   most importantly, fixes the current false-middle-click bug entirely in kernel space.
2. **Optional fidelity experiment, not a capture dependency:** test the IBM ScrollPoint or AMouse
   wheel-aware `MOUSE.SYS` packages in a throwaway clone and determine from their documented IDC
   or source whether button 4/5 can be mapped to line scrolling without a PM helper. IBM's package
   replaces `MOUSE.SYS` and adds desktop DLLs, while AMouse is a third-party wheel stack.
   [IBM ScrollPoint II OS/2 package](https://www.ibm.com/support/pages/node/826882),
   [OS/2 mouse-driver archive](https://www.os2site.com/sw/drivers/mouse/index.html)
3. Do **not** make either replacement part of the initial checkpoint. Historical OS/2 wheel drivers
   had WPS-lock and application-compatibility fixes, and PM-scroll behavior was application
   dependent. The archive explicitly lists a WPS-unlock fix, and Mozilla recorded incompatibility
   with the 2002 PM-scroll behavior.
   [Mozilla OS/2 wheel report](https://bugzilla.mozilla.org/show_bug.cgi?id=178104)

If product requirements demand scroll-under-pointer rather than focused PageUp/PageDown, that is a
separate, non-critical companion: a tiny PM hook/helper can receive deferred wheel counts from the
PDD and post `WM_VSCROLL` (`SB_LINEUP`/`SB_LINEDOWN`) to the appropriate scrollable window. It
reintroduces user-mode scheduling for wheel only and is not the pointer path. Do not call PM APIs
from the ISR, and do not describe this helper as kernel-only.

### Keyboard: `KBDBASE.SYS` device-independent IDC

For ring type 4—and the default wheel translation—attach to the system device-independent
keyboard driver and register/open as a device-dependent producer. OS/2 documents IDC function
`0002h`, **Process Keystroke**, which accepts a complete make/break keystroke packet and says the
buffer can be reused immediately after the call. Preserve make/break and E0 semantics and let
`KBDBASE.SYS` perform layout/code-page translation, session routing, monitors, and PM delivery.
[IBM keyboard driver architecture](https://www.edm2.com/index.php/Input/Output_Device_Driver_Reference/Keyboard_Device_Driver),
[IBM keyboard IDC contract](https://www.edm2.com/index.php/Input/Output_Device_Driver_Reference/Keyboard_Inter-Device-Driver_Communication_Interfaces)

Keyboard is second priority. If the DDK sample reveals unsafe interaction between two
device-dependent keyboard producers on GA, leave keyboard on QEMU's existing PS/2/DBus route;
pointer success must not be held hostage by keyboard scope.

## 4. Auto-start, installation, and checkpoint capture

There is no user-mode daemon to start. On a disposable clone of the image:

1. copy the signed-off build and symbols/map to staging; put only `GWPMOU.SYS` in
   `C:\OS2\BOOT`;
2. preserve a bootable rollback CONFIG.SYS and the original mouse stack;
3. add the base driver in CONFIG.SYS's `BASEDEV` section and replace/order the later mouse lines
   as follows (exact drive spelling follows the guest):

   ```text
   BASEDEV=GWPMOU.SYS
   ...
   DEVICE=C:\OS2\BOOT\POINTDD.SYS
   DEVICE=C:\OS2\BOOT\MOUSE.SYS TYPE=GWPMOU$ QSIZE=100
   DEVICE=C:\OS2\MDOS\VMOUSE.SYS
   ```

   `BASEDEV` takes no path and is loaded before the `DEVICE` phase; retain the guest's existing
   relative ordering for other input/async drivers. Confirm that Warp's automatically loaded
   `RESOURCE.SYS` is available before the first RM call and reject a no-op/-1 Resource Manager
   handle rather than assuming ownership succeeded.
4. remove the `start C:\WARPD.EXE` line from `STARTUP.CMD` only after cold-boot pointer, click,
   keyboard, and wheel fallback tests pass. Keep `WARPD.EXE`, COM1, and its host socket available
   for rollback during the migration window.
5. add exactly one pinned custom PCI `-device` (and its host backend/chardev as T1 specifies) to
   the emitted os2warp launcher and manifest. Keep `pc,acpi=off,usb=off`, Pentium, Cirrus, PCnet,
   and TCG unchanged.
6. **Cold boot** the new device set. Never load the old `golden`. Verify the PDD banner, RMVIEW
   memory/IRQ ownership, armed device status, PM movement/buttons, reboot, and shutdown.
7. create a replacement `golden` only after the driver is loaded and the ring is empty/armed.
   Stop the host event producer or quiesce it before `savevm` so no half-consumed record or
   asserted INTx is captured.
8. restart QEMU with the identical emitted device set and `-loadvm golden`; verify device reset /
   restored BAR state, ring generation renegotiation, interrupt re-arm, sequence baseline, and the
   first input event. The device/driver protocol needs a reset generation so stale host indices
   from before snapshot creation cannot be consumed after restore.

The rollback is atomic: restore the previous launcher/device set **and** its matching pre-driver
checkpoint/CONFIG.SYS. Do not mix a disk carrying `TYPE=GWPMOU$` with a launcher lacking the device.

## 5. Language decision

- **Rust: no for the guest.** There is no demonstrated Rust target, 16:16 ABI, OS/2 driver
  loader, DevHelp binding, or DDK/RMCALLS integration that produces a loadable Warp 4 PDD.
- **C: yes, primary.** Use restricted 16-bit C89 with no standard runtime, dynamic allocation, or
  floating point in the resident path. OpenWatcom 1.9 and the IBM DDK are concrete OS/2 targets.
- **Assembly: minimal and required.** Use `wasm` only for the device header/segment declarations,
  strategy and IDC register shims, ISR prologue/epilogue, carry ownership, far calls/returns, and
  any DevHelp glue the DDK does not express safely in C. Keep parsing, validation, coalescing, and
  state machines in C.

This honors Rust > C > assembly by choosing the highest language with a real loadable target and
limiting assembly to ABI boundaries. Host streamhost remains Rust and the QEMU device remains C as
assigned to T1.

## 6. Effort, risks, fallback, and gates

Estimate for one engineer familiar with C but not this DDK: **18-28 engineer-days (about 4-6
calendar weeks)** after T1 provides a stable device ABI and test injector.

| Risk | Consequence | Mitigation / stop condition |
|---|---|---|
| 16-bit PDD ABI, scarce DDK tooling | boot trap or silent corrupt state | Start from IBM `familyg`/OpenWatcom PDD samples; retain serial debug and a bootable CONFIG.SYS rollback; no production work until inert-PDD and IDC spikes pass. |
| Non-reentrant `MOUSE$` common buffer | corruption under nested events | One ISR producer, device masking, explicit enabled/busy state, bounded ring; never call from both ISR and context hook. |
| Shared INTx on Warp 4 GA | missing/storming IRQ, system hang | RM shared claim, status ownership test, `SetIRQ(...,1)`, correct EOI, watchdog counters; stop if 10^6-event stress or snapshot restore loses/storms an IRQ. |
| BAR mapping/cache semantics | MMIO exits or invalid selector make it slower | <=64 KiB 32-bit BAR, persistent GDT selector, QEMU RAM region, measure exits/latency; ack through a control BAR if shared-page stores are unsafe. |
| MOUSE driver replacement semantics | physical PS/2 fallback disappears | Expected for the gallery; keep COM1 `WARPD.EXE`, alternate CONFIG.SYS, and matched pre-driver checkpoint. |
| Wheel has no Warp 4 GA native IDC field | false clicks or incompatible scroll | Separate type 3, kernel PageUp/PageDown default, optional wheel stack/PM helper only after compatibility tests. |
| Snapshot restores stale ring/IRQ state | ghost input or dead input after `loadvm` | protocol generation/reset handshake, empty ring before save, restore test repeated at least 100 times. |
| ISR does too much work | system latency or stack overflow | coalesce move-only records, strict budget, register stack usage, leave/reassert interrupt for remainder. |
| Pointer gain is hidden by framebuffer polling | little measured E2E improvement | measure enqueue-to-cursor p50/p95/p99 under idle/load against serial; keep driver only if tail latency materially improves. |

Fallback is the already-captured serial `WARPD.EXE` and matching launcher/checkpoint. Keep it if any hard
gate fails, or if measured p95/p99 under CPU load is not materially better enough to justify the
maintenance burden. A sensible production gate is at least a 2x reduction in loaded p95 and p99,
no regression in idle p50, zero lost button transitions/keys in 10^6 mixed records, and 100/100
successful checkpoint restores. The cross-cutting measurement plan may tighten those values.

## 7. Phased implementation plan

### Phase 0 — preserve and baseline (1-2 days)

- Record current cold-boot and checkpoint-restored CONFIG.SYS/STARTUP.CMD, `RMVIEW /IRQ` and
  `/MEM`, PCI.EXE output, display mode, MOUSE/POINTDD/VMOUSE versions, and current agent digest.
- Use the shared measurement harness to baseline serial warpd p50/p95/p99 idle and under a
  repeatable single-CPU load. Separately record motion, down-drag-up, double-click, and wheel (the
  erroneous middle-click) behavior.
- Make a disposable disk/snapshot lineage; all later guest writes happen there, never in the live
  gallery image.

### Phase 1 — feasibility spike (4-6 days, hard gate)

- Acquire/hash the exact IBM DDK inputs and prove a reproducible OW 1.9 inert base-PDD build with
  map file. Cold-load it, expose a read-only diagnostic IOCtl/banner, and prove that the later
  `MOUSE.SYS TYPE=GWPMOU$` attaches to its device-dependent IDC.
- Add the T1 custom PCI device only to a disposable QEMU invocation. Prove `OEMHLP$` discovery,
  BAR/IRQ reads, Resource Manager claims, one-selector BAR mapping, and INTx ownership/EOI with a
  monotonic host test counter.
- Implement only the mouse IDC handshake plus one `Process_Absolute` event. Prove exact corner and
  center placement without a Y flip, then genuine left down/drag/up and WPS double-click.
- **Go only if** all three pieces work after cold boot and repeated interrupt load. Otherwise write
  down the failing ABI/service and return to serial warpd.

### Phase 2 — production driver (10-15 days)

- Freeze/version the ring ABI. Add bounds, sequence/generation, reset, loss counters, interrupt
  mask/ack race closure, move coalescing, and bounded drain.
- Add full absolute/button state transitions and mouse enable/disable lifecycle.
- Add `KBDBASE.SYS` Process Keystroke for keys; if safe, use it for deterministic wheel
  PageUp/PageDown. Explicitly test that buttons 4/5 can never reach the middle-button encoder.
- Stress mixed motion/button/key/wheel, IRQ sharing with PCnet/SB16 activity, CPU load, malformed
  ring state, warm reboot, shutdown, and 10^6 records. Remove debug prints from ISR; retain queryable
  counters.
- Optional and separately gated: evaluate IBM/AMouse or PM scroll-under-pointer compatibility.

### Phase 3 — capture and restore (2-3 days)

- Install the PDD and ordered CONFIG.SYS on the disposable candidate, cold boot with the final
  emitted device set, and complete functional tests.
- Disable WARPD autostart but retain its files/serial rollback. Quiesce and save the replacement
  checkpoint.
- Perform at least 100 launcher restarts/restores, injecting first input at varied times; reject any
  ghost event, stuck INTx, stale coordinate, or missing first event.
- Promote launcher, manifest, disk/checkpoint, driver artifact/digest, build recipe, and rollback as one
  coordinated change.

### Phase 4 — measure and decide (2-4 days)

- Repeat the shared host-enqueue-to-first-cursor-frame benchmark at the same 640x480 mode and
  streamhost display settings. Report p50/p95/p99 for idle and CPU-bound load, serial baseline
  versus PDD, plus missed/overwritten/coalesced counts.
- Run interaction correctness suites for exact positions, double-click, drag, all three buttons,
  key make/break, wheel direction/remainder, DOS/WIN-OS/2 forwarding if in scope, and checkpoint restore.
- Promote only on the quantitative/correctness gates above. Otherwise restore the matched serial
  warpd launcher and checkpoint; retain the spike notes rather than carrying an unproven ring-0 binary.

## Reference shortlist

- IBM, [Physical Device Driver architecture](https://www.edm2.com/index.php/PDDREF%3APhysical_Device_Driver_Architecture_and_Structure)
  and [driver Resource Manager](https://www.edm2.com/index.php/PDDREF%3AResource_Management).
- IBM, [mouse device-driver IDC](https://www.edm2.com/index.php/Input/Output_Device_Driver_Reference/Mouse_Device_Driver)
  and [touch-to-absolute-mouse design](https://www.edm2.com/index.php/Input/Output_Device_Driver_Reference/Touch_Display_Device_Driver).
- IBM, [keyboard device-driver design](https://www.edm2.com/index.php/Input/Output_Device_Driver_Reference/Keyboard_Device_Driver)
  and [keyboard IDC interfaces](https://www.edm2.com/index.php/Input/Output_Device_Driver_Reference/Keyboard_Inter-Device-Driver_Communication_Interfaces).
- IBM DDK mirrors, [SetIRQ](https://www.edm2.com/index.php/DevHelp_SetIRQ),
  [EOI](https://www.edm2.com/index.php/DevHelp_EOI),
  [AttachDD](https://www.edm2.com/index.php/DevHelp_AttachDD), and
  [persistent physical mapping](https://www.edm2.com/index.php/DevHelp_PhysToGDTSelector).
- OpenWatcom, [version 1.9 supported targets](https://open-watcom.github.io/open-watcom-1.9/c_readme.html).
- QEMU, [ivshmem user documentation](https://www.qemu.org/docs/master/system/devices/ivshmem.html)
  and [PCI device specification](https://gitlab.com/qemu-project/qemu/-/blob/master/docs/specs/ivshmem-spec.rst).
- Steven J. Mastrianni, [Writing OS/2 Warp Device Drivers in C](https://www.os2.kr/komh/os2books/pdf/thirded.pdf),
  especially the OEMHLP PCI appendix and mouse/VDD chapters.
