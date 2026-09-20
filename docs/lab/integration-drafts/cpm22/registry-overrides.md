# Registry / SPA override draft — CP/M 2.2 on Kaypro II

Prep only. Apply after MAME `kaypro2` boots the selected disk image.

## Proposed identity

| Field | Proposed value |
|---|---|
| `museum.displayName` | `CP/M 2.2 — Kaypro II` |
| `museum.year` | `1982` for the Kaypro II exhibit |
| `museum.lineage` | `Digital Research CP/M` |
| `museum.arch` | `Zilog Z80` |
| `museum.era` | `1980s` |
| `spa.archetypeId` | `mono-terminal` |
| `spa.eraLabel` | `1982 · CP/M 2.2` |
| `ui` | `text-console` |
| accent | proposed green phosphor `#6b9d70` |

## Proposed software fields

- `eraSoftware`: CCP, WordStar, disk utilities
- `iconicApps`: WordStar, `DIR`, `PIP`
- `periodBrowser`: none
- blurb: `The A> prompt before DOS — CP/M business software on a Z80 Kaypro, where WordStar and drive letters were already familiar before the IBM PC won the market.`

## Interaction/runtime intent

- pointer: none
- keyboard: Kaypro keyboard mapping
- audio/network: none
- reset: MAME relaunch from immutable floppy seeds

## Intended rest scene

`A>` prompt with a directory listing visible; WordStar one command/disk away.

## MEASURE before promotion

- ROM revision and exact floppy format
- actual framebuffer geometry/crop
- key pacing and special keys
- whether WordStar stays on second disk or boot disk
