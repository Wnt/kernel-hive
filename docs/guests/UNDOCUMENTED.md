# Stations without a dedicated guest doc (stub index)

Seven live stations have no `docs/guests/<os>.md` of their own. Until someone writes
one, the authoritative references per station are its build script under
`scripts/build-guests/` and its `emit <tile>` stanza in
`streamhost/stations-manifest.sh` (flag ledger + stanza comments).

| Station | Build script | Notes |
|---|---|---|
| `android` | `scripts/build-guests/tiles/android-x86.sh` | Android-x86 9; one-time SetupWizard coordinate calibration (see MASTER-REPRODUCE Phase 4 table) |
| `postmarketos` | `scripts/build-guests/stages/postmarketos.sh` | UEFI/OVMF — writable `OVMF_VARS.qcow2` varstore (seeded by `stations-manifest.sh` post-emit); unlock PIN 147147 |
| `serenityos` | `scripts/build-guests/tiles/serenityos.sh` | cold-boot station (`labctl reset` refuses); per-boot writable overlay over the read-only seed `_disk_image` |
| `toaruos` | `scripts/build-guests/tiles/toaruos.sh` | cold-boot station (`labctl reset` refuses); live ISO |
| `win2000` | `scripts/build-guests/tiles/win2000.sh` | boot-video clip flagged in the UI (see `scripts/coldboot/`) |
| `win311` | `scripts/build-guests/tiles/win311.sh` | partial coverage exists in `docs/guests/win9x.md` (the Win 3.11 material); serial warpd agent in `streamhost/guest-agents/win311/` |
