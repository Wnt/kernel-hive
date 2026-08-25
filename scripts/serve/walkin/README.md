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
4. **A clone is ARP-primed before it is claimable.** Not renumbering the plane
   costs one thing: the golden carries a warm ARP cache from its retronet
   capture, so it believes `10.99.0.2` lives at CT 951's MAC, which is not on
   `vmbr-wi`. Its first outbound flow is 100% lost until the real gateway ARPs
   it. `clone.prime_network()` runs the plane's helper while the member is still
   paused, so the visitor never waits for it. The helper is named by
   `WALKIN_ARP_PRIME` (a command template taking `{ip}`, `{tap}`, `{identity}`);
   the clone's address is read from the station's own `wi-tapnet.sh`, which is
   where it is asserted, rather than restated in the broker.

   Two halves of this are load-bearing and were each wrong once:
   the guest must be **running** to hear the ARP (a `-S` pool member processes
   no frames, so priming resumes it under a wake lease and restores the pause),
   and the gateway's **neighbour entry must be deleted first**. Because every
   clone of a station carries its golden's MAC, a respawn moves that MAC to a
   new bridge port; CT 952's stale entry keeps unicasting to the port that went
   away, so without the delete the first clone primes and every clone after a
   reset does not. Measured, both times, at the framebuffer.

## Tests

```
cd scripts && python3 -m unittest serve.walkin.test_walkin serve.walkin.test_broker
```

`test_walkin.py` is the derivation half — schema, launcher parsing, the
device-set refusal. `test_broker.py` is the pool half. Both include a test that
every landed `registry/walkin/*.json` parses, which is the check that catches a
station file declaring a schema key the broker has not met yet.

The repo-wide `python3 -m unittest discover -s scripts -p 'test_*.py'` only
reaches top-level `scripts/test_*.py`, the same way `serve/auth` is run on its
own — so run the line above as well.

## Integration seams outside this package

Two, both one line, both deliberately left for the coordinator's integration
pass rather than taken from another lane's territory:

| Seam | What is needed |
|---|---|
| `scripts/serve/signal_route.py` | merge `broker.signal_entries()` into `load_tiles()` so `/signal/walkin-<os>-<n>.json` answers for a pool member the way it does for a station |
| `scripts/serve/signal_route.py` (reaped clone) | answer `/signal/<clone>.json` with `broker.session_end_for_clone(...)` (410) instead of a bare 404, so a reconnect learns why rather than reading "connection lost" |
| `streamhost/` transport | the §3.3 message as the WebTransport **close reason**. Not this lane's territory and not written: lane 4 already accepts the code by any road, and `/walkin/state` is the road that works today |
| `scripts/serve/auth/` (lane 2) | call `walkin.routes.dispatch(...)` after the role check, and `broker.set_access(...)` when the admin switch moves — which returns the number of sessions it disconnected |
