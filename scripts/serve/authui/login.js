// Sign-in page. Three ways in: a passkey you already registered, an invite LINK
// that carries its code in the fragment, or that same code typed by hand. The
// bootstrap token is the one code that still demands a passkey on the spot —
// the first admin has to end up with a way back in.
//
// THE INVITE LINK is the interesting one. Arriving on it signs you in before
// anything is asked of you, and the passkey is then an offer you can decline —
// every visit, because until you take it this URL is the only thing you have.
// Once you DO have a passkey, the invite link stops being special: it's just
// another way in, so it signs you in the same as any other visit and says
// nothing about the link itself (see showInvited's hasPasskey branch).
// The code is left in the address bar on purpose (the device-link page strips
// its own, which lives 60 seconds): this link is meant to be kept and re-opened.

import { api, createCredential, getCredential, say, supported } from '/ui/common.js';

const $ = (id) => document.getElementById(id);
const msg = $('msg');

function busy(on) {
  for (const id of ['signin', 'redeem']) $(id).disabled = on;
}

/** The invite code an invite link carries, or '' for an ordinary visit. */
function linkCode() {
  return decodeURIComponent(location.hash.replace(/^#/, '')).trim();
}

/** Format as the user types: uppercase, dashes every five, code alphabet only. */
function tidyCode(raw) {
  const clean = raw.toUpperCase().replace(/[^0-9A-Z]/g, '').slice(0, 15);
  return clean.replace(/(.{5})(?=.)/g, '$1-');
}

$('code').addEventListener('input', (e) => {
  const before = e.target.selectionStart;
  const wasEnd = before === e.target.value.length;
  e.target.value = tidyCode(e.target.value);
  if (!wasEnd) e.target.setSelectionRange(before, before);
});

/** The ordinary authenticated view: no mention of invites, just signed in. */
function showSignedIn(user) {
  $('invited').classList.add('hidden');
  $('signed-out').classList.add('hidden');
  $('signed-in').classList.remove('hidden');
  $('who').textContent = `Welcome ${user.name}!`;
  $('manage').classList.toggle('hidden', user.role !== 'admin');
}

async function refresh() {
  const state = await api('/auth/state');
  if (state.authenticated) {
    showSignedIn(state.user);
    return state;
  }
  $('signed-out').classList.remove('hidden');
  if (state.needsBootstrap) {
    // Nobody has claimed this gallery yet: the only code that works is the
    // one-time master token, and whoever redeems it names themselves.
    $('name-field').classList.remove('hidden');
    $('foot').textContent = 'No accounts yet — redeem the master token to create the first admin.';
  }
  return state;
}

$('signin').addEventListener('click', async () => {
  busy(true);
  say(msg, 'Waiting for your passkey…');
  try {
    const { ceremonyId, publicKey } = await api('/auth/login/begin', {});
    const credential = await getCredential(publicKey);
    await api('/auth/login/finish', { ceremonyId, credential });
    location.href = '/';
  } catch (err) {
    say(msg, err.name === 'NotAllowedError' ? 'Passkey sign-in was cancelled.' : err.message, 'err');
    busy(false);
  }
});

$('redeem').addEventListener('click', async () => {
  const code = $('code').value.trim();
  if (!code) return say(msg, 'Enter the invite code first.', 'err');
  busy(true);
  say(msg, 'Checking the code…');
  // An INVITE is entered, not redeemed — it needs no passkey. Only the
  // bootstrap token and a device link still run a ceremony, so try the invite
  // path first and fall through when the server says this is not one. A typed
  // code and a followed link then behave identically, which is what someone
  // reading the code aloud over the phone expects.
  try {
    const entered = await api('/auth/invite/enter', { code });
    showInvited(entered);
    busy(false);
    return;
  } catch { /* not an invite (or not valid) — the ceremony below decides */ }
  try {
    const { ceremonyId, publicKey } = await api('/auth/redeem/begin', { code, name: $('name').value.trim() });
    say(msg, 'Now create a passkey for this gallery…');
    const credential = await createCredential(publicKey);
    await api('/auth/redeem/finish', { ceremonyId, credential });
    location.href = '/';
  } catch (err) {
    say(msg, err.name === 'NotAllowedError' ? 'Passkey creation was cancelled.' : err.message, 'err');
    busy(false);
  }
});

/** Show the invited panel for a holder who is now signed in. Once they have a
 *  passkey, the invite link is no longer how they get in — nothing about it
 *  belongs on screen any more, so this is only ever the no-passkey-yet view. */
function showInvited(entered) {
  if (entered.hasPasskey) {
    showSignedIn(entered.user);
    say(msg, '');
    return;
  }
  $('signed-out').classList.add('hidden');
  $('signed-in').classList.add('hidden');
  $('invited').classList.remove('hidden');
  $('inv-who').textContent = `Welcome ${entered.user.name}!`;
  // The validity line is for the RETURN visit: the first time, the link is
  // obviously fresh and a countdown would only be noise. Coming back to it is
  // the moment the deadline becomes information.
  const days = entered.daysLeft;
  $('inv-validity').textContent = entered.returning
    ? `Your invite link works for ${days === 1 ? '1 day' : `${days} days`}. `
      + 'Register a passkey for permanent access!'
    : '';
  say(msg, '');
}

/** Take the invite link's code and enter on it. */
async function enterOnLink(code) {
  try {
    const entered = await api('/auth/invite/enter', { code });
    showInvited(entered);
    return true;
  } catch (err) {
    say(msg, err.message, 'err');
    return false;
  }
}

$('inv-passkey').addEventListener('click', async () => {
  $('inv-passkey').disabled = true;
  say(msg, 'Waiting for this device to create a passkey…');
  try {
    // The ordinary add-a-key pair, not a redemption: entering already made the
    // account and the session, so from here this is just a signed-in person
    // adding a credential.
    const { ceremonyId, publicKey } = await api('/auth/passkeys/begin', {});
    const credential = await createCredential(publicKey);
    await api('/auth/passkeys/finish', { ceremonyId, credential });
    location.href = '/';
  } catch (err) {
    say(msg, err.name === 'NotAllowedError' ? 'Passkey creation was cancelled.' : err.message, 'err');
    $('inv-passkey').disabled = false;
  }
});

$('inv-skip').addEventListener('click', () => { location.href = '/'; });

$('enter').addEventListener('click', () => { location.href = '/'; });
$('manage').addEventListener('click', () => { location.href = '/admin'; });
$('signout').addEventListener('click', async () => {
  await api('/auth/logout', {});
  location.reload();
});

// A browser with no passkey support can still hold an invite link — that is
// most of the point of making the passkey optional — so only the paths that
// REQUIRE a credential are shut off here.
if (!supported()) {
  $('inv-passkey').disabled = true;
  if (!linkCode()) {
    say(msg, 'This browser has no passkey support, so there is no way to sign in from it.', 'err');
    busy(true);
  }
}

const arrived = linkCode();
if (arrived) {
  // Prefill the field as well as acting on it: if entering fails (a revoked or
  // expired link), the visitor is left looking at the code they arrived with
  // rather than an empty box and no idea what went wrong.
  $('code').value = tidyCode(arrived);
  say(msg, 'Checking your invite…');
  enterOnLink(arrived).then((ok) => { if (!ok) refresh().catch(() => {}); });
} else {
  refresh().catch((err) => say(msg, err.message, 'err'));
}
