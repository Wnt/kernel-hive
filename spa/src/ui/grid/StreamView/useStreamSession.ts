/* eslint-disable react-hooks/exhaustive-deps -- effects are lifted VERBATIM from
   StreamView with byte-identical dependency arrays; the refs/setters arrive as
   stable params, which defeats the rule's static ref/setState stability inference
   (the original in-component code passed the rule clean). rules-of-hooks (the
   correctness rule) stays enforced. */
import { useCallback, useEffect, useRef, useState, type RefObject } from 'react';
import type { StreamControlHandle, StreamControlState, StreamStats } from '../../../three/useStreamControl';
import { resumeVideoElement, probeVideoSink, isPausedSink } from '../../../three/streamClient/videoResume';
import { attachResumeSignals, attachSinkPauseSignal, isVisible } from '../../../three/streamClient/resumeSignals';
import { logClientEvent } from '../../../three/clientDebug';

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
}): { connected: boolean; playbackBlocked: boolean; resumePlayback: () => void } {
  // ---- RESUME THE SINK ON RETURN TO THE FOREGROUND -------------------------
  //  The bug this exists for: the effect above was the ONLY caller of play(),
  //  and it runs on `stream` identity. A background/foreground cycle never
  //  changes that identity, so an element Chrome-Android paused on the way out
  //  stayed paused on the way back — a permanent black picture on a session
  //  whose transport, decoder and encoder were all healthy. See videoResume.ts
  //  and docs/lab/STREAM-DEBUGGING.md.
  const [playbackBlocked, setPlaybackBlocked] = useState(false);
  const resumingRef = useRef(false);
  const resume = useCallback(async (why: string) => {
    if (resumingRef.current) return;
    const el = videoRef.current;
    if (!isPausedSink(probeVideoSink(el), isVisible())) return;
    resumingRef.current = true;
    try {
      const r = await resumeVideoElement(el, isVisible());
      if (r.outcome === 'resumed') {
        setPlaybackBlocked(false);
        // The row that tells a future reader the picture came back and WHY it
        // was gone. `advanced` is the jump to the live edge, in seconds.
        logClientEvent('sink-resumed', `why=${why} advanced=${r.advanced.toFixed(2)}s seeked=${r.seeked}`);
      } else if (r.outcome === 'blocked') {
        // Autoplay policy said no. The visitor gets an affordance, never a
        // black rectangle — this is the branch that must not be silent.
        setPlaybackBlocked(true);
        logClientEvent('sink-blocked', `why=${why} err=${r.error ?? 'unknown'}`);
      }
    } finally {
      resumingRef.current = false;
    }
  }, []);

  // A visitor tap carries user activation, which is exactly what a rejected
  // play() was missing — so this call is the one with a real chance.
  const resumePlayback = useCallback(() => { void resume('gesture'); }, [resume]);

  useEffect(() => {
    if (!streamable) return;
    const offSignals = attachResumeSignals(() => { void resume('foreground'); });
    const offPause = attachSinkPauseSignal(() => videoRef.current, () => { void resume('sink-pause'); });
    return () => { offSignals(); offPause(); };
  }, [streamable, resume]);

  // ---- attach the live MediaStream to the visible 2D <video> ----------------
  useEffect(() => {
    const el = videoRef.current;
    if (!el) return;
    if (stream) {
      if (el.srcObject !== stream) el.srcObject = stream;
      void resume('attach');
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

  return { connected, playbackBlocked, resumePlayback };
}
