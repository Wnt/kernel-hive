# Registry / SPA override draft — IBM MVS 3.8j

Prep only. Apply after Hercules + x3270 smoke proof.

## Proposed identity

| Field | Proposed value |
|---|---|
| `museum.displayName` | `IBM MVS 3.8j` |
| `museum.year` | `1978` |
| `museum.lineage` | `OS/360 → MVT/SVS → MVS` |
| `museum.arch` | `IBM System/370 (exact Hercules CPU model after config)` |
| `museum.era` | `1970s` |
| `spa.archetypeId` | `mono-terminal` |
| `spa.eraLabel` | `1978 · IBM MVS 3.8j` |
| `ui` | `text-console` |
| accent | proposed phosphor green `#4fa36c` |

## Proposed software fields

- `eraSoftware`: TSO, ISPF, JES2, JCL
- `iconicApps`: ISPF, TSO, JES2
- `periodBrowser`: none
- blurb: `The mainframe behind the green screen — batch jobs, TSO and formatted 3270 sessions on a shared System/370 world.`

## Interaction/runtime intent

- published surface: x3270 only
- pointer: none required
- keyboard: include Enter/Clear/PA/PF keys in on-screen profile
- reset: relaunch pristine Hercules/DASD state, then reconnect x3270

## Intended rest scene

TSO READY or ISPF primary option menu, with no Hercules operator console visible.

## MEASURE before promotion

- exact TK package / CPU / memory
- x3270 model/font/window geometry
- TSO credentials location (private store only)
- boot-to-3270-ready time
- special key mapping

Allocation/runtime paths remain worker-owned facts.
