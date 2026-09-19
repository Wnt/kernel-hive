# Registry / SPA override draft — Multics MR12.8

Prep only. Apply after DPS8M QuickStart and user-terminal path are proven.

## Proposed identity

| Field | Proposed value |
|---|---|
| `museum.displayName` | `Multics MR12.8` |
| `museum.year` | `1965` as historical-system year; consider `1998` if registry policy prefers release date |
| `museum.lineage` | `MIT / GE / Honeywell Multics` |
| `museum.arch` | `DPS8/M Multics mainframe (exact CPU config after QuickStart)` |
| `museum.era` | `1960s` if supported; otherwise classify by chosen display-year policy |
| `spa.archetypeId` | `mono-terminal` |
| `spa.eraLabel` | `1965 · Multics` provisional |
| `ui` | `text-console` |
| accent | proposed teal-grey `#6f9292` |

## Proposed software fields

- `eraSoftware`: command processor, help, editors, Multics directory system
- `iconicApps`: command processor, help system
- `periodBrowser`: none
- blurb: `The computer as a utility — protected time-sharing, hierarchical files and a system whose scale and structure became the context Unix reacted against.`

## Interaction/runtime intent

- published surface: user terminal on the QuickStart terminal service, never DPS8M operator console
- pointer: none
- keyboard: normal terminal controls; document any escape/control keys used by demo
- reset: relaunch from pristine QuickStart work copy

## Intended rest scene

Clean Multics login or logged-in command-processor prompt in a full-screen terminal.

## MEASURE before promotion

- historical/display-year policy
- exact DPS8M CPU/config and QuickStart revision
- terminal port and terminal emulation
- launch-to-login time
- reset/pristine state files

Allocation and hash fields stay measured-only.
