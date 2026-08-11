import { useCallback, useEffect, useRef, useState } from 'react';
import type { OSBinding } from '../../three/archetypeRegistry';
import { useLiveStream } from '../../three/useLiveStream';
import type { StreamControlHandle, StreamControlState, StreamStats } from '../../three/useStreamControl';
import type { StreamBannerState, StreamExitReason } from '../../three/streamClient';
import { useMuseum } from '../../state/store';
import { keyboardLockApi } from './StreamView/keyboardLock';
import { currentFullscreenElement, leaveFullscreen } from './StreamView/fullscreen';
import { isFirefoxEngine } from './StreamView/env';
import { exitReasonCopy } from './StreamView/exitReason';
import { useDevicePressure } from './StreamView/useDevicePressure';
import { buildStreamhostRows } from './StreamView/buildStreamhostRows';
import { S, SPIN_KEYFRAMES, FS_CSS, POWER_ON_CSS, PRESENT_CSS } from './StreamView/styles';
import { videoStyleFor } from './StreamView/videoStyle';
import { presentAspectFor } from './presentAspect';
import { PosterCard } from './StreamView/PosterCard';
import { OnScreenKeyboard } from '../keyboard/OnScreenKeyboard';
import { PowerOnOverlay } from './StreamView/PowerOnOverlay';
import { BootVideoOverlay } from './StreamView/BootVideoOverlay';
import { DebugOverlay } from './StreamView/DebugOverlay';
import { StageMenu } from './StreamView/StageMenu';
import { StatusOverlays } from './StreamView/StatusOverlays';
import { useStreamSession } from './StreamView/useStreamSession';
import { useStreamInput } from './StreamView/useStreamInput';
import { usePinchZoom } from './StreamView/usePinchZoom';
import { useTouchControl } from './StreamView/useTouchControl';
import { TouchOverlays } from './StreamView/TouchOverlays';
import { KeyboardToggleBadge } from './StreamView/KeyboardToggleBadge';
import { useMobileLayout } from './StreamView/useMobileLayout';
import { MOBILE_CSS } from './StreamView/mobileCss';
import { deriveStatus } from './StreamView/statusDerive';
import { useCinemaMode } from './StreamView/useCinemaMode';
import { useRestoreFlow } from './StreamView/useRestoreFlow';
import { useDemoProgram } from './StreamView/useDemoProgram';
import { bannerCopy } from './StreamView/bannerCopy';
import { posterFor } from '../../data/posterIndex';
import type { GestureState, Vec2, ZoomState } from './StreamView/types';

// StreamView is the shared full-viewport 2D live/showcase component.
//    default export function StreamView({ os, onExit }:
//        { os: OSBinding; onExit: () => void })
//    where `os` is adapted from one validated runtime manifest entry.
//    - streamhost -> WebTransport+WebCodecs on a <video> (or a direct-paint
//      <canvas> on Firefox), behind the shared StreamControlHandle.
//    - showcase -> a poster/placard card; no connection attempt.
//  This orchestrator wires the presentational subcomponents (StreamView/*.tsx)
//  and the extracted effect hooks (useStreamSession / useStreamInput /
//  useCinemaMode / useRestoreFlow). The heavily-commented rationale for each
//  behaviour lives next to its code in those modules.

export default function StreamView({
  os,
  onExit,
  playBootVideo = true,
  onOpenPoster,
  posterOpen = false,
}: {
  os: OSBinding;
  onExit: () => void;
  playBootVideo?: boolean;
  onOpenPoster?: () => void;
  posterOpen?: boolean;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  // The exhibit stage: the picture plus the letterbox bars around it, which are
  // live pointing surface in trackpad mode (useStreamInput / usePinchZoom).
  const stageRef = useRef<HTMLDivElement>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  // Direct-paint canvas for the streamhost path (2D grid low-latency render).
  const canvasRef = useRef<HTMLCanvasElement>(null);

  // Streamhost bindings are live; showcase bindings fall through to a poster.
  const transport = os.transport;
  const streamable = transport === 'streamhost';
  const isStreamhost = transport === 'streamhost';
  // streamhost stations CAN render through a DIRECT visible <canvas> (paint-on-decode)
  // — gated to Firefox (faster there); Chrome keeps its lower-latency overlay
  // <video>. WebCodecs-less Firefox uses the native WebRTC MediaStream fallback,
  // which must stay on a real <video>. See env.isFirefoxEngine.
  const directCanvas = isStreamhost && isFirefoxEngine && typeof VideoDecoder !== 'undefined';
  const nativeWebRtcFallback = isStreamhost && typeof VideoDecoder === 'undefined';
  // The EXHIBIT is a touchscreen device (android / postmarketOS / Sailfish), so
  // a pointer press should behave like a finger on its glass. This is NOT a
  // statement about the VISITOR's hardware — for that see env.isTouchDevice().
  // Confusing the two cost two no-op fixes on 2026-08-05: a stylus on a desktop
  // exhibit is pointerType 'pen' with touchExhibit=false, so it takes the mouse
  // path, not the touch recognizer. See docs/lab/INPUT-DEBUGGING.md.
  const touchExhibit =
    (os as { isTouch?: boolean }).isTouch ?? os.archetypeId === 'touch-phone';
  const displayName = os.displayName ?? os.osId;
  // MOBILE LAYOUT gate (device, not station archetype): three fixed regions —
  // thin bar / maximized stage / collapsible keyboard sheet.
  const mobile = useMobileLayout();

  // coldBoot: frame the connect as a CRT power-on (PowerOnOverlay) instead of a
  // spinner. bootVideo: same-origin recorded power-on clip (BootVideoOverlay),
  // takes the overlay slot ahead of coldBoot + spinner. bootManifest: the merged
  // /boot/index.json fields for THIS station (poster/sprite/vtt/duration).
  const coldBoot = !!os.coldBoot;
  const bootVideo = playBootVideo ? os.bootVideo : undefined;
  const bootManifest = useMuseum((s) => s.vms.find((v) => v.id === os.osId)?.bootVideo);

  // pointerRel: SH_POINTER=rel stations (qnx/freedos/msdoswin1) fed raw movementX/Y
  // as DIRECT type=4 RelMotion under lock.
  //
  // mouseCapture: GFN-style whole-mouse capture (pointer lock in fullscreen).
  // ONLY the relative-pointer stations take it, because only they NEED it — a
  // relative guest has no way to be told "the pointer is here", so it must be
  // fed deltas, and deltas only exist under lock. An ABSOLUTE station is mapped
  // point-for-point from the picture rect, which works identically in
  // fullscreen and windowed; locking it bought nothing and cost the visitor
  // their cursor (the UA hides it under lock, and no CSS can bring it back).
  // So fullscreen on an abs station is now just the windowed view, full-bleed:
  // same 1:1 pointer, same crosshair, no click-to-resume, no captured state.
  const pointerRel = !!os.pointerRel;
  const mouseCapture = transport === 'streamhost' && !touchExhibit && pointerRel;

  // ERA-CORRECT 4:3 PRESENTATION (presentAspect.ts) — non-square-pixel vintage/
  // kiosks fill a display-aspect box (object-fit:fill), else default OFF.
  const present = presentAspectFor(os.osId);
  const presentFill = !!present;

  // Open the live stream + control half (dormant unless streamable).
  const {
    stream, phase, message, control, registerPaintCanvas,
    beginRestoreReconnect, finishRestoreReconnect, expectedReconnect,
  } = useLiveStream(
    os,
    streamable,
    streamable ? { control: true } : undefined,
  );

  // Register the visible <canvas> as the streamhost direct-paint sink. Decoded
  // frames land on it straight from onVideoFrame (no captureStream/<video> hop).
  useEffect(() => {
    if (!directCanvas || !registerPaintCanvas) return;
    registerPaintCanvas(canvasRef.current);
    return () => registerPaintCanvas(null);
  }, [directCanvas, registerPaintCanvas]);

  // The direct-canvas path has NO MediaStream, so its liveness is phase-only; the
  // Chrome and native-WebRTC-fallback paths require the MediaStream.
  const live = directCanvas ? phase === 'live' : phase === 'live' && !!stream;
  const mediaLive = streamable && live;

  const [fs, setFs] = useState(false);
  const [ctl, setCtl] = useState<StreamControlState | null>(null);
  const [stats, setStats] = useState<StreamStats | null>(null);
  const [oskOpen, setOskOpen] = useState(false);
  // DEBUG OVERLAY hidden by default (Cmd/Ctrl+N toggles).
  const [debug, setDebug] = useState(false);
  // Fullscreen hint toast + floating-chrome visibility.
  const [hint, setHint] = useState(false);
  const [chromeVisible, setChromeVisible] = useState(true);
  // Transient message shown when a fullscreen REQUEST is rejected (not silent).
  const [fsError, setFsError] = useState<string | null>(null);
  const fsErrorTimer = useRef(0);
  const [restoreState, setRestoreState] = useState<'idle' | 'busy' | 'ok' | 'err'>('idle');
  const restoreTimer = useRef(0);

  const controlRef = useRef(control);
  controlRef.current = control;
  const hideTimer = useRef(0);
  const hintTimer = useRef(0);
  // ---- POINTER-LOCK state (GFN-style whole-mouse capture) ------------------
  //  Refs (read inside event handlers without stale closures) + a little UI state.
  const [pointerLocked, setPointerLocked] = useState(false);
  // "Click to resume control" affordance, shown when the browser drops the lock.
  const [showResume, setShowResume] = useState(false);
  const lockedRef = useRef(false);                 // are we pointer-locked right now?
  const fsRef = useRef(false);                      // latest `fs` for handlers
  const wantControlRef = useRef(false);             // GFN Of: user wants capture
  const unadjustedRef = useRef(true);               // GFN xf: request unadjustedMovement
  const unknownErrRef = useRef(0);                  // GFN Pf: post-Esc UnknownError backoff
  // Accumulated ABSOLUTE virtual cursor in guest px (movementX/Y integrator).
  const vcursorRef = useRef<Vec2 | null>(null);
  // Last known guest point (seed for the virtual cursor on lock-engage).
  const lastGuestRef = useRef<Vec2 | null>(null);
  // Buttons whose DOWN was forwarded to the guest. Fullscreen/pointer-lock/focus
  // transitions can suppress the matching DOM pointerup, so lifecycle handlers
  // flush this set explicitly (releaseAllKeys does not include mouse buttons).
  const pressedButtonsRef = useRef(new Set<number>());

  const releaseHeldButtons = useCallback((target?: StreamControlHandle | null) => {
    const h = target ?? controlRef.current;
    const vc = vcursorRef.current;
    const g = vc
      ? { x: Math.round(vc.x), y: Math.round(vc.y) }
      : lastGuestRef.current;
    for (const button of pressedButtonsRef.current) {
      try { h?.sendMouseButton(button, false, g?.x, g?.y); } catch { /* channel gone */ }
    }
    pressedButtonsRef.current.clear();
  }, []);

  // ---- CLIENT-SIDE PINCH-ZOOM + PAN (Item 5) — LOCAL CSS transform state -----
  //  Pure local magnification of the <video>; NEVER sends input to the guest.
  const [zoom, setZoom] = useState<ZoomState>({ s: 1, x: 0, y: 0, animated: false });
  const zoomPointersRef = useRef<Map<number, Vec2>>(new Map());
  const gestureRef = useRef<GestureState>({
    mode: 'none', s: 1, x: 0, y: 0, startDist: 1, startScale: 1,
    startMid: { x: 0, y: 0 }, startTx: 0, startTy: 0, panStart: { x: 0, y: 0 }, passThrough: null,
    aStart: { x: 0, y: 0 }, bStart: { x: 0, y: 0 }, twoStartT: 0, scrollLast: { x: 0, y: 0 },
  });

  // ---- TOUCH CONTROL (T-1/T-3/T-4/T-5) — recognizer + trackpad + overlay refs ---
  //  Drives useStreamInput's touch path; `badge`/`setArm` back the armed-state
  //  chip, `trackpadMode` picks the direct vs relative model (the touch default;
  //  a hovering S-Pen switches it to direct), and the cursor refs feed the
  //  overlays. Emitted button-0
  //  rides pressedButtonsRef so releaseHeldButtons flushes any latched drag.
  const touch = useTouchControl({ pointerRel, controlRef, pressedButtonsRef, lastGuestRef, gestureRef, stageRef, presentAspect: present });

  const exit = useCallback(() => {
    if (window.isSecureContext) {
      try { keyboardLockApi()?.unlock?.(); } catch { /* not supported */ }
    }
    try { if (document.pointerLockElement) document.exitPointerLock?.(); } catch { /* noop */ }
    releaseHeldButtons();
    // Flush every held scancode so a forwarded Esc DOWN (or modifier) can't stick
    // when we tear the session down without a blur/keyup.
    try { controlRef.current?.releaseAllKeys(); } catch { /* noop */ }
    try { controlRef.current?.releaseControl(); } catch { /* channel may be gone */ }
    if (currentFullscreenElement()) { void leaveFullscreen().catch(() => { /* noop */ }); }
    onExit();
  }, [onExit, releaseHeldButtons]);

  // ---- POINTER-LOCK request/reconcile (GFN np() port) -----------------------
  //  The element that takes the lock: the <video>/<canvas> for streamhost stations
  //  (null for everything else). Requesting MUST happen inside a user-activation
  //  chain (a click) — never from a bare effect — or the browser rejects it.
  const lockTargetEl = useCallback((): (HTMLElement & {
    requestPointerLock?: (opts?: { unadjustedMovement?: boolean }) => Promise<void> | void;
  }) | null => {
    if (mouseCapture) return directCanvas ? canvasRef.current : videoRef.current;
    return null;
  }, [mouseCapture, directCanvas]);

  // The live picture element (streamhost <canvas> or <video>). BootVideoOverlay
  // samples this to detect when the live layer has painted real (non-black)
  // content. Stable for the component's life (directCanvas is constant per station).
  const getLiveSurface = useCallback(
    (): HTMLVideoElement | HTMLCanvasElement | null =>
      directCanvas ? canvasRef.current : videoRef.current,
    [directCanvas],
  );

  const requestLock = useCallback(() => {
    const el = lockTargetEl();
    if (!el || !el.requestPointerLock) return;
    if (document.pointerLockElement === el) return;
    // GFN Pf<3 gate: after Chrome's ~1s post-Esc cooldown throws UnknownError a
    // few times, stop busy-retrying. A fresh user click resets unknownErrRef.
    if (unknownErrRef.current >= 3) { setShowResume(fsRef.current); return; }
    let p: Promise<void> | void;
    try {
      p = el.requestPointerLock({ unadjustedMovement: unadjustedRef.current });
    } catch { p = undefined; }
    // Chrome returns a Promise; older engines return undefined (assume success —
    // pointerlockchange will confirm). Only the Promise path can report errors.
    if (p && typeof (p as Promise<void>).then === 'function') {
      (p as Promise<void>)
        .then(() => { unknownErrRef.current = 0; })
        .catch((err: unknown) => {
          const name = (err as { name?: string })?.name;
          if (name === 'NotSupportedError' && unadjustedRef.current) {
            // Engine has Pointer Lock but not the unadjustedMovement option:
            // permanently drop to a plain lock and immediately re-request.
            unadjustedRef.current = false;
            requestLock();
          } else if (name === 'UnknownError') {
            unknownErrRef.current += 1;   // post-Esc cooldown — bounded retry
            setShowResume(fsRef.current);
          } else {
            setShowResume(fsRef.current);
          }
        });
    }
  }, [lockTargetEl]);

  // Kick a (re)lock from a fresh user gesture: sets want-control, clears the
  // post-Esc backoff, hides the resume affordance, and requests the lock.
  const acquireLock = useCallback(() => {
    wantControlRef.current = true;
    unknownErrRef.current = 0;
    setShowResume(false);
    requestLock();
  }, [requestLock]);
  // Live ref to acquireLock so the []-deps fullscreenchange effect (which must not
  // re-subscribe) can call the latest closure without going stale.
  const acquireLockRef = useRef(acquireLock);
  acquireLockRef.current = acquireLock;

  // ---- floating-chrome reveal helper (used by edge-hover + debug toggle) ----
  //  DEFINED EARLY (was originally after the fullscreenchange effect): both the
  //  debug-toggle effect in useStreamInput and useCinemaMode need it, and
  //  useStreamInput runs first. Stable ([]-deps) useCallback — repositioning it
  //  ahead of those hooks is behaviour-neutral (no effect setup/cleanup, identical
  //  memoised value every render).
  const revealChrome = useCallback(() => {
    setChromeVisible(true);
    if (hideTimer.current) clearTimeout(hideTimer.current);
    hideTimer.current = window.setTimeout(() => setChromeVisible(false), 2600);
  }, []);

  // ---- media / control-plane / audio / stats effects (#44–49) ---------------
  const connected = useStreamSession({
    videoRef, stream, control, streamable, ctl, controlRef, containerRef, setCtl, setStats,
  });

  // ---- keyboard + pointer + wheel event machinery (#50–55) -----------------
  useStreamInput({
    streamable, inputSuspended: posterOpen, releaseHeldButtons, control, live, touchExhibit, mouseCapture, acquireLock,
    directCanvas, revealChrome, setDebug, touch: touch.controller,
    pointerRel, presentFill, penHoverRef: touch.penHoverRef,
    controlRef, fsRef, lockedRef, vcursorRef, lastGuestRef, pressedButtonsRef,
    videoRef, canvasRef, trackpadRef: touch.trackpadRef, stageRef,
  });
  // ---- LOCAL pinch-zoom / pan view transform (no guest input but the wheel) -
  usePinchZoom({
    streamable, live, directCanvas, setZoom,
    controlRef, containerRef, videoRef, canvasRef, zoomPointersRef, gestureRef,
    trackpadRef: touch.trackpadRef, stageRef,
  });

  // ---- fullscreen + keyboard-lock + pointer-lock reconcile (#56–62) ---------
  const { toggleFullscreen } = useCinemaMode({
    streamable, mouseCapture, fs, pointerRel,
    containerRef, controlRef,
    releaseHeldButtons, acquireLockRef, revealChrome, requestLock, lockTargetEl, acquireLock,
    setFs, setChromeVisible, setHint, setShowResume, setPointerLocked, setFsError,
    fsErrorTimer, hideTimer, hintTimer,
    fsRef, lockedRef, wantControlRef, vcursorRef, lastGuestRef, unknownErrRef, unadjustedRef,
  });

  // ---- RESTORE TO GOLDEN (streamhost only) ---------------------------------
  const { restoreToGolden } = useRestoreFlow({
    osId: os.osId, restoreState, setRestoreState,
    beginRestoreReconnect, finishRestoreReconnect, restoreTimer,
  });

  // ---- TYPE-IN DEMO PROGRAM (registry-declared stations only) -----------------
  const demo = useDemoProgram({ osId: os.osId, streamable, controlRef });

  // ---- status line + debug readout (pure derivation in statusDerive.ts) ----
  const { dotColor, statusLabel, bufReadout, resStr, codecStr } = deriveStatus({
    transport, streamable, phase, mediaLive, connected, nativeWebRtcFallback,
    displayName, live, message, stats,
    resolution: control?.getResolution() ?? null,
  });

  // ---- picture style: pixelation + pinch-zoom + present-aspect (videoStyle.ts)
  const videoStyle = videoStyleFor({ nativeWidth: control?.getResolution()?.w ?? 0, zoom, present });

  // ---- STREAMHOST codec / ABR overlay rows (Section 4) ---------------------
  const sh = stats?.streamhost ?? null;
  const shRows = sh ? buildStreamhostRows(sh, stats) : null;

  // GFN-style connection banner (Section 2.6). Only streamhost drives it.
  const bannerState: StreamBannerState | null =
    streamable && transport === 'streamhost' ? (ctl?.bannerState ?? null) : null;
  const restoreReconnect = expectedReconnect === 'restore';
  const showBanner = restoreReconnect
    || bannerState === 'spotty'
    || bannerState === 'reconnecting'
    || bannerState === 'decoder-unsupported';
  const decoderUnsupported = bannerState === 'decoder-unsupported';

  // ---- STRUCTURED EXIT REASON (Item 3) + IDLE-FRAME STALL (Item 4) ----------
  const exitReason: StreamExitReason | null =
    streamable && transport === 'streamhost' ? (ctl?.exitReason ?? null) : null;
  const frameStalled = streamable && transport === 'streamhost' ? !!ctl?.stalled : false;

  // ---- EXPLICIT DECODER-FAILURE STATE (≥3 configure/decode failures) --------
  const decoderFailed = bannerState === 'decoder-failed';
  const decoderErrShort = (() => {
    const m = ctl?.decoderError;
    if (!m) return '';
    return m.length > 60 ? `${m.slice(0, 59)}…` : m;
  })();

  // ---- DEVICE PRESSURE (Item 6) — observe only while a live stream is on -----
  const pressure = useDevicePressure(mediaLive);
  const deviceUnderLoad = pressure.cpu === 'serious' || pressure.cpu === 'critical';

  // Banner copy (pure derivation in bannerCopy.ts).
  const { bannerText, bannerIsDevice } = bannerCopy({
    restoreReconnect, restoring: restoreState === 'busy',
    bannerState, decoderUnsupported, deviceUnderLoad, exitReason,
  });

  // The stage menu is chrome: in fullscreen it auto-hides with everything else.
  const menuVisible = !fs || chromeVisible;

  return (
    <div
      ref={containerRef}
      className="sv-root"
      style={S.root}
      data-fs={fs ? '1' : '0'}
      data-capture={mouseCapture ? '1' : '0'}
      data-locked={pointerLocked ? '1' : '0'}
      data-mobile={mobile ? '1' : '0'}
      data-present-fill={presentFill ? '1' : '0'}
    >
      <style>{SPIN_KEYFRAMES}{FS_CSS}{POWER_ON_CSS}{PRESENT_CSS}{MOBILE_CSS}</style>

      <div ref={stageRef} className="sv-stage" style={S.stage}>
        {/* The exhibit's only chrome: a hamburger in the stage's top-left and
            every control behind it. In fullscreen it auto-hides with the rest
            of the chrome and comes back on the top-edge reveal / ⌘-Ctrl+N. */}
        {menuVisible && (
          <StageMenu
            fs={fs}
            dotColor={dotColor}
            statusLabel={statusLabel}
            streamable={streamable}
            transport={transport}
            mobile={mobile}
            oskOpen={oskOpen}
            onToggleOsk={() => setOskOpen((v) => !v)}
            restoreState={restoreState}
            restoreToGolden={restoreToGolden}
            demoLabel={demo.program?.label}
            demoState={demo.state}
            demoTypeIn={demo.typeIn}
            toggleFullscreen={toggleFullscreen}
            exit={exit}
            posterAvailable={!!posterFor(os.osId)}
            onOpenPoster={onOpenPoster}
          />
        )}

        {streamable && decoderUnsupported ? (
          <PosterCard os={os} displayName={displayName}
            note="Live streaming needs a browser with WebCodecs H.264 video decoding. Try Chrome, or a desktop browser." />
        ) : streamable ? (
          <>
            {directCanvas ? (
              // DIRECT-PAINT CANVAS (Firefox streamhost) — decoded frames drawn
              // straight to glass in onVideoFrame (no captureStream / <video> hop).
              <canvas
                ref={canvasRef}
                className="sv-video"
                style={videoStyle}
              />
            ) : (
              <video
                ref={videoRef}
                className="sv-video"
                style={videoStyle}
                muted
                autoPlay
                playsInline
                {...({ 'webkit-playsinline': 'true' } as any)}
              />
            )}
            {bootVideo ? (
              // BOOT-VIDEO stations: replay the recorded power-on clip while the live
              // golden connects behind it, then swap invisibly on the first live
              // frame. Takes the overlay slot ahead of coldBoot + the spinner.
              <BootVideoOverlay
                src={bootManifest?.mp4 ?? bootVideo}
                poster={bootManifest?.poster}
                sprite={bootManifest?.sprite}
                vtt={bootManifest?.vtt}
                durationHint={bootManifest?.durationMs}
                live={live}
                getLiveSurface={getLiveSurface}
              />
            ) : coldBoot ? (
              // COLD-BOOT stations: dramatic CRT power-on instead of a spinner.
              <PowerOnOverlay
                displayName={displayName}
                eraLabel={os.eraLabel}
                accent={os.accentColor}
                live={live}
                errored={phase === 'error'}
                errorText={exitReasonCopy(exitReason) ?? message ?? 'No signal'}
              />
            ) : (
              !live && (
                <div style={S.overlay}>
                  <div style={S.spinner} />
                  <p style={S.overlayText}>
                    {phase === 'error'
                      ? (exitReasonCopy(exitReason) ?? message ?? 'Stream unavailable')
                      : (message || 'Connecting…')}
                  </p>
                  <p style={S.overlaySub}>{os.eraLabel}</p>
                </div>
              )
            )}
          </>
        ) : transport === 'showcase' ? (
          <PosterCard os={os} displayName={displayName}
            note="Showcase exhibit — a poster and placard only. Not interactively streamable in this build." />
        ) : (
          <PosterCard os={os} displayName={displayName}
            note="This exhibit is not available on the 2D stream path." />
        )}

        {/* DEBUG OVERLAY — hidden by default; Cmd/Ctrl+N toggles. */}
        {debug && streamable && (
          <DebugOverlay
            displayName={displayName}
            transport={transport}
            shRows={shRows}
            stats={stats}
            bufReadout={bufReadout}
            resStr={resStr}
            codecStr={codecStr}
          />
        )}

        {/* Floating status layer: hint toast, click-to-resume, fs-error toast,
            connection banner, and the distinct device/stall chip stack. */}
        <StatusOverlays
          hint={hint}
          fs={fs}
          mouseCapture={mouseCapture}
          escToGuest={streamable}
          showResume={showResume}
          pointerLocked={pointerLocked}
          acquireLock={acquireLock}
          fsError={fsError}
          showBanner={showBanner}
          restoreReconnect={restoreReconnect}
          bannerState={bannerState}
          decoderUnsupported={decoderUnsupported}
          bannerIsDevice={bannerIsDevice}
          bannerText={bannerText}
          deviceUnderLoad={deviceUnderLoad}
          cpuCritical={pressure.cpu === 'critical'}
          lowBattery={pressure.lowBattery}
          frameStalled={frameStalled}
          decoderFailed={decoderFailed}
          decoderErrShort={decoderErrShort}
          onReconnect={acquireLock}
        />

        {/* TOUCH affordances — mobile + live only: the one-shot right-click badge
            (T-1), one-time coachmark, and the trackpad cursor sprite (T-3). Which
            show depends on the touch model. */}
        {mobile && mediaLive && (
          <TouchOverlays
            touch={touch}
            gestureRef={gestureRef}
            control={control}
            pointerRel={pointerRel}
            onPan={(p) => setZoom({ s: gestureRef.current.s, ...p, animated: false })}
            presentAspect={present}
          />
        )}

        {/* On-screen-keyboard opener — mobile's always-on bottom-right badge,
            mirroring TouchControlBadge's right-click arm on the bottom-left.
            Hidden once the keyboard is open: closing it is the keyboard
            sheet's own job (onRequestClose below), so the badge would just be
            a second, redundant "on" toggle sitting over the sheet. */}
        {mobile && streamable && !oskOpen && (
          <KeyboardToggleBadge onOpen={() => setOskOpen(true)} />
        )}
      </div>

      {/* Shared per-OS on-screen keyboard: mobile = collapsible bottom sheet
          (max 1/3 viewport, fixed screen-space — never affected by the video
          zoom transform); desktop = today's inline footer. */}
      {streamable && oskOpen && (
        <OnScreenKeyboard
          handle={control}
          osId={os.osId}
          variant={mobile ? 'sheet' : 'inline'}
          onRequestClose={() => setOskOpen(false)}
        />
      )}
    </div>
  );
}
