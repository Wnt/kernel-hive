# Registry / SPA override draft — MIT ITS

Prep only. Apply after the upstream SIMH build and separate user terminal work unattended.

## Proposed identity

| Field | Proposed value |
|---|---|
| `museum.displayName` | `MIT ITS` |
| `museum.year` | `1967` provisional |
| `museum.lineage` | `MIT PDP-6/PDP-10 Incompatible Timesharing System` |
| `museum.arch` | `DEC PDP-10 (SIMH target selected by upstream ITS build)` |
| `museum.era` | `1960s` if supported |
| `spa.archetypeId` | `mono-terminal` |
| `spa.eraLabel` | `1967 · MIT ITS` provisional |
| `ui` | `text-console` |
| accent | proposed `#8a929a` |

## Proposed software fields

- `eraSoftware`: DDT, Emacs, Maclisp, Scheme, Zork/Maze War-era tools
- `iconicApps`: DDT, Emacs, Maclisp
- `periodBrowser`: none
- blurb: `MIT’s hackers’ timesharing system — the environment that hosted early Emacs, Maclisp and a culture where the operating system itself was something users explored and changed.`

## Interaction/runtime intent

- published surface: separate ITS user terminal on TCP 10004, never simulator console
- pointer: none for first release
- keyboard: Ctrl-Z login plus Escape/control combinations used by DDT/Emacs
- reset: pristine built-disk copy + automated SIMH relaunch

## Intended rest scene

Logged-in DDT session or an early Emacs screen with daemon console hidden.

## MEASURE before promotion

- exact upstream commit/SIMH variant
- unattended boot sequence/start-auto wrapper
- terminal emulation/key map
- build time and launch-to-user-terminal time
- mutable disk files/reset set
