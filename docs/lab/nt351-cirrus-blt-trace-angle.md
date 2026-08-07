# NT 3.51 hi-res Angle A — Cirrus BLT trace and targeted fix

Investigation date: 2026-07-28. Verdict: **PASS**.

The production candidate is
`streamhost/qemu-patches/0004-cirrus-blt-rop1-fill.patch`. It fixes one
source-independent Cirrus ROP without changing the normal copy, overlap-copy,
color-expand, or display-invalidation paths.

The diagnostic-only instrumentation is
`streamhost/qemu-patches/cirrus-blt-trace.patch`. With
`QEMU_CIRRUS_BLT_TRACE=1`, it records every BLT's source and destination
offset, width, height, effective signed source and destination pitch, ROP,
pixel width, raw mode, direction, transfer kind, and operation class.

## Root cause

The corruption is not a wrong overlap direction, 16bpp stride, ROP
implementation, or missing display invalidation. It is a valid
source-independent ROP1 fill being rejected by source validation.

The trace for the first PageDown includes a conventional scroll and full
clear:

```text
src=0x0014a060 dst=0x0002c060 w=1904 h=16  spitch=2048 dpitch=2048 rop=0x0d bpp=16 mode=0x10 dir=forward  transfer=video-to-video op=copy
src=0x00180800 dst=0x00034060 w=1904 h=572 spitch=2048 dpitch=2048 rop=0x0e bpp=8  mode=0x00 dir=forward  transfer=video-to-video op=copy
```

NT then composes the individual 16-pixel text rows as:

```text
src=0x00180800 dst=0x0003c060 w=1904 h=16 spitch=16 dpitch=2048 rop=0x0e bpp=8  mode=0x00 dir=forward transfer=video-to-video op=copy
src=0x00180800 dst=0x00180a90 w=28   h=16 spitch=16 dpitch=28   rop=0x0d bpp=8  mode=0x04 dir=forward transfer=cpu-to-video   op=copy
src=0x00180a90 dst=0x0003c080 w=448  h=16 spitch=28 dpitch=2048 rop=0x0d bpp=16 mode=0x98 dir=forward transfer=video-to-video op=color-expand
src=0x00180800 dst=0x00044060 w=1904 h=16 spitch=28 dpitch=2048 rop=0x0e bpp=8  mode=0x00 dir=forward transfer=video-to-video op=copy
```

Cirrus ROP `0x0e` is ROP1: every destination bit becomes one and the source is
irrelevant. The NT driver legitimately leaves the source pitch at the previous
glyph-upload width (typically 8–72 bytes) when asking it to clear a
1904-byte-wide text row.

QEMU routes video-to-video ROP1 through the generic generated forward ROP
helper in `hw/display/cirrus_vga_rop.h`. That helper performs:

```c
srcpitch -= bltwidth;
if (bltheight > 1 && (dstpitch < 0 || srcpitch < 0)) {
    return;
}
```

For a 1904-byte row and a stale 16-byte source pitch, the helper returns
without writing anything. The following color-expand draws new glyphs over the
uncleared old row, exactly producing the accumulating PageDown text.

The window-drag trace independently proves that the backward overlap path is
active and is not the cause:

```text
src=0x0015bfdf dst=0x00161fff w=1928 h=654 spitch=-2048 dpitch=-2048 rop=0x0d bpp=16 mode=0x11 dir=backward transfer=video-to-video op=copy
src=0x00161fdf dst=0x00167fff w=1896 h=654 spitch=-2048 dpitch=-2048 rop=0x0d bpp=16 mode=0x11 dir=backward transfer=video-to-video op=copy
```

These copies remain on the existing implementation and render cleanly with
the patch.

## Targeted fix

For forward or backward ROP1 only, the patch:

1. validates the destination VRAM region but not the unused source region;
2. routes the operation through QEMU's existing source-independent
   `cirrus_fill` implementation for ROP1;
3. normalizes the starting address of a backward operation to the left edge.

All other ROPs still call the existing generic forward/backward helper.
`cirrus_do_copy()` still calls `cirrus_invalidate_region()` afterward, so the
display-dirty behavior is unchanged.

## Local pve-qemu build

The reusable assembled source was:

```text
/data/vms/qemu-fastpoll-build.1784076046-22671/pve-qemu/pve-qemu-kvm-11.0.2
```

It is `pve-qemu-kvm 11.0.2-1`, PVE packaging commit
`f17b668feb67097891a5f7012a99bcc1687c2584`, QEMU submodule
`e545d8bb9d63e9dd61542b88463183314cff9482`, with existing PVE patches plus
gallery fast-poll, Sphinx serialization, and gallery-hid already applied.

The exact incremental experiment was:

```sh
clone=/data/vms/soltest/qcirrus-trace-20260728T015851Z-428914
source=/data/vms/qemu-fastpoll-build.1784076046-22671/pve-qemu/pve-qemu-kvm-11.0.2
build=$clone/build/pve-qemu-kvm-11.0.2

cp -a --reflink=always "$source" "$build"
patch -d "$build" -p1 < streamhost/qemu-patches/cirrus-blt-trace.patch
ninja -C "$build/build" qemu-system-x86_64
cp "$build/build/qemu-system-x86_64" \
  "$clone/build/qemu-system-i386-trace"

# Capture the failing baseline, then add only the candidate fix.
patch -d "$build" -p1 < \
  streamhost/qemu-patches/0004-cirrus-blt-rop1-fill.patch
ninja -C "$build/build" qemu-system-x86_64
cp "$build/build/qemu-system-x86_64" \
  "$clone/build/qemu-system-i386-trace-rop1fix"
```

The locally built test binary is:

```text
c616b103fabd11131fcacc9d9be29403a19e966475c58204bddf150189136385  qemu-system-i386-trace-rop1fix
QEMU emulator version 11.0.2 (pve-qemu-kvm_11.0.2-1)
```

The box's `qemu-system-i386` is the same multi-target executable as
`qemu-system-x86_64`; the uniquely named local copy above was used directly.
No package was installed and no system or production-tile QEMU was restarted.

For a production `.deb`, insert
`0004-cirrus-blt-rop1-fill.patch` after the current final patch as
`debian/patches/pve/0050-cirrus-blt-rop1-fill.patch`, append that path to
`debian/patches/series`, run `quilt push -a`, then:

```sh
dpkg-buildpackage -b -us -uc
```

That preserves the PVE-only snapshot state and every already carried patch.
Deployment and the fleet regression sweep are intentionally outside this
isolated experiment.

## Acceptance evidence

The isolated clone and build directory were:

```text
/data/vms/soltest/qcirrus-trace-20260728T015851Z-428914/
/data/vms/soltest/qcirrus-trace-20260728T015851Z-428914/build/pve-qemu-kvm-11.0.2/
```

The repeatable scripts are:

- `scripts/dev/nt351-cirrus-trace-launch.sh`
- `scripts/dev/nt351-cirrus-trace-acceptance.sh`
- `scripts/dev/nt351-cirrus-trace-regression.sh`

The acceptance launcher used `isapc`, `cpu 486`, and
`isa-cirrus-vga,global-vmstate=on`, with no display frontend. Its QEMU argv
started with the exact local binary above and referenced only the namespaced
clone disk, QMP socket, and pidfile.

Each of three resets to the candidate `golden` did all of the following:

1. proved a `1024 768` QMP PPM surface;
2. opened guest Display Settings and captured `65536 Colors`;
3. opened `README.WRI`, issued PageDown ten times, and captured every page;
4. dragged the window diagonally in three passes across the desktop icons,
   capturing intermediate and settled frames;
5. closed the window (discarding the Write save prompt), reopened it over the
   icons, and closed it again;
6. moved the File Manager icon from the left side of the group to the far
   right.

There are 96 run PNGs (32 per repeat). All were inspected in the three complete
contact sheets `qcirrus-final-run-{1,2,3}.png`. No stale text, overlapping
glyphs, window fragments, or icon damage is visible.

The three guest mode/depth captures are byte-identical:

```text
1b91a3859fc51406ce5acc4595d5e001d50cabc7643c7d75392bfc3994713753
```

The three PageDown-ten captures are byte-identical and clean:

```text
2556c95adf160d0cf6165e6ebac1f91cd39f6d682f4bcf56ff45fe4b8c9281ed
```

For comparison, the unpatched PageDown-ten captures were visibly corrupt and
had:

```text
0bc20030a11de9cbc882f8860c3565c585605eee444105c48b360f4774d2f5a0
```

The exact baseline and fixed BLT streams are retained as:

```text
/data/vms/soltest/qcirrus-trace-20260728T015851Z-428914/qemu-baseline.log
/data/vms/soltest/qcirrus-trace-20260728T015851Z-428914/qemu-final.log
```

Their SHA-256 hashes are:

```text
e451f8d47f48dc40d8021adb7d5f0f081c850ee06b47942ae4a8011af9cbbc92  qemu-baseline.log
5462727d1c44b5ae63681416d16a09ea597775792d91945b637f84542c7afdb8  qemu-final.log
```

`acceptance-baseline/trace-ranges.tsv` and
`acceptance-trace/trace-ranges.tsv` give the exact inclusive line range for
every PageDown, drag, open/close, and icon-move action. For example, fixed run
1 PageDown is lines 13899–15012 and its three drag passes are 15018–15182,
15183–16252, and 16253–16385. The run-1 PageDown range contains 1,114 BLTs:
700 ordinary copies and 414 color expands, with 369 ROP1 operations.

`acceptance-trace/evidence-manifest.sha256` hashes every raw PPM, PNG, contact
sheet, and trace-range index.

## Regression evidence

A second isolated clone used a reflink copy of the current clean NT 3.51
640x480 golden and the exact same local fixed binary:

```text
/data/vms/soltest/qcirrus-trace-20260728T015851Z-428914-regression640/
```

`regression-640/` contains the clean golden desktop, opened README, README
after PageDown ten, and restored desktop in both raw PPM and PNG form. All four
were inspected together in `qcirrus-regression-all.png`; its SHA-256 is:

```text
42ccc035bb39b66845b5dcfb943971d8afbb0b64c480f8a5b365bcf32fbcdd6b
```

The isolated QEMUs were stopped through `clone-guard`; both clone directories
and all evidence were retained.
