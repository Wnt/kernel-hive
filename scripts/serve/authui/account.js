// Your own account: the passkeys you hold, and the QR that adds another device
// to this same account. Available to every signed-in user — managing your own
// devices is not an admin power.

import { api, createCredential, say, supported } from '/ui/common.js';

const $ = (id) => document.getElementById(id);
const msg = $('msg');
let ticker = null;

function el(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined) n.textContent = text;
  return n;
}

function renderPasskeys(passkeys) {
  const box = $('passkeys');
  box.replaceChildren();
  for (const k of passkeys) {
    const info = el('div', 'grow');
    info.append(
      el('div', 'name', k.label),
      el('div', 'meta', `added ${k.createdAt.slice(0, 10)}` +
        (k.lastUsedAt ? ` · last used ${k.lastUsedAt.slice(0, 10)}` : ' · never used'))
    );
    const drop = el('button', 'small danger', 'Remove');
    drop.onclick = async () => {
      try {
        await api('/auth/passkeys/delete', { id: k.id });
        await refresh();
        say(msg, 'Passkey removed.', 'ok');
      } catch (err) {
        say(msg, err.message, 'err');
      }
    };
    const row = el('div', 'row');
    // The last one is not removable — losing it locks you out of your own
    // account, and the server refuses anyway.
    row.append(info, ...(passkeys.length > 1 ? [drop] : [el('span', 'meta', 'your only one')]));
    box.append(row);
  }
}

/** Count the code down to zero, then swap the QR for the refresh button. */
function startCountdown(seconds) {
  clearInterval(ticker);
  let left = seconds;
  const tick = () => {
    if (left <= 0) {
      clearInterval(ticker);
      $('qr-wrap').classList.add('hidden');
      $('qr-expired').classList.remove('hidden');
      $('make-link').classList.remove('hidden');
      $('make-link').textContent = 'Show a new QR code';
      return;
    }
    $('countdown').textContent = `Expires in ${left}s — scan it now.`;
    left -= 1;
  };
  tick();
  ticker = setInterval(tick, 1000);
}

$('make-link').addEventListener('click', async () => {
  $('make-link').disabled = true;
  say(msg, '');
  try {
    const link = await api('/auth/link/create', {});
    // The SVG is built by the server, so there is no QR library in the page and
    // the code never travels as its own cacheable image request.
    $('qr').innerHTML = link.qrSvg;
    $('link-code').textContent = link.code;
    $('qr-expired').classList.add('hidden');
    $('qr-wrap').classList.remove('hidden');
    $('make-link').classList.add('hidden');
    startCountdown(link.expiresInSeconds);
  } catch (err) {
    say(msg, err.message, 'err');
  } finally {
    $('make-link').disabled = false;
  }
});

$('add-passkey').addEventListener('click', async () => {
  say(msg, 'Waiting for this device to create a passkey…');
  try {
    const { ceremonyId, publicKey } = await api('/auth/passkeys/begin', {});
    const credential = await createCredential(publicKey);
    await api('/auth/passkeys/finish', { ceremonyId, credential });
    await refresh();
    say(msg, 'Passkey added.', 'ok');
  } catch (err) {
    say(msg, err.name === 'NotAllowedError' ? 'Passkey creation was cancelled.' : err.message, 'err');
  }
});

async function refresh() {
  const me = await api('/auth/me', {});
  $('title').textContent = me.user.name;
  $('sub').textContent = `Signed in as ${me.user.name} (${me.user.role}).`;
  $('admin-link').classList.toggle('hidden', me.user.role !== 'admin');
  renderPasskeys(me.passkeys);
}

if (!supported()) {
  say(msg, 'This browser has no passkey support.', 'err');
  $('add-passkey').disabled = true;
}
refresh().catch((err) => {
  if (String(err.message).includes('sign in')) location.href = '/login';
  else say(msg, err.message, 'err');
});
