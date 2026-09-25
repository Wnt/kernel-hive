import type { CSSProperties, RefObject } from 'react';
import type { VMManifestEntry } from '../../../types';
import { BootVideoOverlay } from './BootVideoOverlay';
import { PowerOnOverlay } from './PowerOnOverlay';
import { S } from './styles';

// ---------------------------------------------------------------------------
//  StagePicture — the live picture element plus the overlay that stands in for
//  it until the first frame (boot-video replay, cold-boot power-on, or the
//  connect spinner). StreamView hangs it on the stage, or a DeviceStage puts
//  it inside a drawn display; either way the overlays are absolutely placed in
//  whatever box holds the picture.
// ---------------------------------------------------------------------------
export function StagePicture({
  directCanvas, canvasRef, videoRef, videoStyle,
  bootVideo, bootManifest, getLiveSurface, coldBoot,
  displayName, eraLabel, accentColor, live, phase, message, failText,
}: {
  directCanvas: boolean;
  canvasRef: RefObject<HTMLCanvasElement | null>;
  videoRef: RefObject<HTMLVideoElement | null>;
  videoStyle: CSSProperties;
  bootVideo: string | undefined;
  bootManifest: VMManifestEntry['bootVideo'];
  getLiveSurface: () => HTMLVideoElement | HTMLCanvasElement | null;
  coldBoot: boolean;
  displayName: string;
  eraLabel: string;
  accentColor: string;
  live: boolean;
  phase: string;
  message: string | null | undefined;
  /** Why the stream ended, in visitor words (exitReasonCopy ?? message). */
  failText: string | null | undefined;
}) {
  return (
    <>
      {directCanvas ? (
        // DIRECT-PAINT CANVAS (Firefox streamhost) — decoded frames drawn
        // straight to glass in onVideoFrame (no captureStream / <video> hop).
        <canvas ref={canvasRef} className="sv-video" style={videoStyle} />
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
        // checkpoint connects behind it, then swap invisibly on the first live
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
          eraLabel={eraLabel}
          accent={accentColor}
          live={live}
          errored={phase === 'error'}
          errorText={failText ?? 'No signal'}
        />
      ) : (
        !live && (
          <div style={S.overlay}>
            <div style={S.spinner} />
            <p style={S.overlayText}>
              {phase === 'error' ? (failText ?? 'Stream unavailable') : (message || 'Connecting…')}
            </p>
            <p style={S.overlaySub}>{eraLabel}</p>
          </div>
        )
      )}
    </>
  );
}
