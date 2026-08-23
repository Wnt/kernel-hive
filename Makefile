.PHONY: station-registry-generate station-registry-check station-registry-validate \
	gallery-manifest-check check-file-size check-generated-drift quality-gate \
	poster-gallery-fetch poster-gallery-verify devwatch \
	release-notes release-notes-check release-notes-brief

station-registry-generate:
	python3 scripts/stations-registry.py generate

# Watch the hand-written registry sources; regenerate + publish runtime
# manifests to the box whenever a save validates (see registry/README.md).
devwatch:
	cargo run --manifest-path streamhost/Cargo.toml -p devwatch --release --

station-registry-check:
	python3 scripts/stations-registry.py --check
	$(MAKE) gallery-manifest-check

station-registry-validate:
	python3 scripts/stations-registry.py validate

gallery-manifest-check:
	cd spa && node --experimental-strip-types scripts/test-gallery-manifest.mjs

# Poster gallery: registry/posters/gallery/*.candidates.json (authored by
# research agents) -> resolved.json + webp assets (see
# docs/lab/POSTER-GALLERY-SPEC.md Phase 2). poster-gallery-verify re-checks
# licenses live; pass --offline via the script directly for a CI-safe,
# network-free sha256/existence-only check.
poster-gallery-fetch:
	python3 scripts/tools/fetch-poster-gallery.py

poster-gallery-verify:
	python3 scripts/tools/fetch-poster-gallery.py --verify

# Release notes: the PROSE is hand-written, one
# registry/release-notes/<end-date>.json per week, by a Claude Code pass the
# operator runs on Sundays (docs/lab/RELEASE-NOTES-PROMPT.md). README.md's
# "## Release notes" section, docs/RELEASE-NOTES.md and
# spa/public/release-notes.json are RENDERED from those files -- never
# hand-edit the three outputs. No git history is read for content, so
# release-notes-check is deterministic: red always means "run `make
# release-notes` and commit". It is deliberately NOT part of quality-gate and
# NOT in check-generated-drift.sh's GENERATED_PATHS (that array is
# cross-validated against the station registry and would break
# `make station-registry-check`).
release-notes:
	python3 scripts/release-notes.py render

release-notes-check:
	python3 scripts/release-notes.py check

# Print the authoring brief for the newest closed week with no summary yet.
# Exits 2 (and this target fails) when a declared emulator fork could not be
# reached: the brief still prints in full, but it is short a fork, and writing
# the week up from it would under-report exactly what it exists to catch.
release-notes-brief:
	python3 scripts/release-notes.py brief

# Cross-cutting quality gates (see docs/lab/AGENT-CI-EXIT-RULE.md).
check-file-size:
	node scripts/check-file-size.mjs --strict

check-generated-drift:
	scripts/check-generated-drift.sh

# The two gates every branch owes, regardless of language touched.
quality-gate: check-file-size check-generated-drift

# Old target names (terminology stage 2, 2026-08-12) — one-epoch aliases so
# muscle memory and in-flight agent briefs keep working. Removed in stage 5.
.PHONY: tile-registry-generate tile-registry-check tile-registry-validate
tile-registry-generate: station-registry-generate
tile-registry-check: station-registry-check
tile-registry-validate: station-registry-validate
