# Red Star OS 3.0 Desktop (`redstar3`)

## Status and acceptance contract

`redstar3` is the private, air-gapped Red Star OS 3.0 Desktop preservation
exhibit. Its public ID, runtime station directory, and builder key are all
`redstar3`; the production slot is 121 and the stream UDP port is 54121.

The accepted artifact is `/data/gallery-guests/RedStar3/redstar3.qcow2`. It
must contain the internal checkpoint tag `golden` and start at a stable,
input-ready Red Star desktop. The checkpoint and the emitted launcher are one
atomic pair. Any guest-visible device change requires a new checkpoint.

## Media and provenance

- Edition: Red Star OS 3.0 **Desktop**, i386, circa 2013.
- Source class: preservation source; redistribution terms are unclear.
- Item: `https://archive.org/details/redstar_desktop3.0_sign`.
- File: `redstar_desktop3.0_sign.iso`, 2,614,644,736 bytes.
- SHA-256 measured on labhost:
  `895ad0e01ae0d35a65e9ac42dd34d0a1d685d6dfa331ce5b4f24bbc753439be3`.
- Intake path: `/data/assets-staging/redstar3/redstar_desktop3.0_sign.iso`,
  checked by its adjacent `MANIFEST.sha256`.

The ISO volume label is `RedStar Desktop 3.0`; its package set contains
`redstar-release-3.0-1.rs3.0.i386.rpm`. Those two independent media facts
distinguish this image from the Server edition and from the other images in
the multi-file Archive item. The ISO stays private under `/data` and is never
committed or served.

## Pinned QEMU device set

The final device set is recorded in `registry/stations/redstar3.json` and emitted
by `streamhost/stations-manifest.sh`:

- `qemu-system-x86_64`, KVM, `pc-i440fx-11.0`, one vCPU, 1024 MiB;
- `-cpu Nehalem,kvm=off`, the stable fallback selected after `-cpu host`
  stopped during early PCI/kernel initialization;
- a 16 GiB qcow2 disk on IDE 0 and an empty IDE CD device on IDE 2;
- `-vga std`, driven by Xorg `vesa` + `Option "ShadowFB" "on"` at 1920x1080
  (packed-linear framebuffer; see the display note below);
- no audio device (no working guest driver was established);
- `-usb -device usb-tablet`, with the default PS/2 keyboard;
- `-nodefaults`, followed by explicit devices only.

There is deliberately **no guest network device**. Every install, first-boot,
checkpoint-capture, verification, and production command uses `-nodefaults` and has
no `-netdev`, `-nic`, network `-device`, or `hostfwd`. The canonical registry
declares no exec/SSH channel. Do not remove `-nodefaults`: QEMU otherwise adds
an implicit e1000 on this machine type even when no network option appears.

### Display: std VGA at 1920x1080 (era-correct resolution bump, 2026-07-27)

Originally shipped `-vga cirrus` at 1024x768: Cirrus's fixed 4 MiB VRAM cannot
reach a 16:9 era-correct mode and QEMU 11 blanks/corrupts Cirrus at hi-res.
Cirrus was swapped for `-vga std` (QEMU Bochs VBE, 16 MiB) at **1920x1080**.
Because a display-adapter change breaks `loadvm golden` matching, this was an
atomic rebuild (new std launcher + a checkpoint recaptured on the std device set).

Red Star 3's kernel (2.6.38) has no `bochs-drm`, so on std VGA Xorg autoconfig
falls through cirrus → **`vesa`** (VBE 3.0, SeaBIOS). The vesa driver aborts
with *"Banked framebuffer requires ShadowFB"* unless ShadowFB is enabled, so a
small `/etc/X11/xorg.conf` pins `Driver "vesa"`, `Option "ShadowFB" "on"`, and
`Modes "1920x1080"` at depth 24 (plus DPMS/blank-time off). ShadowFB renders to
a RAM shadow and blits to the linear VBE framebuffer — a packed-linear memcpy
that is tear-free and captured 1:1 by streamhost's scanout path. The earlier
build note that "`std` tears the graphical installer into vertical stripes" was
the *installer's* own video path; the installed KDE desktop under vesa+ShadowFB
renders the wallpaper, top menubar, dock, and anti-aliased dialogs as complete,
tear-free 1920x1080 frames (clone-proven on `/data/vms/soltest/redstar3-res-*`
before the live cutover). The absolute USB-tablet stays 1:1 full-screen at the
new resolution; calibration corners are `a=[12,12]`, `b=[1906,1068]`.

## Build and machine-vision installation

Run only on labhost. The default work directory is namespaced as
`/data/vms/soltest/redstar3-build-YYYYMMDD`; it never uses a live station, a
`soltest-*` station, or `/mnt/poc`.

The installer has no answer-file interface. `scripts/build-guests/tiles/redstar3.sh`
boots the ISO and drives it as a bounded machine-vision state machine:

1. capture the real framebuffer through QMP;
2. identify the welcome, disk-initialization, target-disk, administrator,
   Pyongyang zone, date/time, confirmation, progress, and completion states
   with cropped templates;
3. save the detected pre-action frame, inject one bounded action through the
   USB input path, and require a framebuffer transition;
4. retain the last frames and fail if the expected next state does not appear;
5. stop by the namespaced pidfile at the completion screen before the ISO can
   boot again.

The administrator screen creates `gallery` and sets the same known secret for
the disabled-login root account. Pass the password on standard input as
documented by the builder. The value lives only in the gitignored
`spa/src/data/credentials.ts`; it must never be placed in a shell argument,
environment dump, tracked file, screenshot, or build log.

Red Star's `kdmgreet` crashes under this QEMU configuration before it can
accept a login. The builder therefore creates a small ext2 helper image,
attaches it as a second IDE disk while the install ISO rescue TTY is running,
and applies the tracked `redstar3-offline-apply.sh`. That patch enables KDE
auto-login for `gallery` and disables the power-manager, mixer, and recurring
integrity-checker autostarts that would otherwise raise delayed modals over the
scene. This is offline file injection, not a network path. First boot remains
framebuffer-gated; a timeout or a merely non-black screen is not success.

## Ready state, pointer, and checkpoint

The checkpoint scene is a logged-in, idle 1920x1080 macOS-styled desktop with no
wizard, modal, screen saver, or focused secret field. The wallpaper, top menu
bar, and dock must all be fully rendered. (On a cold boot the audio subsystem
raises a one-time "음성드라이버초기화에서의 오유" modal because the station is
air-gapped with no audio device; dismiss it with Enter before `savevm golden` —
`loadvm golden` then restores the modal-free state.)

Pointer transport is absolute USB HID: streamhost emits
`--pointer abs --input-dev usb`; `station.env` has `SH_POINTER=abs`; the UI row
does not set `pointerRel`. Acceptance requires framebuffer-visible motion to
all four corners and centre, a click, a dock/menu drag, and keyboard make/break.
Coverage defects are fixed in the guest adapter/resolution, never hidden with
client scaling.

At the ready desktop, the capture procedure:

1. retains a pre-existing output disk as a timestamped rollback copy;
2. deletes only an obsolete `golden` tag on the disposable build artifact;
3. runs `savevm golden` and requires the tag in `qemu-img snapshot -l`;
4. dirties the visible desktop/input state, runs `loadvm golden`, and requires
   the scene framebuffer again;
5. stops by pidfile, starts a fresh QEMU process with the exact production
   device set plus `-loadvm golden`, and repeats framebuffer/input checks;
6. atomically promotes the qcow2 only after every gate passes.

Reset policy is `loadvm`, checkpoint `golden`. The HTTPS restore endpoint is
non-destructive and may load this tag; it must never save or replace it.

## Verification and rollback

Repository gates:

```bash
bash -n scripts/build-guests/tiles/redstar3.sh
scripts/build-guests/check-assets.sh --only redstar3
make station-registry-generate
make station-registry-check
make station-registry-validate
```

Live acceptance uses `labctl shot redstar3`, `GET /signal/redstar3.json`, and
`POST /restore/redstar3`, followed immediately by another framebuffer/input
proof. The signal row must report UDP 54121 and a nonempty certificate hash.

Rollback is station-local: stop only `streamhost@redstar3`, stop QEMU only through
`/data/vms/streamhost/stations/redstar3/qemu.pid`, restore the retained launcher
and qcow2 pair, relaunch that station, and start only its service. Never use
`pkill qemu`, never restart the fleet, and never alter another station.
