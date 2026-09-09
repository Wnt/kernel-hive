# Genode Sculpt OS 25.04 (`sculpt`)

The microkernel "component graph" desktop: Genode Labs' Sculpt, where the
running system is drawn as a live graph of components (the Leitzentrale) that
the visitor adds to, wires and inspects. Tier 1, QEMU/KVM x86-64. Wave record:
[`../lab/SCULPT-WAVE.md`](../lab/SCULPT-WAVE.md).

## Media

- Official Genode Labs release image, fetched from origin:
  `https://genode.org/files/sculpt/sculpt-25-04.img` — 33,923,072 bytes,
  sha256 `54e8bd5f3b7c5ebf0fac84aa2c103d8bb8efa62ef6bcb5a08f2cad42cc29c366`
  (GPT disk image; Genode is AGPLv3 with commercial licensing by Genode Labs).
  `scripts/build-guests/tiles/sculpt.sh` verifies the hash and composes the
  4 GiB qcow2 the station boots. The Virtual OS Museum was read for the recipe
  only (their config: q35, AHCI, e1000, PS/2) — nothing was copied.

## Device set (launcher `streamhost/stations/sculpt/qemu-streamhost.sh`)

`qemu-system-x86_64`, KVM, `pc-q35-11.0`, `-cpu host`, 4 GiB, 2 vCPUs, `-vga
std` (vesa fb at 1024x768), AHCI `ide-hd` on `disk.qcow2`, **`usb-ehci` with
`usb-mouse` + `usb-kbd`**, **`e1000`** on the retronet tap `sculptrn0`, no audio
device. Disk + launcher + golden are one combination.

Two device-set facts cost a race and a relaunch each — see the wall table in
`ADD-NEW-OS-PLAYBOOK.md` §0 once promoted:

- **Genode's `usb_hid` never binds QEMU's absolute `usb-tablet`** (xHCI: a
  sprite that never moves; EHCI: no sprite), and HMP `mouse_move` is dead. A
  relative `usb-mouse` on EHCI moves nitpicker's pointer, so the station ships
  the daemon's rel bridge with readback (below).
- **Genode's PC NIC driver does not drive the `rtl8139`**: the `nic` node
  appears, the guest never transmits (35 s of tcpdump on the tap, no DHCP
  discover). `e1000` gets the DHCP reservation in seconds.

## Pointer

Relative, exact: measured with `scripts/dev/cursor-locate.py` at **1 px per
unit** on both axes, no acceleration, no truncation (1/20/100/200/300 units ->
the same px), the screen edge clamps. Fixture: `SH_INPUT_BACKEND=dbus-rel`,
`SH_CURSOR_SCALE=1.0`, `SH_REL_MAX_STEP=127`, `SH_REL_QUANTUM=0`,
`SH_REL_HOME_ON=reset`, `SH_REL_HOME_TO=701,451` (sprite origin (700,450),
hotspot (1,1)). Two-target proof: (811,533) and (523,333) read back exactly.

## Checkpoint

`savevm golden` 2026-09-09 21:50Z on the shipped device set (VM_SIZE 187 MiB,
VM_CLOCK 0:01:40). Scene: the Leitzentrale with the network **Wired** at
10.99.0.38/24, the `ram fs` in use (so the runtime's `+` menu exists), the `+`
menu open on **Options**, pointer parked at (701,451). Restore proof: kill by
pidfile, relaunch `-loadvm golden -S`, `cont` -> framebuffer diff bbox `None`
against the bake frame; pointer found at the same spot and moved 100 px for
100 units afterwards. Reset = `loadvm golden` (`SH_RESET_MODE=loadvm`).

## Retronet

Web plane: tap `sculptrn0` on `vmbr-rn`, guard `SCULPTRN-IN`, DHCP reservation
10.99.0.38 (gateway journal: OFFER + ACK for the station MAC). **OPEN:** a
browser (Morph/Falkon) is a depot package the guest would download from
`depot.genode.org`, which the contained plane cannot serve — so the station is
on the plane but has no browser to reach `search.retronet`. No IM client exists
for Genode; N/A, not OPEN.

## What a visitor can do

Open the `+` menu and toggle Options (audio, touchpad, system clock, trace
logger…) to watch nodes appear in the graph; click any node for its
Inspect/Remove dialog; switch the top-bar views (Files / Components / Log);
open Settings (fonts, keyboard layout). The **Add** tab needs depot downloads
and stays empty on the retronet.

## Rollback

Stop the unit, delete `disk.qcow2`, rerun `tiles/sculpt.sh` for a pristine
disk, and rebake per `SCULPT-WAVE.md`; nothing outside the station dir changes.
