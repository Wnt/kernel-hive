import { Link } from 'react-router-dom';
import { useReleaseNotes } from '../data/releaseNotes';
import { releaseWeekViews, type WeekView } from './releaseNotesView';
import { parseMarkup, plainText, stationPath, type MarkupToken } from './releaseNotesMarkup';
import './About.css';

// /about — what this project is, plus the weekly release notes.
// The prose is sourced from README.md's opening and deliberately states no
// counts (the lineup changes; /fleet is the live answer). The notes come from
// /release-notes.json, which scripts/release-notes.py LAYS OUT from the
// hand-written registry/release-notes/*.json — no week's words are generated
// here or there. Each week is a native <details>, so collapsing costs no JS
// state at all.

const REPO_URL = 'https://github.com/Wnt/kernel-hive';

// The authored markup, as elements. A station becomes a real link into the
// gallery; everything the vocabulary does not cover stayed `text` in the parser
// and renders literally, so no authored string can inject markup here.
function Markup({ tokens }: { tokens: MarkupToken[] }) {
  return (
    <>
      {tokens.map((token, index) => {
        const key = `${token.kind}-${index}`;
        if (token.kind === 'text') return <span key={key}>{token.text}</span>;
        if (token.kind === 'station') {
          return (
            <Link key={key} className="about-station" to={stationPath(token.id)}>
              {token.text}
            </Link>
          );
        }
        const children = <Markup tokens={token.children} />;
        if (token.kind === 'bold') return <strong key={key}>{children}</strong>;
        if (token.kind === 'italic') return <em key={key}>{children}</em>;
        return <u key={key}>{children}</u>;
      })}
    </>
  );
}

function WeekBlock({ week }: { week: WeekView }) {
  return (
    <details className="about-week" open={week.defaultOpen}>
      <summary>
        <span className="about-week-number">{week.heading}</span>
        <span className="about-week-title">{week.title}</span>
        <span className="about-week-range">{week.range}</span>
        <span className="about-week-code">{week.code}</span>
      </summary>
      <div className="about-week-body">
        {week.sourceNote && <p className="about-week-source">{week.sourceNote}</p>}
        {week.summary.map((section) => (
          <section className="about-section" key={section.theme}>
            <h3 className="about-theme">{section.theme}</h3>
            <p className="about-week-para"><Markup tokens={parseMarkup(section.text)} /></p>
          </section>
        ))}
        {week.bullets.length > 0 && (
          <ul className="about-bullets">
            {week.bullets.map((bullet) => {
              const tokens = parseMarkup(bullet);
              return <li key={plainText(tokens).slice(0, 60)}><Markup tokens={tokens} /></li>;
            })}
          </ul>
        )}
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
        No release notes published. Re-render them with <code>make release-notes</code> (it writes{' '}
        <code>spa/public/release-notes.json</code> from <code>registry/release-notes/*.json</code>).
      </p>
    );
  }
  return (
    <>
      <p className="about-note">
        What changed, a week at a time, newest first. A week ends {doc.cutoff}; the newest one is
        open below, the rest fold out.
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
