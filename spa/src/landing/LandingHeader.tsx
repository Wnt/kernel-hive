import { useCallback, useEffect, useMemo } from 'react';
import { Link } from 'react-router-dom';
import { MUSEUM_NAME } from '../config';
import { useSession } from '../data/SessionContext';
import { IdentityBadge } from '../ui/IdentityBadge';
import { jumpChord } from './jumpChord';

// ============================================================================
//  landing/LandingHeader — the one bar above the machine.
//  ---------------------------------------------------------------------------
//  Four things and no more: whose museum this is, what it is, the way to any of
//  the other exhibits, and the way in. The gallery's own `.appbar` is not
//  reused here on purpose — it carries a Grid/3D/Fleet segmented control that
//  is a tool for somebody who already knows the place, and this page's whole
//  job is the first ten seconds of somebody who does not.
//
//  THE CHORD IS NOT ALWAYS ⌘K, and on a phone there is no chord at all — see
//  jumpChord.ts. The listener below accepts Meta OR Ctrl and always has; only
//  the chip that advertises it was hard-coded to a Mac.
//
//  ⌘K, AND THE ONE THING THAT MAKES IT DELICATE. While a machine is live,
//  EVERY keydown on this page is forwarded to the guest in the capture phase
//  (ui/grid/StreamView/useStreamInput.ts) — that is the promise the page is
//  making, and it is not to be weakened. So the shortcut takes the same route
//  the stream's own debug toggle takes: capture phase plus
//  stopImmediatePropagation, registered from THIS component, which mounts on
//  first paint and therefore before any stream. Capture-phase listeners on the
//  same target run in registration order, so this one is reached first and the
//  guest never sees the chord. Nothing else is intercepted: one chord, and the
//  rest of the keyboard is the visitor's machine's.
// ============================================================================

/** The grid's filter box, which GridView renders below this page's hero. Found
 *  by class rather than by a ref threaded through three components: the filter
 *  is GridView's own, and reaching into it is a page-level convenience, not a
 *  contract between the two. */
function focusCollectionFilter(): void {
  const input = document.querySelector<HTMLInputElement>('.grid-filter-input');
  if (!input) return;
  input.scrollIntoView({ block: 'center', behavior: 'smooth' });
  input.focus();
  input.select();
}

/** What this device can be told about the shortcut. Read once: neither answer
 *  changes without a reload that would remount the header anyway. */
function chordForThisDevice(): string | null {
  if (typeof navigator === 'undefined') return null;
  const nav = navigator as Navigator & { userAgentData?: { platform?: string } };
  return jumpChord({
    platform: nav.userAgentData?.platform || nav.platform || nav.userAgent || '',
    coarsePrimary: !!window.matchMedia && window.matchMedia('(pointer: coarse)').matches,
  });
}

export function LandingHeader({ exhibitCount }: { exhibitCount: number }) {
  const { role } = useSession();
  const jump = useCallback(() => { focusCollectionFilter(); }, []);
  const chord = useMemo(chordForThisDevice, []);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'k' && event.key !== 'K') return;
      if (!event.metaKey && !event.ctrlKey) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      focusCollectionFilter();
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  }, []);

  return (
    <header className="landing-bar">
      <Link className="landing-bar__brand" to="/">
        <span className="landing-bar__name">{MUSEUM_NAME}</span>
        <span className="landing-bar__tag">a working computer museum you can drive</span>
      </Link>
      <nav className="landing-bar__nav">
        <button type="button" className="landing-bar__jump" onClick={jump}>
          {chord && <kbd className="landing-bar__kbd">{chord}</kbd>}
          <span>jump to any of {exhibitCount > 0 ? exhibitCount : 'the exhibits'}</span>
        </button>
        <Link className="landing-bar__link" to="/about">About</Link>
        {role === 'anon'
          ? <a className="landing-bar__link landing-bar__link--in" href="/login">Sign in</a>
          : <IdentityBadge />}
      </nav>
    </header>
  );
}
