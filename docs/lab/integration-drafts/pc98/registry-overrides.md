# Registry / SPA override draft — NEC PC-98

Prep only. Apply after NP2kai boots Japanese Windows 3.1 from the installed seed disk.

## Proposed identity

| Field | Proposed value |
|---|---|
| `museum.displayName` | `NEC PC-98 — Windows 3.1` |
| `museum.year` | `1993` provisional |
| `museum.lineage` | `NEC PC-9800 series` |
| `museum.arch` | `PC-9801/PC-9821 x86 (exact model after NP2kai config)` |
| `museum.era` | `1990s` |
| `spa.archetypeId` | `beige-ibm-pc` |
| `spa.eraLabel` | `1993 · NEC PC-98 / Windows 3.1` |
| `ui` | `desktop` |
| accent | proposed `#5277a5` |

## Proposed software fields

- `eraSoftware`: Japanese MS-DOS 6.2, Program Manager, File Manager, IME/Japanese text stack
- `iconicApps`: Program Manager, File Manager
- `periodBrowser`: none required
- blurb: `Japan’s parallel PC standard — familiar DOS and Windows software running on NEC hardware that was never an IBM-compatible PC.`

## Interaction/runtime intent

- pointer: XTEST into NP2kai window, measured after Windows driver choice
- keyboard: PC-98/Japanese mapping; visitor should still navigate common UI without Japanese typing
- audio/network: optional, not launch gates
- reset: pristine HDD seed copy + emulator relaunch

## Intended rest scene

Japanese Windows 3.1 Program Manager with clearly visible Japanese labels and one representative app/group.

## MEASURE before promotion

- exact PC-98 model/CPU
- BIOS set and WAB config
- video mode/driver
- pointer/key map
- installed disk format/path
