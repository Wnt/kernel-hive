# ravynos boot capture — zero-input prep

Status: **AUDITED, NOT RECORDED, AND NOT RECOMMENDED FOR A CLIP.** The cold-boot
behaviour below was observed first-hand on the bring-up sandbox during this
station's 2026-09-01 bring-up. No clip has been captured, `spa.bootVideo` is
deliberately **not** set in `registry/stations/ravynos.json`, and this file plus
the `ravynos)` arm in `bootrec-tiles.conf` exist so the cold-boot path is
audited — which is what the playbook requires before a station ships.

The station is a live-ISO exhibit: the guest boots the read-only
`ravynOS_0.6.1_amd64.iso` under OVMF on q35 at a firmware-fixed **1280×800**
canvas, 30 fps, audio on. `resetMode` is `loadvm`, snapshot `golden`. The only
writable devices are `ravynos-golden.qcow2` — a carrier the guest never uses for
storage, present solely to hold the vmstate — and `OVMF_VARS.qcow2`, the UEFI
variable store. **Both must be cloned for any record run**, and a record run
must never attach the live writable copies. See the launcher header in
`streamhost/stations/ravynos/qemu-streamhost.sh` (it is the device-set ledger)
and `docs/guests/ravynos.md`.

## THE COLD BOOT IS NOT ZERO-INPUT, AND CANNOT BE MADE ZERO-INPUT IN 0.6.1

This is the whole point of this file. A cold boot of the live ISO reaches a
graphical **LoginWindow** at roughly **95–110 s** and then **waits for a human
forever**. Nothing else happens: there is no timeout, no autologin, no guest
agent. Firmware plus kernel to the ravynOS banner takes well under a minute; the
rest is WindowServer and LoginWindow coming up.

There is **no autologin setting available**. The live image's configuration lives
inside a read-only uzip on the ISO, and 0.6.x ships no Filer and no Settings app
with which to change it from the desktop. So the honest conclusion is:

> **The golden IS the zero-input path for this station.** A cold boot is a
> supervised operation, not something a visitor arrival can trigger.

## Driving the login, if a supervised run needs the desktop

Four steps, in this order. Coordinates are in the **1280×800 framebuffer**.

1. **Click the login panel body (e.g. `640,160`) to ACTIVATE the window.** This
   step is mandatory and non-obvious. Clicking straight into the Username field
   does nothing at all: the field never takes focus, the typed text is silently
   discarded, and the panel then shows a red *"Try Again"* as though the
   credentials were wrong. This cost real time to diagnose — do not skip it and
   do not re-diagnose it.
2. **Click the Username field (`640,267`), then click it AGAIN.** One click on
   the field is not enough after the activation click.
3. **Type `liveuser`.** There is no password — upstream documents this publicly.
4. **Click the Log In button (`640,396`).** The desktop appears **~20–25 s**
   later.

**Pointer injection must be absolute.** Use QMP `input-send-event` with `abs`
axes scaled to `0..32767`. Do **not** use the HMP `mouse_move` stepping in
`labqmp.mouse_relative_from_origin` (`scripts/lib/labqmp.py`): it drifts, and on
this station it put a click roughly **300 px off target**. Note also that
`labqmp`'s `button` action takes a **bitmask** — `button 1` to press, `button 0`
to release. `button left` silently does nothing.

## Ready scene

The clean logged-in desktop: the global menu bar with the raven glyph and a
clock, the Zakim-bridge wallpaper drawn by `Dock.app`, and the Dock (Terminal,
Install, Trash). **No windows open.** Reject any capture that shows the
LoginWindow, a red *"Try Again"*, a half-typed Username field, or a Terminal
window left open by the driving run.

## There is no idle-deterministic frame

The menu-bar **clock repaints once a minute** and 0.6.x offers no way to hide it,
so two captures of "the same" idle desktop can differ purely by clock glyphs.
Frames must therefore be compared at a **fixed machine instant**:

```
stop ; loadvm golden ; stop ; screendump out.ppm ; cont
```

That is exactly the sequence that proved this station's restore byte-exact:
baseline and restored frames hashed identically, while a deliberately dirtied
frame differed. Use it for every frame comparison on this station — a tier-1
change-fraction settle on a live desktop is not a substitute.

## Handoff — why no boot video

A published clip's last frame must match the golden's first live frame. **For
this station that is impossible to satisfy from a true cold boot**: a cold boot
ends at the LoginWindow, and the golden begins at the desktop. The seam would be
a full-screen jump.

**Recommendation: no boot video for `ravynos`**, unless someone deliberately
records the driven login sequence of §"Driving the login" above — which is an
honest clip of a supervised operation, not a cold boot. Setting `spa.bootVideo`
is the registry owner's call; it is left unset on purpose.

## Recording, if it is done anyway

Run `record-boot.sh ravynos --dry-run` first and inspect the rewritten clone
launcher: it must name the clone's `ravynos-golden.qcow2` and `OVMF_VARS.qcow2`
and never the live ones, and it must not add or remove a single `-device` —
`loadvm golden` requires an exact device match. The carrier disk stays declared
**first**, before the pflash pair, or the vmstate lands in the 528 KiB variable
store instead (`qemu-img snapshot -l` must show the VM_SIZE on
`ravynos-golden.qcow2` and 0 B on `OVMF_VARS.qcow2`).

The arm records with a tier-3 fixed timer, because a zero-input run has no
settling desktop to detect — it has a LoginWindow that never changes again.
There is no record driver: the login sequence above is framebuffer-asserted work
that must be watched, not blind-sent on a timer.

## Upstream context

ravynOS **0.6.1 (2025-10-25)** is the **last FreeBSD-based build**. The project
restarted on Darwin/XNU four days later and deleted every release of this line
from GitHub and SourceForge, so the ISO this station boots cannot be re-sourced
upstream.
