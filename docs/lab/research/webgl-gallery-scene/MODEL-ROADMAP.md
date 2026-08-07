# Scene v2 exhibition model roadmap

**Cutover status (2026-07-28):** this roadmap's SceneV2 implementation is the
production `/museum` route; the compatibility route redirects to it and museum
v1 is removed.

This is the exhibit scope for the roadmap's 36-entry cohort (33 production,
3 showcase). The registry has since gained `openvms`; that later entry is not
part of this 36-entry integration baseline.

The director has rejected shared PC archetypes as the lineup plan. Every
entry now has a researched, era- and context-authentic desk signature in
[HARDWARE-MATRIX.md](HARDWARE-MATRIX.md). That matrix is the binding model
specification for re-integration, including remaps for any of the displayed
22 whose current assignment disagrees with it. It uses only project-generated
`gen_*` families: exported production variants, inexpensive unused variants,
the incoming replacements named in the matrix, and the explicitly scoped new
work. Sourced Sketchfab/poly models are not part of the plan.

Visual treatment, density, scale, and lighting remain governed by
[ART-DIRECTION.md](ART-DIRECTION.md).

## Current 22-slot display

Currently displayed: **22/36**, in registry lineup order:
`freedos`, `kolibrios`, `toaruos`, `win311`, `win95`, `win98se`, `win2000`,
`ninefront`, `helenos`, `solaris`, `android`, `postmarketos`, `sailfishos`,
`qnx`, `c64`, `atarist`, `apple2`, `amiga`, `win11`, `riscos`, `macos`,
`amstradcpc`.

All 36 entries remain explicitly mapped in `machines.ts`; the remaining 14
become visible without rebinding when the Phase-3 hall adds physical slots.
