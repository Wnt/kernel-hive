import type { StreamBannerState } from '../../../three/streamClient';
import { S } from './styles';

// The stage's floating status layer: the fullscreen hint toast, the click-to-resume
// affordance, the fullscreen-rejection toast, the GFN-style connection banner, and
// the distinct device/stall chip stack. All decisions are computed by the
// orchestrator and passed in; this stays a pure presentational component.
export function StatusOverlays({
  hint, fs, mouseCapture, escToGuest,
  showResume, pointerLocked, acquireLock,
  playbackBlocked, onResumePlayback,
  fsError,
  showBanner, restoreReconnect, bannerState, decoderUnsupported, bannerIsDevice, bannerText,
  deviceUnderLoad, cpuCritical, lowBattery, frameStalled, decoderFailed, decoderErrShort,
  onReconnect,
}: {
  hint: boolean;
  fs: boolean;
  mouseCapture: boolean;
  escToGuest: boolean;
  showResume: boolean;
  pointerLocked: boolean;
  acquireLock: () => void;
  playbackBlocked: boolean;
  onResumePlayback: () => void;
  fsError: string | null;
  showBanner: boolean;
  restoreReconnect: boolean;
  bannerState: StreamBannerState | null;
  decoderUnsupported: boolean;
  bannerIsDevice: boolean;
  bannerText: string;
  deviceUnderLoad: boolean;
  cpuCritical: boolean;
  lowBattery: boolean;
  frameStalled: boolean;
  decoderFailed: boolean;
  decoderErrShort: string;
  onReconnect: () => void;
}) {
  return (
    <>
      {/* FULLSCREEN HINT TOAST — brief, auto-dismissing. */}
      {hint && fs && (
        <div style={S.hintToast}>
          {/* Two INDEPENDENT locks decide this copy. The mouse clause is about
              pointer capture; the Esc clause is about the SYSTEM KEYBOARD lock,
              which every streamable station takes in fullscreen — under it a tap of
              Esc reaches the guest and only a hold leaves fullscreen. Tying the
              Esc wording to the mouse flag told abs stations "Esc to exit" while
              their Esc was in fact going to the guest. */}
          {[
            mouseCapture ? 'Mouse captured' : null,
            '⌘/Ctrl+N for stats',
            escToGuest ? 'tap Esc → guest · hold Esc to exit' : 'Esc to exit',
          ].filter(Boolean).join(' · ')}
        </div>
      )}

      {/* CLICK-TO-RESUME — the browser dropped pointer lock (Esc / focus loss)
          while still in fullscreen. A click re-acquires it (the required user
          gesture) and clears Chrome's ~1s post-Esc cooldown. */}
      {fs && showResume && !pointerLocked && mouseCapture && (
        <button
          type="button"
          style={S.resumeOverlay}
          onClick={acquireLock}
        >
          <span style={S.resumeBadge}>▶</span>
          <span>Click to resume control</span>
          <span style={S.resumeSub}>mouse capture paused · hold Esc to leave fullscreen</span>
        </button>
      )}

      {/* TAP TO RESUME PLAYBACK — autoplay policy REJECTED our play() after the
          page came back to the foreground. Without this the visitor gets a
          permanent black rectangle on a session that is otherwise perfectly
          healthy: the transport is up, frames are waiting, and the only thing
          missing is the user activation a tap provides. It sits above the
          picture and below the floating bar, and it is the ONLY thing on the
          stage that can clear itself — so it must never be silent. */}
      {playbackBlocked && (
        <button type="button" style={S.resumeOverlay} onClick={onResumePlayback}>
          <span style={S.resumeBadge}>▶</span>
          <span>Tap to resume</span>
          <span style={S.resumeSub}>playback paused while you were away</span>
        </button>
      )}

      {/* FULLSCREEN REJECTION TOAST — the request was denied; no longer silent. */}
      {fsError && (
        <div style={{ ...S.hintToast, ...S.fsErrorToast }}>{fsError}</div>
      )}

      {/* GFN-STYLE CONNECTION BANNER (Section 2.6) — driven by the client-local
          `el` scorer via ctl.bannerState. 'spotty' = smoothed NETWORK score
          (latency+loss) < 60 for ≥2s (cleared > 75 for ≥2s); 'device-load' = the
          decode-queue/freeze score dwelled low while the network scored clean;
          'reconnecting' = transport closed, or unanswered pings AND total silence.
          EWMA windows are the hysteresis, so a single dropped frame never flashes. */}
      {showBanner && (
        <div style={{
          ...S.banner,
          ...(restoreReconnect || bannerState === 'reconnecting' || decoderUnsupported
            ? S.bannerReconnecting
            : bannerIsDevice ? S.bannerDevice : S.bannerSpotty),
          ...(decoderUnsupported ? S.bannerDecoderUnsupported : {}),
        }}>
          <span style={{
            ...S.bannerDot,
            ...(decoderUnsupported ? S.bannerFallbackDot : {}),
          }} />
          {bannerText}
          {/* A genuine reconnect (not a scripted restore / terminal codec fault)
              gets a LARGE tappable Reconnect — the only interactive part of the
              otherwise pointerEvents:none banner. */}
          {bannerState === 'reconnecting' && !restoreReconnect && !decoderUnsupported && (
            <button type="button" style={S.bannerReconnectBtn} onClick={onReconnect}>
              Reconnect
            </button>
          )}
        </div>
      )}

      {/* DISTINCT DEVICE/STALL CHIPS (Items 4 + 6) — a top-right stack kept
          SEPARATE from the centred network banner so a local device problem is
          never conflated with a network one. Device-under-load / low-battery are
          read-only PressureObserver+getBattery signals; the frame-stall chip is
          the idle-frame watchdog (orthogonal to the RTT-ping liveness). */}
      {(deviceUnderLoad || lowBattery || (frameStalled && !restoreReconnect) || decoderFailed) && (
        <div style={S.chipStack}>
          {decoderFailed ? (
            // Explicit decoder-failure chip: suppresses the generic stall chip
            // (the stall watchdog also latches when the decoder never paints).
            <span style={{ ...S.chip, ...S.chipDecoderFail }}>
              <span style={S.chipDot} />No video · decoder failing{decoderErrShort ? `: ${decoderErrShort}` : ''}
            </span>
          ) : frameStalled && !restoreReconnect && (
            <span style={{ ...S.chip, ...S.chipStall }}>
              <span style={S.chipDot} />No video · stream stalled
            </span>
          )}
          {deviceUnderLoad && (
            <span style={{ ...S.chip, ...S.chipLoad }}>
              <span style={S.chipDot} />Device under load{cpuCritical ? ' · critical' : ''}
            </span>
          )}
          {lowBattery && (
            <span style={{ ...S.chip, ...S.chipBattery }}>
              <span style={S.chipDot} />Low battery
            </span>
          )}
        </div>
      )}
    </>
  );
}
