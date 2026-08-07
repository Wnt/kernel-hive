# serenityos boot capture — zero-input prep

Status: **AUTHORED-UNTESTED, CURRENT-LIVE RED FLAG**. The read-only live shot was
entirely black rather than the documented 1024×768 desktop.

Serenity's raw root is the golden and the launcher creates a fresh namespaced qcow2
overlay every boot. NVMe is non-migratable, so `BR_BOOT_KIND=restart` correctly skips
savevm/loadvm. Disk-baked settings are intended to autostart a focused Terminal,
remove graph applets, and make the taskbar date-only; no input should be required.
The arm holds 75 s (150 s cap), records AC97 audio, and uses 1024×768/30 fps.

Ready means the full desktop, taskbar, icons, and focused terminal prompt. A black
poster is a hard failure. Repair/rebuild the raw golden in a separate scope before
publishing; then compare two independent fresh-boot screenshots because vmstate seam
verification is unavailable.
