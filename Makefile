.PHONY: tile-registry-generate tile-registry-check tile-registry-validate \
	gallery-manifest-check check-file-size check-generated-drift quality-gate

tile-registry-generate:
	python3 scripts/tiles-registry.py generate

tile-registry-check:
	python3 scripts/tiles-registry.py --check
	$(MAKE) gallery-manifest-check

tile-registry-validate:
	python3 scripts/tiles-registry.py validate

gallery-manifest-check:
	cd spa && node --experimental-strip-types scripts/test-gallery-manifest.mjs

# Cross-cutting quality gates (see docs/lab/AGENT-CI-EXIT-RULE.md).
check-file-size:
	node scripts/check-file-size.mjs --strict

check-generated-drift:
	scripts/check-generated-drift.sh

# The two gates every branch owes, regardless of language touched.
quality-gate: check-file-size check-generated-drift
