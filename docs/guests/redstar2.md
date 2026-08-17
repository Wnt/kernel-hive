# Red Star OS 2.0

Production identity: `redstar2` · VMID/slot 120 · UDP 54120 · i386 guest.

## Media and provenance

The private install source is Internet Archive item
[`redstar_20181224`](https://archive.org/details/redstar_20181224), file
`redstar.iso`. The disc identifies itself as `REDSTAR DESKTOP 2.0` and carries
an x86 El Torito boot image. The lab copy is 1,416,017,920 bytes and has locally
measured SHA-256
`69a45d07c302782cb777d03abd39c5b45b4099e5c994a74a77bb71ab5d229997`.
It is staged at `/data/assets-staging/redstar2/redstar.iso` beside
`MANIFEST.sha256`; redistribution terms are unclear, so the ISO remains private
and is never committed.

## Isolation policy

The guest is deliberately air-gapped at the emulated-hardware boundary. Every
install, capture, proof, and production launch uses `-nodefaults` and explicitly
adds only disk, VGA, USB tablet, and host-side display/control backends. There
is no NIC, `-netdev`, `-nic`, network-class `-device`, `hostfwd`, in-guest SSH,
or warpd TCP path. `labctl` therefore declares `exec_kind: none`. Any build-time
payload is delivered by a second read-only ISO, never over a guest network.

This is important beyond reproducibility: Red Star OS has been analyzed as a
surveillance-oriented distribution. The gallery does not grant the preserved
guest a communications device.

## Pinned production devices

- `qemu-system-x86_64`, KVM, `pc-i440fx-11.0`, `-cpu host`
- one vCPU and 1024 MB RAM
- 16 GiB qcow2 as IDE disk 0, `-boot order=c`
- `-vga std` (QEMU Bochs VBE, 16 MiB), Xorg `vesa` + `Option "ShadowFB" "on"`
  at 1920×1200, depth 24 (see the display note below)
- `-usb -device usb-tablet`
- no audio device (a working AC97 guest driver was not established)
- no network device or backend

### Display: std VGA at 1920×1200 (era-correct bump, 2026-07-27)

Originally shipped `-vga cirrus` at 1024×768×16 (inbox Xorg `cirrus` driver,
software cursor, no accel). Cirrus's fixed 4 MiB VRAM cannot reach a 1920×1200
16:10 mode and QEMU 11 blanks/corrupts Cirrus at hi-res, so the adapter was
swapped to `-vga std`. Because a display-adapter change breaks `loadvm golden`
matching, this was an atomic rebuild: the verbatim launcher's `-vga` line plus a
checkpoint recaptured on the std device set.

Red Star 2's 2.6.25 kernel has no `bochs-drm`, so on std VGA Xorg uses the
**`vesa`** driver (VBE 3.0). The earlier build note — *"the installed Xorg
desktop tears large black rectangles" under std* — was the vesa driver handed a
**banked** VBE framebuffer window with no shadow: partial/banked writes show
through as black rectangles. Enabling **`Option "ShadowFB" "on"`** makes vesa
render to a RAM shadow and blit the whole surface to the linear framebuffer — a
packed-linear memcpy that is tear-free (clone-proven at 1920×1200: the
fine-line wallpaper and a full-content window drag stay clean, no black
rectangles). `/etc/X11/xorg.conf` pins `Driver "vesa"`, ShadowFB on, `NoAccel`,
`Modes "1920x1200"` at depth 24, DPMS/blank-time off; the old cirrus config is
kept in-guest as `xorg.conf.cirrus-bak`. The evdev absolute USB-tablet input
section (`/dev/input/event3`, the coordinate patch) is preserved verbatim, so
the pointer stays 1:1 full-screen (calibration corners `a=[100,100]`,
`b=[1800,1100]`). Host capture code is unchanged.

## Machine-vision installation

`scripts/build-guests/tiles/redstar2.sh` is fail-fast and uses a uniquely namespaced
`/data/vms/sandbox/redstar2-build-YYYYMMDD/` directory. It drives Anaconda with
bounded QMP framebuffer state transitions, Korean/English OCR, and saved failure
frames:

1. installer welcome;
2. blank-disk initialization confirmation;
3. partition selection and the create-partition dialog;
4. one primary `/` partition using the available space;
5. MBR boot-loader confirmation;
6. root-password screen;
7. package installation and explicit completion screen.

No transition is accepted merely because a timeout elapsed. The installer VM
is stopped by its own pidfile after completion, the install ISO is removed, and
the disk cold-boots under the final device topology.

The first-boot corrections are carried on a read-only helper ISO. It configures
Cirrus Xorg and builds a small, source-level correction to the era evdev driver:
the stock driver passes raw 0–32767 tablet values to Xorg 1.3 instead of the
already screen-scaled values. The patch uses the latter, giving true full-screen
absolute coordinates. Fedora-era compiler/SDK RPMs and upstream
`xf86-input-evdev-1.1.5` are host-fetched into that helper ISO; the guest still
has no network hardware. A normal `gallery` account is created and KDM is
configured offline to log in to its KDE session automatically. Root and gallery
passwords are supplied through a private file descriptor and QMP key events;
they are stored only in gitignored `spa/src/data/credentials.ts`.

## Pointer and keyboard proof

The final Xorg configuration binds the QEMU USB Tablet through evdev at the
stable `/dev/input/event3` node under the pinned topology. Real framebuffer
evidence proves inset versions of all four corners, center, a blank-desktop
click, an Alt+F2 runner launch, and explicit keyboard key-down/key-up events
immediately after `loadvm golden`. The cursor covers the entire 1920×1200
surface; the UI does not set `pointerRel` or compensate with scaling.

Registry/streamhost settings are `--pointer abs --input-dev usb`,
`SH_POINTER=abs`, and `pointer.transport: "abs"` with `usb-tablet`.

## Checkpoint scene and reset

The scene is the clean, logged-in `gallery` KDE desktop, with no modal,
wizard, screensaver, or ticking clock. KDM auto-login makes both cold boot and
checkpoint restore zero-input paths. The qcow2 contains the required internal
checkpoint `golden`. The capture gate performs:

1. `savevm golden` and tag verification;
2. dirty the desktop, `loadvm golden`, and compare the restored real
   framebuffer byte-for-byte with the saved ready frame;
3. inject pointer input immediately after restore;
4. start a fresh QEMU process with the final device set and `-loadvm golden`,
   then repeat framebuffer and input checks.

Reset is `resetMode: loadvm`, checkpoint `golden`, through
`reset-hmp.sock`. A service restart also executes `-loadvm golden`. The launcher
refuses to start if the tag is absent, making launcher and disk an atomic pair.

### KDE screensaver disabled (no branded saver on idle, 2026-07-27)

Red Star 2 runs KDE 3.5.1, whose screensaver has an idle timer independent of X
DPMS/blanking (already off in `/etc/X11/xorg.conf`). Left at defaults,
`kdesktop` fires the **KBanner** saver after `Timeout` (system default 300 s),
painting the branded red text `《붉은별》 사용자용체계 2.0판` on black. In KDE 3
this setting lives in **`kdesktoprc`** `[ScreenSaver]`, not `kscreensaverrc`
(confirmed from `kcm_screensaver.so` / `kdesktop_lock`, which reference
`kdesktoprc`); the logged-in desktop is user `gallery` with `KDEHOME=~/.kde`.

The checkpoint therefore captures the saver off. In the running session
`~/.kde/share/config/kdesktoprc` `[ScreenSaver]` is `Enabled=false`, `Saver=`
(blank), `Timeout=86400`, and `kdesktop` is disabled at runtime with
`dcop kdesktop KScreensaverIface enable false` + `configure`, so the in-RAM
checkpoint also reports `isEnabled=false`. A belt-and-suspenders `kscreensaverrc`
carrying the same keys is written even though this KDE build never reads it.
Clone proof at 1920×1200: with the saver forced to a 5 s timeout the branded
KBanner activated on idle; after the disable, 25 s of idle left the desktop
untouched. On the live checkpoint, `loadvm golden` restores the clean scene and
`isEnabled` is `false`. This is applied on top of the std-VGA checkpoint; the device
set is unchanged.

## Rebuild and verification

Run on labhost with the password passed on fd 3 without printing it:

```bash
scripts/build-guests/check-assets.sh --only redstar2
scripts/build-guests/tiles/redstar2.sh 3</path/to/private-password-fd-source
```

The canonical output is `/data/gallery-guests/RedStar2/redstar2.qcow2`.
Before sealing, the builder creates `redstar2-pre-golden.qcow2`; deployment keeps
`/data/gallery-guests/RedStar2/redstar2.qcow2.bak-pre-golden`. If a live disk
already exists, it is timestamp-copied before replacement. QEMU is killed only
through the builder/station pidfile; never use `pkill qemu`.

Release checks include the registry generate/check/validate gates, required
`golden` tag, real framebuffer shot, input proof after restore, signal document,
and a launcher grep that must find zero network-device/backend tokens. Roll back
by stopping only `streamhost@redstar2`, atomically restoring the backup qcow2,
confirming its expected snapshot policy, and starting only that service.
