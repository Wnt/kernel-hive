# oberon guest — ETH Native Oberon 2.3.6

Status: **LIVE, staged for landing** (Tier 1, QEMU). See
`docs/lab/OBERON-WAVE.md` for the wave that produced this station — the
ledger, the two walls hit, and what is still open (retronet web plane).

**Guest:** ETH Zurich's **Native Oberon 2.3.6** (13 May 1999) — Niklaus Wirth
and Jürg Gutknecht's Oberon System 3 with the Gadgets UI, running on bare PC
hardware with **no host OS underneath**: Native Oberon IS the operating
system, booting straight from its own IDE partition to the Gadgets desktop.
i386, 64 MB RAM, its own TCP/IP stack (NetSystem) and its own `ne2000` driver
(`NetNe2000pci.Mod`). QEMU, not host-native (rule 13 exempts guests that boot
an emulated machine rather than a stock host application).

## Identity and source

- Public ID / tile directory: `oberon`
- Reserved slot / UDP port / VMID: `195` / `54195` / `195`
- Archetype: `beige-ibm-pc`
- Guest media (staged at `/data/assets-staging/oberon/` on labhost, never
  committed as bits — the tile builder pins URL + sha256):
  - **What ships:** `NativeOberon-2.3.6-qemu-fallback.img`, a third-party
    ready-made, pre-installed IDE disk image, 83,886,080 bytes, sha256
    `65f21c27cd62ceffab303d7266606f4db3c22e83be462f8a70a0f0ea4f8c60d1`, from
    `https://github.com/asig/native-oberon` (`2.3.6/`), direct URL
    `https://raw.githubusercontent.com/asig/native-oberon/master/2.3.6/Native%20Oberon%202.3.6.img`.
    The repo's own licence is BSD-style; the Oberon system itself carries the
    ETH Oberon licence (also BSD-style, attribution required).
  - **Staged but not what ships:** the official ETH installer diskettes
    `Oberon0.Dsk` and `OberonCF0.Dsk`, and the 12.3 MB
    `NativeOberon_2.3.6.tar.gz` release tree, all from the SourceForge mirror
    of `ftp.inf.ethz.ch/pub/ETHOberon/Native/`. These are the documented
    from-floppy install path — see §Traps, wall 1 — never raced for this
    station.
  - The Virtual OS Museum was consulted for facts only (reference-only,
    CC BY-NC-SA); nothing was copied from it for this guest.

## Build and device set

- Builder: `scripts/build-guests/tiles/oberon.sh` — converts the raw
  ready-made image to `disk.qcow2` (order 82, `class: fast`, `~1m`,
  `automation: full`).
- Launcher: `streamhost/stations/oberon/qemu-streamhost.sh`. Device set id
  **`oberon-ps2rel-vesa1280-fdqcow`** (golden + binary + device set are ONE
  combination — rule 6):
  - `qemu-system-x86_64` (pve-qemu-kvm 11.0.2), `-machine
    pc-i440fx-11.0,acpi=off -enable-kvm -cpu host`
  - 64 MB RAM, `-smp 1`
  - `-vga std` — Bochs VBE 2.0 LFB, what Oberon's VESA display driver
    expects; the guest runs 1280x1024
  - Storage: `disk.qcow2` on IDE index 0, the **only persistent block
    device**; one empty 1.44 MB floppy, as **QCOW2, not raw** (see §Traps)
  - Audio: `sb16` over the dbus audiodev (Oberon's Sound driver is SB16)
  - Network: one `ne2k_pci` NIC on `-netdev user,id=n0,restrict=on` (slirp,
    no route to labhost or the world) until `rn-tapnet.sh` ships — see
    §Retronet
  - Display: dbus p2p
- Ready framebuffer: the Gadgets desktop, System.Log top right, System.Tool
  below it, empty left user track, reached directly from the ready-made
  image with no bounded automation needed (it boots straight to the
  desktop).

## §Pointer

**PS/2 relative, through the daemon's rel bridge (`dbus-rel` backend).**
Native Oberon reads a plain PS/2 mouse — there is no absolute path on this
guest (no USB, no vmmouse). Measured with QMP `input-send-event` rel deltas
and `scripts/dev/cursor-locate.py` (exact sprite match):

- Scale: exactly **1.5 px per PS/2 unit**, both axes, no acceleration
  (pinned at (0,0), 400 units → (600,600) exactly).
- Two-target readback, both exact: +200/+200 from pin → `300 300`;
  +100/+600 from pin → `150 900`.
- Golden home: +400/+340 from pin → `600 510`.
- Fixture: `SH_INPUT_BACKEND=dbus-rel`, `SH_CURSOR_SCALE=0.6667`,
  `SH_REL_MAX_STEP=126`, `SH_REL_QUANTUM=0`, `SH_REL_HOME_ON=reset`,
  `SH_REL_HOME_TO=600,510`.

**Trap:** the exact-match cursor template is background-dependent — Oberon
draws its cursor as blue-on-grey over the desktop but black-on-white inside
a text viewer, so `cursor-locate.py` needs one template per background or it
reports NOTFOUND over a light viewer even though the pointer is plainly
there in the frame (`bake/tgtC.ppm`, `tgtC-crop.png`).

**Three buttons are the whole UI, and the SPA must carry all three.** LEFT
sets the caret in a text viewer, MIDDLE executes the command word under the
pointer (this is how every menu item in System.Tool runs), RIGHT selects. A
pointer with no middle button reaches half the system at most. Proven:
pin + walk 570/420 units → (855,630), the word `System.Directory` in
System.Tool; one middle click opened a new `Directory` viewer
(`bake/mid.ppm`, `mid-crop.png`).

## §Keyboard

Proven: left click at (960,60) inside System.Log to set the caret, then
`scripts/dev/qmp-type.py --qmp .../qmp.sock --gap 0.08 "Opus typed this"` —
the string appeared under the boot banner, no dropped or scrambled
characters (`bake/kbd.ppm`, `kbd-crop.png`). Fixture pacing is the fleet
floor, `SH_KEY_PRESS_MS=40` / `SH_KEY_GAP_MS=40`; no fleet-specific pacing
issue found on this driver.

## Golden, reset, and rollback

- Reset mode: `loadvm golden`.
- **Bake trap, fixed:** the first bake's empty floppy was raw
  (`floppy-empty.img`); `savevm golden` failed with exactly `Error: Device
  'floppy0' is writable but does not support snapshots`. Fixed by making the
  empty floppy QCOW2 (`floppy-empty.qcow2`, created on demand by the
  launcher with `qemu-img create -f qcow2 ... 1440k`) — a device-set change,
  captured in the device set id above.
- **Proven:** `savevm golden` took **0.107 s**, wrote a **3.51 MiB** vmstate
  (snapshot id 1, tag `golden`, VM_CLOCK 00:26.046). Restore proof: QEMU
  killed by `/proc/<pid>/exe`, relaunched `-loadvm golden -S`, `cont` —
  **0.296 s** to running, screendump pixel-identical to the pre-`savevm`
  frame (`ImageChops.difference(...).getbbox() is None`), cursor back at
  `600 510`. Frames `bake/golden-frame.ppm`, `bake/restore-frame.ppm`.
- Golden fixture: the Gadgets desktop at 1280x1024 — `System.Log` top right
  carrying `ETH Oberon System 3 / PC Native 2.3.6 (13 May 1999)`,
  `System.Tool` below it (Script.Open, Compiler.Compile, System.Directory,
  NetSystem.Tool, Desktops.OpenDoc, …), the whole left user track empty flat
  grey, arrow pointer parked at (600,510).
- Credentials reference only: `guest/oberon` — Native Oberon has no login
  prompt; there is nothing to record.
- Rollback: the pre-bake dead predecessor's rig was killed by `/proc/<pid>/exe`
  before this station's own bake rig started; keep this golden + binary +
  device-set combination together (rule 6) until any replacement is
  restore-proven.

## §Sandbox

**Emulated machine under the fleet QEMU — nothing runs outside it.** The
launcher's device set (above) carries no 9p/virtfs/smb/`fat:` host-directory
drive (only `disk.qcow2` and the empty qcow2 floppy), no `hostfwd` (the
netdev is restricted slirp, `restrict=on`; QEMU logs `Slirp: Failed to send
packet` when the guest's own `NetNe2000pci` driver ARPs into it — proof the
guest's network stack is alive, not that it reaches anywhere), no guest-
reachable QMP/monitor socket (`qmp.sock` is a host-side UNIX socket under
the station dir), and no `virtio-serial` or other host channel. The nspawn
audit block (for a host-application-as-guest station) does not apply: no
host application runs here at all — Native Oberon is the guest's entire
software stack, so there is nothing outside the emulator to contain.

## §Retronet — allocated, meaningful, not proven

10.99.0.42 / tap `oberonrn0` / chain `OBERONRN-IN` / UIN 19500 (UIN unused —
no IM client exists for this guest). This is one of the few guests where
retronet is genuinely meaningful: Native Oberon ships its own TCP/IP stack
and its own `ne2k_pci` driver, and the device is already in the golden, so
the NIC **backend** can move from slirp to the tap without a re-bake. But no
`rn-tapnet.sh` is committed (rule 15 — a committed tap script deploys
fleet-wide on the next `box-deploy --apply`), so the web plane is **not
proven**. Next step: bring the tap up, configure 10.99.0.42 in the guest via
`NetSystem.Tool`/`Oberon.Text`, and prove `Desktops.OpenDoc` fetching a
retronet page on the framebuffer before committing `rn-tapnet.sh`.

## §Traps

1. **From-floppy install wall — inherited, not reproduced.** The
   `asig/native-oberon` README records `Oberon0.Dsk` stopping at `Boot.Bin
   checksum bad` under QEMU, with their working path going through
   VirtualBox + `vbox-img convert`. This station never attempted the
   from-floppy path — the ready-made image booted first try — so treat the
   checksum wall as unverified against this fleet's QEMU build, not as a
   proven dead end.
2. **`savevm` refuses a writable raw floppy.** See §Golden above — fixed by
   using a QCOW2 empty floppy.
3. **Cursor template is background-dependent.** See §Pointer above — a
   NOTFOUND from `cursor-locate.py` over a light viewer is a template-bank
   gap, not a pointer failure.

## Open items

- Retronet web plane (§Retronet above) — the top open item, with the exact
  next command.
- From-floppy install path (§Traps 1) — never raced against this fleet's
  QEMU build.
- IM plane — n/a, no client exists for this guest.
