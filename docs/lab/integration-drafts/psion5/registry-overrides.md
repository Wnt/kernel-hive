# Registry / SPA override draft — Psion Series 5 / EPOC32

Prep only. Apply after the MAME-vs-WindEmu race picks a runtime.

## Proposed identity

| Field | Proposed value |
|---|---|
| `museum.displayName` | `Psion Series 5` or `Series 5mx` matching the ROM winner |
| `museum.year` | `1997` for Series 5; `1999` for 5mx |
| `museum.lineage` | `Psion EPOC32 → Symbian OS` |
| `museum.arch` | `ARM710/ARM710T family (exact model after winner)` |
| `museum.era` | `1990s` |
| `spa.archetypeId` | `touch-phone` temporarily |
| `spa.eraLabel` | `1997 · Psion Series 5` provisional |
| `ui` | `mobile` |
| accent | proposed `#66717f` |

## Proposed software fields

- `eraSoftware`: System screen, Agenda, Contacts, Word, Sheet
- `iconicApps`: Agenda, Word, Contacts
- `periodBrowser`: none required
- blurb: `The clamshell pocket computer whose EPOC operating system became Symbian — pen input above one of the best keyboards ever fitted to a handheld.`

## Interaction/runtime intent

- pointer: absolute pen/touch
- keyboard: full physical keyboard plus system keys
- audio/network: off first
- reset: relaunch from pristine ROM/state seed

## Intended rest scene

EPOC system screen with Agenda/Word immediately reachable.

## MEASURE before promotion

- MAME vs WindEmu winner
- exact model/ROM/year
- LCD geometry and pen range
- keyboard/system-key map
- reset persistence model
