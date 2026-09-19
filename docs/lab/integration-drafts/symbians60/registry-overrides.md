# Registry / SPA override draft — Symbian S60

Prep only. Apply after the Nokia 5320 EKA2L1 profile boots unattended.

## Proposed identity

| Field | Proposed value |
|---|---|
| `museum.displayName` | `Symbian S60` or exact Nokia model label |
| `museum.year` | `2008` if Nokia 5320 target is retained |
| `museum.lineage` | `Psion EPOC → Symbian OS → Series 60 / S60` |
| `museum.arch` | `ARM (exact Nokia CPU/profile follows firmware)` |
| `museum.era` | `2000s` |
| `spa.archetypeId` | `touch-phone` |
| `spa.eraLabel` | `2008 · Symbian S60` provisional |
| `ui` | `mobile` |
| accent | proposed Nokia blue `#2c6fb7` |

## Proposed software fields

- `eraSoftware`: Standby screen, Application menu, Contacts, Messaging
- `iconicApps`: Contacts, Messaging, S60 menu
- `periodBrowser`: S60 Browser if present in selected firmware
- blurb: `The keypad-and-soft-key smartphone platform that dominated the pre-iPhone era — a direct descendant of Psion EPOC running on mass-market Nokia phones.`

## Interaction/runtime intent

- pointer: none required for S60v3 target
- keyboard: D-pad, center, soft keys, menu, back/end, digits, `*`, `#`
- reset: relaunch from pristine EKA2L1 device-profile copy

## Intended rest scene

Standby screen or application menu with soft-key labels visible.

## MEASURE before promotion

- exact Nokia product code/firmware
- device window geometry/crop
- key translation map
- EKA2L1 CLI/data-dir arguments
- reset-state directory list
