// Device B: the page a link QR points at.
//
// The code arrives in the URL FRAGMENT, which the browser never sends to the
// server — so it is not in the access log, not in a Referer, and not in
// anything that proxied the request. We read it here and post it back over TLS.
//
// The ceremony is the same /auth/redeem/* pair the login page uses for invites;
// the server decides from the code itself that this one adds a passkey to an
// existing account rather than creating one.

import { api, createCredential, say, supported } from '/ui/common.js';

const $ = (id) => document.getElementById(id);
const msg = $('msg');

function readCode() {
  const found = decodeURIComponent(location.hash.replace(/^#/, '')).trim();
  // Drop the code from the address bar as soon as it is read: it stays live for
  // a minute, and a URL sits in history, in a screenshot, in a shared tab.
  if (location.hash) history.replaceState(null, '', location.pathname);
  return found;
}

let code = readCode();

// A fragment-only change does not reload the page, so a second code pasted into
// the address bar would otherwise be ignored by an already-running script.
window.addEventListener('hashchange', () => {
  const next = readCode();
  if (next && next !== code) {
    code = next;
    load();
  }
});

function show(which) {
  $('ready').classList.toggle('hidden', which !== 'ready');
  $('dead').classList.toggle('hidden', which !== 'dead');
}

async function begin() {
  // Starting the ceremony is also how we find out whether the code is live: the
  // server does not offer a "check this code" endpoint, because that would be a
  // free oracle for guessing them.
  const { ceremonyId, publicKey } = await api('/auth/redeem/begin', { code });
  return { ceremonyId, publicKey, name: publicKey.user?.displayName || '' };
}

let pending = null;

async function load() {
  if (!code) {
    $('lead').textContent = 'This page needs a link code.';
    show('dead');
    $('retry').classList.add('hidden');
    return;
  }
  if (!supported()) {
    $('lead').textContent = 'This browser has no passkey support, so it cannot be linked.';
    show('dead');
    return;
  }
  try {
    pending = await begin();
    $('lead').textContent = 'Scanned. One tap to finish.';
    $('who').textContent = `This will add a passkey for ${pending.name} to this device.`;
    show('ready');
  } catch (err) {
    $('lead').textContent = err.message;
    show('dead');
  }
}

$('link').addEventListener('click', async () => {
  $('link').disabled = true;
  say(msg, 'Waiting for this device to create a passkey…');
  try {
    const credential = await createCredential(pending.publicKey);
    await api('/auth/redeem/finish', { ceremonyId: pending.ceremonyId, credential });
    location.href = '/';
  } catch (err) {
    say(msg, err.name === 'NotAllowedError' ? 'Passkey creation was cancelled.' : err.message, 'err');
    $('link').disabled = false;
  }
});

$('retry').addEventListener('click', () => load());

load();
