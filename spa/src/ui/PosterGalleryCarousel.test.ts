import { createElement } from 'react';
import { act, create, type ReactTestRenderer } from 'react-test-renderer';
import { describe, expect, it } from 'vitest';
import type { PosterAdLink, PosterGalleryImage } from '../types';
import PosterGalleryCarousel from './PosterGalleryCarousel';

const IMAGES: PosterGalleryImage[] = [
  {
    src: '/posters/widget/gallery/01-widget.webp',
    alt: 'A beige widget on a plain background',
    caption: 'The widget in its original case, 1985.',
    author: 'Evan-Amos',
    license: 'Public domain',
    licenseId: 'pd',
    licenseUrl: 'https://creativecommons.org/publicdomain/mark/1.0/',
    shareAlike: false,
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Widget.jpg',
    sourceName: 'Wikimedia Commons',
    width: 1600,
    height: 1067,
  },
  {
    src: '/posters/widget/gallery/02-widget-drive.webp',
    alt: "The widget's companion drive",
    caption: 'The companion drive, sold separately.',
    author: 'Jane Photographer',
    license: 'Creative Commons Attribution-ShareAlike 4.0',
    licenseId: 'cc-by-sa-4.0',
    licenseUrl: 'https://creativecommons.org/licenses/by-sa/4.0/',
    shareAlike: true,
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Widget-drive.jpg',
    sourceName: 'Wikimedia Commons',
    width: 1200,
    height: 900,
  },
];

const AD_LINKS: PosterAdLink[] = [
  {
    title: '"Buy the widget today" — 1985 magazine advertisement',
    url: 'https://example.org/scan',
    source: 'Internet Archive',
  },
];

function renderCarousel(images: PosterGalleryImage[], adLinks?: PosterAdLink[]): ReactTestRenderer {
  let renderer!: ReactTestRenderer;
  act(() => {
    renderer = create(createElement(PosterGalleryCarousel, { images, adLinks, idPrefix: 'test' }));
  });
  return renderer;
}

function liveRegionText(renderer: ReactTestRenderer): string {
  return renderer.root.findByProps({ id: 'test-gallery-live' }).children.join('');
}

describe('PosterGalleryCarousel', () => {
  it('shows one image at a time with counter, dots, and a credit line that links out', () => {
    const renderer = renderCarousel(IMAGES, AD_LINKS);
    const img = renderer.root.findByType('img');
    expect(img.props.src).toBe(IMAGES[0].src);
    expect(img.props.alt).toBe(IMAGES[0].alt);
    expect(img.props.loading).toBe('lazy');

    const dots = renderer.root.findAllByProps({ role: 'tab' });
    expect(dots).toHaveLength(2);

    const links = renderer.root.findAllByType('a');
    const authorLink = links.find((link) => link.props.href === IMAGES[0].sourceUrl);
    const licenseLink = links.find((link) => link.props.href === IMAGES[0].licenseUrl);
    expect(authorLink).toBeDefined();
    expect(authorLink!.props.target).toBe('_blank');
    expect(authorLink!.props.rel).toBe('noreferrer');
    expect(licenseLink).toBeDefined();

    expect(liveRegionText(renderer)).toBe(`Image 1 of 2: ${IMAGES[0].alt}`);
    renderer.unmount();
  });

  it('advances on next-button click and wraps around', () => {
    const renderer = renderCarousel(IMAGES);
    const next = renderer.root.findByProps({ 'aria-label': 'Next image' });

    act(() => next.props.onClick());
    expect(renderer.root.findByType('img').props.src).toBe(IMAGES[1].src);

    act(() => next.props.onClick());
    expect(renderer.root.findByType('img').props.src).toBe(IMAGES[0].src);
    renderer.unmount();
  });

  it('moves slides on ArrowLeft/ArrowRight when the carousel has focus', () => {
    const renderer = renderCarousel(IMAGES);
    const section = renderer.root.findByProps({ className: 'exhibit-poster-gallery' });
    const prevented: string[] = [];
    const fireKey = (key: string) => {
      act(() =>
        section.props.onKeyDown({ key, preventDefault: () => prevented.push(key) } as unknown as KeyboardEvent),
      );
    };

    fireKey('ArrowRight');
    expect(renderer.root.findByType('img').props.src).toBe(IMAGES[1].src);
    fireKey('ArrowLeft');
    expect(renderer.root.findByType('img').props.src).toBe(IMAGES[0].src);
    expect(prevented).toEqual(['ArrowRight', 'ArrowLeft']);

    // Keys other than the arrows are ignored.
    fireKey('Enter');
    expect(renderer.root.findByType('img').props.src).toBe(IMAGES[0].src);
    renderer.unmount();
  });

  it('renders "Period advertising" only when adLinks is present and non-empty', () => {
    const withAds = renderCarousel(IMAGES, AD_LINKS);
    expect(withAds.root.findAllByType('h3')).toHaveLength(1);
    const adLink = withAds.root.findByProps({ href: AD_LINKS[0].url });
    expect(adLink.props.target).toBe('_blank');
    withAds.unmount();

    const withoutAds = renderCarousel(IMAGES, []);
    expect(withoutAds.root.findAllByType('h3')).toHaveLength(0);
    withoutAds.unmount();

    const withUndefinedAds = renderCarousel(IMAGES, undefined);
    expect(withUndefinedAds.root.findAllByType('h3')).toHaveLength(0);
    withUndefinedAds.unmount();
  });

  it('disables prev/next when there is only one image, and renders nothing for zero images', () => {
    const single = renderCarousel([IMAGES[0]]);
    expect(single.root.findByProps({ 'aria-label': 'Next image' }).props.disabled).toBe(true);
    expect(single.root.findByProps({ 'aria-label': 'Previous image' }).props.disabled).toBe(true);
    single.unmount();

    const empty = renderCarousel([]);
    expect(empty.toJSON()).toBeNull();
    empty.unmount();
  });
});
