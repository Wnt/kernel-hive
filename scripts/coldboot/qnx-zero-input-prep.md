# qnx boot capture — automated-input prep

Status: **CLONE-VALIDATED 2026-07-15 UTC**. The production recipe reaches the
1024×768 Photon desktop on Cirrus VGA with `devg-svga`, 64K colour.

`qnx-record-driver.sh` makes the arm runnable without a human: after a 25 s floor it
requires three stable 720×400 framebuffer samples before sending F2; it then waits
for the 640×480 phgrafx framebuffer, selects 1024×768 (`Tab`×3, `Down`×2,
`Tab`×5, `Space`), accepts the timed test with `Alt+A`, exits with `Alt+X`, and
logs in as root with the empty LiveCD password. `QNX_RECORD_PASSWORD` is an
optional non-echoed override. Do not publish unless `mode-accepted.png` and
`ready.png` are both 1024×768.

The arm copies tile-local `golden.qcow2`, rewrites the legacy monitor 7112→17112,
records 1024×768/30 fps AC97 audio, then holds the desktop 10 s. There is no persistent
LiveCD surface for an autologin fix, so the automated driver is the reproducible prep.
