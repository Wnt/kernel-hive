# Solaris 10 CDE guest (`solaris` station)

> **Renamed 2026-08-10:** the daemon side was `solariscde` (`SH_TILE`, the station
> dir, `streamhost@solariscde`) until it was renamed to match the registry id
> `solaris`. The 5 GiB seed disk keeps its `solariscde-golden.qcow2` name (a
> data artifact, not identity), as do the `solaris-cde` build key and dated
> records below.

The live station runs real Oracle Solaris 10 x86 with the genuine CDE desktop.
In-guest automation (warpd pointer + exec agent, `labctl exec solaris`) is
documented in `streamhost/guest-agents/solaris/README.md`; the seed build
detail lives on labhost in `/data/gallery-guests/SolarisCDE/NOTES.md`.

<!-- section below folded in from exotic-gallery-guests.md (2026-07 restructure) -->

## As-built image manifest — Solaris 10 CDE — READY (real Solaris 10, authentic CDE) — license: free to use in this private collection

- **Image:** `/data/gallery-guests/SolarisCDE/solaris.qcow2` (~1.5 GiB actual / 12 GiB
  virtual). **Real Oracle Solaris 10 x86**, not the open-CDE fallback. `qemu-img check`
  clean. Full build detail in `/data/gallery-guests/SolarisCDE/NOTES.md`.
- **GUI reached:** YES — genuine **CDE (Common Desktop Environment)**, the classic dtwm
  front panel (workspace switcher One/Two/Three/Four, clock, mailer, calendar, Style
  Manager, trash, printer), dtfile File Manager, dthelp Help Viewer, Motif window frames,
  gray fractal backdrop. **NOT** JDS/GNOME. Proof:
  `/data/gallery-guests/SolarisCDE/proof-cde-desktop.png` (captured under the exact
  delivered run-disk config). CDE was explicitly chosen at the first-login desktop
  chooser and set as the persisted default; the "CDE deprecated" nag was suppressed.
- **How finished:** the prior in-progress install was actually complete (paused at the
  JumpStart post-install "Press Return to reboot" prompt). Force-ejected the locked CD so
  reboot wouldn't re-run the installer → boot_archive rebuilt → reboot from disk → dtlogin
  → login **root / solaris** → chose CDE. Verified reproducible across an init6 reboot.
- **Login:** `root` / `solaris`. dtlogin has no native autologin — a boot-to-desktop station
  needs the neko launcher to auto-type `root<CR>solaris<CR>` ~90 s after boot, or it sits
  at the dtlogin greeter (default session already CDE). *(Historical — neko-era
  note; the live streamhost station resumes a logged-in CDE desktop from its
  `golden` checkpoint, no auto-type involved.)*
- **Exact QEMU args (validated, boots to CDE):**
  ```
  qemu-system-x86_64 -machine pc,accel=kvm -cpu Nehalem -m 3072 -smp 2 \
    -drive file=solaris.qcow2,if=ide,index=0,media=disk -boot c -no-shutdown \
    -netdev user,id=net0 -device e1000,netdev=net0 \
    -audiodev pa,id=snd -device AC97,audiodev=snd \
    -vga std -usb -device usb-tablet -rtc base=utc
  ```
  `solvbox` was merely a symlink to stock `qemu-system-x86_64` — **no custom binary
  needed**. machine `pc` (i440FX) + **KVM accel** + cpu `Nehalem`; disk on **IDE**; net
  `e1000` (Solaris `e1000g`); vga `std` (X at 1920×1200). Host-only verify swaps
  `-audiodev pa` → `-audiodev none` (no PulseAudio server for root on the bare host —
  `pa` aborts QEMU there; neko provides `pa`). See `run-disk.sh`.
- **Sound:** AC97 → Solaris `audio810` driver. The device **attaches and the image boots
  cleanly with it present** (a new `/` device node appears), but audio playback was **not**
  verified (no PA backend available for host-side test runs).
- **Footprint:** qcow2 ~1.5 GiB; `sol10.iso` (2.0 GiB) is install-media only and removable
  at runtime. Heaviest exotic station, but well within pool budget (`data` ~48% CAP).
- **License (honest):** Oracle Solaris 10 is **proprietary** (distributed under the Oracle
  Technology Network **developer** license). Free to use in this private collection as a
  personal retro demo behind edge auth; the only rule is the copyrighted image binary isn't
  re-distributed via the GitHub repo. The fully-free path for the same look (not needed
  here) is open-source **CDE** (`cdesktopenv`, freed 2012, LGPL/MIT) on Debian/FreeBSD.

---
