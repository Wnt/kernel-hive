import { Link } from 'react-router-dom';
import { useReleaseNotes } from '../data/releaseNotes';
import { releaseWeekViews, type SectionView, type WeekView } from './releaseNotesView';
import './About.css';

// /about — what this project is, plus the generated weekly release notes.
// The prose is sourced from README.md's opening and deliberately states no
// counts (the lineup changes; /fleet is the live answer). The notes come from
// /release-notes.json — see scripts/release-notes.py — and each week is a
// native <details>, so collapsing costs no JS state at all.

const REPO_URL = 'https://github.com/Wnt/kernel-hive';

function EntrySection({ section }: { section: SectionView }) {
  if (section.collapsed) {
    return (
      <div className="about-section about-section--collapsed">
        <span className="about-section-title">{section.title}</span>
        <span className="about-section-count">{section.summary}</span>
      </div>
    );
  }
  return (
    <details className="about-section" open={section.defaultOpen}>
      <summary>
        <span className="about-section-title">{section.title}</span>
        <span className="about-section-count">{section.summary}</span>
      </summary>
      <ul className="about-entries">
        {section.entries.map((entry) => (
          <li key={entry.key}>
            {entry.station && <span className="about-station">{entry.station}</span>}
            <span className="about-entry-text">{entry.text}</span>
            <a className="about-sha" href={entry.href} target="_blank" rel="noreferrer">{entry.sha}</a>
          </li>
        ))}
      </ul>
    </details>
  );
}

function WeekBlock({ week }: { week: WeekView }) {
  return (
    <details className="about-week" open={week.defaultOpen}>
      <summary>
        <span className="about-week-number">{week.heading}</span>
        <span className="about-week-range">{week.range}</span>
        {week.inProgress && <span className="about-badge about-badge--live">in progress</span>}
        <span className="about-week-commits">{week.commits}</span>
      </summary>
      <div className="about-week-body">
        {week.sections.map((section) => (
          <EntrySection key={section.title} section={section} />
        ))}
      </div>
    </details>
  );
}

function ReleaseNotes() {
  const doc = useReleaseNotes();
  if (doc === undefined) return <p className="about-status">Loading release notes…</p>;
  if (doc === null) {
    return (
      <p className="about-status">
        No release notes published. Regenerate them with <code>make release-notes</code> (it writes{' '}
        <code>spa/public/release-notes.json</code> from the repo&rsquo;s git history).
      </p>
    );
  }
  return (
    <>
      <p className="about-note">
        One entry per non-merge commit, grouped into weeks that end {doc.cutoff}, starting at the
        open-source release. Generated at <code>{doc.generatedFrom}</code>.
      </p>
      <div className="about-weeks">
        {releaseWeekViews(doc).map((week) => <WeekBlock key={week.key} week={week} />)}
      </div>
    </>
  );
}

export function About() {
  return (
    <div className="about-view">
      <div className="about-inner">
        <h2 className="about-title">About Kernel Hive</h2>
        <p className="about-lede">
          Kernel Hive is a &ldquo;living computer museum&rdquo;: a single host runs vintage and
          exotic operating systems as live emulated or virtualised guests — from 1980s home
          computers to hobby OSes still under active development — and streams each one,
          interactively, into a web browser. A visitor can watch a guest boot, move its pointer and
          type into it; the gallery is reachable over the internet but gated behind passkey
          sign-in, so sessions are authenticated rather than open to the world.
        </p>
        <p className="about-lede">
          It is a personal home-lab project, not a product: everything is built against one specific
          machine. The code is published for reading, reuse and reference at{' '}
          <a href={REPO_URL} target="_blank" rel="noreferrer">{REPO_URL}</a>. For what is running
          right now — every station, its emulator and its I/O paths — see the{' '}
          <Link to="/fleet">fleet table</Link>.
        </p>

        <h2 className="about-title about-title--notes">Release notes</h2>
        <ReleaseNotes />
      </div>
    </div>
  );
}
