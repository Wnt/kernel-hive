import { useCallback, useEffect, useRef, useState } from 'react';
import { StreamClient } from './streamClient';
import {
  createStreamController,
  type StreamControlHandle,
  type StreamResolution,
} from './useStreamControl';
import { setDebugTile, clearDebugTile } from './clientDebug';
import { WebRtcFallbackClient } from './webRtcFallbackClient';

// ============================================================================
//  LIVE SESSION — streamhost WebTransport + WebCodecs
//  ---------------------------------------------------------------------------
//  The live streamhost path consumed by StreamView:
//    - decode H.264 AUs (StreamClient) → draw each VideoFrame to an offscreen
//      <canvas>; Chrome receives its captureStream() in a visible <video>.
//    - Firefox registers its visible canvas and paints directly on decode.
//    - the control handle is the shared StreamControlHandle.
//  Near-zero buffering by design: we render on decode output (no jitter buffer),
//  and captureStream is damage-gated by canvas writes — idle tiles cost ~nothing.
// ============================================================================

type LivePhase = 'idle' | 'starting' | 'connecting' | 'live' | 'error';

export interface StreamSessionOptions {
  /** Construct and expose the imperative input/control handle. */
  control?: boolean;
  /** HUD-compatible target value; streamhost itself has no receiver jitter buffer. */
  jitterBufferTargetMs?: number;
  /** Keep the HUD's automatic/manual latency-control state. */
  autoJitter?: boolean;
  /** OS id, selects the guest-quirks profile in the controller. */
  osId?: string;
}

export interface StreamSessionResult {
  phase: LivePhase;
  message: string;
  control: StreamControlHandle | null;
  stream: MediaStream | null;
  registerPaintCanvas?: (el: HTMLCanvasElement | null) => void;
  beginRestoreReconnect?: () => void;
  finishRestoreReconnect?: () => void;
  expectedReconnect: 'restore' | null;
}

// ---------------------------------------------------------------------------
//  Negotiation + session resilience
//  ---------------------------------------------------------------------------
//  The old code connected ONCE: any connect error failed immediately, and an
//  idle tile that had not yet produced a keyframe simply spun forever (or the
//  consumer fell back to the poster too eagerly). streamhost decodes on the FIRST
//  keyframe, so a slow/idle tile can legitimately take a while to paint. We now:
//    - give each attempt a generous KEYFRAME_WAIT budget for the first frame, and
//    - RETRY the whole connect + keyframe-wait a few times with backoff before the
//      first frame, and
//    - keep retrying after a live session drops or stops producing frames. The
//      already-painted canvas remains in place until the replacement session's
//      first frame arrives, avoiding a flash back to the poster during a reboot.
const KEYFRAME_WAIT_MS = 12000;                 // per-attempt budget for frame #1
const MAX_INITIAL_ATTEMPTS = 4;                  // total pre-live tries before poster fallback
const RETRY_BACKOFF_MS = [600, 1500, 3000, 6000]; // unexpected-loss retry delays
const RESTORE_BACKOFF_MS = [250, 500, 1000, 2000]; // host is expected to be briefly unavailable

export function useStreamhostSession(
  signalEndpoint: string,
  active: boolean,
  options?: StreamSessionOptions,
): StreamSessionResult {
  const [phase, setPhase] = useState<LivePhase>('idle');
  const [message, setMessage] = useState('');
  const [control, setControl] = useState<StreamControlHandle | null>(null);
  const [stream, setStream] = useState<MediaStream | null>(null);
  const [expectedReconnect, setExpectedReconnect] = useState<'restore' | null>(null);
  const beginRestoreRef = useRef<() => void>(() => undefined);
  const finishRestoreRef = useRef<() => void>(() => undefined);
  const beginRestoreReconnect = useCallback(() => beginRestoreRef.current(), []);
  const finishRestoreReconnect = useCallback(() => finishRestoreRef.current(), []);

  // ---- DIRECT-CANVAS PAINT SINK (2D grid low-latency path) ------------------
  //  The 2D StreamView registers a VISIBLE <canvas> here. When present, onVideoFrame
  //  paints the decoded VideoFrame STRAIGHT to that canvas (noVNC-style paint-on-
  //  decode) and skips the offscreen-canvas → captureStream → MediaStream → <video>
  //  hop entirely — the <video> presentation pipeline was buffering ~a frame and
  //  adding a rAF/compositor hop the direct path avoids. Refs (not state) let
  //  onVideoFrame read the sink without a React re-render.
  const paintElRef = useRef<HTMLCanvasElement | null>(null);
  const paintCtxRef = useRef<CanvasRenderingContext2D | null>(null);
  const registerPaintCanvas = useCallback((el: HTMLCanvasElement | null) => {
    if (paintElRef.current === el) return;
    paintElRef.current = el;
    // desynchronized:true is the low-latency swap-chain hint — it lets the UA skip
    // the normal DOM-paint sync so a drawImage lands on glass with minimal delay
    // (the whole point of this path). alpha:false = opaque desktop, no blend.
    paintCtxRef.current = el
      ? el.getContext('2d', { alpha: false, desynchronized: true }) as CanvasRenderingContext2D | null
      : null;
  }, []);

  const wantControl = options?.control === true;
  const jitterMs = options?.jitterBufferTargetMs ?? 50;
  const autoJitter = options?.autoJitter !== false;
  const osId = options?.osId;

  useEffect(() => {
    if (!active || !signalEndpoint) return;

    let cancelled = false;
    let client: StreamClient | null = null;
    let fallback: WebRtcFallbackClient | null = null;
    let controller: ReturnType<typeof createStreamController> | null = null;
    let canvas: HTMLCanvasElement | null = document.createElement('canvas');
    let ctx: CanvasRenderingContext2D | null = canvas.getContext('2d');
    let fallbackAudio: HTMLAudioElement | null = null;
    let captureTrack: CanvasCaptureMediaStreamTrack | null = null;
    let firstFrame = true;
    let drawImageErrLogged = false; // log a drawImage() throw ONCE (never swallow silently)

    // Retry bookkeeping.
    let liveReached = false; // at least one attempt has painted successfully
    let attemptLive = false; // the CURRENT attempt has painted successfully
    let attempt = 0;
    let watchdog = 0;        // per-attempt keyframe-wait timer
    let retryTimer = 0;      // backoff timer between attempts
    let settling = false;    // guard: ignore the onState(false) our own dispose emits
    let expectedRestore = false;
    let restoreEndpointSettled = false;

    // Live guest resolution, kept current from decoded frame size for input scaling.
    const resolution: StreamResolution = { w: 0, h: 0 };

    // Telemetry + operator commands (clientDebug): tag events with this tile and
    // run the /clientcmd poller while it is open. The snapshot hook reads the
    // CURRENT attempt's client (the closure variable is reassigned on retry).
    const debugTile = osId ?? signalEndpoint;
    setDebugTile(debugTile, {
      getSnapshot: () => fallback?.getSnapshot() ?? client?.getMetrics() ?? null,
    });

    const clearTimers = () => {
      if (watchdog) { clearTimeout(watchdog); watchdog = 0; }
      if (retryTimer) { clearTimeout(retryTimer); retryTimer = 0; }
    };

    const fail = (msg: string) => {
      if (cancelled) return;
      clearTimers();
      setPhase('error');
      setMessage(msg);
    };

    const markAttemptLive = (w: number, h: number) => {
      if (attemptLive || w <= 0 || h <= 0) return;
      attemptLive = true;
      liveReached = true;
      attempt = 0;
      if (expectedRestore) {
        expectedRestore = false;
        restoreEndpointSettled = false;
        setExpectedReconnect(null);
      }
      clearTimers();
      resolution.w = w; resolution.h = h;
      setPhase('live');
      setMessage('LIVE');
      controller?.notifyConnected();
    };

    const onVideoFrame = (frame: VideoFrame) => {
      if (cancelled) { try { frame.close(); } catch { /* noop */ } return; }
      const w = frame.displayWidth, h = frame.displayHeight;

      // ---- DIRECT-CANVAS PAINT PATH (2D grid) --------------------------------
      //  A visible canvas is registered → paint the decoded frame straight to glass
      //  and take NO offscreen/captureStream/texture detour. Synchronous drawImage
      //  only (no createImageBitmap/Promise) so it stays on the decode hot path.
      const pel = paintElRef.current, pctx = paintCtxRef.current;
      if (pel && pctx) {
        if (w > 0 && h > 0 && (pel.width !== w || pel.height !== h)) {
          pel.width = w; pel.height = h;
        }
        try {
          pctx.drawImage(frame, 0, 0);
        } catch (e) {
          if (!drawImageErrLogged) {
            drawImageErrLogged = true;
            console.error('[streamhost] direct-canvas drawImage(VideoFrame) threw:', e);
          }
        }
        try { frame.close(); } catch { /* noop */ }
        if (firstFrame && w > 0 && h > 0) firstFrame = false;
        // No MediaStream on this path — StreamView gates liveness on phase alone
        // for streamhost tiles (see StreamView `live`). This is deliberately per
        // attempt: the replacement session's first frame returns the phase to live.
        markAttemptLive(w, h);
        return;
      }

      // ---- OFFSCREEN CANVAS + captureStream PATH (Chrome) --------------------
      if (!canvas || !ctx) { try { frame.close(); } catch { /* noop */ } return; }
      if (w > 0 && h > 0 && (canvas.width !== w || canvas.height !== h)) {
        canvas.width = w; canvas.height = h;
      }
      try {
        // drawImage(VideoFrame) is accepted by BOTH Chrome and Firefox (rv ≥ 116);
        // it puts the decoded pixels on the 2D canvas backing the visible video.
        ctx.drawImage(frame, 0, 0);
      } catch (e) {
        // NEVER swallow this silently — a blank canvas here is exactly what hides a
        // "LIVE banner but no picture" render bug. Log once, keep going.
        if (!drawImageErrLogged) {
          drawImageErrLogged = true;
          console.error('[streamhost] ctx.drawImage(VideoFrame) threw — canvas will not paint:', e);
        }
      }
      try { frame.close(); } catch { /* noop */ }

      // captureStream() (no-arg) auto-captures the canvas on each drawImage above,
      // so there is nothing to push here. We deliberately do NOT call
      // track.requestFrame(): it is Chrome-only (Firefox never implemented it on the
      // track), and pairing it with captureStream(0) is what left Firefox's <video>
      // frameless → spinner forever. See the firstFrame captureStream block below.

      if (firstFrame && w > 0 && h > 0) {
        firstFrame = false;

        // A MediaStream the StreamView <video> can render, auto-captured on each
        // canvas draw so it never re-encodes and stays damage-gated.
        try {
          // NO-ARG captureStream(): the browser captures a frame each time the canvas
          // is MODIFIED — and we only ever draw on decode output, so this stays
          // damage-gated (idle tiles cost ~nothing) exactly like the old
          // captureStream(0)+requestFrame() design intended. Crucially it is the ONE
          // path that works in BOTH engines: captureStream(0) needs
          // track.requestFrame() to emit anything, and Firefox has NO requestFrame()
          // on the track (it only ever lived on the stream, non-standard) — so on
          // Firefox frameRate-0 produced ZERO frames and the <video> never painted
          // (phase went 'live', banner showed, but the picture stayed a spinner).
          const ms = canvas.captureStream();
          captureTrack = ms.getVideoTracks()[0] as CanvasCaptureMediaStreamTrack;
          setStream(ms);
        } catch { /* captureStream unsupported — the session will remain non-live */ }

      }
      markAttemptLive(w, h); // also marks a replacement session live
    };

    // Tear down just the CURRENT attempt's client + controller. The paint target,
    // canvas and capture stream deliberately survive a post-live reconnect so
    // the replacement client can paint into the same presentation surface.
    const teardownAttempt = () => {
      settling = true; // the dispose below emits onState(false) — ignore it
      try { controller?.handle.dispose(); } catch { /* noop */ }
      controller = null;
      setControl(null);
      const c = client; client = null;
      try { c?.dispose(); } catch { /* noop */ }
      const f = fallback; fallback = null;
      try { f?.dispose(); } catch { /* noop */ }
      settling = false;
    };

    const cleanup = () => {
      cancelled = true;
      clearTimers();
      clearDebugTile(debugTile); // stop the cmd poller; events lose the tile tag
      teardownAttempt();
      setControl(null);
      try { captureTrack?.stop(); } catch { /* noop */ }
      captureTrack = null;
      setStream(null);
      setExpectedReconnect(null);
      if (fallbackAudio) {
        try { fallbackAudio.pause(); fallbackAudio.srcObject = null; } catch { /* noop */ }
        fallbackAudio = null;
      }
      canvas = null; ctx = null;
    };

    // Give up on this attempt and schedule the next (or fall back to the poster).
    const scheduleRetry = (why: string) => {
      if (cancelled || retryTimer) return;
      clearTimers();
      teardownAttempt();
      attempt++;
      // Log every retry (don't hide it) so slow/idle-tile negotiation is diagnosable.
      console.warn(`[streamhost] ${signalEndpoint} reconnect attempt ${attempt} — ${why}`);
      if (!liveReached && attempt >= MAX_INITIAL_ATTEMPTS) {
        fail('timed out negotiating tile stream (poster fallback)');
        return;
      }
      // `attempt` was just incremented, so attempt 1 uses index 0. The previous
      // indexing accidentally made every first retry wait 1.5 s instead of 600 ms.
      const delays = expectedRestore ? RESTORE_BACKOFF_MS : RETRY_BACKOFF_MS;
      const delay = delays[Math.min(attempt - 1, delays.length - 1)];
      setPhase('connecting');
      setMessage(expectedRestore
        ? 'Reconnecting to restored tile…'
        : liveReached
          ? `Reconnecting to tile… (attempt ${attempt})`
          : `Reconnecting to tile… (${attempt + 1}/${MAX_INITIAL_ATTEMPTS})`);
      retryTimer = window.setTimeout(startAttempt, delay);
    };

    const startAttempt = () => {
      if (cancelled) return;
      clearTimers();
      attemptLive = false;

      const nextClient = new StreamClient({
        signalEndpoint,
        onVideoFrame: (frame) => {
          // A decoder callback can already be queued when its transport reports
          // loss. Never let that old frame cancel the replacement attempt.
          if (client !== nextClient) { try { frame.close(); } catch { /* noop */ } return; }
          onVideoFrame(frame);
        },
        onResolution: (w, h) => {
          if (w > 0 && h > 0) { resolution.w = w; resolution.h = h; }
        },
        onState: (connected, lastError) => {
          // Ignore an async close/failure from an attempt that has already been
          // replaced. Without this identity guard it can tear down the fresh one.
          if (cancelled || client !== nextClient || settling) return;
          controller?.setConnected(connected);
          if (connected) {
            if (!attemptLive) { setPhase('connecting'); setMessage('Waiting for desktop…'); }
          } else {
            // The exact advertised-codec probe runs after signaling but before
            // WebTransport. A negative result is terminal just like an absent API.
            if (nextClient.getDecoderUnsupportedReason()) {
              clearTimers();
              setPhase('error');
              setMessage(lastError || 'This browser does not support the live stream video codec.');
              return;
            }
            // This applies both before frame #1 and after a previously-live
            // transport closes. A restore can resolve OR reject wt.closed,
            // depending on browser/QUIC timing; both require a fresh signal+WT.
            scheduleRetry(lastError || 'stream unavailable');
          }
        },
      });
      client = nextClient;

      if (wantControl) {
        controller = createStreamController(client, {
          // Prefer the guest's NATIVE console geometry so the absolute-pointer
          // coordinate space spans QEMU's full live surface (never confining the
          // cursor to a fraction when ABR downscales the encode). Falls back to the
          // decoded `resolution` object before the first KIND_PARAMS arrives.
          getResolution: () => {
            const n = client?.getNativeResolution?.();
            return n && n.w > 0 && n.h > 0 ? n : resolution;
          },
          osId,
          jitterBufferTargetMs: jitterMs,
          autoJitter,
        });
        if (!cancelled) setControl(controller.handle);
      }

      // Constructor-time WebCodecs feature detection is terminal and immediate.
      // Keep the controller mounted so StreamBannerState reaches the UI, but do
      // not fetch signaling, open WebTransport, arm a watchdog, or schedule retry.
      if (nextClient.getDecoderUnsupportedReason() === 'api-unavailable') {
        setPhase('error');
        setMessage('This browser does not provide the WebCodecs video decoder required for live streaming.');
        return;
      }

      setPhase('connecting');
      setMessage(expectedRestore
        ? 'Reconnecting to restored tile…'
        : attempt === 0 && !liveReached
          ? 'Connecting to tile…'
          : `Reconnecting to tile… (attempt ${Math.max(1, attempt)})`);

      // Keyframe watchdog: the transport can be connected yet an idle tile sends
      // no keyframe. If frame #1 never lands within the budget, retry.
      watchdog = window.setTimeout(() => {
        // A terminal capability result can arrive while signaling is in flight.
        // Keep its controller/banner mounted; reconnecting cannot add codec support.
        if (nextClient.getBannerState() === 'decoder-unsupported') return;
        if (!attemptLive) scheduleRetry('no keyframe within budget');
      }, KEYFRAME_WAIT_MS);

      nextClient.connect().catch((e) => {
        if (client === nextClient) scheduleRetry(`connect failed: ${(e as Error).message}`);
      });
    };

    // WebCodecs-less fallback. Every streamhost tile gets this platform path;
    // the client selects it solely by feature detection. WebCodecs-capable
    // browsers never execute this branch and stay on WebTransport unchanged.
    const startWebRtcFallback = async () => {
      if (cancelled) return;
      setPhase('connecting');
      setMessage('Connecting via browser video fallback…');
      const next = new WebRtcFallbackClient({
        onTrack: (mediaStream) => {
          if (cancelled || fallback !== next) return;
          const track = mediaStream.getVideoTracks()[0];
          const settings = track?.getSettings();
          const w = settings?.width ?? 0, h = settings?.height ?? 0;
          if (w > 0 && h > 0) {
            resolution.w = w; resolution.h = h;
          }

          if (fallbackAudio) {
            try { fallbackAudio.pause(); fallbackAudio.srcObject = null; } catch { /* noop */ }
          }
          // The visible stream <video> is muted for autoplay parity with every
          // other path. Play the same MediaStream through a dedicated audio
          // element so the bridge's Opus track is usable after the tile-opening
          // user gesture. A blocked autoplay is harmless and video stays live.
          fallbackAudio = document.createElement('audio');
          fallbackAudio.autoplay = true;
          fallbackAudio.srcObject = mediaStream;
          void fallbackAudio.play().catch(() => { /* browser may require another gesture */ });

          setStream(mediaStream);
        },
        onState: (state, error, snapshot) => {
          if (cancelled || fallback !== next) return;
          if (state === 'live') {
            liveReached = true;
            attemptLive = true;
            if (expectedRestore) {
              expectedRestore = false;
              restoreEndpointSettled = false;
              setExpectedReconnect(null);
            }
            setPhase('live');
            setMessage('LIVE · WebRTC fallback');
          } else if (state === 'reconnecting') {
            setPhase('connecting');
            setMessage(`Reconnecting WebRTC… (attempt ${Math.max(1, snapshot.reconnectAttempt)})`);
          } else if (state === 'stalled') {
            setPhase('connecting');
            setMessage('WebRTC video stalled — recovering…');
          } else if (state === 'failed') {
            setPhase('error');
            setMessage(`WebRTC fallback failed: ${error || 'connection failed'}`);
          } else {
            setPhase('connecting');
            setMessage('Waiting for native H.264 video…');
          }
        },
      });
      fallback = next;
      try {
        const configured = await next.connect(signalEndpoint);
        if (cancelled || fallback !== next) return;
        if (!configured) {
          next.dispose();
          fallback = null;
          startAttempt(); // old server: preserve the decoder-unsupported banner
        }
      } catch (error) {
        if (cancelled || fallback !== next) return;
        fail(`WebRTC fallback failed: ${String(error)}`);
      }
    };

    // A restore is an EXPECTED discontinuity. Retire the old transport before
    // the host touches QEMU so neither Firefox's stale WebTransport object nor
    // the 2-second frame watchdog can classify it as a fault. Re-signaling waits
    // for the POST to settle, avoiding a race where we reconnect to the session
    // that is about to be reset.
    beginRestoreRef.current = () => {
      if (cancelled || expectedRestore) return;
      expectedRestore = true;
      restoreEndpointSettled = false;
      attempt = 0;
      clearTimers();
      teardownAttempt();
      setExpectedReconnect('restore');
      setPhase('connecting');
      setMessage('Restoring tile…');
    };
    finishRestoreRef.current = () => {
      if (cancelled || !expectedRestore || restoreEndpointSettled) return;
      restoreEndpointSettled = true;
      setPhase('connecting');
      setMessage('Reconnecting to restored tile…');
      // First post-restore signal fetch is immediate. Only a genuinely not-yet-
      // ready host uses the short restore-specific retry sequence above.
      if (typeof VideoDecoder === 'undefined') void startWebRtcFallback();
      else startAttempt();
    };

    setPhase('starting');
    setMessage('Connecting to tile…');
    if (typeof VideoDecoder === 'undefined') void startWebRtcFallback();
    else startAttempt();

    return cleanup;
  }, [active, signalEndpoint, wantControl, jitterMs, autoJitter, osId]);

  useEffect(() => {
    if (!active) {
      setPhase('idle');
      setMessage('');
      setControl(null);
      setStream(null);
      setExpectedReconnect(null);
    }
  }, [active]);

  return {
    phase, message, control, stream, registerPaintCanvas,
    beginRestoreReconnect, finishRestoreReconnect, expectedReconnect,
  };
}
