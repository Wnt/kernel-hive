# solaris boot-capture — zero-input prep + detection notes

Reproduction notes for baking a boot video on the **solaris** vmstate tile
(Oracle Solaris 10 1/13, genuine CDE, 1920x1200 std-VGA) with `record-boot.sh`
(spec `BOOT-VIDEO-REPLAY-SPEC.md` §3.1/§3.2). Verified end to end on a
`/data/vms/sandbox` clone 2026-07-13; the **live tile was never touched** (the
`golden` snapshot stayed byte-identical: ID 1, 732 MiB, 2026-07-08 00:14:51).

## Why prep is needed (cold boot ≠ zero-input) — the HARD blocker

The live golden serves via `loadvm golden` (already at the curated CDE fixture:
GOLDEN-FIXTURE-TERMINAL dtterm open + focused, fresh `# ` prompt, front-panel
Clock removed, perf-meter frozen, screensaver/DPMS off). But `record-boot.sh`
**cold-boots** (no `loadvm`) to film POST → Solaris boot → desktop, and a cold
boot of `solariscde-golden.qcow2` ends at the **graphical dtlogin greeter**
("Welcome to solaris / Please enter your user name"), NOT the CDE desktop — it
needs a username + password. Stock Solaris CDE **has no native auto-login**:
`strings /usr/dt/bin/dtlogin` and `dtgreet` contain no `autoLogin` resource.

## The prep (done on the CLONE's copied qcow2 only)

Three disk changes, all driven over the clone's warpd exec channel
(`/root/gexec.py 58790`, forwarded to guest `:7777`), each verified by a cold
reboot + framebuffer screendump:

1. **Auto-login by repointing the cde-login SMF start method.** Replaced
   `/lib/svc/method/svc-dtlogin` (the `svc:/application/graphical-login/cde-login`
   start method, originally `/usr/dt/bin/dtlogin -daemon`) with a script that
   starts the X server and runs the CDE session **directly as root, no greeter**:
   ```sh
   HOME=/; USER=root; LOGNAME=root; export HOME USER LOGNAME
   PATH=/usr/dt/bin:/usr/openwin/bin:/usr/X11/bin:/usr/bin:/usr/sbin:/sbin; export PATH
   /usr/openwin/bin/xinit /usr/dt/bin/Xsession -- \
       /usr/X11/bin/Xserver :0 -nobanner -depth 24 >/var/tmp/autocde.log 2>&1 &
   exit 0
   ```
   Original saved as `/lib/svc/method/svc-dtlogin.orig`. **Why the SMF method and
   not an rc-script:** the cde-login service stays **online**, so SMF's
   login-service requirement is satisfied and `console-login` stays **offline**
   as it normally does under a graphical login — no maintenance mode. `Xsession`
   restores the saved CDE session (`/.dt/sessions` → the GOLDEN-FIXTURE-TERMINAL
   **and warpd**, so the auto-login golden keeps its exec agent) and sources
   `Xsession.d` (the `9999.golden-fixture` animation-freeze hook).

2. **Disable sendmail** (`svcadm disable svc:/network/smtp:sendmail` +
   `svc:/network/sendmail-client:default`). Without a dtlogin console-message
   handler, sendmail's boot-time `mail.alert` ("unable to qualify my own domain
   name (localhost) -- using short name", routed to `/dev/console`) falls through
   onto the fixture terminal, spoiling the clean `# ` prompt. Disabling sendmail
   (unused by the gallery) removes the one offender; remaining boot messages are
   `kern.info`, which do not route to console. Result: clean fresh `# ` prompt.

3. **`9999.golden-fixture` hook left UNCHANGED** (original plain `dtterm`), so the
   auto-login settled desktop matches the curated golden exactly.

### Approaches that FAILED (lessons)
- **Disabling `console-login`** → Solaris drops straight to **maintenance mode**
  ("Console login service(s) cannot run … Root password for system maintenance")
  because no login service is available. Reverted.
- An **rc3.d/S99autocde xinit** autostart needs console-login disabled to own the
  VGA → same maintenance trap. Abandoned for the SMF-method replacement (keeps
  cde-login online, so console-login stays cleanly offline).

## Detection: Tier-2 on the terminal title bar

Tier-1 framebuffer-stability is unusable: a cold Solaris boot paints the CDE
Corrugated backdrop + dtwm root long before the fixture dtterm, and the front
panel comes up a few seconds BEFORE the dtterm — so both a backdrop crop and a
panel crop would false-settle on a terminal-less desktop. Use **Tier-2** on the
**GOLDEN-FIXTURE-TERMINAL title bar** (`bootrec-tiles.conf` `solaris)` arm):
SSIM a crop of its maroon title band + white title text
(`crop=430:26:350:112`, measured maroon RGB ~178,77,122) — present ONLY once the
terminal (the LAST fixture element) is fully drawn — vs `boot-ref-desktop.png`
for K=4 frames. Observed on the clone: region-SSIM 0.000002 (backdrop) → 1.000000
×4 → **settled at +88.5 s** on the clean desktop. `boot-ref-desktop.png` (the
clean settled-desktop screendump) lives beside the golden in the tile dir; for a
live bake, drop the golden fixture screendump there under that name.

Extra x264 knob: `BR_CRF=14` for this tile (default 18). At 1920x1200 the noisy
Corrugated backdrop leaves enough crf18 H.264 residual that the boot.mp4 **last
frame vs poster** luma-SSIM is 0.998951 (just under the 0.999 gate); crf14 raises
it to 0.999353. Gate-1 (poster == golden) is md5-identical regardless of crf.

## Invariant result (clone, framebuffer truth)

`poster == screendump(loadvm golden)` **SSIM 1.000000 (md5-identical,
b0908f96…)**; boot.mp4 last decoded frame vs poster **SSIM 0.999353** (crf14,
H.264/yuv420p residual only). Clip **91.2 s**, 1920×1200, H.264 video-only
(`hasAudio: false` — Solaris CDE has no boot/login chime). `goldenSha
f8133104…`.

## GOLDEN-CHANGE RISK (for the human go/no-go)

The current LIVE golden is a `loadvm`-restored curated fixture (baseline
framebuffer md5 872a0cfc…). Promoting the boot video requires re-baking the
golden to the **clean cold-boot auto-login desktop** produced here. The two are
visually near-identical — **SSIM(curated golden, clean-boot desktop) = 0.999680**
— both show the GOLDEN-FIXTURE-TERMINAL with a fresh `# ` prompt, the CDE front
panel, and the Corrugated backdrop. The functional deltas a promotion would
introduce, for a human to weigh:
- cde-login now auto-logs-in root via the replaced svc-dtlogin method (greeter
  gone); `.orig` is on disk for rollback.
- sendmail disabled.
- warpd still starts (saved-session restore), so the exec agent is preserved.
This work only records + verifies + **stages**; it does NOT promote to live.
