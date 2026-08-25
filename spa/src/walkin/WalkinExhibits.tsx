import { useEffect, useState } from 'react';
import { loadWalkinExhibits, type WalkinExhibit } from './manifest';
import { WALKIN_OS_IDS } from './fixture';
import { posterFor } from '../data/posterIndex';
import { usePosterDoc } from '../data/posterDocs';
import type { PosterBlock, PosterInlineRun } from '../types';

// /walkin/exhibits — the rest of the museum, to read about.
//
// The point of this page (WALKIN-BRIEF §7): the visitor arrives for Windows
// 3.11 and leaves knowing the lab has sixty other machines in it. So every
// listed exhibit is here with its hero shot and its curator's note — and each
// one that is NOT playable says so as a printed line on the placard, never as a
// button that looks pressable and then refuses. A broken button teaches the
// visitor the site is broken; a label teaches them the museum is bigger than
// the three machines they came for.

function plain(runs: PosterInlineRun[]): string {
  return runs
    .map((run) => (run.kind === 'text' ? run.text : plain(run.children)))
    .join('');
}

function firstParagraph(blocks: PosterBlock[] | undefined): string {
  const block = blocks?.find((entry) => entry.kind === 'paragraph');
  return block && block.kind === 'paragraph' ? plain(block.runs) : '';
}

/** The exhibit's own placard prose, fetched from /poster-docs.json on demand. */
function Placard({ osId }: { osId: string }) {
  const doc = usePosterDoc(osId);
  if (!doc) return <p className="walkin-placard">Fetching the placard…</p>;
  return (
    <>
      {doc.subtitle && <p><em>{doc.subtitle}</em></p>}
      <p>{firstParagraph(doc.blocks) || 'The full placard for this exhibit is still being written.'}</p>
    </>
  );
}

function ExhibitCard({ exhibit, playable }: { exhibit: WalkinExhibit; playable: boolean }) {
  const [open, setOpen] = useState(false);
  const hero = posterFor(exhibit.id)?.hero;
  return (
    <article className="walkin-exhibit" style={{ ['--card-accent' as string]: exhibit.accent }}>
      {hero && <img className="walkin-exhibit-hero" src={hero} alt={`${exhibit.displayName} desktop`} loading="lazy" />}
      <div className="walkin-exhibit-body">
        <span className="walkin-exhibit-name">{exhibit.displayName}</span>
        <span className="walkin-exhibit-meta">
          {[exhibit.year, exhibit.lineage, exhibit.arch].filter(Boolean).join(' · ')}
        </span>
        {exhibit.blurb && <p className="walkin-exhibit-blurb">{exhibit.blurb}</p>}
        <span className={`walkin-tag${playable ? ' walkin-tag--playable' : ''}`}>
          {playable ? 'You can play this one' : 'On display — not playable'}
        </span>
        <details className="walkin-placard" onToggle={(event) => setOpen(event.currentTarget.open)}>
          <summary>Read the placard</summary>
          {open && <Placard osId={exhibit.id} />}
        </details>
      </div>
    </article>
  );
}

export default function WalkinExhibits() {
  const [exhibits, setExhibits] = useState<WalkinExhibit[] | null>(null);

  useEffect(() => {
    let alive = true;
    void loadWalkinExhibits().then((loaded) => { if (alive) setExhibits(loaded); });
    return () => { alive = false; };
  }, []);

  const playable = new Set<string>(WALKIN_OS_IDS);

  return (
    <>
      <p className="walkin-lede">
        The three machines you can use are a small corner of the collection. Everything below is
        running in the same rack — restored, booted and photographed — and is here to be read about
        rather than driven.
      </p>

      <div className="walkin-section-head">
        <h2>The collection</h2>
        <span>{exhibits ? `${exhibits.length} exhibits` : 'loading…'}</span>
      </div>

      {exhibits && exhibits.length === 0 && (
        <section className="walkin-notice walkin-notice--warn">
          <h2>The exhibition list is not available.</h2>
          <p>The placards could not be fetched just now. The three playable machines are unaffected.</p>
        </section>
      )}

      <div className="walkin-exhibits">
        {(exhibits ?? []).map((exhibit) => (
          <ExhibitCard key={exhibit.id} exhibit={exhibit} playable={playable.has(exhibit.id)} />
        ))}
      </div>
    </>
  );
}
