# macos9 — Mac OS 9.2.2 (Power Mac G4 "mac99")

Status: **production**, slot 150 / UDP 54150, LISTED. The lab's FIRST PowerPC
guest. Golden re-baked cold 2026-08-24 on the tb_env-patched fork binary and
captured by `checkpoint-guard`; restore proven by the strict protocol (fresh
process, the guest's own menubar clock across two ticks, pointer consumed —
see Golden / reset for why nothing weaker counts).

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

**Checkpoint restore REQUIRES the fork's `cpu/tb_env` vmstate patch**
(github.com/Wnt/qemu `kernel-hive` commit `196124d`, 2026-08-24). Stock QEMU
never migrates the softmmu timebase state (`tb_env`: `tb_offset`,
`decr_next`), so a checkpoint restored in a fresh process resumed with
`tb_offset = 0` — the guest-visible TB jumped ~30 s AHEAD of the guest's own
records (Mac OS 9's nanokernel zeroes the TB during boot, leaving
`tb_offset ≈ -30 s`) and the nanokernel wedged permanently in its
interrupts-off TB-repair loop. Root-caused 2026-08-24 with `-trace
ppc_tb_store`: post-restore the guest reran `mttbl 0` / `mttbu` / `mttbl`
~700 times a second, its target racing ahead of the TB it kept rewriting
(target upper word 0x2 → 0x5 in 40 s), spinning at `NIP 0xf23xxx` (inside
the nanokernel — the "Starting timeslicing" string sits in that region) with
`MSR 0x1000` (EE=0, real mode) and the DECR wrapping unserviced. The patch
carries `tb_offset`/`atb_offset`/`vtb_offset`/`decr_next` in a new
`cpu/tb_env` cpu-vmstate subsection and re-arms the decrementer on load.

What the 2026-08-24 investigation established on the way (all measured, do
not re-litigate):

- Wedges identically: captured running or stopped; restored fresh-process or
  mid-flight; `-display dbus,p2p=on` or `-display none`; `-cpu g4` or
  `-cpu g3` (AltiVec ruled out). Cold boot always healthy.
- The dumped CPU state (`info registers`, incl. `SDR1`) restores
  byte-faithful across a fresh-process `loadvm` — only the TB moves. The
  much-noticed `DAR 0x209b75e0 / DSISR 0x40000000` "few MB above RAM top"
  was a STALE leftover from a long-handled DSI, present in healthy dumps
  too; `VRSAVE 0x80000000` was equally a red herring.
- A `loadvm` issued right after `savevm` in the SAME process is a no-op
  (state identical to what is live, `tb_env` included) and proves nothing.
- The golden captured by a pre-patch binary predates the subsection and
  wedges under any binary. After ANY binary change: re-bake cold, re-prove.

**A restore proof MUST watch the guest's own menubar clock advance across at
least two ticks (minutes), in a FRESH QEMU process, and then see the guest
consume pointer input.** `checkpoint-guard`'s framebuffer proof PASSES on a
dead checkpoint here (it reported SSIM 0.996 and "guest running" on one that
was already wedged), because a wedged guest still holds a perfect-looking
frame and QEMU still reports `running`. A single good frame proves nothing.

**Warm reset is BROKEN**: `system_reset` hangs the machine at the exception
vector (NIP=0x4, LR in OpenBIOS). Never use it — reset is `loadvm golden`,
cold boot is a fresh QEMU process.

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
- Post-restore (tb_env-patched binary, 2026-08-24): fresh QEMU process,
  `-loadvm` + `cont`; `info registers` byte-identical across the restore
  (TB included, only the lwarx reservation differs); the guest's menubar
  clock advanced across two ticks (70 s apart, twice); a 400,300-unit rel
  move landed as a 71x53 px cursor move — exactly the 0.177 gain. PASS.
  (The earlier pre-patch "PASS" completed before the freeze was visible and
  was void — the strict protocol exists because of it.)
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
