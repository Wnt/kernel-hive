# xenix guest

SCO Xenix System V/386 2.3.4 (1989) — Microsoft's own Unix, licensed to SCO
in 1987 and for a while the most-installed Unix in the world. A pre-installed
disk boots straight to a text console; the exhibit is Multiscreen
(Alt-F1..Alt-F4), the feature Linux's virtual consoles copied a decade later.

## Identity and source

- Public ID / tile directory / SH_STATION: `xenix`
- Slot / UDP port / VMID: `202` / `54202` / `202`
- Sibling scaffolded from `freedos` (`--like freedos`)
- Media: a **pre-installed** disk, not a floppy install —
  `https://archive.org/download/sco-xenix-386-master/SCO%20Xenix%20386%20Master.zip`
  (item `sco-xenix-386-master`), sha256
  `cd5756f07e1ef3b099ff29609c89c2f09baa9aae59d287ba486f2bbd4426545f`,
  326,021,752 bytes. Member `Master/Xenix Master-disk1.vdi` (VirtualBox VDI,
  125 MiB virtual, 133,169,152 bytes) converted with `qemu-img convert -O
  qcow2` to `/data/gallery-guests/Xenix/xenix.qcow2`. Serial `oli560966` in
  the kernel banner; `root` has no password; `/usr` carries `lotus`, `vpix`,
  `games`, `mud`, `sysadm`.
- Provenance-only (NOT used to build the golden): the WinWorld "386 2.3.4q"
  install set is a **mixed** set — its `Installation` floppies are
  `typ=386PS` (IBM PS/2 MicroChannel), which panics under QEMU
  (`TRAP 00000008` / `Double exception`) because QEMU has no MicroChannel
  machine. The usable boot media for a from-floppy install, if anyone picks
  that up, is the PCjs `typ=386GT rel=2.3.4h` set staged at labhost
  `/data/assets-staging/xenix/alt/extracted-pcjs-386-2.3.4h/`.

## Device set

`qemu-system-i386 -machine isapc -cpu 486 -enable-kvm -m 16 -vga std`, one
IDE disk at `/data/gallery-guests/Xenix/xenix.qcow2` with **auto** geometry
(the guest's own device table reports `cyls=253 hds=16 secs=63` — do not put
explicit CHS on the `-drive`; QEMU 11 rejects it for qcow2), SB16 (ISA)
audio, no NIC, no PCI bus at all.

**KVM is load-bearing, not a default.** `-machine isapc` and `-cpu 486`
reflect real 1989 hardware limits (no PCI, no Pentium+ feature bits Xenix 386
understands), but the accel choice is the one fact worth repeating: under
`-accel tcg` this exact kernel boots, prints its banner, and then **every
`exec` in the guest dies with `no stack space`** — reproduced identically on
the install floppy and on this pre-installed disk, so it is a QEMU TCG i386
protected-mode defect, not the media. Under `-enable-kvm`, unchanged
otherwise, the same disk reaches a root shell in about 25 s. See
`docs/lab/XENIX-WAVE.md` Wall 3 for the full elimination sweep.

## Pointer and input

None — Xenix text console, no mouse device, no pointer affordance. Keyboard
runs the fleet pacing floor of 40 ms send / 40 ms flush.

## Boot path

Cold boot (first time only, image captured mid-run by its author) finds the
root filesystem dirty: `Proceed with cleaning (y/n)?` — answer `y`, let fsck
finish. Then RETURN at `(or give root password for system maintenance):` (no
password) reaches `Entering System Maintenance Mode`, RETURN again at `TERM =
(ansi)` reaches `#`. A clean cold boot after that (post `sync;
/etc/haltsys`) skips fsck entirely and reaches `#` in about 25 s — that is
the state the golden captures.

Kernel banner:

```
SysV release 2.3.4 91/03/22 for i80386 Serial Number: oli560966
%disk 0x01F0-0x01F7 36 - type=W0 unit=0 cyls=253 hds=16 secs=63
```

## The exhibit

`uname -a`, `who`, `ls /usr` — a plain System V shell. Then **Alt-F2**, the
one thing a visitor cannot guess from a bare prompt: a second, independent
Multiscreen login on the same kernel, switched back with **Alt-F1**. That is
the feature worth the trip.

## Retronet

**OPEN.** SCO TCP/IP for Xenix was a separate product with its own media and
licence; the base 2.3.4 install set has no TCP/IP stack, no browser, no IM
client. The launcher ships **no NIC at all**, and per AGENTS.md rule 15 no
`rn-tapnet.sh` is committed. Next step for whoever picks this up: source SCO
TCP/IP 1.2.x for Xenix 386, add the NIC to the device set, and **re-bake the
golden** — a new NIC is a device-set change, a new checkpoint, a new restore
proof (rule 6).

## Reset

`loadvm golden` — see `streamhost/stations/xenix/qemu-streamhost.sh`.

## Wall hit and abandoned (floppy install path)

SCO Xenix boot floppies carry no `0x55AA` signature at offset 510, so SeaBIOS
refuses them outright. Writing that signature alone is not enough: the
boot-sector directory scan at `0x73..0x7E` compares a 14-byte filename
starting at `0x1F8`, which runs through `0x1FE`/`0x1FF` and into the
signature just written, so `boot` never matches and the loader walks off the
end of the media, printing `E` forever. The two-byte fix is `55 AA` at
offset 510 **and** shortening the compare length (the `cx` immediate of the
`repz cmpsb`) from `0x0e` to `0x06` at offset 121. This route was used only
to identify boot media, not to build the golden — the golden ships from the
pre-installed disk above, so this walk is provenance, not a live install
path.

## Checkpoint

Baked 2026-09-13. Golden `savevm golden` taken at the System Maintenance
Mode root shell reached by the boot path above, on the device set in this
doc — device set + checkpoint + binary are one combination (AGENTS.md rule
6). resetMode: `loadvm`.

Fixture: a logged-in root `#` shell in System Maintenance Mode, keyboard-
reactive caret, no screensaver/DPMS/monitor-blank.

Restore proof (framebuffer): `loadvm golden -S` + `cont` returns to the same
`#` (`bake/r1-restored.png`); `uname -a; who am i; ls /usr` typed after the
restore echoed correctly (`machine=i80386`, `serial#=560966`, the `/usr`
listing) — this doubles as the keyboard proof (`bake/r2-typed.png`).

Unproven: Multiscreen (Alt-F2 second session) was not raced on the
framebuffer this wave; pointer is N/A (text console, no mouse device).
