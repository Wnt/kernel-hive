/* eslint-disable react-hooks/exhaustive-deps -- effects are lifted VERBATIM from
   StreamView with byte-identical dependency arrays; the refs/setters arrive as
   stable params, which defeats the rule's static ref/setState stability inference
   (the original in-component code passed the rule clean). rules-of-hooks (the
   correctness rule) stays enforced. */
import { useEffect, type RefObject } from 'react';
import type { StreamControlHandle, StreamControlState, StreamStats } from '../../../three/useStreamControl';

// Media/control/audio/stats wiring — the contiguous run of connect-time effects
// extracted verbatim from StreamView. Returns the derived `connected` flag.
export function useStreamSession({
  videoRef, stream, control, streamable, ctl, controlRef, containerRef, setCtl, setStats,
}: {
  videoRef: RefObject<HTMLVideoElement | null>;
  stream: MediaStream | null;
  control: StreamControlHandle | null;
  streamable: boolean;
  ctl: StreamControlState | null;
  controlRef: RefObject<StreamControlHandle | null>;
  containerRef: RefObject<HTMLDivElement | null>;
  setCtl: (s: StreamControlState | null) => void;
  setStats: (s: StreamStats | null) => void;
}): boolean {
  // ---- attach the live MediaStream to the visible 2D <video> ----------------
  useEffect(() => {
    const el = videoRef.current;
    if (!el) return;
    if (stream) {
      if (el.srcObject !== stream) el.srcObject = stream;
      el.play?.().catch(() => { /* muted autoplay should be allowed */ });
    } else {
      try { el.srcObject = null; } catch { /* noop */ }
    }
  }, [stream]);

  // ---- claim host on connect (mouse works implicitly; keyboard needs control) --
  useEffect(() => {
    if (control) { try { control.requestControl(); } catch { /* not ready */ } }
  }, [control]);

  // ---- subscribe to control-plane state (channelOpen / host / locked) -------
  useEffect(() => {
    if (!control) { setCtl(null); return; }
    setCtl(control.getState());
    return control.onStateChange(setCtl);
  }, [control]);

  const connected = ctl?.channelOpen ?? false;

  // ---- AUDIO ALWAYS ON: enable on the handle as soon as control connects.
  //  setAudioEnabled(true) also resumes the AudioContext. The open came from a
  //  user click, so the page has user activation and playback is allowed.
  useEffect(() => {
    if (!streamable || !connected) return;
    const h = controlRef.current;
    if (!h) return;
    try { h.setAudioEnabled(true); } catch { /* channel gone */ }
  }, [streamable, connected]);

  // ---- gesture safety net: any pointer down on the stage ALWAYS resumes audio,
  //  in case the connect-time resume was blocked by autoplay policy (idempotent).
  useEffect(() => {
    if (!streamable) return;
    const el = containerRef.current;
    // Resume on the FIRST user gesture of ANY kind — pointer, key, or touch — since
    // a keyboard-first / cinema user may never point-click the stage. keydown/
    // touchstart go on window (keydown never targets the container). Idempotent.
    const resume = () => { try { controlRef.current?.setAudioEnabled(true); } catch { /* noop */ } };
    el?.addEventListener('pointerdown', resume);
    window.addEventListener('keydown', resume);
    window.addEventListener('touchstart', resume, { passive: true });
    return () => {
      el?.removeEventListener('pointerdown', resume);
      window.removeEventListener('keydown', resume);
      window.removeEventListener('touchstart', resume);
    };
  }, [streamable]);

  // ---- poll live stream stats for the debug overlay -------------------------
  useEffect(() => {
    if (!control) { setStats(null); return; }
    let alive = true;
    const tick = () => {
      control.getStats().then((s) => { if (alive) setStats(s); }).catch(() => {});
    };
    tick();
    const id = window.setInterval(tick, 1000);
    return () => { alive = false; clearInterval(id); };
  }, [control]);

  return connected;
}
