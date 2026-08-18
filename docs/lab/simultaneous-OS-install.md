# Running two OS integrations at once

What the beos + hpuxvue pair (2026-08-17/18, two Claude sessions on one box)
taught, written so the next pair starts where this one ended. The operator's
one hard requirement: **the installation must be watchable as a live video
stream in the gallery UI from the first boot** — not screenshots in chat.

## 1. Publish the stream before you debug anything

The first thing a bring-up session does after its guest shows *any* frame:

1. run the guest with `-display dbus,p2p=on` (dbus capture, no other display)
   and a QMP socket in the sandbox rig dir;
2. run a streamhost daemon by hand from a `stream.env` in that dir — borrow
   a released binary (`readlink -f /usr/local/lib/streamhost/stations/<any>/current`)
   and `set -a; . stream.env; . /etc/osgallery/stream-ticket.env; set +a`
   so the browser's ticket path works exactly as in production;
3. publish `/os/<id>` with `scripts/dev/darklaunch-station.py publish <id>
   --rig <dir> --entry <entry.json>` (`listed:false`, declared in
   `serve/darklaunch.d/<id>.json` so the sync gate stays green);
4. **restart the daemon every time you relaunch the guest** — a hand-run
   daemon keeps encoding the last frame after `qemu.pid` vanishes and the
   operator sees a frozen picture. Put the restart in the rig's launch helper.

Say the URL to the operator the moment it streams. Then debug.

Registry-row dark launch (`listing.state=hidden`, a real
`streamhost@<id>` unit — the tru64/hpuxvue route) is the better shape once
the guest boots reliably; the overlay is for the hours before that. Either way
the operator watches at `/os/<id>`.

## 2. Claim everything you share, before you use it

Two sessions collide on exactly the things AGENTS.md lists. This pair hit:

- **UDP port / slot**: `stations-registry.py new <id> --slot auto` reserves the
  slot in *your* worktree only; the other session's `--slot auto` gives the
  same number until one of you lands. Claim it on the box the moment you
  scaffold: `kh-claim take udp 54<slot> --purpose <id>-bringup`. hpuxvue had
  to move from 54143 to 54144 because the beos rig already listened there.
- **hostfwd / ssh ports** for helper VMs: pick with a bind-0 probe and
  `kh-claim take port <n>`; release in teardown.
- **Rig streamhost binaries**: borrow, never rebuild or promote.
- **Runtime documents**: `serve-https-spa.sh manifests|deploy` republishes
  `tiles.json` / `gallery-manifest.json` / `golden-manifest.json` from ONE
  checkout. An overlay is wiped (re-`publish`); another session's *registry
  row* that is not on main yet is dropped (they must republish from their
  sandbox). Before any republish: `ls serve/darklaunch.d/` and ask on the
  operator's screen / SendMessage who else has an unlanded row.
- **The box checkout** (`/data/kernel-hive`) is `main`: `box-deploy.sh --apply`
  by either session deploys whatever main is; it refuses files under an
  active darklaunch declaration (good) but knows nothing about a row that is
  only in a sandbox. Land early, land often.

## 3. Land without stepping on each other

- Merge `origin/main` before every push; both sessions add rows with
  `bindingOrder`/`bringUpOrder`/`signalOrder`/… = max+1, so the second one to
  land renumbers (validate tells you exactly which). Same for the
  hand-maintained SPA lists (`assembliesByTile.ts`, `machineIdentity.ts`) —
  append at the end, in lineup order.
- `make station-registry-check` compares against the box's LIVE labctl roster:
  it is red for you while the other session's station dir exists on the box
  and its row is not in your tree, and red for them until your dir exists.
  Merge main + `labctl gen` on the box; do not "fix" the check.
- Generated files conflict on every merge (`stations-manifest.sh`,
  `build-all.sh`, `archetypeRegistry.ts`, `posterIndex.ts`): take either side
  and `make station-registry-generate`; never hand-merge them.
- `git stash -u` + merge + pop conflicts on generated files too — same cure.

## 4. Talk

`ListAgents` → `SendMessage` to the other bring-up session works and is
cheap; the operator also offered their screen session as a relay. Say what
port/slot you hold, when you will republish manifests, and when you land.

## 5. What to build next (not done yet)

- `scripts/dev/bringup-rig.sh <id> --qemu-args …` : one command that claims
  the UDP port, starts the guest with the dbus display, starts the borrowed
  daemon, publishes the overlay, and restarts the daemon on every relaunch —
  steps 1–4 of §1 are identical for every station and were typed by hand
  twice today.
- `darklaunch-station.py` could take the entry fields from the sandbox
  registry row (`stations-registry.py emit gallery-manifest.json` for a
  candidate row) instead of a hand-written JSON.
- A `kh-claim take udp` convention in `stations-registry.py new` (print the
  claim command it expects you to run on the box).

Related: [`docs/lab/ADD-NEW-OS-PLAYBOOK.md`](ADD-NEW-OS-PLAYBOOK.md),
[`docs/guests/beos.md`](../guests/beos.md), [`docs/guests/hpuxvue.md`](../guests/hpuxvue.md).
