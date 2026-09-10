// ============================================================================
//  landing/heroStatus — the strip above the machine, and where its numbers
//  come from.
//  ---------------------------------------------------------------------------
//  The strip reads `RUNNING · 1024×768 · MS-DOS + Windows 3.x · win311`, and
//  every cell in it has to be TRUE, because it is the only thing on the page
//  claiming that what the visitor is looking at is a real computer. A strip
//  that says RUNNING over a dead frame teaches the opposite of what the museum
//  is for.
//
//  Where each number comes from, and why:
//
//  * RUNNING is not the claim succeeding and not the socket opening. It is
//    frames arriving — the same rule the lab works by, that the framebuffer is
//    the only proof a guest reacted (AGENTS.md rule 9). The page can see that
//    without asking StreamView anything: a <video> with a non-zero videoWidth,
//    or a paint canvas with a non-zero width, is a picture that decoded.
//  * The RESOLUTION is that same measurement, which is why it is exact and why
//    it changes when a guest changes mode instead of repeating a number
//    somebody typed into a registry file. The gallery manifest carries no
//    resolution field at all (checked, 2026-09-10), so a static one would have
//    had to be invented — and an invented 1024x768 over a guest that switched
//    to 640x480 is precisely the lie this strip must not tell.
//  * The LINEAGE is the manifest's own `lineage`, the line the placard uses.
//  * The ID is the registry id, which is also the station's directory name and
//    its SH_STATION: a station has ONE name (AGENTS.md), so printing it is
//    printing the thing an operator can go and look at.
// ============================================================================

import type { StopReason } from './heroSession';

export type HeroRunState = 'poster' | 'connecting' | 'running' | 'queued' | 'stopped';

export interface MediaSize {
  width: number;
  height: number;
}

/**
 * The first real picture size among the media elements the stream mounted.
 *
 * Takes plain numbers rather than DOM nodes so it is testable under the Node
 * vitest environment this repo runs (vitest.config.ts — no jsdom), and so the
 * caller owns the one browser-specific line: a `<video>` reports
 * videoWidth/videoHeight, a direct-paint `<canvas>` reports width/height, and
 * the stream client picks between them per engine (StreamView's `directCanvas`).
 * Zeroes are not a small picture, they are "nothing has decoded yet", which is
 * why they are skipped rather than rendered as 0x0.
 */
export function pickMediaSize(candidates: readonly Partial<MediaSize>[]): MediaSize | null {
  for (const candidate of candidates) {
    const width = candidate.width ?? 0;
    const height = candidate.height ?? 0;
    if (width > 0 && height > 0) return { width, height };
  }
  return null;
}

/** The word in the first cell. Present tense, because it is a live fact. */
export function runStateLabel(state: HeroRunState): string {
  switch (state) {
    case 'running':
      return 'RUNNING';
    case 'connecting':
      return 'CONNECTING';
    case 'queued':
      return 'ALL BUSY';
    case 'stopped':
      return 'STOPPED';
    case 'poster':
      return 'NOT CONNECTED';
  }
}

export interface StatusFacts {
  state: HeroRunState;
  /** Measured from the decoded picture; null until the first frame. */
  size: MediaSize | null;
  /** The manifest's `lineage` for the station on screen. */
  lineage?: string;
  /** The registry id — stationDir and SH_STATION are the same word. */
  station?: string;
}

/**
 * The strip, cell by cell.
 *
 * Absent facts are DROPPED rather than filled with a placeholder. A dash where
 * the resolution goes reads as a broken readout; a strip with three cells until
 * the first frame arrives and four after it reads as a machine warming up,
 * which is what is actually happening.
 */
export function statusCells(f: StatusFacts): string[] {
  const cells = [runStateLabel(f.state)];
  if (f.size) cells.push(`${f.size.width}×${f.size.height}`);
  if (f.lineage) cells.push(f.lineage);
  if (f.station) cells.push(f.station);
  return cells;
}

/**
 * The line under the machine, which is the page's actual promise.
 *
 * It changes with the state because the promise does: before a frame it is a
 * statement of intent, after one it is a description of what is already true,
 * and the difference is the only thing that tells a visitor whether to start
 * typing yet.
 */
export function heroCaption(state: HeroRunState, station: string | null, stop?: StopReason): string {
  const name = station ?? 'this machine';
  switch (state) {
    case 'running':
      return `Your keys and your mouse are going straight into ${name}. Nothing is recorded, and the next visitor gets a clean copy.`;
    case 'connecting':
      return `Waking ${name} up. The picture is live the moment it appears — no plugin, no download.`;
    case 'queued':
      return 'Every copy of that machine is in use this second. Pick another one, or wait a moment and try again.';
    case 'stopped':
      return stoppedLine(stop);
    case 'poster':
      return 'A still, not a stream — this browser cannot receive a live picture.';
  }
}

/**
 * The line UNDER the stage when the picture is a still.
 *
 * Deliberately not the capability sentence again: that one is already printed
 * across the poster itself (heroPolicy.heroBlockedLine), and a page that says
 * the same thing twice in two type sizes reads as an error page. This is the
 * other half of the answer — what this visitor CAN do here — because a browser
 * that cannot stream can still read every placard in the museum.
 */
export const POSTER_FALLBACK_CAPTION =
  'The collection below is all still here: every exhibit has its placard, its photographs and the story of what it was for.';

/**
 * Why the machine went away, in the visitor's terms.
 *
 * Never "disconnected" and never a blank stage: two of the three reasons are
 * this page taking the machine back on purpose, and a visitor who is not told
 * that assumes something broke and reloads — which is the one thing that would
 * make the pool worse rather than better.
 */
function stoppedLine(stop: StopReason | undefined): string {
  switch (stop) {
    case 'never-driven':
      return 'Nothing was clicked, so the machine went back to the pool for the next visitor. Take another one — it is one press.';
    case 'hidden':
      return 'This tab went into the background, so the machine was handed back rather than held for nobody. Take another whenever you like.';
    default:
      return 'This machine has been handed back to the pool. Take another whenever you like.';
  }
}
