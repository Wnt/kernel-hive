# Tiles without a dedicated guest doc (stub index)

Seven live tiles have no `docs/guests/<os>.md` of their own. Until someone writes
one, the authoritative references per tile are its build script under
`scripts/build-guests/` and its `emit <tile>` stanza in
`streamhost/tiles-manifest.sh` (flag ledger + stanza comments).

| Tile | Build script | Notes |
|---|---|---|
| `android` | `scripts/build-guests/android-x86.sh` | Android-x86 9; one-time SetupWizard coordinate calibration (see MASTER-REPRODUCE Phase 4 table) |
| `postmarketos` | `scripts/build-guests/postmarketos.sh` | UEFI/OVMF — writable `OVMF_VARS.qcow2` varstore (seeded by `tiles-manifest.sh` post-emit); unlock PIN 147147 |
| `serenityos` | `scripts/build-guests/serenityos.sh` | cold-boot tile (`labctl reset` refuses); per-boot writable overlay over the read-only golden `_disk_image` |
| `toaruos` | `scripts/build-guests/toaruos.sh` | cold-boot tile (`labctl reset` refuses); live ISO |
| `win2000` | `scripts/build-guests/win2000.sh` | boot-video clip flagged in the SPA (see `scripts/coldboot/`) |
| `win311` | `scripts/build-guests/win311.sh` | partial coverage exists in `docs/guests/win9x.md` (the Win 3.11 material); serial warpd agent in `streamhost/guest-agents/win311/` |
