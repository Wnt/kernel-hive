import { describe, expect, it } from 'vitest';
import type { PosterBlock, PosterDoc, PosterGalleryImage } from '../types';
import { findOriginsSectionEnd, gallerySlotIndex } from './posterGallerySection';

const SAMPLE_IMAGE: PosterGalleryImage = {
  src: '/posters/widget/gallery/01-widget.webp',
  alt: 'A beige widget',
  caption: 'The widget, 1985.',
  author: 'Evan-Amos',
  license: 'Public domain',
  licenseId: 'pd',
  licenseUrl: 'https://creativecommons.org/publicdomain/mark/1.0/',
  shareAlike: false,
  sourceUrl: 'https://commons.wikimedia.org/wiki/File:Widget.jpg',
  sourceName: 'Wikimedia Commons',
  width: 1600,
  height: 1067,
};

function heading(level: 2 | 3, text: string): PosterBlock {
  return { kind: 'heading', level, runs: [{ kind: 'text', text }] };
}

function paragraph(text: string): PosterBlock {
  return { kind: 'paragraph', runs: [{ kind: 'text', text }] };
}

describe('findOriginsSectionEnd', () => {
  it('stops at the block right before the next h2', () => {
    const blocks: PosterBlock[] = [
      heading(2, 'Origins'),
      paragraph('First origins paragraph.'),
      paragraph('Second origins paragraph.'),
      heading(2, 'Significance'),
      paragraph('Significance paragraph.'),
    ];
    expect(findOriginsSectionEnd(blocks)).toBe(2);
  });

  it('an h3 inside Origins does not end the section', () => {
    const blocks: PosterBlock[] = [
      heading(2, 'Origins'),
      paragraph('Intro.'),
      heading(3, 'A sub-point'),
      paragraph('More detail.'),
      heading(2, 'Legacy'),
    ];
    expect(findOriginsSectionEnd(blocks)).toBe(3);
  });

  it('runs to the end of the poster when Origins has no following heading', () => {
    const blocks: PosterBlock[] = [heading(2, 'Origins'), paragraph('Only paragraph.')];
    expect(findOriginsSectionEnd(blocks)).toBe(1);
  });

  it('returns -1 when the poster has no Origins heading', () => {
    const blocks: PosterBlock[] = [heading(2, 'History'), paragraph('No Origins here.')];
    expect(findOriginsSectionEnd(blocks)).toBe(-1);
  });

  it('matches heading text assembled from runs, not just plain text runs', () => {
    const blocks: PosterBlock[] = [
      { kind: 'heading', level: 2, runs: [{ kind: 'strong', children: [{ kind: 'text', text: 'Origins' }] }] },
      paragraph('Paragraph under an emphasised heading.'),
    ];
    expect(findOriginsSectionEnd(blocks)).toBe(1);
  });
});

describe('gallerySlotIndex', () => {
  const blocks: PosterBlock[] = [
    heading(2, 'Origins'),
    paragraph('First origins paragraph.'),
    heading(2, 'Significance'),
  ];

  it('is -1 -- render no carousel -- when the poster has no gallery at all', () => {
    const gallery: PosterDoc['gallery'] = undefined;
    expect(gallerySlotIndex(blocks, gallery)).toBe(-1);
  });

  it('is -1 when a gallery object is present but images is empty', () => {
    expect(gallerySlotIndex(blocks, { images: [] })).toBe(-1);
  });

  it('delegates to findOriginsSectionEnd when a non-empty gallery is present', () => {
    expect(gallerySlotIndex(blocks, { images: [SAMPLE_IMAGE] })).toBe(1);
  });
});
