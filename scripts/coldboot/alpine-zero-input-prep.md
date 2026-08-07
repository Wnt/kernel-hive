# alpine boot capture — zero-input prep

Status: **PROVEN-NEW** on an isolated clone, 2026-07-14. The live tile was only
read (`labctl shot alpine`); it was not restarted or written.

The tracked/live launcher is a 1280×800 Alpine 3.24 LiveCD with AC97 audio and a
tile-local `state.qcow2` used only for `savevm golden`. A cold boot shows
ISOLINUX/OpenRC, then stops at `localhost login:`. That is not ready. The arm runs
`alpine-record-driver.sh` after capture begins: after an 18 s guard it enters the
passwordless `root` account over the clone QMP. No human input or disk change is
required. Ready means the visible `localhost:~#` shell prompt; the arm holds it 5 s.

The clone launcher copies `state.qcow2`, suppresses conditional `-loadvm golden`,
and rewrites the launcher-added SSH forward 5881→6881. Do not use the live state
disk or port. Framebuffer inspection confirmed the final root prompt.

Proof: record 31.900 s → postprocess → trim 20.416 s; poster and post-`loadvm`
frame were byte-identical (SSIM 1.000000). Trim preserved final-frame MD5
`dba4ca45f346aed181d05d8352e678ab`. Final MP4: 1280×800, H.264 High,
yuv420p, 30/1, 0.5 s keyframes, AAC-LC; sprite/VTT/`durationMs` regenerated.

Run `record-boot.sh alpine`, `postprocess-boot.sh alpine`, then optionally
`trim-boot.sh "$BOOTREC_STAGING_ROOT/alpine"`.
