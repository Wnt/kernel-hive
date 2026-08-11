# Solaris 10 x86/CDE low-latency input plan

Status: **RESEARCH / CONDITIONAL GO FOR A BOUNDED SPIKE (2026-07-15)**

## Verdict

Proceed with a time-boxed pointer-only spike. A native C Solaris DDI/DKI PCI
leaf driver that is also a STREAMS character driver is technically credible on
Solaris 10 x86. Its fastest useful injection point is a dedicated VUID stream
opened directly by the Xorg `mouse` driver: IRQ -> drain a DMA-coherent ring ->
emit `Firm_event` records with `putnext()` -> Xorg core pointer. This removes
SLIRP/TCP, Python, ASCII parsing, XTEST requests, and the second userspace
process from the real-time path. It deliberately bypasses the `consms`
(`/dev/mouse`) multiplexer and `usbms`, where this image's current absolute
tablet path is already known to stop at 1024x768.

This is not an unconditional production go. The UI still cannot react until
the userspace X server runs, and an unloaded XTEST request may be as fast as or
faster than VUID parsing. The expected win is reduced tail latency and jitter
under guest load, not zero latency. Adopt the driver only if the spike proves
full-screen 1920x1200 absolute motion and the measured p95/p99 improvement
justifies about a month of specialist work. Otherwise keep the already-proven
`warpd.py` path.

For this OS, prefer the custom `gallery-hid` PCI option from the generic plan,
with a small control BAR, a guest-allocated DMA-consistent ring, and one
level-triggered legacy INTx interrupt. This is more work than ivshmem, but it
avoids depending on whether Solaris maps an ivshmem PCI BAR truly cacheably,
avoids making MSI-X the first bring-up dependency, and permits explicit QEMU
VMState behavior for `savevm`/`loadvm`. T1 still owns the cross-OS transport
decision; if T1 selects ivshmem globally, the Solaris spike must separately gate
BAR cache behavior, legacy INTx operation, and snapshot support before driver
work continues.

## Actual station and current path

The repository, not a hypothetical Solaris install, is the baseline:

- [`streamhost/guest-agents/solaris/warpd.py`](../../../../streamhost/guest-agents/solaris/warpd.py)
  is Python 2.6 plus `ctypes`. It listens on guest TCP port 7777, parses
  newline ASCII, and calls `XTestFakeMotionEvent`/`XTestFakeButtonEvent`, with
  `XWarpPointer` as a fallback.
- [`streamhost/guest-agents/solaris/README.md`](../../../../streamhost/guest-agents/solaris/README.md)
  records the important observed fact: QEMU `usb-tablet` through Solaris
  `usbms`/VUID only reaches a 1024x768 box on the 1920x1200 CDE desktop, while
  warpd reaches the whole screen.
- [`streamhost/stations/solaris/qemu-streamhost.sh`](../../../../streamhost/stations/solaris/qemu-streamhost.sh)
  pins `pc-i440fx-11.0`, Nehalem, 3 GiB, two vCPUs, standard VGA, AC97,
  `usb-tablet`, IDE, e1000, and SLIRP host-forward
  `127.0.0.1:57790 -> 10.0.2.15:7777`. It conditionally loads the VM-state
  snapshot named `golden` from `solariscde-golden.qcow2`.
- The generated tile uses `SH_POINTER=warpd`; motion and buttons go through the
  TCP client, while keyboard input remains on the existing QEMU D-Bus input
  route. The Python agent and network configuration auto-start from
  `/etc/dt/config/Xsession.d/0100.warpd.sh` and `/etc/hostname.e1000g1`.
- A read-only check of CT950 on 2026-07-15 showed the running QEMU command line
  matches that checked-in launcher. The warpd command channel did not answer a
  read-only inventory request, so installed compiler package versions were not
  guessed. Compiler/header presence is an explicit spike preflight below.

Adding any new PCI device changes the pinned device set. The old VM-state
snapshot must not be loaded with that new command line; a new checkpoint has to be
captured with exactly the final device present.

## 1. Driver model and exact toolchain

### Driver form

Build one loadable, multithread-safe (`D_MP`) **hardware leaf driver** named
`galleryhid`. It uses normal Solaris `dev_ops` for `attach(9E)`, `detach(9E)`,
and `getinfo(9E)`, and a STREAMS `cb_ops.cb_stream`/`streamtab` for open, close,
and write-side `M_IOCTL` processing. `attach()` owns PCI BAR/DMA/interrupt
resources and calls `ddi_create_minor_node()` for a character minor named
`mouse`. The read queue saved by `open()` is the endpoint to which the ISR sends
VUID messages.

This is a STREAMS **driver**, not merely a pushable STREAMS module. A pushable
module such as `usbms` only translates a lower device's byte stream and cannot
own PCI resources. Solaris documents the `cb_ops`/`streamtab`, `attach`, minor
node, and interrupt shape for this kind of driver in the
[STREAMS Programming Guide](https://docs.oracle.com/cd/E19683-01/806-6546/kerdrv10-79840/index.html).
The illumos `mouse8042` driver is a useful source analogue because it combines a
hardware ISR with a STREAMS leaf and calls `putnext()` from the ISR, but it is a
reference to port deliberately, not a binary-compatible Solaris 10 component:
[mouse8042.c](https://github.com/illumos/illumos-gate/blob/master/usr/src/uts/common/io/mouse8042.c).

The first artifact is pointer-only. A second `kbd` minor may be added later,
but must not delay the latency-critical pointer decision.

### Toolchain preflight and build

Build against headers from the exact Solaris 10 update used by the guest,
preferably inside a disposable clone of that guest. Required packages/files are
the kernel/DDI headers (`SUNWhea`, including `sys/ddi.h`, `sys/sunddi.h`,
`sys/pci.h`, `sys/stream.h`, `sys/vuid_event.h`, `sys/vuid_wheel.h`, and
`sys/msio.h`), `/usr/ccs/bin/ld`, and either Sun Studio or GCC. Before writing
the driver, record:

```text
uname -a
isainfo -kv
cc -V
/usr/sfw/bin/gcc --version
pkginfo -l SUNWhea SUNWgcc SUNWsprot
```

For a 64-bit x86 kernel, the Oracle-published build forms are:

```sh
# Sun Studio 10/11 (preferred when available)
cc -D_KERNEL -xarch=amd64 -xmodel=kernel -c galleryhid.c
/usr/ccs/bin/ld -r -o galleryhid galleryhid.o

# Solaris-shipped GCC fallback
/usr/sfw/bin/gcc -D_KERNEL -m64 -mcmodel=kernel -mno-red-zone \
  -ffreestanding -nodefaultlibs -c galleryhid.c
/usr/ccs/bin/ld -r -o galleryhid galleryhid.o
```

Sun Studio 12 instead uses `-m64 -xarch=sse2a -xmodel=kernel`. If `isainfo -kv`
reports a 32-bit kernel, build a 32-bit module using the documented 32-bit
flags; never load a module built for the wrong data model. These commands and
the requirement for both data-model artifacts where applicable come directly
from Sun's Solaris-era [Device Driver Tutorial, pp. 28-31](https://docs.oracle.com/cd/E19253-01/817-5789/817-5789.pdf).

### Language decision: Rust -> C -> assembly

- **Guest driver: C.** Solaris 10's supported DDI/DKI interface, headers,
  module linkage structures, STREAMS ABI, and published compilers are C. A
  current Rust `x86_64-sun-solaris` userspace target, even where available,
  is not a Solaris 10 freestanding kernel-module target and does not provide
  the DDI module ABI. Claiming a loadable Rust driver here would be fiction.
- **Assembly: none planned.** Use DDI accessors and `membar_consumer()` /
  `membar_producer()` rather than handwritten x86 instructions. Assembly is
  justified only if the exact compiler emits an unusable module entry stub,
  which is not expected.
- **Host integration: Rust**, because streamhost is already Rust.
- **QEMU device model: C**, following QEMU's mature PCI device model and
  migration APIs. This Solaris plan does not make QEMU's experimental Rust
  support a dependency.

## 2. Transport binding: PCI, BAR/DMA ring, and IRQ

### Enumeration and binding

The driver must not scan PCI configuration space. The PCI nexus enumerates the
device and creates a `dev_info_t`; the normal driver binding machinery calls
`attach()`. Bind the T1-assigned custom vendor/device pair with an alias such as:

```sh
add_drv -m '* 0600 root sys' -i '"pci1b36,<device-id-in-lowercase-hex>"' galleryhid
prtconf -D | grep -i -A3 galleryhid
```

The exact compatible string must first be copied from this guest's `prtconf
-pv` output, not inferred. Solaris `add_drv -i` matches the device `name` and
ordered `compatible` properties and writes the supported binding databases;
Oracle explicitly says not to edit `/etc/driver_aliases` manually
([Solaris 10 `add_drv(1M)`](https://docs.oracle.com/cd/E26505_01/html/816-5166/add-drv-1m.html),
[driver-install tutorial](https://docs.oracle.com/cd/E19253-01/821-0592/gfoje/index.html)).
Use vendor-specific PCI class `0xff0000` rather than pretending this is a
standard PCI HID class, and bind on vendor/device ID.

In `attach()` use `pci_config_setup()` and `pci_config_get*()` to validate the
vendor/device/revision and enable the required memory-space and bus-master bits.
Solaris requires `pci_config_setup()` for explicit configuration-space access
([PCI configuration-space access](https://docs.oracle.com/cd/E19120-01/open.solaris/819-3196/devaccess-30/index.html)).

### Recommended custom transport

Use a small MMIO control BAR and a ring allocated in normal guest RAM:

1. Discover register sets with `ddi_dev_nregs()` and sizes with
   `ddi_dev_regsize()`. In Solaris register-number space, rnumber 0 is PCI
   configuration space and rnumber 1 is the first real BAR; do not confuse a
   QEMU BAR number with a Solaris rnumber.
2. Map only the control BAR with `ddi_regs_map_setup()` and
   `DDI_STRUCTURE_LE_ACC` plus `DDI_STRICTORDER_ACC`. Access it only through
   `ddi_get*`/`ddi_put*` using the returned access handle. Oracle documents
   both the rnumber convention and required access handle
   [here](https://docs.oracle.com/cd/E36784_01/html/E36886/ddi-regs-map-setup-9f.html).
3. Allocate one page-aligned, single-cookie DMA object with
   `ddi_dma_alloc_handle()`, `ddi_dma_mem_alloc(..., DDI_DMA_CONSISTENT, ...)`,
   and `ddi_dma_addr_bind_handle(..., DDI_DMA_READ | DDI_DMA_WRITE |
   DDI_DMA_CONSISTENT, ...)`. It contains protocol header, producer and consumer
   indices on separate cache lines, and fixed 16-byte records. Program the DMA
   cookie address, length, and protocol version into control registers. Oracle
   specifically recommends `DDI_DMA_CONSISTENT` for randomly accessed shared
   control structures
   ([private DMA buffers](https://docs.oracle.com/cd/E36784_01/html/E36860/dma-100.html)).
4. Require one DMA cookie in v1; failing that, fail attach rather than silently
   handing QEMU an incomplete scatter/gather list. T1 can add scatter/gather in
   a later protocol revision.
5. QEMU writes complete records and then the producer index. The driver reads
   producer, executes the appropriate consumer barrier, reads complete slots,
   writes consumer after processing, then uses a producer barrier before the
   device ack. The protocol must define little-endian fields, 32-bit indices,
   index wrap rules, and acquire/release ownership. Solaris exposes the
   required memory barrier primitives in
   [`membar_consumer(9F)`](https://docs.oracle.com/cd/E36784_01/html/E36886/membar-consumer-9f.html).
   Follow the installed DDI's `ddi_dma_sync()` rules at each ownership transfer
   (`DDI_DMA_SYNC_FORKERNEL` before consuming device writes and
   `DDI_DMA_SYNC_FORDEV` before the device consumes guest writes); establish in
   the spike whether coherent x86 turns these into negligible/no-op work before
   considering any documented optimization.

This arrangement makes the hot ring guest RAM, not potentially uncacheable
MMIO. The control BAR is touched only to identify/ack the interrupt and arm the
ring.

### IRQ registration and service

Use one **fixed legacy INTx** vector for v1. Solaris 10 1/13 exposes the modern
interrupt framework: call `ddi_intr_get_supported_types()` and require
`DDI_INTR_TYPE_FIXED`, allocate one handle with `ddi_intr_alloc()`, add the
handler, get its priority/capabilities, then enable it. The Solaris 10 API is
documented by
[`ddi_intr_get_supported_types(9F)`](https://docs.oracle.com/cd/E26505_01/html/816-5180/ddi-intr-get-supported-types-9f.html)
and the complete fixed-interrupt sequence is shown in
[Writing Device Drivers](https://docs.oracle.com/cd/E19120-01/open.solaris/819-3196/6n5ed4gp4/index.html).
If preflight shows an older Solaris 10 update lacking those symbols, use the
documented legacy `ddi_get_iblock_cookie()`/`ddi_add_intr()` interface rather
than changing OS binaries
([legacy interrupt API](https://docs.oracle.com/cd/E36784_01/html/E36886/ddi-add-intr-9f.html)).

The ISR must:

1. Read device status. Return `DDI_INTR_UNCLAIMED` immediately if this device
   did not assert the shared INTx line.
2. Validate ring magic/version/size and producer-consumer distance. A corrupt
   producer never permits an out-of-bounds kernel read.
3. Drain a bounded batch (for example 64 records), preserving button-motion
   ordering. Coalesce only adjacent pure motion records; never coalesce across
   a button or wheel transition.
4. Convert records to one STREAMS message containing consecutive `Firm_event`
   structures and call `putnext()` on the saved read queue. `putnext()` is legal
   from interrupt context
   ([`putnext(9F)`](https://docs.oracle.com/cd/E19109-01/tsolaris8/835-8009/6ruu72434/index.html));
   Sun's STREAMS guide also provides an interrupt-time `allocb()` pattern
   ([read-device ISR](https://docs.oracle.com/cd/E19683-01/806-6546/kermes8-41/index.html)).
   Preallocating a small pool of message blocks avoids making allocation
   variance the normal hot path. On exhaustion, record a drop and schedule a
   low-priority recovery; never spin or block in the ISR.
5. Publish consumer, acknowledge/deassert, and recheck producer so an event
   racing with ack cannot be stranded. The QEMU device should assert INTx
   while `producer != consumer`, or on an empty-to-nonempty transition with a
   race-free rearm contract.

If `ddi_intr_get_pri()` reports a high-level interrupt at or above lock level,
do not call general STREAMS facilities there. Either fail the spike or use a
low-level software interrupt to drain. That fallback adds a scheduling hop and
must be measured, not described as equivalent.

MSI/MSI-X is a later optimization only after fixed INTx works. One pointer
doorbell does not need multiple vectors, and the compatibility/snapshot risk is
larger than any plausible latency saving.

### Why not ivshmem first

QEMU's ivshmem interface maps shared memory in BAR2 and its doorbell variant
adds BAR0 registers and a BAR1 MSI-X table. Legacy INTx exists only in the
non-MSI-X mode; peer configurations also carry migration restrictions. See the
upstream [ivshmem specification](https://gitlab.com/qemu-project/qemu/-/blob/master/docs/specs/ivshmem-spec.rst).
Solaris can request load/store caching via `ddi_device_acc_attr`, but the
attributes are advisory and the system may use stricter access
([access attributes](https://docs.oracle.com/cd/E36784_01/html/E36860/devaccess-5.html)).
Therefore an ivshmem spike must prove, rather than assume:

- the correct Solaris rnumber for QEMU BAR2 and a valid mapping after reset;
- cache-like read latency instead of uncached MMIO latency;
- doorbell delivery with `msi=off`/fixed INTx on the pinned i440fx machine;
- no interrupt loss and correct reset semantics; and
- successful QEMU `savevm golden`, process restart with `-loadvm golden`, and
  backend reconnection.

Failure of any gate is a reason to use the custom DMA device, not to poll.

## 3. Lowest-latency absolute-pointer injection point

### Chosen: direct VUID STREAMS leaf to Xorg

Create `/devices/.../galleryhid@...:mouse` with `ddi_create_minor_node()` and a
stable `/dev/gallerymouse` link. A suitable `/etc/devlink.tab` rule is of the
form `type=ddi_mouse;name=galleryhid;minor=mouse<TAB>gallerymouse`; validate the
exact generated node with `devfsadm -v -i galleryhid`. Solaris documents that
`devfsadm` maintains `/devices` and `/dev`, and that custom links come from
`/etc/devlink.tab`
([`devfsadm(1M)`](https://docs.oracle.com/cd/E19109-01/tsolaris8/816-1055/6m7gh31f3/index.html),
[`devlinks` examples](https://docs.oracle.com/cd/E26502_01/html/E29031/devlinks-1m.html)).

Configure the existing Xorg `mouse` input driver with no pushed conversion
module:

```text
Section "InputDevice"
    Identifier "GalleryMouse"
    Driver     "mouse"
    Option     "Protocol" "VUID"
    Option     "Device"   "/dev/gallerymouse"
    Option     "Buttons"  "3"
EndSection
```

Make `GalleryMouse` the `CorePointer` in `ServerLayout`. Do **not** specify
`StreamsModule "usbms"`; `galleryhid` already emits VUID `Firm_event` records.
Remove the stock mouse from `CorePointer`/`SendCoreEvents` in the active stanza
so one physical action cannot be delivered twice; retain its old stanza in a
rollback config file.
Solaris 10's Xorg mouse documentation confirms that protocol `VUID` consumes
Solaris mouse streams and that `/dev/mouse` is normally the virtual-mouse
source
([X.Org Solaris mouse support](https://xorg.freedesktop.org/archive/X11R7.5/doc/mouse.html)).

Implement the ioctls that Xorg actually expects:

- `VUIDSFORMAT`/`VUIDGFORMAT`, accepting `VUID_FIRM_EVENT`;
- `MSIOBUTTONS` (3 initially);
- `MSIOSRESOLUTION`, storing Xorg's current width and height;
- `VUIDGWHEELCOUNT`, `VUIDGWHEELINFO`, and wheel state get/set; and
- `VUIDGADDR`/`VUIDSADDR` if the Xorg build probes VUID segment addressing.

The open-source Solaris backend in xf86-input-mouse shows the precise contract:
it sets VUID format, sends `MSIOSRESOLUTION`, decodes `LOC_X_ABSOLUTE` and
`LOC_Y_ABSOLUTE` as absolute valuators, handles VUID wheel events, and reacts to
`MOUSE_TYPE_ABSOLUTE`
([`sun_mouse.c`](https://cgit.freedesktop.org/xorg/driver/xf86-input-mouse/tree/src/sun_mouse.c?h=xf86-input-mouse-1.4.0)).
Oracle's `usbms(7M)` documents the same Firm-event and absolute-mouse interface
([`usbms(7M)`](https://docs.oracle.com/cd/E36784_01/html/E36884/usbms-7m.html)).

### Event and coordinate mapping

- Normalize host coordinates to unsigned `0..32767` despite the generic
  straw-man's `i16` spelling; values outside the range are invalid/clamped at
  the protocol boundary. After `MSIOSRESOLUTION(width,height)`, compute
  `pixel_x = round(x * (width - 1) / 32767)` and likewise for y using a 64-bit
  intermediate. For this fixture that yields exactly `0..1919` and `0..1199`.
- Emit adjacent `LOC_X_ABSOLUTE` and `LOC_Y_ABSOLUTE` events with
  `FE_PAIR_DELTA` pairing as the Solaris header specifies. Emit one
  `MOUSE_TYPE_ABSOLUTE` notification after the first successful resolution
  ioctl per open, not after every ioctl.
- Buttons use `MS_LEFT`, `MS_MIDDLE`, and `MS_RIGHT`; Solaris VUID convention
  is `VKEY_DOWN` **1 for press** and `VKEY_UP` **0 for release**. Track prior button
  state so a ring record produces only transitions.
- A vertical wheel uses wheel instance 0 and a signed eight-bit delta encoded
  in `Firm_event.value`; Xorg maps it to wheel motion/buttons. Preserve wheel
  ordering relative to buttons and coordinates.
- Populate a valid kernel timestamp and use the installed `vuid_event.h`
  definition so the LP64 `timeval32` layout is correct. Never copy the host's
  16-byte transport record as if it were a `Firm_event`.

The illumos sources are useful executable specifications for these details:
[`vuid_event.h`](https://github.com/illumos/illumos-gate/blob/master/usr/src/uts/common/sys/vuid_event.h),
[`vuid_wheel.h`](https://github.com/illumos/illumos-gate/blob/master/usr/src/uts/common/sys/vuid_wheel.h), and
[`usbms.c`](https://github.com/illumos/illumos-gate/blob/master/usr/src/uts/common/io/usb/clients/usbms/usbms.c).
Compile against Solaris 10's installed headers; do not import illumos private
objects or assume all internal symbols match.

### Alternatives evaluated

| Path | Assessment |
|---|---|
| Direct `/dev/gallerymouse` VUID stream | **Chosen.** Shortest documented kernel-to-Xorg route; driver controls resolution mapping; no `usbms` or `consms`. |
| Link as a physical mouse below `consms`, feed `/dev/mouse` | More Solaris-native hotplug/multiplexing, but adds STREAMS plumbing and re-enters the path implicated in the 1024x768 failure. Keep as fallback experiment if direct Xorg open is incompatible. The virtual mouse normally coalesces physical streams ([`virtualkm(7D)`](https://docs.oracle.com/cd/E18752_01/html/816-5177/virtualkm-7d.html)); illumos [`consms.c`](https://github.com/illumos/illumos-gate/blob/master/usr/src/uts/common/io/consms.c) shows the `I_PLINK` and resolution propagation design. |
| Raw leaf plus a new `usbms`-lineage push module | Unnecessary parsing and another module. Use only if the installed Xorg insists on the existing HID/usbms interface. |
| XTEST/XWarpPointer | Proven full-screen fallback, but necessarily enters the userspace X server through a userspace client. There is no Solaris kernel XTEST injection API. It does not satisfy the target architecture. |
| Patch Xorg or write an Xorg input plugin | Can prove transport independently, but it moves conversion into userspace and creates an old Xorg ABI maintenance problem. Diagnostic fallback only. |

### Keyboard

Keep keyboard on the current QEMU D-Bus/emulated input path for the pointer
milestone. If T1's key records are later enabled, add a separate STREAMS minor
created with `DDI_NT_KEYBOARD`; the Solaris DACF `minor-nodetype="ddi_keyboard"`
rule links devices that already speak the keyboard API below `conskbd`, which
feeds `/dev/kbd`. Map host USB HID usages to Solaris VUID station/key IDs and
emit `Firm_event.value` `VKEY_DOWN`/`VKEY_UP`. Implement the keyboard ioctls
that `conskbd` probes and test modifiers, autorepeat, CDE shortcuts, and layout.

That work is less certain than the mouse path: keymap and console semantics are
not represented by the generic 16-byte record alone. It is a separate go/no-go
after pointer measurement, not a claim that arbitrary key injection is free.
The existing keyboard route remains the fallback throughout.

## 4. Installation, auto-start, and checkpoint capture

### Installation and cold boot

For a 64-bit x86 kernel install the final binary as
`/usr/kernel/drv/amd64/galleryhid` (or `/kernel/drv/amd64` if it must load in
early boot), put `galleryhid.conf` in the corresponding parent `drv` directory,
install the alias with `add_drv`, add the devlink rule, and run `devfsadm -i
galleryhid`. Oracle documents the module paths and that `add_drv` invokes
device configuration
([installing drivers](https://docs.oracle.com/cd/E37838_01/html/E61061/loading-85890.html)).
Package the production files and install scripts as a small SVR4 package so the
alias, permissions, and devlink change are reproducible.

No daemon or CDE session script is required. At cold boot the PCI nexus binds
and attaches `galleryhid`; Xorg opens `/dev/gallerymouse` when its configured
input device starts. Keep `warpd.py`, e1000 networking, and the old config on
disk for rollback. It may continue to auto-start as the slow **exec-only**
channel, provided streamhost sends it no `M/P/R/B` pointer verbs; thus it cannot
race the core pointer and is no longer on the real-time path. If exec is moved
elsewhere, disable `0100.warpd.sh`. Keep `usb-tablet` in the launcher initially
as an inactive rollback device unless T1 explicitly elects to remove it during
the same recapture.

### Checkpoint procedure

Never test this by editing the live labhost or trying to load the existing checkpoint
with a changed device set. Work on a copy of the station-local disk and a separate
QEMU instance/ports:

1. Baseline current TCP warpd before changing anything.
2. Add the finalized `gallery-hid` device and backend to a staging copy of the
   launcher. Cold boot; do not pass `-loadvm golden` from the old device set.
3. Build/install the driver and `/dev` link, then verify `prtconf -D`, `modinfo`,
   `ls -l /dev/gallerymouse`, interrupt counters, and driver kstats.
4. Add the Xorg `GalleryMouse` section, restart Xorg/CDE in staging, and verify
   its log reports VUID mode and successful 1920x1200 `MSIOSRESOLUTION`.
5. Run correctness and stress tests, verify the live pointer route emits no
   warpd motion/button verbs, and leave warpd/network available for exec and
   rollback (or disable it only after replacing exec).
6. Stop input at an empty ring and `savevm golden`. Update the checked-in
   launcher and emitted device-set ledger together. Restart QEMU from scratch
   with `-loadvm golden`, reconnect the host backend, and repeat pointer tests.
7. Only after repeated restore success promote the staged disk/launcher through
   the normal checkpoint process.

The custom QEMU device must have VMState for programmed ring GPA/length,
protocol generation, producer/consumer view, masks, and INTx level. Snapshot
restore does not call Solaris `DDI_RESUME`; the restored in-memory driver assumes
the device remains programmed. Save only an empty ring, and have QEMU `post_load`
deassert stale INTx and validate the saved generation. If the host backend
reconnect represents a reset, increment a generation register and interrupt the
guest so the driver can discard stale entries and re-arm without userspace.

## 5. Phased implementation plan, gates, and effort

### Phase 0: preflight and baseline — 1-2 engineer-days

- Clone the disk and reproduce the pinned QEMU command line away from the live
  station.
- Record kernel bitness/update, installed compiler and DDI headers, Xorg and
  xf86-input-mouse versions, `/etc/X11/xorg.conf`, current `/dev/mouse` links,
  `prtconf -pv`, and interrupt APIs exported by the running kernel.
- Measure current warpd p50/p95/p99 idle and under a CPU-bound guest load using
  the T2 harness. Record 9-point/corner accuracy and drag/wheel behavior.

**Gate:** no matching kernel headers/compiler means no in-place experiment.
Provision a disposable Solaris 10 build VM at the identical update; do not
cross-build against illumos and hope the private ABI matches.

### Phase 1: transport + absolute VUID spike — 4-6 engineer-days

- T1 supplies a minimal PCI device/backend with fixed INTx and DMA-ring setup,
  plus VMState skeleton. Add a diagnostic mode that writes known sequence
  records without streamhost.
- Implement attach/map/DMA/INTx/open/close, protocol validation, kstats, and
  only X/Y VUID events plus the required format/resolution ioctls.
- Configure `/dev/gallerymouse` directly in Xorg and demonstrate exact four
  corners and center at 1920x1200.
- Confirm with counters that an event causes one interrupt, one drain, no
  polling, and no interrupt storm. Measure ring access and IRQ-to-queue time
  where DTrace/kstats permit.

**Go gate:** a cold boot and Xorg restart both attach; fixed INTx is reliable;
all coordinates reach `0..1919 x 0..1199`; no kernel panic; and the direct VUID
path shows credible tail-latency potential. If it still caps at 1024x768, inspect
the actual `MSIOSRESOLUTION` ioctl. Try direct pixel-valued events once; then
time-box the `consms` alternative. Do not continue into a broad Xorg rewrite.

### Phase 2: production pointer driver — 8-12 engineer-days

- Add buttons, drag ordering, vertical wheel, batching/coalescing, sequence and
  overflow counters, corrupt-ring defense, flow control, mblk-pool recovery,
  detach/error unwinding, and interrupt race tests.
- Add generation/reset handling and complete QEMU VMState/backend reconnect.
- Test repeated open/close, X restart, cold boot, shared IRQ load, ring wrap,
  host disconnect/reconnect, malformed producer, event flood, and 100
  `loadvm golden` cycles.
- Integrate the Rust streamhost producer using T1's finalized binary protocol.
  Leave exec on TCP/warpd or another slow control channel; it is not part of the
  ISR ring.

Optional keyboard support is **another 4-6 engineer-days** and has its own
correctness gate. It is not included in the pointer adoption estimate.

### Phase 3: package and capture — 2-4 engineer-days

- Produce the reproducible SVR4 driver package/install log and rollback
  procedure.
- Update the staging launcher, station manifest/env, Xorg config, and checkpoint
  documentation as one device-set change.
- Capture from a cold boot with an idle ring, restore in a new QEMU process, and
  prove driver/backend readiness without relying on warpd for pointer input.

### Phase 4: measure and decide — 3-5 engineer-days

- Use T2's host-enqueue-to-first-cursor-frame method for p50/p95/p99, idle and
  under guest CPU load. Run enough samples to show tails, not a short demo.
- Compare current TCP warpd, the new driver, and (as a diagnostic only) QEMU
  tablet inside its reachable region. Keep identical 4 ms D-Bus display polling
  and 60 fps station settings.
- Verify 9-point/corners, press/move/release drag, wheel, no sequence loss,
  multi-session behavior, and snapshot/cold-boot recovery.

**Adopt only if** full-screen correctness is perfect, there are no restore or
IRQ failures, and p95/p99 latency/jitter under load is materially better than
warpd (provisional target: at least a 2x tail reduction, subject to T2's common
criterion). If idle performance merely trades one small cost for another and
tails do not improve, the engineering and kernel-crash risk are not justified.

Pointer-only total: roughly **18-29 engineer-days (about 4-6 weeks elapsed for
one engineer familiar with Solaris DDI)**. Lack of Solaris driver experience or
kernel debugging access can easily double it.

## 6. Risks and fallbacks

| Risk | Consequence and mitigation |
|---|---|
| Solaris 10 update/private ABI mismatch | A loadable object can fail to resolve or panic. Build against the guest's exact headers, test only on a clone, and use only documented DDI/DKI interfaces. |
| Existing 1024x768 defect is above `usbms` | Direct VUID may reproduce the cap. Gate on the actual Xorg resolution ioctl and pixel-valued `Firm_event`; abandon rather than patching several closed-era layers without evidence. |
| Xorg remains userspace | CPU starvation can still delay UI reaction. Measure under load; do not promise ISR-to-pixel determinism. |
| Ring is not actually cache coherent | Use guest-RAM `DDI_DMA_CONSISTENT`, not a hot MMIO BAR. Validate barriers and DMA direction. An ivshmem-only T1 decision needs a cache-latency spike. |
| Shared INTx race/storm | Check status before claiming, use level semantics, bounded drain, ack/recheck, interrupt counters, and flood tests. Keep MSI as later work. |
| STREAMS allocation/flow-control jitter | Batch Firm events, preallocate normal-path mblks, drop with counters on exhaustion, and never block/spin in the ISR. A softint fallback must be benchmarked. |
| Snapshot restores stale DMA/IRQ state | Custom QEMU VMState, idle-ring bake, generation handshake, new-process restore loop. No promotion until repeated load succeeds. |
| Event semantic bugs | Explicit tests for inverted VUID button values, X/Y pairing, wheel sign, drag ordering, and ring wrap. |
| Old toolchain unavailable | Use the documented Solaris GCC build or a matching Solaris 10 build clone. Do not substitute modern Linux cross headers or claim Rust support. |
| Maintenance cost | Keep the device small and versioned; maintain warpd as an operational rollback. T1's custom device benefits several old guests, otherwise Solaris alone may not amortize it. |

Fallback order:

1. Direct VUID driver with custom DMA/INTx transport (target).
2. Same leaf linked below `consms`/`/dev/mouse`, only if the direct device open is
   the blocker and the 1920x1200 test passes.
3. Diagnostic Xorg reader for transport proof only, not production.
4. Existing `warpd.py` over TCP with XTEST/XWarpPointer, which is already captured,
   full-screen-correct, and also retains the exec channel.

Rollback is a launcher/checkpoint pair, not just a pointer setting: boot the prior
device-set launcher with its prior checkpoint, restore `SH_POINTER=warpd` and
`SH_WARPD_ADDR=127.0.0.1:57790`, and ensure the CDE warpd session script is
enabled.

## 7. Reference set

Primary and close-lineage sources used above:

1. Sun/Oracle, [Device Driver Tutorial (April 2008)](https://docs.oracle.com/cd/E19253-01/817-5789/817-5789.pdf) — Solaris 10-era module model, exact Sun Studio/GCC commands, paths, and `add_drv` flow.
2. Oracle, [Writing Device Drivers](https://docs.oracle.com/cd/E19120-01/open.solaris/819-3196/6n5ed4gp4/index.html) — BAR mapping and fixed-interrupt allocation/ISR rules.
3. Oracle Solaris 10 1/13, [`add_drv(1M)`](https://docs.oracle.com/cd/E26505_01/html/816-5166/add-drv-1m.html) and [`ddi_intr_get_supported_types(9F)`](https://docs.oracle.com/cd/E26505_01/html/816-5180/ddi-intr-get-supported-types-9f.html).
4. Oracle, [`ddi_regs_map_setup(9F)`](https://docs.oracle.com/cd/E36784_01/html/E36886/ddi-regs-map-setup-9f.html), [PCI config access](https://docs.oracle.com/cd/E19120-01/open.solaris/819-3196/devaccess-30/index.html), and [DMA-consistent private buffers](https://docs.oracle.com/cd/E36784_01/html/E36860/dma-100.html).
5. Sun/Oracle, [STREAMS driver entry points and interrupt handlers](https://docs.oracle.com/cd/E19683-01/806-6546/kerdrv10-79840/index.html) and [`putnext(9F)` interrupt-context contract](https://docs.oracle.com/cd/E19109-01/tsolaris8/835-8009/6ruu72434/index.html).
6. Oracle, [`usbms(7M)`](https://docs.oracle.com/cd/E36784_01/html/E36884/usbms-7m.html) and [`virtualkm(7D)`](https://docs.oracle.com/cd/E18752_01/html/816-5177/virtualkm-7d.html) — VUID Firm events, absolute notification, wheel/ioctl interface, and `/dev/mouse` multiplexing.
7. X.Org, [Solaris mouse support](https://xorg.freedesktop.org/archive/X11R7.5/doc/mouse.html) and [`xf86-input-mouse` Solaris VUID source](https://cgit.freedesktop.org/xorg/driver/xf86-input-mouse/tree/src/sun_mouse.c?h=xf86-input-mouse-1.4.0).
8. illumos gate source, [`mouse8042.c`](https://github.com/illumos/illumos-gate/blob/master/usr/src/uts/common/io/mouse8042.c), [`usbms.c`](https://github.com/illumos/illumos-gate/blob/master/usr/src/uts/common/io/usb/clients/usbms/usbms.c), [`consms.c`](https://github.com/illumos/illumos-gate/blob/master/usr/src/uts/common/io/consms.c), and [`vuid_event.h`](https://github.com/illumos/illumos-gate/blob/master/usr/src/uts/common/sys/vuid_event.h) — close-lineage examples, not a substitute for the installed Solaris 10 ABI.
9. QEMU, [ivshmem device specification](https://gitlab.com/qemu-project/qemu/-/blob/master/docs/specs/ivshmem-spec.rst) — BAR layout, MSI-X/legacy INTx semantics, and migration caveats.
10. Oracle, [`devfsadm(1M)`](https://docs.oracle.com/cd/E19109-01/tsolaris8/816-1055/6m7gh31f3/index.html) and [`devlinks(1M)` examples](https://docs.oracle.com/cd/E26502_01/html/E29031/devlinks-1m.html) — reproducible `/devices` to `/dev` linkage.
