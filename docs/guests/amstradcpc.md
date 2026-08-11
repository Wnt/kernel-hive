# Amstrad CPC 6128 + Locomotive BASIC — gallery station notes (:8119)

**Guest:** a captured **Debian 12 x86_64 kiosk** running **Caprice32 (`cap32`)**
in a scale-3 SDL/X11 window, emulating an **Amstrad CPC 6128** that boots
**Locomotive BASIC 1.1**
to the classic **yellow-on-blue `Ready`** prompt. This is a **kiosk**
— streamhost captures the Linux framebuffer + AC97 audio (the CPC
**AY-3-8912** PSG routed through ALSA) exactly like every other station. See
**`streamhost/docs/BRIDGE.md`** for the reusable bridge pattern and
**`docs/guests/c64.md`** for the reference (C64) recipe this station forks.

**Shared base:** `/data/vms/bridge/bridge-base.qcow2` (read-only backing; built by
`scripts/build-guests/lib/bridge-base.sh`). Ships VICE(x64sc)+hatari+LinApple+**cap32**
+fs-uae + the bare-X kiosk. cap32 is built from source (github ColinPitrat) in the
base, so this station needs NO base rebuild.
**Build script (station):** `scripts/build-guests/tiles/amstradcpc.sh` (thin overlay +
kiosk `launch.sh` + framebuffer checks + keyboard proof + checkpoint cold-restore).
**Station dir (host):** `/data/vms/streamhost/tiles/amstradcpc/` — `overlay.qcow2`
(thin, on the base; holds the INTERNAL `golden` snapshot), `qemu-streamhost.sh`,
`tile.env`.

## License / provenance
- **Caprice32 (`cap32`)** — GPLv2 emulator.
- **Amstrad CPC ROMs** (Locomotive BASIC + firmware, ~48 KB) — **redistributable
  by Amstrad's granted permission** (Cliff Lawson, on behalf of Amstrad/Sky).
  **Keep the UNALTERED Amstrad copyright string** on screen to stay within the
  permission. The ROM set ships bundled with cap32 in the bridge seed.
- No proprietary media beyond the bundled ROMs is required — the machine boots
  straight to BASIC with no disk.

## Curated metadata (for the UI placard)
- **Year:** CPC 6128 = **1985**.
- **Lineage:** Amstrad's British all-in-one home micro (Zilog **Z80A** @ 4 MHz,
  **128 KB** RAM, built-in 3-inch disk drive, its own colour/green monitor). Boots
  to **Locomotive BASIC 1.1** — the iconic yellow-on-blue `Ready` prompt.
- **One line:** *"The British 8-bit all-in-one — an integrated Z80 micro with
  monitor and disk drive that boots to the iconic yellow-on-blue Locomotive BASIC
  Ready prompt."*
- **Iconic era software:** Locomotive BASIC, AMSDOS / CP/M Plus, Protext, The
  Advanced OCP Art Studio.
- **archetypeHint:** **beige-tower-crt** (ideal: a bespoke CPC 6128 + CTM colour
  monitor).

## Input — keyboard exhibit (NO pointer)
The CPC is **keyboard/joystick driven**; the AMX mouse was rare, so there is **no
mouse/pointer acceptance criterion**. Keyboard mapping is the real input work
(Stage 2). The device set mirrors the C64 keyboard sibling: `-machine
pc-i440fx-11.0,vmport=off`, no `usb-tablet`, `SH_POINTER=rel`. The UI still emits
absolute coordinates; streamhost translates them to bounded PS/2 deltas, but with
no CPC pointer those deltas are inert by design.

## Ports (assigned)
- streamhost UDP (WebTransport): **54119** (slot 119).
- ssh hostfwd (host->guest :22, for `labctl exec`): **127.0.0.1:5819** (guest user
  `root`, key `/data/vms/bridge/bridge_key`).
- UI web port (reserved): **8119**. VMID **219**.

## Proven raw QEMU profile (the station device set — MUST match the checkpoint capture)
```
qemu-system-x86_64 -name streamhost-amstradcpc -enable-kvm -machine pc-i440fx-11.0,vmport=off \
  -m 1536 -smp 2 -cpu host -rtc base=localtime \
  -drive file=overlay.qcow2,if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5819-:22 -device e1000,netdev=n0 \
  -loadvm golden   # when the snapshot is present
  -qmp unix:qmp.sock,server=on,wait=off -pidfile qemu.pid
```

## Kiosk / cap32 launch
Caprice32 4.6.0 has no `--fullscreen` flag. The verified capture is its scale-3
SDL/X11 window on the black 1024×768 X root:
```
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_RENDER_DRIVER=software
export SDL_VIDEODRIVER=x11
export LIBGL_ALWAYS_SOFTWARE=1
exec cap32 -O video.scr_green_mode=0 -O video.scr_scale=3
```
The base configuration is green-monitor mode (`scr_green_mode=1`), so the
command-line override is required for the yellow-on-blue colour prompt. The
windowed capture is intentional: sibling SDL real-fullscreen kiosk emulators
render black through std-VGA capture, while this window is framebuffer-proven.

## Keyboard mapping
The browser and streamhost send explicit XT key-down/key-up events to QEMU's
default PS/2 keyboard. Caprice32 maps those physical keys to the CPC matrix.
Timed QMP `send-key` chords overlap their deferred releases and can drop CPC
characters, so automated input proofs must use explicit down/up pairs. Uppercase
letters use Shift plus the letter; `"` uses Shift plus apostrophe; `Enter`
reaches the CPC Return key. The certified proof types `PRINT "HELLO"`, Return,
then `RUN`, and visibly renders `HELLO` in the CPC framebuffer.

## LIVE status (2026-07-27)
- Production/enabled streamhost station, VMID 219, UDP 54119, slot 119.
- Thin `overlay.qcow2` on the frozen bridge seed, with an internal `golden`
  snapshot of the colour `Ready` prompt.
- A cold QEMU start with the tracked device set and `-loadvm golden` returns to
  `Ready`; `labctl reset amstradcpc` uses the same snapshot.
- `labctl exec amstradcpc "<cmd>"` is wired over root SSH on port 5819 with
  `/data/vms/bridge/bridge_key`.
- Mouse acceptance is N/A: this is a keyboard-only exhibit with inert
  `pointer=rel`.
