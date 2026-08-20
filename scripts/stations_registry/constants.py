"""Repo paths and shared constants for the stations registry generator."""

from __future__ import annotations

from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
REGISTRY = REPO / "registry"
TILES = REGISTRY / "stations"
TEMPLATES = REGISTRY / "templates"
POSTERS = REGISTRY / "posters"

# Where `render` drops the RENDERED artifacts (see render.rendered()). Gitignored: these
# documents are resolved from the registry on demand, never committed, so a
# gallery-visible string has exactly one hit in a tracked file.
RENDER_DIR = "build/registry"

# Generated shell artifacts excluded from shfmt/shellcheck (scripts/lint/shell-sources.sh):
# their bytes are owned by the generator, not hand-formatted. Kept here so the
# gate-list meta-check can assert the exclusion list has not rotted.
GENERATED_SHELL = frozenset(
    (
        "scripts/build-guests/build-all.sh",
        "streamhost/stations-manifest.sh",
        "streamhost/bring-up-all.sh",
    )
)

LABCTL_KEYS = (
    "dir",
    "qmp",
    "pointer_mode",
    "warpd_port",
    "warpd_addr",
    "ssh_port",
    "exec_port",
    "exec_host",
    "exec_kind",
    "exec_user",
    "exec_key",
    "console",
    "udp_port",
    "notes",
)
NEW_TILE_SLOT_FLOOR = 81
