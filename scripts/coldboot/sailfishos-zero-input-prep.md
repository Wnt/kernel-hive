# sailfishos boot capture — zero-input prep

Status: **AUTHORED-UNTESTED, CURRENT-LIVE RED FLAG**. The required read-only
`labctl shot sailfishos` showed a 720×400 Syslinux/kernel boot console, not the GUI.

The launcher uses the external disk with QEMU `-snapshot`, so the arm is
`BR_BOOT_KIND=restart`: it may share the base read-only while all guest writes go to
QEMU's private temporary overlay, and it never savevms. Audio is genuinely off. A
generous 180 s fixed timer (240 s cap) covers the intended cold boot.

Ready must be a Sailfish graphical shell, never the observed boot text. Diagnose or
rebuild the disk in a separate namespaced task before publishing; this arm documents
and safely records the boot once that content issue is fixed. Current canvas evidence
is 720×400/30 fps, but update the arm if the repaired GUI selects another final mode.
