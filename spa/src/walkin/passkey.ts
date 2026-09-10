// One-tap passkey signup for a walk-in account (CONTRACT-LEDGER §3,
// `POST /walkin/signup`) and — `walkinSignIn` below — signing back in on a
// passkey the visitor already made, for the landing page's conversion gate.
//
// Both ceremonies are the ones the gallery already runs elsewhere
// (scripts/serve/authui/common.js): the server hands out options, the browser
// creates or offers a discoverable credential, the credential goes back. This
// is that code in TypeScript, kept deliberately field-by-field rather than
// using PublicKeyCredential.toJSON(), which browsers this gallery must work on
// still lack. The server tolerates extra fields, so this is the conservative
// direction to be wrong in.
//
// ASSUMPTION, and the only one in this lane (lane 2 owns the server half):
// the ledger freezes ONE route for signup, so the two halves of a WebAuthn
// ceremony are POSTed to it — an empty body BEGINS and returns
// `{ceremonyId, publicKey}`, and `{ceremonyId, credential}` FINISHES and
// returns `{handle, role}`. If lane 2's shape differs, it differs HERE, in
// `walkinSignup`, and nowhere else in this lane.

import { WalkinApiError } from './api';

// Origin-absolute for the same reason api.ts is: one auth service, at the
// origin root, whatever base this bundle was built with.

export interface WalkinAccount {
  handle: string;
  role: string;
}

function b64urlToBytes(value: string): Uint8Array<ArrayBuffer> {
  const pad = value.replace(/-/g, '+').replace(/_/g, '/');
  const binary = atob(pad + '='.repeat((4 - (pad.length % 4)) % 4));
  const out = new Uint8Array(new ArrayBuffer(binary.length));
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

function bytesToB64url(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Does this browser have WebAuthn at all? No passkey ⇒ no walk-in account. */
export function supportsPasskeys(): boolean {
  return typeof window !== 'undefined' && !!window.PublicKeyCredential && !!navigator.credentials;
}

async function post<T>(path: string, body: unknown): Promise<T> {
  const response = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    credentials: 'same-origin',
    cache: 'no-store',
  });
  // Same trap as api.ts: an undeployed route comes back as the SPA shell with
  // a 200, not a 404. Treat "OK but not JSON" as absent.
  if (response.ok && !(response.headers.get('content-type') ?? '').includes('json')) {
    throw new WalkinApiError('route not deployed', 'not_json', 404);
  }
  let data: Record<string, unknown> = {};
  try { data = (await response.json()) as Record<string, unknown>; } catch { /* body-less error */ }
  if (!response.ok) {
    const code = typeof data.error === 'string' ? data.error : `http_${response.status}`;
    throw new WalkinApiError(code.replace(/_/g, ' '), code, response.status);
  }
  return data as T;
}

// The server's options, still base64url-encoded on the wire — the browser API
// wants bytes, so this is deliberately NOT PublicKeyCredentialCreationOptions.
type RawCreationOptions = Omit<PublicKeyCredentialCreationOptions, 'challenge' | 'user' | 'excludeCredentials'> & {
  challenge: string;
  user: { id: string; name: string; displayName: string };
  excludeCredentials?: { id: string; type: 'public-key'; transports?: AuthenticatorTransport[] }[];
};

type BeginResponse = { ceremonyId: string; publicKey: RawCreationOptions };

/** Run the create ceremony and hand the credential back to the broker. */
export async function walkinSignup(): Promise<WalkinAccount> {
  if (!supportsPasskeys()) throw new Error('This browser has no passkey support.');
  let begun: BeginResponse;
  try {
    begun = await post<BeginResponse>('/walkin/signup', {});
  } catch (error) {
    // Lane 2 has not deployed the route yet (or this is a staged build with no
    // walk-in plane behind it). Stand in an account so the rest of the journey
    // can be walked and looked at; the real ceremony runs the moment the route
    // answers. Same rule as api.ts's fixture: only ever on a 404.
    if (error instanceof WalkinApiError && error.status === 404) {
      console.warn('[walkin] /walkin/signup is not deployed yet — using a stand-in account');
      return { handle: 'bold-turing', role: 'walkin' };
    }
    throw error;
  }
  const { ceremonyId, publicKey } = begun;
  const options: PublicKeyCredentialCreationOptions = {
    ...publicKey,
    challenge: b64urlToBytes(publicKey.challenge),
    user: { ...publicKey.user, id: b64urlToBytes(publicKey.user.id) },
    excludeCredentials: (publicKey.excludeCredentials ?? []).map((entry) => ({
      ...entry,
      id: b64urlToBytes(entry.id),
    })),
  };
  const credential = (await navigator.credentials.create({ publicKey: options })) as PublicKeyCredential | null;
  if (!credential) throw new Error('No passkey was created.');
  const attestation = credential.response as AuthenticatorAttestationResponse;
  return post<WalkinAccount>('/walkin/signup', {
    ceremonyId,
    credential: {
      id: credential.id,
      // rawId is the same bytes as id, and the server requires both.
      rawId: bytesToB64url(credential.rawId),
      type: credential.type,
      authenticatorAttachment: credential.authenticatorAttachment ?? undefined,
      clientExtensionResults: credential.getClientExtensionResults(),
      response: {
        clientDataJSON: bytesToB64url(attestation.clientDataJSON),
        attestationObject: bytesToB64url(attestation.attestationObject),
      },
    },
  });
}

// The server's options for navigator.credentials.get — the sign-in half of
// the same wire shape as RawCreationOptions above, still base64url-encoded.
type RawRequestOptions = Omit<PublicKeyCredentialRequestOptions, 'challenge' | 'allowCredentials'> & {
  challenge: string;
  allowCredentials?: { id: string; type: 'public-key'; transports?: AuthenticatorTransport[] }[];
};

type LoginBeginResponse = { ceremonyId: string; publicKey: RawRequestOptions };
type LoginFinishResponse = { ok: boolean; user: { id: string; name: string; role: string } };

/**
 * Sign in with a passkey this browser already holds for the gallery — a
 * DISCOVERABLE credential, so the browser offers whatever key it has and no
 * username is ever asked (docs/PUBLIC-GALLERY.md; server side:
 * scripts/serve/auth/passkeys.py `begin_authentication`, "No allowCredentials").
 *
 * This is NOT a new endpoint: it is the same ceremony the sign-in button on
 * /login already runs (scripts/serve/authui/login.js `$('signin')`,
 * scripts/serve/authui/common.js `getCredential`) —
 * `/auth/login/begin` + `navigator.credentials.get` + `/auth/login/finish`.
 * `/auth/` is an open prefix (scripts/serve/auth/gate.py `OPEN_PREFIXES`), so a
 * signed-out stranger can already reach it; the conversion gate (landing/
 * gate/ConversionGate.tsx) is simply the first caller from inside the SPA
 * itself rather than the static /login page.
 *
 * Unlike `walkinSignup`, this has no 404 stand-in: `/auth/login/*` is not part
 * of a lane still landing, it is the gallery's existing sign-in, already
 * deployed everywhere `/login` works. A 404 here is a real bug, not a build
 * still in flight.
 */
export async function walkinSignIn(): Promise<WalkinAccount> {
  if (!supportsPasskeys()) throw new Error('This browser has no passkey support.');
  const { ceremonyId, publicKey } = await post<LoginBeginResponse>('/auth/login/begin', {});
  const options: PublicKeyCredentialRequestOptions = {
    ...publicKey,
    challenge: b64urlToBytes(publicKey.challenge),
    allowCredentials: (publicKey.allowCredentials ?? []).map((entry) => ({
      ...entry,
      id: b64urlToBytes(entry.id),
    })),
  };
  const credential = (await navigator.credentials.get({ publicKey: options })) as PublicKeyCredential | null;
  if (!credential) throw new Error('No passkey was offered.');
  const assertion = credential.response as AuthenticatorAssertionResponse;
  const response: { clientDataJSON: string; authenticatorData: string; signature: string; userHandle?: string } = {
    clientDataJSON: bytesToB64url(assertion.clientDataJSON),
    authenticatorData: bytesToB64url(assertion.authenticatorData),
    signature: bytesToB64url(assertion.signature),
  };
  // Only present for a resident/discoverable credential, which is exactly the
  // case this gallery relies on (no username field) — but the server needs it
  // to tell WHICH account answered, so it is sent whenever the browser gives it.
  if (assertion.userHandle) response.userHandle = bytesToB64url(assertion.userHandle);
  const { user } = await post<LoginFinishResponse>('/auth/login/finish', {
    ceremonyId,
    credential: {
      id: credential.id,
      rawId: bytesToB64url(credential.rawId),
      type: credential.type,
      authenticatorAttachment: credential.authenticatorAttachment ?? undefined,
      clientExtensionResults: credential.getClientExtensionResults(),
      response,
    },
  });
  return { handle: user.name, role: user.role };
}

/** Who the browser is signed in as, if anyone (the existing /auth/state). */
export async function currentAccount(): Promise<WalkinAccount | null> {
  try {
    const response = await fetch('/auth/state', { credentials: 'same-origin', cache: 'no-store' });
    if (!response.ok) return null;
    const data = (await response.json()) as { authenticated?: boolean; user?: { name?: string; role?: string } };
    if (!data.authenticated || !data.user) return null;
    return { handle: data.user.name ?? 'visitor', role: data.user.role ?? 'walkin' };
  } catch {
    return null;
  }
}
