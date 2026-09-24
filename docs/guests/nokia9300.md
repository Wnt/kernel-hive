# Nokia 9300 Communicator — Series 80 v2 — gallery station notes

Status: **DARK-LAUNCH SCAFFOLD** (2026-09-24, agent D2) — registry entry
`listing.state: hidden`, host-native EKA2L1 in a systemd-nspawn sandbox, the
daemon capturing a pinned 1280x400 Xvfb whose root is the 640x200 inner screen
at exactly 2x. Measured facts only; the museum's prose comes later. Research
record: `docs/lab/research/candidate-symbian-s80.md` (branch
`worktree-symbian-s80-research`).

**Guest:** an emulated **Nokia 9300 Communicator** (type RAE-6; TI OMAP1510,
ARM925T at 150 MHz, 64 MiB RAM, 640x200 inner display in 65,536 colours, full
QWERTY keyboard, clamshell) running its **own firmware 5.22 of 2005-11-16** —
Symbian OS 7.0s (EKA1 kernel) with the Series 80 v2 interface. The station
opens at **Desk**, the Series 80 shell. No pointer and no touchscreen: Series 80
is driven by four command buttons beside the screen, eight application
buttons below it, a joystick and the keyboard.

## Identity

- Public ID / station dir: `nokia9300` (registry id == `stationDir` == `SH_STATION`)
- Slot / UDP port / VMID: `219` / `54219` / `219` (`wave.sh alloc`, session `nokia9300`)
- Xvfb display: `:119` (`kh-claim display :119`); container uid base `2621440`
  (40 x 65536, `kh-claim uidbase 2621440`)
- SPA: archetype `putty-lcd` (early-2000s flat LCD; `touch-phone` would put a
  keyboard-only exhibit on the touch recognizer), ui kind `mobile`, keyboard
  family `nokia9300`. Scene tuple `modernMini,lcdA,keyboardH,none` is
  PROVISIONAL — the hall has no clamshell Communicator mesh.

## Emulator

**EKA2L1**, the Symbian HLE emulator, from our fork `github.com/Wnt/EKA2L1`,
branch **`s80-shell` @ `19308cbd0`** (GPL-3; pinned in `tiles/nokia9300.sh`):
agent B1's three application-button commits on top of `s80-epoc7-tables`,
which is upstream master `39858137e` plus agent F1's four commits — `6c81875ce` the Series 80 v2 (7.0s, WS32 build 151) window
opcode table, `2cf4f0daa` kind-checked client handles, `8ef02e3ef` FBS
FontHeightInTwips/Pixels, `6d6805423` Posix PMstat. B1's `3aa70e9eb` makes the
window server handle scancodes 0xB4–0xBB on a Series 80 device (launch the
app, or bring its window group to the front; the focused app never sees the
key), `1e92fc0c5`/`19308cbd0` keep window groups and a ROM Eikon server alive.
With them the ROM's own
Documents, Sheet, Desk and Web paint on the dev box (F1: Desk shell complete
3.5 s after exec, idling at 2 % CPU). Built by
`scripts/build-guests/emulators/build-eka2l1.sh` (agent D1's branch
`eka2l1-builder`: pinned fork commit, trixie build root under nspawn, shared
ccache, mold), called by `scripts/build-guests/tiles/nokia9300.sh`.

Run protocol (measured by agents S, V and F1): `eka2l1_qt --device RAE-6 --run
0x101f8e4f` (Desk; a `0x` token is an app UID) with `XDG_DATA_HOME` on a private
data dir — EKA2L1 copies `compat/ patch/ resources/ scripts/` from its binary
directory into `$XDG_DATA_HOME/EKA2L1` at every start, so two instances must
never share one. It ignores SIGTERM (SIGKILL by pid) and closes itself when
the app it was told to `--run` exits. `QT_QPA_PLATFORM=offscreen` is not a
shortcut (a modal "Unknown Qt platform" dialog, then GLX with no display):
it needs an X server with GLX; Xvfb + Mesa llvmpipe works.

## Golden (never in git — Nokia firmware)

The golden is an EKA2L1 XDG data root: `EKA2L1/config.yml` and
`EKA2L1/data/{devices.yml, roms/rae-6/SYM.ROM, drives/{c,d,e,z}}`.

- Origin: agent F1's working data dir `xdg-9300` of 2026-09-24 (agent S's
  device registration of the 9300 dump staged under
  `/data/assets-staging/symbian-s80/eka2l1-dumps/`) — the data dir that first
  painted Desk, Documents, Sheet and Web.
- Plus ONE file: `C:\System\SharedData\10000865.ini`, the ROM's own default
  (`Z:\System\SharedData\10000865.ini`, UTF-16LE with BOM, CR-separated) with
  `LanguageSelectionDone=0` changed to `=1` — Startup's first-boot language
  wizard captures the application keys and Menu until it completes, and F1's
  C: drive had no SharedData file at all.
- Plus agent B1's `EKA2L1/bindings/default.yml` (2573 B, sha256 `371b0010…`):
  the keymap contract as EKA2L1 bindings — Qt F1–F4 → command buttons
  0xA4–0xA7, F5–F12 → application keys 0xB4–0xBB, Menu → 0x94, F13–F17 → the
  joystick (0xAE/0xAC/0xAD/0xAA/0xAB). F1's copy had F3/F4 on application keys.
- Ledger: 3249 files, 68 106 617 B; tree manifest sha256
  `069a6674568325129bd02f151b3c802dc364023f41d948f4900e5b1118be5c17` (sha256 of
  `find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum` inside the
  root). `SYM.ROM` 17 825 792 B, sha256
  `ca4b0bc929519b046994c8501b0135b688d8d7910d6669f4791805e3ab373596`. Z: tree
  46 635 447 B, C: drive 21 392 B.
- Staged on labhost at `/data/assets-staging/symbian-s80/nokia9300-golden/xdg`
  (+ `MANIFEST.sha256`); `tiles/nokia9300.sh --golden` hash-gates it and
  installs `$STATION/golden` with the previous kept as `golden.prev`.
- `config.yml` logs at `*:trace` (the bring-up setting); the station's live
  copy is rewritten to `NOKIA_LOG_FILTER=*:warn`, and the keeper truncates
  either log past 64 MiB.

## Sandbox

`streamhost/stations/nokia9300/x11-runtime.sh` starts `systemd-nspawn`
(`--as-pid2`, private PID/mount/net/user namespaces, host uids 2621440+, the
rootfs `--volatile=overlay`, capabilities dropped, `~@mount` filtered, no new
privileges, `--private-network`): the EKA2L1 build dir bound read-only at its
own host path (so `/proc/<pid>/exe` names the real binary), the golden
read-only at `/golden`, `work/` and the X socket dir the only writable binds;
`/tmp/.X11-unix/X119` on the host is a symlink to the sandbox's socket. The
reaper is scoped by DESCENT from this launch's nspawn pid (perq measured a rig
and the live station reaping each other's emulator by exe path alone).
`nokia9300-inner.sh` is PID 2: Xvfb, then EKA2L1 in a supervised loop — a
fresh golden copy per launch, relaunch whenever it exits, three exits inside
20 s back off 60 s — and the launcher keeps `mame.pid` on the current
emulator for the daemon's idle freezer.

## Geometry (measured 2026-09-24 on the dev box)

- Qt window tree at the default 900x600: menubar 22 px, central widget with a
  9 px layout margin, the display widget 882x538 at (9,31), status bar 22 px;
  the GL surface is a native, unnamed child of the display widget
  (`gl_x11_render_window`).
- EKA2L1 scales the 640x200 screen by the display widget's WIDTH
  (`mainwindow.cpp`: mult = widget_w / 640, centred). A 1280x400 display
  widget is therefore an exact 2x: in a capture of Desk all 128 000 2x2
  blocks were uniform at (0,0) alignment (nearest-neighbour filter on).
- The inner script finds the display widget (the GL child's parent), resizes
  the top-level by the difference (1298x462 on the dev box) and moves it so the
  widget sits at root (0,0) (-9,-31 on the dev box) on a 1280x400 root: the
  captured root is the phone screen and nothing else. It never assumes the
  offsets — they depend on the container's Qt style and fonts.
- Trap 1: the GL surface resizes LAZILY, on the next present, and Desk presents
  only when its screen changes. Placed after Desk's first frame, the window
  showed the old 882x538 picture in the corner of the new root until a repaint;
  placed the moment the window exists (4.4 s after exec at host load 96, before
  Desk's first frame) the first guest frame is already 2x.
- Trap 2: EKA2L1's Qt `Ctrl+F` is its own fullscreen toggle (a WindowShortcut
  in `mainwindow.ui`); a keeper loop re-places the widget whenever it leaves
  0,0,1280x400. Agent B2's kiosk flags (no menubar, fixed geometry) remove both
  traps; they go in `NOKIA_EMU_ARGS`. The menus have no Alt mnemonics.

## Input — keys only, over XTEST

Agent K1's keymap contract v1 (`$J/K1/keymap-contract.md`; keysyms FIXED, every
row PROVISIONAL until a framebuffer proves it):

| Key | Keysym | Key | Keysym |
|---|---|---|---|
| command buttons 1–4 (top to bottom) | `F1`–`F4` | Menu | `Menu` |
| Desk, Telephone, Messaging, Web | `F5`–`F8` | Chr | `ISO_Level3_Shift` (Alt_L/Alt_R aliases) |
| Contacts, Documents, Calendar, My own | `F9`–`F12` | joystick centre/up/down/left/right | `F13`–`F17` |

Printables are injected as their own keysyms and the fork maps each character
back to the 9300 key; Shift is never held around a printable (X would apply US
shift rules); Ctrl and Chr are held around a key's base keysym. The chain and
what had to change for it:

- SPA: family `nokia9300` (`spa/src/ui/keyboard/keyboardProfiles.data.handheld.ts`)
  — base rows = the eight application buttons, then the four command buttons +
  Menu, Esc, Enter, Backspace, the Chr (sends `Alt_R`), Ctrl and Shift latches
  and the arrows (agent D3's QA: landscape hides `moreRows`, and Chr is the only
  path to € and the task switcher); more rows = Tab, Space and the joystick
  (it sends the same Enter/arrow key codes the base row already carries).
  `KEYSYM_TO_SCANCODE` gained F13–F17 = set1 `0x64`–`0x68`.
- Daemon: `SH_X11TEST_KEYMAP=x11test.keysyms` — the fleet's US table plus
  F13–F17 and `0xe038` → `ISO_Level3_Shift`.
- Xvfb: keycodes 191–195 carry XF86Tools/XF86Launch5–8 in a stock keymap, and a
  runtime remap does NOT stick on Xvfb 21.1 (measured on trixie 21.1.16 and
  Ubuntu 21.1.12: `xmodmap` and an `xkbcomp` upload exit 0 and change nothing,
  even for a plain letter). The inner script starts Xvfb with `-xkbdir` on a
  copy of the XKB data whose `symbols/inet` binds `<FK13>`–`<FK17>` to F13–F17
  (proven on labhost). `-ardelay 65000` keeps X autorepeat out of it; EKA2L1
  makes the Series 80 repeats itself (300 ms, then 100 ms).
- Pacing: fleet floor 40/40. EKA2L1 queues key events
  (`window_server::queue_input_from_driver`) rather than sampling a matrix per
  frame; K1 measured >= 15 ms between events as enough, F1 typed digits at
  xdotool's 12 ms.
- Focus: no window manager, so the inner script pins X focus to the top-level
  (`xdotool windowfocus`, the its/vax43bsd trap); EKA2L1 focuses its display
  widget at app launch.

## Boot and reset

`resetMode: relaunch` — kill the container, a fresh golden copy, cold start of
Desk: 3.5 s after exec on an idle host (F1), 11 s at host load 96 (D2, dev box).
EKA2L1 has no save state on this path and the nspawn CRIU route is blocked by
the sandbox's seccomp filter. `bootrec-tiles.conf` is not armed (no vmstate).

## Period software

- Web = **Opera 6.0 for Symbian OS, build 543**: the about page inside
  `Z:\System\Libs\oprmodel.dll` (2 170 140 B, sha256
  `73b75dacc41b8ccb6290f4aa60dc35609aa359e23cb4af5437a2e1885e16f0f7`) reads
  "Opera 6.0 for Symbian OS - Alpha (543)", © 1995-2003 Opera Software ASA; its
  UA templates are `Mozilla/4.0 (compatible; MSIE %s; %s) Opera 6.0 ~ [%s]` and
  `Opera/6.0%s (%s; U) ~ [%s]`.
- Apps in `Z:\System\Apps` include `desk`, `cword` (Documents), `sheet`,
  `opera`, `agenda`, `mcentre`, `phoneapp`, `sysap`, `startup`.
- Web opens on the ROM's own local home page,
  `file://localhost/Z:/System/Apps/Opera/Home.htm` (agent X1's frames of the
  real platform), so it has a first screen before any network exists; the
  browser plane's home can later be a retronet URL.

## Network

None yet: the container runs `--private-network` (lo only). Opera's plane is
agents N1/N2's — EKA2L1 decodes the 7.0s socket server with 6.1 numbers
(agent Y) — either through a netns on retronet (the amigaos35/nextstep
precedent) or EKA2L1's own `hosts:` map in `config.yml` for the names. No
retronet reservation is held and no `rn-tapnet.sh` is committed until the
plane is proven (AGENTS.md rule 15).

## Dark launch (2026-09-24, before the branch lands)

`/os/nokia9300` is a sandbox rig published with
`scripts/dev/darklaunch-station.py publish nokia9300 --rig
/data/vms/sandbox/nokia9300/smoke --entry <entry.json>` (the entry rendered
from this registry row by `emit_gallery_manifest`, order 900, `listed:
false`). Not `smoke-rig.sh --like`: its stream.env step starts a daemon on the
sibling's LIVE display before it can be patched for an x11 rig.

- Launcher: this branch's `x11-runtime.sh`, unmodified, in the transient scope
  `kh-nokia9300-rig.scope` with `NOKIA_BASE=/data/vms/sandbox/nokia9300/smoke`,
  the emulator and runtime root from agent D1's `/data/vms/sandbox/s80-eka2l1/`
  (`out/eka2l1` rebuilt with D1's builder at `s80-shell` @ `19308cbd0`, 228 s
  incremental, sha256 `5e9c7ee0…7e01`; `rootfs` re-shifted from 3932160 to
  2621440), `NOKIA_MACHINE=kh-nokia9300-rig`,
  `NOKIA_X11_SOCKDIR=/run/streamhost/x11/nokia9300-rig`.
- Daemon: lisa's released binary, `<rig>/run-daemon.sh` + `<rig>/stream.env`
  (x11 capture of `:119`, x11test keys with the station keymap,
  `SH_IDLE_PAUSE_SECS=0`); its log: `[x11cap] first frame 1280x400`,
  `x11test keymap … (108 scancodes resolved)`, `LISTENING udp/54219`.
- Application buttons on the rig (s80-shell @ `19308cbd0`, B1's bindings in
  the golden), XTEST on `:119`, each frame waited with `fb-wait.py --change
  --settle`: F10 → Documents in front (Insert object / Font / Style / Exit),
  F5 → Desk (Open / Write note / Note list), F10 → Documents again
  (`$J/D2/keys-*.png`). Desk does not paint its lower-left pane, so the app
  below shows through there.
- Measured on the box: the trixie root's Qt draws a 19 px menubar (22 on the
  dev box), so placement settled the window at 1298x459+-9+-28 — found, not
  assumed — with the GL surface at 1280x400+0+0, 2 s after exec. The frame
  through the daemon's capture path (`x11spike capture`, what `labctl shot`
  runs for an x11 tile) is pixel-identical to the dev-box frame and has 0 of
  128 000 non-uniform 2x2 blocks. Idle cost: emulator 1 %, daemon 2 % of a core.
- Reaper, measured: a SIGTERM to `systemd-nspawn` never reached the inner
  script's trap, and the old fallback (SIGKILL the supervisor) orphaned the
  container and left `/run/systemd/nspawn/unix-export/<machine>`, so the next
  launch died "Mount point … exists already". The launcher now SIGKILLs the
  container's init (nspawn's direct child) and lets nspawn exit and clean up;
  proven by relaunching over a live rig (31 s, no orphan, no stale mount).
- Restart after a relaunch: `<rig>/run-daemon.sh`. Withdraw:
  `darklaunch-station.py withdraw nokia9300`, then `systemctl stop
  kh-nokia9300-rig.scope` and kill `<rig>/daemon.pid`.

## Known gaps / OPEN

- Every key row is unproven on the station: the command buttons, application
  keys, Menu, Chr and joystick need K1's fork keymap (branch `s80-keymap`) in
  the station build, and B1's application-key switching inside the ROM.
  Acceptance checklist for the four command buttons — the labels each app
  prints beside them (agent X1, the real platform): Desk = Open / Write note
  (/ Note list); Documents = Insert object / Font / Style / Exit; Web = Open Web
  address / Back / Bookmarks / Exit; Sheet = Edit / Insert function / Clear /
  Exit. Cmd N must fire the Nth label on the framebuffer.
- Desk's lower-left 135x140 px (at 1.38x) stays black; Documents and Sheet busy-loop
  one core (window-group text-cursor opcodes; F1 §5).
- `£` (Shift+3) cannot be typed from the on-screen keyboard: the US X layout
  has no sterling keysym to press. `€` is Chr+4.
- Kiosk frontend (B2): no menubar/status bar, fixed geometry, a control socket.
- Hall scene: no clamshell mesh (provisional tuple); poster prose and hero
  are placeholders.
