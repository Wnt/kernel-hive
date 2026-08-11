# scripts/serve — HTTPS SPA origin + same-origin signaling

Files here make the Kernel Hive front-end reproducible from the repo. This is
the single canonical serve/ (the former byte-identical duplicate
`streamhost/serve/` was merged here). Box sync target:
`/data/vms/streamhost/serve/` on the lab host (`restart-https.sh` hardcodes
`SERVE=/data/vms/streamhost/serve`) — re-copy changed files there when you
edit them.

| file | role |
|------|------|
| `osgallery-https-server.py` | HTTPS server on `:8443`. Serves the built SPA (`WEBROOT`) and answers `GET /signal/<osId>.json` (host + udpPort + live cert hash) and `GET /signal/index.json` from `SIGNAL_CONFIG` (= `tiles.json`). Reads tiles.json + each tile's cert-hash file fresh per request, so cert rotation needs no restart. Its admin/observability routes require `X-Admin-Token`; arbitrary-JS eval is additionally default-off (below). |
| `auth/` | Passkey auth for the **public** listener only (see [docs/PUBLIC-GALLERY.md](../../docs/PUBLIC-GALLERY.md)): invite codes, the state file, WebAuthn ceremonies, the policy, the `/auth/*` routes, and the stream tickets streamhost checks. Unit tests: `.venv/bin/python -m unittest discover -s auth -t . -p "test_*.py"`. |
| `authui/` | The standalone pages the auth plane serves: `/login`, `/account` (your passkeys + the **link another device** QR), `/admin` (people), and `/link` (where a scanned QR lands). Deliberately not part of the SPA bundle — a signed-out visitor should not download a WebGL museum to be shown a login button. |
| `requirements.in` / `requirements.txt` | Declared and hash-pinned third-party Python (WebAuthn). Dependabot watches the pair; `sync-venv.sh` installs it. NOT apt — the box should not wait for a Debian backport for a security fix. |
| `sync-venv.sh` | Builds `.venv` from the lockfile, idempotently (`--check` verifies without installing). Run as the unit's `ExecStartPre`, so a Dependabot bump lands on restart. |
| `check-stream-tickets.py` | Fleet check: for every tile, does the ticket the gateway mints actually verify against that daemon's `SH_TILE`? Catches the id-divergence class of bug — the one that took `solaris`/`solariscde` down for four hours on 2026-08-05 — which otherwise only shows up as an exhibit freezing on reconnect. |
| `reset-auth.sh` | The ONLY sanctioned way to wipe or restore the gallery's accounts. Refuses a populated gallery without `--force`, backs up first, and can `--restore` any snapshot. `rm auth-state.json` is not an equivalent shortcut — it destroys passkeys permanently. |
| `gen-local-ca.sh` | Mints the local root CA + leaf server cert (`pki/`) the browser trusts for the HTTPS SPA origin. Idempotent. |
| `tiles.json` | **Not in the repo** — the signaling registry (osId → udpPort + cert-hash file) is rendered from `registry/tiles/`: `python3 scripts/stations-registry.py emit tiles.json`. The live copy at `/data/vms/streamhost/serve/tiles.json` is what the server reads; `serve-https-spa.sh manifests` renders and publishes it. |
| `webroot/gallery-manifest.json` | **Not in the repo** — the public SPA lineup (museum metadata + archetype/transport/order/signal reference; no credentials) is rendered from the registry on demand: `python3 scripts/stations-registry.py emit gallery-manifest.json`, or `serve-https-spa.sh manifests`, which renders it and lands it at this path under `/data/vms/streamhost/serve/` to be served as `/gallery-manifest.json`. |
| `reset-tile.sh` | Golden reset for one tile: `loadvm golden` where a golden snapshot exists, cold-boot restart otherwise; never runs `savevm`. Called by the e2e suite and by the server's `POST /restore/<osId>` endpoint. |
| `golden-manifest.json` | **Not in the repo** — the per-tile golden-fixture manifest (reset mode, snapshot name, expected fixture description) that `reset-tile.sh` and the e2e checks consult is rendered: `emit golden-manifest.json`. Published beside the server by `serve-https-spa.sh manifests`. |
| `clientcmd.sh` | Operator wrapper for the observability plane: enqueue commands, token-authenticated `restore`, and local log readers. Run on the box or from anywhere — it re-execs itself over `ssh lab` when the token file isn't local. |
| `test-clientlog.sh` | SPA-independent security/functional smoke test for the public, admin, restore, and eval contracts on throwaway local servers. Run it locally after touching the server. |

Two server endpoints beyond `/signal/` and the observability plane:

- **`POST /restore/<osId>`** — `X-Admin-Token`-authenticated, non-destructive
  golden reset of one tile (runs `reset-tile.sh`; 403 unless authenticated and
  `RESTORE_ENABLE`, 404 for unknown osIds). StreamView prompts the operator for
  the token and keeps it only in that tab's `sessionStorage`.
- **`/boot/` boot-video plane** — the SPA's boot-replay clips are served as
  static files with single-range **HTTP Range** support (206/416), so
  `<video>` can scrub/seek without pulling the whole mp4; `.mp4`/`.m4v`/
  `.webm`/`.vtt`/`.m4s` MIME types are registered, and `/boot/` is a reserved
  prefix (missing clips 404 instead of falling back to the SPA index).

## Client observability: `/clientlog` + `/clientcmd`

An authenticated operator SPA tab batches telemetry events and polls commands.
Ordinary public tabs do neither: an RFC1918/loopback peer address never grants
access. All files live beside the server and are (re-)read per request —
hand-edits need no restart, and `restart-https.sh`'s log truncation never touches
them.

| endpoint | what |
|----------|------|
| `POST /clientlog` | Requires `X-Admin-Token`. Body: one JSON event object or an ARRAY of events (16 KiB cap, chunked rejected). Server adds `srvTs` + `ip`, truncates client fields, and appends rotating JSONL. |
| `GET /clientcmd?since=<seq>` | Requires `X-Admin-Token`. Reads `clientcmd.json` fresh and returns only newer commands; filters stale `eval` commands whenever eval is off. |
| `POST /clientcmd/admin` | Requires `X-Admin-Token`. Enqueues `snapshot`, `verbose`, or `reload`; `eval` is accepted only with `OSG_ADMIN_EVAL=1`. Queue writes are bounded and atomic. |
| `POST /restore/<osId>` | Requires `X-Admin-Token`; executes the manifest-approved non-destructive reset only. |

Files (all under `$SERVE` = `/data/vms/streamhost/serve` on the box):
`clientlog.jsonl` (+ `.1`), `clientcmd.json`, `pki/clientcmd.token`.

Mint the token once (fails CLOSED — all admin/observability routes 403 until it exists):

```bash
ssh lab 'openssl rand -hex 32 > /data/vms/streamhost/serve/pki/clientcmd.token \
         && chmod 600 /data/vms/streamhost/serve/pki/clientcmd.token'
```

Operator one-liners:

```bash
# enqueue commands (wrapper reads the token itself; ssh-transparent)
scripts/serve/clientcmd.sh snapshot amiga     # one tab posts full metrics
scripts/serve/clientcmd.sh verbose '*'        # all tabs: verbose debug toggle
scripts/serve/clientcmd.sh reload win95       # reload that tile's tab(s)
scripts/serve/clientcmd.sh restore win95      # token-authenticated golden reset

# watch / filter telemetry
scripts/serve/clientcmd.sh tail               # tail -f clientlog.jsonl
scripts/serve/clientcmd.sh log amiga          # last 200 events for one tile
ssh lab "tail -500 /data/vms/streamhost/serve/clientlog.jsonl" \
  | jq -r 'select(.tile=="amiga") | [.srvTs,.event,.detail] | @tsv'

# inspect / hand-edit the queue (file is re-read per poll, no restart needed)
ssh lab 'cat /data/vms/streamhost/serve/clientcmd.json' | jq .
```

Authenticate an operator browser tab before enqueuing browser commands: in
DevTools run `window.__kernelHiveAdminLogin()`, then enter the token in the prompt.
The value is not part of the command history, URL, or bundle. Close the tab or run
`window.__kernelHiveAdminLogout()` to discard it.

Arbitrary-JS eval has a second gate and is **off by default**. For a bounded
debug session, restart the server with `OSG_ADMIN_EVAL=1`, authenticate the
operator tab, and also prefix the helper invocation:

```bash
ssh lab 'OSG_ADMIN_EVAL=1 /data/vms/streamhost/serve/restart-https.sh'
OSG_ADMIN_EVAL=1 scripts/serve/clientcmd.sh eval <sessionId> '<javascript>'
OSG_ADMIN_EVAL=1 scripts/serve/clientcmd.sh evallog <sessionId>
ssh lab '/data/vms/streamhost/serve/restart-https.sh'  # eval off again
```

Restart without the variable (or with `OSG_ADMIN_EVAL=0`) immediately returns to
the default; queued eval commands are filtered while it is off.

## SECRETS — not in the repo (carry safely, never commit)

`serve/pki/` on the host holds `rootCA.key`, `rootCA.pem`, `leaf.key`, `leaf.crt`,
`fullchain.crt`, and `clientcmd.token` (the `/clientcmd/admin` shared secret).
These are **private keys / certs / tokens and are intentionally NOT copied
into Git.** The trust-continuity set is `rootCA.key` (CA private key, mode 600) plus
its matching public `rootCA.pem`. Carry that pair in the gitignored
`scripts/serve/pki/` directory across rebuilds. Losing the key means the existing root
cannot sign a new leaf; replacing it would require browser re-trust everywhere.

After restoring the root pair, regenerate only the leaf (and regenerate
`clientcmd.token` separately if it was not carried):

```bash
# on the host, as root
cd /data/vms/streamhost/serve
chmod 600 pki/rootCA.key
./gen-local-ca.sh                 # reuses pki/rootCA.*; writes leaf.* + fullchain.crt
# one-time trust on the Mac (Chrome uses the macOS System keychain):
#   scp root@192.0.2.10:/data/vms/streamhost/serve/pki/rootCA.pem .
#   sudo security add-trusted-cert -d -r trustRoot \
#     -k /Library/Keychains/System.keychain rootCA.pem
```

Verify the recovered pair before use by comparing public-key or modulus digests with
OpenSSL; never print or log `rootCA.key` itself.

The streamhost WebTransport certs are a **separate** self-signed P-256 pinned via
`serverCertificateHashes` (minted by the Rust `cert.rs`, rotated ~10 d, published
to each tile's `cert_hash_b64.txt` + `signaling.json`) — those need no CA trust
and are created automatically when each `streamhost@<tile>` daemon starts.

## Run the HTTPS server (host)

The server is supervised by **systemd** (`osgallery-https.service`) so it comes
back on its own after a reboot / power cycle. One-time install from a repo
checkout on the box (idempotent; also used by the full rebuild):

```bash
ssh lab 'bash /data/vms/streamhost/serve/install-https-service.sh'
```

Day-to-day the unit is the authority:

```bash
ssh lab 'systemctl status osgallery-https.service'   # state + recent
ssh lab 'systemctl restart osgallery-https.service'  # or restart-https.sh
ssh lab 'journalctl -u osgallery-https.service -n 50'
# logs also append to /data/vms/streamhost/serve/https-server.log
```

`restart-https.sh` (and `serve-https-spa.sh up/down/status`) auto-detect the unit
and drive it through systemd; on a box without the unit they fall back to the old
detached `nohup` launch. To run the server by hand (no supervisor):

```bash
WEBROOT=/data/vms/streamhost/serve/webroot \
SIGNAL_CONFIG=/data/vms/streamhost/serve/tiles.json \
CERT=/data/vms/streamhost/serve/pki/leaf.crt \
KEY=/data/vms/streamhost/serve/pki/leaf.key \
SIGNAL_HOST=192.0.2.10 PORT=8443 BIND_IP=0.0.0.0 \
  python3 osgallery-https-server.py
```

The public listener remains on `0.0.0.0`; authorization is the token, never the
socket peer address. Set `OSG_ADMIN_EVAL=1` only for deliberate eval sessions —
under systemd it is handed to the unit via `/run/osgallery-https.env` (tmpfs), so
a reboot always returns to eval **off** regardless of the last restart.

## SPA bundle

The built Vite SPA served from `WEBROOT` (`/data/vms/streamhost/serve/webroot/`)
is produced from `spa/` in this repo (`npm run build`); deploy the `dist/`
output into `webroot/` as part of a full rebuild. The bundle itself is not
vendored in the repo.
