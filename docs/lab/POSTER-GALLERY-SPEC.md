# Poster image gallery — implementation spec

Adds a **carousel of freely-licensed historical images** to the Origins section
of each exhibit's info poster (`ExhibitPoster`), with per-image attribution and
a link back to the original source.

This file is the contract between the agents building it. Read it instead of
re-deriving the codebase.

## Licensing policy (non-negotiable)

- **Only verifiably-free media is committed to this repo.** An image ships only
  if the Wikimedia Commons API reports one of the allowed licenses below. No
  "probably fine", no scraped retro-blog scans, no `fair use`.
- Allowed `extmetadata.License` values: `pd`, `cc0`, `cc-by-2.0`, `cc-by-2.5`,
  `cc-by-3.0`, `cc-by-4.0`, `cc-by-sa-2.0`, `cc-by-sa-2.5`, `cc-by-sa-3.0`,
  `cc-by-sa-4.0`. Anything else — including any value containing `nc`, `nd`,
  `fairuse`, `nonfree` — is a hard failure.
- Period **advertisements and sales posters are almost always still in
  copyright.** They may be included ONLY when hosted on Commons under an
  allowed license above (the same mechanical check — no special case). A
  copyrighted ad may be referenced as an outbound **link only**, with no image
  bytes in the repo.
- CC BY-SA images carry share-alike obligations. They are permitted, but must
  be flagged in the credits file so the obligation is visible.
- Repo code stays MIT. Bundled media is third-party, under its own license, and
  listed in `docs/IMAGE-CREDITS.md`.

## Round 1 scope — hardware-era exhibits

Only these tiles get a gallery in round 1. Every other poster must render
exactly as it does today (no carousel, no layout shift).

| tile id | machine to find images of |
|---|---|
| `c64` | Commodore 64 (breadbin and/or 64C), 1541 drive, 1084 monitor |
| `amiga` | Commodore Amiga 500 |
| `atarist` | Atari 520ST / 1040ST + SM124 monitor |
| `apple2` | Apple IIe (enhanced) / Apple II + Disk II |
| `amstradcpc` | Amstrad CPC 6128 (+ CTM644 monitor) |
| `mpf2` | Multitech Microprofessor II (MPF-II) |
| `irix` | SGI Indy (also acceptable: SGI Indigo/O2, SGI logo hardware) |
| `solaris` | Sun SPARCstation (SPARCstation 5/10/20, IPX) |
| `openvms` | DEC VAX hardware (VAX-11/780, MicroVAX, VAXstation) |
| `riscos` | Acorn Archimedes / RiscPC (RISC OS hardware lineage) |
| `android` | HTC Dream / T-Mobile G1 (first Android handset) |
| `sailfishos` | Jolla Phone / Jolla Tablet |
| `postmarketos` | PinePhone and/or Nokia N900 |

## Data flow

```
registry/posters/gallery/<id>.candidates.json   ← authored by research agents
        │  scripts/tools/fetch-poster-gallery.py   (verifies + downloads)
        ▼
registry/posters/gallery/<id>.resolved.json     ← GENERATED, committed
spa/public/posters/<id>/gallery/*.webp          ← GENERATED, committed
        │  scripts/poster_registry.py  →  scripts/tiles-registry.py generate
        ▼
spa/src/data/posters.ts  (PosterDoc.gallery)  →  spa/src/ui/ExhibitPoster.tsx
```

Research agents author **only** `*.candidates.json`. They never touch images,
markdown, TypeScript, or the generator. Nothing else authors the resolved file.

## File formats

### `registry/posters/gallery/<id>.candidates.json`

```json
{
  "schemaVersion": 1,
  "id": "c64",
  "images": [
    {
      "commonsFile": "File:Commodore-64-Computer-FL.jpg",
      "alt": "A beige Commodore 64 home computer photographed from above",
      "caption": "The Commodore 64 in its original 'breadbin' case, 1982.",
      "role": "photo"
    }
  ],
  "adLinks": [
    {
      "title": "\"Why is Commodore selling...\" — 1982 magazine advertisement",
      "url": "https://example.org/scan",
      "source": "Internet Archive"
    }
  ]
}
```

- `images`: 3–6 entries per tile, ordered best-first. `role` is `photo` or `ad`.
- `commonsFile`: exact Commons title including the `File:` prefix.
- `alt`: factual description for screen readers, no marketing language.
- `caption`: one sentence, museum-label voice, matching the existing poster
  prose register (see any `registry/posters/*.md`). No credit text — credit is
  generated from the API.
- `adLinks`: optional, 0–2 entries. Outbound links to copyrighted ads/posters
  that are NOT copied into the repo. Omit the key entirely if none.

### `registry/posters/gallery/<id>.resolved.json` (generated)

```json
{
  "schemaVersion": 1,
  "id": "c64",
  "images": [
    {
      "src": "/posters/c64/gallery/01-commodore-64-computer-fl.webp",
      "alt": "…", "caption": "…",
      "author": "Evan-Amos",
      "license": "Public domain",
      "licenseId": "pd",
      "licenseUrl": "https://…",
      "shareAlike": false,
      "sourceUrl": "https://commons.wikimedia.org/wiki/File:Commodore-64-Computer-FL.jpg",
      "sourceName": "Wikimedia Commons",
      "sha256": "…",
      "width": 1600, "height": 1067
    }
  ],
  "adLinks": [ … verbatim from candidates … ]
}
```

## Phase 1 — schema + carousel UI (agent A)

1. `spa/src/types.ts`: add `PosterGalleryImage` (fields exactly as the resolved
   JSON above, minus `sha256`) and `PosterAdLink`; add optional
   `gallery?: { images: PosterGalleryImage[]; adLinks?: PosterAdLink[] }` to
   `PosterDoc`.
2. `scripts/poster_registry.py`: when loading poster `<id>`, if
   `registry/posters/gallery/<id>.resolved.json` exists, validate it and attach
   it as `gallery`. A malformed or non-free entry is a load error, not a
   warning. Absent file = no `gallery` key (must not emit `null`).
3. `make tile-registry-generate` regenerates `spa/src/data/posters.ts`;
   `make tile-registry-check` must stay green (never hand-edit generated files).
4. `spa/src/ui/ExhibitPoster.tsx` + `ExhibitPoster.css`: render the carousel
   **immediately after the last block of the `Origins` section** (i.e. before
   the next `h2`), only when `poster.gallery?.images.length`.
   - One image visible at a time, prev/next controls, dot indicators,
     `n / total` counter.
   - Caption below the image; under it a credit line:
     `Photo: <author> · <license>` where `<author>`+`<license>` link out
     (`sourceUrl` and `licenseUrl`, `target="_blank" rel="noreferrer"`).
   - `adLinks`, when present, render as a short "Period advertising" list of
     outbound links beneath the carousel.
   - Keyboard: Left/Right arrows move slides when the carousel has focus; the
     poster's existing Escape-to-close must keep working. Buttons need
     `aria-label`s; the live region announces the current slide.
   - Respect `prefers-reduced-motion` (no slide animation). Lazy-load
     off-screen images. Never let a wide image break the poster layout.
   - Match the existing poster visual language — reuse the CSS variables and
     figure styling already in `ExhibitPoster.css`, do not invent a new palette.
5. Tests: extend the existing poster/data tests so a fixture with a gallery
   round-trips, and a fixture without one renders no carousel.
6. Full gate green: `cd spa && npx eslint . --max-warnings=0 && npx knip &&
   npm run build`, `ruff check scripts && ruff format --check scripts`,
   `node scripts/check-file-size.mjs --strict`, `make tile-registry-check`.
   `ExhibitPoster.tsx` is near a size cap — extract the carousel into its own
   component file rather than growing that file past its budget.

## Phase 2 — fetch + verify tooling (agent B)

`scripts/tools/fetch-poster-gallery.py`, plus Makefile targets
`poster-gallery-fetch` and `poster-gallery-verify`.

- Input: every `registry/posters/gallery/*.candidates.json` (or `--tile <id>`).
- For each `commonsFile`, query
  `https://commons.wikimedia.org/w/api.php?action=query&format=json&prop=imageinfo&iiprop=url|size|extmetadata&titles=<File:…>`
  with a descriptive `User-Agent`. Missing page (`-1`) → hard error naming the
  tile and title. Read `extmetadata.LicenseShortName`, `License`,
  `LicenseUrl`, `Artist` (strip HTML to plain text), and `DescriptionUrl`.
- Enforce the allowlist in the licensing policy above. Non-free → hard error,
  nothing written for that tile.
- Download the original, convert to WebP with Pillow: max 1600px on the long
  edge, quality ~82, strip EXIF, **target ≤ 200 KB** (step quality down if
  needed). Output `spa/public/posters/<id>/gallery/NN-<slug>.webp`.
- Write the resolved JSON with `sha256` of the shipped WebP and its dimensions.
  Set `shareAlike` true for any `cc-by-sa-*`.
- `--verify` mode: no downloads/writes; re-check every resolved entry's license
  against the live API and confirm each shipped WebP's sha256 and existence.
  Non-zero exit on any drift. Add `--offline` so verify can skip the network
  and check only sha256/existence (CI-safe).
- Idempotent: re-running with unchanged candidates rewrites identical bytes.
- Python style gate: `ruff check scripts && ruff format --check scripts`.

## Phase 3 — research (agents C…)

Per assigned tile, produce `registry/posters/gallery/<id>.candidates.json`.

- Search Commons (`action=query&list=search&srnamespace=6&srsearch=…`) and/or
  category listings (`list=categorymembers&cmtitle=Category:…&cmtype=file`).
  **Never invent a file title** — every title must come back from an API call
  you actually ran.
- Verify each candidate with the imageinfo call above BEFORE writing it down:
  it must exist, carry an allowed license, and be at least 800px on the long
  edge. Prefer: the real machine, well-lit, plain background, front or 3/4
  view; then peripherals (drive, monitor, joystick); then the machine in
  period use. Evan-Amos (public domain) and Wikimedia's retro-computing
  categories are the richest sources.
- Prefer variety over near-duplicates: 3–6 images showing different aspects.
- Do not download anything. Do not touch any file other than your tile's
  `*.candidates.json`. Do not run `make` or build the SPA.
- Report: for each tile, the chosen titles + licenses, and anything you could
  NOT find (a tile with fewer than 3 free images is a legitimate outcome — say
  so rather than padding with a wrong-machine photo).

## Phase 4 — credits and repo licensing

- `docs/IMAGE-CREDITS.md`: generated from the resolved JSONs — one table per
  tile with thumbnail path, author, license (+link), and source page. Mark
  share-alike rows.
- `spa/public/posters/CREDITS.md`: same content shipped alongside the assets.
- `README.md` + a `## Third-party media` note appended to `LICENSE`: code is
  MIT; bundled images are third-party under their own licenses, listed in
  `docs/IMAGE-CREDITS.md`; CC BY-SA items carry share-alike terms.
