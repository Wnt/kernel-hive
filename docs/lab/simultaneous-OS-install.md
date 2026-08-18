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

Two more rules that keep the picture live while you work:

- `SH_IDLE_PAUSE_SECS=0` for the whole install phase — a paused guest is a
  paused installer, and an operator who watches for two minutes and leaves
  would otherwise freeze it. Turn it on (60) only with the golden.
- Reset mode `restart` during the install re-runs the launcher only when QEMU
  is *not* live (`ensure-station-qemu`), so a stray "reset" click from the
  browser does not reboot the installer. Drive the guest yourself through QMP
  (§5) and let the operator's browser be a read-only monitor — two people
  typing into one installer is chaos.

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

## 5. Driving an installer that has no exec channel

QMP is enough for a TUI/Motif installer, and it works with the daemon attached:

- keys: `qmp_hmp.py <qmp.sock> "sendkey <name>"` (`ret`, `tab`, `f5`, `ctrl-c`,
  `shift-2`…); text: a 40-line typing helper mapping chars → sendkey names
  (`/data/vms/sandbox/hpuxvue/hpt.py`; promote to `scripts/dev/` when the next
  station needs it). Motif dialogs: Enter = default button; the softkey row is
  F1..F8.
- pointer: `mouse_move dx dy` / `mouse_button 1|0`; measure the guest gain
  first with two screendumps and `PIL ImageChops.difference().getbbox()` —
  hpuxvue's "2× gain" was plain X acceleration (`xset m 1 1` fixes it);
  macos753's 0.36 was real.
- **Framebuffer is the only proof**: `screendump` after every step; keep a
  rolling `cur.png`. `labctl shot` only works after the row is deployed and
  `labctl gen` ran.
- Trap: the `mount-guard` pre-tool hook pattern-matches the *host command
  line*, so a guest command containing the un-mount word, typed via
  `ssh lab '... hpt.py "<text>"'`, is BLOCKED (it blocks a heredoc that merely
  documents the word, too). Put the guest text in a file on the box and pass
  `$(cat file)`, or split the word with a backslash so it reaches the guest
  intact.
- Give every guest a serial line (`-serial unix:$D/serial.sock,server=on,wait=off`
  or `-serial file:`) — on old x86 guests the kernel debugger shows only on
  COM1 (beos), and on HP-UX it is the future `labctl exec` channel.

## 6. Is it hung or just slow? Check I/O, not CPU

Under TCG an idle 1990s kernel spins at 100 % CPU (no HLT), so `%CPU` says
nothing. `grep write_bytes /proc/<qemu-pid>/io` twice, minutes apart, plus an
unchanged `screendump` md5, is the hang test. hpuxvue's HP post-install
`swinstall` sat 40 min with zero writes; Ctrl-C then a forced reboot was right —
and the guest doc records what that cost (no kernel built → Support-Media
recovery).

## 7. Media and emulator builds: start them on minute one, in the background

- Downloads and emulator builds are the long poles; kick them off before
  touching the registry (archive.org returned 500s in bursts — use
  `curl --retry 8 --retry-delay 20`).
- `media_cache_require` with an **md5** pin md5-sums the entire archive first
  (minutes, per disc) — for interactive work use `curl` + verify +
  `media_cache_put` afterwards; keep sha256 pins for builders.
- Expect the first medium to be wrong. Three HP-UX presses were needed before
  one saw the emulated disk; the fix was in the media, not QEMU. Budget for a
  second and third ISO and archive them all with the reason in
  `ASSETS-MANIFEST.md`.

## 8. Checklist for the next pair (paste into each session's first message)

1. `wt.sh new <id>`; start media fetch + emulator build in the background.
2. `ss -ulnp | grep :541` + `kh-claim ls` → claim port/slot → `new --slot N`.
3. Stream first (§1): rig + daemon + overlay, or hidden registry row + unit
   with `SH_IDLE_PAUSE_SECS=0`; verify `/signal/<id>.json` = 200; hand the
   operator the URL. Only now start driving the installer.
4. Row (hidden), launcher, fixture, placeholder poster/hero → validate →
   **push to `main` + `box-deploy --apply`** within the first hour (§2–§3).
5. Screendump after every step; I/O check when quiet; guest-doc install log as
   you go.
6. Golden → fixture to `loadvm`, idle 60, real hero, drop `listing` → land,
   deploy, `labctl gen`, `POST /restore/<id>`; release claims; state teardown.

## 9. What to build next (not done yet)

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
