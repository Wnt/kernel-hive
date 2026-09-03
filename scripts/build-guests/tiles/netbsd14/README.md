# netbsd14 in-guest steps (after sysinst, before the golden)

GENERIC 1.4.1 hangs in autoconf right after `lpt0` on QEMU and the release has
no userconf, so the station runs the custom kernel `KHMIN` (GENERIC minus every
ISA device the emulated i440fx PC lacks). Both steps run from the INSTALL
floppy's ramdisk shell — the only context in which this kernel's CD reads do
not hang (multiuser `boot -a` on the INSTALL kernel hangs every CD mount and
TFTP transfer; `docs/lab/NETBSD14-WAVE.md`).

Files here are burned onto one ISO with `syssrc.tgz`
(`genisoimage -R -J -V KHEXTRAS -o kh.iso <dir>`), attached as the ONLY CD.

1. Boot `boot.fs`; sysinst → Utility menu → Run `/bin/sh`.
2. `mount /dev/wd0a /mnt2 && mount /dev/wd0e /mnt2/usr && mount -r -t cd9660 /dev/cd0a /mnt2/mnt`
   (wd0e is `/usr`; a chroot without it has no `tar`, `config` or `cc`).
3. `chroot /mnt2 /bin/sh`, `PATH=/sbin:/bin:/usr/sbin:/usr/bin`,
   `sh /mnt/build-kernel.sh KHMIN` (≈5 min under KVM; installs `/netbsd`,
   keeps the previous kernel as `/netbsd.GENERIC`), then `sh /mnt/apply-x.sh`
   (XF86Config for the Cirrus, `/etc/kh-xsession`, static SLIRP network,
   `xinit` from `rc.local`). `sync`, `exit`, umount, reboot from `wd0`.
4. The golden is baked with `streamhost/stations/netbsd14/qemu-streamhost.sh`.
