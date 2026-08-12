# De-bridging rollback — putting a converted station back on its kiosk

The nine converted MAME stations (dragon32, bbcmicro, armeval, zx81,
oricatmos, mpf2, kc854, zxspectrum, sinclairql) each kept everything their
bridge kiosk needed. Rollback is per station and takes three moves; nothing
was deleted, so no rebuild or re-bake is involved.

On labhost, for one `<station>`:

1. **Stop it.** `systemctl stop streamhost@<station>` — the BindsTo scope
   takes the host-native MAME with it.
2. **Put the kiosk files back.** In
   `/data/vms/streamhost/stations/<station>/`, rename
   `qemu-streamhost.sh.debridged-bak` → `qemu-streamhost.sh` and
   `overlay.qcow2.debridged-bak` → `overlay.qcow2` (the kiosk guest with its
   `golden` snapshot, untouched since cutover).
3. **Put the daemon back.** In
   `/usr/local/lib/streamhost/stations/<station>/`, point `current` at what
   `previous` names.

Then `systemctl start streamhost@<station>`.

The station's `station.env` is regenerated from the registry, so a full
rollback also wants the repo side reverted: `git revert` the station's
conversion commit (its `runtime.x11` block, fixture and keymap), then
`make station-registry-generate`, sync the row with
`scripts/dev/box-sync-push.sh registry/stations/<station>.json --apply`, and
re-emit. Until that happens the box copy is authoritative and the pre-push
gate will report the drift — which is the intended loud signal, not a fault.

**What is NOT reversible this way:** nothing yet. The kiosk overlays are
retained deliberately; delete a `*.debridged-bak` only when the operator has
accepted that station for good.

## atarist

Still a hatari bridge kiosk and NOT converted. Its apps live in a host
directory that hatari mounts as a GEMDOS drive
(`stations/atarist/app-build/gemdos`, 2.4 MB) — MAME has no equivalent, so a
faithful conversion first needs that tree turned into a real ST disk image
the `st` driver can mount. See the note in
[`DEBRIDGE-CONVERSION-BRIEF.md`](DEBRIDGE-CONVERSION-BRIEF.md).
