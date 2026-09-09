# Onboarding a station onto the retronet ICQ plane

**Status: ROUTINE.** This was a six-station coordinator contract in August 2026;
by 2026-09-03 the plane carried sixteen stations and the expensive parts had all
become mechanical. It is now a procedure, and most of it is one command.

The A–D difficulty tiers that older docs cite were that contract's planning
device and are retired: every station in them is live, each with its own
`ICQ-STATION-*.md` or `STATION-*.md` record, and `scripts/retronet/icq/roster.json`
is the single source for who holds which UIN.

Parent: [`RETRONET-BRIEF.md`](../RETRONET-BRIEF.md) §5. The server is
[`GATEWAY.md`](GATEWAY.md); the bot is [`BOT.md`](BOT.md); **which client this
guest's era can run, and how to drive it, is [`ICQ-CLIENTS.md`](ICQ-CLIENTS.md)**
— read that before anything else, because the client decides the shape of the
whole bring-up.

## The one command

```sh
scripts/retronet/rn-onboard.sh <id> \
  --address 10.99.0.N --mac <mac> --uin <uin> --client <key> [--static] [--apply]
```

From one allocation row it writes `streamhost/stations/<id>/rn-tapnet.sh` from
the single template, prints the launcher netdev lines, writes the registry
`retronet` block, creates the account server-side, appends the roster row with
`onboarded: false`, and scaffolds `docs/lab/retronet/STATION-<id>.md` with the
proof checklist. **Dry-run by default**; `--apply` writes.

It does three things you must not work around:

- **It refuses to commit a real MAC or a real address.** The allocated MAC goes
  to the BOX-side `/data/kernel-hive/registry/local.env` as `RN_<ID>_MAC` in a
  single append; git gets the scrubbed `02:00:00:00:00:<octet>`, which the
  launcher and `rn-tapnet.sh` read the real value over at boot. Every rendered
  byte is re-checked before it is written, so the refusal cannot be bypassed by
  a template edit.
- **It does not allocate.** Address, MAC and UIN come from `wave.sh alloc`,
  which holds the plane's uniqueness ledger. Passing your own is how two
  stations end up on one address.
- **It does not flip `onboarded`.** That word means "a frame shows this client
  signed in", and the fleet-wide cross-list is gated on it.

Everything it prints under "next" is genuinely not automatable: the NIC model is
a per-guest judgement, and the golden must then be **cold-baked** on the finished
device set.

## What "on the plane" means, and what it costs

The gating fact, proven on win98se and never contradicted since: **OSCAR cannot
traverse slirp**. So every ICQ station needs a bridged tap on `vmbr-rn` — and so
does the pre-OSCAR v4/v5 UDP door, which is reachable only from a bridged guest.
That is a **device-set change**, and a device set and a vmstate are one
combination: adding the NIC invalidates `loadvm` on the existing golden.

**Do the retronet NIC, the `restrict=on` slirp pointer NIC and the absolute
pointer in the FIRST golden bake.** The 2026-09-03 wave did them in three phases
and paid a full golden re-bake per station per phase — about two hours each,
entirely avoidably. The complete device set for a modern station is:

```
-netdev tap,id=rn0,ifname=<id>rn0,script=no,downscript=no \
-device rtl8139,netdev=rn0,mac="$RN_<ID>_MAC" \
-netdev user,id=n0,restrict=on,hostfwd=tcp:127.0.0.1:<port>-10.0.2.15:6000 \
-device <era-appropriate>,netdev=n0
```

Three things about it that each cost somebody an hour:

- **`restrict=on` is containment, not tidiness.** Without it slirp hands the
  guest a default route via 10.0.2.2 and the guest reaches whatever labhost's own
  stack can. `hostfwd` (host → guest) keeps working under it.
- **The tap's lease must win over slirp's.** On the guests measured so far it
  does on its own, because dhclient rewrites `resolv.conf` per lease and the
  tap's is the later one — but check it rather than assume it.
- **Two IDENTICAL NIC models make the guest's interface numbering a coin toss**
  that a `loadvm` cannot re-litigate. Use two different drivers, or accept that
  `eth0`/`eth1` may swap on you.

## The order of operations

1. **`wave.sh alloc <id> --retronet`** — address, MAC, tap, chain, UIN, and the
   `RETRONET_DHCP_RESERVATIONS` pair, all in one atomic claim.
2. **Render the DHCP ledger.** A reservation edited into `local.env` is **not
   live** until `scripts/retronet/web/install-dhcp.sh` re-writes
   `/etc/retronet/dhcp.env` in CT 951. The first guest of the 2026-09-03 wave
   leased a pool address on exactly this gap — and a pool address also escapes an
   IP-scoped guard chain, which is why the template hooks the chain on the MAC
   too.
   **Reserve even for a guest that has no DHCP client** (`--static`): the
   reservation hands such a guest nothing, and exists purely as the plane's
   uniqueness ledger.
3. **`rn-onboard.sh <id> … --apply`**, then add the printed netdev lines to the
   launcher.
4. **Install and configure the client** — [`ICQ-CLIENTS.md`](ICQ-CLIENTS.md).
5. **Cold-bake the golden** on the finished device set, with the client signed
   in and HiveBot listed, and restore-prove it on a fresh emulator process under
   the production launcher args.
6. **Prove it survives a restore** — the step below.
7. **Land it**: `rn-verify.sh <id>`, flip `onboarded`, and the coordinator's
   single fleet-wide `seed_contacts.py ssi --apply`.

## The proof that decides whether the exhibit works

Every visitor arrives through `loadvm golden`. A restored vmstate carries a TCP
socket the gateway forgot hours ago, so **"signed in when we baked it" is not
"signed in when a visitor looks at it"** — and the client's own window will tell
you it is, wrongly: after a reset, `suse64`'s GtkICQ showed its list **Online**
while CT 951 rejected every packet from it as `unknown session, NOT_CONNECTED`.

The proof is a **new** gateway journal line dated after the reset, **and** a
frame:

```sh
ssh lab 'labctl reset <id>'
python3 scripts/dev/fb-wait.py --settle …          # awake, then ~90 s for the redial
ssh lab '/data/kernel-hive/scripts/retronet/rn-verify.sh --since "@<reset epoch>" <id>'
ssh lab 'labctl shot <id>'
```

Measured outcomes so far are in [`ICQ-CLIENTS.md`](ICQ-CLIENTS.md)'s reconnect
column. A client that fails this does not land until it has one of: its own
auto-reconnect, a plugin that turns it on, or a guest-side restart wrapper.

## HiveBot appears by NAME, not a number

The greeter is UIN `10000`, and what a client shows for it comes from the
server's ICQ directory nickname (`rn-tool.py nick 10000 HiveBot`), fetched on
add-by-UIN — so every station onboarded since that was set shows the name
natively. An SSI-aware client gets HiveBot from the server-side roster on its
first login with nothing added by hand; a v4/v5 client is not SSI-aware and its
contact list is a guest-side file that a seeder run cannot reach.
`roster.json` is the single source for both halves — adding a station is ONE
row, which `rn-onboard.sh` writes.

## Guardrails

- Own worktree (`wt.sh new`); land through `station-land.sh`, which serialises
  the landing window so no coordinator has to.
- **Commit a station's `rn-tapnet.sh` only with a proven station** — the
  box-sync pairs glob deploys every committed one.
- Prove containment from inside the guest exactly as the station doc template
  lists it. Host `ping` toward the guest is not a check: containment means
  labhost-initiated traffic is precisely what IS allowed.
- Green-before-done for the languages you touch, or report **BLOCKED**.
