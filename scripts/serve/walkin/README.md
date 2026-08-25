# `scripts/serve/walkin` — the walk-in broker

The private-clone lifecycle behind `/walkin/state|claim|release|reset`
(contract ledger [§3](../../../docs/lab/walkin/CONTRACT-LEDGER.md)). Layout and
the reasoning are in each module's docstring; `__init__.py` is the map.

**The one rule to know before editing anything here:** an override may change
paths, ports, tap names and netdev options — and nothing else. `loadvm` matches
the device set the golden was captured against, and the binary is bound to that
same combination ([`OPERATING-RULES.md`](../../../docs/lab/OPERATING-RULES.md)
rule 6). `deviceset.py` enforces it on every spawn; `spec.py` refuses the shape
of a forbidden override before that. Neither is optional, and neither is a
formality: `derive.py` calls the check on its own output, so code added here
cannot route around it.

## Three things that will surprise you

1. **The broker never executes a station launcher — it reads one.**
   `qemu-streamhost.sh` hardcodes `D=/data/vms/streamhost/stations/<station>`
   and opens with an unconditional `kill "$(cat $D/qemu.pid)"`. Running it for a
   clone takes the LIVE station down (measured on `rhapsody` during this wave;
   it is also the incident [`clone-guard`](../../../docs/lab/clone-guard.md)
   exists for). `launcher.py` parses the text and `derive.py` rewrites the argv;
   neither module may ever gain a `subprocess` import, and a test enforces that.
2. **A clone's disk is a reflink COPY of the seed, not a backing overlay.** An
   internal `savevm` snapshot is per-image and does not inherit through a qcow2
   backing chain, so `-loadvm golden` against an overlay fails with *"Snapshot
   'golden' does not exist in one or more devices"*. `cp --reflink=always` keeps
   the snapshot table and costs milliseconds — but only **within one dataset**:
   on labhost `/data/gallery-guests` and `/data/vms` are separate ZFS datasets,
   so a seed referenced in place under `/data/gallery-guests` fails `EXDEV`. The
   seed must be staged inside `/data/vms`. `--auto` is deliberately not used: it
   would degrade to a silent 853 MB copy on every refill.
3. **The MAC is not per-clone, and that is why `poolSize` is 1.** `loadvm`
   restores the NIC address from saved device state, so `mac=` on the command
   line cannot override it (ledger §5.3).

## Tests

```
cd scripts && python3 -m unittest serve.walkin.test_walkin
```

The repo-wide `python3 -m unittest discover -s scripts -p 'test_*.py'` only
reaches top-level `scripts/test_*.py`, the same way `serve/auth` is run on its
own — so run the line above as well.

## Integration seams outside this package

Two, both one line, both deliberately left for the coordinator's integration
pass rather than taken from another lane's territory:

| Seam | What is needed |
|---|---|
| `scripts/serve/signal_route.py` | merge `broker.signal_entries()` into `load_tiles()` so `/signal/walkin-<os>-<n>.json` answers for a pool member the way it does for a station |
| `scripts/serve/auth/` (lane 2) | call `walkin.routes.dispatch(...)` after the role check, and `broker.set_access(...)` when the admin switch moves — which returns the number of sessions it disconnected |
