# Scene v2 reference set

The director's nine original photos are **reference-only and are NEVER
committed to this repo** (they depict a real collection; the director keeps
them off the project). What lives here instead:

- `mj-recreation-prompts.md` — detailed per-photo descriptions used to
  recreate each shot in Midjourney (real brand names kept per director's call
  2026-07-27; recreations are reference material, not shipped UI art).
- `ref-01-mj.webp` … `ref-09-mj.webp` — the picked Midjourney recreations
  (2688px Subtle upscales, q90 WebP; lossless PNGs archived off-repo at
  `~/scene-v2-reference/mj-upscales/` on the dev box), committed as the
  in-repo visual anchor for agents + the `--sref` style source for all later
  2D art (posters, signage, placards, tileable material albedos). Style
  anchor for the whole set: the director-approved ref-01 v1 pick
  (`cdn.midjourney.com/a29b9d38-1242-4766-867c-e1bbf0580067/0_3.png`).

The written source of truth is `../ART-DIRECTION.md` (manifest of what each
ref anchors, palette, lighting, space plan, scale rules). When a recreation
and the text disagree, the text wins — the director corrects both.

Generation happens on the dev-box VNC Chrome (xdesk `:1`, CDP `:9222`,
profile `~/.config/mj-chrome`) with the director logged into Midjourney.

The obsolete art-direction transcodes formerly stored in
`spa/public/assets/photos/` were removed at cutover.
