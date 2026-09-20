# Integration seed — Linux 0.12

Tracking: #54  
Prep branch: `linux012`  
Exhibition copy: `docs/lab/spa-drafts/linux012.md`

## Proposed station shape

- **station id:** `linux012`
- **runtime:** QEMU x86 text console
- **closest sibling:** `minix2`
- **archetype:** `beige-ibm-pc`
- **pointer:** none
- **audio/network:** none for first wave
- **reset:** relaunch is sufficient; loadvm may be added only if it materially improves latency

This should be one of the cheapest integrations in the epic.

## Start here

```bash
scripts/dev/wt.sh new linux012-work --from origin/linux012
cd ../linux012-work
scripts/dev/wave.sh alloc linux012
python3 scripts/stations-registry.py new linux012   --like minix2 --production --slot auto
```

Keep the Minix text-console shape but replace all disk/device assumptions.

## Media acquisition

Exact mirrored images:

Base directory:
- https://mirror.math.princeton.edu/pub/oldlinux/Linux.old/Linux-0.12/images/

Use the 2004 repackaged raw images if present:
- `bootimage-0.12-20040306`
- `rootimage-0.12-20040306`

If only compressed `.Z` forms are available, decompress during the builder and hash both source and resulting raw images.

Secondary reference:
- https://oldlinux.org/

## First smoke command

```bash
qemu-system-i386   -m 4M   -drive file=bootimage-0.12-20040306,format=raw,if=floppy,index=0   -drive file=rootimage-0.12-20040306,format=raw,if=floppy,index=1   -boot a
```

Use TCG first. KVM is unnecessary for a 1992 386 workload and can introduce CPU-feature differences.

If modern QEMU's default machine confuses the kernel, switch to the simplest old-PC shape available in the fleet before changing images.

## Builder target

`scripts/build-guests/tiles/linux012.sh` should:

1. fetch pinned boot/root images
2. decompress if necessary
3. verify byte size/hash
4. stage immutable copies under `assets/linux012/`
5. generate no install disk — the two floppies **are** the exhibit

## Intended rest scene

Boot to a root shell and leave:

```
uname -a
ps
ls /
```

visible above the prompt.

If the historical image requires a login, automate only that login sequence; do not replace the original root filesystem.

## Demo program

A good one-button demo is a typed shell sequence rather than a custom program:

```sh
cd /usr/src 2>/dev/null || cd /
pwd
ls
ps
```

Keep it short enough for the early keyboard scan rate.

## Proof checklist

- [ ] two-floppy boot works on fleet QEMU
- [ ] keyboard 40/40 test passes at fleet pacing or measured slower value
- [ ] root shell reaches deterministic scene
- [ ] relaunch/reset returns to the same scene
- [ ] poster explicitly links Minix → early Linux → later Linux stations
