# freedos boot capture — zero-input prep

Status: **PROVEN-NEW** end to end on an isolated clone, 2026-07-14. The live tile
was read only.

FDAUTO.BAT/`MENU.BAT` cold-boots without input to the 720×400 FreeDOS 1.3 retro-games
menu. Ready means the full menu and `Pick a game` prompt are visible; Tier 3 holds
12 s. The external writable qcow2 is copied to the namespace and the unconditional
`-loadvm golden` is removed. The clone never attaches the live external disk.

Proof: record 11.960 s → postprocess → trim 6.477 s. Visual poster inspection showed
the complete games menu. Poster vs post-loadvm SSIM was 0.999594 (the only variance
is the hardware text caret); trim preserved final-frame MD5
`c1ce1660d06b40c4514edefad6df391d`. Final MP4 is 720×400, H.264 High,
yuv420p, 30/1, 0.5 s keyframes, plus AAC-LC; sprite/VTT/`durationMs` regenerated.
