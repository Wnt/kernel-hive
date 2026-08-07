# Naming: Kernel Hive vs. streamhost vs. labctl

This project is **Kernel Hive** — the name for the project as a whole: the
React SPA, the docs, the museum concept, the GitHub repo. Use "Kernel Hive"
in anything user-facing: READMEs, page titles, UI copy, issue trackers.

Two internal names deliberately do **not** change, and keep appearing
throughout the code, systemd units, and runtime paths:

- **`streamhost`** — the Rust daemon that captures a tile's display and audio
  and streams it to the browser over WebTransport. Its crate/binary name,
  the `streamhost@<tile>` systemd unit template, the `/data/vms/streamhost/…`
  runtime paths, and every `SH_*` environment variable are all called
  `streamhost`. This predates the Kernel Hive rebrand and is load-bearing on
  the live lab box: renaming it would mean touching every unit file, every
  path reference, and every deployed binary in place, for no user-visible
  benefit. See `streamhost/README.md` and `streamhost/docs/DESIGN.md`.
- **`labctl`** — the operator CLI on the box (`scripts/labctl`, installed at
  `/usr/local/bin/labctl` on the lab host) used to drive tiles: `labctl ls`,
  `labctl exec`, `labctl shot`, and friends. Its safety-guard sibling
  `scripts/lib/clone-guard.sh` is in the same category. Both must stay
  byte-identical to their live copies on the box, so they are never
  rebranded or otherwise edited casually.

A few other identifiers also stay as they are for the same "it's a live
box resource, not branding" reason: the `osgallery-dev` hostname for the
CT950 dev container, the `scripts/serve/osgallery-https-server.py` /
`osgallery-https.service` HTTPS origin server and its systemd unit, and any
`/etc/osgallery/…` path referenced in the docs. If you're renaming
something and it turns up in `AGENTS.md`'s access map, check there first —
that file is the map of what is actually deployed on the box today.

**Rule of thumb:** if it's prose, a UI string, a page title, a package name,
or a doc heading — it's Kernel Hive. If it's a systemd unit, an environment
variable, a runtime path under `/data/vms/streamhost/…` or `/etc/osgallery/…`,
or a script the box already has installed under a fixed name — it keeps its
existing name.
