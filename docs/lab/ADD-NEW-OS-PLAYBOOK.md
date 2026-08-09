# Add a new OS to the gallery

This is the end-to-end procedure for taking an arbitrary operating system from
source media to a reproducible, interactive streamhost exhibit. It fills the
gap between the per-guest notes in [`docs/guests/`](../guests/) and the
whole-lab rebuild in [`MASTER-REPRODUCE.md`](MASTER-REPRODUCE.md).

The canonical tile registry makes repeated lineup metadata a one-entry
integration. A production tile still has a build recipe, a QEMU/device set,
runtime sidecars where needed, a golden, guest documentation, private
credentials outside Git, and optionally a boot video. Treat the checklist in
this document as a release gate. Do not make a tile visible until its
framebuffer, input, and reset path have all passed.

Start every Tier 1–3 add with the scaffold command, then fill and prove what it
creates:

```bash
python3 scripts/tiles-registry.py new <osId> \
  --tier <1|2|3> --archetype <existing-archetype-id> --slot auto
make tile-registry-check
```

The command reserves `slot` and UDP `54000+slot`, writes a schema-valid disabled
candidate entry, copies the matching builder template, and stubs the guest doc
and cold-boot arm. Disabled means it does not enter the streamhost, signaling,
reset, or SPA lineups while its TODOs remain. The paved path is now **scaffold →
fill → verify**: builders use [`scripts/lib/labqmp.py`](../../scripts/lib/labqmp.py)
for build-time QMP console/input, and clone-only golden proof uses
[`scripts/lib/golden-verify.sh`](../../scripts/lib/golden-verify.sh).

All commands which affect the lab are examples for a planned maintenance
window. Develop and validate against a clone or scratch output first. Never
experiment against a live writable guest disk, and never use `/mnt/poc` as an
input or output.

## 1. Current scope and candidate backlog

`registry/tiles/` is the source of truth for the current lineup. Each entry has
an explicit `lifecycle`; `streamhost/tiles-manifest.sh` is generated from its
production entries rather than maintained as an independent inventory. At the
current registry revision, `python3 scripts/tiles-registry.py count` reports
**39 lineup entries: 37 streamhost production tiles and 2 showcase posters**.
Use that command for the current roster count and `labctl ls` for observed live
service state; do not copy the number into another inventory.

Difficulty tiers used below:

- **Tier 1 — direct:** pinned live ISO or prebuilt free disk; stock QEMU devices;
  deterministic framebuffer in minutes.
- **Tier 2 — install:** ordinary unattended install, offline image injection, or
  a captured-Linux emulator bridge; no new guest driver.
- **Tier 3 — legacy/gated:** licensed or account-gated media, fragile old
  drivers, manual calibration, multiple install stages, or a non-QEMU backend.
- **Tier 4 — research:** emulator incompatibility, bespoke kernel/device work,
  or a platform whose streaming path has not yet been designed.

The planned/recovery set is:

| OS / exhibit | State and blocker | Rough tier |
|---|---|---|
| `macos` | Showcase poster. The proven Sequoia VM 925 and VNC/WebSocket bridge were deleted; recreation needs Apple-compatible OpenCore/QEMU work, substantial disk space, and a new streamhost-era capture path. Tahoe is not viable without working accelerated graphics on this host. | **4** |
| `nextstep` | Not live and not in the SPA lineup. The builder reaches device detection, but NeXTSTEP 3.3 loses IDE/SCSI I/O under current QEMU; the likely paths are a QEMU 0.9 sidecar or Previous plus a licensed NeXT ROM. The ISO is also not staged. | **4** |
| `riscos` | Showcase poster. Its former RPCEmu/neko backend was retired. ROOL media and a builder exist, but it needs a streamhost-compatible captured-Linux/RPCEmu bridge and a new golden. | **3** |
| `win11` | Showcase poster. VM 900 was deleted with the legacy RDP/neko path. Re-entry needs user-supplied licensed media plus a supported UEFI/TPM guest and streamhost/RDP capture design. | **3–4** |
| `winxp` | Fully registered and previously built, but currently inactive. A clean rebuild is blocked on the operator's licensed XP SP3 ISO, product key, and administrator password; the consumed ISO has no recorded hash. | **3** |
| `sailfishos` | Fully registered and previously built, but currently inactive. A clean two-stage rebuild needs an account/EULA-gated Sailfish SDK emulator VDI; the source VDI was not retained. | **3** |

`amiga500` is not a missing candidate: it is the active production tile
`amiga`, a Debian kiosk running FS-UAE with Kickstart/Workbench. It is distinct
from the active x86 AROS tile whose `osId` is `aros` and `tileDir` is
`amigaos`. Use the Amiga 500 path as a Tier-2 bridge template.

Candidate details and the live bridge distinction are recorded in the existing
guest notes: [`macos.md`](../guests/macos.md),
[`nextstep.md`](../guests/nextstep.md),
[`riscos.md`](../guests/riscos.md), [`win11.md`](../guests/win11.md),
[`winxp.md`](../guests/winxp.md), [`sailfish.md`](../guests/sailfish.md),
and [`amiga500.md`](../guests/amiga500.md). These notes include historical
neko-era material; the canonical registry and a current read-only `labctl ls`
result take precedence for lineup and live status respectively.

[`docs/guests/UNDOCUMENTED.md`](../guests/UNDOCUMENTED.md) is a documentation
gap list, not a candidate list: its rows are already-live tiles. At the time of
this inventory its heading says seven but its table contains six (`android`,
`postmarketos`, `serenityos`, `toaruos`, `win2000`, and `win311`).

## 2. Establish identity and acceptance criteria

Choose these names before downloading anything:

```text
builder key   lower-case build-all key, e.g. solaris-cde
osId          public SPA/signal/reset identifier, e.g. solaris
tileDir       runtime directory and systemd instance, e.g. solariscde
displayName   museum label, e.g. Solaris CDE
```

Prefer one identical lower-case value for the first three. Existing aliases
(`solaris` → `solariscde`, `aros` → `amigaos`) require repeated special-case
mapping and should not be copied.

Write the acceptance criteria into `docs/guests/<os>.md` before implementation:

- exact stable release, architecture, source/license class, and expected hashes;
- canonical output disk/ISO path;
- pinned QEMU binary, machine, accelerator, CPU, display, storage, NIC, audio,
  and input devices;
- the exact GUI/console state that proves success in a framebuffer;
- reset mode: `loadvm` with snapshot `golden`, or deterministic `restart`;
- pointer path and a visible motion/click/drag test;
- whether a login exists, with values kept outside Git;
- optional boot-video ready state and zero-input policy.

A serial log is supporting evidence, not proof that a graphical exhibit works.
The final gate is the captured framebuffer seen by streamhost.

## 3. Acquire and record media

### 3.1 Select the source

At execution time, re-check the upstream and select the latest **stable**
release that the guest can actually run. Do not interpret a nightly, rolling
`latest`, beta, or an old URL already present in a script as stable without
checking. If the newest stable release regresses under the pinned QEMU, document
the failing framebuffer evidence and pin the newest proven-compatible stable
release instead (ReactOS is the existing pattern).

Classify every external input:

- **free/open:** fetch from the canonical project/release service and verify the
  publisher's checksum or signature;
- **licensed:** require the operator to stage their own media; never commit it,
  embed a key, or invent a public mirror;
- **account/EULA gated:** accept an explicit local path/environment variable and
  fail with a precise staging message;
- **preservation source:** record provenance, copyright status, stable item URL,
  size, and a locally measured SHA-256. Treat the artifact as private unless its
  redistribution terms are clear.

**Pulling one file out of a huge preservation set.** archive.org's download
endpoint can extract a single member from a ZIP stored at an item's root:

```text
https://archive.org/download/<item>/<file>.zip/<path-inside-the-zip>
```

On the MPF-II add this fetched a 16 KB ROM in 1.4 s instead of a 20 GB merged
MAME set. It works only where the item stores per-game ZIPs at its root
(`MAME_0.224_ROMs_merged` does); a `.tar.gz` item cannot serve it, because gzip
is not seekable. In a **merged** MAME set a clone's ROM lives in the **parent's**
ZIP — `mpf2` ships inside `tk2000.zip` — which is the usual cause of a
"ROM not found" after an otherwise correct download.

**The media can answer questions the wiki cannot.** Dumping the BASIC keyword
table straight out of `mpf_ii.rom` proved the MPF-II carries the full Applesoft
graphics set (`HGR`, `HCOLOR`, `HPLOT`, `DRAW`), which decided what its demo
program could use. Before trusting a secondary source about what a machine can
do, look in the ROM.

### 3.2 Stage and hash

Use `/data/assets-staging/<osId>/` for the immutable intake copy. Builders
should place or derive their canonical artifacts beneath
`/data/gallery-guests/<GuestName>/`; only shared live ISOs which launchers
explicitly reference belong under `/data/isos/`.

```bash
# On the lab host, after the operator has supplied media when required.
install -d -m 0750 /data/assets-staging/<osId>
sha256sum /data/assets-staging/<osId>/<media> \
  | tee /data/assets-staging/<osId>/MANIFEST.sha256
sha256sum -c /data/assets-staging/<osId>/MANIFEST.sha256
```

Record the filename, full SHA-256, size, license class, canonical source, stage
path, builder, and **environment-variable names only** in
[`docs/lab/ASSETS-MANIFEST.md`](ASSETS-MANIFEST.md). Extend
`scripts/build-guests/check-assets.sh` so `build-all.sh --check-assets --only
<key>` fails before a long build. Do not print or record product keys,
passwords, tokens, private keys, or private download URLs.

The builder must download to a temporary filename, verify it, then atomically
move it into the cache. A size-only check is a last resort and must be called
out as a reproducibility gap.

## 4. Author `scripts/build-guests/tiles/<os>.sh`

The scaffold has already copied a tier-specific starting file here. Fill its
TODOs rather than copying another complete builder. Import `labqmp.QMPClient`
from `scripts/lib/labqmp.py`, or invoke its qdrv-compatible CLI from shell. It
provides the single keymap plus `type`, `sendkey`, `screendump`, `savevm`,
`loadvm`, `hostfwd_add`, and `assert_idle_deterministic`. This is the
**build-time** helper; it does not replace the operator-side `/root/cdrv.py`
used by `labctl` on the box.

Make the builder idempotent, fail-fast, and isolated. It must own a namespaced
work directory, unique sockets and ports, and a pidfile. Stop only its own QEMU
through QMP/HMP or its pidfile; never use `pkill qemu` or a shared fixed socket.
Support an explicit force/rebuild option and a verification opt-out consistent
with existing builders.

Register the builder through `build.rows` in
`registry/tiles/<osId>.json`; `scripts/build-guests/build-all.sh` is generated
from those rows, including `DEFAULT_ORDER`. The rendered row fields are:

```text
KEY | SCRIPT | OUTPUT_DIR | CLASS | EST_TIME | AUTOMATION | PRODUCES [| media]
```

Use these templates by difficulty:

| Tier | Start from | Why |
|---|---|---|
| 1 | `alpine.sh`, `kolibrios.sh`, `reactos.sh` | Stable-media resolution, checksum validation, LiveCD/scratch snapshot, automated framebuffer gates. |
| 2 install | `haiku-install.sh`, `win2000.sh` | Real install, fixture provisioning, final device-set snapshot and restore proof. |
| 2 bridge | `bridge-base.sh`, `c64.sh`, `amiga.sh`, `streamhost/docs/BRIDGE.md` | Captured-Linux kiosk around a non-QEMU architecture/emulator. |
| 3 graphical | [`scripts/install-vision/README.md`](../../scripts/install-vision/README.md) plus `redstar3.flow.yaml` | Declarative screenshot/OCR/template state machine, capture helper, optional dialogs, secret injection, and framebuffer checkpoints. |
| 3 unattended | `win2000.sh` plus `docs/lab/research/unattended-install-win2000.md` | Secret-free answer-file template; secrets supplied only at execution. |
| 3 legacy | `os2warp.sh`, `win95.sh`, `win98.sh` | TCG/legacy chipset, old display/audio/input drivers, exact golden parity. |
| 4 negative research | `nextstep.sh` and `docs/guests/nextstep.md` | How to retain a reproducible failure without advertising a broken tile. |

For the two nontrivial automation styles, also read
[`unattended-install-win2000.md`](research/unattended-install-win2000.md) and
the declarative [install-vision guide](../../scripts/install-vision/README.md).

### 4.1 Pick a pinned virtual machine

Start with the smallest plausible device set and change one variable at a time.
The builder's final QEMU launch and the production launcher must enumerate the
same guest-visible devices and properties.

**Machine and accelerator decision:**

1. Use KVM first for a normal x86/x86_64 guest. Confirm `/dev/kvm` and boot with
   the final CPU model.
2. If an old kernel hangs, triple-faults, depends on historical timing, or has a
   known virtualization incompatibility, reproduce the failure under a clone
   and try `-accel tcg`. OS/2 Warp is the reference TCG-only guest. Do not choose
   TCG merely because installation automation is slow.
3. Use the oldest chipset the guest has drivers for: i440fx/`pc` for most legacy
   systems, q35 for guests that require newer PCI/UEFI behavior.
4. Resolve the alias to the host's current versioned type (today's rebuild uses
   `pc-i440fx-11.0` or `pc-q35-11.0`) and pin it. Re-check on a future QEMU
   upgrade; do not silently retarget an existing golden.
5. Pin CPU model, vCPU count, memory, ACPI/APIC/USB properties, RTC behavior,
   firmware/varstore, and boot order. A change to any guest-visible device can
   invalidate `loadvm golden`.

**Display decision:**

1. Prefer a device with an inbox driver in the target release, not the newest
   emulated GPU. Test the install mode and the final desktop mode.
2. Modern/hobby guests with VBE support can begin with `-vga std`. If a fixed
   canvas is required, use an explicit `-device VGA,...,edid=on,xres=...,yres=...`
   and omit built-in VGA (`--vga none`); Haiku is the reference.
3. NT-era and older guests should use the device their installed driver expects
   (`cirrus` is a common safe choice). **Win9x must not ship on bare `-vga std`
   merely because setup renders:** its 16-colour planar std-VGA path has shown
   tearing. Use `-vga cirrus`, or install and framebuffer-prove a VBE/VBEMP
   driver before selecting `std`.
4. If the desktop is black, corrupted, palette-torn, or only partially updated,
   change the emulated adapter/guest driver before changing capture code.
5. Verify with QMP `screendump` and the streamhost D-Bus capture. A VNC view or
   guest log alone does not establish framebuffer compatibility.

**Bridge tiles — fitting an emulator window to the captured root.** The
captured surface is the kiosk's X root, so the emulator must fill it:

- **Do not force the emulator's `-resolution` to the machine's raw pixel
  count.** That number is the pixel count, not the picture's shape, and setting
  it defeats the emulator's aspect correction. MPF-II at `-resolution 1120x384`
  sat as a 2.92:1 strip in the middle of a black root; fullscreen plus
  `-keepaspect` on the bridge base's stock root reconstructs the roughly 4:3
  image the real machine drew on a television.
- **Where the emulator's window cannot grow, shrink the root to it.** VICE's SDL
  window is a fixed 719×544 at `-VICIIdsize`, so the X root drops to the smallest
  advertised mode that contains it (800×600). Do not reach for SDL real
  fullscreen instead: it renders BLACK under std-VGA capture (see the note in
  `scripts/build-guests/tiles/amstradcpc.sh`).
- Any change to the launcher or the X geometry invalidates the golden. Re-bake
  it, or reset restores the old layout and the fix appears not to have worked.

**Other devices:**

- Disk: prefer qcow2 for installed guests and internal snapshots; use IDE/SATA
  for old inbox drivers, virtio only where supported. UEFI guests need a
  per-tile writable varstore, never a shared writable template.
- NIC: use virtio-net for modern guests; e1000/rtl8139/pcnet for older inbox
  drivers. Put host forwards on the existing `-netdev user` backend so a later
  reset does not accidentally add a guest-visible device.
- Audio: `intel-hda` for modern guests, AC97 for many NT/Unix guests, SB16 for
  DOS/Win9x, or none. The guest must have a real driver. Match the production
  D-Bus audiodev and sample format during the golden bake.
- Keyboard/input: USB tablet/PS2/virtio choice is part of the device set. Decide
  it before saving the snapshot; Section 5 gives the pointer policy.

### 4.2 Automate the install as a state machine

Choose the least fragile mechanism the OS supports:

1. **Unattended answer file/cloud-init/offline configuration** — preferred.
   Keep the template secret-free and substitute gated values at runtime. Verify
   that the target installer version actually consumes every directive.
2. **In-guest SSH/serial/bootstrap payload** — type only a short command, then
   transfer an idempotent script through a namespaced host forward.
3. **Machine vision** — for a graphical installer with no unattended interface,
   author an `install-vision run <flow.yaml>` flow following
   [`scripts/install-vision/README.md`](../../scripts/install-vision/README.md).
   Detect screen state from QMP screenshots, then click/type. Harvest stable
   crops with `install-vision capture`, use bounded waits, optional steps for
   branch dialogs, and post-action framebuffer checkpoints. Coordinates alone
   are acceptable only after resolution and screen state are positively
   identified.
4. **Manual VNC** — acceptable only for initial research. Convert the observed
   sequence into an answer file or framebuffer-driven state machine before the
   builder is called reproducible. If a one-time calibration truly cannot be
   removed, label the build honestly as `1-click` and document it.

Every phase should be restartable or should fail with the last framebuffer,
serial tail, command, and expected next state. Never treat a timeout followed by
blind input as success.

### 4.3 Create and prove the golden

Curate an idle, deterministic, input-ready screen: no setup wizard, modal error,
screen saver, changing clock where avoidable, or unknown login prompt. Run the
standard clone-only proof on the lab host:

```bash
# Bake/rebake on copied disks, then independently verify the retained tag.
scripts/lib/golden-verify.sh <tileDir> --bake
scripts/lib/golden-verify.sh <tileDir>
```

The helper uses the tile's `bootrec-tiles.conf` disk/port/ready metadata, copies
every writable disk under a namespaced `/data/vms/soltest/golden-verify-*`
directory, statically checks the rewritten launcher, gates destructive QMP by
`clone-guard`, and tears the clone down. Its required sequence is:

```text
stop/pause guest at the ready state
delete an obsolete snapshot only on the disposable build artifact
savevm golden
query snapshots and require the `golden` tag
dirty the framebuffer/input state
loadvm golden
capture again and compare the expected region/frame
restart QEMU with the final production device set and `-loadvm golden`
repeat the visible input proof
```

On a first bake (no tag), the configured cold-boot driver/detector must reach the
ready fixture; on a rebake, the existing tag is the ready seed. Without
`--bake` the helper refuses to create or replace a snapshot and verifies the
existing `golden`. Set `GOLDEN_VERIFY_DIRTY_TEXT` only when the fixture needs a
different visible keyboard string; a dirty action which does not change the
framebuffer is a failure, not a skipped assertion.

The disk containing the internal snapshot must be writable during `savevm` and
normal production restore. Do not combine an internal snapshot with QEMU
`-snapshot` mode unless the design explicitly proves where the vmstate persists.
For immutable ISOs/raw bases or non-migratable devices, use
`resetMode=restart` and prove the cold boot is deterministic.

**Bake from a clean cold boot, and let the restore finish alone.**

- The screen you bake is the screen every visitor sees for the life of the
  exhibit. A golden baked while the framebuffer still carried output from a
  verification run gave the MPF-II an exhibit that restored to a scrolled screen
  with the banner gone and two prompts stacked. Cold-boot the fixture, leave it
  untouched, bake that.
- **Do not inject keys after `loadvm`.** mpf2 sent `scroll_lock,f3,scroll_lock`
  after a restore purely to replay the ROM power-on beep; it raced the restore
  and intermittently corrupted the screen, and was removed. Note also that
  MAME's F3 is a *warm* start — RAM survives, so an Apple-family ROM skips its
  banner entirely; Shift+F3 behaves the same.
- **Use the sibling pattern.** `resetMode: loadvm` plus an internal `golden`
  snapshot is what every restorable tile does. A bespoke reset mode with a tile
  name hardcoded in the generic `scripts/serve/reset-tile.sh` was tried on this
  add and reverted: per-tile behaviour belongs in the registry entry, never in a
  case statement in shared code.

Keep the launcher and golden as an atomic pair. Adding/removing a disk, tablet,
NIC, serial device, firmware property, PCI device, or machine version after
`savevm golden` requires a new golden. Display/audio **backends** can sometimes
vary without changing guest-visible state, but prove this rather than assuming.

## 5. Choose and wire pointer/input transport

Select the first path in this table which the guest supports correctly. Test
motion to all corners, click, drag, wheel, key make/break, pointer re-entry, and
input immediately after a reset.

| Path | Choose when | Production wiring |
|---|---|---|
| Absolute HID | Guest has USB HID or virtio-input and maps the full display correctly. This is the default and lowest-effort path. | Emit `--pointer abs --input-backend dbus-abs --input-dev usb` for `-usb -device usb-tablet`, or `--input-dev virtio` for virtio keyboard/tablet. `tile.env` gets `SH_INPUT_BACKEND=dbus-abs`. Add cursor scale/offset only from measured framebuffer calibration. Do not set SPA `pointerRel`. |
| Direct relative PS/2 | Guest only has a good PS/2 relative mouse and browser Pointer Lock produces usable 1:1 deltas. | Emit `--pointer rel --input-backend dbus-rel --input-dev ps2`; no tablet. Set `pointerRel: true` in the SPA binding so raw relative movement is sent. QNX is the reference. |
| TCP warpd / hybrid | Existing baked guest exposes a trustworthy absolute cursor API but its virtual HID is absent, range-limited, accelerated, or otherwise wrong. | Warpd is frozen: reuse only for its six existing tiles; do not add another agent or protocol verb. Their emit form is `--pointer warpd --input-backend warpd --warpd-addr 127.0.0.1:<hostPort>`. Optional `--warpd-buttons qemu` keeps motion on the agent while real QEMU mouse buttons preserve window-manager semantics. |
| Serial warpd agent | Existing baked guest has no reliable NIC/TCP path but reads COM1 and calls an absolute cursor API. | Warpd is frozen: retain the existing Unix socket chardev and `--pointer warpd --input-backend warpd --warpd-addr unix:<tileDir>/serial.sock` only for Win3.11/OS2/TempleOS. New OS work must not create another guest agent. |
| `gallery-hid` | Only after the OS-specific kernel driver and patched QEMU device have passed latency, restore, and fallback gates. It is not the generic first choice. | Follow `docs/lab/research/low-latency-input/qemu-transport.md`: pinned patched QEMU; `-chardev socket,id=ghid0,path=<tileDir>/gallery-hid.sock,server=on,wait=off`; `-device gallery-hid-pci,id=ghid0,chardev=ghid0,bus=pci.0,addr=0x1e`; guest driver installed/armed before a new golden; `SH_GHID_SOCKET=<path>` in `tile.env`. Keep the old HID/warpd route available for rollback until the tile is promoted. |

The experimental transport contract and its promotion/rollback requirements are
in [`qemu-transport.md`](research/low-latency-input/qemu-transport.md).

### 5.1 Keyboard-only exhibits — pacing, layout, and the type-in demo

For a machine with no pointing device (MPF-II, Amstrad CPC) the keyboard *is*
the exhibit, and it has its own failure modes. All the numbers below were
measured on the lab box during the MPF-II add (2026-08-06).

**Pace the release→press GAP, not just the hold.** An emulator samples its input
ports once per emulated frame, so a press+release completing inside one frame is
never observed. The quantity that must survive a frame is the gap *between*
successive keys. Bisected on mpf2 (MAME, 60 Hz), typing a 16-key line:

| Inter-key gap | Keys that landed |
|---|---|
| 0 ms | 0 of 16 |
| 8 ms | 4 of 16 |
| 12 ms | 12 of 16 |
| 16 ms (one frame) | 16 of 16 |

The knobs are `SH_KEY_MIN_HOLD_MS` and `SH_KEY_MIN_GAP_MS` (declared per tile in
`runtime.tileEnv`; reference in `streamhost/docs/CONFIG.md`). **Derive the values
from the machine's frame period**, with two frames as the shipped margin: mpf2 at
60 Hz → `32`/`32`; amstradcpc, whose PSG scans the matrix at 50 Hz → `40`/`40`.
An earlier empirical 80/250/500 ms triple also worked but was never bisected and
is roughly 6× the physical requirement — extrapolating from it makes every
type-in glacial.

**Two frames is a floor, not an answer — measure it.** vic20 shipped at the
frame-derived `40`/`40` and a visitor's type-in still came back with two
characters missing. Bisected with
[`scripts/dev/emu-key-pacing-bisect.py`](../../scripts/dev/emu-key-pacing-bisect.py)
on a clone: 40/40 corrupted 1 line in 22, 60/60 and 80/80 none in 14 and 22.
The residual failure is **host scheduling, not frame quantisation** — this box
runs 30+ emulators, and when the emulator's thread is starved for longer than
the hold, the press *and* the release land between two of its input pumps and
the key is never sampled at all. That margin does not scale with the frame
period, so derive a starting value from the frame period and then *measure* on
a clone before shipping. Two traps make the measurement lie: QEMU's `send-key
hold-time` releases asynchronously and overlapping calls lose characters on
their own (use explicit `input-send-event` press/release pairs), and the
guest's cursor blinks, so mask the pixels that differ between repeated
reference captures before comparing frames.

**Turn X's auto-repeat OFF in any kiosk driven by synthetic keys — before you
touch the pacing at all.** On the Oric Atmos add (2026-08-09) the pacing was
never the problem. Every key a bridge tile sees is an injected press/release
pair, and when the release arrives late — this box runs thirty emulators — X's
typematic repeat starts hammering the key that is still "held". The demo
listing's line 40 came out as `PRINT "ORIC ATMOS 19999999999`: one late
release, eleven nines. The flood then left the emulated machine **deaf** —
nothing typed afterwards landed, until the next `loadvm` — and that symptom
impersonates, in turn, frame quantisation, host starvation and an emulator
freeze. `xset r off` in the tile's `/etc/bridge/launch.sh` fixes it; the golden
must be re-baked afterwards, because the X state is inside it. Three cheap
discriminators, in the order they pay off:

1. the guest kernel's `/proc/interrupts` i8042 counter proves whether QEMU
   delivered the keys at all (on that tile it always had);
2. a screen that keeps changing while keys do nothing is an INPUT fault, not a
   frozen emulator — but pick a test pattern that actually changes, since a
   screen scrolling identical characters compares equal frame to frame;
3. a tile with no viewer is idle-paused (`[idle] no sessions for 60s -> guest
   paused`), and a paused guest swallows every key. A bare QMP harness must
   send `cont` after each `loadvm`; `labctl` does it for you.

**The bisect's 250/250 reference is an assumption, not a law.** On that same
Oric tile a LONG hold was the failure mode: 40/40, 60/60 and 80/80 all typed a
40-character line intact in 10 of 10 trials, while the harness's "pacing nobody
disputes" reference dropped 7 characters of 40 — so
`emu-key-pacing-bisect.py` reported every rung as corrupt against a reference
that was itself broken. Look at the reference frame before believing a rung.

**Raising the pacing obliges the typist to slow down too.** The SPA waits
`line.length * perCharMs` before submitting the next line; below the tile's
hold+gap drain rate a backlog builds and BASIC loses the characters that arrive
while it is tokenising. Declare `demoProgram.perCharMs` in the registry when a
tile drains slower than the fleet default — `validate_demo_pacing` in
`scripts/tiles-registry.py` fails the build if the two disagree.

**A guest's keyboard is not necessarily laid out like a PC's.** The SPA's
`typeText()` maps ASCII to US set1 scancodes. The MPF-II's 8×8 matrix puts `=` on
Shift+O, `-` on Shift+I and `+` on Shift+P, and its shifted number row is offset
by one (Shift+8/9/0 give `( ) *` where a PC gives `* ( )`). Untranslated, `=` and
`-` **vanish** — those PC keys do not exist in the matrix — and every bracket
lands one key over. The fix is the registry-declared `spa.demoProgram.keyMap`
(applied by `applyKeyMap()` in
`spa/src/ui/grid/StreamView/typeDemoProgram.ts`). To check a new guest, read the
`PORT_CHAR` pairs in its MAME driver (e.g. `src/mame/apple/tk2000.cpp`): they
give the exact unshifted/shifted pairing of every key in the matrix.

**Wait in proportion to LINE LENGTH, not on a fixed tick.** `typeText()` returns
immediately and streamhost drains the queue at the tile's paced rate (~64 ms per
character on mpf2), so a 25-character line is still arriving 1.6 s later.
Submitting the next line on a fixed tick overruns the queue and loses characters
— it shows up as the first character after each ENTER going missing, in a
regular pattern. `DEMO_PER_CHAR_MS` in `typeDemoProgram.ts` is the per-character
budget; keep the delay proportional.

**`labctl type` is not a fair test of a guest's keyboard.** It drives QMP
directly and therefore gets none of streamhost's pacing, so it drops characters
while printing `ok: typed N chars`. Judge a keyboard through the SPA path, or
through a proof the builder runs, and check the framebuffer.

If a USB tablet covers only part of a high-resolution desktop (the Solaris VUID
case), do not hide the defect with arbitrary client scaling if an in-guest
absolute API can solve it. Conversely, do not write a guest agent where native
absolute HID already works.

## 6. Register the tile everywhere

The scaffolded `registry/tiles/<osId>.json` is the source of truth. It begins as
an inert candidate with the slot/port reservation; fill it using `alpine.json`
and `android.json` as complete streamed-tile examples, then set `enabled: true`
and promote its lifecycle only after its proof passes. Audit the
entry's `schemaVersion`, `id`, `tileDir`/`aliases`, `lifecycle`, `enabled`,
`build`, `stream`, `runtime`, `reset`, `operator`, `spa`, `museum`, `guestDoc`,
`credentialsRef`, and `render` fields. Do not add a field that is absent from
the schema or infer that a sidecar will be created merely because the registry
references it.

Regenerate and prove byte parity after every registry edit:

```bash
make tile-registry-validate
make tile-registry-generate
make tile-registry-check
```

`tile-registry-check` recomputes every output and fails on drift. The **Tile
registry** GitHub Actions workflow runs the same check for pull requests and
pushes to `main`. The generated surfaces and their actual inputs are:

| Generated artifact (do not hand-edit) | Registry fields used |
|---|---|
| `streamhost/tiles-manifest.sh` | Production rows ordered by `render.tilesManifestOrder`; `render.tilesManifestPrelude` and `render.tilesManifestInvocation`, with the invocation validated against `tileDir` and `runtime.qemu.emitArgs`. |
| `streamhost/bring-up-all.sh` | Production `tileDir` values grouped by `render.bringUpGroup` and ordered by `runtime.bringUpOrder`. |
| `scripts/build-guests/build-all.sh` | `build.rows` entries (`order`, rendered `line`/`prelude`, typed `value`, and optional `defaultOrder`) plus shared rows in `registry/registry-v1.json`. |
| `scripts/serve/tiles.json` | Every streamhost row's `id`, `stream.udpPort`, `tileDir`-derived certificate-hash path, and `render.signalOrder`. |
| `scripts/serve/golden-manifest.json` | Production `id` and `reset`, ordered by `render.goldenOrder`. |
| `scripts/tools/gallery-action-map.json` | `operator.actionMap`, ordered by `render.actionMapOrder`. |
| `spa/src/three/archetypeRegistry.ts` | `id` and `spa`, represented by the validated `render.bindingLine`/`bindingPrelude` and ordered by `render.bindingOrder`. |
| `spa/src/mock/manifest.json` | `museum` for entries that have `render.mockManifestOrder`. |
| `spa/src/data/museumCatalog.ts` | `museum`, represented by the validated `render.museumBlock`/`museumPrelude` and ordered by `render.museumOrder`. |
| `spa/src/data/catalog.ts` | The `museum` catalog subset (`accent`, `era`, `eraSoftware`, `periodBrowser`, `iconicApps`, and `blurb`), represented by the validated `render.catalogBlock`/`catalogPrelude` and ordered by `render.catalogOrder`. |
| `registry/index.json` | The aggregate of every entry, excluding generator-only `render` data. |
| `registry/generated/labctl-declarations.json` | Streamhost `tileDir` plus the declared keys in `operator.labctl`. Live observed golden state is intentionally excluded. |

Use this table as an exhaustive audit of the JSON entry, not as an edit list for
derived files. `python3 scripts/tiles-registry.py explain <osId>` is useful for
reviewing one entry's principal derived values.

### 6.0 Writing the entry: rendered blocks and visitor-facing fields

- `render.museumBlock`, `render.catalogBlock` and `render.bindingLine` are
  **pre-rendered strings** validated against the entry's `museum`/`spa` source
  fields. Editing one side without the other fails
  `python3 scripts/tiles-registry.py validate`. Change the source field, then
  regenerate.
- **`museum` describes the real machine, never how the gallery runs it.**
  `lineage` is a heritage — "Windows NT 3.x", "Multitech (Taiwan)" — not a
  paragraph. `notes` is the one operator-facing field, but
  `spa/src/data/catalog.ts` falls back to `notes` when `blurb` is absent, so a
  tile shipped without a `blurb` leaks rig detail onto the public placard.
  Always set `blurb`.
- `ramMB` cannot express a sub-megabyte machine. Use `ramKB` (the MPF-II has
  64 KB); both are accepted by the schema and the museum renderer.

### 6.1 Build registry

- `registry/tiles/<osId>.json`: add the typed and rendered `build.rows` entry;
  use its `order` and optional `defaultOrder` for the manifest/default sequence.
  Gate licensed media with class `licensed`; gate account media with the
  `media` flag. Regeneration writes `build-all.sh`.
- `scripts/build-guests/tiles/<os>.sh` remains hand-managed: implement the complete
  build, framebuffer verification, and golden/reset proof. The registry names
  the script but does not generate it.
- `scripts/build-guests/check-assets.sh` and `docs/lab/ASSETS-MANIFEST.md`: add
  the source inputs and checks. Store variable names, never secret values.
- `docs/guests/<os>.md` remains hand-managed: set `guestDoc` to it and document
  status, exact media, device-set rationale, automation, golden, pointer,
  verification, blockers, and rollback notes.

### 6.2 Streamhost registry and tile directory

Describe the stream in `stream`, the declared emitted environment in
`runtime.tileEnv`, the pinned device set in `runtime.qemu`, and startup order in
`runtime.bringUpOrder`. Put the exact emitter argument vector in
`runtime.qemu.emitArgs` and its validated shell rendering/order in `render`.
Regeneration writes the production `emit` stanza and ordered bring-up list; do
not edit either generated shell script.

Add `streamhost/tiles/<tileDir>/` when the tile needs tracked runtime material.
These source sidecars remain hand-managed even when the registry references
their paths through `runtime.qemu.launcher`, `envFixture`, or `auxFiles`:

- `qemu-streamhost.sh`: required for a **verbatim** launcher; it is the complete
  guest-visible device-set ledger, creates only namespaced sockets/files, kills
  only by pidfile, and conditionally uses `-loadvm golden` where appropriate;
- `tile.env.fixture`: appended metadata/reset stanza such as
  `SH_RESET_MODE`, `SH_GOLDEN_*`, and fixture notes;
- `qemu-setup.sh` or equivalent: optional one-time, clone-safe setup/calibration;
- `golden-bake.sh`: optional reproducible fixture creation and dirty→restore
  framebuffer proof;
- any helper used at runtime: pass it through `--aux-file` or reference a
  tracked deployed path. Do not depend on an unrecorded box-only file.

For a verbatim runtime, set `runtime.qemu.mode` to `verbatim`, point `launcher`
at the tracked script, and keep `launcherParity` honest. The generator records
and reports launcher parity but does not synthesize the launcher or
`tile.env.fixture`. The emitter produces the deployed `tile.env`, launcher, and
`ROLLBACK.md` from the generated invocation and referenced source material.
Ensure `runtime.tileEnv.SH_TILE` and paths use `tileDir`, while public maps use
`id`.

Choose `runtime.bringUpOrder` and `render.bringUpGroup` after every build or
runtime prerequisite and in a sensible memory/boot order. One-time varstore,
reattach, or cgroup behavior belongs in the hand-managed template/control-flow
code, not in an operator's shell history or the generated `TILES=(...)` row.

Validate generation in scratch before deployment:

```bash
scripts/dev/verify-emit.sh --host lab --pin-machine --verbose
# Fresh-box/local form:
# bash scripts/dev/verify-emit.sh --local --pin-machine
```

Do not save the golden until the launcher has the pinned production device set.

### 6.3 Serve, reset, and operator maps

Set `stream.udpPort` and `render.signalOrder`; generation derives the public
signal row from `id`, `tileDir`, and that port. The HTTPS server reads the
signal JSON and certificate hash fresh on every request, but the **live**
`SIGNAL_CONFIG` copy must still be updated. The SPA deploy helper preserves an
existing host copy, so do not assume an SPA deploy has copied a changed map.

For production, fill `reset` and `render.goldenOrder`. Use
`resetMode: "restart"` with `snapshot: null` only when the launcher creates a
fresh deterministic fixture. `mouse` and `keyboard` are evidence (`PASS`,
`SKIP`, or `UNVERIFIED`), not desired outcomes. Keep `reset.pointer` consistent
with `stream.pointer.transport`.

Put the performance/input probe under `operator.actionMap` and order it with
`render.actionMapOrder`. Use `mouse: null` for a text-only surface. Its `key`
may be an `id`, `tileDir`, or retained historical tool spelling; prefer an
alias-free `id` for new entries.

Declare `dir`, `qmp`, `pointer_mode`, `warpd_port`, `warpd_addr`, `ssh_port`,
`exec_port`, `exec_kind`, `exec_user`, `exec_key`, `console`, `udp_port`, and
`notes` in `operator.labctl`. Set the exec kind, port, user, and private-key
**path** only when a captured-output exec channel is proven; otherwise use null
declarations. Regeneration writes the committed declaration seed. After the
runtime tile directory, launcher, and emitted `tile.env` exist, run:

```bash
ssh lab 'labctl gen'
ssh lab 'labctl ls'
```

This verifies the declarations against live files, adds observed golden state,
and regenerates `/data/vms/streamhost/tiles.json`; do not hand-edit it.

### 6.4 Runtime SPA manifest (no rebuild for an existing archetype)

The public lineup is served from `/gallery-manifest.json`, generated from each
registry row's `museum` + `spa` data. It carries the display metadata,
archetype/transport binding, order, and `/signal/<osId>.json` reference. It does
**not** carry `credentialsRef`, logins, passwords, keys, tokens, or other private
operator data. The SPA fetches it with `cache: "no-cache"`, validates every row,
and uses its embedded generated last-known-good copy if the request 404s, fails,
or has an invalid shape.

For an ordinary OS using an existing `ArchetypeId`, do not edit SPA TypeScript or
run Vite. After updating `registry/tiles/<osId>.json`:

```bash
make tile-registry-generate
make tile-registry-check

# On an authorized deploy run (not from a source-only task), publish the
# generated signaling map and public lineup with atomic per-file replacement:
scripts/serve-https-spa.sh manifests
```

That command copies the two generated JSON documents to
`/data/vms/streamhost/serve/tiles.json` and
`/data/vms/streamhost/serve/webroot/gallery-manifest.json`; the new OS then
appears without `npm ci`, `npm run build`, or a bundle deployment. A direct
manual copy of those same two files is equivalent. Run the generator on the box
or sync the generated files before copying; never hand-edit the live JSON.

**A tile in the registry lineup is not finished until the 3D scene knows it.**
The runtime manifest carries the placard, but the WebGL museum and the on-screen
keyboard are compiled in, and they are hand-managed:

- `spa/src/ui/keyboard/keyboardProfiles.ts` — add the tile to `OS_FAMILY`, or its
  virtual keyboard falls back to `generic`;
- `spa/src/scene/machines.ts` — `ASSEMBLIES_BY_TILE` places the exhibit;
  **order matters** and must follow the registry lineup order, not alphabetical;
- `spa/src/scene/machineIdentity.ts` — a `Record<keyof typeof
  ASSEMBLIES_BY_TILE, ExhibitIdentity>` exhaustiveness check. A missing tile is a
  **type error caught only by `npm run build`**, never by vitest, so a branch can
  be green on tests and still fail the build.

Posters are two artifacts, both required: `registry/posters/<id>.md` for the
prose and `spa/public/posters/<id>/desktop.webp` for the 1024×768 hero image.
mpf2 shipped with neither and had to be fixed up afterwards.

A Vite build is still required when adding a genuinely new Three.js/React
archetype or changing UI/schema code. Such a scheduled build also refreshes the
embedded last-known-good copy. `spa/src/data/credentials.ts` remains
hand-managed, gitignored, bundle-side, and keyed by OS id; add only local
credential/sentinel values there. Never put a real credential in the public
manifest, tracked source, docs, screenshots, or logs.

### 6.5 Cold boot and boot video

Boot video is optional. Even without publishing a clip, audit the cold-boot
behavior so the guest cannot stop on first-run input.

- Add `scripts/coldboot/<tileDir>-zero-input-prep.md` describing the ready state,
  blockers, automation, and clone proof.
- Add a `case` arm to `scripts/coldboot/bootrec-tiles.conf`: `BR_BOOT_KIND`, final
  canvas, FPS/audio, every writable disk to clone, port rewrites, detection tier,
  timeout, and optional automated record driver.
- Run `record-boot.sh <tileDir> --dry-run` and inspect the rewritten clone launcher
  before a real capture. It must never attach a live writable disk.
- A published clip's last frame must match the golden's first live frame. Follow
  `scripts/coldboot/README.md`; do not publish a clip merely because it plays.

On an authorized box-side run:

```bash
export SH_DBUS_TAP=/data/vms/streamhost/build/target/release/bootrec-tap
export WEBROOT=/data/vms/streamhost/serve/webroot
scripts/coldboot/record-boot.sh <tileDir> --dry-run
scripts/coldboot/record-boot.sh <tileDir>
scripts/coldboot/postprocess-boot.sh <tileDir>
scripts/coldboot/gen-boot-manifest.sh <tileDir>
```

The runtime `/boot/index.json` supplies detailed clip metadata without an SPA
rebuild. The current grid badge/mount also reads `OSBinding.bootVideo`, so a
newly published tile still needs `spa.bootVideo` in its registry entry followed
by regeneration and an SPA rebuild until the architecture is fully
runtime-driven.

## 7. Deploy and verify

### 7.1 Pre-deploy checks

```bash
make tile-registry-validate
make tile-registry-generate
make tile-registry-check
bash -n scripts/build-guests/tiles/<os>.sh
bash -n streamhost/tiles/<tileDir>/qemu-streamhost.sh  # if verbatim
jq empty scripts/serve/tiles.json
jq empty scripts/serve/golden-manifest.json
jq empty scripts/tools/gallery-action-map.json
scripts/build-guests/build-all.sh --list
scripts/build-guests/build-all.sh --check-assets --only <builderKey>
(cd spa && npm ci && npm run build)
```

Run the builder against its own namespaced artifact. Require its checksum,
framebuffer, input, and golden round-trip gates before registration is deployed.

### 7.2 Supervised tile deployment

Follow Phase 5 of `MASTER-REPRODUCE.md` for repository-to-box sync. In outline:

1. finish `registry/tiles/<osId>.json` and any hand-managed builder, guest doc,
   launcher, `tile.env.fixture`, or coldboot sidecar; prepare the gitignored
   credential separately when required;
2. run `make tile-registry-generate`, then `make tile-registry-check`;
3. sync the tracked tree, including the registry, generated streamhost/serve/SPA
   files, generated labctl declarations, and hand-managed tracked sidecars;
4. emit with pinned machine types into scratch and pass `verify-emit`;
5. emit/deploy the new tile directory;
6. launch only its `qemu-streamhost.sh`, wait for `qmp.sock`, then start
   `streamhost@<tileDir>`;
7. publish the **three** runtime documents with
   `scripts/serve-https-spa.sh manifests` (or atomically copy generated
   `scripts/serve/tiles.json` to the live `SIGNAL_CONFIG` path,
   `scripts/serve/webroot/gallery-manifest.json` to the live webroot, and
   `scripts/serve/golden-manifest.json` beside the HTTPS server).
   **Do not skip the third.** Its keys are the allow-list for
   `POST /restore/<osId>` (`_restore_osids()` in
   `scripts/serve/osgallery-https-server.py`), so a tile missing from the
   live copy streams perfectly while its "reset to golden" button returns
   `404 unknown osId` — a failure that looks like a broken tile and is not.
   This doc said "the two runtime documents" until 2026-08-09 and that is
   exactly how the Commodore wave shipped with dead reset buttons;
8. run `labctl gen` so the generated declarations are checked against the live
   runtime and observed state is added;
9. do not rebuild the SPA for a tile that uses an existing archetype; a new
   compiled archetype or UI/schema feature follows the coordinated SPA build and
   deploy path.

Do not run the full `bring-up-all.sh` merely to test one new tile if that would
restart unrelated guests. Once the tile is proven, run the full ordered path in
a planned fleet-rebuild test.

### 7.2.1 Traps that make a correct fix look broken

Four of these cost time on the MPF-II add. Check them before you conclude a
change did not work.

- **The tile is running an old binary.** streamhost deploys are per-tile
  canaries: `scripts/dev/build-deploy.sh` swaps a `current` symlink under
  `/usr/local/lib/streamhost/tiles/<tile>/`, and the fleet is **not** promoted
  automatically. A tile can therefore be running a binary that predates the knob
  you just declared in its `tile.env`. Confirm with
  `ssh lab 'readlink -f /usr/local/lib/streamhost/tiles/<tile>/current'` before
  debugging the knob.
- **SPA changes are invisible until the bundle is deployed** to
  `/data/vms/streamhost/serve/webroot/`. A local `npm run build` proves nothing
  about what the browser is loading.
- **Tiles idle-pause with no viewer attached**, so a raw `ssh` into a bridge
  guest simply hangs. `labctl` auto-resumes and is the supported path. A
  freshly-resumed VM also swallows the first characters sent to it.
- **A silent emulator segfault reads as an X or systemd fault.** On the vic20
  add, `xvic` died instantly with no output; what was observable was X exiting a
  second after it started and `getty@tty1` looping to `start-limit-hit`, with no
  `(EE)` in the Xorg log and nothing from the emulator in the startx log.
  **VICE 3.9 segfaults in `vice_banner()` whenever its stdout is not a
  terminal** (`log_helper()` hands a NULL to `strlen`), so copying mpf2's
  `exec startx … >"$HOME"/startx.log 2>&1` — correct and harmless for MAME —
  kills a VICE tile. Leave stdout on tty1, as the stock bridge profile and the
  c64/vic20 tiles do. A *second*, independent fault has the same signature: VICE's
  `make install` skips some ROM data files and the emulator segfaults with no
  output when one is missing (the C64 BASIC ROM for c64, `basic-901486-01.bin`
  for vic20). Reach for `script -qec '<cmd>' /dev/null` (a pty makes the first
  fault vanish) and gdb, not for the X log. See
  [`docs/guests/vic20.md`](../guests/vic20.md).
- **A `/proc` scan matches the shell running it.** The `pkill -f` self-match trap
  in `AGENTS.md` applies equally to
  `for p in /proc/*/cmdline; do grep <pattern> ...`: it reported 9 stray
  processes here when the true answer was 0. Resolve each candidate through
  `/proc/<pid>/exe` and check the actual binary.

### 7.3 Acceptance matrix

Use the real HTTPS origin and public `osId`:

```bash
# Signaling exists and describes the intended UDP port/hash.
curl -ksS -o /tmp/<osId>-signal.json -w '%{http_code}\n' \
  https://192.0.2.10:8443/signal/<osId>.json
jq '{host,udpPort,hasHash:(.certHashB64|type=="string" and length>0)}' \
  /tmp/<osId>-signal.json

# Operator inventory and framebuffer.
ssh lab 'labctl ls'
ssh lab 'labctl shot <tileDir> /tmp/<tileDir>-accept.png'

# Reset (safe restore only; never savevm through this endpoint).
curl -ksS -X POST https://192.0.2.10:8443/restore/<osId>
ssh lab 'labctl shot <tileDir> /tmp/<tileDir>-restored.png'

# Only where a captured-output exec channel was explicitly configured.
ssh lab 'labctl exec <tileDir> "uname -a"'
```

Then verify in a browser, not only with curl:

- the exhibit appears once with the right placard/archetype;
- `/signal/<osId>.json` returns 200 and the browser receives moving frames and
  audio (where enabled);
- absolute or relative pointer reaches all edges without scaling drift; click,
  drag, wheel, keyboard, pointer-lock exit/re-entry, and touch semantics work;
- reset restores the exact curated fixture and input works immediately after;
- cold restart reaches the same fixture with no human action;
- optional boot clip has audio, scrubs, and hands off without a visible seam;
- stopping/restarting this tile by pidfile/systemd does not affect another tile;
- no secret appears in the SPA bundle, network response, Git diff, or logs.

Finally, run `make tile-registry-check`, compare the live signal and labctl
outputs with the canonical entry, and keep the pre-change launcher+golden pair
until repeated cold boots and restores have passed.

## 8. Worked friction example: `soltest-warpd` / `soltest-ghid`

The Solaris A/B pair records the friction the canonical registry removed.
Before the registry landed, making two experimental streams browser-visible
required independent edits to:

- two tile directories with `tile.env` and bespoke launchers;
- two signal rows in `scripts/serve/tiles.json` for UDP 54911/54912 and the
  corresponding certificate-hash paths;
- two bundled `OS_BINDINGS` rows in `archetypeRegistry.ts` (before the runtime
  manifest migration);
- `labctl gen` after runtime files existed;
- a complete SPA rebuild and deployment.

Today a registry row declares lifecycle, signal, public museum/binding data, and
labctl capabilities. Regeneration updates those derived surfaces together; the
two runtime JSON files can be published without rebuilding the SPA, while
lifecycle still controls inclusion in production tile and golden manifests.

The remaining friction is real but no longer duplicated registry work. The pair
still needs hand-managed verbatim launchers/runtime sidecars and live runtime
proof. Any registry change still needs the generated signal map copied to
`SIGNAL_CONFIG`, `labctl gen` run after the runtime files exist, and an SPA
rebuild because bindings/catalog data remain bundled. For a normal new tile,
the repeated lineup metadata is principally one registry file plus regeneration;
the OS-specific builder, guest doc, golden, and optional launcher/fixture remain
authored artifacts.
