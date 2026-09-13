# SCO Xenix System V/386 2.3.4 integration wave — 2026-09-13

SCO Xenix 386 2.3.4 (1989) — Microsoft's own Unix, licensed to SCO and for a
while the most-installed Unix in the world. Tier: the `freedos` archetype
(`--like freedos`), a plain x86 PC under the fleet QEMU. UI kind
`text-console`: an 80x25 Xenix console with Multiscreen (Alt-F1..Alt-F4), no
pointer. Runs beside four other station waves tonight (macsys1, apple2gs,
minix2, os213) behind the `job-84ed2a5b` coordinator — allocations through
`wave.sh alloc`, main pushes serialised by the landing lock (`wave.sh land`,
taken by `station-land.sh`). See `WAVE-COORDINATION.md`.

## Ledger — from `wave.sh alloc xenix`

| Field | Value |
|---|---|
| slot / UDP port / VMID | 202 / 54202 / 202 |
| x11warp display | — (text console, no in-guest X) |
| retronet address / MAC / tap / chain / UIN | — (see Retronet below) |
| sibling (`--like`) | `freedos` |
| hardware tuple | `towerE|crtA|keyboardA|paramMouseA` (DISTINCT from freedos's `pizzaBoxB|crtA|keyboardA|paramMouseA`) |
| render orders | as scaffolded by `stations-registry.py new --like` — never hand-edited |
| device set | `qemu-system-i386 -machine isapc -cpu 486 -m 16 -vga std`, one IDE disk with an EXPLICIT CHS geometry, SB16 (ISA) audio, no NIC, TCG (no `-enable-kvm`) |
| media | staged by the `xenix-media` agent under labhost `/data/assets-staging/xenix/`; URL + sha256 + byte size in that dir's `SOURCES.md` and in `scripts/build-guests/tiles/xenix.sh` |

`wave.sh alloc` refused slot 199 on the first call — `macsys1` had claimed it
microseconds earlier in the same wave. That is rule 7 working as designed (a
hard failure naming the holder, never a silent bump); the retry took 202.

## Why this device set

Xenix 386 2.3.4 predates PCI, CPUID and everything QEMU's default `pc` machine
assumes:

- `-machine isapc` — no PCI bus at all. The Xenix kernel probes AT/ISA
  hardware; a PCI IDE controller it cannot see is a disk it cannot boot from.
- `-cpu 486` — Xenix 386 dislikes Pentium+ feature bits.
- **TCG is the default, KVM is a theory** — 386-era protected-mode code has
  bitten KVM before, and a text console on 16 MB of emulated 486 is not a
  performance problem. KVM is raced as a clone, never assumed.
- **Explicit CHS** (`cyls=,heads=,secs=`) on a disk **≤ 504 MB**. The Xenix
  boot block and divvy table are written against the geometry the installer
  saw; boot the same image with QEMU's auto-derived geometry and the boot
  block reads garbage. This is the single most likely wall on this station.
- No NIC — see Retronet.

## Retronet — OPEN, and why

SCO TCP/IP for Xenix was a **separate product** with its own media and its own
licence; the base 2.3.4 install set has no TCP/IP stack, no browser and no IM
client. Putting xenix on the retronet web plane means sourcing and installing
SCO TCP/IP Runtime for Xenix first — an install-floppy hour that this wave
does not spend. The launcher therefore ships **no NIC at all** rather than a
NIC the guest cannot use, and no `rn-tapnet.sh` is committed (AGENTS.md rule
15: a committed tap script deploys fleet-wide on the next `box-deploy
--apply`). Next step when it is picked up: source SCO TCP/IP 1.2.x for Xenix
386, add the NIC to the device set, and **re-bake the golden** — a new NIC is
a device-set change, so it is a new checkpoint and a new restore proof.

## Sandbox verdict

**No nspawn container.** This station is an EMULATED MACHINE under the fleet
QEMU (pve 11.0.2): the visitor's reach ends at the emulated 486, and the
launcher line above is the whole host surface. There is no 9p/virtfs/smb/`fat:`
host drive, no `-netdev user` hostfwd, no guest-reachable QMP or monitor, and
no virtio-serial host channel. The QMP socket is a host-side unix socket the
guest has no device for.

## Pointer, keyboard, demo

- Pointer: **none**. A Xenix text console has no mouse; the registry row says
  so and the SPA must not offer a pointer affordance.
- Keyboard: the fleet floor **40/40**. Measured only if characters drop.
- Demo: `uname -a`, `who`, `ls /usr`, then **Alt-F2** to a second Multiscreen —
  the one thing a visitor cannot guess from a shell prompt and the feature
  that made Xenix feel like a real Unix on a PC.

## Streams

| Stream | Owns | Model | Status |
|---|---|---|---|
| `xenix-media` (coordinator-spawned) | labhost `/data/assets-staging/xenix/` + `MANIFEST.sha256` + `SOURCES.md` | — | running |
| `xenix-spa` (coordinator-spawned) | poster, hero, prose, scene rows | — | running |
| lead (this branch) | ledger, launcher, fixture, smoke boot, golden bake + proofs, landing | Opus | active |
| `xenix-docs` | `docs/guests/xenix.md`, `GUEST-TIERS.md`, release-notes fact file | sonnet-low | after golden |

## Walls hit

(filled as they happen — theories raced on `rig-clone.sh` clones, never
bisected serially; every wait is `fb-wait.py`, never `sleep N`)

## Proofs

(frame paths, filled by the golden stream)
