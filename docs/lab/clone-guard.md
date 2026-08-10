# clone-guard — the hard safety guard for VM-clone tooling

**Source of truth:** `scripts/lib/clone-guard.sh` (repo) == `/usr/local/bin/clone-guard`
(box), kept **byte-identical** — re-scp + `chmod +x` after any edit (verify with
`md5sum`).

## The incident it prevents

A clone-setup task ran a **stale lab-side launcher** that had been copied from a
LIVE tile's `qemu-streamhost.sh`. That launcher opens with the production footgun:

```bash
D="${D:-/data/vms/streamhost/tiles/solaris}"          # parameter-DEFAULT
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")"   # unconditional kill preamble
```

The intended namespace override was passed as `D=…`. When it was **not actually
exported** into the launcher's environment, the `:-` default silently fell back
to the LIVE tile path and the next line **killed the running production
Solaris QEMU** — the tile was named `solariscde` then — (recovered from golden
in ~1 min, but a real breach). Root
cause: an override that fails *open* (falls back to a live tile) followed by an
**unguarded** `kill $(cat …/qemu.pid)`, with nothing asserting the target was a
clone.

## What the guard guarantees (fail-CLOSED)

Every clone kill / stop / destructive-QMP / launcher-run MUST route through the
guard. It refuses, **loudly (non-zero exit + message)**, to touch anything that
is not confined to `/data/vms/soltest/<namespace>/`:

- any path under the production tiles tree `/data/vms/streamhost/tiles/`;
- any `streamhost@<tile>` systemd unit (clones never run as a unit);
- any pidfile whose **path** is outside the clone root, **or** whose **PID** is a
  QEMU whose `/proc/<pid>/cmdline` references the tiles tree (belt-and-braces:
  catches a namespaced clone dir whose `qemu.pid` was mis-populated with the live
  PID);
- a clone launcher that statically embeds a live target — the
  `${VAR:-…/streamhost/tiles/…}` default, a live `-pidfile`/`-qmp`/disk/kill
  path, or a `systemctl stop streamhost@…`.

Kills are ONLY ever by the clone's own pidfile — never `pkill`-by-name.

## Use it

**CLI** (exits non-zero on refusal):

```bash
clone-guard assert-path    <path>       # path must be inside /data/vms/soltest/
clone-guard assert-unit    <unit|tile>  # refuse a streamhost@<tile> unit
clone-guard assert-qmp     <qmp.sock>   # sock must be inside the clone root
clone-guard assert-vmid    <vmid>       # refuse a production-range VMID (<900)
clone-guard check-launcher <file>       # static-lint a clone launcher before running it
clone-guard kill-pidfile   <pidfile>    # the GUARDED kill (path + /proc argv check)
```

**Sourced** (functions `clone_guard_*` RETURN non-zero on refusal — never kill on
refusal):

```bash
source /usr/local/bin/clone-guard
clone_guard_check_launcher "$LAUNCHER" || exit 1     # lint before launch
clone_guard_kill_pidfile   "$D/qemu.pid"             # instead of a raw kill
```

New per-clone launchers should:
1. hard-code `D=/data/vms/soltest/<namespace>` (never a `${D:-/live/tile}` default);
2. `source /usr/local/bin/clone-guard` and replace the
   `kill "$(cat "$D/qemu.pid")"` preamble with `clone_guard_kill_pidfile "$D/qemu.pid"`.

Override the roots only to point at a *different* sandbox:
`CLONE_GUARD_CLONE_ROOT` (default `/data/vms/soltest`),
`CLONE_GUARD_PROD_TILES_ROOT` (default `/data/vms/streamhost/tiles`).

## Where it's already wired

`scripts/coldboot/bootrec-lib.sh` (used by `record-boot.sh` and every
`*-record-driver.sh`) sources the guard and routes `br_kill_pidfile` through
`clone_guard_kill_pidfile`; destructive HMP verbs (`savevm`/`loadvm`/`delvm`/
`stop`/`quit`/`system_reset`/`system_powerdown`/`cont`) in `br_hmp` assert the
target socket is a clone socket first. If the guard file is somehow absent, an
**inline fail-closed fallback** in `br_kill_pidfile` enforces the same
path + `/proc` checks — the tooling is never *less* safe than the guard.
