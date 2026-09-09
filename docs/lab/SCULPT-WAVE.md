# Genode Sculpt OS 25.04 integration wave — 2026-09-09

Genode Sculpt OS 25.04, the microkernel "component-graph" desktop (Leitzentrale),
x86-64 on QEMU/KVM (Tier 1), scaffolded `--like serenityos`. Runs beside the
`medley`, `domainos`, `lisa` waves. **Status: dark-launched / VIEWABLE — the
Leitzentrale boots and streams at `/os/sculpt`, but interactive pointer injection
into the fresh official image is UNPROVEN (see OPEN items). NOT landed live.**

## Ledger — from `wave.sh alloc sculpt --retronet --x11warp`

| Field | Value |
|---|---|
| slot / UDP port / VMID | 190 / 54190 / 190 |
| x11warp display | `:90` (loopback `127.0.0.1:6090`) — unused; Genode has no X |
| retronet address | 10.99.0.38 |
| retronet tap / chain | `sculptrn0` / `SCULPTRN-IN` |
| ICQ UIN | 19000 (unused — no IM client on Genode) |
| sibling (`--like`) | serenityos |
| hardware tuple | `towerC \| lcdB \| keyboardF \| paramMouseE` (distinct from serenityos) |
| device set | q35, `-cpu host`, 4 GiB, 2 vCPUs, AHCI disk (qcow2 over the image), qemu-xhci + usb-tablet + usb-kbd, ONE NIC (retronet tap rtl8139), std VGA, no audio device |
| media | https://genode.org/files/sculpt/sculpt-25-04.img — 33,923,072 bytes, sha256 `54e8bd5f3b7c5ebf0fac84aa2c103d8bb8efa62ef6bcb5a08f2cad42cc29c366` (official Genode Labs release; fetched from origin, NOT from VOM) |

## Proven in the spine

- **Media**: official Sculpt 25.04 image fetched from genode.org and hashed
  (above). VOM carries only `andrew_warkentin`'s 964 MB pre-configured install
  (`.../drops/genode_sculpt_25.04_config/hda.qcow2`), read for the recipe only —
  their `RUN_QEMU` is `-machine q35 -m 4096`, AHCI disk, `-netdev user -device
  e1000`, and NO explicit input device (relies on the q35 default PS/2). Their
  disk is a used install with a Falkon/WebKit browser deployed; ours is the
  fresh release image.
- **Boot**: the guest reaches the Leitzentrale in ~11 s and the frame is stable
  (two no-input screendumps are byte-identical). The component graph shows
  `Hardware -> ps2 / vesa fb / usb (usb hid) / ahci`, plus `Config / Info / GUI /
  ram fs`. This is the distinctive exhibit frame — nothing else in the lineup
  looks like it.
- **Smoke rig published** at `/os/sculpt` via `smoke-rig.sh --like serenityos`
  (dark-launch `darklaunch.d/sculpt.json`).

## Walls hit

### Interactive pointer does not respond to injected input (OPEN, needs a race)

Across FOUR device-set variations — (1) `-nodefaults` + tap-only NIC + xhci
usb-tablet; (2) QMP `input-send-event` absolute (usb-tablet); (3) HMP PS/2
relative; (4) VOM-faithful `q35 / e1000 / user-net` + xhci usb-tablet — **no
injected pointer or PS/2 event produced any framebuffer change.** The frame is
stable, so this is not a capture artifact: `info mice` confirms both a "QEMU HID
Tablet (absolute)" and a "QEMU PS/2 Mouse" exist, and Sculpt's graph shows the
`ps2` and `usb hid` driver nodes running, yet nitpicker draws no pointer sprite
and the menu bar (`Settings / Files / Components / Network / Log`) never
switches. (Early apparent "reactions" were the one-time settling of the `ahci`
node's selection border during the first ~15 s of boot; once stable, all input
diffs are zero.)

**This is a discovery wall — race it (rule 14), do not poke serially.** A fork
cannot spawn `rig-clone.sh` runners; the next session should race these theories,
first framebuffer proof wins:

1. **USB controller**: bind the tablet via UHCI/EHCI (`-usb -device usb-tablet`)
   instead of `qemu-xhci`. Sculpt's `usb_hid` may not enumerate the tablet on
   xHCI. **Top theory — untested.**
2. **Fresh-image deploy state**: the official image may hold input until a "used
   file system" / storage target is selected in the Leitzentrale, which is
   circular without a working pointer. Check whether the graph is in a
   pre-deploy state and whether a config edit (or a pre-selected storage target
   composed onto the disk) makes it interactive. Genode's Sculpt manual §"Using
   a persistent storage device" is the reference.
3. **PS/2 only, correctly positioned**: drive the q35 default PS/2 mouse with a
   proper origin-then-relative walk (HMP relative is mis-scaled — the openbsd
   note) and confirm nitpicker's pointer moves.
4. **dbus display input path**: confirm `input-send-event` actually reaches the
   Genode drivers on this build (send a keyboard event Sculpt reacts to).

If the pointer is proven, complete the device set (tap NIC + slirp already
wired), bake `savevm golden`, prove restore + `rn-verify.sh`, then promote the
listing (drop the `hidden` block) and land via `station-land.sh`.

## Landing

**Not landed to main.** Branch `sculpt` pushed with the ledger, launcher,
scaffold (registry entry with real Genode prose, `listing: hidden`), retronet
wiring (`rn-onboard.sh --apply`, tap + guard + DHCP reservation on the box),
media manifest, and this doc. A push is not a deploy; no live station row is
promoted.

## Proofs (the framebuffer is the only proof — rule 9)

- Boot to Leitzentrale, frame stable: `f1.png`, `n1.png`/`n2.png` (byte-identical
  no-input pair) in `/data/vms/sandbox/sculpt/smoke/`.
- Pointer NON-reaction: `n2.png` vs `n3-mv.png` (move to 300,250) — zero diff;
  `s2-base.png` vs `s2-mv.png` / `s2-settings.png` — zero real diff.

## OPEN items

- **Interactive pointer** — race the four theories above; #1 (UHCI/EHCI
  usb-tablet) first.
- **Golden** — not baked (blocked on the pointer; a golden with a dead pointer
  is not shippable).
- **Retronet web plane** — tap + guard + DHCP reservation wired and rendered,
  but not proven on the plane (`rn-verify.sh sculpt`) because the guest's own
  network deploy needs the interactive Leitzentrale first.
- **IM client** — N/A: Genode has no era-appropriate ICQ client; report as not
  applicable, not OPEN.

## Teardown

Smoke rig left UP intentionally so `/os/sculpt` stays viewable for the operator.
Claims (slot/port/vmid/display/retronet 190 / 10.99.0.38) remain under
`$KH_SESSION=sculpt`; they transfer to the station session only at a real
`station-land.sh`, which has not run. Release them with
`kh-claim release --session sculpt ...` if the wave is abandoned.
