# Scene-v2 standing QA lap

These are review criteria for a human reading the contact sheets `qa-lap.mjs`
produces; the automated judge that once consumed them has been removed.

Review only the visible composition, coverage, and regression evidence in the
four labeled contact sheets. Do not discuss tone, color grading, palette,
lighting mood, or stylistic taste.

## Composition

- In both rail sweeps, the camera framing remains usable at every stop: the
  museum is legible, focal exhibits are not accidentally cut off, and no large
  foreground object hides the view.
- Desktop (1600x1000) and portrait (390x844) frames preserve a coherent
  eye-level view without stretching, letterboxing, or viewport-specific
  clipping.
- Section and lineup shots center their intended subject and show enough
  surrounding geometry to judge placement.

## Coverage

- The desktop and portrait rail sheets together show a continuous sweep of the
  hall, including its near and far extents, rather than repeated or empty views.
- Every labeled decade has a readable wide section view.
- All five labeled lineup models are present, fully visible, and framed at a
  useful inspection scale.

## Regressions

- Flag blank or black renders, missing models, broken assets, severe geometry
  intersections, floating or buried exhibits, camera penetration, duplicate
  frames, and obvious layout discontinuities.
- Treat labels as evidence identifiers, not part of the scene composition.
- Do not invent defects that are not visible in the supplied sheets.

End with exactly one decision line:

`VERDICT: SHIP` when no blocking composition, coverage, or regression defect is
visible, otherwise `VERDICT: ITERATE`.

Before that line, cite each finding by contact-sheet name, tile label, and
visible image region. If there are no defects, cite at least two concrete
regions that demonstrate coverage and composition.
