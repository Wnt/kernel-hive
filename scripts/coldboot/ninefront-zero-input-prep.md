# ninefront boot capture — zero-input prep

Status: **PROVEN + LIVE (2026-07-15)**. The vendored pipeline cold-recorded and
baked a namespaced clone, restored the settled fixture with immediate warpd and
keyboard input, passed SSIM `1.000000`, and supplied the promoted live golden.

`plan9.ini` suppresses boot questions, so the disk cold-boots hands-off to rio.
The clone-only `ninefront-record-driver.sh` waits on the real 1024×768 rio
framebuffer, focuses the initial terminal, and launches acme, stats, catclock,
and a final focused rc terminal. The arm then holds 3 s (120 s overall cap).
The intel-HDA stream is recorded as 48 kHz stereo AAC.

Safety is the important part: the writable golden is outside the tile directory at
the manifest path. `BR_EXTERNAL_DISKS` copies it to `ninefront.qcow2`, rewrites the
clone launcher, removes inline `-loadvm golden`, and moves hostfwd 57793→58793.
Inspect the dry-run launcher and poster; no clone may attach the external live qcow2.

Evidence: raw 34.660 s → trimmed 31.183 s; final-frame MD5 remained
`370587372846cf749aebe732c0c7fce8`; output is H.264 High/yuv420p 1024×768
30 fps plus AAC-LC. Published `/boot/ninefront/` and `/boot/index.json` returned
HTTP 200 and Range 206. The live reset completed in 458 ms and the pointer probe
returned `K` immediately afterward.
