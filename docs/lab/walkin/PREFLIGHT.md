# Walk-in production pre-flight

The walk-in wave ends **deployed on the production URL at Invited only**, so that
turning walk-ins on is one click in `/admin` and nothing else — no deploy, no
restart, no edge change, no migration.

This is the ordered list the **coordinator** executes at integration. Each item
says what to run, what "good" looks like, and what to do when it is not.
Lane 9 verified the items marked **VERIFIED** on 2026-08-25 against the live
system; the ones marked **NOT VERIFIABLE WITHOUT THE CODE** could only be
established as a requirement, because the lane that writes the code had not
landed it yet. Nothing here was taken on trust from a doc where the doc could be
wrong.

Ledger: [`CONTRACT-LEDGER.md`](CONTRACT-LEDGER.md) §8. Brief:
[`../WALKIN-BRIEF.md`](../WALKIN-BRIEF.md) §8. Public plane:
[`../../PUBLIC-GALLERY.md`](../../PUBLIC-GALLERY.md).

---

## 0. Blockers found before integration

These are **not** deploy steps. They are edits that must exist in `main` before
the deploy list below is worth running, and **none of them falls inside any
lane's territory** (§1 of the ledger), so nobody owns them by default. The
coordinator must assign or make them.

| # | What is missing | Where | Why it is fatal |
|---|---|---|---|
| B1 | `scripts/serve/walkin/**` is in **no** deploy path | `scripts/lib/box-sync-pairs.sh:202`, `scripts/serve-https-spa.sh:143` | Lane 1's entire package never reaches the box, and `verify-box-sync.sh` never notices |
| B2 | `WALKIN_OPEN` exists in no unit and no script | `scripts/serve/osgallery-https.service` | §4.2 env floor: unset = closed. The admin click does nothing, and fixing it needs the deploy + restart this document exists to avoid |
| B3 | `walkin` missing from the state-file default list | `scripts/serve/auth/store.py:73-77` | `KeyError` on the live `auth-state.json`, on the hot path of every gated request |
| B4 | `/walkin/state` + `/walkin/signup` are public but the gate is default-deny | `scripts/serve/auth/gate.py:22,30` | A signed-out visitor cannot reach the sign-up route at all |

**B1.** Two one-line additions. In `scripts/lib/box-sync-pairs.sh` the serve
tree loop globs only two directories:

```sh
done < <(git -C "$REPO" ls-files 'scripts/serve/auth/*' 'scripts/serve/authui/*' | sort)
```

Add `'scripts/serve/walkin/*'`. In `scripts/serve-https-spa.sh` the deploy tars
the same two:

```sh
tar czf - -C "$REPO/scripts/serve" --exclude __pycache__ auth authui |
  $SSH "set -e; rm -rf $SERVE_DIR/auth $SERVE_DIR/authui; tar xzf - -C $SERVE_DIR"
```

Add `walkin` to both the tar list and the `rm -rf`. Miss the second and a
`serve-https-spa.sh deploy` ships an `osgallery-https-server.py` that imports a
package that is not there — the unit then fails to start, taking the LAN gallery
down with it, which is the worst possible failure for a "one click" launch.

**No gate catches this.** `scripts/lint/deploy-pair-imports.py` is the closest
thing — it exists for exactly this shape of bug (a helper that reaches the box
checkout but never the installed tree) — but it resolves imports only against
`scripts/lib/`, so an unpaired `scripts/serve/walkin/` is invisible to it, and
to `verify-box-sync.sh`, which can only compare files it has a pair for. The
first symptom would be in production.

Note also (`scripts/serve-https-spa.sh:145`) that this deploy path does
`rm -rf $SERVE_DIR/auth`. That is safe today only because `auth-state.json`
sits one level **above** `auth/`. **No walk-in runtime state may be written
under `serve/auth/` or `serve/walkin/`** — it would be deleted, unbacked-up, by
a routine SPA deploy.

**B2.** `WALKIN_OPEN` is referenced by the brief and the ledger and implemented
nowhere. The unit is a synced pair with a `daemon-reload` post step
(`box-sync-pairs.sh:241`), so the fix is an `Environment=WALKIN_OPEN=1` line in
`scripts/serve/osgallery-https.service` (plus the matching default in
`scripts/serve/restart-https.sh`, which writes `/run/osgallery-https.env` and is
loaded **last**, so it wins). Land it with the wave. Landing the floor at `1`
does **not** open walk-ins: the floor can only lower, and `walkin.access`
defaults to `closed`.

**B3.** `store.py::_read` is the only migration point there is. It seeds
top-level keys with `setdefault` and every method afterwards indexes hard
(`self._doc["users"]`, `self._doc["sessions"]`, …). Lane 2 must add `walkin` to
that same list. There is a `version` field but nothing reads it — it is
vestigial, not a migration mechanism. See item 3 below for the verification.

**B4.** `gate.py` is default-deny on the public listener: `OPEN_PATHS` and
`OPEN_PREFIXES` are the entire allowlist. `/walkin/state` and `/walkin/signup`
are `public` in ledger §3 and must be added explicitly. `/walkin/claim`,
`/release`, `/reset` and `/manifest.json` need a session and must **not** be
opened. This is lane 2's file.

> **Do NOT add `/walkin/` to the `reserved` tuple in
> `scripts/serve/static_files.py:169`.** It is tempting — it would make a
> mistyped API path 404 instead of rendering the SPA — but `/walkin`,
> `/walkin/play/<os>` and `/walkin/exhibits` are **client-side** routes that
> depend on the extensionless index fallback. Reserving the prefix would 404
> the visitor's own landing page. The stray-path cost is cosmetic; this is not.

---

## 1. Edge relay range — **VERIFIED GOOD, no change needed**

**Finding: the live edge DNATs exactly `udp 54080–54200`. Walk-in slots 152–200
(ports 54152–54200) all arrive. Item 1 is clear; the plan does not change.**

Verified against the edge itself, not read off a doc, because that is exactly
the failure that shipped on 2026-08-09 (slots 131–134 dark behind a `54130` cap,
with service active, ticket passing and signalling valid). There is no shell on
the edge, so the truth was established by **probing the real path**: send UDP
from labhost out to the edge's public address on a spread of ports, and watch
`wg0` on labhost for what the edge's DNAT actually delivers to `10.66.0.3`.

```sh
# 1. capture what the edge relays into the tunnel (labhost side)
ssh lab 'nohup timeout 120 tcpdump -l -n -i wg0 -c 300 \
  "udp and dst host 10.66.0.3 and dst portrange 54070-54260 and less 60" \
  > /tmp/wgprobe.txt 2>/dev/null </dev/null & echo started'

# 2. knock on the edge's PUBLIC address across the boundary
#    (the address is `wg show wg0 endpoints`; never write it down here)
ssh lab 'EDGE=$(wg show wg0 endpoints | awk "{print \$2}" | cut -d: -f1); \
  for i in 1 2; do for p in 54079 54080 54130 54152 54176 54199 54200 54201 54250; do \
    printf "KHPROBE-%s" "$p" | timeout 3 nc -u -w1 "$EDGE" "$p" >/dev/null 2>&1 || true; \
  done; done; echo sent'

# 3. what got through
ssh lab 'sed "s/.*10.66.0.3.//;s/:.*//" /tmp/wgprobe.txt | sort -n | uniq -c; rm -f /tmp/wgprobe.txt'
```

**Result on 2026-08-25** (`2` = both probes arrived, absent = nothing arrived):

| Port | 54079 | 54080 | 54085 | 54130 | 54131 | 54152 | 54176 | 54199 | 54200 | 54201 | 54250 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| arrived | — | 2 | 2 | 2 | 2 | **2** | **2** | **2** | **2** | — | — |

Both edges of the range are sharp and in the right place: `54079` and `54201`
are silent, `54080` and `54200` arrive. The whole walk-in slot block is covered
with the top slot exactly on the boundary. The `less 60` filter keeps live
stream traffic out of the capture — an unrelated public session on `54090` was
in flight during the first attempt and filled a 60-packet capture in under a
second, which is worth knowing if this is re-run.

**Good looks like:** every probed port from 54080 to 54200 shows a count,
54079/54201 show none.

**If it is short:** the rule is *derived*, not authoritative. Do not patch the
edge by hand. Change `UDP_RELAY_PORT_RANGE` in the **forwarder** repo's
`deploy/site.env` — one commit on its `main`, CI rewrites `/etc/nftables.conf`
on the edge. Then keep the three-way agreement:
`registry/registry-v1.json` `ports.publicRelayLow/High` ==
`UDP_RELAY_PORT_RANGE` == the range quoted in `docs/PUBLIC-GALLERY.md`
(`scripts/stations_registry/generate.py:171-178` asserts the registry against
`scripts/serve/install-public-relay.sh`, which is the emergency hotfix path
only). Re-run the probe above afterwards; nothing on labhost will tell you.

**Caveat, stated plainly:** the probe proves packets *reach labhost's `wg0`* at
those ports. It does not prove the walk-in clone bound to that port will accept
a session — that is the ticket gate, item 5.

---

## 2. Serving-plane deploy and restart — the exact order

New routes under `scripts/serve/` reach production through **two different
doors**, and neither alone is enough.

* `scripts/dev/box-deploy.sh --apply` deploys a **commit**: it fast-forwards the
  box checkout to `origin/main` and installs the per-file pairs in
  `scripts/lib/box-sync-pairs.sh`. It ships the serve-plane Python, the systemd
  unit and `requirements.txt`. **It has no row for the SPA bundle** and it
  **restarts nothing**.
* `scripts/serve-https-spa.sh deploy` pushes from your **working tree**: the
  built `spa/dist/` into `webroot/`, a fixed name list of serve files, the
  `auth`/`authui` trees, and a wholesale republish of the runtime manifests.

Run, in this order:

```sh
# 0. everything is on origin/main; box-install refuses a dirty checkout
git -C <coordination worktree> status --porcelain   # empty
git push origin main

# 1. serve plane (python, unit, requirements) — the commit door
scripts/dev/box-deploy.sh --apply

# 2. the SPA bundle — box-deploy cannot ship it
scripts/serve-https-spa.sh build     # a PRODUCTION base build, never a stage.sh dist
scripts/serve-https-spa.sh deploy

# 3. venv, only if requirements changed (ExecStartPre no-ops otherwise)
ssh lab '/data/vms/streamhost/serve/sync-venv.sh --check'

# 4. restart the HTTPS plane — the new routes do not exist until this runs
ssh lab '/data/vms/streamhost/serve/restart-https.sh'

# 5. re-arm darklaunch overlays that step 2 wiped   (item 6)
# 6. verify
scripts/dev/box-deploy.sh --status
scripts/dev/verify-box-sync.sh
```

**Good looks like:** `--status` reports the pushed rev; `verify-box-sync.sh`
reads `N MATCH, k DARKLAUNCH, 0 need attention`; `restart-https.sh` prints
`https server up on :8443 via systemd`; `curl -sk https://127.0.0.1:8443/walkin/state`
on the box returns `{"access":"invited",…}` rather than HTML (HTML means the
route does not exist and the SPA index fallback answered — go back to B1).

**If step 4 is skipped:** the unit keeps running the old module objects. The
signalling documents (`tiles.json`, `gallery-manifest.json`) are re-read fresh
per request and need no restart, but **Python route code does**.

**Traps.**

* `scripts/dev/box-deploy.sh` **without `--apply` still syncs the box checkout**
  — a bare "plan" mutates the baseline. Only run it when you mean to.
* `serve-https-spa.sh:100` aborts the deploy if `spa/dist/index.html` lacks
  `src="/assets/` — that catches a leftover `stage.sh` build with
  staging-rooted asset paths. Do not work around it; rebuild.
* `box-deploy --apply` clobbers live agent edits on the box. Confirm no station
  agent is mid-flight (`ssh lab 'labctl who'`) before running it.

---

## 3. `auth-state.json` migrates in place — **VERIFIED for the current file, requirement stated for lane 2**

**Nothing anywhere `rm`s it during a deploy or a test run.** That was checked,
not assumed:

| Path | What it does | Verdict |
|---|---|---|
| `scripts/serve/reset-auth.sh:100` | the **only** `rm -f` of the file | Guarded: refuses when accounts exist unless `--force`, and takes a timestamped backup first (line 98). No caller anywhere in the repo — docs only |
| `scripts/serve/auth/store.py:118` | `os.replace(tmp, path)` | The normal atomic write |
| `scripts/serve/auth/store.py:100` | `stale.unlink()` | Deletes **dated snapshots** past 14; the glob cannot match the live file |
| `scripts/serve/install-https-service.sh:34` | `rm -f /run/*` only | No risk |
| `scripts/dev/box-deploy.sh` | no rsync, no `--delete`, no `rm` — per-file pairs | Cannot remove it |
| `scripts/serve-https-spa.sh:146` | `rm -rf $SERVE_DIR/auth $SERVE_DIR/authui` | Safe **only** because the state file lives one level above. See B1 |
| `tests/e2e-live/e2e/publicAuth.spec.ts` | destructive suite | Double-guarded: skips without `PUBLIC_BOOTSTRAP_TOKEN` (line 37) and hard-throws in `beforeAll` if the gallery already has accounts (line 58) |
| `scripts/serve/auth/test_auth.py`, `scripts/test_usage_stats.py` | unit tests | `TemporaryDirectory`; no path to the live file |

**Tolerance of a live file that lacks the new keys — the load path
(`store.py:63-77`):**

```python
doc.setdefault("version", 1)
for key in ("users", "credentials", "invites", "links", "sessions"):
    doc.setdefault(key, [])
doc.setdefault("bootstrap", None)
```

Loading tolerates anything: unknown keys survive, missing keys are seeded. The
save path dumps `self._doc` **whole** with `fsync` + atomic rename, so the
seeded defaults land on disk at the next write. **But the tolerance stops at
this list.** Every method below it indexes hard. If lane 2 reads
`self._doc["walkin"]` without adding `walkin` to that `setdefault` block, the
live file — which has no `walkin` — raises `KeyError` inside `session_user` /
`_touch_seen`, which runs on **every gated request**. That is B3.

**Check at integration, before the restart in item 2:**

```sh
ssh lab 'python3 -c "import json;d=json.load(open(\"/data/vms/streamhost/serve/auth-state.json\"));print(sorted(d))"'
ssh lab 'cp -a /data/vms/streamhost/serve/auth-state.json \
         /data/vms/streamhost/serve/auth-state.pre-walkin.json'   # a same-day restore point
# ... restart ... then sign in once on the gallery and re-read:
ssh lab 'python3 -c "import json;d=json.load(open(\"/data/vms/streamhost/serve/auth-state.json\"));print(json.dumps(d.get(\"walkin\"),indent=2))"'
```

**Good looks like:** the first read shows the existing keys and no `walkin`;
after a restart and one authenticated request the second read shows
`{"access": "closed", "drain": false, "accounts": {}, "audit": []}` and every
pre-existing user is still present.

**If it does not:** the dated snapshot (`auth-state.<date>.json`) is once per
UTC day and best-effort, which is why the manual copy above exists. Restore with
`reset-auth.sh --restore <file>`. Never `rm` the file, and never edit it under a
running server — the doc is held in memory and the next write overwrites you
(`docs/PUBLIC-GALLERY.md`). Stop → edit → start.

---

## 4. Service worker staleness — **VERIFIED, a returning visitor gets the new routes**

The SPA is an installable PWA, but the service worker is hand-written
(`spa/public/sw.js`, registered in `spa/src/main.tsx:134`, production only) and
it is **network-first for top-level navigations and caches nothing else**:

```js
if (req.mode !== 'navigate') return;
const fresh = await fetch(req);       // network first
if (fresh.ok) cache.put(SHELL_KEY, fresh.clone());
return fresh;                          // cached shell only in the catch
```

That is what makes the answer yes. Four things hold it up, and all four were
checked in the code:

1. Navigations go to the network; the single cached shell (`kh-app-shell`) is
   returned **only** when the fetch throws, i.e. fully offline.
2. The SW takes over immediately — `skipWaiting()` on install, `clients.claim()`
   on activate — so there is no "waiting worker" window.
3. `index.html` is served `Cache-Control: no-store` with no validators
   (`scripts/serve/static_files.py:51-56`), so the HTTP cache cannot serve an
   old shell either.
4. Hashed `/assets/*` are `immutable` for a year but their names change per
   build, and they are never `mode: 'navigate'`, so the SW does not touch them.

`/walkin` itself resolves because `static_files.py:166-185` falls back to
`index.html` for any extensionless, non-reserved path. `/walkin` is not
reserved, and must stay that way — see the warning under B4.

**Check at integration**, in a browser that already has the PWA installed
(not a fresh incognito window — that proves nothing about staleness):

open the installed app, navigate to `/walkin`, and confirm the walk-in landing
page renders.

**If instead you land on the station grid**, the shell is not stale — the
**bundle** is old. `spa/src/App.tsx` ends in
`<Route path="*" element={<Navigate to="/" replace />} />`, so a bundle without
lane 4's route silently redirects rather than erroring. Re-run item 2 step 2
(build + deploy) and hard-reload; if it persists, check that the build was a
production base build and not a staging one.

**One genuine, bounded hazard:** `/sw.js` is served
`public, max-age=60, stale-while-revalidate=600` (it falls into the default
branch of `_static_cache_policy` — it is not `.html` and not a hashed asset).
If this wave changes `sw.js` itself, a returning visitor can run the previous
worker for up to 60 s, and up to 10 minutes while revalidating. Browsers also
bypass the HTTP cache on their own SW update check, so it self-heals; it is a
window, not a wedge. **If lane 4 does not touch `sw.js`, this is a non-issue.**

---

## 5. `check-stream-tickets.py` knows the pool — **DONE (lane 9)**

`scripts/serve/check-stream-tickets.py` now classifies every `tiles.json` row
by the frozen clone identity `walkin-<os>-<n>` (ledger §5.1):

* a pool slot with **no published `signaling.json` is `idle`** — the pool's
  normal resting state — and is never a failure. Without this, enabling walk-in
  turns the fleet health check red on a perfectly healthy box, which is the
  fastest way to make it stop being read;
* a **running** clone is held to exactly the same HMAC ticket check as a station;
* a per-OS pool summary is printed (`live` / `idle` / `REFUSING`);
* the closing line no longer claims that skipped tiles accept their tickets.

Run it (read-only, safe at any time):

```sh
ssh lab 'python3 /data/vms/streamhost/serve/check-stream-tickets.py'
```

**Good looks like** — before the pool is provisioned:

```
--- walk-in pool ---
  no walk-in clones in tiles.json (pool not provisioned, or access closed)

all 70 running tile(s) of 71 accept their own tickets
```

and once lane 1's pool exists, a line per OS, e.g.
`os2warp      3 slot(s): 1 live, 2 idle`. Exit status 0.

**If a clone shows `REFUSING`:** the ticket is signed over the identity the
**daemon** publishes in its own `signaling.json`, not the signalling endpoint
key. For a clone those two are `walkin-<os>-<n>` and must match; a clone that
inherited the parent station's `SH_STATION` will fail with `bad signature`, and
the symptom to a visitor is "it froze after I clicked".

There is also an **opt-in** range check that ties this file to item 1 without
becoming a fourth place the range is declared:

```sh
ssh lab 'python3 /data/vms/streamhost/serve/check-stream-tickets.py --relay-range 54080-54200'
```

Any tile whose `udpPort` falls outside is reported as a failure. Pass the range
from `registry/registry-v1.json` `ports.publicRelayLow/High`; it is deliberately
not defaulted.

**Note this file travels on both doors** — it is a named row in
`box-sync-pairs.sh` *and* in `serve-https-spa.sh`'s name list — and it needs no
restart, because it is a standalone script.

---

## 6. Darklaunch overlays — re-arm after the SPA deploy

`serve-https-spa.sh deploy` republishes `tiles.json`, `gallery-manifest.json`,
`poster-docs.json`, `fleet-table.json` and `golden-manifest.json` wholesale from
the rendered registry. A dark-launch overlay lives **inside** the first two, so
the deploy wipes it while leaving its declaration file in
`serve/darklaunch.d/` — which then fails the gate as `DARKLAUNCH_STALE`.

**Before item 2 step 2, write down what is armed:**

```sh
ssh lab 'ls /data/vms/streamhost/serve/darklaunch.d/'
```

**Verified 2026-08-25: this directory is currently empty** — nothing is armed
right now, so if it is still empty at integration this item is a no-op. It is
not stable state: any lane that dark-launches a bring-up rig arms one, so
**check, do not assume.**

**After the SPA deploy, re-arm each declaration by re-running its `owner`
script** (the `owner` field inside the JSON names it — normally
`scripts/dev/darklaunch-station.py`):

```sh
ssh lab '/data/kernel-hive/scripts/dev/darklaunch-station.py publish <id> --rig <rig> --entry <entry.json>'
ssh lab '/data/kernel-hive/scripts/dev/darklaunch-station.py status <id>'
scripts/dev/verify-box-sync.sh
```

**Good looks like:** `verify-box-sync.sh` reports the overlay as `DARKLAUNCH`
(green, non-blocking), not `DIFFERS` and not `DARKLAUNCH_STALE`. No restart is
needed — both documents are re-read per request.

---

## 7. The last check: the click itself

With everything above green and `walkin.access` at `invited`:

1. `/admin` shows the walk-in panel with a three-position switch, and the
   `envFloor` it reports is **not** `closed` (if it is, B2 was missed and the
   switch is decorative).
2. `GET /auth/walkin/status` as an admin returns `access: "invited"` and the
   pools lane 1 provisioned.
3. Move the switch to **Open**, then back to **Invited**. `POST
   /auth/walkin/access` returns the new value, the audit array in
   `auth-state.json` gains a row, and no deploy, restart or edge change was
   involved.

That third step is the actual acceptance test for this document. If any part of
it needs a shell, the wave is not finished.
