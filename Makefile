.PHONY: tile-registry-generate tile-registry-check tile-registry-validate \
	gallery-manifest-check check-file-size check-generated-drift quality-gate \
	poster-gallery-fetch poster-gallery-verify

tile-registry-generate:
	python3 scripts/tiles-registry.py generate

tile-registry-check:
	python3 scripts/tiles-registry.py --check
	$(MAKE) gallery-manifest-check

tile-registry-validate:
	python3 scripts/tiles-registry.py validate

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

# Cross-cutting quality gates (see docs/lab/AGENT-CI-EXIT-RULE.md).
check-file-size:
	node scripts/check-file-size.mjs --strict

check-generated-drift:
	scripts/check-generated-drift.sh

# The two gates every branch owes, regardless of language touched.
quality-gate: check-file-size check-generated-drift
