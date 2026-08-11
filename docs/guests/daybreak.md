# Xerox 6085 "Daybreak" / ViewPoint 2.0.5 — gallery station notes (udp/54139)

**Guest:** a captured **Debian 12 x86_64 bare-X kiosk** running **Dwarf/Draco**
(a Java Mesa-architecture emulator) emulating a real **Xerox 6085
"Daybreak"/Dove** workstation booting **ViewPoint 2.0.5** off a Pilot rigid-disk
image. A **kiosk** — streamhost captures the Linux framebuffer
exactly like every other station. See **`streamhost/docs/BRIDGE.md`**.

**Shared base:** `/data/vms/bridge/bridge-base.qcow2` (frozen). Java is **not**
in the base; `openjdk-17-jre` is installed **into this station's overlay**.
**Build script (station):** `scripts/build-guests/tiles/daybreak.sh` — thin overlay
+ JRE + upstream Dwarf/disk fetch with verified sha256 + a US Dwarf keymap + the
kiosk `launch.sh`, then a documented manual logon and checkpoint capture.
**Station dir (host):** `/data/vms/streamhost/tiles/daybreak/`.
**Registry entry:** `registry/tiles/daybreak.json` (slot 139, udp 54139,
VMID 239, ssh hostfwd 127.0.0.1:5849).

This is **not** the GlobalView-on-Windows-3.1 route that an earlier feasibility
study recommended. There is no second emulation layer and no Windows host: this
is the 6085 itself, emulated directly.

## Media and licence

Nothing is committed. Both files are fetched at build time from upstream and
their sha256 verified; see `docs/lab/ASSETS-MANIFEST.md`.

| file | sha256 | size | class |
|---|---|---|---|
| `dist.zip` (github.com/devhawala/dwarf) | `67f84b77…cf75` | 509 198 B | **BSD-3-Clause**, redistributable |
| `disks-6085/vp2.0.5.zdisk` | `02bdb53b…f872` | 4 657 062 B | preservation-source (Xerox) |

The **container is BSD-3, the contents are not.** `vp2.0.5.zdisk` is a Pilot
disk carrying Xerox-copyright ViewPoint software; it is preservation-class
material streamed as pixels to a passkey-private gallery, never redistributed
and never given a download affordance.

**The disk's "Software Options" are unlocked but bound to processor id
`10-00-FE-31-AB-21`.** Changing `processorId` in the Draco properties re-locks
every ViewPoint application. Do not touch it.

## The scene

The checkpoint is the **logged-in ViewPoint desktop**: the 50 %-dither grey desk,
`91198 Free Disk Pages` in the message area, a `Help` button top right and a
single `Directory` icon bottom right. Logon happens **once**, at capture time.

That is deliberate. A cold Draco lands on the **logged-off screen** — a small
bouncing keyboard graphic on black, with `8000` in the emulator's status bar.
MP 8000 is Pilot's normal run state, not a hang; the screen means "press a key
to log on", and the key is the Xerox **NEXT**, which Dwarf maps to `Ctrl+N`. A
visitor would never guess that, so they never see it.

There is no Clearinghouse and no Dodo XNS server, so ViewPoint cannot find a
home File Service. That is the documented standalone path, not a fault: any
user name plus any password, then ViewPoint offers *"Do you want a new Desktop
created for you?"* and builds a **temporary desktop**. The capture answers YES.
Credentials used at capture time: `guest` / `guest`, domain `dev`, organisation
`hawala` (the disk's own defaults). `credentialsRef: guest/daybreak`.

## Display

`largeScreen = true` → the 19" 6085 screen, **1152×861, one bit deep**. Dwarf
wraps it in a Swing frame **1152×913** (toolbar, Mesa screen, status line). The
kiosk therefore builds a **custom 1152×914 X mode** with `xrandr --newmode`, so
the frame fills the captured framebuffer with no grey gutter. A stock mode does
not exist at that size; 1280×1024 leaves a dead margin on two sides.

## Input — two things that are not obvious, and one that is

**1. Focus, twice over.** No window manager runs in the kiosk, so:

- nothing calls `XSetInputFocus` and the Dwarf frame never becomes the X focus
  window;
- even once it is focused, Dwarf's display panel does not hold the *Swing
  component* focus, so its `KeyListener` never fires.

`launch.sh` fixes both: `xdotool windowfocus` on the frame, then one synthetic
`xdotool click 1` inside the Mesa screen. **Without both, every keystroke is
silently dropped** — and that silence is exactly what was first misread as an
MP 8000 hang. The cheap oracle is `java -jar dwarf.jar … -logkeypressed`: if it
logs nothing, the problem is focus, not Pilot.

**2. Dwell, and it is long.** Dwarf is Java/Swing and coalesces input rather
than sampling once per emulated frame, so the playbook's two-frame rule does not
apply. Measured on this station: a zero-length `send-key` chord lands **nothing**;
**400 ms hold with a 150 ms gap** landed 5/5 typed characters and actuated
`Ctrl+N` first try. Mouse clicks need the same ~400 ms press→release dwell — a
zero-dwell synthetic click does nothing in an option sheet. Shipped as
`SH_KEY_MIN_HOLD_MS=400` / `SH_KEY_MIN_GAP_MS=150`.

**2b. The SHIFT is a key, and it needs its own dwell.** A modifier batched into
the *same* synthetic input event as the key it modifies is applied
inconsistently: in one sweep `Shift`+`1` → `!` and `Shift`+`[` → `{` came out
right while `Shift`+`a` → `a` and `Shift`+`;` → `;` silently lost the shift.
Hold the modifier as a separate, earlier press —
`shift↓ · 350 ms · key↓ · 400 ms · key↑ · 250 ms · shift↑` — and every case
works, including the literal colon a ViewPoint XNS three-part name needs
(`Shift`+`;` → `:`, verified against a plain `;` typed beside it). The UI's
shift latch already does exactly this, which is why the on-screen keyboard is
the reliable route and a hand-rolled QMP chord is not.

The lead does **not** need to be long here — 150 ms, 250 ms and 350 ms all
produced `:A`, so `SH_KEY_MIN_GAP_MS=150` is sufficient and is what ships. What
fails is a lead of *zero*. (The Star under Darkstar is different: 200 ms failed
there and 350 ms worked. Same rule, different number — measure per machine.)

**3. The keymap.** Dwarf ships **only** `kbd_linux_de_DE.map`, and when a keymap
file is loaded **there are no defaults** — every key absent from it is dead. The
build writes `keyboard-maps/kbd_linux_en_US.map`, a US re-seat of the shipped
German map with the Level-V block unchanged.

### The Xerox Level-V keys

| Level-V key | Dwarf binding | Level-V key | Dwarf binding |
|---|---|---|---|
| NEXT | `Ctrl+N` | FIND | `Ctrl+F` |
| OPEN | `Ctrl+O` | UNDO | `Ctrl+U` |
| PROPERTIES | `Ctrl+P` | HELP | `Ctrl+H` |
| MOVE | `Ctrl+M` | STOP | `Esc` |
| COPY | `Ctrl+C` | DELETE | `Delete` |
| SAME | `Ctrl+S` | | |
| AGAIN | `Ctrl+A` | | |

The UI exposes these through the shared **Level-V keyboard family**
(`spa/src/ui/keyboard/keyboardProfiles.ts`), which is a per-machine keycode map:
the same logical buttons and labels are bound to `Ctrl+letter` here and to plain
PC function keys on a Darkstar-driven Star. The text-property block (F2 Center,
F3 Bold, F4 Italic, F5 Case, F6 Strikeout, F7 Underline, F8 SuperSub, F9
Smaller, F10 Margins, F11 Font) is in the profile's extra rows.

Pointer: **absolute** `usb-tablet`. The 6085 mouse is two-button (SELECT and
ADJUST) and Dwarf takes host left/right directly.

## Cold-boot route (framebuffer-verified, 2026-08-09)

| Step | Action | Framebuffer result |
|---|---|---|
| 1 | kiosk starts | logged-off bouncing keyboard on black, status bar `8000`, ~90 s |
| 2 | `Ctrl+N` (400 ms hold) after the launcher's focus + click | **Logon Option Sheet**, message area *"Please type your password and then press &lt;NEXT&gt;"* |
| 3 | type `guest` in Name, `guest` in Password | both fields fill, 5/5 characters |
| 4 | click `Start` (400 ms dwell) | *"Cannot find your home File Service because the Clearinghouse is down"* → *"Do you want a new Desktop created for you?"* YES |
| 5 | click `Start` again | **ViewPoint desktop**, ~45 s |
| 6 | `savevm golden` / `loadvm golden` | restores the desktop bit-for-bit |

## Cost, and the soak

- JVM RSS at the desktop: **226–229 MB**, flat. QEMU RSS **~1.65 GB** with
  `-m 1536`.
- CPU at the idle desktop: the JVM takes **~9–15 %** of one core inside the
  guest; the whole station — QEMU plus the streamhost encoder — sits at **~18 %**
  of one core while streaming. (The feasibility study's "3.5 % of a core" was
  measured under bare Xvfb with no capture; expect this figure instead.)
- Checkpoint VM state: **1.42 GiB**; overlay ~2.9 GB.
- **Soak — the study's one unexplained JVM exit did not recur.** Two windows,
  ~71 minutes of observed JVM liveness in total: 02:02→02:39 on the prototype
  before the capture, then 02:50→03:25 under the production daemon while
  streaming — **35 one-minute samples, 0 of them non-active**, JVM RSS bounded
  at **225 064–228 564 kB** with no upward drift. Across that window the JVM
  also survived the YES/START moment the original crash was seen at, the checkpoint
  capture, four `loadvm` restores, the Directory open and a shifted-punctuation
  sweep. Watch for it anyway: one unreproduced crash is not the same as no
  crash.

## Shutting down

**Never shut the guest down from inside ViewPoint.** The Dwarf disks readme is
explicit that an in-guest halt can leave the Pilot disk unusable. The only safe
stop is the emulator's own Stop button — and a `loadvm golden` kiosk sidesteps
the question entirely, because the station is always restored, never shut down.
`oldDeltasToKeep` is set to 1: Dwarf writes disk changes as delta files on a
clean stop, and a checkpoint-reset station discards them anyway.

## Rollback

The station is a thin overlay: `systemctl stop streamhost@daybreak`, then restore
`overlay.qcow2` (the checkpoint lives **inside** it — never `rm` and recreate it).
Rebuilding from scratch is `scripts/build-guests/tiles/daybreak.sh --force`
followed by the manual logon and capture in §"Cold-boot route".
