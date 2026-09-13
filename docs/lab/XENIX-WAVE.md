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

Three, all on the framebuffer. Frames live in `/data/vms/sandbox/xenix/smoke/`.

### Wall 1 — SeaBIOS refuses every SCO Xenix floppy, and the obvious fix is wrong

`frame-boot1.png`: `Booting from Floppy... Boot failed: not a bootable disk`.
SCO Xenix boot floppies carry **no 0x55AA signature** at offset 510; SeaBIOS
requires one. Writing `55 AA` there gets past SeaBIOS and then fills the screen
with the letter `E` forever (`frame-boot2b.png`, `frame-pc.png`) — which looks
exactly like a disk-controller wall and is not one.

Disassembling the sector explains it
(`objdump -D -b binary -mi386 -Maddr16,data16 --stop-address=512 <img>`):

- `0x1E8` is the loader's INT13-error path — `mov ax,0x0500; int 0x10` then
  `mov ax,0x0e45` (teletype `'E'`), and it **returns instead of retrying**.
- `0x73..0x7E` is a directory scan: `mov si,0x1f8; mov cx,0xe; repz cmpsb` — it
  compares a **14-byte** filename, `"boot"` plus NUL padding, starting at
  **0x1F8**. Fourteen bytes from 0x1F8 runs to 0x205: **through 0x1FE/0x1FF and
  on into the next sector.** The signature we wrote lands inside the string the
  loader is looking for, so `boot` never matches, the scan walks off the end of
  the media, and every read from there on prints `E`.

**The fix is two bytes, not one:**

```
printf '\x55\xaa' | dd of=<floppy>.img bs=1 seek=510 conv=notrunc   # SeaBIOS
printf '\x06'     | dd of=<floppy>.img bs=1 seek=121 conv=notrunc   # mov cx,0xe -> 0x6
```

Offset 121 is the `cx` immediate of that `repz cmpsb`; shortening the compare to
six bytes (`"boot\0\0"`) leaves the match intact and still uniquely identifies
the entry. With both bytes patched the guest prints `XENIX System V` / `Boot :`
(`frame-boot3.png`). Patch a COPY — the pristine image stays as staged.

### Wall 2 — the WinWorld archive is two different machine classes in one set

Volume labels read straight out of the images (`strings <img> | head`):

| Image | label |
|---|---|
| `Installation 1/2/3.img` | `prd=xos typ=386PS rel=2.3.4q vol=N01..N03` |
| `Basic Utilities.img` | `prd=xos typ=n386 rel=2.3.4h vol=B01` |
| `Extended Utilities 1-4.img` | `prd=xos typ=n386 rel=2.3.4h vol=X01..X04` |

`386PS` is the **IBM PS/2 MicroChannel** build — the set's own `readme.txt` says
"For the MicroChannel BIOS" — and QEMU has no MicroChannel machine. Booted, that
kernel prints its banner and device table and dies:
`TRAP 00000008 in SYSTEM` / `kernel: PANIC: Double exception` (`frame-boot4.png`).
So the WinWorld set is **not installable as shipped**: its boot floppies are a
different machine class AND a different release letter from its utilities.

The usable boot media is the PCjs set the `xenix-media` runner found, staged at
labhost `/data/assets-staging/xenix/alt/extracted-pcjs-386-2.3.4h/` —
`N1-BOOT.img`/`N2.img` are `typ=386GT rel=2.3.4h`, and that kernel runs on the
same QEMU hardware all the way to `init` (`frame-gt2.png`).

### Wall 3 — OPEN: `no stack space`, because the kernel sees no hard disk

The 386GT kernel reaches `Entering System Maintenance Mode` and then loops
`-: no stack space` forever (`frame-gt2.png`, `sweep-mem8.png`). The early
banner (`ban-2.png`, `gtpc-3.png`) is the diagnosis:

```
device    address        vector  dma   comment
%fpu      -              35      -     type=80387
%floppy   0x03F2-0x03F7  06      2     unit=0 type=135ds18
%serial   0x03F8-0x03FF  04      -     unit=0 type=Standard nports=1
%parallel 0x0378-0x037A  07      -     unit=0
%console  -              -       -     unit=vga type=0
rootdev 2/64, pipedev 31/1, swapdev 31/0
mem: total = 16000k, reserved = 4k, kernel = 1860k, user = 14136k
nswap = 1000, swplo = 0, Hz = 50, maximum user process size = 14436k
```

**There is no `%disk`/`%hd` line** — the kernel has not attached a hard disk —
yet `pipedev` and `swapdev` are both major **31**, the hard disk. The maintenance
shell asks for stack, the kernel needs a swap reservation on a device that does
not exist, and it answers `no stack space`. Memory is not the problem: 14136k of
user memory is reported, and the symptom is byte-identical at `-m 8`
(`sweep-mem8.png`). `-machine pc,acpi=off` did not add the disk either
(`gtpc-3.png`) — same table, plus a second `%serial`.

Theories tested serially, each on the one rig, because `rig-clone.sh new`
refused all four clones at a labhost 1-min load of 59.06 (cap 50) — the race in
rule 14 was unavailable, not skipped:

| Theory | Frame | Result |
|---|---|---|
| `-m 8` | `sweep-mem8.png` | identical `no stack space` loop |
| `-m 16` | `frame-gt2.png` | identical |
| `-machine pc` vs `isapc` | `gtpc-3.png` | identical; still no `%hd` |
| `-cpu 486` (both above) | — | the 386PS TRAP 8 is media, not CPU |

**Tried and ruled out:** overriding the devices at the `Boot :` prompt.
`qmp-type.py --qmp <sock> 'fd(64)xenix root=fd(64) swap=fd(64) pipe=fd(64)\n'`
boots exactly as the bare `\n` does and loops `no stack space` unchanged
(`sw-final.png`) — this loader either ignores the extra words or the devices are
compiled into the kernel, so the swap device cannot be moved off the missing
hard disk from the prompt.

**Next commands, in order, for whoever picks this up:**

1. The 386GT boot floppy simply has no `hd` driver linked in —
   PCjs's own page warns this set's boot "is still being debugged". Get a third
   set: extract `Xenix386 2.3.4.rar` out of the already-staged
   `/data/assets-staging/xenix/sco-xenix-386-and-extras.rar`, which needs an
   `unrar` labhost does not have (its `7z` reports "Unsupported Method" on
   RAR3/PPMd). Check the extracted `N01`'s label for `typ=n386` — an AT-class
   boot floppy is what this station has never had. That archive also carries
   `xenix serials.txt`; the WinWorld set's own serial is `ING008637` /
   activation `mgzxcszg` (2-user licence), in its `serial.txt`.
2. Only then bake the golden. The device set in the launcher is the one every
   frame above was taken with; a change to it is a new checkpoint and a new
   restore proof (rule 6).

## Proofs

| Proof | State | Frame |
|---|---|---|
| first framebuffer | PASS | `frame-boot3.png` — `XENIX System V` / `Boot :` |
| kernel boots, device table | PASS | `ban-2.png` — `SysV release 2.3.4 91/03/22 for i80386` |
| multi-user / root shell | **FAIL (wall 3)** | `frame-gt2.png` |
| golden `savevm` + `loadvm` restore | NOT REACHED | — |
| typed-text keyboard proof | NOT REACHED | — |
| pointer | N/A — text console, `pointer: none` | — |

**This station is NOT landed and must not be.** There is no golden, so
`station-land.sh` has nothing to copy in; the registry row, launcher, fixture,
poster and scene rows are all committed and green on branch `xenix` for the next
session to finish from wall 3.
