# Walk-in contract ledger — frozen shared values for the build wave

The walk-in epic ([`../WALKIN-BRIEF.md`](../WALKIN-BRIEF.md)) is built as ten
parallel lanes. **Everything two lanes would otherwise have to agree on is fixed
here, before any lane forks.** A lane implements against this document, never
against another lane's code.

The rule that makes the wave work: **if a name, route, key or number appears
below, it is not yours to choose.** If something you need is missing, ask the
coordinator to add it here — do not invent it locally, because the other lane
will invent a different one.

---

## 1. Lane roster and file territory

One lane owns a path. No lane writes outside its territory. Anything shared is
created by the ledger commit, not by a lane.

| # | Lane | Owns (writes) | Reads |
|---|---|---|---|
| 1 | **broker** | `scripts/serve/walkin/**` | §3, §5, §6 |
| 2 | **auth core** | `scripts/serve/auth/**` | §3, §4, §5 |
| 3 | **handles** | `scripts/serve/auth/handles/**` (module + wordlists) | §4.3 |
| 4 | **walk-in UI** | `spa/src/walkin/**` | §3, §7 |
| 5 | **admin UI** | `spa/src/admin/**` | §3, §7 |
| 6 | **network plane** | `scripts/retronet/walkin-net/**`, box-side CT 951 | §6 |
| 7 | **`os2warp` enablement** | `registry/walkin/os2warp.json`, `streamhost/stations/os2warp/wi-tapnet.sh` | §5, §6 |
| 8 | **`rhapsody` enablement** | `registry/walkin/rhapsody.json`, `streamhost/stations/rhapsody/wi-tapnet.sh` | §5, §6 |
| 9 | **production pre-flight** | `docs/lab/walkin/PREFLIGHT.md`, `scripts/serve/check-stream-tickets.py` | §8 |
| 10 | **`win311` enablement** | `registry/walkin/win311.json`, `streamhost/stations/win311/wi-tapnet.sh` | §5, §6 |

Lane 3 is nested inside lane 2's tree but is the only writer under
`auth/handles/`; lane 2 writes the single call site, which the ledger commit
stubs so neither lane creates it.

**Territory is enforced by the push gate.** The box-state check fails a push only
on rows that push touches
([`../AGENT-CI-EXIT-RULE.md`](../AGENT-CI-EXIT-RULE.md)), so disjoint
territories mean lanes cannot redden each other's pushes.

## 2. Wave rules

1. **Your own full stack**: `scripts/dev/wt.sh new <lane>`. Never the shared clone.
2. **No lane runs `box-deploy`** — not `--apply`, not a bare plan, not `--sync`.
   Deploying is the coordinator's, once, at integration. To exercise your own row
   live, install *your* row from *your* tree.
3. **UI review is staging**: `box-deploy.sh --stage` → `/staging/<lane>/`.
4. **Land small and often.** Several small merges beat one terminal commit.
5. **Smoke checks, not drills.** One happy path per feature plus the quality
   gate. Hardening and load are a later pass; problems get fixed after the
   initial version is up.
6. **Green before done** — the gate for the languages you touched plus
   `node scripts/check-file-size.mjs --strict` and `make station-registry-check`,
   or report **BLOCKED** with the failing command and output.
7. **Never `wt.sh gc --apply`** — other people's evidence sandboxes live on that
   box. Remove only your own, with `wt.sh rm <lane>`.
8. **Placeholders stay placeholders.** No real IP, MAC, host or domain in a
   commit; real values live in gitignored `registry/local.env`.

## 3. HTTP contract

Same origin as the gallery. All walk-in routes live under `/walkin/`; the switch
lives under `/auth/` because it is an admin control.

| Route | Method | Role | Request | Response |
|---|---|---|---|---|
| `/walkin/state` | GET | public | — | `{"access":"closed\|invited\|open","pools":[{"os":"os2warp","free":2,"size":3}],"notice":"…"}` |
| `/walkin/signup` | POST | public | WebAuthn attestation | `{"handle":"bold-turing","role":"walkin"}` |
| `/walkin/claim` | POST | walkin, viewer, admin | `{"os":"os2warp"}` | `{"clone":"walkin-os2warp-3","signalEndpoint":"/signal/walkin-os2warp-3.json","ttlSeconds":1200}` or `{"queued":true,"position":2}` |
| `/walkin/release` | POST | owner | `{"clone":"…"}` | `{"ok":true}` |
| `/walkin/reset` | POST | owner | `{"clone":"…"}` | same shape as claim |
| `/walkin/manifest.json` | GET | walkin | — | §5.3 of the brief — allowlisted exhibition fields, one `signalEndpoint` |
| `/auth/walkin/status` | GET | admin | — | `{"access":"…","envFloor":"…","sessions":3,"pools":[…],"accounts":41}` |
| `/auth/walkin/access` | POST | admin | `{"access":"closed\|invited\|open"}` | `{"access":"…","disconnected":3}` |
| `/auth/walkin/drain` | POST | admin | `{"drain":true}` | `{"ok":true}` |
| `/auth/walkin/purge` | POST | admin | `{"olderThanDays":90}` | `{"purged":7}` |

Errors are the existing `AuthError` shape. A refused claim while closed returns
**403** with `{"error":"walkin_closed"}`.

### 3.1 Reason codes

| Code | Meaning | Who emits |
|---|---|---|
| `WALKIN_CLOSED` | Access dropped to Closed under a live session | broker → client |
| `WALKIN_TTL` | Session hit its TTL | broker |
| `WALKIN_IDLE` | No input for the idle window | broker |
| `walkin_closed` | HTTP body error on a refused claim/signup | auth |

`WALKIN_CLOSED` sits beside the existing `SESSION_REJECTED`; the SPA renders
distinct copy per code (§7).

## 4. Persisted state

### 4.1 `auth-state.json`

Written through the existing store. **Migration is in place and tolerant**: a
live file without these keys gains defaults on first write. Never `rm` it.

```
walkin: {
  access:   "closed" | "invited" | "open",   # default "closed"
  drain:    false,
  accounts: { <userId>: { handle, createdAt, lastSeenAt } },
  audit:    [ { at, admin, from, to } ]
}
```

### 4.2 Env floor

`WALKIN_OPEN` in the serving unit's environment. `0`/unset = the effective
access is `closed` whatever `walkin.access` says. It can only lower, never raise.

### 4.3 Handles

`<adj>-<pioneer>`, adjectives ≤5 chars, pioneer surnames ≤7, both lists curated
and committed under `scripts/serve/auth/handles/`. Collisions take `-2`…`-9`.
Allocation happens inside the same store lock that writes `auth-state.json`.
The handle is display-only and carries no authority.

Lane 3 exposes exactly one entry point, which lane 2 imports:

```python
# scripts/serve/auth/handles/__init__.py
def generate_handle(taken: set[str]) -> str: ...
```

Lane 3 lands first (it is the smallest lane). If lane 2 is ready to push before
that module is on `main`, lane 2 rebases — it does not create the module.

## 5. Clone identity and the per-station override

### 5.1 Names

| Thing | Form | Example |
|---|---|---|
| Clone identity | `walkin-<os>-<n>` | `walkin-os2warp-3` |
| Sandbox root | `/data/vms/walkin/<identity>/` | — |
| Tap | `wi-<os>-<n>` (≤15 chars, kernel limit) | `wi-os2warp-3` |
| systemd | `walkin.slice`, `walkin-clone@<identity>.service` | — |
| Slot | claimed from **152–200** via `kh-claim` | — |
| UDP port | `54000 + slot` | slot 152 → 54152 |
| Clone MAC | generated per clone, `02:00:00:00:57:<slot-hex>` in docs | — |

Slots, taps and IPs are claimed with `kh-claim` under `$KH_SESSION`. Never
check-then-create ([`../OPERATING-RULES.md`](../OPERATING-RULES.md) rule 7).

### 5.2 `registry/walkin/<station>.json`

Adding an OS to the pool is **data, not code**. The broker reads this; the
enablement lanes write it. Unknown keys are an error, not a silent ignore.

```json
{
  "station": "os2warp",
  "enabled": true,
  "poolSize": 2,
  "seed":       { "disk": "…/os2warp-golden.qcow2", "readOnly": true },
  "overlay":    { "format": "qcow2", "discardOnKill": true },
  "launcher":   "streamhost/stations/os2warp/qemu-streamhost.sh",
  "overrides":  {
    "netdev": { "type": "tap", "bridge": "vmbr-wi", "ifnamePattern": "wi-os2warp-%d" },
    "tapnet": "streamhost/stations/os2warp/wi-tapnet.sh"
  },
  "sandbox": true
}
```

**`overrides` may change paths, ports, tap names and netdev *options* only.**
It may not add, remove or retype a device: `loadvm` matches the device set the
golden was captured against, and the binary is bound to that same combination
([`../OPERATING-RULES.md`](../OPERATING-RULES.md) rule 6). `sandbox: true` adds
`-sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny`
where the binary is QEMU.

## 6. The walk-in network plane

| Value | Frozen |
|---|---|
| Bridge | `vmbr-wi`, `bridge-ports none` |
| Subnet | `10.98.0.0/24` |
| Gateway (CT 951 `net1`) | `10.98.0.2/24` |
| DHCP pool | `10.98.0.100` – `10.98.0.199`, short leases |
| Services on `eth1` | proxy `3128`, DNS `53`, `:80` origin, `search.retronet` |
| **Not** on `eth1` | OSCAR `5190` — that is the station-to-station relay |
| No transit | `net.ipv4.ip_forward=0` in CT 951 **and** an nft `FORWARD` drop between `eth0`/`eth1` |
| No clone↔clone | `bridge link set dev <tap> isolated on` on every walk-in tap; the gateway port stays un-isolated |
| Guard chain | `WI<STATION>-IN`, fail-closed, modelled on `WIN311RN-IN` |

`streamhost/stations/win311/rn-tapnet.sh` (landed 2026-08-25) is the reference
implementation to model a `wi-tapnet.sh` on. Each station gets its **own**
script — no shared fragment, no generalising a sibling's.

## 7. SPA contract

| Path | Lane | Shows |
|---|---|---|
| `/walkin` | 4 | Landing: three cards + pool status, or the closed notice |
| `/walkin/play/<os>` | 4 | The station view for the visitor's own clone |
| `/walkin/exhibits` | 4 | The listed fleet's notes + heroes, marked not playable |
| `/admin` → walk-in panel | 5 | Three-position switch, live session count, accounts, purge |

Closed-state copy: **"Walk-in access is currently closed."**

**Shared types.** Lane 4 creates `spa/src/data/walkinTypes.ts` in its first
commit, verbatim from this block. Lane 5 imports it and never edits it. It is
not scaffolded into the ledger commit because an export nothing imports yet
fails `npx knip`.

```ts
export type WalkinAccess = 'closed' | 'invited' | 'open';
export type WalkinPool = { os: string; free: number; size: number };
export type WalkinState = { access: WalkinAccess; pools: WalkinPool[]; notice?: string };
export type WalkinClaim = { clone: string; signalEndpoint: string; ttlSeconds: number };
export type WalkinQueued = { queued: true; position: number };
export type WalkinAdminStatus = {
  access: WalkinAccess; envFloor: WalkinAccess;
  sessions: number; pools: WalkinPool[]; accounts: number;
};
```

## 8. Production pre-flight (lane 9)

The wave ends **deployed on the production URL at Invited only**, so enabling is
one click. Everything a switch position cannot change must be true first:

1. **Edge relay range verified live** — `udp 54080-54200` DNAT on the edge VPS
   actually covers slots 152–200. Verified against the edge, not read off a doc:
   slots 131–134 once shipped broken while looking perfectly healthy against a
   `54130` cap ([`../../PUBLIC-GALLERY.md`](../../PUBLIC-GALLERY.md)).
2. Serving plane deployed **and restarted** — new routes do not travel without it.
3. `auth-state.json` migrated in place on the live file (§4.1).
4. Service worker not serving a stale shell over the new routes (the SPA is an
   installable PWA).
5. `check-stream-tickets.py` recognises pool identities.
6. Darklaunch overlays re-armed after the SPA deploy.
