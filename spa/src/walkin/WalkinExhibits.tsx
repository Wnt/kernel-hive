import { useEffect, useState } from 'react';
import { exhibitVm, loadWalkinExhibits, type WalkinExhibit } from './manifest';
import { WALKIN_OS_IDS } from './fixture';
import { posterFor } from '../data/posterIndex';
import ExhibitPoster from '../ui/ExhibitPoster';

// /walkin/exhibits — the rest of the museum, to read about.
//
// The point of this page (WALKIN-BRIEF §7): the visitor arrives for Windows
// 3.11 and leaves knowing the lab has sixty other machines in it. So every
// listed exhibit is here with its hero shot — and each one that is NOT playable
// says so as a printed line on the placard, never as a button that looks
// pressable and then refuses. A broken button teaches the visitor the site is
// broken; a label teaches them the museum is bigger than the three machines
// they came for.
//
// The placard itself is the GALLERY's placard: `ExhibitPoster`, the same
// component the invited gallery and the operator open, opened the same way —
// as an overlay from a grid of cards. A walk-in reads the full curatorial
// prose, the hero, the Origins carousel and the era facts, not a thinner
// summary written for them. Nothing extra is exposed by that: `ExhibitPoster`
// reads nine fields off `vm`, all of them exhibition facts the §5.3 allowlist
// already carries (`manifest.ts`, `exhibitVm`), and its prose and imagery come
// from `/poster-docs.json` and `/posters/`, which are public.

function ExhibitCard({
  exhibit,
  playable,
  onOpen,
}: {
  exhibit: WalkinExhibit;
  playable: boolean;
  onOpen: () => void;
}) {
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
        <button type="button" className="walkin-placard-open" onClick={onOpen}>
          Read the placard
        </button>
      </div>
    </article>
  );
}

export default function WalkinExhibits() {
  const [exhibits, setExhibits] = useState<WalkinExhibit[] | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    void loadWalkinExhibits().then((loaded) => { if (alive) setExhibits(loaded); });
    return () => { alive = false; };
  }, []);

  const playable = new Set<string>(WALKIN_OS_IDS);
  const open = exhibits?.find((entry) => entry.id === openId) ?? null;

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
          <ExhibitCard
            key={exhibit.id}
            exhibit={exhibit}
            playable={playable.has(exhibit.id)}
            onOpen={() => setOpenId(exhibit.id)}
          />
        ))}
      </div>

      {open && (
        <ExhibitPoster osId={open.id} vm={exhibitVm(open)} onClose={() => setOpenId(null)} />
      )}
    </>
  );
}
