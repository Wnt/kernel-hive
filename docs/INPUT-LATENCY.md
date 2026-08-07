# Input → visual-feedback latency: where the milliseconds go, and how to get them back

*How long from a key press / mouse move in the browser to the pixel change
appearing back on screen — and the architectural levers to push it lower. LAN
figures; WAN adds the physical round-trip on top of everything here.*

Measured LAN click-to-photon today is **~20–25 ms** (was ~33 ms before the QEMU
fast-poll landed; ~200 ms on the pre-project neko/WebRTC stack). The number is no
longer dominated by any one giant stall — it is a sum of small, well-understood
stages, which means further wins now come from **re-architecting the two biggest
remaining stages (encode, mouse-move application) and from hiding latency the
client can predict locally**, not from another single "floor" fix.

---

## 1. The round trip, stage by stage

```
        ┌──────────────────────────── YOU PRESS / MOVE ────────────────────────────┐
        │                                                                           │
  BROWSER (client)                     LAN                    HOST (streamhost + QEMU + guest)
        │                               │                                           │
  [1] capture event  ── QUIC ─────────► │ ──► [2] daemon inject ──► [3] guest reacts │
      (key/click: reliable stream)      │        (dbus / warpd)        + REPAINTS    │
      (move: unreliable datagram)       │                                  │         │
                                        │                          [4] QEMU capture  │
                                        │                              (dbus poll)   │
                                        │                          [5] H.264 encode  │
        [8] paint ◄─ [7] decode ◄── QUIC │ ◄── AU (reliable uni-stream) ◄── [6] ship │
            (canvas/                     │                                           │
             video)                      │                                           │
        └──────────────────────────── PIXEL APPEARS ───────────────────────────────┘
```

Two halves: the **input path** (1→3, key/mouse to the guest) is short; the
**output path** (4→8, the guest's repaint back to your screen) carries most of
the cost. The guest's own reaction time (3) sits in the middle and is the wild
card — a console echoing a character is fast; Win9x repainting a dragged window
in 16-colour planar VGA is not (that is a *guest* problem, addressed separately
by the VBEMP driver work, not a pipeline problem).

---

## 2. Current LAN latency budget

Per-stage, steady state, a small damage event (e.g. a character echo or cursor
move), post-fast-poll:

| # | Stage | Where | ~ms | Notes |
|---|-------|-------|----:|-------|
| 1 | Event capture + encode-to-wire | client JS | ~0.5 | capture-phase listener, scancode/coords packed |
| 1→2 | Input on the wire (one-way) | LAN | ~1.5 | QUIC; key/click reliable, move = datagram |
| 2 | Inject into guest | daemon → QEMU | ~0.5–**N** | dbus `SetAbsPosition` / warpd; **see §3 mouse caveat** |
| 3 | Guest reacts + repaints framebuffer | guest | **var.** | fast for a console; slow for unaccelerated GUI repaint |
| 4 | Capture wait (display poll) | QEMU dbus | **~2** | was ~15 (30 ms poll); fast-poll `SH_DBUS_UPDATE_MS=4` |
| 5 | H.264 encode (snap→AU) | x264 (CPU) | **~8** | p50 8.2 / p95 10 ms; dedicated `sh-encode` thread, CQP |
| 6→7 | AU on the wire (one-way) | LAN | ~1.5 | reliable QUIC uni-stream, one AU per frame |
| 7 | WebCodecs decode | browser | ~1.3 | avc-mode, `optimizeForLatency`, HW-probe |
| 8 | Present (paint) | browser | ~1.4 | Firefox→canvas / Chrome→`<video>` (engine-optimal) |
| | **Fixed pipeline total (excl. stage 3)** | | **~16–17** | + guest reaction (3) → the ~20–25 ms observed |

### Where the fixed time actually is (bar chart, ms)

```
encode (x264, CPU)  ████████████████████████████████████████  8.0   ◄ dominant
input path + net    ██████████████████                        3.5
decode + present    █████████████                             2.7
capture wait        ██████████                                2.0   (was ~15 pre-fast-poll)
event capture       ███                                       0.5
                    └────┴────┴────┴────┴────┴────┴────┴────┘
                    0    1    2    3    4    5    6    7    8  ms
```

**The headline:** now that the fast-poll has collapsed the old ~15 ms capture
floor, **the single CPU H.264 encode (~8 ms) is the biggest fixed cost** — nearly
half the fixed pipeline. That is the primary target for the next big win.

### How we got here

```
neko / WebRTC          ████████████████████████████████████████████████  ~200 ms
  → WebTransport+WebCodecs, in-proc x264, enc thread    ████████          ~33 ms
  → + QEMU fast-poll (this project)                     █████             ~20–25 ms
                                                        └──┴──┴──┴──┴──┴
                                                        0  50 100 150 200 ms
```

---

## 3. The mouse-specific caveat (stage 2)

Mouse **movement** has an extra hazard that key presses do not. On the abs/rel
**dbus** tiles (winxp, win2000, reactos, haiku, all usb-tablet tiles, the rel
tiles), the datagram receive loop applies each move as an **awaited** dbus
`SetAbsPosition` / `RelMotion` call — it waits for QEMU's method *reply* before
reading the next datagram. Under pointer-lock at high move rates (up to ~1 kHz)
moves queue one round-trip each, and a **backlog of already-superseded cursor
positions** builds up, so the cursor lags the pointer under fast motion. The
`warpd`-agent tiles (win95, win311, 9front, solaris) already avoid this via
server-side coalesce + 8 ms pacing; the dbus tiles do not. This is a known,
un-shipped fix (`LATENCY-NOTES.md` item 1) and is the **biggest felt mouse-lag
win available without new hardware**.

---

## 4. What is already reference-optimal (don't touch)

Verified against Moonlight / Sunshine / neko / Selkies (`LATENCY-NOTES.md`):
present-ASAP with **no client jitter buffer**; `optimizeForLatency` decode; CQP /
**no VBV** (VBV/CBR would *add* latency); SPS/PPS inline every IDR; moves on
**unreliable** datagrams (neko/Selkies carry them reliably and are *slower*);
per-class QUIC input streams (no head-of-line blocking); delay-gradient ABR;
force-IDR-on-join. WebTransport over WebRTC is a **measured** ~5–6× LAN win
because WebRTC's receiver jitter buffer cannot be floored on our bursty,
damage-gated source. None of these are where remaining latency lives.

---

## 5. Levers for even lower latency

Ranked by expected felt win. "Re-arch" = worth a real rebuild for the size of the
prize.

| # | Lever | Cuts | Est. win | Effort | Where it lives | Notes |
|---|-------|------|---------:|--------|----------------|-------|
| A | **Client-side cursor prediction** | perceived mouse lag | **→ ~0 ms felt** | Med | client (SPA) | draw the cursor locally at the pointer the instant it moves; the guest cursor catches up underneath. Standard in RDP/Guacamole/Parsec. Doesn't lower the *pipeline*, it **hides** it — the single biggest perceptual mouse win, client-only, no hardware. |
| B | **GPU hardware encode** (NVENC / VA-API / QSV) | stage 5 encode | **~8 → ~1–2 ms** | High (re-arch + **GPU**) | host | the box is deliberately GPU-less; CPU x264 is the ~8 ms. A GPU encoder drops encode to ~1 ms *and* frees ~30 % of a core per busy tile (more fps / more tiles). Biggest **fixed-pipeline** reduction. Requires adding a GPU and a VAAPI/NVENC path in `encode/`. |
| C | **Fix the dbus move-apply backlog** (§3) | stage 2 (mouse) | removes queued-move lag | Low–Med | daemon | coalesce + pace the abs/rel dbus move path like `warpd.rs` already does (apply only the latest position, don't await each call). Un-shipped `LATENCY-NOTES.md` item 1. |
| D | **Verify/force SPS VUI `num_reorder_frames=0`, `max_dec_frame_buffering≤1`** | stage 7 decode | up to **~1 frame (~16 ms)** worst case | Trivial (measure) | encoder | `bframes=0` does *not* guarantee the VUI flags; if the browser DPB defensively buffers a frame, that is a hidden ~16 ms. Dump the emitted SPS; add the x264 VUI opts only if missing. Cheapest possible check with a large upside if it's wrong today. |
| E | **Slice / damage-region pipelined capture-encode** | stages 4–6 serialization | ~2–5 ms | High (re-arch) | capture+encode | today: guest finishes frame → capture whole frame → encode whole frame → ship. Instead encode+ship each damaged region / H.264 slice **as it is captured**, overlapping encode with the guest still drawing and with the network. Removes whole-frame serialization; pairs naturally with GPU encode. |
| F | **Faster guest repaint** (per-guest, not pipeline) | stage 3 | large on slow guests | Med per tile | guest | KVM accel + packed-linear VBE driver (the Win9x VBEMP work) + reasonable colour depth. Only matters where the guest can't rasterise fast enough (retro GUIs); modern guests already fine. |
| G | **WAN: local echo / speculative present + edge** | the physical RTT | hides WAN RTT | High | client + edge | on the internet the round-trip dominates and is physics. Client-side input prediction (A generalised), an edge relay near the user, and DSCP/SO_PRIORITY on the input socket are the WAN levers. No-op on LAN. |

### Projected budget after the big wins (A hides mouse; B+C+D+E on the pipeline)

```
                     NOW                         AFTER B+C+D+E (+ A hides mouse)
encode          ████████ 8.0                     █ 1.0          (GPU encode, B)
input path/net  ████ 3.5                          ██ 2.0        (move coalesce, C; net unchanged)
decode+present  ███ 2.7                            ██ 1.5       (VUI check, D)
capture wait    ██ 2.0                             ██ 2.0       (already fast-poll'd)
event capture   ▌ 0.5                              ▌ 0.5
                ───────────────                   ─────────────
  fixed total   ~16–17 ms                          ~7–8 ms      + mouse feels instant via A
```

A realistic target is a **~7–8 ms fixed pipeline** (roughly halved), with **mouse
motion feeling instant** via client-side cursor prediction regardless of the
pipeline — because at that point the perceived cursor latency is zero and the
keyboard-to-echo path is bounded by encode + one LAN round-trip + decode.

---

## 6. Recommended roadmap

1. **A — client cursor prediction.** Biggest felt win for the reported pain
   (mouse), client-only, no hardware, no server risk. Do first.
2. **C — dbus move coalesce** and **D — SPS VUI check.** Low-effort, and D is a
   trivial measurement that could reveal a hidden ~16 ms decoder frame.
3. **B — GPU encode.** The one true "re-architecture for a big win": it needs a
   GPU in the box, but it halves the fixed pipeline's dominant stage *and* buys
   headroom for higher frame rates and more concurrent tiles. Design the
   `encode/` path so a VAAPI/NVENC backend slots in behind the existing
   `EncodeWorker` boundary.
4. **E — slice-pipelined capture/encode**, best done *with* B (a GPU encoder
   consuming damage slices as they land is the end-state low-latency architecture).
5. **F/G** as guests and WAN exposure demand.

The through-line: the fast-poll removed the last big *fixed floor*, so the next
tier of wins is **hiding** latency the client can predict (A, the mouse answer)
and **shrinking the encode** (B), the two levers big enough to justify a rebuild.
