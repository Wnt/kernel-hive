# nextstep pointer — angle "flatten-accel", PAUSED mid-run (2026-08-09)

Measured on clone `/data/vms/soltest/NSPTR-flatten-accel` (copy of the tile
overlay, `-loadvm golden`, hostfwd 5948), by framebuffer only.

## Instrument
`fa.py track` — exact-bitmap cursor template match restricted to the pixels that
CHANGED against a reference frame. Validated against two independent ground
truths: over-driven into the top-left clamp it reads (0,0); into the bottom-right
clamp it reads (1119,831) on a 1120x832 screen. Zero mismatch, unique hit.

## Previous's own transfer function: 1.000, not a scale factor
`src/gui-sdl/sdlevent.c: GuiEvent_HandleMouseMotion` computes
`fLin = fLinScale * (bADB ? 1.0 : 0.75)`. The tile ships `fLinScale = 1.333333`
and `bADB = FALSE`, so fLin = 0.99999975 — an intentional exact 1:1. What it does
add: (a) SDL_PeepEvents SUMS all queued motion into one event before scaling;
(b) `kms_mouse_move` CLAMPS the delta to a signed 6-bit +-63 px; (c) the float
result is truncated to int with a carried fraction, so the first event after a
direction change is short by 1 px.

## NeXTSTEP's transfer function: a x10 acceleration table, measured
Single event of S px (after a homing burst, so S-1 px is delivered), landed px:
S=8->70, 10->90, 12->110, 16->150, 20->190, 24->230, 32->310, 40->390, 48->470,
63->620; S=5->16, 6->30. Fits exactly `out = D * factor(D)` with
factor = 1,1,2,4,6,8,10 for D > 1,2,3,4,5,6 (strictly greater), saturating at 10.
Predicts every multi-event sweep to the pixel (e.g. the recurring 950 plateau).

That table IS NeXTSTEP's `MouseScaling` **level 3**: Preferences.app carries
`MouseScaling_Level_0..3` in its resources, e.g. Level_3 = `5 2 2 3 4 4 6 5 8 6 10`
(numScaleLevels, then threshold/factor pairs) — identical to the measured curve.

## Where the setting lives
- kernel: `evsioMouseScaling { numScaleLevels; scaleThresholds[20]; scaleFactors[20] }`
  (found in the guest's stabs), set through the ev driver.
- user default: key `MouseScaling`, GLOBAL owner, in the user's defaults DB
  `~/.NeXT/.NeXTdefaults.D|.L`. `loginwindow` reads it AT LOGIN and puts it in
  effect (its man page lists MouseScaling first; its binary parses `%d` then
  `%hd %hd`). Non-interactive: `dwrite -g MouseScaling "N t1 f1 ..."`.
- Preferences.app also carries `MouseScaling_Level_0..3` presets; the panel picks
  one of those four.

## Status of the flattening attempt
`dwrite -g MouseScaling "1 1 1"` was written and verified with `dread`, the
session was logged out and auto-logged back in — and the curve did NOT change
(S=16 still lands 150). So either the value is being rejected/ignored, the owner
is wrong, or loginwindow needs a different form. NEXT STEP if resumed: try the
four `MouseScaling_Level_N` preset strings verbatim (Level_0 =
`5 1 1 6 2 7 3 8 5 9 7`), and set the level through Preferences.app once to see
which key/owner Preferences itself writes (`dread -l` before/after).

## What is already proven about the angle
Feed-forward on the UNFLATTENED plant fails the acceptance test badly: commanded
(306,70) landed (296,48) — 22 px out — because a 1 px delivery error is
multiplied by the guest's x10 factor. Flattening is therefore necessary for this
angle, and its value is exactly that it turns a +-1 px plant error into +-1 px.
