# beos boot capture — zero-input prep

Status: **hand-verified on the bring-up rig 2026-08-17; no clip recorded yet.**
A cold boot of `beos-golden.qcow2` reaches the 1024×768×16 BeOS R5 desktop
(Deskbar top-right, Tracker, one Terminal window) with **no input at all**:

- the on-disk boot loader boots the partition straight through (`makebootable`
  done in-guest; no boot menu unless space is held);
- `home/config/settings/kernel/drivers/vesa` pins `1024 768 16`, so the splash
  and the desktop are both 1024×768;
- both first-run nag alerts are pre-dismissed (`stop_vga_nagging`,
  `stop_swap_nagging` under `home/config/settings/`), and the media server has
  been started once so its settings file exists;
- `home/config/boot/UserBootscript` opens the Terminal that is part of the
  fixture.

Under TCG the desktop lands ~150 s after power-on on a loaded box (`BR_MAX_MS`
is 300 s). The only motion after that is the Deskbar clock (once a minute) and
the Terminal caret, so the change-fraction detector settles; when comparing the
clip's last frame with the checkpoint's first live frame, sample at a fixed
machine instant (`stop; loadvm golden; stop; screendump`) so the caret does not
make two captures of the same state differ.

Blockers that had to be fixed *inside the volume* for the boot to be
input-free at all (`docs/guests/beos.md`): the ISA config manager's PnP-BIOS
call (add-on removed) and MP-table IRQ routing (`multiprocessor_support
disabled`).
