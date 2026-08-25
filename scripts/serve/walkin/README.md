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
