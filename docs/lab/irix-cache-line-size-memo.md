# `osd_get_cache_line_size()` is called once per compiled DRC block

Measured 2026-08-03 on the lab box (`labhost`, Debian trixie, 16 logical CPUs),
MAME `indy_4610`, one R4600, 256 MB, IRIX 6.5.22, golden v3
(`368fcfb9b56fb4165a4e456238dc1a18`), `-video none` + shm publish, `-sound none`,
`-frameskip 6`, `-nothrottle`, pinned to core pair 1,9.

Patch: `scripts/build-guests/patches/mame-osd-cache-line-size-memo.patch`.
Work dir on the box: `/data/vms/soltest/cacheline-memo-3d91/`.

## The defect

`src/devices/cpu/drcbex64.cpp` `generate()` calls `osd_get_cache_line_size()`
unconditionally, and uses the answer only to build the block-start alignment
mask. On Linux `src/osd/modules/lib/osdlib_unix.cpp` implements that as
`fopen`/`fscanf`/`fclose` on
`/sys/devices/system/cpu/cpu0/cache/index0/coherency_line_size`, with no cache
anywhere. So the recompiler re-reads a constant out of sysfs every time it emits
a block. Upstream since ff92d10a048; `drcbearm64.cpp` has the same call site.

## The call rate — uprobes on the shipped binary, no instrumented build

The production binary is unstripped, so three kernel uprobes placed by **raw ELF
offset** count exact events with zero rebuild. `perf probe`'s own symbol
resolution fails on these names (it reads C++ `::` as a line number), so write
the events directly:

```
B=/data/vms/streamhost/assets/irix/mame/sgi          # PIE, vaddr == file offset
readelf -sW $B | grep -E 'osd_get_cache_line_size|drcbe_x648generate|code_compile_block'
echo 'p:clsmemo/cls '$B':0x22b87a0' >> /sys/kernel/tracing/uprobe_events   # osd_get_cache_line_size
echo 'p:clsmemo/gen '$B':0x7e2700'  >> /sys/kernel/tracing/uprobe_events   # drcbe_x64::generate
echo 'p:clsmemo/ccb '$B':0x5fed40'  >> /sys/kernel/tracing/uprobe_events   # mips3_device::code_compile_block
perf stat -x, -e clsmemo:cls,clsmemo:gen,clsmemo:ccb,syscalls:sys_enter_openat -p <mame> -- sleep 20
```

(Delete with `-:clsmemo/cls` etc. Do **not** truncate `uprobe_events` wholesale
on this box: it removes probes belonging to other agents too.)

One 20 s window at the iconlogin chooser:

| event | count |
|---|---|
| `mips3_device::code_compile_block` | 12832 |
| `drcbe_x64::generate` | 12832 |
| `osd_get_cache_line_size` | 12832 |
| `syscalls:sys_enter_openat` | 12832 |

Two conclusions. The chain is 1:1:1 — genuinely once per block. And **MAME's
`openat` count is its block-compile rate**: in this workload the emulator opens
no other file, so

```
perf stat -e syscalls:sys_enter_openat -p <pid> -- sleep 60
```

is a zero-overhead blocks-per-second meter, reusable by anyone making a
compile-side claim. `strace -c` is the wrong instrument — its ptrace stops cost
30-100 us apiece and skew both the rate and the share.

Rates measured that way (`sys_enter_read` tracked `sys_enter_openat` to the
single count, which is the stdio signature of exactly this call):

| regime | blocks/s | blocks per 1e9 cycles |
|---|---|---|
| cold boot, active (emu 0-70 s) | 3150-4600 | 1270-1780 |
| console → chooser | 620-2670 | 260-1100 |
| settled idle 4Dwm desktop | 3-11 | 1.4-4.6 |

The settled desktop compiles essentially nothing: with the 256 MB DRC cache the
working set stops being evicted. So this patch is worth **nothing at idle** and
its whole value is in boot — which is also the one regime that sits below 100%
and is therefore not clamped by the tile's throttle.

## What one call costs

The box runs IBRS + PTI + MDS "clear CPU buffers", so three syscalls are not
cheap here. Two independent measurements:

* standalone microbenchmark of exactly this triple (`clscost.c`), pinned to the
  same core pair: **10.3-11.2 us/call, ~25 000 cycles/call** (3 runs, 300 000
  calls each, 2.32-2.35 GHz achieved).
* inside MAME, differencing kernel cycles between the two builds over matched
  emulated windows: **~33 000-38 000 cycles/call**.

## Effect in MAME

Both arms were built from **one** source tree
(`/data/vms/soltest/cacheline-memo-3d91/mame`, MAME 8f21e978 + the ten shipped
IRIX patches), differing only in `osdlib_unix.cpp`; only that file was reverted
between the two links, so nothing else moved.

* control `sgi.ctrl` md5 `8206ab830a21ec589a308247e26c30e3`
* treatment `sgi.memo` md5 `ccf71cfeea122ef085bca3e6eb26ef13`

The primary metric is **kernel-cycle share** (`cycles:k / cycles`) sampled in
25 s windows against the emulated-time trace. The whole triple lands in
`cycles:k`, so the arms separate there far more cleanly than in end-to-end speed
— which matters, because the box was carrying load 12-15 from five sibling
agents and foreign occupancy on the claimed pair ran 28-35%.

Correctness first: **the memoized build makes zero `openat` calls** across the
entire boot (12 in one whole run, versus 429 149 for the control over the same
190 emulated seconds), and still reaches a real 4Dwm desktop — verified from the
shm framebuffer, not from logs.

### Primary: kernel-cycle share, 5 runs per arm, interleaved

Whole sampled boot (emulated 0→~190 s, every 25 s sample summed per run):

| arm | per-run `cycles:k` share | median | openat over the run |
|---|---|---|---|
| stock | 3.84, 4.13, 4.01, 3.82, 4.21 % | **4.01 %** | 424 222 – 524 273 |
| memoized | 1.54, 1.46, 1.33, 1.40, 1.16 % | **1.40 %** | 7 – 797 |

**2.61 % of every cycle the emulator burns across a boot** (per-run spread of
the difference 2.28–3.05 %), achieved clock 2.42–2.47 GHz on every run.

Restricted to the compile-heavy first ~70 emulated seconds (16 control samples,
13 treatment samples):

| arm | median `cycles:k` share | median blocks/s |
|---|---|---|
| stock | 5.78 % | 3129 |
| memoized | 1.73 % | 0 |

**4.05 % of cycles** in that phase.

### Secondary: cycnorm% — NOT usable on this box tonight, reported anyway

| window | stock median | memo median | ratio |
|---|---|---|---|
| emu 40–110 s | 73.69 | 90.04 | 1.22 |
| emu 110–180 s | 100.10 | 131.18 | 1.31 |

**Do not believe those ratios.** Five sibling agents held the box at load 12–15
and foreign occupancy on the claimed pair reached 55 %, 80 %, 94 %, 103 % — the
control arm happened to draw the worse rounds, and a +22 %/+31 % reading from a
2.6 % cycle saving is exactly the manufactured result the measurement rules
exist to prevent. Filtering to the runs with foreign ≤ 15 % leaves n=1 control
(91.10 % at foreign 11.0 %, against the clean baseline's 93.84 %) and n=3
treatment (median 96.05 %) on emu 40–110, i.e. about +5 % — consistent with the
cycle measurement in direction and rough size, but underpowered. The
kernel-cycle result above is the claim; the speed A/B corroborates it at best.

### Where it lands in production

The tile runs throttled, so a saving only becomes visible speed in a regime that
is below 100 %. Boot is: the baseline measured 93.84 % cycnorm over emu 40–110 s
and 150.65 % over 110–180 s. So this shows up as a slightly faster boot — the
part of the exhibit a visitor actually waits through — and as reduced host CPU
elsewhere. At an idle desktop it is worth nothing at all.


## What this does not do

Nothing at the idle desktop (rate 3-11/s → below 0.01% of cycles). Nothing for
the interactive workloads that the baseline could not drive on golden v3.

## Upstreaming

The patch is not lab-specific and fixes `drcbearm64.cpp` for free. It should go
to mamedev/mame as-is.
