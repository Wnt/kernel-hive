# Registry / SPA override draft — Symbolics Genera

Prep only. Apply after Open Genera VLM reaches a stable X desktop.

## Proposed identity

| Field | Proposed value |
|---|---|
| `museum.displayName` | `Symbolics Genera 8.x` |
| `museum.year` | `1990` provisional |
| `museum.lineage` | `MIT Lisp Machine → Symbolics Genera` |
| `museum.arch` | `Symbolics Lisp Machine environment via VLM` |
| `museum.era` | `1990s` |
| `spa.archetypeId` | `beige-tower-crt` initially |
| `spa.eraLabel` | `1990 · Symbolics Genera` |
| `ui` | `desktop` |
| accent | proposed `#8067a8` |

## Proposed software fields

- `eraSoftware`: Lisp Listener, Zmacs, Inspector, Dynamic Windows
- `iconicApps`: Zmacs, Lisp Listener, Inspector
- `periodBrowser`: none required
- blurb: `A Lisp Machine operating environment where editor, debugger, inspector and running applications are all live Lisp objects in the same programmable world.`

## Interaction/runtime intent

- pointer: absolute XTEST
- keyboard: preserve Meta/Control and any Genera-specific keys required by demos
- network: off first
- reset: pristine saved-world/VLM disk copy + relaunch

## Intended rest scene

Lisp Listener plus Zmacs/Inspector or another unmistakable Genera tool.

## MEASURE before promotion

- exact world/VLM build
- X geometry and font set
- modifier/key map
- startup time
- exact mutable files that reset must replace
