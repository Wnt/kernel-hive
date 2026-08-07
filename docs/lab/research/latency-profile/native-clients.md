# Native hardware-decode clients: latency opportunity and cost

**Research date:** 2026-07-16<br>
**Scope:** research/brainstorm only; no product implementation<br>
**Baseline:** [the Solaris cursor latency profile](README.md)

## Verdict

**Do not start five native clients.** A native client would normally use the same
fixed-function decoder that a hardware-accelerated browser already uses. The current
profile's ~2 ms decode and especially its estimated ~8 ms paint are measurements from
GPU-less CT950 and are not evidence of a 10 ms browser tax. The ~8 ms is also close to
the unavoidable average wait for the next refresh on a 60 Hz display (8.33 ms), even
before considering CT950's software rendering.

First measure the existing **engine-specific 2D fast path** on representative
GPU-equipped macOS, Windows, and Android hardware. Proceed only if a native proof of concept saves
at least **4 ms p50 or 8 ms p95 input-to-photon** on the primary client, or if the
browser demonstrably falls back to software decode. If that gate passes, build one
**macOS VideoToolbox + Metal spike**, not a cross-platform product. macOS is the best
latency-per-effort target because it is a high-value desktop client, has one coherent
media/display stack, and shares much of its decoder code with a possible later iOS
client.

Even a successful native client is a secondary lever. The measured server-side
capture/encode path is ~18 ms p50, including a 14 ms full-frame encode. Damage-scoped
conversion/encode, faster color conversion, capture pacing, and local cursor
prediction have more credible upside than replacing a real-GPU browser client.

## What the browser already does

The production client already selects an engine-specific low-latency 2D sink:

- [`streamClient.ts`](../../../../spa/src/three/streamClient.ts) configures WebCodecs
  with `optimizeForLatency: true`, probes hardware support, and requests
  `hardwareAcceleration: 'prefer-hardware'` when the probe succeeds. It submits one
  complete H.264 AU per `EncodedVideoChunk` and does not add a jitter queue.
- [`useStreamhostSession.ts`](../../../../spa/src/three/useStreamhostSession.ts) can
  paint a decoded `VideoFrame` directly into a visible canvas with
  `desynchronized: true`, bypassing offscreen canvas → `captureStream()` → `<video>`.
  [`StreamView.tsx`](../../../../spa/src/ui/grid/StreamView.tsx) enables that route for
  Firefox, where it measured faster; Chrome deliberately keeps the overlay `<video>`
  route because that measured faster on Chrome. The 3D exhibit path still has
  CanvasTexture/WebGL/compositor work and is a more plausible place for a native-style
  presentation win, but a plain native viewer would not reproduce that product UI.
- The WebCodecs specification defines hardware selection and latency optimization as
  **hints**, not guarantees. It also warns that hardware decode is not intrinsically
  lower latency for every stream. A native client can require and verify hardware;
  that is a determinism/reliability benefit, not evidence that its silicon decodes
  faster.
- Chromium contains platform decoder backends for **VideoToolbox, MediaCodec, D3D11,
  VA-API, and V4L2**. Thus, on a healthy supported configuration, native and browser
  converge on the same decoder hardware. The browser adds IPC/API/compositor layers,
  but it does not normally decode H.264 in JavaScript or WebAssembly.

The current `decodeMs` metric is submit-to-output-callback time, so it includes decoder
queueing and callback dispatch, not just fixed-function execution. The ~8 ms paint
figure in the profile is an estimated, software-inflated upper bound, not a measured
browser-compositor slice. Neither number should be extrapolated to a real GPU.

## Per-platform assessment

The expected wins below are **estimates versus the current engine-specific 2D fast path
in a correctly hardware-accelerated browser on the same GPU and display**. They are not
estimates versus CT950. “One refresh” is 16.7 ms at 60 Hz and 8.3 ms at 120 Hz.
Decode and present estimates are conditional and should not be added as if independent.
Effort is one experienced engineer, viewer/input/telemetry/reconnect included but not
full gallery UI, accessibility, audio parity, store review time, or long-term QA.

| Platform | HW decode API and minimal-buffer path | GPU-resident present path | Plausible latency win vs good browser | Rough effort and main risk |
|---|---|---|---:|---|
| **macOS** | `VTDecompressionSession`; require HW, query that HW was selected, realtime session; AVCC sample per AU; no output reorder with a compliant no-B-frame SPS | `CVPixelBuffer`/IOSurface → two Metal plane textures with `CVMetalTextureCache` → YUV shader → `CAMetalLayer` | **Decode 0–1 ms; present 0–4 ms typical.** Up to one refresh only if Canvas/DWM-equivalent composition is proven to queue an extra frame | **2–3 wk spike; 6–10 wk robust MVP.** Session rebuilds, color metadata, drawable/vsync timing, signing/notarization |
| **iOS/iPadOS** | Same VideoToolbox path; app must handle lifecycle/resource pressure and decoder loss | `CVPixelBuffer` → Metal → `CAMetalLayer`; IOSurface-backed CoreVideo buffers stay off CPU | **Decode 0–1 ms; present 0–3 ms typical.** Direct scanout is not app-guaranteed | **+4–8 wk after macOS core.** Touch/keyboard semantics, app lifecycle, store/signing, device/OS matrix |
| **Android** | Async `MediaCodec` configured for `video/avc`; provide SPS/PPS as codec-specific data, one AU/input buffer; enable `KEY_LOW_LATENCY` when `FEATURE_LowLatency` exists | Decoder output directly to a `SurfaceView`/`Surface`; `releaseOutputBuffer(..., true/now)` enters BufferQueue/SurfaceFlinger without a CPU readback and may receive a hardware overlay | **Decode 0–1 ms; present 0–4 ms typical.** A one-refresh win is possible if browser Canvas missed an overlay/fast path; vendor-dependent | **8–12 wk.** Codec/vendor quirks, Java/Kotlin or JNI surface glue, rotation/lifecycle, broad device lab |
| **Windows** | Prefer Media Foundation H.264 MFT with `CODECAPI_AVLowLatencyMode` plus an `IMFDXGIDeviceManager`; direct D3D11VA is lower-level, not obviously faster | NV12 D3D11 decoder texture → video processor/pixel shader → DXGI flip-discard swapchain; waitable frame-latency object; conditional DirectFlip/Independent Flip/MPO | **Decode 0–1 ms; present 0–4 ms typical.** Up to one refresh only in a proven flip/tearing/fullscreen case | **8–12 wk.** COM/MFT negotiation, device loss, color conversion, swapchain timing; HW support must be probed at 1920×1200 |
| **Linux desktop** | VA-API VLD is the general desktop route. V4L2 stateful M2M can ingest Annex-B on supported SoCs; stateless V4L2 requires userspace H.264 parsing and Request-API controls | `VASurface` export or V4L2 capture buffer as DMA-BUF → EGLImage/Vulkan image/Wayland dmabuf or KMS plane; CPU-free only when modifiers/formats intersect | **Decode 0–2 ms if browser already uses VA-API. Potentially much larger only where browser HW decode is disabled/broken; present 0–4 ms typical** | **10–16 wk.** Highest risk: VA driver/vendor, Wayland/X11, modifiers, sandbox/permissions, V4L2 stateful/stateless, distro packaging |

### macOS and iOS: VideoToolbox

`VTDecompressionSession` is a direct low-level hardware decode API. Set
`kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder` when creating the
session and verify `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder`.
VideoToolbox treats decompression as realtime by default; explicitly keeping
`kVTDecompressionPropertyKey_RealTime` true documents the intent.

The wire AUs are Annex-B. VideoToolbox's practical input path is a
`CMVideoFormatDescription` made from SPS/PPS plus a `CMSampleBuffer` containing
length-prefixed NAL units, so the native core performs the same Annex-B → AVCC
conversion the web client already performs. Rebuild the session on SPS/PPS or dimension
change. The stream's complete AUs, repeated SPS/PPS on IDR, and no B-frames suit
low-delay decode, but **the SPS/VUI still decides legal DPB/output behavior**; native
code cannot override codec-required buffering.

Request bi-planar 4:2:0 Metal-compatible IOSurface-backed `CVPixelBuffer`s. Map luma and
chroma planes with `CVMetalTextureCacheCreateTextureFromImage`, perform YUV→RGB and
scale in one Metal pass, keep at most one drawable outstanding, and present the newest
completed frame. This removes CPU readback and browser canvas work, but it still does a
GPU render/composition pass. `CAMetalLayer` does not guarantee direct scanout, and
vsync/scanout remains.

Apple is the cleanest native experiment, but Chromium on macOS itself has a
`VideoToolboxVideoDecoder`; a native client does not gain a different Apple decoder
class. The expected decode win is consequently near zero when browser hardware decode
is healthy.

### Android: MediaCodec

Use `MediaCodec` asynchronously so input availability and decoded output arrive as
callbacks. Configure the hardware AVC decoder with SPS/PPS codec-specific data and the
render `Surface`. On Android 11/API 30 and later, query
`CodecCapabilities.FEATURE_LowLatency` and set `MediaFormat.KEY_LOW_LATENCY=1` (or the
runtime low-latency parameter). Low-latency mode promises not to retain buffers beyond
what the codec standard requires; it does not eliminate reference surfaces.

Surface output is the strongest simple zero-copy story in this survey: decoded output
buffers are not exposed to the CPU, and releasing an output buffer for rendering sends
it to the surface queue. A `SurfaceView` is preferable to `TextureView` for a dedicated
viewer because it gives SurfaceFlinger/HWC the best chance of using an overlay. That is
still conditional on scaling, transforms, other layers, device policy, and format.
Chrome already has a MediaCodec decoder and SurfaceControl/overlay machinery, so the
native advantage is strict queue control and reduced UI composition, not a unique
decoder.

### Windows: Media Foundation / D3D11VA

Start with the system Media Foundation H.264 decoder MFT rather than implementing the
D3D11 video decoder protocol directly. It accepts Annex-B H.264 with start codes,
supports Baseline/Main/High, exposes `CODECAPI_AVLowLatencyMode`, and can use DXVA.
Attach the application's D3D11 device through `IMFDXGIDeviceManager` and negotiate NV12
GPU surfaces. Direct D3D11VA provides finer control but adds H.264 parsing, picture and
slice parameter management, reference surfaces, and driver work without a demonstrated
latency benefit over the low-latency MFT.

Feed the decoder texture to a D3D11 video processor or shader and a flip-discard DXGI
swapchain. A frame-latency waitable object and maximum latency of one prevent the app
from building its own presentation queue. DirectFlip/Independent Flip or an MPO can
bypass some DWM work, but only under documented window coverage, scaling, format, and
occlusion conditions; it is not a general property of “native.” Tearing can reduce
latency further but is a visible quality tradeoff.

Microsoft only guarantees DXVA for the documented decoder through 1920×1088; modern
hardware often supports more, but this stream is 1920×1200. The MVP must prove actual
hardware selection at the real profile/level/resolution rather than silently accepting
a software MFT. Chromium already has a zero-copy-capable D3D11 H.264 decoder, so the
same requirement applies to the browser baseline.

### Linux: VA-API / V4L2

VA-API is the appropriate first choice on Intel/AMD Linux desktops: create H.264 VLD
decode surfaces, parse SPS/PPS/slices, submit picture/slice buffers, and retain enough
surfaces for H.264 references. Export a completed `VASurface` as DMA-BUF, then import it
to EGL/Vulkan/Wayland or KMS. This can be GPU-only, but “DMA-BUF” alone does not prove
zero-copy: producer and consumer formats, plane layout, and modifiers must intersect.

V4L2 stateful M2M decoders accept complete Annex-B chunks and return decoded capture
buffers in display order, which fits this AU stream well where such a device exists.
V4L2 stateless decoders are substantially harder: userspace owns the H.264 parser, DPB,
reference timestamps, per-frame Request API controls, and buffer lifetime. V4L2 is
important on ARM/embedded Linux but is not a universal desktop substitute for VA-API.

Linux offers the largest **conditional** gain because browser VA-API enablement and
driver integration are less uniform. It also has by far the worst test and maintenance
matrix. A native Linux client makes sense as a compatibility project for a known kiosk
image, not as the first general client.

## Transport and input

### Reuse WebTransport/QUIC

The native client can reuse the current protocol unchanged. Rust's `wtransport` has a
client endpoint and supports certificate-hash pinning, matching the server's current
self-signed certificate model. Reuse:

- server-opened unidirectional streams: one tagged H.264 AU per stream, with the
  existing 9-byte frame header;
- QUIC datagrams: supersedable mouse motion, RTT probes, and ABR feedback;
- reliable client streams: keyboard, button, wheel, and other non-supersedable input;
- existing join-keyframe, codec-parameter, reconnect, and feedback behavior.

HTTP/3/WebTransport setup overhead is paid at connection establishment. Per-frame QUIC
stream framing and crypto are tiny compared with a 0.3 ms measured LAN one-way path,
hardware decode, and refresh timing. Reusing the transport also keeps the browser and
native clients on one server protocol.

### Raw QUIC or raw UDP

**Do not use raw UDP for the MVP.** At best it saves a small fraction of the already
negligible 0.3 ms transport hop. In exchange, an AU larger than the path MTU needs
fragmentation/reassembly; loss needs detection and either recovery, FEC, or an early
IDR; discrete input needs reliability and ordering; and the product still needs
authentication, encryption, congestion control, pacing, NAT behavior, and path MTU
handling. That is a partial, less-tested reinvention of QUIC.

A custom raw-QUIC ALPN could remove the HTTP/3/WebTransport session layer while keeping
QUIC semantics, but it requires a second server protocol and cannot benefit the browser.
It is worth considering only if profiling attributes a material measured delay to the
WebTransport implementation. Current measurements rule that out.

### Input send

Native clients can read raw pointer/touch input on a dedicated thread and avoid JS main
thread stalls. That may improve **tail consistency** and capture high-rate mouse data,
but the current browser already emits compact binary motion over unreliable datagrams;
its estimated capture/pack work is ~0.2 ms. Native input is therefore a sub-millisecond
true-latency opportunity. Local cursor rendering/prediction can hide the whole video
round trip and is much more valuable perceptually, whether implemented in browser or
native.

## Where native can really win

1. **Prove and require hardware.** Native APIs can fail session creation if hardware is
   unavailable and expose the selected decoder. WebCodecs preferences are hints. This
   is valuable on misconfigured Linux systems and unusual driver/profile combinations.
2. **Own the presentation queue.** A dedicated viewer can keep zero application-level
   jitter buffer, cap outstanding decode/present work, discard stale *decoded outputs*,
   and present the newest complete frame. It must not arbitrarily drop dependent H.264
   delta AUs before decode.
3. **Avoid general-purpose UI composition.** A fullscreen video-only surface may earn
   Windows Independent Flip/MPO, an Android hardware overlay, or Linux KMS plane. These
   are conditional optimizations, not portable guarantees. Apple offers no public
   promise that a native Metal layer will direct-scan out.
4. **Remove canvas/3D texture detours.** This can matter for the gallery's 3D path. It
   is much less compelling against the already-shipped direct visible-canvas 2D path.
5. **Reduce input scheduling tails.** Raw OS input and a dedicated network task avoid
   browser-main-thread contention, but do not materially change the measured LAN RTT.
6. **Provide platform-specific reliability.** A kiosk client may be easier to lock to a
   known decoder, display, refresh rate, and fullscreen mode than an arbitrary browser
   install. This is an operations benefit as much as a latency benefit.

Native does **not** remove fixed-function decode time, H.264 DPB requirements, waiting
for the next display scan, pixel color conversion, or the measured server-side
capture/encode bottleneck. “Zero-copy” means no CPU round trip; it usually still means a
GPU shader/video-processor pass into a compositor or swapchain buffer.

## Rust and maintenance reality

Use Rust for transport, protocol parsing, input state, metrics, and lifecycle state,
with thin platform modules for decode and display. Assembly has no useful role: H.264
decode is fixed-function hardware, while framing and NAL parsing are already far below
one millisecond.

Useful building blocks include:

| Area | Practical Rust options | Caution |
|---|---|---|
| Shared QUIC | `wtransport` (already used server-side), Tokio | Preserve the exact wire protocol and cert-hash trust model |
| Apple | `objc2-video-toolbox`, `objc2-core-media`, `objc2-core-video`, Metal/Objective-C bindings | Bindings reduce FFI typing, not CoreMedia/IOSurface lifetime complexity |
| Android | `ndk` / `ndk-sys` `AMediaCodec`, `AMediaFormat`, `ANativeWindow`; small Kotlin/JNI shell if needed | MediaCodec objects are thread-affine; lifecycle and Surface ownership dominate |
| Windows | Microsoft `windows` crate for Media Foundation, D3D11, DXGI, DirectComposition | COM/MFT setup remains verbose and unsafe resource lifetime needs care |
| Linux | `cros-libva` (published as `cros-libva`), raw `libva`; `v4l`/`linux-video-core`, `drm`/Vulkan/EGL bindings | No single crate makes VA/V4L2 plus DMA-BUF modifiers portable |
| Cross-platform render | `wgpu`/`winit` can share windowing, shaders, and swapchains | Decoder-surface import is still platform-specific; forcing a CPU upload defeats the project |
| FFmpeg umbrella | `ffmpeg-next`/`ffmpeg-sys-next` can drive VideoToolbox, D3D11VA, and VA-API | Eases parsing, but opaque hw-frame negotiation and accidental downloads/copies make latency proof harder |

`vpx` bindings are irrelevant to this stream: libvpx decodes VP8/VP9, not H.264.

A realistic five-platform product is roughly **9–15 engineer-months** before ongoing
driver/OS/device regression work, even with a shared Rust core. Store packaging,
signing, auto-update, accessibility, keyboard layouts/IME, touch gestures, audio,
telemetry, reconnect behavior, and security patching multiply the surface. Native
clients also give up the browser's zero-install deployment and mature sandbox/update
channel.

## Conditional MVP architecture

If the benchmark gate passes, the macOS spike should be deliberately narrow:

```text
NSWindow/CAMetalLayer
        ▲
Metal Y+UV shader (one pass; newest completed CVPixelBuffer)
        ▲
VTDecompressionSession (HW required, realtime, no app jitter queue)
        ▲
Annex-B AU → SPS/PPS tracking + AVCC sample conversion
        ▲
wtransport client (existing AU streams, datagrams, reliable input streams)
        ▲
existing streamhost — unchanged
```

The shared Rust core owns WebTransport, the existing framing, reconnect/keyframe
behavior, ABR feedback, timestamps, and input records. The macOS layer owns
VideoToolbox/CoreVideo/Metal and exposes measured timestamps for AU received, decode
submitted, decode callback, GPU submitted, present requested, and (where the OS makes
it observable) displayed. Keep queue depth bounded, rebuild at SPS/resolution changes,
and verify—not assume—hardware decode.

Do not start with `wgpu` or FFmpeg if either makes the decoded `CVPixelBuffer` traverse
CPU memory. A later abstraction is justified only after the native Metal path proves a
real input-to-photon win.

## Decision experiment before any product work

1. Test the existing engine-specific 2D browser path on at least one current Apple
   Silicon Mac, one Windows GPU, and one Android device at their native 60/120 Hz
   modes. Record the actual decoder name/backend and whether hardware was selected.
2. Separate AU-arrival→decode-output from decode-output→display using browser tracing
   plus platform present tooling (PresentMon/ETW on Windows, Perfetto FrameTimeline on
   Android, appropriate macOS compositor tracing). Confirm with a 240 fps or faster
   input-to-photon camera test; API timestamps alone do not prove photons.
3. Compare direct visible canvas, Chrome's overlay-video route, the 3D CanvasTexture
   path, fullscreen, and a 120 Hz display. Report p50/p95 and missed-refresh counts,
   not just average decode time.
4. Build the smallest macOS VideoToolbox/Metal viewer using the same WebTransport
   session and stream. Compare on the same host/display/network with identical AUs.
5. Continue only for **≥4 ms p50, ≥8 ms p95, or a clear browser HW-decode reliability
   failure**. Otherwise stop and spend the engineering budget on capture/encode ROI,
   color conversion, capture pacing, and local cursor prediction.

## Recommendation

**No-go for a five-platform native-client program; conditional go for a macOS-only
measurement spike after real-GPU browser benchmarking.** The likely healthy-GPU win is
only a few milliseconds, while the known server-side opportunity is around 10 ms for
damage-scoped conversion/encode and the current 8 ms client paint estimate is not a
valid target. Native becomes worthwhile only for a controlled fullscreen kiosk, a
platform where browser hardware decode is demonstrably unreliable, or a measured extra
compositor frame that the native surface path actually removes.

## Primary references

- [WebCodecs specification: decoder hardware and latency hints](https://www.w3.org/TR/webcodecs/#videodecoderconfig)
- [Chromium decoder types: MediaCodec, D3D11, VA-API, V4L2, and VideoToolbox](https://chromium.googlesource.com/chromium/src/+/master/media/base/decoder.h)
- [Chromium macOS VideoToolbox decoder](https://chromium.googlesource.com/chromium/src/+/HEAD/media/gpu/mac/video_toolbox_video_decoder.cc)
- [Chromium Android MediaCodec decoder](https://chromium.googlesource.com/chromium/src/+/HEAD/media/gpu/android/media_codec_video_decoder.h)
- [Chromium D3D11 H.264 decoder and zero-copy requirements](https://chromium.googlesource.com/chromium/src/+/333f1b8b1118ade83532a7761807a6d10a8a0946/media/gpu/windows/d3d11_video_decoder.h)
- [Apple VideoToolbox overview](https://developer.apple.com/documentation/videotoolbox)
- [Apple: require hardware-accelerated decode](https://developer.apple.com/documentation/videotoolbox/kvtvideodecoderspecification_requirehardwareacceleratedvideodecoder)
- [Apple: map CoreVideo image buffers to Metal textures](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage%28_%3A_%3A_%3A_%3A_%3A_%3A_%3A_%3A_%3A%29)
- [Android MediaCodec low-latency decode](https://developer.android.com/about/versions/11/features#low-latency)
- [Android MediaCodec Surface output](https://developer.android.com/reference/android/media/MediaCodec#using-an-output-surface)
- [Microsoft Media Foundation H.264 decoder](https://learn.microsoft.com/en-us/windows/win32/medfound/h-264-video-decoder)
- [Microsoft Direct3D-aware Media Foundation transforms](https://learn.microsoft.com/en-us/windows/win32/medfound/direct3d-aware-mfts)
- [Microsoft DXGI flip/Independent Flip guidance](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/for-best-performance--use-dxgi-flip-model)
- [VA-API overview and decode-surface model](https://intel.github.io/libva/index.html)
- [Linux V4L2 stateful decoder interface](https://docs.kernel.org/userspace-api/media/v4l/dev-decoder.html)
- [Linux V4L2 stateless decoder interface](https://docs.kernel.org/userspace-api/media/v4l/dev-stateless-decoder.html)
- [Linux DMA-BUF exchange across V4L2, EGL/Vulkan, Wayland, and KMS](https://docs.kernel.org/userspace-api/dma-buf-alloc-exchange.html)
- [`wtransport` native client configuration and certificate hashes](https://docs.rs/wtransport/latest/wtransport/struct.ClientConfig.html)
- [`objc2-video-toolbox` Rust bindings](https://docs.rs/objc2-video-toolbox/latest/objc2_video_toolbox/)
- [`ndk` Rust MediaCodec bindings](https://docs.rs/ndk/latest/ndk/media/media_codec/struct.MediaCodec.html)
- [Microsoft `windows` crate Media Foundation feature](https://docs.rs/crate/windows/latest/features#Win32_Media_MediaFoundation)
- [`cros-libva` Rust bindings and support caveat](https://docs.rs/crate/cros-libva/latest)
