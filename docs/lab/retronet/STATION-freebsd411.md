# freebsd411 on the retronet — the bridge, Konqueror, and Kopete

**Status: PARTIAL — web plane proven on the framebuffer, ICQ plane wired but NOT
yet signed in.** `freebsd411` (FreeBSD 4.11-RELEASE i386, KDE 3.3.2 on XFree86
4.4.0) was given a second, **bridged** NIC on `vmbr-rn` on 2026-09-03 so that
Konqueror can reach the gateway's `:80` museum-corpus origin and Kopete can reach
its OSCAR door — OSCAR cannot traverse the station's slirp NIC, which stays in
place purely as the x11warp pointer path.

What is **proven on the framebuffer** (frames in
`/data/vms/streamhost/stations/freebsd411/evidence/`):

| Proof | Frame |
|---|---|
| `kdenetwork-3.3.2` (Kopete) installed from the 4.11 package archive, `EXIT=0`; `/usr/local/bin/kopete` present | `retronet-kdenetwork-pkg_add-exit0-20260903.png` |
| the guest resolves and fetches `http://search.retronet/` over the bridge with **no proxy** | `retronet-guest-fetch-search-retronet-20260903.png` |
| **Konqueror renders `http://search.retronet/`** — the AltaVista-styled retronet search page, status bar "Page loaded." | `retronet-konqueror-search-retronet-20260903.png` |

What is **not yet proven**: Kopete signed in as UIN `17800`, HiveBot in the
contact list, the desktop Konqueror launcher, and the **re-baked golden** on the
new device set. See §Open.

## The wiring, at a glance

| | |
|---|---|
| NIC | **second** NIC `-device rtl8139,netdev=rn0,mac="$RN_FREEBSD411_MAC"`, backend `-netdev tap,id=rn0,ifname=freebsd411rn0,script=no,downscript=no`. FreeBSD 4.11 drives it as **`rl0`** (GENERIC). `rtl8139` and not `ne2k_pci`: the NE2000 is 16-bit PIO and under KVM that is one VM exit per word — the same trap that put this station's system disk on an `lsi53c895a` (`docs/lab/FREEBSD411-WAVE.md` §Measured facts). `rl` does real DMA. |
| slirp NIC | **unchanged** — `-netdev user,id=n0,hostfwd=tcp:127.0.0.1:6078-10.0.2.15:6000 -device ne2k_pci,netdev=n0`, guest `ed0`. It carries **only** the x11warp pointer forward; the pointer route is untouched, so the fixture's `SH_X11WARP_DISPLAY=127.0.0.1:78` still holds. |
| MAC | fleet scheme `52:54:00:52:4e:23` (`52:4e` = RN, last octet = last IP octet, `.35` → `0x23`). Real value box-local in gitignored `registry/local.env` `RN_FREEBSD411_MAC`; the committed launcher carries the scrubbed placeholder `02:00:00:00:00:23` and reads the one line at boot. **The MAC lives in the golden's device vmstate**, so the golden must be baked by a COLD boot on this set. |
| Tap | `freebsd411rn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/freebsd411/rn-tapnet.sh up` from the launcher on **every** start. The launcher runs under `set -e` and `rn-tapnet.sh` exits non-zero unless it can read its own rules back out of the kernel, so **QEMU never starts an uncontained guest**. |
| Guard chain | `FREEBSD411RN-IN`, hooked into `INPUT` twice — scoped to the guest IP **and** to the guest MAC (the beos lesson: an IP-scoped chain stops containing a guest that lands on a pool address). ESTABLISHED,RELATED → RETURN; everything else the guest starts toward labhost → DROP. |
| Guest IP | **DHCP** (`dhclient rl0`), reservation `52:54:00:52:4e:23 → 10.99.0.35`, DNS `10.99.0.2`, domain `retronet.lab`, **no default gateway** (`retronet-dhcp` withholds option 3, so the addressing itself is Lock 1). |
| Seamless web | DNS = `10.99.0.2` via DHCP + **no proxy** → any name resolves to the gateway and its `:80` origin serves the corpus by `Host`. Konqueror 3.3.2 is HTTP/1.1 and sends `Host:`, so it uses the origin door, not `:3128`. |
| ICQ | Kopete **0.9.1** (from `kdenetwork-3.3.2`), UIN **`17800`**, gateway `10.99.0.2:5190`. Account exists and is open; the client is installed but **not yet configured or signed in**. |

## The ICQ client — why Kopete, and how it got onto the disk

The 4.11 `disc1-kde` ISO carries `kde-lite-3.3.2` and its friends but **no
`kdenetwork`** (checked with `isoinfo -R -f` over `/packages/All/`: 192 packages,
none of them `kdenetwork`, `gaim`, `licq` or `centericq`). The FreeBSD archive
still serves the full 4.11 package set, and `kdenetwork-3.3.2.tgz` installs
against the already-installed KDE 3.3.2 with only **two** missing dependencies —
`openslp-1.0.11_1` and `qca-tls-1.0_1`. That is Kopete 0.9.1, a native KDE
desktop application with an OSCAR (ICQ) plugin: the right shape for the exhibit,
where the alternatives (`gaim-1.1.1`, `centericq-4.13.0`, `licq-1.3.0`) would
have dragged in a GTK2 stack or put a terminal client on a KDE desktop.

Getting the bits in needed no exec channel and no new door. A one-shot caching
mirror of the archive ran on labhost (`/data/vms/sandbox/freebsd411-rn/pkgmirror.py`,
bring-up tooling, not shipped) and the guest ran:

```sh
sh -c 'PACKAGESITE=http://10.99.0.1:8112/All/ pkg_add -r kdenetwork-3.3.2'
```

**This required a temporary hole in the guard chain** —
`iptables -I FREEBSD411RN-IN 1 -p tcp -d 10.99.0.1 --dport 8112 -j RETURN` — which
**must be removed** before the station is called done. It is not in
`rn-tapnet.sh` and does not survive a `rn-tapnet.sh up`, which rebuilds the chain
from empty.

## Open — what the next pass must finish

1. **Kopete**: create the ICQ account (UIN `17800`, password
   `registry/local.env RETRONET_ICQ_FREEBSD411_PASS`, server `10.99.0.2:5190`),
   auto-connect on start, autostart from `/root/.kde/Autostart/`, and prove the
   contact list shows **HiveBot** by name. Kopete 0.9's OSCAR plugin reads the
   server-side SSI roster, so the contact should arrive from
   `seed_contacts.py ssi --apply` with nothing added by hand; if it does not,
   add UIN `10000` in the client and alias it.
2. **Roster**: `scripts/retronet/icq/roster.json` carries the row with
   `onboarded: false`. Flip it to `true` and re-run
   `seed_contacts.py ssi --apply` only once the client is proven signed in.
3. **Konqueror launcher**: a desktop icon / Kicker button pointing at
   `http://search.retronet/`, and the home page set to it.
4. **Golden**: the new NIC is a **new device set**, so the shipped `golden` is
   invalid against this launcher (rule 6). Bake a fresh one by COLD boot on the
   exact new launcher, restore-prove it, and stage it as
   `/data/gallery-guests/FREEBSD411/freebsd411.qcow2` +
   `/data/vms/streamhost/stations/freebsd411/disk.next.qcow2`. Until then the
   station must keep its current launcher and golden.
5. **Remove the port-8112 hole** and stop the mirror.
