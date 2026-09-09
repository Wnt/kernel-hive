# ravynos guest — ravynOS 0.6.1 "Hyperpop Hyena" (amd64 live ISO)

Status: **proven** (Tier 2). Media is sourced, hashed and staged; the device set
is settled by first-hand probes on labhost — UEFI/OVMF, `pc-q35-11.0`, `-vga
std`, USB HID, intel-hda; the golden is baked and **restore-proven byte-exact**;
pointer, keyboard, audio and the ready scene are all framebuffer- or
guest-confirmed. Everything below is first-hand from the 2026-09-01 bring-up
unless it says otherwise. What remains is **box-side acceptance** — deployment,
a browser pass through the SPA, the reset button and a cold restart — which the
coordinator is running; that is pending, not claimed.

This exhibit exists for a preservation reason, not a novelty one. ravynOS 0.6.1
(released **2025-10-25**) is the **last FreeBSD-based build of ravynOS**. Four days
later, on 2025-10-29, lead developer **Zoë Knox** (GitHub `mszoek`) opened
Discussion #529, *"It's decision time. Please read."*, and the project abandoned
the FreeBSD kernel base to restart on Apple's real Darwin/XNU kernel. **Every
FreeBSD-era release — v0.4.x through v0.6.1 — was subsequently deleted from the
GitHub releases page and from the SourceForge mirror**, and survives only on
volunteer mirrors. The current official artifact is a Darwin/XNU "demo VM"
(tag `demo-vm`, v0.7.1) that is console-only with **no GUI at all**, so the
Mac-like desktop this station shows exists *only* in the deleted line. The
station preserves a build that its own project has withdrawn.

## Identity and source

- Public ID / `stationDir` / `SH_STATION`: `ravynos`
- Display name: **ravynOS**
- Reserved slot / UDP port / VMID: `173` / `54173` / `173`
- Archetype: `apple-studio`; era year **2025** (`museum.year` 2025 as well)
- Tile UI kind: `desktop`. Pointer `abs` / `qemu-usb-tablet`. Audio on
  (`SH_AUDIO=on`). `resetMode: loadvm`, snapshot `golden`.
- OS: **ravynOS 0.6.1 "Hyperpop Hyena"**, amd64, released 2025-10-25.
  Base: **FreeBSD 15** — 0.5.0 moved the tree to FreeBSD 15-CURRENT and 0.6.0 to
  FreeBSD stable/15, so 0.6.1 is a FreeBSD-15 userland and kernel underneath.
  The kernel string read out of the running guest is
  `FreeBSD 15.0-ALPHA5 #0: Fri Oct 24 16:02:10 UTC 2025
  root@vixen:/usr/obj/usr/src/amd64.amd64/sys/RAVYN amd64` — the kernel config is
  literally named **RAVYN**, and it was built the day before release.
- Lineage: started as **airyx / airyxOS**; the `ravynsoft/ravynos` repository was
  created **2021-01-31**. Mascot: a raven named **Muninn**.
- License class: **free/open** — permissive BSD. The ISO tooling is BSD 3-Clause
  and the project requires clean-room BSD/MIT contributions, so nothing here is
  preservation-class or redistribution-encumbered. (We still do not commit the
  bits; the repo is public and the ISO is 728 MiB.)
- Project goal, in its own words: *"the finesse of macOS with the freedom of open
  source"* — **source-level** compatibility with macOS applications (not binary),
  Apple GUI metaphors (global menu bar, Dock) and the macOS folder layout
  (`/Applications`, `/Library`, `/System`, `/Users`, `/Volumes`) over a BSD. The
  Cocoa stack (AppKit, Foundation, CoreGraphics, Onyx2D, CoreText) is clean-room
  work descended from Cocotron/GNUstep-style implementations. The project calls
  itself a **pre-alpha developer preview** and this station does not oversell it.

### Media — acceptance criteria

| property | value |
|---|---|
| File | `ravynOS_0.6.1_amd64.iso` |
| Release / arch | ravynOS **0.6.1**, **amd64** |
| Bytes | **762 972 160** (728 MiB) |
| SHA-256 | **`e7a2b90e8d87c073857bce6f65ec5023542ec76d4f694b55f49af981c4ff9516`** |
| License class | free/open (BSD) |
| Intake staging | `/data/assets-staging/ravynos/` with `MANIFEST.sha256` |
| Builder output | `/data/gallery-guests/RavynOS/` (builder `outputDir: RavynOS`) |
| Runtime path | `/data/isos/ravynOS_0.6.1_amd64.iso` — what the launcher attaches |

That SHA-256 is **locally measured on labhost this session and it matches the
checksum that was published on the — now archived — GitHub release page**. The
agreement matters: it is the only way left to tell a mirror's copy from a
re-rolled one, because the authoritative release page no longer exists to check
against.

Sources, in the order to try them:

1. `http://ftp.nvg.ntnu.no/pub/mirrors2/mirrors.nomadlogic.org/www/releases/0.6.1/ravynOS_0.6.1_amd64.iso`
   — the NTNU mirror of the project's own nomadlogic mirror; **this is the copy
   that was fetched and hashed**.
2. `https://mirrors.nomadlogic.org/ravynOS/releases/0.6.1/ravynOS_0.6.1_amd64.iso`
   (200)
3. `https://mirror.clarkson.edu/ravynos/releases/0.6.1/ravynOS_0.6.1_amd64.iso`
   (200)

Dead, and expected to stay dead: the **GitHub release tag (404)** and the
**SourceForge mirror (404)**. Do not treat either as a fallback; they were
deleted deliberately.

## Install method — and why this station ships the live ISO

The station boots the **read-only live ISO**. That is not a shortcut taken
because a disk install was skipped: the disk install **was performed, it
completed successfully, and the resulting system does not work**. The live ISO is
also upstream's own distribution form, and it is the exact artifact the project
deleted — so booting it is both the working path and the more faithful one.

**Live boot, for reference.** Take the default boot-menu entry and log in at the
**LoginWindow** as **`liveuser` with no password**. That the account has no
password is stated in the upstream release notes, so it is public and safe to
record here. No other secret exists for this station; the registry's
`credentialsRef: guest/ravynos` stays the reference and **no password value is
ever written into a tracked file**. A "Boot ravynOS Safe Mode" entry exists in
the boot menu as a fallback.

### The disk install: completed, then stalled

`/bin/install.sh` ("Welcome to ravynOS Setup for Developers") is an interactive
shell script and it was driven non-interactively with four piped answers:

```
printf 'ada0\n1\ny\nn\n' | sudo /bin/install.sh
```

Target disk `ada0`, from `sysctl -n kern.disks`. `liveuser` has passwordless
sudo — `sudo -n id` returns uid=0 — so no credential is needed.

- **Trap: it must be run as bash.** `sudo /bin/install.sh` works. Forcing it
  through `sh` fails with `/bin/install.sh: [[: not found` and **silently skips
  the entire partitioning branch**; cpdup then fills the live RAM disk and the
  run dies with "No space left on device". The failure looks like a disk-space
  problem and is not.
- It laid down **GPT + a 256 MB EFI partition + 4 GB swap + a ZFS pool named
  `ravynOS`**, copied **1 382 801 565 bytes / 38 681 source items / 40 988
  copied** in **181.9 s**, set `zfs_enable`, `zfsd_enable` and `sshd_enable` to
  YES, and wrote the bootloader. It reports a user **`dev`** with password
  `temp`.
- **The installed system never reaches a desktop.** It boots UEFI off the disk
  fine, mounts `zfs:ravynOS/ROOT/default [rw]`, prints
  `pid 1 comm launchd: nosys 689` — and **stalls there permanently**. Two
  framebuffer captures 150 s apart were byte-identical, and `rc` never emits a
  single line.

Two hypotheses were tested and **refuted**:

- *Entropy starvation.* Adding `-object rng-random` + `-device virtio-rng-pci`
  changed nothing. (The device stayed in the shipped set anyway — upstream's own
  VM script ships one.)
- *rc.conf drift.* `diff /etc/rc.conf /mnt/etc/rc.conf` is exactly the three
  service lines the installer added, and nothing else.

The lead for whoever picks this up: **the installed
`/System/Library/LaunchDaemons` tree does not match the live one.** The live tree
carries `com.ravynos.ws.seatd.json` and `org.freebsd.ttyv0.json`; the installed
listing does not show them. That is consistent with `launchd` coming up with no
seat and no console job and never handing off to `rc`.

The copy itself was sound: the pool re-imported cleanly from the live ISO
afterwards — `zpool import -f -R /mnt ravynOS` showed the full
`/Applications /Library /System /Users /Volumes` layout. So the conclusion is
**pre-alpha breakage in ravynOS's own disk-install path, not a lab
misconfiguration**. If a future release fixes it and the station moves to an
installed disk, the `dev` credentials go to `guest/ravynos` outside Git and the
shipped default password is changed.

Every 0.6.x release note carries the same warning verbatim, and it is fair to
repeat: this is *"unstable pre-release… bugs — sometimes serious ones —
including application and desktop crashes and even kernel panics."*

## Device set

This is the tracked launcher, `streamhost/stations/ravynos/qemu-streamhost.sh`,
which is deployed **verbatim** and is the device-set ledger. QEMU **11.0.2**
(host `pve-qemu-kvm` 11.0.2-1).

```
qemu-system-x86_64 -name streamhost-ravynos \
  -enable-kvm -m 4096 -smp cores=4,sockets=1 \
  -machine pc-q35-11.0 -cpu host \
  -drive file=$D/ravynos-golden.qcow2,if=none,id=hd0,format=qcow2,cache=writeback \
  -drive if=pflash,unit=0,format=raw,readonly=on,file=/usr/share/pve-edk2-firmware/OVMF_CODE_4M.fd \
  -drive if=pflash,unit=1,format=qcow2,file=$D/OVMF_VARS.qcow2 \
  -device ide-hd,drive=hd0,bus=ide.0,bootindex=2 \
  -drive file=/data/isos/ravynOS_0.6.1_amd64.iso,media=cdrom,if=none,id=cd0,readonly=on \
  -device ide-cd,drive=cd0,bus=ide.1,bootindex=1 \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  -device intel-hda,id=hda -device hda-duplex,bus=hda.0,audiodev=snd0 \
  -device qemu-xhci,id=xhci \
    -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0 \
  -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 \
  -netdev user,id=n0,restrict=on -device virtio-net-pci,netdev=n0,id=net0 \
  -boot menu=off,strict=on
```

Every constraint below was established first-hand on labhost, not inferred.

- **UEFI is mandatory.** There is no BIOS/legacy boot path in this build: legacy
  BIOS boot dies at the FreeBSD `mountroot>` prompt. The OVMF pflash pair is a
  hard requirement.
- **The variable store must be a writable qcow2**, `OVMF_VARS.qcow2`, per
  station. **Raw** makes `savevm` refuse — it will not accept a writable device
  that cannot hold snapshots — and a **read-only** pflash hangs OVMF before it
  initialises the display. Never point unit 1 at the shared template.
- **The carrier disk is declared FIRST**, before the pflash pair. See
  *Golden / reset* below; the ordering is load-bearing, not cosmetic.
- **`pc-q35-11.0` is required.** i440fx with OVMF produces a black screen with a
  white rectangle and gets no further (upstream issue #433).
- **`-cpu host` / KVM.** **SSE4.2 is a hard requirement of the OS**, so a
  reduced CPU model is not an option here.
- 4096 MB / 4 cores.
- **`-vga std`, and there is no alternative.** ravynOS ships **no GPU driver at
  all**. Since 0.5.1 WindowServer renders **directly into the framebuffer that
  OVMF's EFI GOP hands it**. There is no OpenGL, no DRM/KMS, and no
  virtio-gpu/qxl path; there is also **no guest-side way to change resolution** —
  the canvas is fixed by OVMF at boot. **Canvas on this host: 1280×800.**
  Anything that wants a different canvas has to change what OVMF hands over, not
  anything inside the guest.
- **Input is USB only.** The 0.6.1 release notes say PS/2 or virtio input *"may
  cause input lag. Use USB devices."* — so `qemu-xhci` + `usb-kbd` +
  `usb-tablet`. Confirmed in the guest: `hkbd0: <QEMU QEMU USB Keyboard>` and
  `hms0: <QEMU QEMU USB Tablet> on hidbus1` /
  `hms0: 5 buttons and [XYW] coordinates ID=0`. Absolute pointing works in 0.6.x
  (upstream issue #501 restored it), and the shipped `ISO/settings/rc.conf`
  carries `hw.usb.usbhid.enable=1`, `usbhid_load="YES"` and
  `kld_list="cuse ig4 utouch ums asmc"` to make it so. Upstream itself calls the
  QEMU tablet *"the preferred mouse for Proxmox (KVM/QEMU) VMs"*.
- **Audio is real.** `intel-hda` + `hda-duplex` on the production
  `-audiodev dbus,…out.frequency=48000,out.channels=2,out.format=s16`. See
  *Audio* below.
- NIC: **`virtio-net-pci`** (FreeBSD 15's `vtnet(4)`) on `-netdev user,restrict=on`.
  `restrict=on` isolates the guest: an unsupervised exhibit must not be able to
  phone home, and ravynOS needs no network to reach its desktop. There is no
  browser in the guest anyway — the NIC is for the shell, not for a web plane.
- **No exec channel.** The 0.6.1 live image runs no sshd, so
  `operator.labctl.exec_kind` is `null` and `console` is `fb`. Drive the station
  through the framebuffer (`labctl shot` / pointer + keys).

## Audio

Present, enumerated and driveable — but the desktop itself is silent.

- Devices: `-device intel-hda,id=hda -device hda-duplex,bus=hda.0,audiodev=snd0`,
  with `-audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16`
  and `-display dbus,p2p=on,audiodev=snd0`.
- Verified in the guest. dmesg:
  `hdacc0: <Generic (0x1af40022) HDA CODEC>`,
  `hdaa0: Audio Function Group`,
  `pcm0: <Generic (0x1af40022) (Analog)>`. And
  `cat /dev/sndstat` reports
  `pcm0: <Generic (0x1af40022) (Analog)> (play/rec) default`.
- The registry sets `SH_AUDIO=on` (`stream.audio: true`, `SH_AUDIO_BITRATE`
  96000).
- **The honest limit:** the 0.6.1 desktop emits no sounds of its own — there is
  no audio server in this build. The hardware and driver are present and a
  visitor with a shell could write to `/dev/dsp`, but in normal use the exhibit
  is effectively silent. Do not file that as a streaming regression.

## Ready scene

The **clean logged-in desktop at 1280×800**: the global menu bar with the raven
glyph and the clock, the Zakim-bridge wallpaper drawn by `Dock.app`, and the Dock
(Terminal, Install, Trash). **No windows open.** This exact frame is also the
poster hero at `spa/public/posters/ravynos/desktop.webp`.

Reject any capture that shows the LoginWindow, a red *"Try Again"*, a half-typed
Username field, or a Terminal window left open by a driving run.

What the guest contains: **WindowServer** plus **SystemUIServer** (the
macOS-style global menu bar), **Dock.app** — which also draws the wallpaper and
shows running-application dots — and the wallpaper itself. Plus **Terminal.app
v0.9.2**, which the project itself describes as *"a very basic
proof-of-concept"*. `grabscr`, a screenshot tool, is in `/usr/bin`.

Be sober about what is *not* there, because a visitor will look for it:

- **Filer, the file manager, is commented out of the 0.6.x build and does not
  ship.** There is no way to browse files graphically.
- **The graphical installer likewise does not ship** — the Dock's "Install" icon
  leads to the shell installer described above.
- **There is no web browser.**
- Present and usable: `turbo`, `vim`, **`zsh` (the default shell)**, `curl`, and
  the FreeBSD userland.

The honest summary, and the one the exhibit copy should carry: **a convincing
shell of a Mac desktop over a BSD, not a usable Mac.** The value is that the
metaphor is complete enough to read as Aqua-descended at a glance — and that this
particular build no longer exists upstream.

Escape hatches, worth knowing before driving the guest: **Cmd-Shift-Q** quits
WindowServer, and **Alt-F2** gives a console login. Do **not** send Cmd-Shift-Q
to a live station: 0.6.x ships no Filer with which to restart WindowServer, so
the station is left at a console until the next reset.

### There is no idle-deterministic frame

The menu-bar **clock repaints once a minute** and 0.6.x offers no way to hide it,
so two captures of "the same" idle desktop can differ purely by clock glyphs.
Frames on this station must always be compared at a **fixed machine instant**:

```
stop ; loadvm golden ; stop ; screendump out.ppm ; cont
```

A tier-1 change-fraction settle on a live desktop is not a substitute.

## Golden / reset

`resetMode: loadvm`, snapshot `golden`. **Baked and restore-proven byte-exact.**

The sequence that proved it: `stop` → `screendump` baseline → `savevm golden` →
`query-snapshots` shows the tag → `cont` → dirty the framebuffer by opening
Terminal from the Dock → `screendump` dirty → `stop; loadvm golden; stop;
screendump restored; cont`. Baseline and restored hashed **identically**
(same SHA-256); the dirtied frame differed. Sampling at a fixed machine instant
is what makes the comparison exact — see above.

**Where the vmstate lives is load-bearing.** A live ISO is read-only and cannot
hold a vmstate, so this station carries an otherwise-unused **24 GB
`ravynos-golden.qcow2`** purely to hold the golden's RAM image. It is declared
**first** on the command line, before the OVMF pflash pair, because `savevm`
picks its vmstate device by walking BlockBackends in `-drive` order — with the
pflash first the RAM image tries to land inside the 528 KiB variable store
instead. Measured after the bake: `qemu-img snapshot -l` shows
`golden  579 MiB` on `ravynos-golden.qcow2` and `0 B` on `OVMF_VARS.qcow2`.
**Both files carry the tag and must be rolled back together** —
`SH_GOLDEN_DISKS` in `station.env.fixture` lists both, and the pair is atomic.
Re-verify that split after any `-drive` reorder.

The device set above is **part of the checkpoint**: `loadvm golden` requires the
same devices, and the OVMF pflash pair is a device. Swapping the NIC model,
dropping the HDA pair, or moving off `pc-q35-11.0` is a cold re-bake, not a
launcher edit.

**One caveat, stated honestly:** the restore proof was performed in the bring-up
sandbox with headless backends (`-display none`, `-audiodev none`). The shipped
golden is baked on the box through the tracked launcher, with the dbus display
and the dbus audiodev. The **guest-visible device set is identical either way**,
which is what `loadvm` matches on.

Helpers:

- Cold-boot arm: `scripts/coldboot/ravynos-bootrec-arm.sh`; the audit is
  `scripts/coldboot/ravynos-zero-input-prep.md`.
- Clone-only proof in this repo: **`scripts/lib/checkpoint-verify.sh ravynos`**
  (`scripts/lib/golden-verify.sh` is only a one-epoch compatibility shim that
  `exec`s it — do not cite the old name).
- A live recapture is `ssh lab 'checkpoint-guard recapture ravynos'` and nothing
  hand-rolled.

## Pointer and input — both PASS

- Pointer path: **absolute HID** — `--pointer abs` over `usb-tablet` on the xHCI
  controller. Registry `pointer.transport: abs`, `method: qemu-usb-tablet`,
  `absolute: true`, `device: usb-tablet`, `scale: 1.0`, `offset: [0,0]`. No
  RAM-write trick and no closed loop is needed here: unlike the era guests on
  this box, ravynOS has a real USB HID stack and takes absolute coordinates
  directly.
- Enumeration: `hms0: <QEMU QEMU USB Tablet> on hidbus1` /
  `hms0: 5 buttons and [XYW] coordinates ID=0`, and
  `hkbd0: <QEMU QEMU USB Keyboard>`.
- **Calibration proven on the framebuffer.** A commanded click at (640,267) in
  the 1280×800 canvas landed exactly inside the LoginWindow's Username field;
  clicks on the Log In button and on Dock icons all hit their targets. **No scale
  or offset correction is needed** — hence `scale 1.0`, `offset [0,0]`.
- **Keyboard proven by typing in Terminal.app**: `uname -a` returned the
  `FreeBSD 15.0-ALPHA5 … sys/RAVYN amd64` string quoted at the top of this file,
  and `sysctl hw.model` returned the host CPU.
- **Input works immediately after `loadvm golden`** — proven by opening Terminal
  and typing straight after a restore. No re-arming, no first-click warm-up.
- **Do not "fix" input by adding PS/2 or virtio-input devices.** Upstream names
  both as lag sources, and either one is a device-set change that invalidates the
  golden.

### Two harness traps — both cost real time

1. **Absolute injection must use QMP `input-send-event`** with `abs` axes scaled
   to `0..32767`. Do **not** use `labqmp.mouse_relative_from_origin`
   (`scripts/lib/labqmp.py`): its HMP `mouse_move` stepping drifts, and on this
   station it put a click roughly **300 px off target**.
2. **`labqmp`'s `button` action takes a BITMASK** — `button 1` to press, then
   `button 0` to release. `button left` silently does nothing at all.

### The LoginWindow focus trap

A cold boot reaches the graphical **LoginWindow at ~95–110 s** and then waits for
a human forever: no timeout, no autologin, no guest agent. Driving it takes four
steps, in this order, in 1280×800 coordinates:

1. **Click the login panel body (`640,160`) to ACTIVATE the window.** Mandatory
   and non-obvious. Clicking straight into the Username field does nothing: the
   field never takes focus, the typed text is **silently discarded**, and the
   panel then shows a red *"Try Again"* as though the credentials were rejected.
   Do not re-diagnose this as a bad password.
2. **Click the Username field (`640,267`), then click it AGAIN.** One click after
   the activation click is not enough.
3. **Type `liveuser`.** No password.
4. **Click Log In (`640,396`).** The desktop appears **~20–25 s** later.

**Cold boot is therefore not zero-input, and cannot be made zero-input in
0.6.1** — the live image's configuration lives in a read-only uzip and there is
no Settings app to change it from the desktop. **The golden IS the zero-input
path for this station**; a cold boot is a supervised operation. Full audit:
`scripts/coldboot/ravynos-zero-input-prep.md`.

## Open items

- **The installed-disk stall has no root cause yet.** `launchd` stops at
  `nosys 689` and `rc` never runs; the missing `com.ravynos.ws.seatd.json` /
  `org.freebsd.ttyv0.json` in the installed `/System/Library/LaunchDaemons` is
  the lead. Not a blocker for the station, which ships the live ISO.
- **Boot video: none, recommended.** A published clip's last frame must match the
  golden's first live frame, and that is impossible here — a cold boot ends at
  the LoginWindow and the golden begins at the desktop, so the seam would be a
  full-screen jump. `spa.bootVideo` is deliberately unset. Recording the driven
  login sequence would be an honest clip of a *supervised operation*, not a cold
  boot; that is the registry owner's call.
- **Box-side acceptance is pending** (coordinator): deployment, a browser pass
  through the SPA, the reset button, and a cold restart of the station service.
  Nothing here claims those have passed.
- **Canvas is not ours to choose.** 1280×800 is what OVMF hands the guest on this
  host and there is no in-guest control. If the tile ever wants a different
  aspect, the lever is OVMF, and it has not been investigated.
- **No GPU acceleration, ever, in this build** — WindowServer paints the EFI GOP
  framebuffer. Expect software-rate redraw; do not chase it as a regression.
- **Only one display is supported**, and there are **no global display
  coordinates** (upstream).
- **USB 3.0 is unsupported** (upstream). `qemu-xhci` works for HID; do not
  attach USB 3 mass storage expecting it to enumerate.
- **The upstream wiki's Virtualization page still warns of "no graphics under
  virtual machines".** That warning is **stale** — the 0.6.x release notes
  supersede it and this station contradicts it directly. Recorded so nobody
  re-derives the dead end from the wiki.
- **The media has no authoritative source any more.** All three working URLs are
  volunteer mirrors. The archived checksum agreement is the only integrity anchor
  left, which is exactly why the hash above is recorded twice over.

## Rollback

- The pristine, never-booted media is the staged ISO at
  `/data/assets-staging/ravynos/ravynOS_0.6.1_amd64.iso`, hash-checked against
  `MANIFEST.sha256`. The runtime copy at `/data/isos/ravynOS_0.6.1_amd64.iso` and
  the builder output under `/data/gallery-guests/RavynOS/` can both be rebuilt
  from it; if they are lost, refetch from the mirror list above and re-verify the
  SHA-256 before use.
- Golden rollback is the standard shape, with one station-specific rule: stop
  only `streamhost@ravynos`, stop its QEMU by the station pidfile, restore
  **both** `ravynos-golden.qcow2` and `OVMF_VARS.qcow2` — they carry the same tag
  and are one unit — then restart only this station's service. Never retire a
  golden before its replacement is restore-proven; checkpoint, binary and device
  set are one combination.
- The per-station `OVMF_VARS.qcow2` is *not* freely disposable now that a golden
  exists: it holds part of the checkpoint. Recreating it from
  `/usr/share/pve-edk2-firmware/OVMF_VARS_4M.fd` is a device-state change and
  needs a re-bake, not a restart.
