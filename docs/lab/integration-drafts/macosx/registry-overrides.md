# Registry / SPA override draft — early Mac OS X

Prep only. Final year/version follows the Jaguar vs Panther winner.

## Proposed identity

| Field | Proposed value |
|---|---|
| `museum.displayName` | `Mac OS X 10.2 Jaguar` preferred first target |
| `museum.year` | `2002` if Jaguar wins; `2003` if Panther wins |
| `museum.lineage` | `NeXTSTEP / Rhapsody → Mac OS X` |
| `museum.arch` | `PowerPC G4 (QEMU mac99)` |
| `museum.era` | `2000s` |
| `spa.archetypeId` | `apple-studio` initially |
| `spa.eraLabel` | `2002 · Mac OS X Jaguar` provisional |
| `ui` | `desktop` |
| accent | proposed Aqua blue `#5d8fc7` |

## Proposed software fields

- `eraSoftware`: Finder, Dock, Terminal, System Preferences
- `iconicApps`: Finder, Dock, Terminal
- `periodBrowser`: Internet Explorer for Mac / Safari only if the chosen release includes it
- blurb: `Aqua arrives: Apple’s NeXT-derived Unix foundation becomes the Macintosh, with protected memory, the Dock and Finder on the same PowerPC machine as the classic OS it replaced.`

## Interaction/runtime intent

- pointer: measure from mac99 PMU HID; prefer built-in HID over duplicate USB devices
- keyboard: built-in PMU USB keyboard path if sufficient
- network: none first; add sungem/retronet only before the first final golden if desired
- reset: loadvm golden if restore is stable under the patched PPC QEMU

## Intended rest scene

Finder open, Dock visible, Terminal one click away, no Setup Assistant/update dialogs.

## MEASURE before promotion

- exact release/build
- QEMU binary/fork commit
- pointer mode/scale
- boot/install timings
- final device set and optional NIC

Do not prefill device-set hash or slot/port values.
