# newsos guest

Status: **scaffold only** (Tier 3, disabled candidate; not in the lineup).

## Identity and source

- Public ID / tile directory: `newsos`
- Reserved slot / UDP port: `148` / `54148`
- Archetype: `putty-lcd`
- Stable release, architecture, source/license class, URL, size, and SHA-256: TODO

## Build and device set

- Builder: `scripts/build-guests/tiles/newsos.sh`
- Canonical output: TODO
- QEMU binary, machine, accelerator, CPU, RAM, display, storage, NIC, audio, and input: TODO
- Ready framebuffer and bounded automation path: TODO

## Golden, input, and rollback

- Reset mode and fixture: TODO
- Run `scripts/lib/golden-verify.sh newsos --bake` on a namespaced clone, then
  rerun without `--bake` before promotion.
- Pointer/click/drag/wheel/keyboard proof: TODO
- Cold-boot zero-input state and optional clip: TODO
- Credentials reference only (never values): `guest/newsos`
- Rollback plan: TODO
