import { useEffect, useState } from 'react';
import { S } from './styles';

// ---------------------------------------------------------------------------
//  PowerOnOverlay — the COLD-BOOT power-on EXPERIENCE (flag-gated).
//  ---------------------------------------------------------------------------
//  Shown ONLY for stations with coldBoot=true, in place of the generic spinner,
//  while the live stream is connecting. It stages the classic CRT switch-on:
//    1. dark tube → a bright horizontal flyback line snaps in and blooms open to
//       full raster (pw-on), warm phosphor glow + scanlines + vignette settle;
//    2. a tasteful "Powering on…" placard (machine name + era + a pulsing power
//       LED in the station accent) sits centre while the real BIOS/POST streams in
//       underneath — the placard NEVER covers the live picture once it arrives;
//    3. the instant the first live frame lands (`live`), a short degauss-bloom
//       reveal (pw-reveal) brightens then fades the whole overlay to nothing,
//       handing the screen to the live boot. The component then unmounts itself.
//  pointerEvents:none throughout, so the live media underneath is interactive the
//  moment it paints. Respects prefers-reduced-motion (skips the transforms, keeps
//  a simple fade). Engine-safe: transform/opacity/filter/gradients only.
// ---------------------------------------------------------------------------
export function PowerOnOverlay({
  displayName, eraLabel, accent, live, errored, errorText,
}: {
  displayName: string;
  eraLabel: string;
  accent: string;
  live: boolean;
  errored: boolean;
  errorText: string;
}) {
  // `gone` unmounts the overlay a beat AFTER the first live frame so the degauss
  // reveal can play; `revealing` triggers that reveal animation.
  const [gone, setGone] = useState(false);
  const [revealing, setRevealing] = useState(false);
  useEffect(() => {
    if (!live) { setGone(false); setRevealing(false); return; }
    setRevealing(true);
    const t = window.setTimeout(() => setGone(true), 820);
    return () => clearTimeout(t);
  }, [live]);
  if (gone) return null;

  const cls = `pw-crt${revealing ? ' pw-reveal' : ''}${errored ? ' pw-fault' : ''}`;
  return (
    <div className={cls} style={S.pwRoot} aria-hidden>
      <div className="pw-tube" style={S.pwTube}>
        <div className="pw-scan" style={S.pwScan} />
        <div className="pw-vig" style={S.pwVig} />
        <div className="pw-card" style={S.pwCard}>
          <span
            className="pw-led"
            style={{ ...S.pwLed, background: accent, color: accent }}
          />
          <span style={S.pwName}>{displayName}</span>
          <span style={S.pwStatus}>
            {errored ? errorText : 'Powering on…'}
          </span>
          <span style={S.pwEra}>{eraLabel}</span>
        </div>
      </div>
    </div>
  );
}
