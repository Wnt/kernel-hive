# Android-x86 first-run machine-vision spike

> **HISTORICAL SESSION RECORD.** The host identity below is the retired pre-wipe
> system, not the current `labhost` host.

Date: 2026-07-14/15 UTC  
Host: CT950 lab host `pve-dryrun` (CPU only)  
Task clone: `/data/vms/soltest/repro-android-cv-1784064830/`

## Verdict

Local CPU-only vision is feasible for this tile and is materially safer than
the reconstructed tap array. The final detector found all ten observed targets
in 30/30 native template replays and 30/30 replays of the same framebuffers
resampled from 1024x768 to 800x600. It completed the wizard through the real
Quickstep home screen, including two screens absent from the old array, and the
result cold-booted without SetupWizard.

This is a prototype, not a recommendation to enable the path by default yet.
The text installer array before SetupWizard is independently stale, the second
resolution result is a resampled-frame test rather than a second guest mode,
and crops remain version/theme-specific. The proposed builder path therefore
stays behind `INSTALL_VISION=1`; the coordinate path remains the default for an
A/B run.

## Isolation and inputs

- No live QMP socket, live tile file, service, or `/data/gallery-guests` image
  was modified. The only source read from the gallery directory was the ISO.
- The ISO copied into the task namespace matched the builder pin:
  `91cedb534ba095a0c9b3eceede4147967fd27beea9bba640776f787dc3555021`,
  761,266,176 bytes, Android-x86 9.0-r2.
- The task disk is a fresh 8 GiB qcow2. QEMU ran under `nice -n15`, with its
  own PID file and `/data/vms/soltest/repro-android-cv-1784064830/qmp.sock`.
- Pool free space was checked before installation and at each expensive
  milestone. It started at 19.6 GiB, never crossed the 8 GiB stop boundary,
  and was 10.9 GiB after retaining the checkpoint set and `golden`.
- Host dependencies were `tesseract-ocr` plus the local venv pinned in
  `scripts/install-vision/requirements.txt`. No GPU API or device was used.

Measured on CT950 for representative 1024x768 frames:

| operation | wall time | peak RSS |
| --- | ---: | ---: |
| Tesseract text lookup | 0.59 s | 47 MiB |
| 13-scale OpenCV lookup | 1.09 s | 67 MiB |
| one frame-diff pair | 0.22 s | 46 MiB |

## What the reconstructed builder gets wrong

The problem is larger than coordinates. The observed ISO and wizard do not
match the comments in `android-x86.sh`:

1. The 640x480 ISO GRUB menu has **Installation as entry 3**, while the script
   sends three Downs and selects entry 4 (`Advanced options`).
2. The partition UI starts on `Create/Modify partitions`, but cfdisk starts on
   `Help`, not `New`; its Write navigation also differs from the array comment.
3. `Do not re-format` is the filesystem default; ext4 is one Down, not Enter.
4. The actual first-run flow has no `Copy apps & data` page. It has separate
   `MORE` and `ACCEPT` pages and, after SetupWizard, a launcher chooser requiring
   `Quickstep` and `ALWAYS`. Thus the real flow has ten actions, not eight.
5. The existing final `assert_not_black` would accept the animated
   `Just a sec...` page or launcher chooser as success.

The manually corrected text-install sequence was used only to reach the scope
of this spike. The flag-gated builder change below replaces the wizard taps;
it does not claim to repair all text-installer keystrokes.

## Detector reliability

Coordinates are centres returned from the native 1024x768 framebuffer. Native
OCR counts use the recorded restored-screen trials where available; template
counts are three separately launched detector replays per target. The 800x600
column is three template replays per target on a full framebuffer resampling.
That exercises scale and antialiasing tolerance but not Android layout reflow.

| observed target | native OCR | native template | 800x600 template | native centre | reconstructed tap |
| --- | ---: | ---: | ---: | ---: | --- |
| Welcome `START` | 0/5 | 3/3 (1.000) | 3/3 (0.957) | 630,432 | 512,470 — miss |
| Wi-Fi `SKIP` | 5/5 | 3/3 (1.000) | 3/3 (0.863) | 231,616 | 820,560 — miss |
| Wi-Fi confirm `CONTINUE` | 3/3 | 3/3 (0.957) | 3/3 (0.800) | 693,486 | 760,560 — miss |
| Date/time `NEXT` | 0/1 | 3/3 (1.000) | 3/3 (0.962) | 768,616 | tap 4/5 both miss |
| Services `MORE` | 0/1 scoped | 3/3 (1.000) | 3/3 (0.866) | 784,616 | 820,690 — miss |
| Services `ACCEPT` | 0/1 scoped | 3/3 (1.000) | 3/3 (0.870) | 784,616 | no distinct tap |
| Lock `Not now` | 3/3 | 3/3 (1.000) | 3/3 (0.789) | 302,501 | 760,560 — miss |
| Lock confirm `SKIP ANYWAY` | 0/2 | 3/3 (1.000) | 3/3 (0.821) | 710,423 | 760,560 — miss |
| Launcher `Quickstep` | 3/3 | 3/3 (0.967) | 3/3 (0.835) | 364,574 | absent |
| Launcher `ALWAYS` | 0/2 | 3/3 (1.000) | 3/3 (0.901) | 699,688 | absent |

At native size OCR alone handled four of ten screens. At 800x600 it handled
only `Not now` and `Quickstep`. OCR is therefore useful as the first, semantic
attempt but is not sufficient for Android's small styled button labels.
Weighted grayscale/edge `matchTemplate` with multi-scale crops handled all ten
at both sizes. Relative regions (`rel:x,y,w,h`) prevent body-copy occurrences
of `MORE` or `ACCEPT` from outranking the actual lower-right button.

The legacy coordinates geometrically hit 0/8 intended targets on the observed
layout. More importantly, even a recalibrated eight-coordinate array cannot
handle the ten-state flow.

## QMP action and settle findings

The driver performs this state machine:

`screendump -> wait for target -> savevm pre-click -> OCR -> template fallback -> absolute QMP move/click -> require transition -> frame-diff settle`

Two details were required for honest success reporting:

- After `loadvm`, Android accepted the absolute move but swallowed the first
  button event. The final driver polls for a >=1% framebuffer transition and
  retries the click only when none occurs. `cp-preclick-lock` passed 3/3 action
  retries; every JSON record shows attempt 1 moving only and attempt 2 producing
  the dialog transition.
- A settle result must observe a transition relative to the pre-click frame
  before counting steady frames. Without this rule a dropped tap was falsely
  reported as a steady destination.

The region watchdog was also exercised. Consecutive `Just a sec...` spinner
frames changed 0.35% globally but 0% outside the declared spinner region, so
they report known-region animation. Comparing that state with the unexpected
launcher chooser changed 75.86% outside the region and set
`unexpected_change=true`.

## Checkpoint tree

These are QEMU internal snapshots in the task qcow2. The tree is the logical
forward path; internal snapshot metadata itself is a flat tag list.

```text
cp-media-boot
└── cp-textsetup-done
    └── cp-firstboot
        └── cp-preclick-welcome
            └── cp-preclick-wifi
                └── cp-preclick-wifi-confirm
                    └── cp-preclick-datetime
                        └── cp-preclick-services-more
                            └── cp-preclick-services-accept
                                └── cp-preclick-lock
                                    └── cp-preclick-lock-confirm
                                        └── cp-preclick-launcher-quickstep
                                            └── cp-preclick-launcher-always
                                                └── golden
```

Abandoned/intermediate branches `cp-installer-partition-menu`,
`cp-cfdisk-blank`, `cp-partitioned`, `cp-textsetup-formatted`, and the stuck
`cp-postwizard-processing` experiment were deleted with `delvm`. No qcow2 file
was copied to make checkpoints and no reinstall was used after a misfire.

## Framebuffer and tile-contract evidence

Evidence remains in the namespaced clone under `evidence/`:

- `grub.png`: real 640x480 ISO menu with Installation in position 3.
- `firstboot-22s.png`: 1024x768 orange Welcome page.
- `post-welcome.png` through `post-lock-3b.png`: every wizard boundary.
- `final-wait-25.png`: the launcher chooser that the eight-tap path misses.
- `home-final.png`: first verified Quickstep home.
- `coldboot-production-home.png`: zero-input cold boot with the production
  launcher's USB, HDA-output, RTC, VGA, disk, and network topology.
- `golden-dirty.png` and `golden-restored.png`: search UI opened, then reset.
  Below the changing status bar the restored frame had changed fraction
  **0.00000000** and mean absolute delta **0.000000**.
- `cold-loadvm-golden.png`: a fresh QEMU process started with `-loadvm golden`.
  Its PNG MD5 equals `golden-restored.png` (`b311e2d498cb09011a2e210434a626d5`).
- `native-results-weighted.json`, `native-template-replays.json`, and
  `resampled-800x600/{results-weighted.json,template-replays.json}`: detector
  coordinates, scores, and hit counts.
- `final-qmp-retries-v2/`: restored-checkpoint input retry audit JSON.

This proves the task disk boots to home, and that the launcher's internal
`golden`/`loadvm` reset contract works with the exact production device set.
The production launcher has no external overlay; its writable qcow2 contains
the internal snapshot and starts with `-loadvm golden`.

## Proposed builder change

`scripts/build-guests/tiles/android-x86.sh` now contains the proposal behind
`INSTALL_VISION=1`:

```bash
apt-get install -y tesseract-ocr python3-venv
scripts/install-vision/install.sh
INSTALL_VISION=1 scripts/build-guests/tiles/android-x86.sh
```

The proposed path adds a unique QMP socket, waits for content instead of a
75-second initial sleep, checkpoints immediately after detection and before
each click, runs the actual ten-state flow, uses relative ROIs for ambiguous
service copy, and gates completion on OCR of the Quickstep `Google` search bar.
`INSTALL_VISION=0` retains `WIZARD_TAPS` for comparison.

Before making this the production default:

1. Repair and framebuffer-gate the independently stale text-installer keys.
2. Run a true second guest video mode, not only framebuffer resampling.
3. Add negative-screen fixtures per crop so score/ROI regressions fail in CI.
4. Decide whether the builder should cold-relaunch with the exact tile device
   set and create/verify `golden`; the spike proves that operation but does not
   silently change the builder's existing artifact policy.

## Generalization

The toolkit is a good candidate for other graphical-installer tiles when they
have deterministic screen states and QEMU-supported absolute input. Reuse the
QMP capture/action/settle code, but supply per-OS target phrases, crops, score
thresholds, and relative regions. Template matching should remain a fallback
to semantic OCR, and every click must be followed by a target transition or an
explicit known-animation region.

It is not a universal unattended-installer solution. Theme/version changes can
invalidate crops; animated desktops need masks; relative-pointer-only guests
need another injection backend; and a visually similar wrong dialog can still
need a state-specific negative fixture. The defensible general pattern is
**state-gated OCR + calibrated template + transition proof**, not unrestricted
screen scraping.
