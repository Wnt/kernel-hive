# cpm22 — facts for the week closing 2026-09-20

Raw material for the Sunday authoring pass.

## New stations

<u>[CP/M 2.2](station:cpm22) joins the museum</u> — a **Kaypro II** (Non-Linear
Systems, 1982), one of the "luggable" all-in-one CP/M machines that sold
computing to small businesses before the IBM PC did. The station boots the
genuine 1982 CP/M 2.2 (GMv2.72) system floppy straight to the `A>` prompt,
with WordStar 3.3 on a second floppy alongside it.

The station runs host-native on MAME's `kayproii` driver — no QEMU, no guest
OS underneath, keyboard-only (the Kaypro II has no mouse port and this
station has no network).

What was hard: nothing about the Kaypro's own hardware — the keyboard is
handled by its own Intel i8048 microcontroller rather than a CPU-scanned
matrix, and a keyboard proof against the fleet-pinned MAME 0.289 landed
byte-perfect at the fleet's ordinary pacing floor. What was hard was a MAME
UI behavior: the `kayproii` driver flags its own beeper as "imperfect
sound", which makes MAME pop up a modal "known problems" panel before the
machine ever starts running — invisible with the kiosk's UI stripped, but
the input wait behind it still blocked the guest forever, so the station
went live showing a solid black screen. It was caught by an operator reading
the actual framebuffer, not a log. The fix is the same patch two other
audio-off MAME stations (domainos, newsos) already carry
(`mame-irix-skip-warnings.patch` + `NATIVE_SKIP_WARNINGS=1`); once applied
the station rebuilt in about a minute (ccache hit) and came up clean.

What's open: the real-browser typing proof hasn't been run yet — the
probe script exists but needs an authenticated session to reach `/os/cpm22`.
The daemon-level typing path (same one the browser uses) is proven, and the
station does have a golden checkpoint, restore-proven pixel-identical at the
`A>` prompt.
