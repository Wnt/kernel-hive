import { useSession } from '../data/SessionContext';
import { identityBadgeText } from './identityBadge';
import './IdentityBadge.css';

// A signed-up walk-in gets a handle like `tidy-noyce` at sign-up
// (WalkinLanding.tsx) and then — before this component — never saw it again:
// the grid and /walkin/play/<os> carried no trace of who was signed in. This
// is the fix: one small pill, dropped into an existing chrome bar's corner
// (App.tsx's TopBar `.appbar-actions`, WalkinPlay.tsx's `.walkin-play-chrome`)
// rather than a new header of its own — both already exist on every route this
// needs to reach, and the stream surface / on-screen keyboard live below them,
// never inside them.
//
// `identityBadgeText` (identityBadge.ts) carries all the role logic so it can
// be unit-tested under plain node; this component is just markup.
export function IdentityBadge() {
  const session = useSession();
  const text = identityBadgeText(session);
  if (!text) return null;
  return <span className="identity-badge">{text}</span>;
}
