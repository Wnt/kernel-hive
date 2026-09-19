# Registry / SPA override draft — Linux 0.12

Prep only. Apply after the two-floppy boot is proven on fleet QEMU.

## Proposed identity

| Field | Proposed value |
|---|---|
| `museum.displayName` | `Linux 0.12` |
| `museum.year` | `1992` |
| `museum.lineage` | `early Linux / i386 Unix-like` |
| `museum.arch` | `i386` |
| `museum.era` | `1990s` |
| `spa.archetypeId` | `beige-ibm-pc` |
| `spa.eraLabel` | `1992 · Linux 0.12` |
| `ui` | `text-console` |
| accent | proposed warm terminal beige `#b49a63` |

## Proposed software fields

- `eraSoftware`: shell, core Unix userland, early kernel tools
- `iconicApps`: shell, `ps`, source tree if present
- `periodBrowser`: none
- blurb: `Linux before distributions — a young 386 kernel, a tiny Unix userland and two floppy images, placed beside Minix and the later Linux distributions it grew into.`

## Interaction/runtime intent

- pointer: none
- keyboard: PC text console
- network/audio: none
- reset: relaunch from immutable boot/root floppy seeds

## Intended rest scene

Logged-in root shell showing `uname`, `ps`, and `ls` output.

## MEASURE before promotion

- exact image filenames/hashes
- machine type/CPU compatibility
- keyboard pacing
- boot-to-shell time
- whether root floppy must be writable
