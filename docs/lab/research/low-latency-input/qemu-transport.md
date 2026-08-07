# Low-latency input: authoritative QEMU device and transport contract

Status: **DESIGN COMPLETE / IMPLEMENTATION GO, FLEET GO IS CONDITIONAL** (2026-07-15)

This is CROSS-CUTTING T1 from the [generic plan](00-generic-plan.md). It fixes the virtual
hardware, guest-visible ABI, host backend, interrupt behavior, snapshot rules, and rollout gates to
which all six per-OS plans bind. It is a build plan, not an implementation report. Nothing in this
research changed the lab.

## Verdict

Build a **custom conventional-PCI `gallery-hid-pci` device in QEMU C**, with a small RAM-backed
shared-memory BAR and one legacy level-triggered INTA interrupt. Connect streamhost to the device
over a dedicated per-tile Unix socket implemented with QEMU's normal chardev frontend. Put
**absolute pointer state and keyboard events in one ordered ring**. Keep exec on the existing
TCP/serial/SSH agent channels and out of both the device ISR and this ABI.

This is a **GO for the transport and for a first 9front/TempleOS spike**, not a promise that six
useful guest drivers can be delivered. Win3.11 and Win95 remain genuine go/no-go gates: a PCI driver
can be loadable yet still be unable to call the UI's input path safely from interrupt context. Each
OS plan must prove its injection point and beat warpd under load. Until then, existing warpd remains
installed and is the operational fallback.

The custom choice is not “full DMA.” Version 1 deliberately exposes a **device-owned RAM BAR**. A
guest-RAM DMA ring would make every old driver allocate, pin, describe, and synchronize DMA-capable
physical memory. That is needless risk when QEMU can expose ordinary host-backed RAM directly. QEMU
distinguishes RAM regions (direct memory) from MMIO regions (a host callback on every access), and
RAM created with `memory_region_init_ram()` is also automatically included in migration/snapshot
state ([QEMU memory API](https://www.qemu.org/docs/master/devel/memory.html)). BAR0 is MMIO only for
infrequent control/acknowledgement; event reads are from BAR2.

## Decision record: custom PCI versus ivshmem

| Requirement | `ivshmem-plain` | `ivshmem-doorbell` | custom `gallery-hid-pci` |
|---|---|---|---|
| Direct shared BAR | Yes | Yes | Yes |
| Host can wake an ancient guest with INTx | **No interrupt** | **No in current rev-1 device**; doorbell uses MSI-X | Yes, INTA by design |
| Extra host service | mapped file | ivshmem server + host peer | none beyond QEMU's Unix listener |
| Production status of helper | n/a | example server is explicitly “not to be used in production” | our bounded device/backend |
| Snapshot semantics | `master=on` required to copy memory | same, plus server/peer lifecycle | defined for the gallery golden flow |
| Guest ABI fit | generic shared memory only | peer IDs/vectors and three BARs | exactly one input ring and one IRQ |
| Downstream QEMU code | none | none only if MSI-X is acceptable | isolated new device, build wiring, tests |
| Maintenance | lowest | low QEMU patch cost, high service/guest complexity | modest recurring downstream rebase |

The apparent ivshmem advantage does not survive the fleet's interrupt requirement:

- `ivshmem-plain` maps a memory backend but cannot interrupt the guest. Upstream documentation says
  interrupt support requires `ivshmem-doorbell`, a server, and a chardev
  ([ivshmem usage](https://www.qemu.org/docs/master/system/devices/ivshmem.html)). Polling the BAR
  would reintroduce latency/burn and is therefore a no-go.
- The current device specification says doorbell BAR1 is the MSI-X table. Its only legacy-INTx
  description applies to old **revision 0 devices without an MSI-X capability**; revision 1 reserves
  those mask/status bits ([ivshmem device specification](https://www.qemu.org/docs/master/specs/ivshmem-spec.html)).
  The exact QEMU commit pinned by the installed pve-qemu build (`e545d8b...`) unconditionally adds an
  MSI-X BAR for `ivshmem-doorbell`; its notification callback only calls `msix_notify()` for that
  type ([pinned `ivshmem-pci.c`](https://qemu.googlesource.com/qemu/+/e545d8bb9d63e9dd61542b88463183314cff9482/hw/misc/ivshmem-pci.c)).
  Win95 is launched with `-apic`, and none of the six drivers should be forced to implement MSI-X.
- Doorbell also requires the ivshmem server to distribute a shared-memory fd and eventfds to peers.
  The upstream spec calls its bundled server example non-production and documents poorly designed
  protocol behavior and reconnect limitations. We would need to own a production server, ordering,
  one namespace per tile, and a host peer. That is more operational code than a QEMU chardev.
- Patching current ivshmem to restore a rev-1 INTx receive path and a host-friendly endpoint would
  make it downstream code anyway while retaining its irrelevant peer-ID protocol. At that point the
  custom device is smaller and its ABI is under our control.

The custom model should borrow well-tested QEMU idioms, not invent QEMU infrastructure. The upstream
EDU device is a compact PCI model showing BAR registers, level INTx acknowledge behavior, MSI, and
DMA ([EDU specification](https://www.qemu.org/docs/master/specs/edu.html)); the QEMU memory and qdev
APIs cover RAM/MMIO regions and device realization
([memory API](https://www.qemu.org/docs/master/devel/memory.html),
[qdev API](https://www.qemu.org/docs/master/devel/qdev-api)). Qtest is the upstream device-model
test framework and is the required test style here
([qtest documentation](https://www.qemu.org/docs/master/devel/testing/qtest.html)).

### Why not guest-RAM DMA in version 1

DMA offers cacheable ordinary guest RAM, but moves complexity to the six least convenient kernels:

1. allocate physically contiguous or scatter/gather memory;
2. prevent paging/movement;
3. translate CPU to PCI bus addresses and honor each OS's DMA API;
4. program a queue address safely on 16/32-bit toolchains;
5. handle reset while QEMU may still hold a bus address.

The QEMU PCI DMA APIs exist specifically for bus-master accesses
([QEMU load/store APIs](https://www.qemu.org/docs/master/devel/loads-stores.html)), but using them
does not make those guest requirements disappear. An 8 KiB, 32-bit, prefetchable RAM BAR gives the
driver a fixed physical range discovered through normal PCI BAR enumeration. Under KVM, event data
is host RAM rather than callback MMIO. An old OS may conservatively map the BAR uncached; that can
cost CPU-load latency but does not turn each read into a QEMU MMIO callback. The first spike must
measure this. DMA is a version-2 escape hatch only if a target proves that its BAR mapping is too
slow and also has a credible DMA API.

## Guest-visible PCI function

The following values are the version-1 contract:

| Property | Value |
|---|---|
| QEMU type | `gallery-hid-pci` |
| PCI vendor/device | `1b36:0015` |
| revision | `0x01` |
| class/subclass | `0xff00` (unclassified, vendor-specific) |
| header | conventional PCI type 0, one function |
| interrupt | INTA, level-triggered; no MSI/MSI-X capability in v1 |
| BAR0 | 4 KiB, 32-bit non-prefetchable MMIO control registers |
| BAR1 | unused/reserved (leaves room for a future MSI-X table without moving BAR2) |
| BAR2 | 8 KiB, 32-bit prefetchable RAM; coherent shared header + 256 records |
| byte order | little-endian; all six target guests are x86 |
| instances | exactly one per VM |

`1b36:0015` is a **local lab assignment**, selected because `0014` is the last assignment in the
pinned/current QEMU list. It is not an upstream allocation. QEMU's PCI-ID policy says to contact its
maintainer for a 1b36 ID and reserves unassigned values
([QEMU PCI IDs](https://www.qemu.org/docs/master/specs/pci-ids.html)). Therefore:

- the lab ABI and all baked drivers use `1b36:0015` consistently;
- before proposing the device upstream or distributing it as a general product, request an official
  ID; if a different ID is required, make that change **before** any production golden bake;
- an upstream refusal is not a local technical blocker, but collision auditing is part of every
  QEMU-bump review.

Use a 32-bit BAR, even on `qemu-system-x86_64`. Several guests and driver kits predate robust 64-bit
BAR handling, and the ring is only 8 KiB. Marking BAR2 prefetchable states that reads have no side
effects. Drivers may request a cached mapping only where their kernel API documents that as safe;
they must remain correct with an uncached mapping.

### BAR0 control registers

All accesses are aligned 32-bit little-endian accesses. Undefined offsets read zero and ignore
writes. Writes with another width are rejected/ignored by the model and counted as protocol errors.

| Offset | Name | Access | Reset | Meaning |
|---:|---|---|---:|---|
| `0x000` | `DEVICE_MAGIC` | RO | `0x44494847` | bytes `GHID` |
| `0x004` | `ABI_VERSION` | RO | `0x00010000` | major in bits 31:16, minor in 15:0 |
| `0x008` | `FEATURES` | RO | `0x0000000f` | same required feature bits as BAR2 |
| `0x00c` | `STATUS` | RO | varies | bit 0 backend connected; bit 1 driver ready; bit 2 reset required; bit 3 ring stalled/full; others reserved |
| `0x010` | `IRQ_STATUS` | RO | 0 | bit 0 ring nonempty; bit 1 reset/config; bit 2 backend link changed |
| `0x014` | `IRQ_MASK` | RW | 0 | a set bit enables the corresponding INTA cause |
| `0x018` | `IRQ_ACK` | WO | — | W1C causes; model immediately reasserts bit 0 if `producer != consumer` |
| `0x01c` | `DRIVER_READY` | WO | — | write the BAR2 `epoch`; mismatch is ignored |
| `0x020` | `GUEST_KICK` | WO | — | any value: acquire `consumer`, retry a staged record, recompute IRQ/full state |
| `0x024`–`0xfff` | reserved | — | 0 | must not be used in ABI 1 |

INTA is asserted exactly when `(IRQ_STATUS & IRQ_MASK) != 0`. This is a shareable, level-triggered
PCI interrupt: an ISR must first read `IRQ_STATUS`, return “not mine” without side effects if no
enabled bit is set, and acknowledge only causes it handled. The QEMU PCI-serial specification is a
simple upstream precedent for a QEMU conventional device wired to pin A
([QEMU PCI serial](https://www.qemu.org/docs/master/specs/pci-serial.html)).

`IRQ_ACK` closes the classic lost-wakeup race. After the driver advances `consumer`, it executes a
release/write barrier, writes bit 0 to `IRQ_ACK`, then rereads producer. QEMU acquires consumer in
the ACK callback and refuses to clear/reasserts ring status if the ring is still nonempty. A host
enqueue racing with ACK therefore leaves INTA asserted. `GUEST_KICK` is also mandatory after a
consumer update so a record held during ring-full backpressure can be published.

Version 1 intentionally has no MSI capability. INTx is supported by the PIC-era pc machines, works
with Win95's current `kernel-irqchip=off,-apic` launch, and avoids six MSI implementations for one
low-rate queue. A future minor-compatible model may add an optional single-vector MSI capability,
but every v1 driver must continue to work on INTA. MSI-X is not justified here.

## BAR2 shared-memory ABI

BAR2 is 8192 bytes. Reserved bytes are zero on device reset and must be ignored by drivers. All
indices are monotonically increasing unsigned 32-bit counters; select a slot with
`index & (ring_entries - 1)`. Occupancy is unsigned `producer - consumer` and must never exceed 256.

| Offset | Size | Owner | Field |
|---:|---:|---|---|
| `0x000` | 4 | device | magic `0x4e494c47` (bytes `GLIN`) |
| `0x004` | 2 | device | ABI major = 1 |
| `0x006` | 2 | device | ABI minor = 0 |
| `0x008` | 2 | device | header bytes = `0x0100` |
| `0x00a` | 2 | device | record bytes = 16 |
| `0x00c` | 2 | device | ring entries = 256 |
| `0x00e` | 2 | — | reserved |
| `0x010` | 4 | device | required features = `0x0000000f` |
| `0x014` | 4 | device | epoch, nonzero; changes only on device/system reset |
| `0x018`–`0x03f` | — | — | reserved constant block |
| `0x040` | 4 | device | producer index (release store) |
| `0x044` | 2 | device | next sequence number (diagnostic) |
| `0x046`–`0x047` | — | — | reserved |
| `0x048` | 4 | device | protocol-error count |
| `0x04c` | 4 | device | ring-stall count |
| `0x050`–`0x07f` | — | — | reserved producer cache line |
| `0x080` | 4 | guest | consumer index (release store) |
| `0x084` | 4 | guest | last epoch accepted (diagnostic) |
| `0x088`–`0x0ff` | — | — | reserved guest/cache-line area |
| `0x100` | 4096 | split by slot ownership | 256 × 16-byte event records |
| `0x1100`–`0x1fff` | — | — | reserved |

Required feature bits are: bit 0 absolute-pointer-state record, bit 1 canonical XT-set-1 key
record, bit 2 host monotonic timestamp, bit 3 reset/config interrupt. A driver rejects an unknown
major version or a missing required bit. It accepts a newer minor version only while
`header_bytes`, `record_bytes`, and all required bits remain compatible. It never interprets
reserved bits or bytes.

### Fixed 16-byte event record

Every event begins with this common prefix and trailer:

| Offset | Type | Field | Rule |
|---:|---|---|---|
| 0 | `u8` | type | values below |
| 1 | `u8` | flags | type-specific; unknown set bits make that record invalid |
| 2 | `u16` | sequence | assigned by QEMU, modulo 65536, across all event types |
| 12 | `u32` | `host_time_us` | low 32 bits of streamhost monotonic-raw microseconds; diagnostic only |

Type `0x01`, `POINTER_ABS_STATE`, is an atomic snapshot rather than separate move/button records:

| Offset | Type | Field | Meaning |
|---:|---|---|---|
| 0 | `u8` | type | `0x01` |
| 1 | `u8` | flags | must be zero in ABI 1 |
| 2 | `u16` | sequence | common |
| 4 | `u16` | x | normalized absolute X, 0..32767 |
| 6 | `u16` | y | normalized absolute Y, 0..32767 |
| 8 | `u16` | buttons | bit 0 left, 1 middle, 2 right, 3 X1, 4 X2; all other bits zero |
| 10 | `i8` | wheel vertical | DOM convention: negative = up, positive = down; notches, saturate to -127..127 |
| 11 | `i8` | wheel horizontal | negative = left, positive = right; may be ignored if OS lacks it |
| 12 | `u32` | timestamp | common |

Every pointer record carries position and the complete button state. The driver moves first, then
synthesizes button transitions against its previous mask, then wheel impulses. This prevents a
button from overtaking a pointer event and eliminates the two-channel stale-position race visible
in today's warpd/QEMU hybrid modes. Host pixel coordinates map to normalized coordinates as:

```
norm = round(clamp(pixel, 0, size - 1) * 32767 / (size - 1))
pixel = round(norm * (current_size - 1) / 32767)
```

Use at least a 32-bit intermediate. `size <= 1` maps to zero. The guest queries its current display
geometry through its native display/input subsystem; no resolution is stored in the transport.

Type `0x02`, `KEY`, carries a physical key transition:

| Offset | Type | Field | Meaning |
|---:|---|---|---|
| 0 | `u8` | type | `0x02` |
| 1 | `u8` | flags | bit 0 down(1)/up(0), bit 1 repeat; bits 2..7 zero |
| 2 | `u16` | sequence | common |
| 4 | `u16` | key | canonical XT set-1 make token |
| 6 | `u16` | modifiers | snapshot: bits LShift,RShift,LCtrl,RCtrl,LAlt,RAlt,LMeta,RMeta in that order |
| 8 | `u32` | reserved | zero; physical-key semantics are authoritative, not Unicode text |
| 12 | `u32` | timestamp | common |

For an ordinary one-byte set-1 make code, `key = 0x00xx`. For an E0-prefixed key,
`key = 0xe0xx`. `0xe037` denotes Print Screen and `0xe145` Pause; a guest driver emits whatever
multi-byte/internal form its keyboard subsystem requires. Break is represented by the same token
with down clear, not by setting bit 7 in `key`. The existing browser-to-streamhost path already
carries this XT-set-1 namespace, including E0 keys, so the new host binding should reuse its tested
mapping rather than create a second key vocabulary.

Type `0x03`, `RELEASE_ALL`, recovers input state:

| Offset | Type | Field | Meaning |
|---:|---|---|---|
| 0 | `u8` | type | `0x03` |
| 1 | `u8` | flags | bit 0 focus/session loss, bit 1 backend disconnect, bit 2 sequence fault; others zero |
| 2 | `u16` | sequence | common |
| 4–11 | — | reserved | zero |
| 12 | `u32` | timestamp | common |

The driver releases every key and pointer button that this driver injected; it does not move the
pointer. The device also raises backend-change IRQ status on an abrupt socket disconnect, so the
driver performs the same release even if the ring is full and no `RELEASE_ALL` can be enqueued.

Types `0x00` and `0x04`–`0xff` are reserved. Exec chunks are **not** reserved for later use in this
ring; a future ABI that adds bulk messages must use a separate queue/device version.

### Producer/consumer and ordering contract

There is one producer (QEMU) and one consumer (the guest driver):

1. QEMU acquires `consumer` and verifies `producer - consumer < 256`.
2. QEMU writes all 16 bytes of the selected slot, executes a release barrier, release-stores the new
   producer, sets ring IRQ status, and evaluates INTA.
3. The guest acquire-loads producer. For each available slot it copies the full record before doing
   any injection, validates type/flags, and processes it in sequence order.
4. After the batch, the guest release-stores consumer, executes its OS/architecture write barrier,
   writes `GUEST_KICK`, then W1C-acknowledges ring status. It loops if producer changed.

The driver treats a sequence delta other than one (modulo 65536) as a fault, releases its injected
state, records a diagnostic, and then processes the current valid record. Sequence wrap is normal.
The first record after initialization establishes the expected sequence. Malformed records are
consumed but cause release-all; an ISR must never spin forever on a bad slot.

QEMU never overwrites a published slot and never silently drops a reliable event. If the ring is
full, it holds at most one complete parsed record, sets `ring stalled`, returns zero from the
chardev `can_receive` callback, and relies on Unix-socket backpressure until `GUEST_KICK`. The host
binding must prevent that backpressure from becoming stale-pointer latency: it keeps only the
latest unsent move-only pointer state, while key/button state transitions use a small bounded
reliable queue. It may replace an unsent pointer record only when both records have the same button
mask and zero wheel delta; it must never coalesce across a button transition or wheel impulse.
Pointer coalescing occurs **before publication**, never by racing the guest to rewrite a ring slot.

The guest-owned consumer is untrusted input to QEMU. If unsigned `producer - consumer > 256`, the
device increments its protocol-error counter, stops accepting events, clears driver-ready, resets
the ring under a new epoch, and raises reset/config status. It never uses an invalid consumer to
index host memory. Likewise, QEMU validates every backend type, flag, reserved field, coordinate,
button bit, and key token before publication; a malformed host record is rejected without consuming
a sequence number.

The hard ISR should bound pathological work (recommended maximum 256 records, exactly the ring
size). If an OS's input API is legal at that interrupt priority, inject while draining for the
lowest latency. If not, copy records into the OS's highest-priority kernel deferred mechanism and
ack promptly. A usermode helper on the realtime path does not satisfy this design.

### Reset and driver initialization

On device/system reset QEMU deasserts INTA, clears the ring and indices, increments a nonzero epoch,
clears driver-ready, and sets reset-required/config status. A driver does this sequence at attach or
on epoch/reset change:

1. disable/mask the device interrupt and register the shared INTx handler;
2. enable PCI memory decoding and map BAR0/BAR2;
3. validate PCI ID/revision, both magics, ABI, sizes, features, and `producer-consumer <= 256`;
4. release any locally injected key/button state;
5. set consumer to the current producer and `last_epoch` to epoch with a release barrier;
6. write that epoch to `DRIVER_READY`;
7. enable all three IRQ mask bits, acknowledge stale causes, and recheck status/producer.

QEMU accepts backend events only after a matching `DRIVER_READY`. Initialization failure leaves the
device masked and the existing warpd/QEMU input route available. A guest driver must expose useful
diagnostics (epoch, last sequence, invalid record count, ISR count, last producer/consumer) through
whatever debug facility its OS provides.

## Host-to-device backend

Use a dedicated Unix stream socket owned by QEMU's standard chardev backend:

```sh
-chardev socket,id=ghid0,path=$D/gallery-hid.sock,server=on,wait=off \
-device gallery-hid-pci,id=ghid0,chardev=ghid0,bus=<root>,addr=0x1e
```

QEMU documents Unix `-chardev socket` with `path`, `server`, and `wait` options
([QEMU invocation](https://www.qemu.org/docs/master/system/invocation.html)). The device implements
a `CharFrontend`, accumulates split reads into fixed frames, and uses QEMU's existing event loop. It
does not create threads, poll, or open files itself. The launcher removes only its own stale socket
path before QEMU starts. The tile directory and socket must not be writable by untrusted users.

### Backend handshake and frames

The socket is `SOCK_STREAM`; record boundaries are not inherited from writes. On every connection,
streamhost first sends exactly this 16-byte hello, little-endian:

| Offset | Type | Value |
|---:|---|---|
| 0 | 4 bytes | ASCII `GHIN` |
| 4 | `u16` | backend major = 1 |
| 6 | `u16` | backend minor = 0 |
| 8 | `u16` | event record bytes = 16 |
| 10 | `u16` | flags = 0 |
| 12 | `u32` | reserved = 0 |

QEMU replies with 16 bytes: ASCII `GHOK`, negotiated major/minor at 4/6, current epoch at 8, and
current BAR0 status at 12. It then marks backend-connected and raises link-change status. A bad hello
is counted and the connection is closed. After `GHOK`, every host-to-QEMU frame is exactly the same
16-byte event layout as the ring except that host sequence must be zero; QEMU assigns sequence at
publication. QEMU sends no per-event reply. Streamhost stamps `host_time_us` immediately before it
queues the frame for this Unix socket.

Only one client is accepted. On disconnect QEMU discards a partial frame, marks link down, and
raises backend-change so the guest releases injected state. Reconnect requires a new hello. The
streamhost task reconnects with bounded backoff, but does not replay old transitions; it starts with
`RELEASE_ALL` followed by the current absolute pointer/button snapshot.

### Why not QMP or a mapped file

- **Not QMP:** QMP is a JSON machine-management protocol with greeting/capability negotiation and a
  response per ordinary command ([QMP specification](https://www.qemu.org/docs/master/interop/qmp-spec.html)).
  This tree already uses QMP for dbus-display fd handoff, idle `stop`/`cont`, screendumps, and golden
  management. A high-rate input command would add QAPI schema and JSON work, share a management
  serialization point, and complicate transient QMP-client discipline. It gives no benefit over a
  16-byte local frame.
- **Not a mapped shared file:** streamhost could write the ring without QEMU copies, but it could not
  assert emulated INTA. Adding eventfd/socket notification, ownership recovery, and snapshot
  coordination recreates an ivshmem server. At this event rate, one 16-byte copy in QEMU is much
  cheaper than that lifecycle complexity.
- **Dedicated chardev wins:** it is local, binary, bounded, reconnectable, has no network stack, and
  lets the device publish data and assert IRQ as one QEMU-main-loop operation.

## One device for pointer + keyboard; exec remains separate

Pointer and keyboard share one device, one ring, and one IRQ. This minimizes PCI resources and old
driver surface, preserves cross-class order, and has no meaningful head-of-line cost: keyboard is
low volume and the ISR drains a maximum 256 tiny records. Splitting pointer and keyboard would add
another function/IRQ or multiplexing protocol without reducing the latency-critical copy.

Exec is deliberately separate because it is variable-length, bidirectional, blocking, privileged,
and not latency-critical. Running a shell from a hardware ISR is infeasible and unsafe; forwarding
exec to usermode would reintroduce the helper path without helping input. Keep the existing channels:
Solaris's warpd `E` verb, SSH where present, serial/TCP agents where a per-OS plan retains them. This
also means the old warpd process may remain installed for fallback even when its pointer verbs are
disabled.

At rollout, configure exactly one pointer/keyboard producer. Do not leave QEMU dbus keyboard or
warpd pointer injection active alongside `gallery-hid` for the same browser events, or every event
will be duplicated. Emergency lab tooling may still use QMP `send-key` while the normal streamhost
route is stopped.

## Implementation language

- **QEMU device: C.** The pinned QEMU APIs for `PCIDevice`, PCI config/BAR registration, chardev,
  `pci_set_irq`, atomics, VMState, and qtest are mature C interfaces. Keep the device in one new
  source file plus Kconfig/Meson and tests; target roughly 500–800 lines before tests.
- **Host binding: Rust.** streamhost is Rust/Tokio already. Add a bounded reconnecting Unix-stream
  writer after its existing datagram/reliable-stream coalescers. Reuse the tested XT key mapping and
  make pointer records carry current position/button state.
- **Guest drivers:** C plus the minimum assembly demanded by each old ABI; TempleOS uses HolyC.
  There is no credible Rust kernel-driver target common to these guests. Exact choices and toolchains
  belong to the six per-OS plans.

Do **not** use QEMU's Rust framework for this device now. QEMU's own current status says the focus is
safe `SysBusDevice` support and that PCI devices capable of DMA are future work; migration support is
partly proof-of-concept, and the sample devices are PL011 and HPET
([Rust in QEMU](https://www.qemu.org/docs/master/devel/rust.html)). Even though this v1 avoids DMA,
it still needs `PCIDevice`, PCI BAR flags, INTA, chardev frontend callbacks, and stable VMState. Filling
those binding gaps would be a second research project, increase the pve build dependency surface,
and make QEMU bumps harder. Rust remains the right host language, not the right downstream QEMU
device language for this pin.

## Binding requirements for every per-OS driver

The six OS plans own exact driver kits and native input calls, but none may change this transport
contract. Each must demonstrate all of the following:

1. Enumerate `1b36:0015`, validate revision/ABI, enable memory decoding, discover rather than
   hardcode BAR physical addresses, and map the full BARs.
2. Obtain the BIOS/OS-routed INTA IRQ from its PCI mechanism. Register it as shared where the API
   permits; never hardcode IRQ 9/10/11. Its handler must prove the interrupt is ours from BAR0.
3. Implement the acquire/release ordering and ACK/recheck loop. `volatile` alone is not a portable
   memory barrier. The OS plan must name the real primitive or justify x86 locked/MMIO ordering plus
   compiler barriers for its toolchain.
4. Turn `POINTER_ABS_STATE` into the OS's lowest legal kernel absolute-pointer operation and derive
   button transitions in order. If the native operation is forbidden in the hard ISR, use the
   highest-priority kernel deferred path and state the expected latency honestly.
5. Turn canonical physical keys into the OS keyboard subsystem's input form; handle E0, Print Screen,
   Pause, repeat, and release-all. It may phase pointer first and leave normal QEMU keyboard enabled
   temporarily, but a production switch must not duplicate keys.
6. Auto-load at boot, expose diagnostics, tolerate backend absence, reset cleanly, and be armed in
   the new golden. Failure must leave the machine bootable and warpd selectable.

The device contract does not prove those OS input subsystems are callable at ISR level. That is the
largest fleet feasibility risk, not PCI transport throughput.

## Actual fleet fit and pinned device sets

The inspected launchers/manifest show that all six machines already have a conventional PCI root,
but their interrupt environments differ. Keep every existing disk, display, audio, NIC, USB, serial,
and CPU property during the first bake; add only the chardev and device. Existing tablet/serial/NIC
devices remain physically present for fallback even when streamhost stops routing normal input to
them.

| Tile | Grounded current set | Required addition/concern |
|---|---|---|
| solariscde | `pc-i440fx-11.0`, KVM, Nehalem, std VGA, AC97, USB tablet, e1000 | `bus=pci.0,addr=0x1e`; shared INTx alongside e1000/AC97; keep tablet for fallback |
| ninefront | generated `q35`, 2 vCPU, std VGA, HDA, PS/2, IDE, virtio-net-pci, unconditional golden | `bus=pcie.0,addr=0x1e`; no new bridge |
| win95 | `pc`, KVM, Pentium `-apic`, `acpi=off,usb=off,kernel-irqchip=off`, std VGA, SB16, pcnet | first pin alias to the matching `pc-i440fx-11.0`; INTA/PIC is mandatory; no MSI assumption |
| win311 | `pc-i440fx-11.0`, TCG, Pentium, cirrus, SB16, NE2K PCI, COM1 | `pci.0:1e`; Win3.x driver and interrupt legality are a hard go/no-go |
| os2warp | `pc`, TCG, Pentium, `acpi=off,usb=off`, cirrus, SB16, pcnet, COM1 | pin matching i440fx machine; `pci.0:1e`; preserve serial warpd fallback |
| templeos | `pc`, KVM, host CPU, std VGA, ISO + snapshot disk, COM1 | pin matching i440fx machine; `pci.0:1e`; HolyC/IRQ spike first, preserve RAM-snapshot behavior |

Sources are the checked-in launchers
([Solaris](../../../../streamhost/tiles/solariscde/qemu-streamhost.sh),
[Win95](../../../../streamhost/tiles/win95/qemu-streamhost.sh),
[Win3.11](../../../../streamhost/tiles/win311/qemu-streamhost.sh),
[OS/2](../../../../streamhost/tiles/os2warp/qemu-streamhost.sh),
[TempleOS](../../../../streamhost/tiles/templeos/qemu-streamhost.sh)) and the
[ninefront manifest entry](../../../../streamhost/tiles-manifest.sh). `addr=0x1e` is a proposed
stable slot because it is away from current default devices; it is not considered final for a tile
until `info pci`/QMP and a cold boot prove it free on that exact machine. Record the root bus and
slot explicitly in each emitted launcher. Never rely on QEMU auto-placement for a saved VM.
The pinned QEMU tree's own q35 ACPI qtests attach the conventional `pci-testdev` directly to
`pcie.0`, including explicit functions/slots, so a PCIe-to-PCI bridge is not required for this
non-hotplug endpoint
([pinned q35 test source](https://qemu.googlesource.com/qemu/+/e545d8bb9d63e9dd61542b88463183314cff9482/tests/qtest/bios-tables-test.c)).

The unversioned `pc`/`q35` aliases are another snapshot risk. QEMU's compatibility documentation
states that compatible migration requires the same versioned machine type and hardware
configuration ([QEMU migration compatibility](https://www.qemu.org/docs/master/devel/migration/compatibility.html)).
Resolve each alias to the current matching `*-11.0` type as part of the same device-set re-bake;
do not change chipset generation independently.

### Golden/snapshot contract

An old golden cannot be loaded after adding a PCI function. For each tile, work on a clone and:

1. build/install the patched pve-qemu package, keep a same-version stock `.deb` rollback, and prove
   it still loads an untouched existing golden;
2. cold-boot **without the old `-loadvm golden`** using the final explicit machine, bus, slot,
   chardev, and `gallery-hid-pci` properties;
3. install and auto-load the guest driver; retain but disable warpd input routing;
4. quiesce host input, send/reach release-all, disconnect the gallery socket, and verify
   `producer == consumer`, no injected key/button is held, driver-ready is set, and parser has no
   partial frame;
5. save a new `golden`, relaunch the exact command line with `-loadvm golden`, then connect
   streamhost and test reset/reconnect/input;
6. keep the pre-device disk/golden and launcher as the rollback pair.

The QEMU device uses a stable `VMStateDescription` name/version and a stable BAR2 RAM-region name.
VMState contains PCI config, IRQ status/mask, epoch, sequence, and driver-ready state; BAR2 RAM is
snapshot state. Backend connection/socket ownership is deliberately **not** VM state. QEMU's VMState
framework is the supported way to version device state and provides pre/post-load hooks
([QEMU migration framework](https://www.qemu.org/docs/master/devel/migration/main.html)).

For a process-start `-loadvm`, streamhost connects only after load, so it always handshakes. For a
live QMP `loadvm golden`, the reset coordinator must stop event production and close the gallery
Unix connection before load, then reconnect/hello afterward. This prevents a half-read stream frame
or pre-reset input from crossing the restore boundary. Idle QMP `stop`/`cont` does not require a
disconnect; with no viewer there should be no producer.

## Coexistence with pve-qemu fast-poll

This device must ship in the same pve-qemu package as the existing display fast-poll. An upstream
binary cannot load these goldens because they contain PVE's `pbs-state`; the existing
[build script](../../../../scripts/provision/build-pve-qemu-fastpoll.sh) already clones the exact installed
packaging commit, applies the complete quilt series, verifies the display patch, and builds a
same-version `.deb`. The [patch README](../../../../streamhost/qemu-patches/README.md) records the
validated QEMU pin and canary/rollback workflow.

Plan the gallery device as another downstream quilt patch after the existing fast-poll and Sphinx
patches, and generalize the script name/logging only when implementing it. The code paths do not
overlap:

- fast-poll changes `ui/console.c` and `ui/dbus-listener.c` and is inert unless
  `SH_DBUS_UPDATE_MS` is set;
- gallery input adds an isolated PCI device, Kconfig/Meson wiring, documentation, and qtests;
- runtime interaction is only normal QEMU main-loop/BQL scheduling. A 4 ms display timer and a
  chardev-ready callback may run near each other but share no state.

Do not claim zero performance interaction: a storm of socket callbacks or an ISR that never acks
could consume QEMU main-loop/vCPU time and indirectly move framebuffer capture. The canary must run
fast-poll cadence tracing and end-to-end latency simultaneously, with malformed/full-ring tests,
under both KVM and TCG. The device must be inert (apart from a disconnected chardev) when the guest
driver is not ready.

## QEMU maintenance cost

The recurring custom-device cost is real. Budget approximately **0.5–2 engineer-days per routine
pve-qemu/QEMU bump**, and **3–5 days** when PCI, chardev, atomics, Meson/Kconfig, or migration APIs
change. Every bump requires:

- rebase the isolated quilt patch after PVE's last patch;
- audit `1b36:0015` for a collision and re-run compile/qtests;
- boot i440fx and q35 canaries under KVM and TCG;
- load existing gallery-hid goldens, check VMState version compatibility, IRQ, socket reconnect, and
  fast-poll;
- retain the old patched `.deb` until fleet validation completes.

The ABI and VMState names must not be casually refactored. Additive state uses VMState subsections;
QEMU explicitly warns that changing/removing fields breaks migration compatibility
([VMState compatibility guidance](https://www.qemu.org/docs/master/devel/migration/main.html)). A
routine QEMU bump should **not** require six golden re-bakes. If the old golden cannot load, that is a
release blocker unless a deliberate migration/re-bake project is approved.

Ivshmem would reduce this downstream rebase cost, but only after accepting MSI-X or carrying an
INTx patch and a production server. For this fleet, the custom patch exchanges a bounded, testable
maintenance cost for much lower per-OS and operational risk.

## Build and verification plan

### Phase 0 — freeze and test the ABI (2–3 engineer-days)

- Put the register/header/record definitions in one endian-explicit C header plus a matching Rust
  module; add compile-time size/offset assertions and golden byte vectors.
- Confirm `1b36:0015`, BAR placement, direct `pcie.0` attachment, and INTA routing on throwaway
  i440fx and q35 QEMU instances at the exact pinned commit.
- Add a tiny host-side protocol exerciser and a fake guest ring consumer. No OS driver yet.
- Gate: split socket frames, endian vectors, wrap arithmetic, sequence wrap, and all reset states are
  unambiguous. Otherwise revise ABI before any guest code.

### Phase 1 — QEMU C device + host Rust spike (6–9 days)

- Implement BAR0/BAR2, chardev handshake/parser/backpressure, INTx, reset, VMState, and diagnostics.
- Implement qtests for IDs/BAR flags, masked/unmasked level IRQ, shared-IRQ “not mine,” ACK/enqueue
  race, wrap/full/recovery, split/malformed hello and records, disconnect release, reset, and
  save/load. Fuzz the 16-byte backend parser or at least add exhaustive length/flag cases.
- Add the Tokio Unix writer behind a feature/config switch; preserve current input paths. Coalesce
  only unsent pointer snapshots and never silently discard key transitions.
- Package it through the existing pve quilt build alongside fast-poll. Test stock rollback.
- Gate: under both KVM and TCG, host enqueue to observed INTA is reliable with zero lost wakeups and
  no unbounded queue/RSS growth. A process-start and live coordinated loadvm round-trip both pass.

### Phase 2 — reference guest and latency proof (driver 3–5 days, bake 1 day, measure 1–2 days)

- Start with 9front or TempleOS, whichever per-OS plan proves a legal kernel injection path first.
  They have source/toolchain access and avoid the Win9x VxD uncertainty.
- First write a diagnostic driver that enumerates/maps/IRQs and logs records without injecting.
  Stress 16-bit wrap, held buttons, E0 keys, backend reconnect, guest reset, and 256-record bursts.
- Add pointer injection, then keyboard. Bake only after cold-boot attach and coordinated loadvm pass.
- Baseline current warpd first, then measure p50/p95/p99 idle and CPU-loaded input-to-frame latency
  using T2's harness. Also record ISR-to-injection time and fast-poll cadence.
- Gate: material p95/p99 improvement under load, no regressions in clicks/drags/keys/reset, and no
  stuck state. Otherwise keep warpd and reassess BAR caching/deferred injection before more drivers.

### Phase 3 — per-OS drivers and fleet bake (roughly 6–12 weeks total)

- Proceed in ascending uncertainty: 9front/TempleOS, Solaris, OS/2, Win95, Win3.11, adjusted by the
  sibling plans' evidence.
- For each: PCI/IRQ diagnostic → pointer → buttons/wheel → keys → cold boot/autoload → cloned golden
  → latency and load test → canary. Do not batch six unmeasured bakes.
- A single OS is no-go if its required kernel API cannot be called from ISR/deferred kernel context,
  driver install destabilizes boot/snapshots, or its measured p95/p99 does not justify maintenance.
  Leave that tile on warpd; mixed fleet operation is supported.

### Phase 4 — hardening and rollout (3–5 days plus observation)

- Security-review socket ownership, malformed input handling, bounded queues, guest-written indices,
  and denial-of-service behavior. The device must clamp/validate every untrusted guest/host value.
- Canary one tile through the existing same-version `.deb` rollback procedure, then one example of
  each chipset/accelerator combination before the fleet.
- Document the final device ledger in each emitted launcher and the patched-QEMU build metadata.
- Keep current warpd artifacts and pre-device goldens until several reset/uptime cycles pass.

Overall planning estimate is **2–3 weeks for ABI + QEMU/host/reference spike**, then **3–25 days per
guest driver depending on OS**, plus **1 day to bake and 1–2 days to measure each**. A realistic
six-OS total is **8–14 engineer-weeks**, dominated by Windows 3.x/9x and OS/2, not by the QEMU model.

## Risks and explicit fallbacks

| Risk | Consequence | Mitigation / stop rule |
|---|---|---|
| Native input API illegal at hard IRQ priority | crash/deadlock or forced scheduling jitter | per-OS diagnostic + highest kernel deferred path; no-go if it cannot beat warpd |
| Ancient driver cannot map/observe BAR coherently | stale indices or poor latency | 32-bit prefetchable RAM BAR, barriers, KVM/TCG stress; consider DMA only for that credible OS |
| INTx routing/ack bug | interrupt storm or no input | explicit slot, shared ISR, W1C+recheck qtests, per-chipset canary |
| Explicit PCI slot collides with a tile default | QEMU fails launch or topology moves | inspect `query-pci` for every final launcher and choose/freeze another slot before bake |
| Socket backpressure creates stale pointer queue | rubber-band lag | latest-unsent pointer coalescer, bounded reliable queue, ring-full telemetry |
| Snapshot crosses partial backend/event state | stuck keys or corrupt frame alignment | quiesce/disconnect before live loadvm; hello on reconnect; release-all; empty-ring bake check |
| PCI ID is not officially allocated | future collision/upstream rejection | local fixed ID audit each bump; request allocation before external distribution |
| Custom device breaks on QEMU bump | fleet cannot load goldens | stable VMState, qtests, pinned machine, old patched `.deb`, 0.5–5 day bump budget |
| Two input paths remain enabled | duplicate movement/keys | one streamhost routing switch; retain fallback installed but inactive |
| Six-driver scope is uneconomic | long project with marginal wins | reference latency gate before difficult drivers; per-OS no-go is acceptable |

The universal fallback is the current, already baked warpd path under
[`streamhost/guest-agents`](../../../../streamhost/guest-agents/). It remains slower and more
jitter-prone, but it is known to boot and preserves gallery availability. A failed custom transport
must not force a fleet-wide cutover or remove that escape hatch.

## Acceptance checklist

The T1 implementation is complete only when all of these are true:

- exact ABI byte-vector tests pass in C and Rust;
- device IDs, 32-bit BARs, INTA, slot, and versioned machine are explicit;
- qtests cover IRQ races, full/wrap, malformed socket input, reconnect, reset, and VMState;
- the combined pve package retains PVE `pbs-state`, fast-poll, stock-deb rollback, and old-golden
  compatibility for VMs without the new device;
- one reference guest cold-boots, auto-loads, survives process-start and coordinated live golden
  restore, and never sticks a key/button;
- measured p95/p99 under load materially beats that guest's warpd baseline;
- every additional OS independently passes its own driver/toolchain/injection feasibility gate;
- launchers and goldens carry the same final device set, while old launchers/goldens remain available
  for rollback.
