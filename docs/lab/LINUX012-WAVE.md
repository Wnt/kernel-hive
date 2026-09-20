# linux012 wave notes — Linux 0.12 (issue #54)

Station: `linux012` · slot/udp/vmid 205 (wave.sh alloc, session `linux012-work`) ·
scaffolded `--like minix2 --tuple pizzaBoxB,crtF,keyboardH,paramMouseG`.

## Media — measured, pinned

The seed doc (`docs/lab/integration-seeds/linux012.md`) pointed at
`Linux-0.12/images/` for the raw `-20040306` repackaged floppies. That path
only has the `.Z`-compressed originals. The raw repackaged pair the seed
actually wants lives one directory up, at the `Linux.old/images/` root:

| file | bytes | sha256 | source |
|---|---|---|---|
| `bootimage-0.12-20040306` | 150016 | `1df233ade3c71b6622b138622c81128460e84351b80ee7d54fb4fdad71e05425` | `https://mirror.math.princeton.edu/pub/oldlinux/Linux.old/images/bootimage-0.12-20040306` |
| `rootimage-0.12-20040306` | 1474560 | `4e79e37b074f2ed1de5aea212e282b6970c41d1c731903aa01ff1431b8ea0713` | `https://mirror.math.princeton.edu/pub/oldlinux/Linux.old/images/rootimage-0.12-20040306` |

Also fetched and hashed (NOT used — the compressed originals, kept here only
because they were staged during the wall investigation):

| file | bytes | sha256 |
|---|---|---|
| `bootimage-0.12.Z` | 70345 | `ec4daef983b6595ca83ea4563f415e9492c0f5bc198cadea174df63a0eacb5ed` |
| `rootimage-0.12.Z` | 825931 | `4d8d9851c01ad9df3da1038ac9c0c131e17cb61589cbd9399fc7fa26f5b58537` |

`scripts/build-guests/tiles/linux012.sh` fetches, hashes and pads the boot
floppy (see below) into `assets/linux012/{boot,root}.img`.

## Boot wall — what the framebuffer actually showed

Command (TCG, no KVM needed per the seed):

```
qemu-system-i386 -m 8 \
  -drive file=boot.img,format=raw,if=floppy,index=0,readonly=on \
  -drive file=root.img,format=raw,if=floppy,index=1,readonly=on \
  -boot a -display none -vga std -qmp unix:qmp.sock,server=on,wait=off
```

**Stage 1 — the raw (unpadded) 150016-byte boot image never gets past
`Loading.............`.** `info registers` on QMP showed EIP frozen bit-for-
bit at `9020:0132` across repeated samples seconds apart — a real spin, not
a slow one. Disassembly at that address (`xp /32xb`) decodes to
`IN AL,0x60 / CMP AL,0x82 / JB back` — the classic Linux 0.12 keyboard-flush
loop, waiting for a release-code byte. This reproduced identically across
every accelerator/machine-type theory raced (`-enable-kvm`, `-M isapc`,
`-M pc-i440fx-5.2`, `-global isa-fdc.fdtypeA=144`) — all four produced the
EXACT same frozen frame, which ruled out timing/accelerator as the cause.

**Fix that changed the outcome:** zero-padding the boot image to a full
1.44M floppy (`truncate -s 1474560`) plus injecting several distinct QMP
`send-key` events (a single `ret` alone was not reliably enough — see below)
let the CPU advance past this exact address into
`Press <RETURN> to see SVGA-modes available or any other key to continue.`,
then into kernel init messages (`copy_to_cooked: missing queues` x4,
`8 virtual consoles`, `4 pty's`), then to `Insert root floppy and press
ENTER`. Frame evidence: `/data/vms/sandbox/linux012-work/smoke6/fb-after-key.png`.

**Stage 2 — `Insert root floppy and press ENTER` has NOT been proven to
reach a shell in this wave.** Multiple theories raced, none conclusively
resolved it before the box's load spiked (see below):
- repeated plain `ret` (1x, 6x, HMP `sendkey ret 1000`): no visible change
- diverse key blast (`ret`,`spc`,`shift`, repeated, some runs mixed with
  `a`/`b`/`root` typed text): text echoes on screen character-by-character
  (frame `smoke9/fb2.png` shows `a` then `b` on their own lines under the
  prompt) but no further boot message appears
- QMP `eject` + `blockdev-change-medium` swapping floppy0 from the boot
  image to the root image (mimicking the historical single-drive floppy
  swap dance), then the same key blast: same result, frame
  `smoke10/fb2.png` — an extra blank prompt line, no further progress
- `info registers` sampled seconds apart during these waits shows EIP
  genuinely moving (`0x78dd` / `0x682b` / `0x6e91`, CPL alternating 0/3),
  i.e. the CPU is doing real work (a syscall loop), not spinning on a fixed
  address the way Stage 1 was — this is NOT the same class of wall as Stage 1.

**Confound found late: labhost load was 116–133 against the documented cap
of 50 for most of Stage 2's investigation** (`ssh lab uptime`, wave
coordinator flagged this independently and stood four workers down). A TCG
guest under that much host contention can appear to hang for minutes while
actually just running at a small fraction of real time. Stage 2's "no
visible change" reads are NOT trustworthy evidence of a real guest wall —
they may just be starved polls. Stage 1's readings ARE trustworthy (EIP was
read as bit-identical across samples, which host slowness does not explain
the same way, and the fix — padding + keys — produced an immediate,
reproducible unstick).

## What is proven vs open

- PROVEN: the two-floppy image set is correct and pinned (hashes above).
- PROVEN: the boot floppy must be padded to 1474560 bytes for the guest to
  progress past the SVGA-mode prompt under this fleet's QEMU.
- PROVEN: real guest pixels reach the framebuffer through kernel init
  (`8 virtual consoles`, `4 pty's` — genuine Linux 0.12 boot text, not a BIOS
  message).
- OPEN: whether `Insert root floppy and press ENTER` is a real second wall
  (needs a still-uncontended host to re-test with a clean, single, well-
  paced `ret` and a multi-minute settle) or was mis-read under host load.
- OPEN: root shell scene, `uname`/`ps`/`ls` demo, reset proof, poster hero,
  keyboard-pacing measurement — none attempted yet, blocked on Stage 2.

## Status

NOT landed. `/os/linux012` smoke-rig publish not yet done — station has not
reached a scene worth publishing (still mid-boot prompt). Registry scaffold
(commit `b00f20c6`, this doc alongside it) is pushed to `origin/linux012-work`
so the work is not stranded; land/station-land.sh is deferred until Stage 2
is resolved or the stop-rule clock runs out.
