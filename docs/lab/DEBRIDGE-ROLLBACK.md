# De-bridging rollback — putting a converted station back on its kiosk

The nine converted MAME stations (dragon32, bbcmicro, armeval, zx81,
oricatmos, mpf2, kc854, zxspectrum, sinclairql) and the first converted VICE
station (vic20) each kept everything their bridge kiosk needed. Rollback is per
station and takes three moves; nothing was deleted, so no rebuild or re-bake is
involved. **The VICE stations roll back exactly the same way** — the engine
differs, the shelved files and the daemon pool do not.

On labhost, for one `<station>`:

1. **Stop it.** `systemctl stop streamhost@<station>` — the BindsTo scope
   takes the host-native emulator (MAME, or VICE on vic20) with it.
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

## nextstep — same three moves, one extra step, and one thing that is gone

Converted 2026-08-25 and it keeps the same two shelved files
(`qemu-streamhost.sh.debridged-bak`, `overlay.qcow2.debridged-bak`), so steps 1
and 2 above are identical. Two differences:

- **Step 3 does not apply.** No daemon canary was needed: `nextstep` already ran
  the same artifact `irix` and the de-bridged MAME stations do, and `previous`
  in its pool still names what it named before the conversion. Leave both
  symlinks alone.
- **Tear the retronet link down.** `bash
  /data/vms/streamhost/stations/nextstep/rn-tapnet.sh down` removes the veth
  pair, the private netns and the `NEXTSTEPRN-IN` guard chain. The kiosk had no
  network of its own and will not clean this up.

What rolling back gives up, stated plainly: the kiosk is a MONO NeXTcube with no
network and no browser, and its reset is `loadvm golden` on a snapshot from
2026-08-11. The colour machine, the retronet join, OmniWeb and the 3 s CRIU
reset all belong to the host-native shape. The repo side is a `git revert` of
the conversion commit as above, plus `stream.pointer.method` going back to
`qemu-usb-tablet`.

The host-native assets under `/data/vms/streamhost/assets/nextstep` (the
emulator binary, the ROM, the cold-boot disk and the CRIU golden, 252 MB with
the disk reflinked) can stay: nothing reads them once the unit is on the kiosk
launcher, and re-converting without them means a fresh install.

## atarist

Still a hatari bridge kiosk and NOT converted. Its apps live in a host
directory that hatari mounts as a GEMDOS drive
(`stations/atarist/app-build/gemdos`, 2.4 MB) — MAME has no equivalent, so a
faithful conversion first needs that tree turned into a real ST disk image
the `st` driver can mount. See the note in
[`DEBRIDGE-CONVERSION-BRIEF.md`](DEBRIDGE-CONVERSION-BRIEF.md).
