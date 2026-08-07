import { useEffect, useRef, type CSSProperties, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { posterFor } from '../data/posters';
import type {
  EnrichedVM,
  PosterBlock,
  PosterImage,
  PosterInlineRun,
} from '../types';
import './ExhibitPoster.css';

function renderRuns(runs: PosterInlineRun[], keyPrefix: string): ReactNode {
  return runs.map((run, index) => {
    const key = `${keyPrefix}-${index}`;
    switch (run.kind) {
      case 'text':
        return run.text;
      case 'emphasis':
        return <em key={key}>{renderRuns(run.children, key)}</em>;
      case 'strong':
        return <strong key={key}>{renderRuns(run.children, key)}</strong>;
      case 'link': {
        const external = /^https?:\/\//.test(run.href);
        return (
          <a
            key={key}
            href={run.href}
            target={external ? '_blank' : undefined}
            rel={external ? 'noreferrer' : undefined}
          >
            {renderRuns(run.children, key)}
          </a>
        );
      }
    }
  });
}

function PosterFigure({ image, hero = false }: { image: PosterImage; hero?: boolean }) {
  return (
    <figure className={hero ? 'exhibit-poster-hero' : 'exhibit-poster-figure'}>
      <img src={image.src} alt={image.alt} />
      <figcaption>
        {image.caption}
        {image.credit && <span className="exhibit-poster-credit"> {image.credit}</span>}
      </figcaption>
    </figure>
  );
}

function Block({ block, index }: { block: PosterBlock; index: number }) {
  const key = `block-${index}`;
  switch (block.kind) {
    case 'heading':
      return block.level === 2
        ? <h2>{renderRuns(block.runs, key)}</h2>
        : <h3>{renderRuns(block.runs, key)}</h3>;
    case 'paragraph':
      return <p>{renderRuns(block.runs, key)}</p>;
    case 'list':
      return (
        <ul>
          {block.items.map((item, itemIndex) => (
            <li key={`${key}-${itemIndex}`}>{renderRuns(item, `${key}-${itemIndex}`)}</li>
          ))}
        </ul>
      );
    case 'quote':
      return <blockquote>{renderRuns(block.runs, key)}</blockquote>;
    case 'image':
      return (
        <figure className="exhibit-poster-figure">
          <img src={block.src} alt={block.alt} />
        </figure>
      );
  }
}

/**
 * An 8-bit machine's memory does not survive being rounded to whole megabytes:
 * `ramMB: 0` rendered as "0 MB", which is not merely imprecise but wrong -- the
 * card said zero beside an `arch` line reading "64 KB". Tiles under a megabyte
 * carry `ramKB` instead and are shown in their own unit.
 */
function formatRam(ramMB?: number, ramKB?: number): string {
  if (ramKB !== undefined && ramKB > 0) return `${ramKB} KB`;
  if (ramMB !== undefined && ramMB > 0) return `${ramMB} MB`;
  return '—';
}

function factRows(vm: EnrichedVM): Array<[string, string]> {
  return [
    ['Year', String(vm.year)],
    ['Lineage', vm.lineage],
    ['Architecture', vm.arch],
    ['RAM', formatRam(vm.ramMB, vm.ramKB)],
    ['Iconic software', vm.eraSoftware.join(' · ') || '—'],
    ['Period browser', vm.periodBrowser || '—'],
    ['Iconic apps', vm.iconicApps.join(' · ') || '—'],
  ];
}

export default function ExhibitPoster({
  osId,
  vm,
  onClose,
}: {
  osId: string;
  vm: EnrichedVM;
  onClose: () => void;
}) {
  const poster = posterFor(osId);
  const panelRef = useRef<HTMLElement>(null);
  const closeRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    const previouslyFocused = document.activeElement as HTMLElement | null;
    closeRef.current?.focus();

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        event.stopImmediatePropagation();
        onClose();
        return;
      }
      if (event.key !== 'Tab') return;
      const panel = panelRef.current;
      if (!panel) return;
      const focusable = Array.from(
        panel.querySelectorAll<HTMLElement>('a[href], button:not([disabled]), [tabindex]:not([tabindex="-1"])'),
      );
      if (focusable.length === 0) {
        event.preventDefault();
        panel.focus();
        return;
      }
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };

    window.addEventListener('keydown', onKeyDown, true);
    return () => {
      window.removeEventListener('keydown', onKeyDown, true);
      previouslyFocused?.focus();
    };
  }, [onClose]);

  if (!poster) return null;
  const heroImage = poster.hero
    ? poster.images.find((image) => image.src === poster.hero) ?? {
        src: poster.hero,
        alt: '',
        caption: '',
      }
    : undefined;
  const remainingImages = poster.images.filter((image) => image.src !== poster.hero);
  const style = { '--poster-accent': vm.accent } as CSSProperties;
  const titleId = `exhibit-poster-title-${osId}`;

  return createPortal((
    <div
      className="exhibit-poster-backdrop"
      style={style}
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <div className="exhibit-poster-close-anchor">
        <button
          ref={closeRef}
          className="exhibit-poster-close"
          type="button"
          onClick={onClose}
          aria-label={`Close exhibit information for ${poster.title}`}
        >
          <span aria-hidden="true">×</span>
        </button>
      </div>

      <article
        ref={panelRef}
        className="exhibit-poster"
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        tabIndex={-1}
      >
        <header className="exhibit-poster-header">
          <p className="exhibit-poster-kicker">Operating Systems Gallery · Exhibit notes</p>
          <h1 id={titleId}>{poster.title}</h1>
          <p className="exhibit-poster-subtitle">{poster.subtitle}</p>
        </header>

        <dl className="exhibit-poster-facts" aria-label="Exhibit facts">
          {factRows(vm).map(([label, value]) => (
            <div key={label}>
              <dt>{label}</dt>
              <dd>{value}</dd>
            </div>
          ))}
        </dl>

        {heroImage && <PosterFigure image={heroImage} hero />}

        <div className="exhibit-poster-essay">
          {poster.blocks.map((block, index) => <Block key={index} block={block} index={index} />)}
          {remainingImages.map((image) => <PosterFigure key={image.src} image={image} />)}
        </div>

        <footer className="exhibit-poster-footer">
          · The Kernel Hive ·
        </footer>
      </article>
    </div>
  ), document.fullscreenElement ?? document.body);
}
