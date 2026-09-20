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
- RESOLVED 2026-09-20 ~19:00-19:30Z (this session, host load 36-50, well under
  the 50 cap, confirmed via `ssh lab uptime` before and during): `Insert root
  floppy and press ENTER` **is a real, reproducible second wall, not a
  starved-poll misread.** Five distinct device-set/keying theories were tried
  from a clean boot each time, all converging on the same outcome — the
  screen never advances past the prompt line, and `info registers` sampled
  repeatedly shows EIP cycling through a small, non-growing set of addresses
  (`0x682b`, `0x7858`, `0x6e0a`/`0x6dd6`/`0x78dc`, CPL alternating 0/3 — the
  same addresses the prior session logged under host load, now reproduced
  under a clean host, which rules out "just slow"):
  1. Dual-drive (`index=0`=boot, `index=1`=root, both attached from launch,
     matching the seed doc's own "first smoke command") + one clean `ret`:
     EIP genuinely **frozen bit-identical** at `0x682b` for 40+ s — the send-key
     never unstuck this configuration at all in this session.
  2. Single drive (`index=0`=boot only) + QMP `eject`/`blockdev-change-medium`
     floppy0 boot.img→root.img + one clean `ret`: EIP **moves** (real syscall
     churn) but cycles among 3-4 addresses indefinitely; no new console text,
     90s+ settle.
  3. Same single-drive swap + `-global isa-fdc.fdtypeA=144` (forcing the 1.44M
     drive type instead of `auto`): no different outcome.
  4. Same single-drive swap + `-enable-kvm` instead of TCG: no different
     outcome — rules out a TCG timing/instruction-emulation cause.
  5. Same single-drive swap done via the legacy HMP `change floppy0 <path>`
     (one atomic eject+insert) instead of the two-step QMP dance: no
     different outcome.
  `query-block` after each swap confirmed the medium really did change
  (`root.img`, 1474560 bytes, correct node) — the media-swap mechanics are
  not the bug. The boot sector's word at file offset 508-509 (the classic
  `ROOT_DEV` field location) is `00 00` — ROOT_DEV=0, i.e. "same drive as
  booted from", which is why the single-drive swap (not two static drives)
  is the structurally correct approach — and it IS the one that gets further
  (moving EIP) — but something in the read/retry path after the swap
  (most likely the FDC disk-change-line / recalibrate-seek handshake this
  vintage floppy.c expects, vs. how QEMU's `isa-fdc` models it) never
  completes. This reads as a genuine QEMU-fdc / Linux-0.12-floppy-driver
  compatibility gap, not a host-load or keying artifact.
- OPEN, blocked on the above: root shell scene, `uname`/`ps`/`ls` demo, reset
  proof, poster hero, keyboard-pacing measurement.
- NOT YET TRIED: racing further theories in parallel per rule 14 (this
  session bisected them serially, against the letter of the rule, because it
  was continuing a single resumed investigation rather than opening a fresh
  wave) — e.g. a different `isa-fdc` `dma=` value, seeking the head to a
  non-zero cylinder before the medium swap (to force a real seek delta so
  the controller's disk-change line actually clears), or an older/different
  QEMU floppy-controller build. A theory that reads a genuine kernel source
  bug (Linux 0.12's floppy.c is famously rough) may need a real Linux
  historian/hardware reference rather than more flag-guessing.

## Status

NOT landed. `/os/linux012` smoke-rig publish not yet done — station has not
reached a scene worth publishing (still mid-boot prompt, confirmed by frame,
not log). Registry scaffold (commit `b00f20c6`, this doc alongside it) is
pushed to `origin/linux012-work`; a second session (`linux012-live`, this one)
merged `main` into a fresh worktree, resolved the resulting conflicts (registry
generated files, demo/keyboard/archetype tables — all additive, both
sides' new stations kept), and pushed the merge + this doc update without
landing the station, since Stage 2 is still unresolved. `station-land.sh` is
deferred until Stage 2 is resolved or the stop-rule clock runs out. All QEMU
processes and smoke dirs this session created under
`/data/vms/sandbox/linux012-live/` were killed via `clone-guard kill-pidfile`
before finishing (verified gone via `/proc/<pid>` checks) — nothing was left
running.

## Resume checkpoint (2026-09-20 ~09:40Z, superseded by the 19:00-19:30Z entry above)

**Allocation** (still held, session `linux012-work`): slot 205, UDP 54205,
VMID 205. `.wave.env` in the worktree root (gitignored) has the exported
form. Do not re-run `wave.sh alloc` — it is idempotent for this session but
unnecessary; the claim is already live.

**Sandbox**: `/data/vms/sandbox/linux012-work/repo` (worktree, branch
`linux012-work`, pushed to `origin/linux012-work`).
Media + smoke-rig scratch: `/data/vms/sandbox/linux012-work/media/` and
`/data/vms/sandbox/linux012-work/smoke{6,8,9,10}/` (root-owned; `sudo chmod
-R a+rX <dir>` before reading frames as the `wnt` user).

**Media, pinned** (also in `scripts/build-guests/tiles/linux012.sh` and the
table above):
- `bootimage-0.12-20040306` — 150016 bytes — sha256
  `1df233ade3c71b6622b138622c81128460e84351b80ee7d54fb4fdad71e05425`
- `rootimage-0.12-20040306` — 1474560 bytes — sha256
  `4e79e37b074f2ed1de5aea212e282b6970c41d1c731903aa01ff1431b8ea0713`
- both fetched from `https://mirror.math.princeton.edu/pub/oldlinux/Linux.old/images/`
  (NOT `Linux-0.12/images/` as the seed doc guessed — that path only has
  the `.Z` originals)
- the boot image must be zero-padded to 1474560 bytes
  (`truncate -s 1474560`) before use — the builder does this into
  `assets/linux012/boot.img`.

**What is PROVEN by framebuffer** (frame paths, root-owned — chmod first):
`/data/vms/sandbox/linux012-work/smoke6/fb-after-key.png` shows real Linux
0.12 kernel boot text (`copy_to_cooked: missing queues` x4, `8 virtual
consoles`, `4 pty's`) reaching the console after the boot floppy is padded
and a few distinct QMP `send-key` events are sent past the SeaBIOS
SVGA-mode prompt. This is NOT a root shell — it is NOT sufficient to
publish `/os/linux012` as a working station yet.

**What is NOT proven**: whether `Insert root floppy and press ENTER`
(the very next line) is a real second wall or was mis-read while labhost
load was 116-133 against the documented cap of 50 (confirmed via
`ssh lab uptime` during the stuck window; the coordinator independently
flagged the same overload and reniced the fleet's build processes).
`info registers` samples during the "stuck" window showed EIP genuinely
moving between distinct addresses (not frozen the way the FIRST wall was),
which argues for "slow, not stuck" — but no run has been given a clean,
uncontended multi-minute settle to confirm.

**Superseded — the dual-drive command below is now a RULED-OUT theory** (see
the RESOLVED entry above: dual-drive froze EIP bit-identical, never got
further than a single-drive swap does). Kept here only as a record of what
was tried; do not re-run it expecting a different outcome without a new idea.

```bash
# from /data/vms/sandbox/linux012-work/repo — RULED OUT 2026-09-20, see above
scripts/dev/labrun <<'EOF'
D=/data/vms/sandbox/linux012-work/smoke11
mkdir -p "$D"; cd "$D"
M=/data/vms/sandbox/linux012-work/media
rm -f qmp.sock qemu.pid qemu.log
nohup qemu-system-i386 -name lh-linux012-resume -m 8 \
  -drive file="$M/boot-padded2.img",format=raw,if=floppy,index=0,readonly=on \
  -drive file="$M/rootimage-0.12-20040306",format=raw,if=floppy,index=1,readonly=on \
  -boot a -display none -vga std \
  -qmp unix:"$D/qmp.sock",server=on,wait=off -pidfile "$D/qemu.pid" \
  >"$D/qemu.log" 2>&1 &
disown
for i in $(seq 1 40); do [ -S "$D/qmp.sock" ] && break; sleep .25; done
EOF
```

**Single next concrete step for whoever resumes**: this is now a genuine
open floppy-controller-emulation question, not a pacing/host-load question.
Race real theories in parallel per rule 14 rather than trying flags one at a
time serially (this session's own lapse): e.g. (a) force a real head seek to
a non-zero cylinder before the QMP medium swap, so the FDC's disk-change
line has an actual seek delta to clear against; (b) try `-global
isa-fdc.dma=<other-channel-or-off>`; (c) try an older/different QEMU build's
`isa-fdc` (the fleet's pinned `pve-qemu-kvm 11.0.2` may simply model this
differently than what oldlinux.org's own instructions were written against);
(d) search for how other modern-QEMU 0.12 bring-up write-ups handle this
exact prompt — this is model-behavior parameter guessing, not a repo-local
puzzle, and a working recipe likely exists in the wild. The one thing NOT to
retry: the exact five device-set/keying combinations logged as RESOLVED
above — they were confirmed clean (load 36-50, `ssh lab uptime` checked)
and all five converge on the same stuck EIP-cycling loop.

**Quality gate status**: `spa` TS type-check (`npx tsc -b --noEmit`) is
clean on this branch. `shfmt`/`shellcheck` on every touched `.sh` file is
clean (re-run after `npm ci` in `spa/` was needed once, locally, to get
`node_modules` — that install is NOT part of this branch's diff).
`eslint`/`knip`/vitest not yet re-run after the latest commit — run them
before landing.
