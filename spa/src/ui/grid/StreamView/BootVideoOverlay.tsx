import { useEffect, useMemo, useRef, useState } from 'react';
import { parseThumbVtt, thumbAt, type Thumb } from '../thumbVtt';
import { S } from './styles';

// ---------------------------------------------------------------------------
//  BootVideoOverlay — the BOOT-VIDEO REPLAY experience (flag-gated on bootVideo).
//  ---------------------------------------------------------------------------
//  Drop-in sibling of PowerOnOverlay, mounted in the same stage slot when the
//  station carries a recorded power-on clip. It plays that clip in a native
//  <video> (autoplay muted playsInline, preload=auto) while the live checkpoint
//  connects behind it, exposing scrub (currentTime), speed (0.5/1/2/4×) and a
//  WebVTT sprite-crop hover preview. Its media is pinned to the same full-stage
//  geometry as the live surface. On the first live frame it PINS the clip to its
//  last frame and fades ITSELF out over the already-painting live layer
//  beneath (reveal-before-drop, §5.3): because clip[last] === checkpoint[first] the
//  fade is pixel-insurance only, then the overlay unmounts. pointerEvents stays
//  'none' on the root (so click-to-acquire pointer-lock reaches the media
//  beneath); only the transport controls opt back into 'auto', and the whole
//  root goes 'auto' while the scrubber is actively grabbed.
// ---------------------------------------------------------------------------
// Resolve sibling boot assets by convention from the mp4 URL (spec §2.8 layout:
// /boot/<id>/{boot.mp4,poster.jpg,sprite.jpg,thumbs.vtt}).
function bootAssetSiblings(src: string): { poster: string; vtt: string; dir: string } {
  const dir = src.replace(/[^/]*$/, '');
  return { dir, poster: `${dir}poster.jpg`, vtt: `${dir}thumbs.vtt` };
}

// Fetch + parse the thumbnail VTT once; [] when absent (no preview, no error).
// `spriteOverride` (from the /boot/index.json manifest) makes the captured sprite
// sheet authoritative for every cue, in case the VTT's relative ref and the
// manifest path ever diverge; absent ⇒ each cue's own resolved src is used.
function useThumbs(vttUrl: string, spriteOverride?: string): Thumb[] {
  const [thumbs, setThumbs] = useState<Thumb[]>([]);
  useEffect(() => {
    let cancelled = false;
    fetch(vttUrl)
      .then((r) => (r.ok ? r.text() : Promise.reject(new Error(String(r.status)))))
      .then((txt) => {
        if (cancelled) return;
        const cues = parseThumbVtt(txt, vttUrl);
        setThumbs(spriteOverride ? cues.map((c) => ({ ...c, src: spriteOverride })) : cues);
      })
      .catch(() => { /* no thumbnail track — scrubbing still works, no preview */ });
    return () => { cancelled = true; };
  }, [vttUrl, spriteOverride]);
  return thumbs;
}

export function BootVideoOverlay({
  src, poster: posterProp, sprite, vtt: vttProp, durationHint,
  live, getLiveSurface,
}: {
  src: string;
  // P3e: captured manifest paths (/boot/index.json). Each falls back to the
  // by-convention sibling if the manifest omits it, so an absent index.json
  // leaves behaviour unchanged.
  poster?: string;
  sprite?: string;
  vtt?: string;
  durationHint?: number;   // clip duration in ms (durationMs) — seeds the scrub range
  live: boolean;
  // Getter for the live picture element beneath the overlay (<canvas>/<video>).
  // Sampled once `live` is true to hold the pinned last clip frame until the live
  // layer paints REAL (non-black) content — see the first-non-black-frame effect.
  getLiveSurface?: () => HTMLVideoElement | HTMLCanvasElement | null;
}) {
  const siblings = useMemo(() => bootAssetSiblings(src), [src]);
  const poster = posterProp ?? siblings.poster;
  const vtt = vttProp ?? siblings.vtt;
  const vref = useRef<HTMLVideoElement>(null);
  const barRef = useRef<HTMLDivElement>(null);
  const [scrub, setScrub] = useState(false);   // user is grabbing the slider
  const [t, setT] = useState(0);
  // Seed the scrub range from the manifest duration hint (ms→s) so the slider is
  // usable before <video> metadata loads; onLoadedMetadata replaces it with the
  // real measured duration.
  const [dur, setDur] = useState(durationHint ? durationHint / 1000 : 0);
  const [rate, setRate] = useState(1);
  const [muted, setMuted] = useState(false); // intent: unmuted; falls back to muted only if the browser blocks unmuted autoplay
  const [revealing, setRevealing] = useState(false);
  const [gone, setGone] = useState(false);
  const [videoEnded, setVideoEnded] = useState(false); // clip finished (natural end or user skip)
  const [preview, setPreview] = useState<{ cue: Thumb; left: number } | null>(null);
  // livePainted flips true once the live surface beneath has actually painted
  // real (non-black) content — NOT merely when `live` (phase===live) is true. The
  // first live frame the bridge delivers is often black for a beat; revealing on
  // `live` alone flashed that black through. See the sampler effect below.
  const [livePainted, setLivePainted] = useState(false);
  const thumbs = useThumbs(vtt, sprite);

  // Autoplay UNMUTED by default — the click that opened the station is a fresh user
  // gesture, which most browsers accept for playback with sound. If the autoplay
  // policy still blocks unmuted, fall back to muted playback (so the boot is at
  // least shown) and flip the state so the 🔇 toggle appears — one click restores
  // audio and raises the site's media-engagement, so later stations autoplay with sound.
  useEffect(() => {
    const v = vref.current;
    if (!v) return;
    v.muted = false;
    void v.play().then(() => setMuted(false)).catch(() => {
      v.muted = true;
      setMuted(true);
      void v.play().catch(() => {});
    });
  }, []);
  useEffect(() => { if (vref.current) vref.current.playbackRate = rate; }, [rate]);

  // SUSTAINED-NON-BLACK DETECTOR — once `live`, poll the live surface (the
  // <canvas>/<video> beneath) via rAF: drawImage a downscaled sample into a tiny
  // offscreen canvas and read back mean luma. The bridge's live stream can FLICKER
  // black for a few frames right after connect (a non-black frame, then another
  // black one, then it settles), so revealing on the FIRST non-black frame let a
  // later black dip punch through during the fade. Instead require the surface to
  // read non-black on a few CONSECUTIVE polls (reset the run on any black sample)
  // so we only reveal once the live layer is stably painting. A ~2000ms TIMEOUT
  // FALLBACK force-sets livePainted even if the surface stays black (cross-origin
  // taint, decode stall, all-black guest) — we NEVER strand the user on the clip.
  useEffect(() => {
    if (!live) return;
    let raf = 0;
    let done = false;
    let nonBlackSince = 0;           // timestamp of the current unbroken non-black run
    const SUSTAIN_MS = 200;          // live must read non-black continuously this long
    const sampler = document.createElement('canvas');
    sampler.width = 24; sampler.height = 24;
    const sctx = sampler.getContext('2d', { willReadFrequently: true });
    const LUMA_THRESHOLD = 6; // mean luma 0..255; above this ⇒ real content painted
    const finish = () => { if (done) return; done = true; setLivePainted(true); };
    const poll = () => {
      if (done) return;
      let nonBlack = false;
      const surf = getLiveSurface?.();
      if (surf && sctx) {
        // Source dims: <video> exposes videoWidth/Height, <canvas> width/height.
        const sw = (surf as HTMLVideoElement).videoWidth || (surf as HTMLCanvasElement).width || 0;
        const sh = (surf as HTMLVideoElement).videoHeight || (surf as HTMLCanvasElement).height || 0;
        if (sw > 0 && sh > 0) {
          try {
            sctx.drawImage(surf, 0, 0, sampler.width, sampler.height);
            const { data } = sctx.getImageData(0, 0, sampler.width, sampler.height);
            let sum = 0;
            for (let i = 0; i < data.length; i += 4) {
              sum += 0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2];
            }
            nonBlack = sum / (data.length / 4) > LUMA_THRESHOLD;
          } catch { /* tainted / not decodable — treat as black, fallback covers it */ }
        }
      }
      const now = performance.now();
      // Wall-clock sustained window (NOT a frame count) so it rides out the bridge's
      // connect-time black flickers identically whether the client paints at 60fps
      // or a stuttering software-decode rate. Any black sample restarts the run.
      if (nonBlack) {
        if (!nonBlackSince) nonBlackSince = now;
        if (now - nonBlackSince >= SUSTAIN_MS) { finish(); return; }
      } else {
        nonBlackSince = 0;
      }
      raf = requestAnimationFrame(poll);
    };
    raf = requestAnimationFrame(poll);
    const fallback = window.setTimeout(finish, 2000);
    return () => { done = true; cancelAnimationFrame(raf); clearTimeout(fallback); };
  }, [live, getLiveSurface]);

  // HANDOFF — swap to the live station only once the CLIP HAS FINISHED (played through,
  // or the user skipped / scrubbed to the end), NOT when `live` merely becomes ready.
  // loadvm golden restores in ~1s, so gating on `live` cut the boot video off almost
  // immediately. The live station is readied in the background WHILE the clip plays; we
  // swap when the clip is done. Pin to the last frame (== checkpoint first frame) so the
  // held image matches live even on a mid-clip skip, and gate the reveal on
  // livePainted (real non-black live content) to kill the bridge's black-first-frame
  // flash — with a safety fallback so a finished clip never strands the viewer if the
  // live layer never paints. Don't yank the clip out from under an active scrub.
  useEffect(() => {
    if (!videoEnded || scrub) { return; }
    const v = vref.current;
    if (v && v.duration && Number.isFinite(v.duration)) {
      try { if (v.currentTime < v.duration) v.currentTime = v.duration; v.pause(); } catch { /* noop */ }
    }
    const reveal = () => { setRevealing(true); return window.setTimeout(() => setGone(true), 820); };
    if (livePainted) { const id = reveal(); return () => clearTimeout(id); }
    const fb = window.setTimeout(reveal, 4000); // clip done but live never painted — don't strand
    return () => clearTimeout(fb);
  }, [videoEnded, scrub, livePainted]);
  if (gone) return null;

  const onBarMove = (e: React.MouseEvent<HTMLElement>) => {
    if (!dur || thumbs.length === 0) return;
    const bar = barRef.current;
    if (!bar) return;
    const rect = bar.getBoundingClientRect();
    const frac = Math.min(Math.max((e.clientX - rect.left) / rect.width, 0), 1);
    const cue = thumbAt(thumbs, frac * dur);
    if (!cue) return;
    // Centre the preview on the cursor, clamped to the bar ends.
    const left = Math.min(Math.max(e.clientX - rect.left - cue.w / 2, 0), rect.width - cue.w);
    setPreview({ cue, left });
  };

  return (
    <div
      style={{
        ...S.pwRoot,
        // Transparent, not black: the clip hands over to the live picture in the
        // same stage box, so both must letterbox against the SAME mat (S.stage —
        // gallery paper windowed, cinema black in fullscreen) or the handoff
        // flashes at the seam.
        background: 'transparent',
        pointerEvents: scrub ? 'auto' : 'none',
        opacity: revealing ? 0 : 1,
        transition: 'opacity 700ms ease',
      }}
      aria-hidden
    >
      <video
        ref={vref}
        src={src}
        poster={poster}
        style={{ ...S.video, ...S.bootVideo, pointerEvents: 'none', cursor: 'default' }}
        playsInline
        preload="auto"
        {...({ 'webkit-playsinline': 'true' } as Record<string, string>)}
        onLoadedMetadata={(e) => { const d = e.currentTarget.duration; if (Number.isFinite(d) && d > 0) setDur(d); }}
        onTimeUpdate={(e) => { if (!scrub) setT(e.currentTarget.currentTime); }}
        onEnded={() => setVideoEnded(true)}
      />

      {/* Transport controls — pinned bottom, opt back into pointer events. */}
      <div style={S.bootControls}>
        <div style={S.bootRate}>
          {[0.5, 1, 2, 4].map((r) => (
            <button
              key={r}
              type="button"
              onClick={() => setRate(r)}
              style={rate === r ? { ...S.bootRateBtn, ...S.bootRateOn } : S.bootRateBtn}
              title={`Play at ${r}×`}
            >
              {r}×
            </button>
          ))}
          <button
            type="button"
            onClick={() => {
              const v = vref.current;
              if (!v) return;
              const nextMuted = !v.muted;
              v.muted = nextMuted;
              setMuted(nextMuted);
              if (!nextMuted) void v.play?.().catch(() => {});
            }}
            style={S.bootRateBtn}
            title={muted ? 'Unmute' : 'Mute'}
            aria-label={muted ? 'Unmute boot audio' : 'Mute boot audio'}
          >
            {muted ? '🔇' : '🔊'}
          </button>
          <button
            type="button"
            onClick={() => setVideoEnded(true)}
            style={S.bootRateBtn}
            title="Skip to the live machine"
          >
            Skip ⏭
          </button>
        </div>
        <div ref={barRef} style={S.bootBar}>
          {preview && (
            <div
              style={{
                ...S.scrubPreview,
                left: preview.left,
                width: preview.cue.w,
                height: preview.cue.h,
                backgroundImage: `url(${preview.cue.src})`,
                backgroundPosition: `-${preview.cue.x}px -${preview.cue.y}px`,
              }}
            />
          )}
          <input
            type="range"
            min={0}
            max={dur || 0}
            step={0.02}
            value={t}
            style={S.bootScrub}
            aria-label="Scrub boot video"
            onPointerDown={() => { setScrub(true); vref.current?.pause(); }}
            onPointerUp={() => {
              setScrub(false);
              const v = vref.current;
              if (!v) return;
              // Released near the end ⇒ treat as "skip to live"; otherwise resume playback.
              if (dur && v.currentTime >= dur - 0.3) setVideoEnded(true);
              else void v.play?.().catch(() => {});
            }}
            onMouseMove={onBarMove}
            onMouseLeave={() => setPreview(null)}
            onChange={(e) => {
              const v = vref.current;
              const nt = +e.target.value;
              if (v) { try { v.currentTime = nt; } catch { /* noop */ } }
              setT(nt);
            }}
          />
        </div>
      </div>
    </div>
  );
}
