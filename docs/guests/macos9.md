# macos9 — Mac OS 9.2.2 (Power Mac G4 "mac99")

Status: **production**, slot 150 / UDP 54150, LISTED. The lab's FIRST PowerPC
guest. Golden captured by `checkpoint-guard` 2026-08-24 (first capture,
restore-proven on the framebuffer, SSIM 0.996), pointer/click/keyboard
re-proven on the framebuffer after a `loadvm golden` restore.

## Identity and source

- Public ID / station dir: `macos9`; slot `150`, UDP `54150` (inside the
  public relay range 54080–54200)
- Media: `macos-922-uni.zip` → `macos-922-uni.iso`, the Macintosh Garden
  "Mac OS 9.2.2 Universal" bootable install CD (US English). Hashes, sizes and
  provenance in [`docs/lab/ASSETS-MANIFEST.md`](../lab/ASSETS-MANIFEST.md);
  immutable intake copy at `/data/assets-staging/macos9/` with
  `MANIFEST.sha256`. Never committed.
- **No ROM is needed** — the machine boots through OpenBIOS. This is the big
  advantage over the 68k Macs (macos753/aux need a dumped Quadra 800 ROM).

## Device set (pinned; the launcher is the ledger)

`streamhost/stations/macos9/qemu-streamhost.sh` (verbatim, byte-identical on
the box):

- **Binary**: `/opt/qemu-ppc/bin/qemu-system-ppc` — standalone build of the
  kernel-hive QEMU fork (11.0.2 + fast-poll); pve-qemu ships no ppc target.
  Configure line in the launcher header. **ninja installs no firmware**: copy
  `pc-bios/{openbios-ppc,vgabios-stdvga.bin,qemu_vga.ndrv}` to
  `/opt/qemu-ppc/share/qemu/` or the machine will not start / Mac OS will not
  drive the display.
- **Machine**: `-M mac99,via=pmu -cpu g4 -m 512`, TCG only (ppc on x86).
  **`via=pmu` is mandatory** — the default `via=cuda` breaks USB input.
- **Input**: the via=pmu machine instantiates its OWN USB keyboard and mouse
  behind a USB hub. **Do not add `-device usb-kbd`/`-device usb-mouse`**: a
  second HID pair splits QEMU's input routing across two mice and clicks go
  nowhere (cost an hour of the bring-up). Mac OS 9 has **no usb-tablet
  driver** — absolute events were proven inert on the framebuffer — so the
  pointer is relative (`dbus-rel`).
- **Display**: `-g 1024x768x32 -display dbus,p2p=on`. Mac OS drives the
  qemu_vga ndrv and offers a full resolution list in Monitors; the golden is
  baked at 1024x768 millions of colors.
- **Disk**: single IDE qcow2 `macos9-golden.qcow2` (4 GB virtual, one Mac OS
  volume via Drive Setup's default initialize), carries the internal `golden`
  snapshot.
- **NO NIC** (`-nic none`, which suppresses the default user-mode sungem):
  operator scope for this add was an ordinary station — no retronet, no
  networking. TCP/IP and AppleTalk control panels were never configured.
- **No audio**: QEMU's mac99 has no sound device (the community "screamer"
  patch is not in the fork). Deliberately out of scope.

## Install recipe (as built, no automated builder)

The CD is itself a live Mac OS 9.2.2 system with the full Apple installer:

1. Boot the CD (`-boot d`) → Finder desktop in ~3 min under TCG.
2. Utilities → Drive Setup → select `<not initialized>` ATA 0/0/0 →
   Initialize (default "1 Mac OS" partitioning; the Custom Setup type popup
   does not track selection under the emulated mouse, and HFS standard is
   fine at 4 GB).
3. Run "Mac OS Install" → Welcome → Select Destination → Continue past
   Before-You-Install → Agree the license → Start. ~9 min copy, no input.
4. Quit, Special → Shut Down (or the **Power key**, which raises the
   Restart/Sleep/Cancel/Shut Down dialog with Shut Down as the default —
   the most reliable scripted path). via=pmu powers the machine off and QEMU
   exits.
5. Boot the disk (no CD). First boot opens the **Mac OS Setup Assistant**:
   Cmd-Q, confirm Quit — it does not return on later boots.

## Fixture curation (what the golden holds)

- **Energy Saver → Never sleep** (a slept guest is a black exhibit).
- **Mouse tracking → Very Slow** — the only NON-accelerated setting, measured
  **dead linear at exactly 0.18 px per delta unit** (600 units → 108 px,
  identical at every send chunk size 1..32) → `SH_CURSOR_SCALE=5.5556`.
  Double-click speed slowest so a click pair survives the stream.
- **Monitors → 1024x768, millions of colors.**
- Disk renamed **Macintosh HD**; all Finder windows closed, nothing selected,
  cursor parked dead-centre (512,384 = `SH_REL_HOME_TO`).
- Scene: platinum desktop, purple stamped-Finder backdrop, Macintosh HD
  top-right, era aliases down the right edge, Trash bottom-right, Control
  Strip along the bottom.

## Golden / reset

`resetMode=loadvm`, snapshot `golden`, captured with
`checkpoint-guard recapture macos9` (never hand-rolled savevm/delvm). The
launcher probes `qemu-img snapshot -l | grep -qw golden` and boots
`-loadvm golden -S` — paused until the first visitor. Idle auto-pause 60 s.
First-capture byte backup kept at
`macos9-golden.qcow2.cpg-bak-20260824T173938Z` until the operator is happy
(`checkpoint-guard prune macos9`).

**Warm reset is BROKEN on -M mac99**: `system_reset` hangs the machine at the
exception vector (NIP=0x4, LR in OpenBIOS). Never use it — reset is `loadvm`,
cold boot is a fresh QEMU process.

## Verification record (framebuffer, 2026-08-24)

- CD desktop, Drive Setup, installer, installed-disk desktop: screendumped at
  every step (bring-up shots under `/data/vms/sandbox/ppc-macos9/rig/shots/`).
- usb-tablet: abs events move nothing → no absolute path exists. usb-mouse
  relative motion, click, drag (rubber-band), menu press-drag-release: PASS.
- Post-restore: pointer motion + click (icon selection highlight) + Cmd-O
  chord (window opened): PASS on the framebuffer after `loadvm golden`.
- Reset: `loadvm golden` wiped a dirtied screen back to the fixture.
- Browser-path (streamhost/WebRTC) input: UNVERIFIED — left for the
  operator's eyeball, like macos753.

## Known quirks / open items

- **USB input can wedge**: once during bring-up the guest stopped consuming
  ALL input (motion, buttons, keys) while the machine kept running. Prime
  suspect: overlapping HMP `sendkey` releases (the playbook §5.1 async
  hold-time trap); after switching to explicit `input-send-event`
  press/release pairs it did not recur through the whole curation, bake and
  proof sequence. If it recurs in production, `loadvm golden` (reset button)
  is the recovery; watch for it at the operator eyeball.
- Menus: fine-grained (≤4-unit) relative motion is eaten while the Menu
  Manager tracks a held button; drags through menus need ≥8-unit chunks.
  Sticky menus time out after ~15 s.
- The Custom Setup / resolution-list popups needed a second click; Drive
  Setup's type popup never tracked — HFS standard was accepted instead.
- `fixgoto` (closed-loop cursor goto used during bring-up) undershoots near
  the right screen edge; dead-reckon with the 0.18 gain from a known point
  instead.

## Rebuild

No automated builder (`build.rows` is empty, the tru64 precedent). To rebuild
by hand: build `/opt/qemu-ppc` (launcher header), stage the media
(ASSETS-MANIFEST row), then follow the install recipe above; the bring-up
driver scripts (`drv.py`, `fixgoto.py`, `gain.py`) live in the
`ppc-macos9` sandbox and are trivially recreated from this doc.

## Rollback

Pre-golden byte backup in the station dir (see above); the launcher +
checkpoint are an atomic pair — any device-set change means a cold re-bake
(chokanji/macos753 pattern). `credentialsRef: guest/macos9` — no login
exists; Multiple Users was never enabled.
