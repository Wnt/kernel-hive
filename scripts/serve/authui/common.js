// Shared browser helpers for the sign-in and people pages: base64url, the JSON
// API wrapper, and the two WebAuthn ceremonies.
//
// The credential payloads are assembled field by field rather than with
// PublicKeyCredential.toJSON(), which is still missing from browsers this
// gallery has to work on. The server tolerates extra fields, so this is the
// conservative direction to be wrong in.

export function b64urlToBytes(s) {
  const pad = s.replace(/-/g, '+').replace(/_/g, '/');
  const bin = atob(pad + '='.repeat((4 - (pad.length % 4)) % 4));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function bytesToB64url(buf) {
  const bytes = new Uint8Array(buf);
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** POST (or GET) JSON. Throws Error(message) carrying the server's own wording. */
export async function api(path, body) {
  const res = await fetch(path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: body === undefined ? {} : { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    credentials: 'same-origin',
    cache: 'no-store',
  });
  let data = {};
  try { data = await res.json(); } catch { /* a body-less error is still an error */ }
  if (!res.ok) throw new Error(data.error || `request failed (${res.status})`);
  return data;
}

/** Decode the server's options, run navigator.credentials.create, re-encode. */
export async function createCredential(publicKey) {
  const opts = {
    ...publicKey,
    challenge: b64urlToBytes(publicKey.challenge),
    user: { ...publicKey.user, id: b64urlToBytes(publicKey.user.id) },
    excludeCredentials: (publicKey.excludeCredentials || []).map((c) => ({
      ...c,
      id: b64urlToBytes(c.id),
    })),
  };
  const cred = await navigator.credentials.create({ publicKey: opts });
  if (!cred) throw new Error('no passkey was created');
  return {
    id: cred.id,
    // rawId is the same bytes as id, and the server requires both.
    rawId: bytesToB64url(cred.rawId),
    type: cred.type,
    authenticatorAttachment: cred.authenticatorAttachment || undefined,
    clientExtensionResults: cred.getClientExtensionResults(),
    response: {
      clientDataJSON: bytesToB64url(cred.response.clientDataJSON),
      attestationObject: bytesToB64url(cred.response.attestationObject),
    },
  };
}

/** Same, for navigator.credentials.get. */
export async function getCredential(publicKey) {
  const opts = {
    ...publicKey,
    challenge: b64urlToBytes(publicKey.challenge),
    allowCredentials: (publicKey.allowCredentials || []).map((c) => ({
      ...c,
      id: b64urlToBytes(c.id),
    })),
  };
  const cred = await navigator.credentials.get({ publicKey: opts });
  if (!cred) throw new Error('no passkey was offered');
  const payload = {
    id: cred.id,
    rawId: bytesToB64url(cred.rawId),
    type: cred.type,
    authenticatorAttachment: cred.authenticatorAttachment || undefined,
    clientExtensionResults: cred.getClientExtensionResults(),
    response: {
      clientDataJSON: bytesToB64url(cred.response.clientDataJSON),
      authenticatorData: bytesToB64url(cred.response.authenticatorData),
      signature: bytesToB64url(cred.response.signature),
    },
  };
  if (cred.response.userHandle) {
    payload.response.userHandle = bytesToB64url(cred.response.userHandle);
  }
  return payload;
}

export function supported() {
  return !!(window.PublicKeyCredential && navigator.credentials);
}

/** Show a message under a form. `kind` is 'err', 'ok' or '' for neutral. */
export function say(el, text, kind = '') {
  el.textContent = text;
  el.className = `msg ${kind}`;
}
