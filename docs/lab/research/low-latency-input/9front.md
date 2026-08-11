# 9front low-latency input: kernel PCI driver plan

Status: **research / implementation plan (2026-07-15)**  
Scope: the `ninefront` station, 9front release 11554, amd64 `9pc64`; no implementation or live-lab
changes were made.

## Verdict

**GO, gated by a short interrupt/ring spike.** 9front is one of the strongest candidates for this
architecture. Its PC kernel already has direct PCI enumeration, BAR mapping, DMA allocation and IRQ
APIs, and `devmouse.c` explicitly describes `mousetrack()`/`absmousetrack()` as callable at interrupt
level. `absmousetrack()` is the exact state/queue producer behind `/dev/mouse`, so it bypasses TCP,
the user-mode `warpd` process and ASCII parsing without inventing a second input subsystem.

The recommended guest implementation is a small **built-in Plan 9 C driver**, not a loadable module.
The preferred transport for 9front is a custom `gallery-hid` PCI function with a small uncached
control BAR and DMA into a cacheable ring allocated in guest RAM. An ivshmem BAR is a useful spike
fallback, but amd64 9front's `vmap()` deliberately applies `PTEUNCACHED`; putting the hot ring there
would give up one of the generic plan's key properties. Ship only if measurement shows a material
p95/p99 win under guest CPU load; otherwise keep the already-working warpd path.

## Actual station and baseline

The checked-in source of truth is `streamhost/tiles-manifest.sh`; the generated launcher is not in
this checkout, so its emitted copy was also inspected read-only on `lab`. The current pinned device
set is:

- `qemu-system-x86_64`, KVM, `pc-q35-11.0`, `-cpu host`, 1 GiB, 2 vCPUs;
- std VGA at 1024x768, Intel HDA, IDE qcow2, and `virtio-net-pci` on SLIRP;
- no USB tablet; `plan9.ini` selects `mouseport=ps2`;
- TCP host forward `127.0.0.1:57793` to guest port 7777; and
- an internal `golden` VM snapshot loaded unconditionally with `-loadvm golden`.

Today `streamhost/guest-agents/ninefront/warpd.c` receives newline ASCII `M/P/R/B` commands over
that TCP path and writes `A x y buttons msec` to `/dev/mousein`. This is functionally correct,
including buttons and wheel, and is the rollback baseline. The new path should retain the same
absolute semantics while removing SLIRP, TCP, user scheduling, the write system call and parsing
from the realtime path.

## 1. Driver model and exact toolchain

### Driver form

Add `sys/src/9/pc/devgalleryinput.c` and add a `galleryinput pci` entry after `kbd` in the `dev`
section of `sys/src/9/pc64/pc64`. It should define a normal `Dev galleryinputdevtab` (device
character `G`, after confirming it remains unused in the release-matched `pc64` configuration),
with reset/init/shutdown methods and a tiny optional `#G` diagnostics tree (`ctl`/`stats`). The
device initializes because it is in `devtab`; no user process or namespace bind is required for
input. Binding `#G` is only for diagnostics. A Plan 9 kernel device is itself a kernel-resident
file-tree server, as described by the [Plan 9 device introduction](https://git.9front.org/plan9front/plan9front/bc2fc553b81c86fc10501cf668ae62120ad7d35b/sys/man/3/0intro/f.html).

Use a built-in driver. Although the a.out format mentions dynamically loadable objects, the 9front
manual is unusually direct that they “aren't even used anywhere”; there is no supported `insmod`
style lifecycle to base this deployment on
([a.out(6) source](https://github.com/9front/9front/blob/front/sys/man/6/a.out)). The kernel config is
turned into `devtab[]` and reset/init calls at link time by
[`mkdevc`](https://github.com/9front/9front/blob/front/sys/src/9/port/mkdevc), and the amd64 kernel
calls `pcicfginit()`, `links()` and `chandevreset()` during boot
([pc64 `main.c`](https://github.com/9front/9front/blob/front/sys/src/9/pc64/main.c)).

### Build tools

Build **inside the release-matched guest source tree** with the tools already shipped by 9front:

```text
cd /sys/src/9/pc64
mk
mk install.9fat
```

For an isolated spike, use a copied config (for example `pc64g`) and run `mk 'CONF=pc64g'` to build
`9pc64g` first, leaving the known-good `9pc64` alongside it. For the bake, use `mk install` followed
by `9fs 9fat` and a
careful old/new kernel copy if `install.9fat` is unavailable in the pinned release. The current
9front FQA procedure specifically builds from `/sys/src/9/pc64` and installs the new kernel as
`/n/9fat/9pc64`, retaining `9pc64.o`
([FQA kernel-install source](https://git.9front.org/sl/fqa.9front.org/e7422424f56d5bc6eff76f546c8e5dc68bfee090/commit.html)).

`mk` selects the compiler through `objtype=amd64`; 9front maps that architecture to **`6c`, `6l`,
object suffix `6`** ([`pcc.c`](https://git.9front.org/plan9front/plan9front/9d30b0f32dd9d8219805ed0d3ef04605c5f461cf/sys/src/cmd/pcc.c/f.html)). `8c`/`8l` are the 386 tools and
are not the toolchain for this amd64 station. The existing warpd agent was
already built in this guest with `6c`/`6l`, which is a useful toolchain sanity check. Before editing,
archive `/dev/config`, the running kernel hash, the exact `/sys/src` revision if available, and the
compiler output: current upstream source is guidance, but the release-11554 source in the disk is
the ABI authority.

## 2. Transport binding: PCI, ring, BAR and interrupt

### Recommended device contract for 9front

Use the T1 `gallery-hid` custom PCI device: vendor `0x1b36`, with the final non-conflicting device ID
assigned by T1. The device should initially expose only legacy level-triggered **INTx** and one
4 KiB MMIO control BAR. The data ring is one page of normal guest RAM, allocated by the driver and
made available to the device as a 64-bit physical address. QEMU then writes records with PCI DMA
(`pci_dma_write`/the device address space), which is the model QEMU recommends for DMA-capable
devices ([QEMU load/store APIs](https://www.qemu.org/docs/master/devel/loads-stores.html)). This is
shared memory, but the hot reads hit the guest's ordinary write-back mapping rather than an MMIO
BAR.

The common 16-byte record and producer/consumer rules remain those in `00-generic-plan.md`. Do not
cast the wire bytes to an ABI-dependent C struct: define explicit little-endian load helpers and
compile-time size/offset checks. Reserve BAR registers for protocol version/features, 64-bit ring
GPA, ring size, READY, interrupt cause/ack, reset generation, and optional diagnostic counters.
The device must reject unsupported versions rather than interpreting a mismatched ring.

This choice matters on 9front. Its amd64
[`vmap()`](https://github.com/9front/9front/blob/front/sys/src/9/pc64/mmu.c) maps device memory with
`PTEUNCACHED|PTEWRITE|PTENOEXEC`; that is right for BAR registers, but wrong for a frequently read
event ring. Allocate the ring page with `xspanalloc(..., BY2PG, 0)`, zero it, obtain its DMA address
with `PADDR()`, and call `pcisetbme()` before arming the device. Existing PC drivers use the same
allocation/PADDR pattern, while `devlml` is a compact example of `pcimatch`, `vmap` and
`intrenable` together
([`devlml.c`](https://github.com/9front/9front/blob/front/sys/src/9/pc/devlml.c)).

### Driver initialization sequence

1. In `galleryinputreset`, call `pcimatch(nil, 0x1b36, GALLERY_HID_DID)` and require exactly one
   supported function. The kernel's match routine walks the enumerated `Pcidev` list and filters
   vendor/device IDs ([`pci.c`](https://github.com/9front/9front/blob/front/sys/src/9/port/pci.c)).
2. Validate that BAR0 is memory, is at least the specified size, and contains the expected
   protocol/version. Map `p->mem[0].bar & ~0x0F` with `vmap`. Keep MMIO pointers `volatile`; use
   32-bit accesses of the width required by the spec.
3. Allocate the page-aligned cacheable ring in guest RAM, initialize producer/consumer/generation,
   program its low/high physical address and length in BAR0, and enable bus mastering with
   `pcisetbme(p)`.
4. Register `intrenable(p->intl, galleryinputintr, ctlr, p->tbdf, "galleryinput")`. Passing the
   real TBDF allows 9front's APIC code to route the PCI interrupt. Plan 9's IRQ layer permits
   handlers to share a vector, so the ISR must first test this device's cause bit and return if it
   is not ours ([`irq.c`](https://github.com/9front/9front/blob/front/sys/src/9/pc/irq.c)).
5. Keep the device masked through reset. In `galleryinputinit`—which runs after the earlier mouse
   device init—publish READY, clear stale causes, then unmask. If `gscreen` is not ready,
   `absmousetrack()` safely drops the event; nevertheless, READY should not be published until the
   input side is initialized.
6. On shutdown, clear READY, mask/ack the device, and unregister the IRQ if the pinned kernel's
   shutdown path supports the matching `intrdisable` call.

### ISR and memory ordering

The ISR must not allocate, sleep, parse text or touch user memory. After confirming the cause, it
reads the producer index, applies the architecture's `coherence()` barrier, drains complete records,
advances the consumer, applies another barrier, publishes the consumer, and acknowledges the
level interrupt before returning. The host/device must write a record completely before publishing
producer; the driver must never consume past producer. Test this ordering with two vCPUs because a
single-vCPU success can hide a broken protocol.

Use sequence numbers and counters for malformed type, bad version, gaps, overrun, IRQ-with-no-work,
and maximum records drained. Coalesce replaceable motion at the producer and never drop button/key
transitions. A bounded ring (for example 64 records) is enough for input, but the ISR needs a drain
budget and a defined reassert/reschedule rule so a corrupt producer cannot monopolize interrupt
context. Ack only after publishing consumer; INTx remains asserted while valid work remains.

Although current 9front can automatically try MSI for a PCI TBDF and supports `*nomsi`, initial
bring-up should make the emulated function advertise **no MSI capability**, forcing the simpler
INTx path. The relevant APIC code tries MSI first and then PCI IRQ routing
([`mp.c`](https://github.com/9front/9front/blob/front/sys/src/9/pc/mp.c)); the documented `*nomsi`
switch confirms MSI is optional
([`plan9.ini(8)`](https://github.com/9front/9front/blob/front/sys/man/8/plan9.ini)). Once INTx is
stable and measured, MSI can be a separate optimization, not a prerequisite.

### Why ivshmem is not the primary 9front choice

QEMU ivshmem exposes registers in BAR0, an MSI-X table in BAR1 for `ivshmem-doorbell`, and shared
memory in BAR2 ([ivshmem specification](https://www.qemu.org/docs/master/specs/ivshmem-spec.html)).
A 9front driver can PCI-match `1af4:1110` and `vmap` BAR2, but that mapping is uncached. Doorbell
mode also adds ivshmem-server/eventfd lifecycle and MSI-X handling, while this station needs only one
host-to-guest producer. Use ivshmem only for a disposable proof that PCI enumeration and a doorbell
reach the ISR, or if T1 proves the uncached BAR ring is still faster and sufficiently stable. It is
not the shipping recommendation without that measurement.

## 3. Lowest-latency injection point

### Pointer, buttons and wheel

Call **`absmousetrack(x, y, buttons, TK2MS(MACHP(0)->ticks))` directly from the PCI ISR**. This is
the lowest stable kernel input entry point. `devmouse.c` says the track functions are called at
interrupt level; `absmousetrack` clamps to `gscreen->clipr`, updates `mouse.xy`, buttons, timestamp
and counter under the mouse lock, queues button transitions, wakes the `/dev/mouse` reader and
requests cursor redraw. `rio` already reads `/dev/mouse`, so it sees precisely the same events as
real hardware without the `/dev/mousein` parse/write path
([`devmouse.c`](https://github.com/9front/9front/blob/front/sys/src/9/port/devmouse.c),
[`mouse(3)`](https://github.com/9front/9front/blob/front/sys/man/3/mouse)). Do not write directly to
the private `mouse` structure or clone its 16-entry click queue; the exported function owns those
invariants.

Map normalized protocol coordinates to the current framebuffer, not the launcher's assumed size:

```text
xpix = clipr.min.x + round(xnorm * (Dx(clipr)-1) / 32767)
ypix = clipr.min.y + round(ynorm * (Dy(clipr)-1) / 32767)
```

Use widened arithmetic, clamp normalized inputs to 0..32767, and let `absmousetrack` perform a final
clip. This remains correct if `vgasize` changes. Preserve the Plan 9 mask `1=left, 2=middle,
4=right`. Convert a positive/negative wheel delta into momentary bit-8/bit-16 presses followed by a
release at the same absolute position; cap repetitions per interrupt and carry excess into a later
record. Maintain button state in the driver and exercise simultaneous move+button, drag, wheel and
overflow cases. The mouse queue holds only 16 click-state changes, so transition storms must not be
silently generated faster than `rio` can read them.

The cursor bitmap redraw is intentionally deferred by `mouseredraw()` to the existing mouse kernel
process. Updating the canonical mouse state and waking `rio` in the ISR is still the lowest correct
injection point; drawing pixels under the driver's IRQ would introduce lock-order and interrupt
latency hazards.

### Keyboard (secondary path, candid limitation)

On PC 9front, the kernel PS/2 ISR puts raw bytes into the `devkbd.c` scancode queue; the normal
**user-mode** `aux/kbdfs` service translates that stream and serves `/dev/kbd` to `rio`
([`devkbd.c`](https://github.com/9front/9front/blob/front/sys/src/9/pc/devkbd.c),
[`kbd(3)`](https://github.com/9front/9front/blob/front/sys/man/3/kbd),
[`kbdfs(8)`](https://github.com/9front/9front/blob/front/sys/man/8/kbdfs)). There is therefore no
honest all-kernel keyboard queue equivalent to `absmousetrack` in this desktop stack.

Pointer work should ship first. If key records are added, refactor the static PS/2 queue insertion
into a tiny exported `kbdputscancode(uchar)` used by both `i8042intr` and `galleryinputintr`, then
feed valid set-1 make/break bytes. That bypasses QEMU's PS/2 device but intentionally retains
`kbdfs`, exactly as physical keyboards do. Do not have the IRQ handler open or write `/dev/kbdin`.
Until that refactor is proven, leave keys on the existing QEMU keyboard path; command execution is
out of scope and stays on its current channel.

## 4. Auto-start and checkpoint capture

There is no service to start: the driver is linked into `9pc64`, enumerates during boot, and arms in
its `Dev.init`. Installation and bake should be:

1. Clone the qcow2 and use an isolated launcher. Add the finalized `-device gallery-hid,...` and
   backend socket to both the bake launcher and the eventual production manifest. Do not test a
   new device against the old `golden`; a QEMU VM-state snapshot requires an identical device tree.
2. In the clone, preserve the old kernel, add the driver/config, build with the guest's `mk`/`6c`,
   install `9pc64` to 9fat, and retain a bootloader-selectable old kernel. Cold boot the new kernel.
3. Verify `/dev/config` contains `galleryinput`, `pci` shows the expected ID/BAR/IRQ, diagnostics
   show READY, and absolute corners, buttons, drag and wheel work before involving streamhost.
4. Keep `/amd64/bin/warpd` and its current termrc listener during the canary. With no client it is
   blocked and is not in the realtime path; changing the host pointer mode back to warpd remains a
   fast rollback. Remove/gate its autostart only after the new path has passed soak testing.
5. Quiesce the input backend and require `producer == consumer` with no asserted IRQ. Cleanly
   `fshalt`, cold boot with the final production device set, reach stable rio, then `delvm golden`
   and `savevm golden`. Relaunch normally with `-loadvm golden` and retest.
6. Update `streamhost/tiles-manifest.sh`—the device-set ledger—and the reproducible 9front build/bake
   automation. Retain `virtio-net-pci` and the host forward initially for rollback; removing them is
   a separate device-set change.

The custom QEMU device must have complete `VMState` coverage. Ring contents live in snapshotted
guest RAM, but ring GPA, generation, producer state, interrupt mask/cause and pending level must be
restored coherently. Its post-load path must reconnect or tolerate a late streamhost backend and
reassert INTx if work is pending. The saved checkpoint must contain an empty ring: otherwise every station
start can replay stale clicks. This save/restore handshake is the largest integration risk.

## 5. Language decision

- **Guest driver: Plan 9 C (`6c`)**. This is the highest preference language that is a real target
  for this kernel and exactly matches all surrounding PCI/input drivers. 9front ships no supported
  Rust compiler, kernel ABI, panic/runtime, allocator integration or module loader for a Rust
  driver. Claiming Rust here would create a language port before creating an input driver.
- **Assembly: none planned.** PCI MMIO, barriers, locking and interrupt entry already have kernel
  primitives. Add assembly only if a measured compiler/barrier defect demands it, which is
  unlikely and would reduce maintainability.
- **Shared components:** retain Rust for streamhost and C for the QEMU device model, as assigned by
  the generic/T1 workstreams. Those choices do not make Rust a viable guest-kernel language.

## 6. Effort, risks, fallback and go/no-go gates

Estimated 9front-specific effort, excluding the shared T1 QEMU device and T2 host harness, is
**8–13 engineer-days**:

| Phase | Estimate | Exit condition |
|---|---:|---|
| spike | 1.5–3 d | release-matched `9pc64` boots; PCI/BAR/INTx works; one record reaches `absmousetrack` |
| production driver | 3–5 d | ordered ring, buttons/wheel, diagnostics, overflow/reset and SMP tests pass |
| capture/integration | 1–2 d | cold boot and `loadvm golden` both arm cleanly; manifest and rollback are reproducible |
| measure/harden | 2–3 d | p50/p95/p99, load, soak and restore-loop data support the ship decision |

If the shared custom QEMU device/backend does not yet exist, budget roughly another **5–10 shared
engineer-days** in T1/T2 rather than hiding that work in this port estimate.

Principal risks, in order:

1. **Snapshot/backend/ring coherence:** a restored device and restored guest RAM can disagree or
   replay stale input. Mitigate with a versioned generation handshake, empty-ring bake invariant,
   full VMState, post-load tests and sequence counters.
2. **Cache and ordering errors:** `volatile` is not a DMA barrier, and ivshmem BAR2 is uncached on
   this kernel. Use guest-RAM DMA, `coherence()`, release/publish ordering and SMP stress.
3. **IRQ routing/ack bugs:** an unacknowledged level INTx can livelock the guest; a shared IRQ can
   call the handler for another device. Start INTx-only, check cause first, mask on fault and keep a
   bootable old kernel.
4. **Mouse transition loss:** the canonical click queue is only 16 entries. Preserve transitions,
   coalesce only motion, bound wheel expansion and expose loss counters.
5. **Pinned-source mismatch:** current upstream examples may differ from release 11554. Compile
   only against the source and headers matching the baked kernel; treat signature drift as a spike
   task, not with casts or copied internals.
6. **Payoff smaller than expected:** rio/cursor redraw or framebuffer capture may dominate after
   transport removal. That is a valid no-go result, not a reason to reinterpret the benchmark.

Fallback is the existing, verified `warpd.c` + TCP host-forward path. Keep it in the disk and keep
the current pointer configuration documented until the new path wins. **No-go/rollback** if the
driver cannot survive 100 cold boots plus 100 `loadvm golden` restores without a stuck IRQ or stale
event, loses any button transition in stress, corrupts state, or fails to materially improve loaded
p95/p99 latency. A practical initial ship gate is at least a 2x reduction in loaded p95 and p99
versus warpd with no regression in event correctness; T2 may set a stricter common target.

## 7. Phased implementation and measurement plan

### Phase A — spike

- Record current warpd idle/load p50/p95/p99 and correctness using the T2 host-to-first-cursor-frame
  method before changing the clone.
- Build a `pc64g` kernel with a minimal `Dev` that matches the final PCI ID, maps BAR0, registers
  INTx and counts causes. Prove clean failure when the device is absent or version-mismatched.
- Add a one-record guest-RAM DMA ring. Inject only absolute motion via `absmousetrack`; test all four
  corners, center, clipping, screen blank/unblank, SMP and a CPU-bound rio workload.
- Decision gate: proceed only if IRQ delivery is stable, the ring is demonstrably cacheable/coherent,
  and direct injection moves rio without `/dev/mousein` or warpd.

### Phase B — production driver

- Implement the finalized protocol/version negotiation, sequence/overrun handling, barriers,
  bounded drain, level-IRQ ack, reset generation, diagnostics and shutdown.
- Add combined absolute position/buttons and wheel pulses. Test press at a new position, multi-button
  chords, drag across windows, menu clicks and wheel directions; then inject malformed records and
  full-ring pressure.
- Add keyboard only as a separate sub-phase using the shared raw scancode enqueue helper. Pointer
  readiness must not depend on it.
- Run repeated high-rate and two-vCPU stress with an instrumented QEMU backend; assert no allocations
  or blocking calls occur in interrupt context.

### Phase C — capture

- Install the final kernel to the clone's 9fat with old-kernel recovery, cold boot with the exact
  production `pc-q35-11.0` device set, and verify device absence fails safely.
- Update the manifest, build/bake recipe and rollback notes together. Keep the warpd binary/listener
  for the canary.
- Quiesce to an empty ring, save a new `golden`, then run at least 100 cold-boot and 100 loadvm loops,
  checking READY, first event, stale-event absence and IRQ state each time.

### Phase D — measure and decide

- Compare current TCP warpd and kernel PCI paths at identical 60 fps/capture settings: host enqueue
  T0 to first framebuffer frame with the cursor pixel changed. Report p50/p95/p99 and sample count.
- Repeat under a guest CPU-bound job, with button/drag/wheel correctness, motion burst, 30-minute
  soak and snapshot-restore tests. Report ring/sequence/IRQ counters with the latency data.
- Separate host/backend-to-ISR timing from ISR-to-frame timing where instrumentation permits; this
  reveals whether remaining tail latency belongs to the transport, rio redraw, or capture.
- Ship only on the correctness/restore gates and a material tail-latency win. Otherwise select warpd
  in `tile.env`, retain the research measurements, and do not carry an unearned kernel/QEMU fork.

## Reference index

- 9front mouse implementation and interface:
  [`devmouse.c`](https://github.com/9front/9front/blob/front/sys/src/9/port/devmouse.c),
  [`mouse(3)`](https://github.com/9front/9front/blob/front/sys/man/3/mouse)
- 9front PCI and interrupts:
  [`pci.c`](https://github.com/9front/9front/blob/front/sys/src/9/port/pci.c),
  [`pci.h`](https://github.com/9front/9front/blob/front/sys/src/9/port/pci.h),
  [`irq.c`](https://github.com/9front/9front/blob/front/sys/src/9/pc/irq.c),
  [`mp.c`](https://github.com/9front/9front/blob/front/sys/src/9/pc/mp.c),
  [`devlml.c`](https://github.com/9front/9front/blob/front/sys/src/9/pc/devlml.c)
- 9front amd64 kernel/build and memory mapping:
  [`pc64` config](https://github.com/9front/9front/blob/front/sys/src/9/pc64/pc64),
  [`pc64/mkfile`](https://github.com/9front/9front/blob/front/sys/src/9/pc64/mkfile),
  [`pc64/mmu.c`](https://github.com/9front/9front/blob/front/sys/src/9/pc64/mmu.c),
  [`mk(1)`](https://git.9front.org/plan9front/plan9front/b4d4cf69be84b92796b5e5bd81f16999a54bff39/sys/man/1/mk/f.html),
  [FQA install procedure](https://git.9front.org/sl/fqa.9front.org/e7422424f56d5bc6eff76f546c8e5dc68bfee090/commit.html)
- 9front keyboard path:
  [`devkbd.c`](https://github.com/9front/9front/blob/front/sys/src/9/pc/devkbd.c),
  [`kbd(3)`](https://github.com/9front/9front/blob/front/sys/man/3/kbd),
  [`kbdfs(8)`](https://github.com/9front/9front/blob/front/sys/man/8/kbdfs)
- QEMU transport mechanics:
  [ivshmem specification](https://www.qemu.org/docs/master/specs/ivshmem-spec.html),
  [DMA/load-store APIs](https://www.qemu.org/docs/master/devel/loads-stores.html),
  [EDU PCI DMA/IRQ example](https://www.qemu.org/docs/master/specs/edu.html)
