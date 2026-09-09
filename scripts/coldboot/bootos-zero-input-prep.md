# bootos boot capture — zero-input prep

Status: **PROVEN on a clone**, 2026-09-02 (`/data/vms/sandbox/bootos-golden/`,
production device set: `pc-i440fx-11.0,pcspk-audiodev=snd0`, KVM, `-cpu host`,
64 MB, `-vga std`, dbus display + dbus audiodev). No live station existed yet; the
station dir was staged from this clone.

bootOS (Óscar Toledo G., 2019) is one 512-byte boot sector. SeaBIOS prints its
banner and the iPXE line, `Booting from Floppy...`, then the guest prints `bootOS`
and the `$` prompt — about 3 s after power-on, with **no input of any kind**: there
is no first-run dialog, no login, no menu. Ready means the `$` prompt with the caret
on the line below `bootOS`, in the 720×400 VGA text mode (80×25, 9×16 cells). Reject
anything still in the SeaBIOS phase or a `$` with typed text after it.

Blockers: **none**. Nothing is typed into the golden; the checkpoint is the untouched
cold boot.

The only block device is `floppy.qcow2` — the 360K `osall.img` floppy converted to
qcow2 (virtual size 368640 bytes; bootOS boots from 360K, 720K or 1.44M images and
only ever touches track 0..32 side 0). It carries **both** the filesystem the guest
writes (`enter`/`del`/`format`) and the `golden` vmstate (VM_SIZE 1.29 MiB), so
`loadvm golden` restores the directory of programs as well as RAM: `BR_DISKS` clones
just that one file. Audio is on (PC speaker → `pcspk-audiodev=snd0`); the canvas is
720×400 at 30 fps.

Clone proof (all frames sampled at a fixed machine instant, `stop; screendump; cont`,
so the blinking caret cannot fake a difference):

- cold boot → `$`, then `stop; savevm golden` on the floppy qcow2: accepted.
- in-process `loadvm golden`, dirty with `dir`, `loadvm golden` again, and after
  `del pi` + `dir`: every restore is byte-identical (`sha256 3e615bc1…`); `dir`
  after the restore lists `pi` again and is byte-identical to the first `dir` frame.
- fresh process through the launcher's own `-loadvm golden -S` + `cont`: the paused
  frame is byte-identical to the in-process restore. The only pixels that ever differ
  between two samples of the ready state are the 18 px (9×2) hardware caret cell at
  rows 157–158, whose blink phase is display-refresh state, not vmstate.

Only the caret animates after ready, so Tier 1 would also settle, but it could just
as well settle on a SeaBIOS pause; the DOS siblings' Tier-3 timer (12 s, cap 60 s) is
the honest detector. `record-boot.sh bootos --dry-run` was run with
`BOOTREC_TILES_ROOT` pointed at the tracked launcher (no live dir existed) and
wrote the rewritten clone launcher; the real record and the poster review are the
coordinator's, after the station is live.
