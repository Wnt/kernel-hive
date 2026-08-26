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
| 6 | **network plane** | `scripts/retronet/walkin-net/**`, box-side CT 952 | §6 |
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

### 3.1 Broker interface

Lane 2 calls lane 1 across this surface. Duck-typed, and frozen here so the two
lanes cannot pick different names:

```python
live_sessions() -> int
pools() -> list[dict]          # [{"os": str, "free": int, "size": int}]
close_sessions(reason: str) -> int
kill_all_clones() -> None
refill() -> None
set_drain(value: bool) -> None
```

Lane 2 binds it with `AUTH.walkin.bind_broker(...)`. A missing broker is
tolerated and logged — the lanes land on their own schedules.

### 3.2 Signup is two round trips

WebAuthn registration cannot be one request. `/walkin/signup` routes on the body
— attestation present means finish, absent means begin — so the frozen route
holds, with explicit `/walkin/signup/begin` and `/walkin/signup/finish` beside it.

```
POST /walkin/signup  {}                          -> {"ceremonyId": …, "publicKey": …}
POST /walkin/signup  {ceremonyId, credential}    -> {"handle": …, "role": "walkin"}  + session cookie
```

The handle offered to the authenticator during *begin* is a **candidate**. The
authoritative allocation happens under the store lock at *finish*, so two
simultaneous signups cannot both become `bold-turing`.

### 3.3 Reason codes

| Code | Meaning | Who emits |
|---|---|---|
| `WALKIN_CLOSED` | Access dropped to Closed under a live session | broker → client |
| `WALKIN_TTL` | Session hit its TTL | broker |
| `WALKIN_IDLE` | No input for the idle window | broker |
| `walkin_closed` | HTTP body error on a refused claim/signup | auth |

`WALKIN_CLOSED` sits beside the existing `SESSION_REJECTED`; the SPA renders
distinct copy per code (§7).

**How a reason code reaches the client.** The broker sends it on the signaling
channel as the session ends, and also as the transport close reason:

```json
{"type": "session-end", "reason": "WALKIN_CLOSED"}
```

The SPA prefers the broker's code over anything it inferred itself, so a visitor
is never told "connection lost" when the honest answer is the clock.

**Ticket revocation is gateway-side only.** A ticket already in a browser stays
cryptographically valid until its ≤300 s expiry — streamhost's verifier is not
ours. What actually ends a session is killing the clone, step 4 of the teardown.

**`/usage/stations.json` is denied to walk-ins** (it enumerates per-station
activity); `/usage` and `/clientlog` are allowed.

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
| Cell bridge | `wibr<slot>` — the clone's own L2 domain (§5.4, §6) | `wibr152` |
| Cell netns | `wicell<slot>` — the cell's NAT namespace | `wicell152` |
| Cell peer | `10.99.0.<slot-100>` — what the gateway sees (§6) | slot 152 → `10.99.0.52` |
| Clone MAC | **not settable** — see §5.4 | — |

Slots, taps and IPs are claimed with `kh-claim` under `$KH_SESSION`. Never
check-then-create ([`../OPERATING-RULES.md`](../OPERATING-RULES.md) rule 7).

### 5.2 `registry/walkin/<station>.json`

Adding an OS to the pool is **data, not code**. The broker reads this; the
enablement lanes write it. Unknown keys are an error, not a silent ignore.

```json
{
  "station": "os2warp",
  "enabled": true,
  "poolSize": 3,
  "seed":       { "disk": "…/os2warp-golden.qcow2", "readOnly": true },
  "//seed":     "or `disks: [ … ]` — win311 restores two goldens together",
  "overlay":    { "format": "qcow2", "discardOnKill": true },
  "launcher":   "streamhost/stations/os2warp/qemu-streamhost.sh",
  "binary":     "/opt/qemu-rhapsody/bin/qemu-system-i386",
  "overrides":  {
    "netdev": { "type": "tap", "bridge": "vmbr-wi", "ifnamePattern": "wi-os2warp-%d" },
    "tapnet": "streamhost/stations/os2warp/wi-tapnet.sh",
    "chardev": { "ser0": "<clone>/serial.sock" }
  },
  "invariants": ["-bios …/bios-256k-int16if.bin", "-device ne2k_pci,netdev=n0"],
  "sandbox": true
}
```

**The seed copy is a reflink, not a backing chain.** An internal `savevm`
snapshot is per-image and does **not** inherit through a qcow2 backing file, so
`-loadvm golden` against a backing-chain overlay cannot work — measured by lane 7.
What does work, and what the broker must do: `cp --reflink=always` of the golden
(853 MB in **27 ms**, 1 K of new space, internal `golden` snapshot preserved).
The reflink must stay **within one dataset** — cross-dataset fails `EXDEV` — so
the seed is staged inside `data/vms`, not referenced in place under
`/data/gallery-guests`. Read `overlay.format: "qcow2"` as *a reflinked qcow2*,
discarded on kill.

Three keys are optional and station-shaped:

- **`seed.disks[]`** instead of `seed.disk`, for a station whose golden spans
  more than one image — win311 restores `win311-golden` and `games-golden`
  together, and one `disk` cannot say that.
- **`overrides.chardev`** re-roots a chardev's **backend path** per clone (the
  COM1 socket the in-guest warpd agents speak over). The device comes from the
  machine type; only the backend moves, so the device set is untouched.
- **`invariants[]`** — literal argv fragments the derived command line must
  still contain. The broker **asserts** them rather than trusting review, which
  is how a station declares the thing that must survive derivation: win311's
  patched `-bios` is the case in point, since a clone that loses it wedges after
  ~61 key edges instead of surviving hundreds.

`binary` is optional and pins the emulator a station's golden was captured
against (rhapsody's fork). Declared so it is machine-checkable rather than
implicit in a shell file, and so a substitution fails loudly instead of falling
back to stock pve-qemu.

**`overrides` may change paths, ports, tap names and netdev *options* only.**
It may not add, remove or retype a device: `loadvm` matches the device set the
golden was captured against, and the binary is bound to that same combination
([`../OPERATING-RULES.md`](../OPERATING-RULES.md) rule 6). `sandbox: true` adds
`-sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny`
where the binary is QEMU.

### 5.3 A station launcher must never be invoked as-is

**A naive `launcher` invocation kills the live station.** Measured by lane 8:
`streamhost/stations/rhapsody/qemu-streamhost.sh` hardcodes
`D=/data/vms/streamhost/stations/rhapsody`, its own `ifname`, its own
`rn-tapnet.sh` call — and **unconditionally kills `$D/qemu.pid`**. A broker that
runs it for a clone attaches to the live station directory and takes down the
live QEMU. The other stations' launchers share the shape.

So the broker **derives** a clone command line; it does not execute a station
launcher. Until a launcher is env-overridable for `D`, tap name and tapnet
script, the broker must refuse to spawn from it rather than try. Fail loudly —
"it exists" is not "it is safe to run" ([`../OPERATING-RULES.md`](../OPERATING-RULES.md)
rule 7's spirit, and rule 4: never experiment on a live station).

### 5.4 A pool of identical machines, and the cell that carries it

`loadvm` restores the NIC's MAC from saved device state, so **every clone of one
station carries the same MAC** — `mac=` on the command line cannot override it,
and the device set may not be changed to work around it (rule 6). Each golden
also has a **baked network identity** — the address and lease it held when it
was captured on `vmbr-rn` — and these guests do not re-DHCP inside a session.
So every clone of one station is identical on the wire: same MAC, same IP.
Measured on a stand-in plane: two clones on one bridge, and the FDB entry for
the shared MAC moved to whichever transmitted last.

This section used to conclude `poolSize: 1` from that. The conclusion is
replaced; the facts stand, and the design leans on them:

- **Identical machines never share a bridge.** Each clone's tap joins its own
  L2 cell — bridge `wibr<slot>` — so one FDB never sees two claimants. The
  guest is untouched: it restores, believes it is `10.99.0.19`, and inside its
  cell it is right.
- **A NAT namespace joins each cell to `vmbr-wi`** (`wicell<slot>`, helper
  `wi-clonecell`, §6). On the way out the guest's baked source address is
  SNATed to a unique per-slot peer (`10.99.0.<slot-100>`), so the gateway sees
  three distinct hosts where three guests each see themselves as the one
  captured machine. CT 952 is not modified at all — no alias, no route, no
  config: it simply serves three more peers on its own `/24`.
- **The MAC is still not rewritten anywhere.** Not on the command line (the
  vmstate would disagree, §5.2's derivation asserts it), and not in the saved
  state — vmstate surgery couples the pool to QEMU's snapshot format and was
  rejected outright; worse, it would not even work, because these guests'
  drivers composed their frames' source MAC into guest RAM at capture time.
  The wire identity is accepted as a fact of the golden and contained by
  topology instead.

`poolSize` is therefore a real knob, **3 per station** as shipped (schema cap
8). The remaining ceiling is honest and bounded: CPU (three resumed TCG guests
per station), the 49-slot claim range, and the visitor-facing
`ACTIVE_SESSION_CAP` — not the network. Growing a pool still never needs a
per-station walk-in golden, and no golden was recaptured for any of this.

### 5.5 The pool's lock is never held over a clone's life

`pools()`, `state()`, `own_of()`, `live_sessions()` and `signal_entries()` all
take the broker's one lock, and a visitor's landing page polls `/walkin/state`
every 15 s. So **nothing that takes minutes may hold that lock** — and both ends
of a pool member's life do:

| work | measured |
|---|---|
| build one clone (TCG restore of the golden) | ~10 s warm cache, up to ~2 min 10 s cold |
| destroy one (`clone-guard` kill, tap down, cell down, `rm -rf`) | seconds |

At `poolSize` 1 the whole warm was one member and it hid. At 3 it is nine, and
`refill()` built all nine serially under the lock: `/walkin/state` timed out for
the length of the warm, after every restart and after every reap, so the landing
page said "Checking what is free…" and never stopped. Same lesson as the two
startup-thread fixes above it, one layer in.

The shape, in `scripts/serve/walkin/warm.py`:

```
reserve (locked)  ->  build (unlocked)    ->  publish (locked)
retire  (locked)  ->  destroy (unlocked)
```

What the lock still protects is what it is for. **Two builds must never pick the
same pool index** — the index names the tap (§5.1) and interface names are
box-wide — so the index is RESERVED under the lock before the build starts, and
a reservation counts toward the pool's size exactly as a member does.
`_build_lock`, which no read path touches, keeps builds one at a time.
`kh-claim` arbitrates between SESSIONS; the broker is one session, so within it
the reservation is the arbitration.

Two consequences the reapers must respect: a reservation holds a slot claim
before its directory exists, and a retiring clone keeps its tap, cell and
directory until `destroy` returns. Both now run alongside a tick, so
`_known_identities()` — members **plus** reservations **plus** retirements — is
what the sweeps are told, not `_members`.

## 6. The walk-in network plane

**A separate gateway, not a second leg on the live one.** CT 951 serves five
ICQ stations and the corpus web; giving it a second interface put the live
retronet at risk for no gain, and it could not hold the numbering below anyway
(one container cannot carry `10.99.0.2/24` twice).

| Value | Frozen |
|---|---|
| Bridge | `vmbr-wi`, `bridge-ports none`, **no address on labhost** — the host is not even reachable on this segment |
| Gateway | **CT 952 `walkin-gw`**, single-homed on `vmbr-wi`, from CT 951's own reproducible provisioner |
| Numbering | `10.99.0.0/24`, gateway `10.99.0.2/24` — deliberately the same as retronet, on a different L2 with no route between them, so each clone's baked identity is correct (§5.4) |
| Addressing | **No DHCP.** Each clone keeps the address its golden was captured with — every clone of a station holds the SAME one, which is why cells exist |
| Cells | one per clone: bridge `wibr<slot>` + NAT netns `wicell<slot>` (`wi-clonecell`), joining `vmbr-wi` as peer `10.99.0.<slot-100>` — **.52–.100 reserved** for cell peers |
| Corpus | the existing corpus mounted **read-only** |
| Services | proxy `3128`, DNS `53`, `:80` origin, `search.retronet` |
| **Not** served | OSCAR `5190` — that is the station-to-station relay |
| No transit | CT 952 has one leg and no route to `vmbr-rn`, labhost or the internet. Nothing to forward |
| No clone↔clone | separate L2 cells per clone; each cell's outer veth is `isolated on` on `vmbr-wi` (the gateway port stays un-isolated); each cell's namespace FORWARDs to `10.99.0.2` only, fail-closed |
| Guard chain | `WI<STATION>-IN`, fail-closed, modelled on `WIN311RN-IN` |

The live retronet gateway CT 951 is **not modified at all**.

**Prime the ARP cache after the tap comes up.** Not renumbering has one cost,
measured by lane 8 on the real plane: a golden carries a **warm ARP cache from
its retronet capture**, so `10.99.0.2` resolves to CT 951's MAC — which exists
on no walk-in segment. The clone's *first* outbound flow fails until it hears
the gateway's ARP, which repairs the entry permanently. Inside a cell the
gateway's own ARP cannot reach the guest (the NAT namespace terminates L2), so
**the cell speaks first**: `wi-clonecell prime` broadcasts the gateway's ARP
from the cell's inner leg, takes the guest's ARP reply as proof the repair
landed, and pins the guest's MAC in the namespace in the same motion. The
plane provides the helper; the broker calls it, with the guest resumed under a
wake lease. This hits every station, not one. (`wi-warm-arp`, the flat-plane
ancestor that had CT 952 ping the clone, remains for the plane's own tooling.)

`streamhost/stations/win311/rn-tapnet.sh` (landed 2026-08-25) is the reference
implementation to model a `wi-tapnet.sh` on. Each station gets its **own**
script — no shared fragment, no generalising a sibling's.

## 7. SPA contract

| Path | Lane | Shows |
|---|---|---|
| `/walkin` | 4 | Landing: three cards + pool status, or the closed notice |
| `/walkin/play/<os>` | 4 | The station view for the visitor's own clone |
| `/walkin/exhibits` | 4 | The listed fleet's notes + heroes, marked not playable |
| `/admin/walkin` | 5 | Three-position switch, live session count, accounts, purge |

Closed-state copy: **"Walk-in access is currently closed."**

**`/admin` is not available.** `config.py`'s `AUTH_PAGES` maps the literal path
`/admin` to the static `admin.html` (people + passkeys) before the SPA loads.
The lookup is exact (`AUTH_PAGES.get(path)`), so the walk-in panel lives at
**`/admin/walkin`**, which falls through to the SPA untouched. Do not repoint
`AUTH_PAGES` — the static admin page is a working surface.

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

## 7.1 Two things a visitor can trip

**The reset button races the idle-pauser.** Measured by lane 7: a `reset` on a
station whose daemon has just idle-paused it fails with
`Could not load snapshot 'golden' … Invalid argument`. Not damage, and not the
emulator — it is the race `scripts/lib/guest_wake.py` exists for. Redone inside
a `WakeLease` it succeeded first try. The broker's reset path **must hold the
wake lease** (or retry), or a stranger is told "reset failed" on a perfectly
healthy station.

**A seed can show a stranger a lab failure.** The `os2warp` golden boots with
its ICQ client already running, which on this plane immediately raises
*"ICQ server not accepting your login"* — correct behaviour (CT 952 withholds
OSCAR) but a broken-looking first frame. The same image carries the station's
retronet ICQ identity, which the brief's own per-seed checklist says must not
be in a walk-in seed. Open decision, recorded in
[`../WALKIN-BRIEF.md`](../WALKIN-BRIEF.md) §3.

**A warm pool member must stay PAUSED, and a session must end on its TTL.**
Measured 2026-08-26 while proving the multi-clone plane, by running nine clones
RESUMED and unattended for hours — far outside the production envelope — and
watching them decay in station-specific ways:

- **win311 loses its baked DHCP lease.** The golden's lease is real and has a
  real expiry; hours into a resumed-idle soak, DHCP.386 drops to a full-screen
  blue "lost the lease" text prompt and the network is gone. A paused member's
  clock does not run, and a ≤30-minute session never gets there.
- **rhapsody decays faster and less predictably**: PS/2 input goes first
  (sometimes it never arms after the restore at all — the wedge is
  NONDETERMINISTIC, reproduced repeatedly under load with the same golden and
  binary, and entirely network-independent), the userspace follows, and the
  guest's IP stack can go quiet within tens of minutes. A clone that restores
  bad should be respawned, not debugged: the broker's respawn IS the fix, and
  `wi-clonecell prime`'s hard failure is the detector that catches the network
  half before a visitor does. The input half has no host-side detector yet —
  open item.

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
