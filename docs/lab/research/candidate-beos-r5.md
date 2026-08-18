# BeOS R5 (Professional Edition) — verified

**BeOS R5 5.0.3 on `qemu-system-x86_64 -accel tcg`, native VGA/VESA
framebuffer.** Tier 2, no bridge, no ROM. The deliberate **BeOS↔Haiku
pairing** with the `haiku` station already live in the gallery. Full guest
note: [`docs/guests/beos.md`](../../guests/beos.md).

**Status: bring-up done, interactive, not yet promoted.** Media sourced and
hashed, disk built, both real R5-under-QEMU blockers diagnosed and fixed,
station boots to a usable desktop under TCG. What was previously open
questions in this document are now closed — see below. Remaining: golden
bake/promotion, audio device choice, and builder-script automation.

## What the exhibit is

A visitor lands on BeOS's native desktop — Tracker, Deskbar, a Terminal — the
same three components a Haiku visitor sees, which is the point of the
pairing: Haiku is the open-source recreation, already live
(`registry/stations/haiku.json`); BeOS R5 is the original it recreates.

## Media — resolved

- **BeOS R5 Professional 5.0.3**, archive.org item
  `beos-5.0.3-professional-gobe` (the item this document previously pointed to,
  `beos-professional-edition-5.0.3`, no longer exists).
  `beos-5.0.3-professional-gobe.bin` (772,302,720 B,
  sha256 `1889fd6cf5af4259b01c9d1925e62f664effdf9dd88f924dc9b4da41ce1f0106`) +
  `.cue` (186 B, sha256
  `a57d9552cdadbbdbe6f608e8dbe9ac2bec2a010da1ad801fc0176e4d66bb234c`). Staged
  `/data/assets-staging/beos/` with `MANIFEST.sha256`.
- The item's download redirector returns HTTP 500; the fix is to resolve the
  direct storage-node URL from the item's own metadata JSON (`server`/`dir`
  fields), not to retry the redirector.
- Three MODE1/2352 tracks: track 1 is the bootable ISO 9660 `BeOS_Tools`
  installer/rescue CD, track 2 is the raw BFS `BeOS 5 Pro Edition` system
  volume (325 MB, this is what's installed), track 3 is other/PPC content,
  unused.
- No second source was checked, and none was needed — the one item was
  sufficient.

## Install — resolved (not the disc's own Installer)

QEMU cannot present a multi-track disc, so the disc's installer path is not
usable. Instead:

1. `sfdisk` a fresh disk image: one MBR partition, type `0xEB`, sector 63,
   bootable; MBR boot code from Haiku's `writembr`.
2. Create a fresh BFS filesystem in that partition and copy the track-2 BFS
   volume's files **with attributes** using a Haiku R1/beta5 helper VM (a
   sandbox clone of the `haiku` station's persistent disk, reached over ssh)
   — the only readily-available BFS-aware tooling on the box.
3. Boot the resulting disk **directly** (`-boot c`). Booting the CD's loader
   with the partition selected as boot volume also boots, but **ignores the
   volume's own kernel/vesa settings** — those are only honoured when BeOS's
   own on-disk boot loader starts the kernel.
4. Run BeOS's own `makebootable /boot` from a Terminal launched by
   `/boot/home/config/boot/UserBootscript`.

## The two blockers — root-caused and fixed

1. **ISA `config_manager/isa` calls the 16-bit PnP BIOS; SeaBIOS doesn't
   implement it.** Kernel page fault (`eip 8`) inside `input_server`'s devfs
   driver scan → `input_server` never starts → `Bootscript` hangs at
   `waitfor _input_server_event_loop_` → desktop shows only the flat colour,
   no cursor, no Tracker. Diagnosed via KDL's mirror to COM1 (serial always
   gets KDL output, regardless of video state). **Fix**: move the add-on to
   `config_manager_off/isa`.
2. **KVM traps the idle thread; TCG doesn't.** `-cpu pentium2`/`pentium3`
   under KVM → GPF (trap `0d`) in the idle thread almost immediately;
   `-cpu qemu32` gets further, still hangs. Under **TCG** `-cpu pentium3`,
   clean boot and interactive use. Consistent with an unhandled MSR read: KVM
   injects a real `#GP`, TCG's MSR path returns 0. **Fix**: ship on TCG only,
   same posture as `os2warp`. Which specific MSR is not identified — see open
   items.

Neither blocker is covered by the R5 boot menu's "Don't call the BIOS"
toggle.

## Device set — resolved

`qemu-system-x86_64 -accel tcg -M pc-i440fx-11.0 -cpu pentium3 -m 512 -smp 1
-rtc base=localtime`, one IDE raw/qcow2 disk, `-vga std` (R5's "stub/
unsupported" driver — dismiss the nag with Don't nag), `ne2k_pci` NIC
(`rtl8139` driver also present in R5 if ever needed), PS/2 keyboard + PS/2
relative mouse (BeOS applies its own acceleration; **`usb-tablet` absolute
pointer is not supported by R5** — this closes the pointer-mode open question
below in favour of PS/2 relative, not the guess of "needs an actual boot to
confirm" this document previously carried).

## Graphical target — resolved

`/boot/home/config/settings/kernel/drivers/vesa` = `mode 1024 768 16`, applied
via the volume's own settings tree — only takes effect on direct disk boot
(see Install above). Ready scene: 1024×768×16 blue desktop, Deskbar
top-right, Tracker, Terminal open from `UserBootscript`. Framebuffer-verified.

## Still open

1. **Audio device**: ES1370 (`es137x` driver) vs AC97 (`i801` driver) — not
   yet probed in-guest. Write "TBD" wherever the device set is quoted until
   resolved.
2. **Builder automation**: `scripts/build-guests/tiles/beos.sh` does not exist
   yet. The install recipe above is currently manual/interactive (partition,
   BFS create+copy-with-attributes via the Haiku helper VM, `makebootable`,
   settings write) and needs scripting before this is a from-scratch
   reproducible build like the Tier 1 native-x86 stations.
3. **Which MSR** triggers the KVM `#GP` is not identified. TCG sidesteps it;
   a real fix would let this station run accelerated like the rest of the
   fleet, but was out of scope for getting one exhibit interactive.
4. **Golden bake/promotion**: not done. See `docs/guests/beos.md` "Golden /
   reset".
5. **Second/Pro-disc driver coverage**: not needed — the one archive.org item
   was sufficient; no missing-driver symptom was observed.

## Effort, risk (final)

Landed at **small–medium**, matching the earlier MV-5/"works-known" estimate:
comparable in shape to the NT 3.51/4.0 native-x86 recipes, plus the two R5-
specific fixes above, which were well within a single bring-up session once
diagnosed via serial KDL output.
