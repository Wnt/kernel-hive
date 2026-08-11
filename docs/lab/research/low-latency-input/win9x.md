# Windows 95 OSR2 / Windows 98 SE low-latency input plan

Status: **research / implementation plan (2026-07-15)**. No driver or QEMU change has been made.
This plan answers every item in the [generic per-OS template](00-generic-plan.md) for the two
Win9x guests.

## Verdict

**Conditional GO for a bounded VxD spike; no unconditional production GO.** A 32-bit x86
Plug-and-Play VxD can bind a PCI function through Win9x Configuration Manager, map its assigned
resources, service a shareable legacy INTx through VPICD, and enter the Win9x mouse/keyboard stack
without waiting for a network/serial reader process. Contemporary Microsoft material even shows
`VMD_Post_Absolute_Pointer_Message` being called from interrupt time. The transport half is therefore
credible.

The injection half is the qualification:

- **Win95 OSR2:** worth the spike. It currently traverses QEMU SLIRP/PCnet, Winsock, the scheduled
  `warpnet.exe`, ASCII parsing, `SetCursorPos`, and (for non-production button tests) `mouse_event`.
  Removing that path should materially reduce load-dependent tail latency. However, Microsoft
  confirmed that Win95's exact VMOUSE absolute service is broken. Its official workaround hooks the
  VMOUSE protected-mode API and schedules a time-critical VM event which calls USER's registered
  mouse callback. That is much shorter and higher priority than `warpnet`, but it is not a magically
  synchronous cursor update inside the hardware ISR. Fullscreen DOS mouse ownership is another hard
  compatibility constraint.
- **Win98 SE:** technically easier, but likely **NO-GO on value** unless measurement proves otherwise.
  The actual station no longer uses `warpnet`: it already has an in-kernel, absolute `usb-tablet` path.
  A custom PCI VxD may shave USB/HID emulation overhead, but it takes on far more compatibility risk.
  Build the same binary for Win98 during the common spike; do not ship it merely for uniformity.

Ship per OS only if the driver survives cold boot, snapshot restore, IRQ sharing and DOS/fullscreen
tests, while beating the actual baseline at p95/p99 under load. Otherwise retain the existing
Win95 `warpnet` plus QEMU-PS/2-button hybrid and the Win98 USB tablet. A hardware-cursor-only shortcut
is a no-go: it could move pixels quickly but would leave USER's cursor position, hit testing, window
messages and button ownership inconsistent.

## Actual system being changed

This is not a generic “old Windows” VM:

| Guest | Current realtime pointer path | Pinned machine/device facts | Consequence |
|---|---|---|---|
| Win95 OSR2 | `streamhost/guest-agents/win9x/warpnet.c`: Winsock 1.1 TCP `:7777`, ASCII `M/P/R/B`, `SetCursorPos`; production buttons remain on emulated PS/2 | 256 MiB, one Pentium, `pc,acpi=off,usb=off,kernel-irqchip=off`, `-cpu pentium,-apic`, standard VGA, SB16, PCI PCnet | PIC/legacy INTx only. PCI is nevertheless alive (the working PCnet proves it). The new function must work without ACPI, APIC, USB or an in-kernel irqchip. |
| Win98 SE | QEMU `usb-tablet`, already absolute and kernel serviced; no agent | 384 MiB, one Pentium III, `pc,acpi=on`, APIC/default irqchip, standard VGA, SB16, PCI PCnet, UHCI plus tablet | PCI enumeration depends on keeping ACPI on. The baseline is the tablet, not old serial/TCP notes. |

The live launchers are `streamhost/tiles/win95/qemu-streamhost.sh` and
`streamhost/tiles/win98se/qemu-streamhost.sh`; the current behavior and history are recorded in
`streamhost/guest-agents/win9x/README.md` and `docs/guests/win9x.md`. Read-only CT950 inspection on
2026-07-15 found QEMU `11.0.2 (pve-qemu-kvm_11.0.2-1)`, only
`i686-w64-mingw32-gcc` among the candidate historical driver tools, and an
`ivshmem-doorbell` property list with no legacy-IRQ/`msi=off` switch.

Adding any PCI function changes the launcher's pinned device set. Neither existing `golden` snapshot
may be loaded with the old device topology and then retrofitted; both must be cold-booted with the
new function, have the driver installed and verified, and be saved again.

## 1. Driver model and toolchain

### Chosen model: one Win95-compatible Plug-and-Play VxD

Use one 32-bit x86 Plug-and-Play VxD, provisionally `GLLI.VXD`, as the function driver for a dedicated
PCI hardware ID. Its INF uses Configuration Manager as the device loader:

```ini
[Gallery.Device]
CopyFiles=Gallery.Copy
AddReg=Gallery.AddReg

[Gallery.AddReg]
HKR,,DevLoader,,*CONFIGMG
HKR,,DeviceDriver,,GLLI.VXD
```

The real INF also needs Win95-compatible `[Version]`, manufacturer/models, `PCI\VEN_1B36&DEV_xxxx`,
destination/copy sections and an uninstall/rollback record. Microsoft's generic PnP VxD loading
sample gives exactly the `*CONFIGMG`/`DeviceDriver` arrangement
([Q140731](https://ftp.zx.net.nz/pub/Patches/ftp.microsoft.com/MISC/KB/en-us/140/731.HTM));
the companion static/dynamic loader note repeats it
([Q180578](https://www.betaarchive.com/wiki/index.php/Microsoft_KB_Archive/180578)).

On `PNP_New_DevNode`, the VxD registers a configuration handler with
`CONFIGMG_Register_Device_Driver`. That handler owns `CONFIG_START`, `CONFIG_STOP`, removal and power
transitions. Microsoft documents the registration signature and flags, including the Win98
`CM_REGISTER_DEVICE_DRIVER_ACPI_APM` behavior
([Q247251](https://ftp.zx.net.nz/pub/archive/ftp.microsoft.com/MISC/KB/en-us/247/251.HTM)).
Register it **static + synchronous**, because the PCI function is fixed at boot, VPICD has no safe
general-purpose “unhook this shared IRQ and unload my code” lifecycle to rely on, and the Win95 VMOUSE
workaround cannot unhook `Hook_Device_PM_API`. On Win95, also load the same file at startup through
its `StaticVxD` service entry; the INF still supplies the PCI hardware binding and CONFIGMG resources.
On Win98 the PnP load is sufficient unless testing proves the common static lifetime simpler. Include
the ACPI/APM flag when the running CONFIGMG version supports it. Keep the control dispatcher and all
ISR-reachable code/data in locked segments.

This common VxD is preferable to WDM. Windows 98 implements WDM 1.0
([Microsoft's WDM version table](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-ioiswdmversionavailable)),
but an unmodified Win95 OSR2 scene is not a dependable WDM target. A WDM function driver would
therefore create a second implementation and still would not solve the Win95 VMOUSE interface.

### Reproducible build decision

The reference/oracle build should be made in a disposable, checksummed 32-bit Windows build VM with:

- Microsoft Windows 98 DDK headers, libraries, samples and tools;
- Microsoft Visual C++ 5.0 SP3 x86 compiler/linker; and
- MASM 6.11d (`ML.EXE`, supplied in the Win98 DDK) for the small VxD shell, DDB/control dispatcher,
  VxDCall wrappers and interrupt thunk.

The archived DDK product requirements say Visual C++ must be installed before the Win98 DDK
([Win98 DDK requirements](https://www.shopmsdn.com/detail-MicrosoftWindows98DriverDevelopmentKit%28DDK%29-389.html));
Microsoft's VxD wrapper note points to the DDK's `BASE\SAMPLES\CVXD32` C-wrapper example
([Q131030](https://ftp.zx.net.nz/pub/archive/ftp.microsoft.com/MISC/KB/en-us/131/030.HTM)).
Pin the build VM image hash, DDK media hash, compiler versions, environment batch file, exact commands,
map file and resulting VxD hash in the repository. Do not install this unsupported toolchain on CT950.
Set the Win98 DDK makefile's `WIN40COMPAT` option and audit the DDB SDK/minimum version so the output
advertises Win4.0 compatibility instead of the DDK's Win4.10 default; this exact omission is known to
make Win98-DDK-built VxDs fail on Win95
([contemporary `WIN40COMPAT` report](https://groups.google.com/g/microsoft.public.win32.programmer.kernel/c/VJScJbhQBYM)).
Link no 4.10-only service statically into the common path; runtime-gate the Win98 APM calls. A
successful cold load on the exact OSR2 clone is part of the toolchain acceptance test, not an assumed
binary-compatibility claim.

Toolchain alternatives were weighed as follows:

| Candidate | Assessment |
|---|---|
| Microsoft Win98 DDK + VC5 SP3 + MASM | **Chosen oracle.** It matches the headers, calling conventions, LE VxD image format, samples and VMM/CONFIGMG/VPICD macros being used. Proprietary availability is a reproducibility/licensing cost, hence the hermetic build VM and hashes. |
| Open Watcom v2 (`wcc386`, `wasm`, `wlink`) | **Promising second build, not the initial oracle.** Its linker explicitly supports `system win_vxd dynamic` and 32-bit Win95 images ([Open Watcom linker guide](https://open-watcom.github.io/open-watcom-v2-wikidocs/lguide.pdf)). It is a good route to a Linux-hosted reproducible build, but first prove its MASM compatibility, section locking, DDK structure packing, name decoration, service wrappers and byte-level DDB/LE output against the known-good Microsoft build. CT950 does not currently have it installed. |
| Vireo VToolsD | Technically helpful C/C++ wrappers and IRQ classes, but obsolete commercial middleware with an uncertain redistributable license and no current installation. It would add a dependency harder to preserve than the driver. Use its documentation only as corroboration, not generated runtime/framework code. |
| `i686-w64-mingw32-gcc` | **Not a VxD toolchain.** It is present on CT950 and correctly builds current `warpnet.exe`, but its target is `i686-w64-mingw32` and its linker exposes only `i386pe`; it emits Win32 PE executables/DLLs, not LE VxDs or VMM DDB/control records. Keep it only for the fallback agent or test utilities. |

### Language decision (Rust -> C -> assembly)

- **Guest driver: freestanding C, with a small amount of x86 assembly.** C holds protocol validation,
  ring draining, coalescing, state machines and CONFIGMG callbacks. Assembly is confined to the DDB,
  control dispatch, VxD service call wrappers, register-contract ISR entry/exit and the Win95 VMOUSE
  workaround where the published interface is register-oriented.
- **Not Rust:** there is no supported Rust target/linker/ABI for a Win9x LE VxD, no bindings for VMM
  locked sections or VxDCall conventions, and no viable panic/runtime story. A Rust-shaped core linked
  through C would increase unproven ABI surface without removing the required assembly.
- **Not C++:** constructors, exceptions, RTTI and framework runtime behavior at ring 0 are liabilities.
  VToolsD could make C++ load, but gives no latency or correctness advantage for this tiny driver.
- **Host streamhost remains Rust; QEMU device model remains QEMU-style C.** Those components belong to
  the cross-cutting plans, not this VxD binary.

Build both a checked/debug VxD (serial/Bochs debug port counters only, no filesystem or Win32 calls in
the ISR) and a stripped release VxD. Generate a link map and mechanically assert that ISR entry,
ring state, VMOUSE/VKD wrappers and every called helper reside in locked code/data sections.

## 2. Transport binding: PCI enumeration, BAR/ring and IRQ

### Device contract required by Win9x

Prefer the cross-cutting plan's **custom minimal `gallery-hid` PCI function** over stock ivshmem for
this OS family. Give it a fixed QEMU vendor/device/revision ID, one **32-bit, non-prefetchable control
BAR below 4 GiB**, bus-master capability, and one level-triggered legacy INTx pin. It must not require
MSI, MSI-X, PCIe capabilities, ACPI methods, 64-bit BAR allocation or hotplug.

Use normal guest RAM for the event ring, not trap-heavy MMIO reads:

1. On `CONFIG_START`, allocate and lock a small page-aligned common buffer in system memory. Start
   with one physically contiguous 4 KiB page—enough for header plus hundreds of 16-byte records—and
   obtain its physical address through the Win98 DDK VMM page/lock services. If the chosen VMM API
   cannot return a stable physical address on both images, use VDMAD's buffer/lock service instead.
2. Zero the header, set protocol version/generation, consumer and capacity, then program the 32-bit
   ring physical address and size into BAR0. The QEMU model DMA-writes records and producer index into
   ordinary write-back guest RAM. This meets the generic plan's cacheable-ring requirement without
   relying on the cache attributes of the PCI hole.
3. BAR0 is used only for feature/version negotiation, ring address/size, interrupt status/mask/ack,
   device generation and fatal/error counters. It is not the data path.

A direct shared-memory BAR is the secondary spike if guest-RAM allocation is the only blocker.
`CONFIGMG_Get_Alloc_Log_Conf` yields its physical memory window; reserve a system linear page range,
map the assigned physical pages using `PageReserve` + `PageCommitPhys`, and lock it globally. NXP's
Win95 PCI-agent application note supplies concrete source for exactly
`CONFIGMG_Get_Alloc_Log_Conf`, `PageReserve`, `PageCommitPhys`, `LinPageLock` and VPICD setup
([AN1780](https://www.nxp.com/docs/en/application-note/AN1780.pdf)). Do not call a BAR mapping
“cacheable” until an in-guest benchmark and page-table/MTRR inspection prove it; falling back to an
uncached but directly mapped RAM BAR may still avoid VM exits, but it no longer satisfies the ideal
cache budget.

Stock `ivshmem-plain` has no interrupt. Stock modern `ivshmem-doorbell` exposes BAR0 registers,
an MSI-X BAR and the shared-memory BAR; QEMU documents those interfaces
([ivshmem device specification](https://qemu-project.gitlab.io/qemu/specs/ivshmem-spec.html)). The
spec retains a description of revision-0 legacy INTx, but CT950's actual QEMU 11.0.2 device exposes no
property to disable MSI-X. Its server/migration semantics also complicate `savevm`/`loadvm`
([QEMU ivshmem manual](https://qemu.readthedocs.io/en/v7.2.19/system/devices/ivshmem.html)). Thus it
is not a usable no-code shortcut here. T1 could modify ivshmem to restore reliable legacy INTx, but at
that point a tiny purpose-built function with a 32-bit guest-RAM ring is simpler to specify and test.

### Enumeration and resource ownership

Do **not** scan config mechanism #1 ports `0xCF8/0xCFC` and do not issue PCI BIOS `INT 1Ah` from the
normal driver. Both bypass Win9x PnP resource arbitration; the BIOS interrupt is also an awkward
real-mode boundary from a protected-mode VxD. Let PCI.VXD enumerate the hardware ID and CONFIGMG
assign resources. If configuration-space access is needed for a diagnostic or to verify command bits,
use `CONFIGMG_Call_Enumerator_Function`, which Microsoft specifically documents for Win95 PCI config
space ([Q140730](https://www.betaarchive.com/wiki/index.php/Microsoft_KB_Archive/140730)). Never size
or rewrite a live BAR behind CONFIGMG.

The VxD path is:

1. INF match causes `*CONFIGMG` to load `GLLI.VXD`; `PNP_New_DevNode` supplies the device node.
2. Register the configuration handler. At `CONFIG_START`, call
   `CONFIGMG_Get_Alloc_Log_Conf`/the DDK's `CMCONFIG` form and require exactly the expected 32-bit
   memory window plus one IRQ. Record `dMemBase/dMemLength`, `bIRQRegisters` and IRQ attributes.
3. Map only the assigned BAR, validate device magic/version/features, allocate/register the ring,
   then virtualize the assigned IRQ. Finally unmask the device and VPICD line. Return failure to
   CONFIGMG rather than guessing if any resource or feature is wrong.
4. On `CONFIG_TEST`, reject removal while active. On `CONFIG_STOP`/power down, mask the device,
   deassert/ack INTx and quiesce DMA, but keep the static VxD's locked code and VPICD callback resident.
   Release mappings/pages only at a lifecycle point proven safe by the DDK and checked VMM. On Win98
   resume, revalidate device generation and reprogram the ring before unmasking. The test-only device
   disable flow may require a reboot; runtime unload is not a product requirement.

This flow follows the PnP configuration function model described in Microsoft's contemporary
driver article, including `CONFIG_START`/`CONFIG_STOP`
([Microsoft Systems Journal, Dec. 1995](https://jacobfilipp.com/MSJ/1995/1995-12.pdf)).

### Shared INTx service

Fill a `VPICD_IRQ_Descriptor` with the CONFIGMG-assigned IRQ, a locked hardware interrupt procedure,
`VPICD_OPT_CAN_SHARE` (and reference-data option if used), then call `VPICD_Virtualize_IRQ` outside
interrupt context. VPICD requires every owner of a shared IRQ to opt into sharing and defines the
handled/not-handled return convention
([Microsoft DDK VPICD chapter mirror](https://www.pcjs.org/documents/books/mspl13/win/w3ddkvxd/));
Microsoft also corrected how reference data is delivered in
[Q152541](https://helparchive.huntertur.net/document/37473)).

The locked ISR must be short and deterministic:

1. Read BAR0 interrupt status first. If the device's cause bit is clear, return **not handled** so the
   next shared handler runs; do not send a device ack.
2. Mask the device cause (not the whole PIC), apply an x86/compiler read barrier, read producer and
   drain validated ring records. Coalesce only consecutive motion-only records to the newest point;
   never coalesce across a button/key/wheel transition. Cap work per entry (for example 64 records)
   and leave/reassert level INTx if more remain.
3. Publish consumer with a compiler/write barrier, acknowledge/deassert the device, then call
   `VPICD_Phys_EOI(irq_handle)`. A VPICD hardware callback returns to VMM, not with `iret`; Microsoft's
   VxD ISR example makes both rules explicit
   ([Dr. Dobb's VxD shell](https://jacobfilipp.com/DrDobbs/articles/DDJ/1996/9614/9614d/9614d.htm)).
4. Unmask the device and recheck producer/status to close the lost-wakeup race.

INTx is deliberately level-triggered: an event cannot be lost merely because interrupts were
disabled. Nonetheless Win9x is not a hard realtime system; even a VxD ISR can be delayed when legacy
code disables CPU interrupts. The ring and “newest motion wins” policy bound the visible consequence.

### Snapshot/backend generation

`loadvm golden` restores guest RAM, VxD state and PCI device state but not a Unix socket's external
peer. The device/backend protocol therefore needs a migration-safe generation register:

- QEMU saves device features, ring GPA/size, producer, INTx mask/pending state and generation;
- on backend (re)connect, QEMU increments generation, discards unconsumed pre-connection host input,
  and raises INTx;
- the ISR detects a changed generation, resets consumer to the advertised clean producer, republishes
  readiness and button state, and only then accepts new events; and
- the host sends an initial absolute position plus complete current button/key state after ready.

Test this both for an in-process QMP `loadvm` and for a fresh QEMU process started with `-loadvm
golden`. Stale button-down records after a reset are a release blocker.

## 3. Lowest-latency coherent injection point

### Chosen point: VMOUSE/VMD absolute service, with the documented Win95 repair

The single lowest legitimate injection point is **VMOUSE.VXD's
`VMD_Post_Absolute_Pointer_Message` (service 0x000B)**, called from the PCI VxD's locked interrupt
path when the System VM owns the mouse. It is below `mouse.drv`, USER's cursor state/message
generation and the Win32 API, while still preserving the OS's one authoritative cursor and hit-test
state. A period implementation describes an IRQ handler passing absolute X/Y and button value
directly to VMD and scan codes to VKD
([US Patent 6,243,772 implementation description](https://patents.justia.com/patent/6243772)).

On **Win98 SE**, first call `VMD_Get_Version`, verify the service exists, and spike this direct call.
It is the intended fast path. Do not silently use undocumented USER globals if it fails.

On **Win95 OSR2**, do not pretend the service is reliable: Microsoft confirmed that
`VMD_Post_Absolute_Pointer_Message` fails to call USER's Mouse_Event correctly. Implement its
published workaround verbatim in structure:

- make this VxD static for the input-hook portion because `Hook_Device_PM_API` has no corresponding
  unhook;
- hook the VMD protected-mode API, capture `VMDAPI_SET_MOUSE_EVENT_CALLBACK`, initialize and track
  VMOUSE focus through `Set_Device_Focus`;
- from IRQ time, retain only the newest pending absolute state and schedule one
  `Call_Priority_VM_Event` with `TIME_CRITICAL_BOOST` and
  `PEF_Wait_For_STI | PEF_Always_Sched`; and
- in that event, `Begin_Nest_Exec`/`Simulate_Far_Call` the registered USER Mouse_Event callback with
  the absolute bit (`0x8000`), coordinates, button count and state.

The source, register contract, interrupt-time assumption and static-driver caveat are all in
[Microsoft KB Q139292](https://www.betaarchive.com/wiki/index.php?title=Microsoft_KB_Archive/139292).
This deferred time-critical callback—not a normal thread or app—is the lowest known coherent Win95
path. The spike must compare it with the direct service because OSR2 may contain a newer VMOUSE than
the original Win95 build, but the release path must not assume an undocumented fix.

### Coordinates, movement and buttons

The transport's 0..32767 coordinate maps to USER's normalized 0..65535 domain as:

```text
u16 = round(clamp(input, 0, 32767) * 65535 / 32767)
pixel = round(u16 * (display_extent - 1) / 65535)
```

Pass the normalized value and `SF_ABSOLUTE`/absolute bit; USER maps it to the current primary display,
so the ISR neither calls GDI nor queries resolution. Microsoft documents the 0..65535 mapping and
that relative motion is subject to speed/acceleration
([`mouse_event` coordinate semantics](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-mouse_event)).
The station is single-monitor, so Win98's multi-monitor absolute limitation is irrelevant; nevertheless
verify all four corners and center after every resolution/mode switch.

Maintain a complete button state and derive the transition flags expected by USER/VMD. Before every
button transition, inject the latest position so hit testing uses the intended coordinates. Never
implement click as `Sleep(15)` in the VxD: host down/up records carry real ordering and timing.

Win95 production currently routes buttons through QEMU PS/2 for a good reason: a Windows-level click
can steal focus from a fullscreen DOS VM and crash the game's VESA session. Preserve a per-station
**hybrid policy** initially: VxD absolute movement for the System VM, QEMU PS/2 buttons always. The
driver may implement VMD desktop buttons for measurement, but they ship only after fullscreen DOS
ownership tests pass.

The Win95 workaround explicitly states that VMD absolute injection does not handle DOS VMs. The
driver must track mouse focus. When focus is not the System VM, it must not call USER. The complete
solution needs one of these measured behaviors, in preference order:

1. expose a one-bit guest focus state to the QEMU device/host and have streamhost route motion and
   buttons through ordinary PS/2 while a DOS VM owns the mouse;
2. retain PS/2 for buttons and ignore remote absolute motion in fullscreen DOS if the curated games
   are keyboard-only; or
3. keep the complete existing warpd/PS2 hybrid on Win95.

Duplicating every move into both VMD and PS/2 is not acceptable because it reintroduces acceleration
and double motion on the desktop.

### Wheel and keyboard

- **Keyboard:** feed Set-1 make/break scan codes through VMOUSE's peer **`VKD_Force_Keys`**, which
  inserts them as physical keyboard input. Microsoft explicitly recommends that service for forcing
  scan codes from a VxD
  ([Q169588](https://www.betaarchive.com/wiki/index.php/Microsoft_KB_Archive/169588)). Preserve E0/E1,
  modifier and key-up state; reset stuck keys on generation change. Do not inject translated ASCII.
- **Wheel:** no source found establishes a Win95/98 VMOUSE kernel service equivalent to the modern
  `MOUSEEVENTF_WHEEL` data field. This is an explicit spike question, not a fabricated API. Inspect
  the licensed Win98 DDK's VMOUSE headers/samples and the actual VMOUSE exports. If it provides a
  documented wheel call, use it from the same priority-event path. Otherwise:
  - on Win98, post a correctly targeted `WM_MOUSEWHEEL` through a documented SHELL/VxD mechanism only
    if it behaves like system input in Notepad, Explorer and DirectInput tests;
  - on Win95, where wheel support may depend on IntelliPoint, retain the existing `mouse_event` helper
    for wheel only or declare wheel unsupported on the kernel path.

Wheel is not allowed to block the pointer-motion replacement. A tiny fallback wheel hop may retain
usermode scheduling for wheel, but movement/buttons/keys must not traverse it. Document the measured
behavior per checkpoint.

### Why not drive the display driver's cursor directly?

The display driver's cursor callbacks run close to hardware and can move a sprite at interrupt time,
but that is only visual output. It bypasses USER's cursor coordinates, clipping, capture, hit testing,
window messages, double-click state and mouse ownership; synthesizing buttons afterward can target a
different point. It also couples input to the currently installed VBEMP/standard-VGA display driver.
Use it only as a diagnostic timestamp marker, never as the production injection mechanism.

## 4. Auto-start, installation and checkpoint capture

### Development installation

1. Work only on disk clones. Add the final PCI function with a fixed `addr=` to the clone launcher
   before the first driver boot. Save `info pci`, Device Manager resources and QEMU logs.
2. Put INF and VxD on a read-only test ISO/floppy or offline-copy them into a staging directory.
   Use Add New Hardware/Device Manager to bind the exact PCI ID; do not manually edit live registry
   resource values.
3. Confirm Device Manager has no yellow bang, the assigned BAR/IRQ matches QEMU, the VxD reports
   protocol-ready counters, and an idle/shared IRQ does not storm. Reboot twice and exercise disable,
   re-enable and shutdown.
4. For Win95's static VMOUSE hook, install the VxD through the documented static VxD registry path
   `HKLM\System\CurrentControlSet\Services\VxD\...`/`StaticVxD` (or the DDK-prescribed equivalent)
   and leave the PCI device's resource binding with CONFIGMG. Windows loads registry static VxDs at
   startup as described in Microsoft's startup documentation
   ([Initializing static VxDs](https://techshelps.github.io/MSDN/DNWIN95/HTML/S6F38.HTM)). Avoid
   editing or rebuilding the monolithic `VMM32.VXD`; a separate file is recoverable from Safe Mode.

Have a DOS/Safe-Mode rollback that removes the separate VxD and its service/INF binding. A bad static
VxD can prevent the desktop from booting, so every test disk needs an untouched clone and an automated
offline removal recipe.

### Golden integration

For each station independently:

1. Back up all qcow2s and their internal snapshots. Add the exact custom PCI device/backend arguments
   to `qemu-streamhost.sh` and the emitted launcher/device ledger. Use a stable PCI address and socket
   path. Win95 retains all fragile machine flags; Win98 retains `acpi=on`, APIC/default irqchip and
   initially retains the USB tablet as an A/B fallback.
2. Boot **cold**, allow PnP to bind the already-staged INF/VxD, reboot as required, verify the driver
   is ready before the scene UI settles, and exercise input. Do not load the old snapshot.
3. Remove/disable `warpnet.exe` auto-start on the candidate Win95 disk only after the PCI path passes;
   keep the binary present for rollback. Keep QEMU PS/2 buttons enabled. On Win98, keep the USB tablet
   until benchmark cutover; avoid sending duplicate motion.
4. Re-run the existing determinism/reactivity capture, delete the old internal snapshot and `savevm
   golden` with the VxD loaded, ring armed and device generation clean. Win98's snapshot spans both
   C: and D: images; preserve their consistency.
5. Kill QEMU, start a new process with `-loadvm golden`, reconnect the host backend, and verify first
   movement, down/up state, keys, no stale events and framebuffer identity. Then exercise repeated
   QMP `loadvm golden` without restarting QEMU.
6. Only after measurement, change the manifest pointer selection to the new backend and regenerate
   emitted configuration. Rollback restores the old launcher+checkpoint pair together—not just one side
   of the device set.

`loadvm` success means the driver is already resident and armed; no `WIN.INI load=` program is needed.
Command execution remains on the existing slower agent/channel if required.

## 5. Effort, risks, gates and fallback

### Estimate

Assuming T1 supplies a documented, migration-capable custom PCI model and host socket, this is roughly
**30-48 focused engineer-days (6-10 weeks)** for one engineer familiar with C/x86 but new to Win9x:

| Work | Estimate | Exit result |
|---|---:|---|
| Toolchain + loadability + PCI/INTx spike | 6-9 d | Reproducible VxD loads on both clones, reads BAR, survives shared interrupts, counter increments from host doorbell |
| Absolute injection spike | 6-10 d | Win98 direct VMD and Win95 Q139292 path move to five exact points; buttons and VKD keys proven; DOS focus behavior characterized |
| Production driver hardening | 10-16 d | Ring validation/coalescing, barriers, bounded ISR, stop/resume/generation, diagnostics, INF, rollback, stress tests |
| Checkpoint capture/integration | 4-7 d | Cold PnP install and fresh verified checkpoint for each station, fresh-process and repeated loadvm recovery |
| Measurement and decision | 4-6 d | Baseline/candidate p50/p95/p99 idle+load, fullscreen compatibility matrix, per-OS go/no-go |

If the QEMU model/backend must also be designed here, add roughly 2-4 weeks, but that belongs primarily
to T1. Open Watcom parity is optional follow-up (3-6 d), not on the first latency gate.

### Major risks and mitigations

| Risk | Severity / likelihood | Mitigation or stop condition |
|---|---|---|
| Win95 VMOUSE absolute bug and USER callback scheduling erase the expected tail-latency gain | Critical / high | Implement the published priority-event workaround first; instrument IRQ-to-callback time. Stop if p95/p99 under load is not materially below warpnet. |
| Fullscreen DOS VM owns mouse; Windows-level injection steals focus or does nothing | Critical / high | Track VMOUSE focus, preserve QEMU PS/2 buttons, add host PS/2 routing for DOS focus, replay GTA/Duke/Quake mode-switch tests. Any VESA regression blocks shipping. |
| Shared INTx storm/deadlock, especially Win95 userspace irqchip and `-apic` | Critical / medium | Level status bit, check-before-claim, mask/drain/ack/EOI ordering, per-ISR cap, fixed PCI address, simultaneous PCnet/audio stress, watchdog counter. No MSI. |
| Win9x code calls pageable/unsafe service from ISR or corrupts register/stack contract | Critical / medium | Locked sections, tiny assembly thunk, link-map assertions, checked VMM in clone, ISR stack budget, no allocation/logging/GDI/Win32 calls. |
| Guest-RAM DMA buffer is not physically stable/coherent | Critical / medium | One locked contiguous page through documented VMM/VDMAD API, device feature handshake, canaries and sequence validation. Fall back to mapped RAM BAR only after proving semantics. |
| Snapshot restores stale indices or held keys/buttons while backend reconnects | High / high without design | Generation protocol, discard stale host events, full-state resync, repeated in-process and fresh-process loadvm tests. |
| Win98 gains nothing over USB tablet | High / high | Compare against tablet, not warpnet. Do not ship if tail latency/compatibility is not clearly better. |
| Historical toolchain cannot be reproduced or legally retained | High / medium | Hash and archive the licensed build VM internally; create an Open Watcom parity build. Stop before production if source cannot be rebuilt. |
| Wheel has no safe kernel injection API | Medium / high | Keep wheel on existing helper or omit it; do not contaminate pointer motion with a usermode dependency. |
| Protocol corruption or malicious lengths at ring 0 | Critical / low in appliance | Fixed-size records only; validate type, sequence, indices and capacity; never trust producer arithmetic; reset on impossible state. No exec payload in ISR. |

### Explicit go/no-go gates

Proceed from spike to production driver only if all are true:

- both images cold-boot with correct PCI resources and 10,000+ shared doorbells without IRQ storm,
  hang or lost wakeup;
- Win95 and Win98 exact-point tests land within one pixel at corners/center, with correct down/up and
  no stuck VKD keys after reconnect/reset;
- Win95 fullscreen DOS ownership has a safe routing behavior; and
- initial IRQ-to-visible-cursor p95 under CPU load is clearly better than its actual baseline.

Ship a station only if repeated fresh-process and in-process checkpoint restores pass, no curated app/input
regression occurs, and the measurement plan reports a large enough p95/p99 improvement to justify a
ring-0 component. A suggested decision threshold is at least **2x lower p95 and p99 under load** with
no worse idle median, subject to the cross-cutting measurement plan's final criterion.

Fallbacks are first-class:

- Win95: restore the matching old launcher/checkpoint and `SH_POINTER=warpd`, TCP
  `127.0.0.1:57791`, with `SH_WARPD_BUTTONS=qemu`.
- Win98: restore the matching launcher/checkpoint and `SH_POINTER=abs` with `usb-tablet`.
- During development, command exec and (if necessary) wheel remain on the old agent; never block
  rollback on deleting `warpnet.exe`.

## 6. Phased implementation plan

### Phase A — spike (12-19 days)

1. Freeze the device ABI needed by Win9x: 32-bit BAR0, one 32-bit ring GPA, legacy level INTx, version,
   generation, ready and status/ack registers. Confirm QEMU save/load behavior. Build a host exerciser
   that can ring one event at a time and read counters; no streamhost cutover yet.
2. Create the hermetic Win98-DDK build VM. Build an untouched generic PnP VxD sample, install it on
   disposable Win95/98 clones, record hashes and debugger procedure. This proves the toolchain before
   input code exists.
3. Bind the new PCI ID through INF/CONFIGMG, map BAR0, allocate/register one DMA page, and install a
   shareable VPICD ISR. Initially the ISR only drains/validates records and updates counters. Stress
   with PCnet traffic and audio on both exact machine configurations.
4. Add Win98 `VMD_Post_Absolute_Pointer_Message`, normalized coordinate conversion and
   `VKD_Force_Keys`. Prove five points and ordered press/release.
5. Add the Q139292 VMOUSE hook/priority-event path for Win95 and instrument doorbell-to-USER-callback.
   Prove points on OSR2; test whether direct VMD is fixed but keep the documented path as default.
6. Inspect Win98 DDK VMOUSE wheel interfaces and explicitly close the wheel decision. Track System-VM
   versus DOS-VM mouse focus and define the PS/2 handoff before proceeding.

Deliverable: source, INF, reproducible build log, clone-only install/rollback, QEMU/guest counter dump,
latency sanity plot and a written spike go/no-go. No checkpoint changes.

### Phase B — driver (10-16 days)

1. Implement the final fixed-record ring, barriers, sequence/generation checks, consecutive-move
   coalescing, bounded ISR drain and lost-wakeup closure. Keep exec out of this ring.
2. Complete pointer, button-state, VKD scan-code and selected wheel paths. Add reconnect full-state
   reset and a safe DOS-focus mode. Preserve hybrid PS/2 buttons on Win95 by default.
3. Handle CONFIG start/stop/test/remove, Win98 APM suspend/resume and failure unwind. Add read-only
   diagnostic counters accessible outside the realtime path; remove interrupt-time logging.
4. Run cold boot/reboot/shutdown, IRQ-sharing, CPU load, PCnet load, audio, resolution changes,
   fullscreen DOS, Windows games and fault injection (bad sequence/index, backend disconnect,
   interrupt during ring wrap). Audit locked sections and ISR call graph.
5. Produce checked and release builds from the pinned toolchain. Optionally start Open Watcom parity
   after the Microsoft-built binary is stable.

Deliverable: release-candidate VxD/INF, hashes, ABI conformance tests, rollback and compatibility matrix.

### Phase C — capture (4-7 days)

1. Back up each station, update its launcher/device ledger, stage the release package, and cold boot.
2. Bind PnP, reboot, verify exact resources and readiness. Run the full curated compatibility suite.
3. Recapture Win95 and Win98 checkpoints with device+driver armed. Verify scene determinism and input
   reactivity.
4. Verify ten repeated QMP resets and ten fresh QEMU `-loadvm golden` starts, including backend
   reconnect, first motion, all buttons released and no stale key.
5. Keep A/B launchers/checkpoints until measurement passes. Do not yet remove USB tablet or warpnet
   fallback artifacts.

Deliverable: paired candidate launcher+checkpoint backups and recovery evidence for each OS.

### Phase D — measure and decide (4-6 days)

1. Baseline the actual paths first: Win95 warpnet-TCP/PS2-buttons; Win98 USB tablet. For diagnostic
   completeness also measure Win95 serial if desired, but it is not the production comparator.
2. Measure host enqueue T0 to first framebuffer cursor-pixel change at idle and under CPU-bound load;
   report p50/p95/p99 and loss/coalescing counters over enough trials. Separate backend-to-IRQ,
   IRQ-to-USER-callback and callback-to-frame timestamps where instrumentation allows.
3. Repeat movement with button transitions, rapid ring wrap, network/audio traffic, mode changes and
   after `loadvm`. Run the fullscreen DOS regression suite separately because framebuffer latency
   alone will not catch focus corruption.
4. Make two independent decisions. Win95 ships only with a large tail improvement and safe DOS
   handoff. Win98 ships only if it materially beats USB tablet without regression; the expected result
   is that USB tablet remains.
5. If approved, flip the manifest pointer backend, regenerate emitted files and archive the old pair.
   If rejected, restore the old launcher/checkpoint and retain the spike as evidence rather than an
   auto-loaded ring-0 component.

## 7. Reference index

### Repository evidence

- `docs/lab/research/low-latency-input/00-generic-plan.md` — architecture, binary record, language
  policy, capture and measurement contract.
- `streamhost/guest-agents/win9x/README.md`, `warpnet.c`,
  `warpwin-serial-altbuild.c` — actual agent/API/transport and current Win95-vs-Win98 split.
- `streamhost/tiles/win95/qemu-streamhost.sh`,
  `streamhost/tiles/win98se/qemu-streamhost.sh` — exact pinned device sets.
- `streamhost/tiles/{win95,win98se}/golden-bake.sh` — current cold-capture/savevm flows.
- `docs/guests/win9x.md` — verified ACPI/PCI/USB behavior, VBEMP state, checkpoint history and Win95
  fullscreen-DOS PS/2-button requirement.

### Driver model, PnP, memory and IRQ

- Microsoft KB [Q140731, generic PnP VxD loading](https://ftp.zx.net.nz/pub/Patches/ftp.microsoft.com/MISC/KB/en-us/140/731.HTM).
- Microsoft KB [Q247251, `CONFIGMG_Register_Device_Driver`](https://ftp.zx.net.nz/pub/archive/ftp.microsoft.com/MISC/KB/en-us/247/251.HTM).
- Microsoft KB [Q140730, PCI configuration through CONFIGMG](https://www.betaarchive.com/wiki/index.php/Microsoft_KB_Archive/140730).
- Microsoft Systems Journal, Dec. 1995,
  [Plug-and-Play VxD/CONFIGMG article](https://jacobfilipp.com/MSJ/1995/1995-12.pdf).
- Freescale/NXP [AN1780, Win95 VxD PCI mapping and VPICD source](https://www.nxp.com/docs/en/application-note/AN1780.pdf).
- Microsoft DDK mirror, [VPICD services and shared-IRQ contract](https://www.pcjs.org/documents/books/mspl13/win/w3ddkvxd/).
- Microsoft KB [Q152541, VPICD reference-data correction](https://helparchive.huntertur.net/document/37473).
- Dr. Dobb's, [C+assembly Win95 VxD ISR shell](https://jacobfilipp.com/DrDobbs/articles/DDJ/1996/9614/9614d/9614d.htm).

### Input subsystem

- Microsoft KB [Q139292, Win95 `VMD_Post_Absolute_Pointer_Message` defect and workaround](https://www.betaarchive.com/wiki/index.php?title=Microsoft_KB_Archive/139292).
- Microsoft KB [Q244771, `VMD_Set_Mouse_Data`/VMOUSE warning](https://www.betaarchive.com/wiki/index.php?title=Microsoft_KB_Archive%2F244771).
- Microsoft KB [Q169588, `VKD_Force_Keys`](https://www.betaarchive.com/wiki/index.php/Microsoft_KB_Archive/169588).
- Microsoft [`mouse_event` absolute coordinate semantics](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-mouse_event).
- Period implementation using IRQ -> VMD absolute/VKD key services,
  [US Patent 6,243,772](https://patents.justia.com/patent/6243772).

### Transport and toolchain

- QEMU [ivshmem PCI device specification](https://qemu-project.gitlab.io/qemu/specs/ivshmem-spec.html) and
  [ivshmem manual/migration notes](https://qemu.readthedocs.io/en/v7.2.19/system/devices/ivshmem.html).
- Microsoft KB [Q131030, Win98 DDK CVXD32 VxDCall wrappers](https://ftp.zx.net.nz/pub/archive/ftp.microsoft.com/MISC/KB/en-us/131/030.HTM).
- Contemporary Win98-DDK report, [`WIN40COMPAT` required for Win95](https://groups.google.com/g/microsoft.public.win32.programmer.kernel/c/VJScJbhQBYM).
- Open Watcom [linker guide, `win_vxd` output](https://open-watcom.github.io/open-watcom-v2-wikidocs/lguide.pdf).
