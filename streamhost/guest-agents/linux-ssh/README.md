# Guest ssh shells (alpine / tinycore / haiku) — bake recipe

Real captured-output exec channels for the modern tiles: sshd inside the guest
+ a host→guest `:22` forward + the shared key `/root/.ssh/gallery_guest_key`
(on the box; generate with `ssh-keygen -t ed25519 -N "" -f ~/.ssh/gallery_guest_key`
if absent). `labctl exec <tile> "<cmd>"` uses these (ports in
`/data/vms/streamhost/tiles.json`).

Everything in-guest lives INSIDE the golden snapshot (`savevm golden` after
setup, clean screendump first). The host→guest forward is host-side SLIRP
state, NOT in the snapshot:

- **haiku**: `hostfwd=tcp:127.0.0.1:5807-:22` baked onto the EXISTING
  `-netdev user` in the launcher (backend property — device set unchanged, so
  `loadvm golden` still matches).
- **alpine / tinycore**: these run on QEMU's DEFAULT SLIRP NIC (no explicit
  `-netdev` to extend), so their golden launchers re-add the forward POST-BOOT
  via `qmp_hmp.py <qmp> "hostfwd_add net0 tcp:127.0.0.1:<port>-10.0.2.15:22"`.
  Never add a `-device` for this — it breaks `loadvm golden`.

## Per-tile in-guest setup (run once per fresh golden, console via cdrv/labctl)

### alpine (port 5881, user root)
```sh
# SLIRP internet works out of the box for apk
apk add openssh
ssh-keygen -A
# static IP (no DHCP client in the fixture)
ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up; route add default gw 10.0.2.2
mkdir -p /root/.ssh   # then install gallery_guest_key.pub as /root/.ssh/authorized_keys
rc-update add sshd; /usr/sbin/sshd
# restore the clean fixture screen (clear; cat /root/banner), then savevm golden
```

### tinycore (port 5882, user tc)
```sh
tce-load -wi openssh            # eth0 already has a DHCP lease
sudo cp /usr/local/etc/ssh/sshd_config.orig /usr/local/etc/ssh/sshd_config
sudo /usr/local/etc/init.d/openssh start    # generates host keys
mkdir -p /home/tc/.ssh          # install gallery_guest_key.pub as authorized_keys
# persist via TinyCore backup if the fixture uses it; clean screen; savevm golden
```

### haiku (port 5807, user `user`, uid 0)
Haiku ships `/bin/sshd` + host keys + sshd_config already.
```sh
# GOTCHA: sshd_config has an ACTIVE 'AuthorizedKeysFile config/settings/ssh/authorized_keys'
# so the key goes to /boot/home/config/settings/ssh/authorized_keys (NOT ~/.ssh)
mkdir -p /boot/home/config/settings/ssh     # install gallery_guest_key.pub there
# disk-persisted autostart:
mkdir -p /boot/home/config/settings/boot/launch && ln -s /bin/sshd /boot/home/config/settings/boot/launch/sshd
# clean screen; savevm golden
```
NOTE: the live haiku launcher boots a persistent `haiku-persist.qcow2` (`-boot c`),
NOT the manifest's `--cdrom` LiveCD emit — the launcher is hand-baked; don't
regenerate it blindly from `tiles-manifest.sh`.

## Verify (from the box, all non-interactive)
```sh
ssh -i /root/.ssh/gallery_guest_key -p 5881 -o StrictHostKeyChecking=no root@127.0.0.1 'echo OK; uname -sm'  # alpine
ssh -i /root/.ssh/gallery_guest_key -p 5882 -o StrictHostKeyChecking=no tc@127.0.0.1  'echo OK; uname -sm'  # tinycore
ssh -i /root/.ssh/gallery_guest_key -p 5807 -o StrictHostKeyChecking=no user@127.0.0.1 'echo OK; uname -sm' # haiku
# persistence: loadvm golden, then re-run the ssh — must still answer
```

## Not done (candidates)
sailfishos/postmarketos (GUI multi-step; pmOS is snapshot=on ephemeral),
android (no sshd, -snapshot), serenityos/reactos (no ssh server shipped).
