import { useCallback, useState, type KeyboardEvent } from 'react';
import type { PosterAdLink, PosterGalleryImage } from '../types';
import './PosterGalleryCarousel.css';

export interface PosterGalleryCarouselProps {
  images: readonly PosterGalleryImage[];
  adLinks?: readonly PosterAdLink[];
  /** Prefixes the live-region id so two carousels never collide. */
  idPrefix: string;
}

/**
 * One-at-a-time image carousel for the Origins section of an ExhibitPoster
 * (docs/lab/POSTER-GALLERY-SPEC.md Phase 1). Presentational only: the caller
 * decides whether a gallery exists at all and where in the poster it goes
 * (see posterGallerySection.ts) -- this component just renders one.
 */
export default function PosterGalleryCarousel({ images, adLinks, idPrefix }: PosterGalleryCarouselProps) {
  const [index, setIndex] = useState(0);
  const total = images.length;

  const go = useCallback(
    (delta: number) => {
      setIndex((current) => (total === 0 ? 0 : (current + delta + total) % total));
    },
    [total],
  );

  const onKeyDown = useCallback(
    (event: KeyboardEvent<HTMLElement>) => {
      if (event.key === 'ArrowLeft') {
        event.preventDefault();
        go(-1);
      } else if (event.key === 'ArrowRight') {
        event.preventDefault();
        go(1);
      }
    },
    [go],
  );

  if (total === 0) return null;
  const image = images[index];

  return (
    <section
      className="exhibit-poster-gallery"
      aria-label="Historical images"
      aria-roledescription="carousel"
      tabIndex={0}
      onKeyDown={onKeyDown}
    >
      <figure className="exhibit-poster-gallery-figure">
        <img
          key={image.src}
          src={image.src}
          alt={image.alt}
          width={image.width}
          height={image.height}
          loading="lazy"
          decoding="async"
        />
        <figcaption>
          {image.caption}
          <span className="exhibit-poster-credit">
            {' '}
            Photo:{' '}
            <a href={image.sourceUrl} target="_blank" rel="noreferrer">
              {image.author}
            </a>{' '}
            ·{' '}
            <a href={image.licenseUrl} target="_blank" rel="noreferrer">
              {image.license}
            </a>
            {image.shareAlike && <span className="exhibit-poster-gallery-sa"> · share-alike</span>}
          </span>
        </figcaption>
      </figure>

      <div className="exhibit-poster-gallery-controls">
        <button
          type="button"
          className="exhibit-poster-gallery-nav"
          aria-label="Previous image"
          onClick={() => go(-1)}
          disabled={total < 2}
        >
          <span aria-hidden="true">‹</span>
        </button>

        <div className="exhibit-poster-gallery-dots" role="tablist" aria-label="Choose image">
          {images.map((candidate, dotIndex) => (
            <button
              key={candidate.src}
              type="button"
              role="tab"
              aria-selected={dotIndex === index}
              aria-label={`Image ${dotIndex + 1} of ${total}`}
              className={dotIndex === index ? 'exhibit-poster-gallery-dot is-current' : 'exhibit-poster-gallery-dot'}
              onClick={() => setIndex(dotIndex)}
            />
          ))}
        </div>

        <button
          type="button"
          className="exhibit-poster-gallery-nav"
          aria-label="Next image"
          onClick={() => go(1)}
          disabled={total < 2}
        >
          <span aria-hidden="true">›</span>
        </button>

        <span className="exhibit-poster-gallery-counter" aria-hidden="true">
          {index + 1} / {total}
        </span>
      </div>

      <p id={`${idPrefix}-gallery-live`} className="exhibit-poster-gallery-live" aria-live="polite">
        Image {index + 1} of {total}: {image.alt}
      </p>

      {adLinks && adLinks.length > 0 && (
        <div className="exhibit-poster-gallery-ads">
          <h3>Period advertising</h3>
          <ul>
            {adLinks.map((ad) => (
              <li key={ad.url}>
                <a href={ad.url} target="_blank" rel="noreferrer">
                  {ad.title}
                </a>{' '}
                — {ad.source}
              </li>
            ))}
          </ul>
        </div>
      )}
    </section>
  );
}
