# dragon32 guest

Status: **scaffold only** (Tier 2, disabled candidate; not in the lineup).

## Identity and source

- Public ID / tile directory: `dragon32`
- Reserved slot / UDP port: `130` / `54130`
- Archetype: `beige-tower-crt`
- Stable release, architecture, source/license class, URL, size, and SHA-256: TODO

## Build and device set

- Builder: `scripts/build-guests/dragon32.sh`
- Canonical output: TODO
- QEMU binary, machine, accelerator, CPU, RAM, display, storage, NIC, audio, and input: TODO
- Ready framebuffer and bounded automation path: TODO

## Golden, input, and rollback

- Reset mode and fixture: TODO
- Run `scripts/lib/golden-verify.sh dragon32 --bake` on a namespaced clone, then
  rerun without `--bake` before promotion.
- Pointer/click/drag/wheel/keyboard proof: TODO
- Cold-boot zero-input state and optional clip: TODO
- Credentials reference only (never values): `guest/dragon32`
- Rollback plan: TODO
