# win311 in-guest absolute-pointer agent — STATUS: BAKED + LIVE (AGENT.EXE in the live golden; coalescing rev baked 2026-07-08)

`agent.c` is a tiny Win16 (NE) application for **Windows for Workgroups 3.11**
(streamhost tile `win311`, 640x480 VGA, 386-enhanced under QEMU). It fixes the
pointer-desync / cursor-**jump** symptom that appears when the abs->rel homing
bridge feeds big coalesced deltas into the Win3.x DOS mouse-driver acceleration.

## What it does

It opens **COM1** and speaks the warpd newline protocol (guest pixels):

```
M x y       move cursor to (x,y)                  -> SetCursorPos (absolute)
P n x y     move to (x,y) then press button n     (1=L 2=M 3=R)
R n x y     move to (x,y) then release button n
B n x y     move to (x,y) then click button n     (n 4/5 = wheel: ignored)
```

`M` uses `SetCursorPos` — **absolute, immune to mouse acceleration and to delta
coalescing**, so there is zero position drift. Verified: 20 random jumps then
`M 320 240` lands byte-for-byte identical to a direct center move.

`P/R/B` use `SetCursorPos + WindowFromPoint + ScreenToClient + PostMessage(WM_*BUTTON*)`
with `GetTickCount` double-click detection. This works for **client-area** targets
(icons, buttons, Minesweeper cells, flags) but **NOT** for non-client areas
(menus, title bars) — see button modes below. `mouse_event()` is a **no-op** on
this stack (QEMU + WfW 3.11 `mouse=*vmd`), so it is only a supplement.

## Button modes (daemon `SH_WARPD_BUTTONS`)

Motion always stays on the agent (`M` = SetCursorPos). Buttons can be routed two ways:

| Mode | `SH_WARPD_BUTTONS` | click / flag | menu open | **title-bar drag (user scenario)** |
|------|--------------------|:---:|:---:|:---:|
| A — agent PostMessage | (unset / `agent`) | yes | **no** | **no (window does not move)** |
| B — qemu-hybrid PS/2  | `qemu`             | yes | yes | **yes (window relocates cleanly)** |

**Mode B is the recommendation.** Real PS/2 button down/up (QMP
`input-send-event`, position-less) fire at the agent's `SetCursorPos` location —
because `SetCursorPos` also syncs the Win3.x driver's tracked position — giving
true window-manager semantics: menus drop, and the title-bar drag follows the
cursor with **no jump and no stuck button**. All clone-proven on `win311-c1`.

## Build (OpenWatcom 1.9, Linux binl -> NE Win16)

OpenWatcom **1.9** — the box's pinned Watcom toolchain (V2's runtime crashes on
OS/2 Warp 4 GA, so 1.9 is the standard for all DOS/Win16/OS2 agents; see
`AGENTS.md` and `docs/guests/os2warp.md`).

```sh
WATCOM=/root/watcom PATH=$WATCOM/binl:$PATH \
  INCLUDE=$WATCOM/h/win:$WATCOM/h \
  wcl -bcl=windows -mc -fe=AGENT.EXE agent.c
```

Output must be `NE ... for MS Windows 3.00` (verify: `file AGENT.EXE` and the
`NE` signature at the `e_lfanew` offset, 0x80). Produces a ~4.3 KB `AGENT.EXE`.

## Inject into the win311 qcow2 (FAT16, offline)

The disk is FAT16. **Never qemu-nbd a disk whose VM is running** — stop the VM
first (and back up the golden qcow2 as `*.pre-agent`).

```sh
modprobe nbd max_part=16
qemu-nbd --connect=/dev/nbd7 -f qcow2 win311-golden.qcow2
mount -t vfat /dev/nbd7p1 /mnt/win311
cp AGENT.EXE /mnt/win311/AGENT.EXE                 # -> C:\AGENT.EXE
# WINDOWS\WIN.INI  [windows]  load=C:\AGENT.EXE   (CRLF, no argument)
#   set the empty  load=  line to  load=C:\AGENT.EXE  keeping CRLF endings
sync; umount /mnt/win311; qemu-nbd --disconnect /dev/nbd7
```

`load=` (not `run=`) autostarts the agent at Windows boot. It creates a 1x1
`WS_POPUP` window that owns the message queue and drains COM1 via
`EnableCommNotification`/`WM_COMMNOTIFY` (plus a 55 ms `WM_TIMER` fallback).

## Transport / daemon wiring

Launcher gets a COM1 backend socket (guest COM1 device unchanged, so a
`loadvm golden` still matches):

```
-chardev socket,id=ser0,path=<tiledir>/serial.sock,server=on,wait=off
-serial chardev:ser0
```

station.env:

```
SH_POINTER=warpd
SH_WARPD_ADDR=unix:<tiledir>/serial.sock
SH_WARPD_BUTTONS=qemu          # Mode B — required for title-bar drags + menus
```

Because the disk was modified offline, the internal `golden` snapshot's disk is
stale: after injecting you must **cold-boot** (not loadvm), reach a clean
Program Manager desktop, then `delvm golden` + `savevm golden` anew.
