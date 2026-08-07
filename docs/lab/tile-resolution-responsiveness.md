# Tile resolution vs perceived responsiveness — the unaccelerated-VGA question

Investigation date 2026-07-27, QEMU 11.0.2 on `labhost`. **READ-ONLY**: no live
tile was re-baked or reconfigured; the four already-bumped tiles were driven only
with input that was immediately reverted (`loadvm golden`) and framebuffer-verified
back to their curated fixtures. Old-resolution baselines were measured on a
disposable `/data/vms/soltest/` clone (killed via `clone-guard`). All backups
(`*.bak-res*`) were left intact.

## The question

Wave-1 bumped four tiles on QEMU's **unaccelerated** display path (`-vga std` /
Bochs-VBE packed-linear framebuffer): win95 640×480→**1280×1024**, win98se
640×480→**1600×1200**, kolibrios 1024×768→**1280×1024**, alpine 1280×800→**1920×1200**.
Directive: *"make sure responsiveness doesn't suffer; I think we cannot use the
non-accelerated VGA."* Does raising resolution on the unaccelerated path hurt
perceived responsiveness, and if so is an accelerated display the fix?

## TL;DR verdict

**The unaccelerated VGA is NOT the responsiveness bottleneck, and switching to an
"accelerated" display device would NOT help our pipeline.** The resolution-dependent
cost lives entirely in **capture+encode (and downstream egress + client decode)** —
all of which are set by *changed scanout pixels*, not by how the guest drew them.
The guest's own software blit (packed-linear VBEMP / VESA / bochs-drm) keeps up 1:1
at every resolution tested. So the correct lever is **CAP the pixel count**, not
**SWITCH the display path**. Every bumped tile is KEEP-able today on LAN; the cost
that *does* scale with resolution is egress bytes + client (esp. mobile) decode +
CPU-contention headroom.

## Where the cost is — the decomposition

Only two pipeline stages depend on resolution: **(3) guest repaint** and
**(5) capture+encode**. Everything else (input path, network, decode, present) is
resolution-independent. So `ΔRTT(hi-vs-lo) ≈ Δ(guest repaint) + Δ(encode)`. Both
were measured directly.

### (A) Guest repaint — packed framebuffer keeps up 1:1 at every resolution

Method: drive a sustained full-window drag (warpd for win95; QMP `input-send-event`
abs for the tablet tiles) and sample the QMP framebuffer as fast as possible,
counting distinct fully-repainted frames + single-move settle time. The **bare
screendump round-trip** is the sampling floor (my instrument, not the guest).

| tile | resolution | bare screendump RTT p50 | single-move settle | sustained-drag: distinct / samples | guest keeps up? |
|---|---|---:|---|---|---|
| win95 clone | 640×480 | 6.8 ms | < 30 ms (below floor) | 206 / 207 (34/s) | **yes** |
| win95 live | 1280×1024 | 15.9 ms | < 45 ms (below floor) | 135 / 135 (22/s) | **yes** |
| win98se live | 1600×1200 | 19.6 ms | — | 149 / 151 (30/s) | **yes** |
| kolibrios live | 1280×1024 | 15.1 ms | — | 192 / 195 (38/s) | **yes** |
| alpine live | 1920×1200 | 20.3 ms | — | cursor is an uncaptured overlay; idle FB bit-stable | n/a |

At **every** resolution the guest produced a fresh, fully-repainted frame for
essentially every sample (distinct ≈ samples). The single-move repaint settled
*below the screendump sampling floor* even at 1280×1024. The only thing that
declined from lo-res to hi-res (34→22 samples/s) is the **screendump RTT of my
measurement instrument** (6.8→15.9 ms — the per-pixel copy cost), not the guest.
This refutes the "unaccelerated VGA can't keep up at hi-res" hypothesis: with a
**packed-linear** framebuffer a repaint is a `memcpy`, which is sub-frame even at
1600×1200. (The old *planar* 16-colour VGA — 4-plane read-modify-write — WAS slow,
which is why the shipped Win9x tiles already run the VBEMP packed driver.)

### (B) Capture+encode — cheap on real content, bounded worst case

Live streamhost `snap→AU` latency (includes capture wait + damage-scoped I420
conversion + x264), read from the journal on the real desktop content:

| tile | resolution | idle p50/p95 | during full-window drag p50 / p95 / max |
|---|---|---|---|
| win95 | 1280×1024 | 1.8 / 2.7 ms | 2.0 / 2.8 / **5.8** ms |
| win98se | 1600×1200 | 2.7 / 4.3 ms | 2.7 / 5.9 / **11.4** ms |
| kolibrios | 1280×1024 | 1.9 / 3.6 ms | 1.9 / 4.1 / **7.8** ms |
| alpine | 1920×1200 | 3.2 / 4.3 ms | (idle) 3.2 / 4.3 / 6.1 ms |

Retro-desktop content is **low-entropy** (a white Notepad over a flat desktop), so
even a full-window drag encodes cheaply — worst single frame 11.4 ms at 1600×1200,
far inside the 33 ms budget of the 30 fps cap. This is exactly what the
damage-scoped conversion (`SH_DAMAGE_CONV`, full-frame fallback at
`SH_DAMAGE_FULL_PCT=35`) + CQP-SKIP encoding are designed to deliver.

### x264 encode-only scaling law (the worst-case ceiling)

Isolated bench: encode-only per-frame time (raw yuv420p in, `-f null` out),
mirroring streamhost's params (`veryfast`, `tune=zerolatency`, CQP `qp=10`,
`profile high`, sliced-threads). STATIC = repeated frame (≈ keyframe/idle);
CHANGE = a full-frame high-entropy `testsrc2` change **every** frame (the
worst case — video/complex scrolling, which these desktops rarely produce).

| resolution | pixels vs 640×480 | STATIC (4 thr) | CHANGE (4 thr) | CHANGE (1 thr) |
|---|---:|---:|---:|---:|
| 640×480 | 1.00× | 0.81 ms | 2.67 ms | 4.33 ms |
| 1280×1024 | 4.27× | 2.98 ms | 8.03 ms | 16.27 ms |
| 1600×1200 | 6.25× | 4.37 ms | 13.38 ms | 31.16 ms |
| 1920×1200 | 7.50× | 5.22 ms | 15.58 ms | 31.46 ms |

Encode scales ~linearly with pixel count. Against the 30 fps budget (33 ms/frame):
CHANGE at 4 threads fits comfortably at every resolution. **At 1 thread** (a tile
that loses its thread budget under contention on the 30-tile box) 1600×1200 and
1920×1200 full-frame high-entropy hit ~31 ms — *at the edge* of 30 fps. 1280×1024
stays comfortable (16 ms) even single-threaded.

## Does an accelerated display device help? — Box-verified, no.

- QEMU 11 emulates **no S3/Tseng**; the box is **GPU-less**, so virtio-gpu-gl /
  virgl / DMABUF scanout cannot init (`-display dbus,gl=on` → *egl: no drm render
  node*). Every tile is captured as the CPU-composited packed scanout.
- streamhost's capture (`capture/listener.rs`) serves only the shared-memory
  `ScanoutMap` + `UpdateMap` damage path — **no DMABUF method, no cursor-overlay
  method**. Therefore:
  - Guest **2D/BitBLT acceleration is invisible to us**: we encode the composited
    scanout; its cost is changed-pixel count, not how the guest drew it. Accel only
    lowers the guest's *internal* draw time — which is already sub-frame here.
  - A **hardware-cursor overlay** (cirrus/qxl/virtio HW cursor) is delivered as a
    separate overlay, **not composited into the captured frame → it would be
    invisible in the stream**. Our tiles work because the guest renders a *software*
    cursor.
  - **virtio-gpu 2D** captures identically to `-vga std` (same `ScanoutMap`/damage);
    only **3D/virgl** would flip to whole-surface DMABUF updates and *defeat*
    damage-scoping — and that path can't run on this box anyway.
- `-vga cirrus` **blanks GDI text at hi-res on QEMU 11** (documented in
  `docs/guests/win9x.md`) and its Win9x driver **deadlocks under KVM**.

The only display property that helps our pipeline is a **packed-linear framebuffer
with a software cursor** (memcpy repaint completes inside one 4 ms fast-poll, so we
capture the final frame, not torn planar intermediates). Every bumped tile already
has that. Moving to qxl/virtio-gpu for "acceleration" buys the stream nothing and
adds the invisible-cursor hazard.

### Accelerated-display matrix

| guest family | current | accel candidate that works on QEMU 11 w/ a driver the guest has | reduces OUR encode cost? | recommend |
|---|---|---|---|---|
| Win9x (win95/win98se) | `-vga std` + VBEMP packed, KVM | none (cirrus deadlocks/blanks; no 9x qxl/virtio driver) | **no** (scanout-side); packed *format* already captured | keep `-vga std` + VBEMP |
| NT (reactos/win2000) | reactos `-vga std`; win2000 `-vga cirrus` (NT driver, packed hi-res, no 9x deadlock) | qxl marginal on 2000, experimental on ReactOS | **no** + invisible-cursor risk | keep current |
| Haiku | `-device VGA`+EDID, KVM (VESA packed) | none (Haiku has no qxl/virtio/cirrus accel driver) | **no** | keep `-device VGA` |
| Linux (redstar/tinycore/alpine) | `-vga std` (bochs-drm) / redstar cirrus | qxl/virtio-gpu-2D KMS work but same scanout; virgl unavailable | **no** | keep `-vga std` |

## win311 accelerated hi-res (SHIPPED 2026-07-27)

> **Update 2026-07-27:** win311 is now LIVE at **1024×768×8** via path #1 below —
> `PluMGMK/vbesvga.drv` on `-vga std` (the packed-linear Bochs VBE path, software
> cursor). Full recipe + the `dacdepth=6` savevm/loadvm gotcha in
> `docs/guests/win9x.md` → "Win311 hi-res SHIPPED". The text below is the original
> pre-ship ranking (kept for context).

Original (pre-ship) state: win311 = `-vga cirrus`, **TCG**, Microsoft Standard-VGA 640×480×16 planar.
Ranked paths to a readable, settled, hi-res Program Manager:

1. **`PluMGMK/vbesvga.drv` on `-vga std`** — the Win16 analogue of the shipped Win9x
   VBEMP path: packed-linear VBE framebuffer at 800×600/1024×768, actively
   maintained. Best chance of readable settled hi-res. Effort low–med; validate the
   documented QEMU VBE quirks on a clone.
2. **Microsoft CPU-rendered SVGA256 @ 800×600×256** — *already proven clean and
   settled* on this exact QEMU device set (`docs/guests/win9x.md`); its only demerit
   ("unaccelerated") is irrelevant to our scanout-encoding pipeline. Pragmatic
   fallback.
3. cirrus-with-fix / `ati-vga` — blocked (cirrus text-blank; ati experimental).
4. Patch QEMU's cirrus text/BitBLT path — high effort, and even success buys the
   *stream* nothing over a packed-linear VBE driver.

S3 Trio/Virge and Tseng ET4000 are **impossible** — QEMU 11 does not emulate them.
Accelerated hi-res Win3.11 is **not worth it for the stream**: raising its
resolution only *increases* our per-full-frame encode geometry, and BitBLT accel is
invisible to us. Pursue #1 only for a *fidelity* upgrade; otherwise the current path
is fine.

## Per-tile recommendation

No severe live regression was found, so nothing was rolled back.

| tile | resolution | verdict | why |
|---|---|---|---|
| win95 | 1280×1024 | **KEEP** | guest keeps up; encode 2–6 ms real / 16 ms 1-thread worst case — comfortable |
| kolibrios | 1280×1024 | **KEEP** | guest keeps up; encode 2–8 ms; comfortable single-threaded |
| win98se | 1600×1200 | **KEEP on LAN; CAP-candidate** | fine today (encode ≤ 11 ms real) but 1-thread worst case 31 ms is at the 30 fps edge; 6.25× the egress/decode of 640×480 |
| alpine | 1920×1200 | **KEEP on LAN; CAP-candidate** | heaviest (1-thread CHANGE 31 ms; 7.5× egress/decode). Terminal content is low-change so real cost is low, but this is the least-headroom tile |

### General rule — max responsive resolution per class

- **KVM + packed framebuffer, LAN, 4 encode threads:** up to ~**1920×1200** stays
  within the 30 fps encode budget on real (low-entropy) content.
- **Under CPU contention (effectively 1 encode thread) OR mobile/WAN clients:** cap
  at ~**1280×1024** — single-thread worst case 16 ms, and ~4× fewer egress bytes +
  client-decode load than 1920×1200. This is the safe gate for the remaining
  un-bumped tiles (reactos/aros/tinycore/haiku/toaruos/serenityos/redstar2/redstar3/
  win2000/os2warp).
- **Never SWITCH display path for "acceleration"** — it does not reduce our
  encode/egress/decode cost and risks the invisible-cursor / cirrus-text-blank bugs.
  If a hi-res guest is a *format* problem (planar tearing), fix it with a
  **packed-linear** driver (VBEMP/VESA), keeping `-vga std`.

## Reproduction

Measurement scripts live under `/data/vms/soltest/resmeas/` on the box:
`drawmeas.py` (warpd drag + QMP screendump cadence), `absdrag.py` (tablet-abs drag),
`x264bench.sh` (encode-only scaling bench). Live encode figures come from the
`[encode] enc latency (snap->AU)` journal line (always emitted per 120 frames;
`SH_ENC_PROFILE=1` adds per-component detail).
