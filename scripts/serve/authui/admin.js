// People management. Every button here is an admin-only server call; this page
// only draws what the server already decided it would allow.

import { api, say } from '/ui/common.js';

const $ = (id) => document.getElementById(id);
const msg = $('msg');
let me = null;

function el(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined) n.textContent = text;
  return n;
}

function row(...children) {
  const r = el('div', 'row');
  for (const c of children) r.append(c);
  return r;
}

function labelled(name, meta) {
  const box = el('div', 'grow');
  box.append(el('div', 'name', name), el('div', 'meta', meta));
  return box;
}

async function guarded(fn) {
  try {
    say(msg, '');
    await fn();
    await refresh();
  } catch (err) {
    say(msg, err.message, 'err');
  }
}

function renderUsers(users) {
  const box = $('users');
  box.replaceChildren();
  for (const u of users) {
    const keys = u.passkeys.length === 1 ? '1 passkey' : `${u.passkeys.length} passkeys`;
    const last = u.passkeys.map((k) => k.lastUsedAt).filter(Boolean).sort().pop();
    // `lastSeenAt` is stamped whenever a session is USED, not only when a
    // passkey is presented — an invite-link visitor may hold a live cookie for
    // weeks and never touch a passkey, and used to leave no trace at all.
    const meta = `${keys}${last ? ` · passkey last used ${when(last)}` : ' · passkey never used'}`
      + ` · last seen ${when(u.lastSeenAt)}`;
    const info = labelled(u.name, meta);
    const tag = el('span', 'tag', u.role);

    const promote = el('button', 'small secondary', u.role === 'admin' ? 'Make viewer' : 'Make admin');
    promote.onclick = () =>
      guarded(() => api('/auth/users/role', { userId: u.id, role: u.role === 'admin' ? 'viewer' : 'admin' }));

    const remove = el('button', 'small danger', 'Remove');
    remove.onclick = () => {
      if (!confirm(`Remove ${u.name}? Their passkeys and sessions go with them.`)) return;
      guarded(() => api('/auth/users/delete', { userId: u.id }));
    };

    // Self-management belongs on the passkey panel below, not here: an admin
    // demoting or deleting themselves mid-session is a support call.
    const isMe = me && u.id === me.id;
    box.append(row(info, tag, ...(isMe ? [el('span', 'meta', 'that’s you')] : [promote, remove])));
  }
  if (!users.length) box.append(el('p', 'meta', 'Nobody yet.'));
}

// ---- the scoreboard --------------------------------------------------------
// /auth/usage/report is admin-only on the server (auth/routes.py, below the role
// check). Everything drawn here therefore arrives only for an admin; the page
// hides nothing that the server was willing to send.

const nf = new Intl.NumberFormat();

function when(iso) {
  return iso ? iso.replace('T', ' ').replace('Z', ' UTC') : 'never';
}

/** The one station somebody used most, for the row's second line. */
function favourite(stations) {
  let best = null;
  for (const [id, s] of Object.entries(stations || {})) {
    const total = (s.clicks || 0) + (s.keys || 0);
    if (!best || total > best.total) best = { id, total };
  }
  return best;
}

function renderScoreboard(rows) {
  const box = $('scoreboard');
  box.replaceChildren();
  for (const r of rows) {
    const total = r.clicks + r.keys;
    const fav = favourite(r.stations);
    const meta = [
      `${nf.format(r.clicks)} clicks · ${nf.format(r.keys)} keystrokes`,
      fav ? `most on ${fav.id} (${nf.format(fav.total)})` : null,
      `last seen ${when(r.lastSeenAt)}`,
    ].filter(Boolean).join(' · ');
    const count = el('span', 'tag', nf.format(total));
    box.append(row(labelled(r.name, meta), count));
  }
  if (!rows.length) box.append(el('p', 'meta', 'Nobody yet.'));
}

function renderPopular(stations) {
  const box = $('popular');
  box.replaceChildren();
  const ranked = Object.entries(stations || {})
    .map(([id, s]) => ({ id, clicks: s.clicks || 0, keys: s.keys || 0, lastAt: s.lastAt }))
    .sort((a, b) => (b.clicks + b.keys) - (a.clicks + a.keys))
    .slice(0, 15);
  for (const s of ranked) {
    const meta = `${nf.format(s.clicks)} clicks · ${nf.format(s.keys)} keystrokes · last used ${when(s.lastAt)}`;
    box.append(row(labelled(s.id, meta), el('span', 'tag', nf.format(s.clicks + s.keys))));
  }
  if (!ranked.length) {
    box.append(el('p', 'meta', 'Nothing counted yet. The same totals, per machine, are in the fleet table’s Use column.'));
  }
}

function renderInvites(invites) {
  const box = $('invites');
  box.replaceChildren();
  for (const i of invites) {
    const revoke = el('button', 'small danger', 'Revoke');
    revoke.onclick = () => guarded(() => api('/auth/invites/revoke', { id: i.id }));
    // A link keeps working after its first use, so "claimed" is not "spent" —
    // it means somebody is relying on this URL, and revoking it locks them out
    // unless they have since made a passkey.
    const state = i.claimed ? 'in use' : 'not opened yet';
    box.append(row(labelled(i.name, `${i.role} · ${state} · expires ${i.expiresAt.slice(0, 10)}`), revoke));
  }
  if (!invites.length) box.append(el('p', 'meta', 'None outstanding.'));
}

async function refresh() {
  const state = await api('/auth/state');
  if (!state.authenticated) return void (location.href = '/login');
  me = state.user;
  // This page is admin-only; a viewer who lands here belongs on their own
  // account page, which is where per-user passkeys live for every role.
  if (me.role !== 'admin') return void (location.href = '/account');
  const people = await api('/auth/people', {});
  renderUsers(people.users);
  renderInvites(people.invites);
  const usage = await api('/auth/usage/report', {});
  renderScoreboard(usage.users);
  renderPopular(usage.stations);
}

$('invite').addEventListener('click', () =>
  guarded(async () => {
    const name = $('inv-name').value.trim();
    const issued = await api('/auth/invites/create', { name, role: $('inv-role').value });
    $('issued').classList.remove('hidden');
    $('issued-code').textContent = issued.code;
    $('issued-url').value = issued.url;
    $('issued-note').textContent =
      `For ${issued.name} (${issued.role}), valid until ${issued.expiresAt.slice(0, 10)}. ` +
      'Send them the link — it signs them in and offers a passkey. ' +
      'Shown once: only a hash is stored, so copy it now.';
    $('inv-name').value = '';
  })
);

// Copy the LINK, not the code: the code is there to read aloud, the link is
// there to send. navigator.clipboard needs a secure context, which this origin
// always is — but a browser can still refuse, so fall back to selecting the
// field, which leaves the user one keystroke from copying it themselves.
$('copy-url').addEventListener('click', async () => {
  const field = $('issued-url');
  try {
    await navigator.clipboard.writeText(field.value);
    say(msg, 'Invite link copied.', 'ok');
  } catch {
    field.select();
    say(msg, 'Press ⌘/Ctrl+C to copy the selected link.', 'err');
  }
});

refresh().catch((err) => say(msg, err.message, 'err'));
