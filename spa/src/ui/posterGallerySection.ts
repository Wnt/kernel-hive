import type { PosterBlock, PosterDoc, PosterInlineRun } from '../types';

function runsText(runs: readonly PosterInlineRun[]): string {
  return runs
    .map((run) => (run.kind === 'text' ? run.text : runsText(run.children)))
    .join('');
}

/**
 * The image carousel (docs/lab/POSTER-GALLERY-SPEC.md Phase 1) renders
 * "immediately after the last block of the Origins section (before the next
 * h2)". Poster bodies are a flat `PosterBlock[]`, not a section tree, so this
 * walks the list to find the block index the carousel should follow: the
 * "## Origins" heading itself, then every block up to (but not including) the
 * next level-2 heading, or the end of the poster if Origins runs to the end.
 *
 * Returns -1 when the poster has no "Origins" heading at all. Every round-1
 * gallery station's prose does have one (see any registry/posters/*.md), but a
 * poster is never assumed to -- this is the defensive, not the expected,
 * path.
 */
export function findOriginsSectionEnd(blocks: readonly PosterBlock[]): number {
  const start = blocks.findIndex(
    (block) => block.kind === 'heading' && block.level === 2 && runsText(block.runs).trim() === 'Origins',
  );
  if (start === -1) return -1;
  for (let index = start + 1; index < blocks.length; index += 1) {
    const block = blocks[index];
    if (block.kind === 'heading' && block.level === 2) return index - 1;
  }
  return blocks.length - 1;
}

/**
 * The block index the carousel should follow, or -1 to render nothing.
 * -1 covers both the round-1 non-gallery posters (the common case: `gallery`
 * absent entirely) and the defensive case of an empty `images` array --
 * either way ExhibitPoster's block map never matches, so no carousel mounts
 * and the poster's layout is byte-for-byte what it was before this feature.
 */
export function gallerySlotIndex(blocks: readonly PosterBlock[], gallery: PosterDoc['gallery']): number {
  if (!gallery || gallery.images.length === 0) return -1;
  return findOriginsSectionEnd(blocks);
}
