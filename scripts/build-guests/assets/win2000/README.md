# Windows 2000 unattended-install candidate

`WINNT.SIF.in` is a secret-free research template, not a validated golden input.
Render both `@@PRODUCT_KEY@@` and `@@ADMIN_PASSWORD@@` only into a mode-0600
scratch file. Never commit the rendered file or the floppy containing it.

The proposed raw-QEMU delivery is a 1.44 MB FAT12 virtual floppy containing the
rendered file as `A:\WINNT.SIF`, attached with `-fda`. This is the least invasive
option: it preserves the operator-supplied ISO byte-for-byte, is visible during
text-mode Setup, and follows the repository's already-validated Windows XP
unattended-delivery pattern.

Example artifact construction after the guarded builder preflight has verified
the authorized ISO and key inputs:

```sh
dd if=/dev/zero of=unattend.flp bs=1024 count=1440 status=none
mkfs.vfat -F 12 unattend.flp
MTOOLS_SKIP_CHECK=1 mcopy -o -i unattend.flp WINNT.SIF ::/WINNT.SIF
chmod 600 WINNT.SIF unattend.flp
```

No `$OEM$` payload is proposed yet. `DriverSigningPolicy=Ignore` permits supplied
drivers, but it cannot resolve hardware for which no driver is present. The
current tile's recurring prompt is the driverless `ACPI\QEMU0002` device; the
existing-image builder now suppresses that prompt with an offline registry flag.
