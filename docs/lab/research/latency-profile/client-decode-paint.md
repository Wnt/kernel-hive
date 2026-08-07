# Client decode and paint/present latency

> **Historical-path note (2026-07-28).** References below to `ScreenSurface`,
> `Museum`, `Effects`, and the old 3D texture path describe the deleted v1
> museum. The flat StreamView analysis remains current; this report is retained
> unchanged as research evidence for the pre-cutover comparison.

Research note for the client-side part of the
[Solaris latency profile](README.md): WebCodecs decode (about 2 ms on CT950) and
browser paint/present (estimated at about 8 ms on CT950). This is a design and
measurement document only; it does not propose cursor prediction. A crosshair is
already present, and predicting the guest cursor would make selection, dragging, and
painting disagree with the authoritative guest state.

## Verdict

The reported **8 ms is not yet a measured GPU paint cost**. CT950 has no usable GPU and
was observed through a software WebGL/software-decode/VNC setup. It is suitable for
correctness probes, but not for valuing presentation optimizations. On a current real
GPU, the likely raster/upload/render work is roughly **0.5–2 ms for the flat path** and
**1–4 ms for the current 3D path**. Those are hypotheses to measure, not results.

Do not confuse that work with waiting for the display. A frame that becomes ready at a
random point in a fixed-refresh interval waits a median of half an interval merely to
reach the next presentation opportunity: **8.3 ms at 60 Hz, 4.2 ms at 120 Hz, or
3.5 ms at 144 Hz**. Scanout to the measured screen row and pixel response add more.
Consequently, a real-GPU trace may show sub-2-ms rendering while an optical
decode-output-to-photon measurement still shows about 8 ms or more. The original 8 ms
may be software inflation, refresh phase, or both; the present data cannot separate
them.

The first engineering finding is concrete: the 3D path marks its `CanvasTexture`
dirty in the decoder output callback **and again on every Three.js render frame**. The
second mark can upload unchanged 1920×1200 content continuously. Removing that
redundant work is the smallest promising experiment, but even its absolute value needs
the real-GPU measurement below.

## What the client does now

| View/path | Current frame route | Scheduling and avoidable work |
|---|---|---|
| Streamhost decode | AU → `VideoDecoder.decode()` → output callback | `optimizeForLatency: true` is set in the normal AVC configuration, Annex-B fallback, and last-resort baseline configuration ([`streamClient.ts`](../../../../spa/src/three/streamClient.ts)). Submit-to-output time and `decodeQueueSize` are already exposed in the HUD. |
| Chrome flat view | `VideoFrame` → offscreen 2D canvas → `captureStream()` → visible `<video>` | This apparently longer route is intentional: an earlier browser-specific comparison found Chrome's visible overlay video faster than direct canvas. That result was not a physical real-GPU measurement in this profile and must be repeated. |
| Firefox flat view | `VideoFrame` → visible opaque, `desynchronized` 2D canvas | Draws immediately in the decoder output callback; there is no application rAF or `captureStream()` hop ([`StreamView.tsx`](../../../../spa/src/ui/grid/StreamView.tsx), [`useStreamhostSession.ts`](../../../../spa/src/three/useStreamhostSession.ts)). |
| 3D museum | `VideoFrame` → offscreen 2D canvas → `CanvasTexture` upload → screen mesh → full-scene postprocessing → WebGL canvas → compositor | The decoder callback sets `tex.needsUpdate`, then `ScreenSurface.useFrame()` sets it again every rAF, including when no new decoded frame exists. The museum also renders shadows, DPR up to 1.8, SMAA, bloom, chromatic aberration, scanline, noise, and vignette ([`ScreenSurface.tsx`](../../../../spa/src/three/ScreenSurface.tsx), [`Museum.tsx`](../../../../spa/src/three/Museum.tsx), [`Effects.tsx`](../../../../spa/src/three/Effects.tsx)). |

Raycasting is not a paint bottleneck: the expensive raycasts occur on pointer samples,
not while uploading or presenting a decoded frame. A flat surface is still valuable
because it bypasses the entire 3D scene, not because it removes one raycast.

## How to re-measure properly

### Questions and boundaries

Report three different quantities rather than calling all of them "paint":

1. **Decode latency:** `VideoDecoder.decode()` call to the matching output callback.
2. **Sink-to-present latency:** output callback to compositor presentation. This
   includes canvas/video/texture work and refresh scheduling, but not a known physical
   scanout location unless an optical sensor is used.
3. **Glass-to-glass latency:** physical input edge to the first changed photons at a
   named location on the client display. This is the authoritative user-visible result.

The profile's existing `decodeMs` measures (1). JavaScript `drawImage()` return time is
**not** (2): GPU work and compositing can still be deferred. A video
`requestVideoFrameCallback` (rVFC) exposes compositor estimates such as
`presentationTime` and `expectedDisplayTime`, but it is not a photon sensor and its
callback itself can be one v-sync late. Use its metadata, not callback arrival time, as
supporting evidence.

### Required test client

- Use a locally attached, physically visible display. No headless browser, VNC,
  Remote Desktop, virtual display, VM GPU, SwiftShader, or llvmpipe may be in the
  measured output path.
- Start with one representative integrated-GPU client and, if available, one discrete
  GPU or Apple Silicon client. Use stable Chrome and stable Firefox with default
  production flags. Record browser build, OS, GPU, driver, display, connection type,
  and power mode.
- On Chromium, save `chrome://gpu` and reject the run unless WebGL/WebGL2 and
  compositing name the physical GPU. Confirm the WebGL renderer in-page and capture a
  Rendering/Media/GPU/Viz trace. On Firefox, save `about:support` graphics and media
  diagnostics. A successful `isConfigSupported({hardwareAcceleration:
  'prefer-hardware'})` call is not proof of hardware decode.
- Use AC power and a fixed performance policy. Disable VRR for the baseline, disable
  display motion interpolation, night/color enhancement, and panel power saving. Run
  both 60 Hz and the display's native 120/144 Hz mode. Record whether browser fullscreen
  is used.
- Hold stream conditions constant: Solaris 1920×1200 H.264, the baseline profile's
  fps/tier/quality settings, same LAN and server load, and ABR changes disabled for the
  run. Warm the decoder and GPU before sampling.

### Optical setup

Use an LDAT-style photodiode/logic-analyzer setup, or a global-shutter camera at
**at least 1,000 fps** that sees both the physical input indicator and client pixels.
Hardware optical tools are preferred because software timestamps cannot observe OS
present queues, scanout, or panel response. The traditional high-speed-camera and
photodiode approaches are described in NVIDIA's
[latency measurement overview](https://www.nvidia.com/en-gb/geforce/news/nvidia-reviewer-toolkit/).

1. Add a **test-only** guest pattern: a wired button/mouse edge toggles a high-contrast
   black/white patch and a small encoded frame ID. Keep the patch at the sensor's screen
   location. Do not use a predicted/local cursor as the response.
2. Wire the input switch and photodiode to the same logic analyzer. For a camera setup,
   drive an LED directly from the input switch and keep the LED and display patch in one
   exposure. The physical edge is time zero; the luminance threshold crossing is the
   optical endpoint.
3. Measure the patch at the top, center, and bottom in separate runs so scanout is not
   silently attributed to browser paint. State the luminance threshold used (for
   example, first 10% of the black-to-white transition).
4. Take at least **500 warm samples per cell**, with input timing randomized relative
   to v-sync. Preserve raw samples and report p50, p90, p95, p99, minimum, refresh-rate
   histogram, and dropped/mismatched frame IDs. Do not add independent percentile
   values from different stages.
5. Repeat each cell in windowed and browser-fullscreen mode. Keep a software-rendered
   CT950 cell only as a labeled negative control, never in the real-client aggregate.

### Instrumentation that accompanies the optical result

In a test build, record the same frame ID at AU receipt, decode submit, decoder output,
sink draw/texture-dirty, Three render start/end, compositor submission, and (where a
visible `<video>` is used) rVFC `presentationTime`, `expectedDisplayTime`,
`presentedFrames`, and `processingDuration`. Use `performance.mark()`/trace events and
the existing frame timestamp rather than console logging every frame. Capture a Chrome
Perfetto trace with Renderer, Media, GPU, `cc`, and Viz tracks; Chromium's
[RenderingNG architecture](https://developer.chrome.com/docs/chromium/renderingng-architecture)
shows why renderer, compositor, GPU, and Viz timings are distinct.

For the canvas/WebGL paths there is no web callback that proves photons appeared.
Correlate the internal trace to the optical distribution. The optical end-to-end delta
between two otherwise identical sink variants is more trustworthy than subtracting
unsynchronized server and client clocks.

### Test matrix and decision rule

| Axis | Baseline cells |
|---|---|
| Browser | Current stable Chrome; current stable Firefox |
| View | Chrome flat `<video>`; direct flat canvas; current 3D; 3D without redundant uploads/post effects experiment |
| Decode | Browser default/current preference; forced software only as a diagnostic control where the browser supports it |
| Refresh | Fixed 60 Hz; fixed 120/144 Hz |
| Presentation | Windowed; browser fullscreen |

Change one axis at a time and alternate A/B order. Adopt a path only if it improves
optical p50 **and** p95 without unacceptable tearing, frame loss, color/rotation errors,
or input-coordinate regressions. A CPU/GPU-time improvement with no optical improvement
is still useful for capacity/power, but it is not a latency win.

## Ranked ideas (expected saving divided by effort)

Savings below are hypotheses for a real 1920×1200 GPU client. “One refresh” means
16.7 ms at 60 Hz or 8.3 ms at 120 Hz. Missing a deadline makes small GPU savings
quantized into a much larger optical win.

| Rank | Idea | Likely saving | Effort | Confidence / prerequisite |
|---:|---|---:|---:|---|
| **1** | **Upload a 3D `CanvasTexture` only when a new frame arrived.** Remove the unconditional `ScreenSurface.useFrame()` dirty mark and retain the decoder callback mark; verify one upload per decoded frame in a trace. | **0–2 ms/frame**, lower GPU/CPU load; up to one refresh in deadline-bound tails | XS | The redundant mark is proven by code. Absolute latency value needs real GPU. |
| **2** | **Repeat the flat-path A/B on each real browser/GPU, then keep the winner.** Compare current Chrome canvas→`captureStream()`→video against the already-built direct opaque/desynchronized canvas; keep Firefox's direct path unless data reverses it. | **0–one refresh** if one sink buffers; otherwise <1 ms | S | Real-GPU optical A/B is mandatory; there is no universal winner implied by API shape. |
| **3** | **Verify actual HW decode and queue behavior on real clients.** Use submit→output p50/p95, queue size, OS/browser media trace, CPU/GPU engine activity, and a software control. Do not change the preference merely because “hardware” sounds faster. | **0–1.5 ms** likely; mainly CPU/power and tail capacity | XS | `optimizeForLatency` is already on. Hardware choice is only a hint and may not reduce wall latency. DPB conclusions belong to `lat-dec-buffering`. |
| **4** | **Add a 3D interactive low-latency render profile.** While controlling one exhibit, disable or reduce full-screen post effects, shadows, animated background work, and excessive DPR; restore museum quality when control ends. | **1–5 ms GPU work**, potentially one refresh at the tail | S–M | Must be valued on real GPU; visual trade-off. Preserve the screen mesh and authoritative input mapping. |
| **5** | **A/B `desynchronized: true` and opaque WebGL for interactive 3D.** R3F passes WebGL context attributes through its renderer creation options. Check the returned context attributes and test tearing. | **0–half refresh p50** if the browser enables a lower-buffered path; often 0 | XS | Browser/OS dependent; real-GPU optical test mandatory. Tearing is an explicit allowed outcome of the API. |
| **6** | **Prototype direct `VideoFrame → tex(Sub)Image2D` for 3D.** Retain only the newest frame until the next renderer upload, upload it once, then close it; remove the intermediate 2D canvas. | **0.3–2 ms** and one full-frame intermediate write; tail capacity gain | M | WebGL accepts `VideoFrame`, but does **not** guarantee zero-copy. Trace on every target browser/GPU; handle YUV→RGB, color space, crop, flip, lifetime, and context loss. |
| **7** | **For a visually flat focused/control mode, use a dedicated plain surface instead of the museum render.** Route to the existing flat sink, or test a dedicated opaque low-latency blit canvas; retain 3D only when perspective/curvature is visible. | **1–5 ms**, perhaps one refresh | M | Flat StreamView mostly exists already. Product/navigation choice and real-GPU A/B required. Do not claim raycast savings. |
| **8** | **Use rVFC for visible-video measurement and new-frame work, not as a WebCodecs pacer.** On the Chrome flat `<video>`, collect compositor metadata. If a video is sampled into a GPU texture, upload once in rVFC and do not add another rAF. | Measurement; avoids redundant uploads, normally **not a direct latency saving** | XS | rVFC applies to `HTMLVideoElement`, not raw WebCodecs outputs. The decoder output callback remains the earliest direct-canvas signal. |
| **9** | **Investigate WebGPU `importExternalTexture({source: frame})` only after the above.** It can sample decoder-backed YUV planes without an application-visible RGBA copy. | **0.3–2 ms** if the implementation shares the decoder resource | L | Copy avoidance is explicitly implementation-defined. Requires a WebGPU material/renderer or isolated blit path plus fallback and broad compatibility testing. |

### Present-path API conclusions

- **Direct WebGL upload is worth a prototype, not a “zero-copy” claim.** The Khronos
  [WebGL specification](https://registry.khronos.org/webgl/specs/latest/1.0/)
  includes `VideoFrame` in `TexImageSource`, so `texImage2D`/`texSubImage2D` may accept
  it. The spec does not say the decoder's resource must be shared with WebGL, and
  WebCodecs requires necessary rendering color conversion. This can remove the
  explicit offscreen 2D canvas even when the browser still performs an internal copy.
- **`importExternalTexture` is WebGPU, not WebGL.** The
  [WebGPU specification](https://www.w3.org/TR/webgpu/) permits a `VideoFrame` source
  and says it can be implemented without a copy, but that is implementation-defined.
  The external texture expires when its source frame is closed, so import, sample,
  submit, and close need deliberate lifetime handling.
- **Do not insert `createImageBitmap()`.** It adds asynchronous lifetime/conversion
  machinery between a `VideoFrame` and a sink and provides no latency guarantee.
- **rAF is not automatically a whole-frame bug.** WebGL presentation normally aligns
  to browser rendering. The current 3D path will use the next R3F/rAF opportunity; the
  audit did not find a second explicit rAF after that. A frame arriving just after the
  submission deadline necessarily waits unless an accepted tearing/desynchronized
  path can update the scanout. The actionable bug is uploading unchanged content every
  rAF, not the existence of rAF itself.
- **rVFC and rAF serve different sources.** rVFC fires when a new video frame is sent
  for composition and runs immediately before rAF in the normal rendering steps; its
  [specification](https://wicg.github.io/video-rvfc/) also warns that callbacks can
  occasionally be one v-sync late. Raw WebCodecs already supplies an output callback,
  so waiting for rAF or manufacturing a `<video>` solely to obtain rVFC would add work.
- **`desynchronized` is a hint, not a contract.** The WHATWG
  [canvas definition](https://html.spec.whatwg.org/multipage/canvas.html) and WebGL
  specification allow the browser to bypass ordinary paint/double buffering, possibly
  through front-buffer rendering, and explicitly permit tearing. The Firefox flat
  canvas already requests it; test whether it was honored via `getContextAttributes()`.

### Decode conclusions and coordination

`optimizeForLatency: true` is already configured everywhere this stream can configure
H.264. Per the [WebCodecs specification](https://www.w3.org/TR/webcodecs/), this asks
the decoder to minimize how many chunks must be accepted before output, but bitstream
and hardware constraints can still require inputs. No further decoder flag is missing.

The client probes hardware support and uses `prefer-hardware` outside Firefox only when
that probe succeeds; Firefox and fallback cases use `no-preference`. This is sensible.
The specification calls hardware acceleration a hint that the browser may ignore and
notes that hardware can have higher startup latency and does not necessarily decode
faster. At 1920×1200 it is still likely to reduce CPU load and improve loaded tails, so
confirm the actual route on representative clients rather than changing policy from
CT950's approximately 2 ms software result. The companion
[native-client survey](native-clients.md) documents the platform hardware backends and
reaches the same practical conclusion: a healthy browser and native viewer normally
use the same fixed-function decoder, so hardware is not evidence of a native-only
latency win.

The companion **`lat-dec-buffering`** investigation owns the SPS/VUI/DPB and
decoder-queue question. It is building a live headed submit→output probe (including
whether later submits precede an output) and an SPS parser for
`num_reorder_frames`/`max_dec_frame_buffering`. This note deliberately does not repeat
that work or book a speculative one-frame saving. Import its result when committed; if
it finds no hold and `decodeQueueSize` remains at 0–1, treat decode buffering as closed
and focus on presentation.

## Recommended first two

1. **Run the real-GPU optical + trace matrix before changing production.** At minimum,
   measure Chrome flat video, direct flat canvas, and current 3D at 60 and 120/144 Hz.
   This determines whether “8 ms paint” is software work, refresh phase, a buffered
   sink, or some mixture, and produces the baseline every later idea needs.
2. **In a measurement branch, stop unconditional 3D CanvasTexture re-uploads and A/B
   it against current 3D.** This is a tiny, code-proven waste with no intended visual
   change. If 3D still misses presentation deadlines, next test the interactive
   low-postprocessing profile; if flat view is slower instead, use the per-engine sink
   A/B result before touching WebGL/WebGPU architecture.

Do not prioritize WebGPU migration or cursor prediction. The former has a poor
saving-to-effort ratio until direct upload is measured; the latter is explicitly out
of scope and would make precise interaction incorrect.
