# Registry / SPA override draft — MSX2 / MSX-DOS 2

Prep only. Apply after a real MSX2 machine profile and DOS2 media boot in openMSX.

## Proposed identity

| Field | Proposed value |
|---|---|
| `museum.displayName` | `MSX2 — MSX-DOS 2` |
| `museum.year` | `1985` |
| `museum.lineage` | `MSX standard → MSX2` |
| `museum.arch` | `Zilog Z80A / MSX2 VDP platform (exact machine after profile choice)` |
| `museum.era` | `1980s` |
| `spa.archetypeId` | `beige-tower-crt` temporarily |
| `spa.eraLabel` | `1985 · MSX2` |
| `ui` | `home-computer` |
| accent | proposed `#376ca8` |

## Proposed software fields

- `eraSoftware`: MSX-BASIC, MSX-DOS 2, disk tools, one productivity/creative app
- `iconicApps`: MSX-BASIC, MSX-DOS 2
- `periodBrowser`: none
- blurb: `A home-computer standard instead of a single vendor machine — BASIC in ROM, cartridges, disks and MSX-DOS shared across machines from Sony, Panasonic, Philips and others.`

## Interaction/runtime intent

- pointer: none unless chosen demo app needs MSX mouse
- keyboard: standard MSX mapping
- audio: optional; network: none
- reset: openMSX relaunch from immutable ROM/disk seed

## Intended rest scene

MSX-BASIC or MSX-DOS 2 prompt with the alternate environment one action away.

## MEASURE before promotion

- exact real MSX2 profile
- ROM/media set
- framebuffer/window geometry
- key map and optional mouse
- chosen demo software
