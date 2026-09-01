// Who is driving this tab — the ONE question the app asks before it renders.
//
// Until this module existed the app chose its shape from the PATH: `/walkin*`
// booted the walk-in app, everything else booted the gallery. That is wrong for
// exactly one visitor, and it is the visitor who has just signed up: a walk-in
// who types the root URL is allowed to fetch `/` (gate.py `WALKIN_PATHS`), so
// the shell loads — and then boots the GALLERY, which fetches the full-fleet
// `/gallery-manifest.json` the same gate refuses them. The result is a page
// that loads and shows nothing. Role, not path, is the thing that was always
// being asked.
//
// `GET /auth/state` is the existing "who am I" — the same document
// `walkin/passkey.ts` already reads — and `/auth/` is in gate.py's
// `OPEN_PREFIXES`, so every session may ask. (`/auth/me` is POST-only and
// returns the passkey list; it is the wrong door for this.) One cheap
// same-origin request before first paint, and no visitor class is a special
// case.

/** The roles the serving plane mints. `anon` is "no auth on this listener". */
type Role = 'admin' | 'viewer' | 'walkin' | 'anon';

export interface Session {
  role: Role;
  /** The account's display handle, when it has one. */
  name: string;
  /** The account's server-side id, when it has one ('' for `anon`). Not
   *  previously surfaced here — `analytics/instana.ts` is the first reader,
   *  which is why this field exists at all. */
  id: string;
}

const ANON: Session = { role: 'anon', name: '', id: '' };

const KNOWN: Role[] = ['admin', 'viewer', 'walkin'];

/** `{authenticated, user:{id,name,role}}` -> a Session. */
function parse(value: unknown): Session {
  if (typeof value !== 'object' || value === null) return ANON;
  const doc = value as { authenticated?: unknown; user?: unknown };
  if (doc.authenticated !== true) return ANON;
  if (typeof doc.user !== 'object' || doc.user === null) return ANON;
  const user = doc.user as Record<string, unknown>;
  const role = user.role;
  return {
    role: KNOWN.includes(role as Role) ? (role as Role) : 'anon',
    name: typeof user.name === 'string' ? user.name : '',
    id: typeof user.id === 'string' ? user.id : '',
  };
}

/**
 * Read the current session's role.
 *
 * Fails OPEN to `anon`, and that is deliberate rather than lax. The LAN
 * listener serves no `/auth/*` at all (gate.py's preamble: it keeps the open,
 * tokenless behaviour every lab script and the Playwright suite depend on), and
 * a `/staging/<slot>/` preview has no auth plane behind it either. In both the
 * request 404s or answers unauthenticated, both must keep rendering the full
 * gallery exactly as they do today, and neither is a place where `anon` grants
 * anything: `anon` selects a UI SHAPE, never an access decision. Every document
 * this app fetches is authorized server-side by the same gate whatever this
 * function returned, so the worst an `anon` guess can do on the gated listener
 * is render a gallery whose fetches then 403 — which is precisely the state
 * that cannot arise there, because an unauthenticated caller is redirected to
 * `/login` before this code ever runs.
 */
export async function loadSession(fetcher: typeof fetch = fetch): Promise<Session> {
  const forced = forcedRole();
  if (forced) return { role: forced, name: `${forced} (preview)`, id: `preview-${forced}` };
  try {
    const response = await fetcher('/auth/state', { credentials: 'same-origin', cache: 'no-store' });
    if (!response.ok) return ANON;
    return parse(await response.json());
  } catch {
    return ANON;
  }
}

/**
 * `?role=walkin` on a DEV or STAGED build only — the smoke check's lever.
 *
 * A staging preview has no auth plane behind it, so every load there reads
 * `anon` and the walk-in shape could never be eyeballed before it shipped. This
 * is the same affordance `walkin/fixture.ts` already gives the pool states
 * (`?walkin=closed`), and it is refused on a production bundle so the live site
 * has no such switch at all.
 *
 * It could not be a privilege escalation even if it were: the role picks a UI
 * SHAPE, and every document the shape then asks for is authorized server-side
 * by `gate.py` against the real session. Forcing `?role=admin` on the live
 * plane as a walk-in would render an invited grid whose every fetch is refused.
 */
function forcedRole(): Role | null {
  const staged = import.meta.env.DEV || import.meta.env.BASE_URL !== '/';
  if (!staged || typeof location === 'undefined') return null;
  const asked = new URLSearchParams(location.search).get('role');
  return KNOWN.includes(asked as Role) ? (asked as Role) : null;
}
