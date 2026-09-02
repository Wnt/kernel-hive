// lib/invite.mjs — bootstrap an invited (viewer/admin) session from an
// invite LINK'S code, with no passkey at all
// (docs/PUBLIC-GALLERY.md: "An invite is a link, and the passkey is
// optional"). Verified live against the real gallery:
//
//   POST /auth/invite/enter  {"code": "<code>"}
//   -> 200 {"ok":true,"user":{"role":"viewer",...},"hasPasskey":false,
//           "expiresAt":"...","daysLeft":7}
//
// and it sets the session cookie via a plain Set-Cookie — no platform
// authenticator, no navigation even, just one POST from a throwaway browser
// context. That session is then cached to disk as a Playwright storageState
// so every later run reuses it via the same `--storage-state` path this tool
// already had, rather than redeeming the invite again every run.
//
// CREDENTIAL HANDLING: the invite code is a bearer secret
// (docs/PUBLIC-GALLERY.md "this makes the URL a bearer token"). It is read
// here, used in exactly one POST body, and then let go — it is never written
// to the saved storageState (which only ever holds cookies/origins, not the
// request that minted them), never logged, and the CALLER is responsible for
// keeping it out of anything that gets serialized (visitor-sim.mjs keeps the
// resolved code in a local variable, never on the `config` object that
// lib/log.mjs's RunManifest writes to disk).

import fs from 'node:fs';
import path from 'node:path';

/** Resolve `--invite <code-or-path>` to a literal code. A FILE path (the
 *  documented case: the box's gitignored, mode-600
 *  serve/pki/sim-invite.code) is read and trimmed — this keeps the secret
 *  out of `ps`, shell history and this tool's own argv logging, which a
 *  bare `--invite <code>` on a shared box cannot avoid. A value that is not
 *  an existing file is treated as the literal code, for an operator running
 *  this from their own Mac with a code copy-pasted from `/admin`. */
export function resolveInviteCode(value) {
  let stat = null;
  try {
    stat = fs.statSync(value);
  } catch {
    // No such path (or an unreadable parent directory) — not a file we can
    // point at, fall through and treat `value` as the literal code.
    stat = null;
  }
  if (stat && stat.isFile()) {
    // The path DOES exist as a file: read it for real, and let a permission
    // error (e.g. the box's mode-600 sim-invite.code read by the wrong user)
    // throw here rather than silently falling through to "treat the path
    // string itself as the code" — that would send the literal path as the
    // POST body and come back "that code is not valid", which hides the
    // actual problem (wrong user / wrong perms) behind a misleading error.
    return fs.readFileSync(value, 'utf8').trim();
  }
  return String(value).trim();
}

/** Redeem `code` via ONE throwaway APIRequestContext (no page, no
 *  navigation needed — the route is a plain same-origin POST), then persist
 *  the resulting session as a Playwright storageState at `statePath`.
 *  Throws on any non-ok response so a bad/expired/revoked code fails loudly
 *  rather than silently leaving the run in walk-in-only mode. */
export async function redeemInvite(browser, { galleryUrl, code, statePath }) {
  const context = await browser.newContext({ ignoreHTTPSErrors: true });
  // The auth routes live at the ORIGIN even when the UI under test is a
  // staging slot (`--gallery-url https://<lab>/staging/<session>`).
  const origin = new URL(galleryUrl).origin;
  try {
    const resp = await context.request.post(`${origin}/auth/invite/enter`, {
      data: { code },
      headers: { 'content-type': 'application/json', origin },
    });
    if (!resp.ok()) {
      throw new Error(`invite redemption failed: HTTP ${resp.status()}`);
    }
    const body = await resp.json().catch(() => null);
    if (!body || body.ok !== true) {
      throw new Error('invite redemption returned no session (unexpected response shape)');
    }
    fs.mkdirSync(path.dirname(statePath), { recursive: true });
    await context.storageState({ path: statePath });
    return { role: body.user && body.user.role, expiresAt: body.expiresAt, daysLeft: body.daysLeft };
  } finally {
    await context.close();
  }
}

/** Ensure a usable storage-state file exists at `statePath`: reuse it as-is
 *  if present (unless `refresh`), otherwise redeem `code` once and cache the
 *  result there. Returns `statePath` — the caller wires this straight into
 *  `config.storageState`, exactly as if an operator had hand-exported it. */
export async function ensureInviteSession(browser, { galleryUrl, code, statePath, refresh, log }) {
  if (!refresh && fs.existsSync(statePath)) {
    log?.(`reusing cached invite session at ${statePath} (pass --invite-refresh to redeem a fresh one)`);
    return statePath;
  }
  log?.('redeeming invite for a session (no passkey) — this happens once, then the session is cached to disk');
  const info = await redeemInvite(browser, { galleryUrl, code, statePath });
  log?.(
    `invite redeemed: role=${info.role ?? '?'}, session expires ${info.expiresAt ?? '?'} ` +
      `(${info.daysLeft ?? '?'} day(s) left) — cached at ${statePath}`,
  );
  return statePath;
}
