# Registry / SPA override draft — Palm OS

Prep only. Apply after scaffolding and after the Palm III vs m505 smoke race.

## Proposed identity

| Field | Proposed value |
|---|---|
| `museum.displayName` | `Palm OS 4.1` if m505 wins; otherwise exact Palm III release |
| `museum.year` | `2001` for Palm OS 4.1 / m505 target |
| `museum.lineage` | `PalmPilot / Palm OS` |
| `museum.arch` | `Motorola DragonBall 68k-family (exact device after winner)` |
| `museum.era` | `2000s` or `1990s` if an earlier Palm III ROM wins |
| `spa.archetypeId` | `touch-phone` as temporary PDA stand-in |
| `spa.eraLabel` | `2001 · Palm OS 4.1` (adjust if needed) |
| `ui` | `mobile` |
| accent | proposed `#65755b` |

## Proposed software fields

- `eraSoftware`: Applications launcher, Date Book, Address Book, Memo Pad, Calculator
- `iconicApps`: Date Book, Memo Pad, Graffiti
- `periodBrowser`: none required
- blurb: `The pocket organizer that made the stylus practical — instant-on PIM apps, Graffiti handwriting and a software ecosystem built for a few seconds of attention at a time.`

## Interaction/runtime intent

- pointer: absolute stylus; pen-down maps to primary button
- keyboard: optional hardware keys plus text/Graffiti support as emulator allows
- audio/network: off for first release
- reset: relaunch from pristine device state

## Intended rest scene

Applications launcher with built-in PIM apps visible; no calibration/setup dialog.

## MEASURE before promotion

- winning device/ROM release
- portrait geometry/orientation
- pen coordinate mapping
- hard-button key map
- persistent-state/reset shape

Do not guess slot/port/render orders or image hashes.
