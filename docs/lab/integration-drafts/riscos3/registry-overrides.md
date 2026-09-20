# Registry / SPA override draft — RISC OS 3.11

Prep only. Apply after the normal scaffold; measured runtime facts win over this file.

## Proposed identity

| Field | Proposed value |
|---|---|
| `museum.displayName` | `RISC OS 3.11` |
| `museum.year` | `1992` |
| `museum.lineage` | `Acorn Arthur → RISC OS` |
| `museum.arch` | `ARM2/ARM3 (exact CPU follows aa310 vs aa5000 winner)` |
| `museum.era` | `1990s` |
| `spa.archetypeId` | `beige-tower-crt` initially |
| `spa.eraLabel` | `1992 · RISC OS 3.11` |
| `ui` | `desktop` |
| accent | muted Acorn green/grey; proposed `#6f8f63` |

## Proposed software fields

- `eraSoftware`: Filer, !Draw, !Paint, BASIC
- `iconicApps`: Filer, !Draw, !Paint
- `periodBrowser`: `none` for the first exhibit
- blurb: `Acorn’s native ARM desktop — the icon bar, !applications and the graphical system that turned ARM from a processor experiment into a personal computer platform.`

## Interaction/runtime intent

- pointer: absolute, three-button if the emulator path exposes it cleanly
- keyboard: standard Acorn mapping, measured from MAME
- audio: off initially
- network: none initially
- reset: relaunch unless MAME savestate is proven stable

## Intended rest scene

RISC OS Desktop with icon bar visible, one Filer window open, !Draw or !Paint immediately reachable.

## MEASURE before promotion

- exact machine (`aa310` vs `aa5000`)
- RAM / framebuffer dimensions
- mouse port tags and coordinate range
- reset mode and boot time
- final hero image / screenshot alt text

Do not prefill slot, UDP port, VMID, render orders, hashes, or runtime paths here; the scaffold/allocation and worker measurements own those facts.
