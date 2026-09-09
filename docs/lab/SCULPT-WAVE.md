# Genode Sculpt OS 25.04 integration wave — 2026-09-09

Genode Sculpt OS 25.04, the microkernel "component graph" desktop (Leitzentrale),
x86-64 on QEMU/KVM (Tier 1), scaffolded `--like serenityos`. Ran beside the
`medley`, `domainos` and `lisa` waves (landing lock via `wave.sh land`).
**Status: LANDED** — live station with a relative USB-mouse pointer (exact,
with readback), a restore-proven golden, and the guest on the retronet plane
(DHCP reservation taken; browser OPEN, see below).

## Ledger — from `wave.sh alloc sculpt --retronet --x11warp`

| Field | Value |
|---|---|
| slot / UDP port / VMID | 190 / 54190 / 190 |
| x11warp display | `:90` (loopback `127.0.0.1:6090`) — unused; Genode has no X server, and no slirp NIC ships (a second NIC only adds a dead `nic` node) |
| retronet address | 10.99.0.38 (DHCP, reservation rendered in CT 951) |
| retronet tap / chain | `sculptrn0` / `SCULPTRN-IN` |
| ICQ UIN | 19000 — unused; there is no IM client for Genode (N/A, not OPEN) |
| sibling (`--like`) | serenityos; hardware tuple `towerC \| lcdB \| keyboardF \| paramMouseE` |
| device set | q35, `-cpu host`, 4 GiB, 2 vCPUs, AHCI `ide-hd` on `disk.qcow2`, **`usb-ehci` + `usb-mouse` + `usb-kbd`**, **`e1000`** on tap `sculptrn0`, `-vga std` (1024x768), no audio device |
| media | https://genode.org/files/sculpt/sculpt-25-04.img — 33,923,072 bytes, sha256 `54e8bd5f3b7c5ebf0fac84aa2c103d8bb8efa62ef6bcb5a08f2cad42cc29c366` (official Genode Labs release, fetched from origin; VOM read for the recipe only) |
| golden | `savevm golden` 21:50Z, VM_SIZE 187 MiB, VM_CLOCK 0:01:40, baked on `/data/vms/sandbox/sculpt/bake/disk.qcow2` |

## Proven in the spine

- Boot to the Leitzentrale in ~11 s; frame stable (two no-input screendumps
  byte-identical). Smoke rig published at `/os/sculpt` at minute ~8.
- VOM's `RUN_QEMU` (`q35 -m 4096`, AHCI, `e1000` + user net, no explicit input
  device) read for the recipe; their 964 MB disk is a used install with a
  Falkon/WebKit browser deployed and was never copied.

## Walls hit

### 1. Injected pointer never reached the Leitzentrale — RACED, WON

The spine's four serial device-set variations (QMP abs `usb-tablet` on xHCI,
HMP PS/2 relative, `-nodefaults` + tap-only, VOM-faithful e1000/user-net) all
produced zero framebuffer change; the `ps2` and `usb hid` driver nodes were
running and `info mice` listed both devices. The coordinator raced six runners
(`race/usbmouse`, `race/ps2only`, `race/usbctl`, `race/inpath`, …), framebuffer-
proven, frames kept in `/data/vms/sandbox/sculpt/race/usbmouse/`:

- **WINNER: `-device usb-ehci,id=e -device usb-mouse,bus=e.0 -device
  usb-kbd,bus=e.0`.** QMP `input-send-event` **rel** x/y moves nitpicker's
  pointer sprite (F12 to a black desktop with only the sprite; 3×(+200,+150)
  then (−400,−300) put it at ~(628,472); F12 back shows it atop the
  Leitzentrale; a left btn down/up cleared the `ahci` selection outline).
- **Keyboard** proven on both xHCI and EHCI: `input-send-event` key qcode `f12`
  toggles the Leitzentrale (reversible).
- **DEAD:** QEMU's absolute `usb-tablet` on xHCI (sprite exists, never moves)
  and on EHCI (no sprite at all) — Genode's `usb_hid` never binds it. HMP
  `mouse_move` dead on every set.

Shipped transport: the daemon's abs→rel bridge with readback (`dbus-rel`),
measured on the bake guest with `scripts/dev/cursor-locate.py`: **1 px per
unit on both axes, no acceleration, no truncation** (1/20/100/200/300 units →
the same px; the screen edge clamps), so `SH_CURSOR_SCALE=1.0`,
`SH_REL_QUANTUM=0`, `SH_REL_MAX_STEP=127` (one int8 HID report),
`SH_REL_HOME_ON=reset`, `SH_REL_HOME_TO=701,451`. Two-target readback proof:
(811,533) after +100,0 and (523,333) after −500,−300 from the clamped edge —
both exact.

**Wall-table candidate row (playbook §0):**

| Wall | Measured cause | Fix |
|---|---|---|
| Genode/Sculpt: the Leitzentrale ignores every injected pointer event although its `ps2` and `usb hid` driver nodes run | Genode's `usb_hid` never binds QEMU's absolute `usb-tablet` (xHCI: a sprite that never moves; EHCI: no sprite); HMP `mouse_move` is dead too | `-device usb-ehci -device usb-mouse -device usb-kbd` and ship the rel bridge with readback: 1 px/unit exact, `SH_REL_MAX_STEP=127`, re-home on reset (sculpt, 2026-09-09) |
| Genode: the `nic` node appears but the guest never transmits (no DHCP discover on the tap in 35 s, fdb empty) | Genode's PC NIC driver does not drive the `rtl8139` | `e1000` on the tap — DHCP OFFER/ACK for the reservation within seconds |

### 2. The retronet NIC: rtl8139 bound, never transmitted

Second row above. Found before the bake, so it cost one relaunch and a
scripted replay of the clicks (Network → Wired, ram fs → Use), not a rebake.

### 3. Tooling notes (not walls)

- The smoke-rig daemon owns the QMP monitor; drive the guest through the
  launcher's HMP `reset-hmp.sock` for screendumps (PPM regardless of the
  extension) or stop the daemon for the bake. HMP `mouse_move` is relative and
  mis-scaled — never a pointer proof.
- `cursor-locate.py learn` on a frame pair where the guest also repainted the
  hole under the old sprite learns TWO templates; drop the repaint id from
  `cursor-bank.json` (or learn `--at`).

## Landing

`scripts/dev/station-land.sh sculpt --golden /data/vms/sandbox/sculpt/bake/disk.qcow2`
(window taken 18:58Z, released 19:00Z): fetch+merge clean, scene rows rebuilt,
validate + vitest green, pre-push gate green (eslint/knip, vitest, ruff, shfmt/
shellcheck ×4, size budget, drift, box state), **main pushed `cb79c525`**,
`box-deploy --apply` (452 same), golden swapped in (old disk parked as
`disk.qcow2.pre-20260909-185833`), smoke rig down, `station-up.sh` → unit
active, LISTENING udp/54190, first frame 1024x768 in 1.9 s, claims re-homed.

**Step 11 then FAILED on a false negative:** `station-land.sh` ran
`rn-verify.sh` on CT950, where `ip link`/systemd/`pct` see nothing, so it
printed `tap=none unit=inactive reservation=0` for a station that was up. The
same check on labhost: `tap=UP master=vmbr-rn unit=active env-rn=3
reservation=1 OK`. Fixed at the root in this wave (`station-land.sh` now calls
the deployed copy through `ssh lab`). The failure also skipped step 12 (SPA
build + deploy) and left the smoke rig's dark-launch overlay masking the
registry row as "sculpt (smoke rig)"; both were finished by hand: overlay
withdrawn, manifests republished, SPA built + deployed in a second landing
window, other waves' overlays re-applied.

Live proofs after landing: `labctl reset sculpt` → `loadvm golden` restored in
3.4 s and `labctl shot` shows the bake scene (`sculpt-after-reset.png`); a
`/proc/*/cwd` sweep finds no QEMU left under `/data/vms/sandbox/sculpt/`.

## Proofs (the framebuffer is the only proof — rule 9)

- Pointer race: `race/usbmouse/{d0,d1v,d2v,WIN-v1,back,afterclick}.png`.
- Scale + two-target readback: `bake/m1..m8.ppm` with `cursor-locate.py find`
  (711,533 → 811,533 → 811,633 → edge → 523,333 → 543,333 → 543,313 → 544,314).
- Network: `bake/r1.png` (Network panel "Wired 10.99.0.38/24"), gateway journal
  `retronet-dhcp <station MAC> -> OFFER/ACK 10.99.0.38` (the MAC stays in the
  box-side local.env, rule 1), `bridge fdb` count 1.
- Golden + restore: `bake/g0.ppm` (bake frame, pointer 700,450) vs `bake/g1.ppm`
  after kill → `-loadvm golden -S` → `cont`: diff bbox `None`; `g2.ppm` pointer
  at 800,450 after +100 units.

## OPEN items

- **`fdb=0` in rn-verify** after landing: reported, not gated — the daemon
  idle-pauses the guest, so the L2 entry ages out; it was 1 during the bake
  right after the DHCP ACK.
- **Retronet web plane, browser half:** the guest is ON the plane (reservation
  taken, L2 seen), but a browser is a depot package fetched from
  `depot.genode.org`, which the contained plane cannot serve. Next step: mirror
  the `genodelabs` depot index + the `morph_browser`/`falkon` pkg archives onto
  the retronet gateway and point Sculpt's depot at it, or compose a pre-deployed
  depot onto the disk before the bake. `rn-verify.sh sculpt` gates tap/master/
  unit/reservation/fdb only; it passes.
- **IM client:** N/A for Genode.
- **Type-in demo:** none (mouse-driven desktop); keyboard proven only by the
  race's F12 toggle.

## Measured timeline

Fork sessions cannot run `session-timeline.py` on their own transcript (it is
the parent's). From git and box timestamps: alloc 18:13Z, smoke `/os/sculpt`
~18:21Z, first branch push 18:33Z (viewable, pointer OPEN), race won by the
coordinator ~21:30Z, golden 21:50Z, landing after.

## Teardown (part of "done" — rule 8)

Race clones `usbmouse` and the smoke emulator + daemon killed by pidfile
through `clone-guard`; `ps2only` was already gone (`/proc/*/exe` sweep found
only the bake guest). The bake guest is killed by pidfile after the golden is
installed; claims re-homed by `station-land.sh`. Check: the `/proc` sweep lists
no QEMU with a cwd under `/data/vms/sandbox/sculpt/`, `labctl who sculpt`.
