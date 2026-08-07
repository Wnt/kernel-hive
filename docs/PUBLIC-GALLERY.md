# The public gallery — gallery.example.com

The gallery is reachable from the internet at **https://gallery.example.com**,
behind a passkey login. The LAN origin (`https://192.0.2.10:8443`) is
unchanged and unauthenticated: every lab script, the e2e suites and `labctl`
keep working exactly as before. This document is the whole public path — how a
packet gets in, what stops it, and how to run it.

## Why it needed more than a tunnel

The [forwarder](https://github.com/Wnt/forwarder) publishes NAT'd apps over
HTTP/WS and raw TCP. The gallery's SPA and signaling fit that fine; **the video
does not**. Tiles stream WebTransport over QUIC — UDP end to end — and carrying
QUIC inside a TCP tunnel would replace its loss recovery with TCP's, which is
the thing a low-latency media path exists to avoid.

So the public deployment has two planes that reach the box by different routes:

```
                    gallery.example.com  ──A──►  203.0.113.10 (vm-control)

  ┌──────────────────────── vm-control (the edge VPS) ─────────────────────────┐
  │  HAProxy :443 ──SNI──► Caddy (LE cert, /ask-gated) ──► forwarder :7080     │
  │                                                             │              │
  │  nftables: udp 54080-54130 ──dnat──► 10.66.0.3 (same port)   │              │
  └──────────────────┬──────────────────────────────────────────┼──────────────┘
      WireGuard      │ (peer dials OUT, PersistentKeepalive)     │ yamux/wss
                     ▼                                          ▼
  ┌──────────────────────────── labhost (the box) ────────────────────────────┐
  │  wg0 10.66.0.3 ──► streamhost@<tile> udp/54xxx   (QUIC, ticket-gated)      │
  │  forwarder-agent ──► 127.0.0.1:8081  the PUBLIC listener (session-gated)   │
  │                      127.0.0.1:8443  the LAN listener (unchanged, open)    │
  └───────────────────────────────────────────────────────────────────────────┘
```

Neither route opens an inbound port at home: the WireGuard peer and the
forwarder agent both dial out.

## The three gates

A public visitor meets three independent checks. Each is useless without the
others, which is why all three exist.

**1. The session gate** (`scripts/serve/auth/gate.py`). The public listener is
default-deny: only the login page, its assets and `/auth/*` are reachable
without a session. The operator command plane (`/clientcmd*`) is refused
outright — it can push arbitrary JavaScript into every open tab, and no amount
of visitor authentication makes that safe to expose. A browser navigating in
gets a 302 to `/login`; a fetch gets a 401.

**2. The passkey** (`scripts/serve/auth/`). WebAuthn via Yubico's `fido2`, with
discoverable credentials so signing in is one tap and no username. Sessions are
random 256-bit tokens in an `HttpOnly; Secure; SameSite=Lax` cookie, stored
server-side as SHA-256 — the state file cannot be replayed into a login. Every
state-changing call must carry `Origin: https://gallery.example.com`.

**3. The media-plane ticket** (`streamhost/src/session_ticket.rs`). This one is
easy to forget and the reason the other two are not enough. A tile's QUIC
listener answers whoever reaches its UDP port, and a WebTransport session
carries the guest's **input** plane as well as its video — so with the ports
published, a login guarding only the SPA would have been decorative: a stranger
could watch the exhibits *and type into them*. The authenticated gateway now
mints a short-lived HMAC ticket per connect and streamhost refuses any session
whose path does not carry a live one for that tile.

The ticket rides the signaling doc's existing `path` field, so the SPA needed no
change. It is minted for LAN callers too — a tile with `SH_SESSION_KEY` set
refuses unticketed sessions from **any** source, so minting only for the public
listener would have taken the LAN gallery down.

## Who gets in

The first person in redeems a **one-time 15-character master token**, which the
server mints on first start and prints to `https-server.log`. Redeeming it
creates the first admin and burns the token, so the "anyone can claim an empty
gallery" window closes on use rather than staying open until someone remembers.

Everyone after that needs an invite an admin issues at `/admin`. The name and
role are baked into the invite, so using one cannot promote anybody. Roles are
`admin` (also manages people) and `viewer` (the gallery). The last admin cannot
be deleted or demoted.

Codes are Crockford base32 — no character pair that is misread aloud, and a
documented mapping for the mistakes people do make (`I`/`L`→`1`, `O`→`0`). They
are stored only as SHA-256, so a lost code is re-issued, never recovered.

### An invite is a link, and the passkey is optional

`/admin` hands out both forms of the same code: the grouped code to read aloud,
and `https://gallery.example.com/login#<code>` with a copy button. Opening the
link **signs the holder in on the spot** — the account is created on first use,
with no passkey — and then offers a passkey, every visit, which is what they
need to keep access once the link expires. Declining is a real answer: they can
come back to the same URL until it lapses. A second visit says how many days are
left and why a passkey is worth making.

This makes the URL a bearer token, so it is bounded on three sides:

* it expires (`INVITE_TTL_SECS`, 7 days) and an admin can revoke it sooner —
  `/admin` shows whether anyone has opened it yet, which is what tells you
  whether revoking will lock somebody out;
* while the account has no passkey, its **session is capped at the invite's own
  expiry**, so access cannot outlive the link that granted it (a 30-day session
  minted on the invite's last day would have made the countdown a lie);
* the code rides the URL **fragment**, which browsers never send — it is absent
  from the access log, from every Referer, and from anything in between. Unlike
  the device-link page, `/login` deliberately does **not** strip it from the
  address bar: this link is meant to be kept and re-opened.

Deleting a person kills their link: the URL will not silently re-create the
account you just removed. And an invite has exactly one route in (`/auth/invite/
enter`) — the passkey ceremony refuses invite codes outright, so no stale client
can make a second account from a link that already has one.

## A second device for the same person

An account is a person, not a device, and it holds as many passkeys as they have
devices. Two ways to add one:

**From a device you are already signed in on** — `/account` → **Link another
device** shows a QR. Scan it with the new device and it creates a passkey on
*that* device for *this* account. The code lives **60 seconds**, is single-use,
and minting a new one kills the old; when the countdown runs out the QR is
replaced by a button to show a fresh one. It rides the URL's **fragment**, which
browsers never send to a server, so it stays out of the access log and out of
any Referer. Every role can do this — managing your own devices is not an admin
power.

**From the new device itself** — sign in with the iCloud/Google-synced passkey
over the browser's own cross-device (QR + Bluetooth) flow, then `/account` →
**Add a passkey for this device**. No link code needed.

What NOT to do: issuing a second *invite* for the same person creates a second
account with the same name. Invites make people; links make devices.

## Operating it

```bash
# Who is in, and what is outstanding
ssh lab 'python3 -c "import json;d=json.load(open(\"/data/vms/streamhost/serve/auth-state.json\"));\
print([(u[\"name\"],u[\"role\"]) for u in d[\"users\"]])"'

# The master token (only ever printed once, at the start that minted it)
ssh lab 'grep BOOTSTRAP /data/vms/streamhost/serve/https-server.log | tail -1'

# Locked out? RESTORE first — the state file is the account database, and the
# server keeps a dated snapshot before the first write of each day.
ssh lab '/data/vms/streamhost/serve/reset-auth.sh --list'
ssh lab '/data/vms/streamhost/serve/reset-auth.sh --restore <file>'

# Only if starting over is genuinely what you want. NEVER `rm auth-state.json`:
# passkeys cannot be regenerated, so deleting it locks every enrolled device out
# forever. reset-auth.sh refuses a populated gallery unless forced, backs up
# either way, and prints how to undo itself.
ssh lab '/data/vms/streamhost/serve/reset-auth.sh --force'

# Outstanding device-link codes (there is at most one per account, ~60s each)
ssh lab 'python3 -c "import json;d=json.load(open(\"/data/vms/streamhost/serve/auth-state.json\"));\
print(d[\"links\"])"'

# Rejected sign-ins, with the real reason (the browser only sees a generic one)
ssh lab 'grep "\[auth\]" /data/vms/streamhost/serve/https-server.log | tail'

# Refused streams
ssh lab 'journalctl -u "streamhost@*" --since "10 min ago" | grep SESSION_REJECTED'

# Would every tile accept the ticket the gateway mints for it? Run this after
# ANY change to the ticket, the key, or a tile's id — a mismatch is invisible
# until a visitor reconnects and the exhibit appears to freeze.
ssh lab 'python3 /data/vms/streamhost/serve/check-stream-tickets.py'
```

The auth state is read once at startup and held in memory, so **editing
`auth-state.json` under a running server does nothing** (and will be overwritten
on the next write). Stop the service, edit, start.

## Rotating the secrets

### Backups

`auth-state.json` is the account database and has no other copy. The server
writes a dated snapshot beside it before the first change of each day (14 kept),
and `reset-auth.sh` takes a timestamped one before anything destructive. Neither
holds a usable secret — invite codes and session tokens are stored as hashes,
and passkey public keys are public — so they need no special handling beyond the
0600 they inherit.

| Secret | Where | Rotate by |
|---|---|---|
| Stream-ticket key | `serve/pki/stream-ticket.key` + `/etc/osgallery/stream-ticket.env` | Write a new value to both, `systemctl restart osgallery-https` and the tiles. Both sides must change together — a mismatch refuses every session. |
| Session cookies | `auth-state.json` | Delete the `sessions` array (server stopped) to sign everyone out. Passkeys survive. |
| A device you lost | `/account` | Remove its passkey there. The server refuses to remove your last one; an admin can remove the whole account from `/admin`. |
| Forwarder token | `/etc/forwarder-agent/agent.env` on the box, `/etc/forwarder/forwarder.env` on the edge | See the forwarder repo; both ends share one token. |
| WireGuard keys | `/etc/wireguard/wg0.conf` both ends | `wg genkey`, update the peer's `PublicKey`, redeploy the edge. |

## Reproducing it

Box side, from a checkout:

```bash
scripts/serve-https-spa.sh deploy        # SPA + server + auth plane + lockfile
ssh lab 'bash /data/vms/streamhost/serve/install-https-service.sh'
```

`install-https-service.sh` builds the Python virtualenv from
`scripts/serve/requirements.txt` (hash-pinned, Dependabot-tracked) before
enabling the unit, and the unit re-syncs it on every start. The public listener
exists only because `PUBLIC_PORT` is set in the unit; unset it and the whole
public plane is gone, LAN untouched.

Edge side is the forwarder's own deploy: set `UDP_RELAY_PEER_IP`,
`UDP_RELAY_PEER_PUBKEY` and `UDP_RELAY_PORT_RANGE` in
`/etc/forwarder/forwarder.env` and land a commit on that repo's `main` — CI
redeploys. The tunnel itself is one entry in `FORWARDER_TUNNELS`, written by
`scripts/cloud-agents/box-endpoint-setup.sh` (`GALLERY_HOST=` to unpublish).

## Testing it

```bash
# The passkey ceremonies, for real. DESTRUCTIVE: it spends the master token, so
# it needs an EMPTY deployment and refuses to run against one that has accounts.
# Do not clear a live gallery to satisfy it — that is how a real admin account
# with two enrolled devices was destroyed on 2026-08-05.
cd tests/e2e-live
PUBLIC_BOOTSTRAP_TOKEN=XXXXX-XXXXX-XXXXX npx playwright test -c e2e/publicAuth.config.ts

# The decisions around the ceremony, offline
ssh lab 'cd /data/vms/streamhost/serve && .venv/bin/python -m unittest discover -s auth -t . -p "test_*.py"'
```

The Playwright suite drives a CDP virtual authenticator, so its passkeys are
genuine WebAuthn: a pass also proves the tunnel, Caddy's certificate, the cookie
flags over the real TLS hop, and — in its last test — a live stream across the
UDP relay.

## Known limits

- **Browser support** is whatever WebTransport + WebCodecs support is: Chrome
  and Chromium-family everywhere, Firefox desktop. Firefox-Android has no
  `VideoDecoder` and gets the existing banner. Safari is untested here.
- **One relay hop** of added latency for public visitors (~4.5 ms box↔edge, plus
  the visitor's own path to Helsinki). LAN visitors are unaffected — they still
  talk to the tile directly.
- **The relay range is a firewall hole** to one host's ports, bounded by
  nftables to `54080-54130` and the single WireGuard peer. It carries no auth of
  its own; the ticket gate behind it is what makes that acceptable.
- **A tile's SPA id is not always its `SH_TILE`.** `solaris` runs as
  `solariscde`, `aros` as `amigaos`. The ticket is signed over the identity the
  DAEMON publishes in its `signaling.json`, not the signalling endpoint's key —
  signing with the latter locked both tiles out of every session for four hours
  on 2026-08-05, which presented as "the exhibit froze after I clicked" because
  the open session kept working and only the next reconnect was refused.
  `check-stream-tickets.py` is the guard.
- **`openvms` is flaky across restarts** (`dual-VM stack did not become ready`)
  and needs a retry — unrelated to any of this, but it will stop a fleet-wide
  promotion, so stop that tile before a `--promote` and start it after.
