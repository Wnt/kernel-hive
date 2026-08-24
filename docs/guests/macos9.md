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

**`resetMode=loadvm` DOES NOT WORK ON THIS STATION.** Every restore of a
checkpoint wedges the guest: the PC freezes at one address (repeated
`info registers` samples identical), the framebuffer goes byte-identical, the
guest's own menubar clock stops, and QEMU keeps burning ~100 % of a core with
`DSISR 0x40000000` on a `DAR` a few MB ABOVE the top of the 512 MB of guest
RAM (`0x209b75e0`, `0x20430000`, `0x20…` every time). Restoring paints the
fixture desktop perfectly first, which is what makes it so convincing.

Measured 2026-08-24, five restores, everything varied that could be varied:

| what was varied | result |
|---|---|
| checkpoint captured RUNNING (checkpoint-guard) | wedges |
| checkpoint captured STOPPED (hand-rolled test label) | wedges |
| restore in a FRESH process (`-loadvm X -S` + `cont`) | wedges |
| restore MID-FLIGHT into a running QEMU | wedges |
| `-display dbus,p2p=on` vs `-display none` | wedges either way |
| **cold boot, no checkpoint** | **healthy — 3/3 boots, 7 min+ each, input works** |

**The one "successful" restore was a measurement artefact.** A `loadvm`
issued immediately after a `savevm` in the SAME process survived 5 minutes —
but that restores state identical to what is already live, so nothing
actually changes. It is a no-op, not a restore. Never accept it as proof.

**A restore proof MUST watch the guest's own menubar clock advance across at
least two ticks.** `checkpoint-guard`'s framebuffer proof PASSES on a dead
checkpoint here (it reported SSIM 0.996 and "guest running" on one that was
already wedged), because a wedged guest still holds a perfect-looking frame
and QEMU still reports `running`. A single good frame proves nothing.

Consequences until this is fixed: the launcher's `-loadvm golden -S` path
produces a DEAD station on every start, `labctl reset` cannot work, and the
checkpoint in the qcow2 is retained only as evidence. **Bring this station up
by cold booting** (~7 min to the desktop under TCG); idle auto-pause still
works normally, and QMP `stop`/`cont` on a cold-booted guest is proven safe —
a 15-minute pause resumed cleanly and the guest reacted to input afterwards.

The open lead is that `DAR` sitting just past the end of RAM: something
mapped at or after the RAM top is not being carried in the vmstate — the
mac99 VRAM / `qemu_vga.ndrv` framebuffer aperture and the PPC BAT/segment
registers are the first places to look.

**Warm reset is BROKEN too**: `system_reset` hangs the machine at the
exception vector (NIP=0x4, LR in OpenBIOS). Never use it.

Reading the registers: `MSR 0x00001000` is a NORMAL transient here — it
appears repeatedly in a healthy guest inside exception handlers, as does
`NIP 0x00f24030`. The wedge signature is the **stuck NIP** across repeated
samples plus a frozen clock, not the MSR value.

## Driving the guest over QMP

HMP `mouse_move` does NOT reach this guest — only explicit
`input-send-event` `rel`/`btn`/`key` events do.

**Never send a pointer delta with |value| > 127.** The USB HID report field
is a signed byte; an out-of-range delta wedges the guest's mouse — motion and
clicks stop being consumed entirely while **the keyboard keeps working**, so
it looks like a half-dead guest. Recovery is one button press/release pair
(`resync`); no reboot needed. Travel in chunks of 8 units.

Pointer scale on the cold disk measures **0.177 px per delta unit**, dead
linear (400 units → 71 px, 300 units → 53 px) — the "Very Slow" tracking
figure, confirmed persisted in the on-disk prefs, not just in a checkpoint.

Useful keys (explicit press/release pairs, never overlapping HMP `sendkey`):
`meta_l-w` close window, `meta_l-n` NEW FOLDER (not a new window),
`shift_l-meta_l-backspace` Empty Trash, `power` raises the shutdown dialog
with **Shut Down** as the default button, `ret` confirms it.

## Verification record (framebuffer, 2026-08-24)

- CD desktop, Drive Setup, installer, installed-disk desktop: screendumped at
  every step (bring-up shots under `/data/vms/sandbox/ppc-macos9/rig/shots/`).
- usb-tablet: abs events move nothing → no absolute path exists. usb-mouse
  relative motion, click, drag (rubber-band), menu press-drag-release: PASS.
- Post-restore: pointer motion + click (icon selection highlight) + Cmd-O
  chord (window opened): PASS on the framebuffer after `loadvm golden`.
  **This proof is void** — a restored checkpoint is wedged (see Golden /
  reset); the proof completed before the freeze was visible.
- Reset: `loadvm golden` wiped a dirtied screen back to the fixture.
- Browser-path (streamhost/WebRTC) input: UNVERIFIED — left for the
  operator's eyeball, like macos753.

## Known quirks / open items

- **USB input can wedge**: once during bring-up the guest stopped consuming
  ALL input (motion, buttons, keys) while the machine kept running. Prime
  suspect: overlapping HMP `sendkey` releases (the playbook §5.1 async
  hold-time trap); after switching to explicit `input-send-event`
  press/release pairs it did not recur through the whole curation, bake and
  proof sequence. The cause is now known and it is NOT a guest bug: a
  pointer delta with |value| > 127 overflows the USB HID report byte and
  wedges the mouse while the keyboard keeps working. One button
  press/release pair clears it — see "Driving the guest over QMP".
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
