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

## Resume checkpoint (2026-09-20 ~09:40Z)

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

**Exact resume command** (run when `ssh lab uptime` load is reasonable —
this wave's builds were reniced to 19, so the guest itself should no longer
be starved):

```bash
# from /data/vms/sandbox/linux012-work/repo
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
# then via scripts/dev/fb-wait.py: settle to first frame, send ONE clean
# "ret" (qmp send-key qcode "ret"), settle 8s, send ONE more "ret" for the
# "insert root floppy" prompt, then --change --settle 20 --timeout 180
# (a genuinely patient wait, not another 30-45s guess) before concluding
# it is a real second wall. If it settles on a root shell, capture that
# frame, THEN run scripts/dev/smoke-rig.sh linux012 --like minix2 to
# publish /os/linux012, then proceed to the gate + station-land.sh.
```

**Single next concrete step**: re-run the boot with ONE clean Enter per
prompt (not a key-blast — that theory is unconfirmed and adds noise) and a
patient (2-3 min) settle wait on an uncontended host, to settle whether
Stage 2 is a real wall or a starved poll.

**Quality gate status**: `spa` TS type-check (`npx tsc -b --noEmit`) is
clean on this branch. `shfmt`/`shellcheck` on every touched `.sh` file is
clean (re-run after `npm ci` in `spa/` was needed once, locally, to get
`node_modules` — that install is NOT part of this branch's diff).
`eslint`/`knip`/vitest not yet re-run after the latest commit — run them
before landing.
