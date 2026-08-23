"""Repo paths and shared constants for the stations registry generator."""

from __future__ import annotations

from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
REGISTRY = REPO / "registry"
TILES = REGISTRY / "stations"
TEMPLATES = REGISTRY / "templates"
POSTERS = REGISTRY / "posters"

# The retronet ICQ cross-list roster: the SINGLE source for every station's ICQ
# persona (uin/nick/client/onboarded). The registry's per-station `retronet`
# block declares bridge membership only and deliberately does NOT restate the
# persona; fleet_table.py merges the two and stations-registry.py cross-checks
# them in both directions.
ICQ_ROSTER = REPO / "scripts/retronet/icq/roster.json"

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
    # exec_shell: the guest login shell's family, for exec kinds whose framing
    # depends on it. Only telnet_unix_e reads it today -- "sh" means the exit
    # code is $?, absent means csh's $status (sunos414's default). Getting it
    # wrong is invisible: output is correct and the exit code is always -1.
    "exec_shell",
    "console",
    "udp_port",
    "notes",
)
NEW_TILE_SLOT_FLOOR = 81
