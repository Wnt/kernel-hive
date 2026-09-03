# freebsd411 on the retronet — the bridge, Konqueror, and Kopete

**Status: PARTIAL — web plane proven on the framebuffer and the station's
retronet address confirmed; ICQ plane wired, client installed, NOT yet signed
in.** `freebsd411` (FreeBSD 4.11-RELEASE i386, KDE 3.3.2 on XFree86
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
| the guest takes its **reserved** address — `ifconfig rl0` → `inet 10.99.0.35 netmask 0xffffff00`, on a cold boot of the exact new launcher set | `retronet-dhcp-10.99.0.35-20260903.png` |

What is **not yet proven**: Kopete signed in as UIN `17800`, HiveBot in the
contact list, the desktop Konqueror launcher, and the **re-baked golden** on the
new device set. See §Open.

## The wiring, at a glance

| | |
|---|---|
| NIC | **second** NIC `-device rtl8139,netdev=rn0,mac="$RN_FREEBSD411_MAC"`, backend `-netdev tap,id=rn0,ifname=freebsd411rn0,script=no,downscript=no`. FreeBSD 4.11 drives it as **`rl0`** (GENERIC). `rtl8139` and not `ne2k_pci`: the NE2000 is 16-bit PIO and under KVM that is one VM exit per word — the same trap that put this station's system disk on an `lsi53c895a` (`docs/lab/FREEBSD411-WAVE.md` §Measured facts). `rl` does real DMA. |
| slirp NIC | same device, now `-netdev user,id=n0,**restrict=on**,hostfwd=tcp:127.0.0.1:6078-10.0.2.15:6000 -device ne2k_pci,netdev=n0`, guest `ed0`. It carries **only** the x11warp pointer forward, so the pointer route is untouched and the fixture's `SH_X11WARP_DISPLAY=127.0.0.1:78` still holds. **`restrict=on` is containment, not tidiness**: without it SLIRP hands the guest a default route via `10.0.2.2` and the guest can reach whatever labhost's own stack can. `hostfwd` (host → guest) keeps working under it. It is a backend option, not a device change, but the golden is baked with the exact launcher regardless. |
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

## The pointer that works on this rig — `xclick.py` (x11warp motion + QMP button)

The rig's QMP **PS/2 relative** mouse is not accurate enough here: a click aimed
at a dialog field landed on the root window. The route that does work is the one
the daemon itself uses on the live station — **XWarpPointer for motion over the
loopback X forward, QMP for the button**:

```
python3 scripts/dev/x11ptr.py 127.0.0.1 <the rig's X forward port> X,Y q
```

then a **button-only** QMP `input-send-event` (`btn` left, down then up, **no
motion**) — the click lands wherever X thinks the pointer is. Mechanically it is
the X connection-setup handshake (the same one `x11warp-check.sh` does), the
**root window id** read out of the setup reply, `WarpPointer` (opcode 41) with
`dst-window = root` so the coordinates are absolute, and a `GetInputFocus`
round-trip as a barrier before the button. Every menu click in this doc was made
that way, first try. It is the only reliable pointer this station has outside
the daemon, and it is the same route the pcbsd-rn wave used.

## The two traps that cost this bring-up its ICQ half

**KWallet.** Kopete's first connect pops the **KDE Wallet first-use wizard**,
and on the first attempt it opened *behind* the Configure dialog — so Kopete
looked "hung" (KWin offered to kill it, PID 222) and the account that had been
typed into the wizard was **lost**. Confirmed by the pcbsd-rn wave: Kopete
ignores `kwalletrc [Wallet] Enabled=false`, and **cancelling** the wallet wizard
silently drops the password. The fix is to run that wizard through to its
*Password Selection* page and **Finish with "Yes, I wish to use the KDE wallet"
UNCHECKED**; Kopete then prompts once for the password and "Remember password"
lands it in `kopeterc`.

**`qmp-type.py` eats backslash escapes.** Typing `printf "%s\n"` into the guest
put a literal `n` in the file the first time and pressed **Enter** the second —
so `kopeterc`, the desktop launcher and the autostart file were all written as
one broken line, and the account was invisible to Kopete. `\012` is eaten too.
**Write multi-line files with a `{ echo …; echo …; } > file` group, never with
`printf` escapes**, and remember root's shell is **csh**: wrap everything in
`sh -c '…'` (no single quotes inside).

## Driving Kopete's Add-Account wizard by keyboard — the map, measured

There is no exec channel and the station's pointer is x11warp (the rig's QMP
PS/2 relative mouse is **not** accurate enough — a click aimed at the UIN field
landed on the root window and took focus off the dialog). So the wizard is
driven by **keys only**, and its focus chain is not what you would guess. This
is the measured route, from `kopete` started with no config:

1. Kopete opens **Configure - Kopete** on the *Appearance* page. `up` selects
   **Accounts** in the left icon list.
2. `alt-n` → **New...** → the Add Account Wizard. `ret` → Step One.
3. Step One's protocol list does **not** have focus: `shift-tab` moves into it
   and selects the LAST row (Yahoo). The order is AIM, Gadu-Gadu, ICQ, IRC,
   Jabber, MSN, SMS, Yahoo — so `up up up up up` reaches **ICQ**. `alt-n` → Step Two.
4. Step Two, "ICQ Account Settings": `alt-p` ticks **Remember password** *and
   leaves focus on that checkbox*; `alt-s` ticks **Connect automatically at
   startup**; `alt-w` focuses **Password**.
5. **The UIN field is reachable only as `shift-tab` FROM the Remember-password
   checkbox** — and only when focus is actually on that checkbox. `tab tab` from
   the UIN field skips Password and lands on the Connect checkbox, so a password
   typed after tabbing goes nowhere visible. Every wasted cycle in the first
   attempt was this. Verify each field by frame: the UIN shows its digits, the
   password shows one asterisk per character (8 for this account).
6. A line edit does **not** select-all on focus and `ctrl-a` does not select-all
   either (it moves to the start), so clearing a field is `end` + N × `backspace`.

**The server is not set in the wizard and does not need to be:** `retronet-dns`
answers `login.icq.com` with `10.99.0.2`, so Kopete's shipped default host
reaches the gateway. Set the literal `10.99.0.2:5190` on the *Account
Preferences* tab only if the hijack proves flaky.

**Where the third window ended:** `kopeterc` now carries a correct, multi-line
`[Account_ICQProtocol_17800]` group (`AccountId`, `Protocol=ICQProtocol`,
`Server=10.99.0.2`, `Port=5190`, `RequireAuth=false`, `AutoConnect=true`,
`RememberPassword=true`) next to the `[Plugins] kopete_icqEnabled=true` the
wizard had already written, and Kopete starts and reads it — but **it has never
opened a socket to the gateway**: no `17800` line has ever appeared in
`retronet-oscar`'s journal. The missing piece is the **password**, which is what
the KWallet dance above is for. Frames
`retronet-kopeterc-and-desktop-launcher-20260903.png` (the file, and the desktop
launcher) and `retronet-kopete-running-not-connected-20260903.png`.

**Where the second window ended:** the wizard was filled correctly (UIN `17800`,
8-character password, both boxes ticked — frame `retronet-kopete-wizard-filled-20260903.png`)
and then `alt-n`/`alt-f` closed it **without the account appearing in the
Accounts list**, and no `17800` login reached the gateway. The Finish step is the
one part of the route still unmapped: the wizard's buttons sit below the visible
1024x768 frame, so the next pass should **move or resize the wizard window first**
(`alt-F3` → Move, or shrink the Configure dialog) so Back/Next/Finish are visible
and can be confirmed by frame instead of guessed at by accelerator.

## Server-side state that is already done

`rn-tool.py ssi-seed 17800 10000=HiveBot` has been run: `buddies 17800` returns
`10000 HiveBot`, so the account's server-side roster is populated and an
SSI-aware client gets HiveBot **by name** on its first login with nothing added
by hand. The fleet-wide cross-list (`seed_contacts.py ssi --apply`) has **not**
been run and the roster row stays `onboarded: false`, so no other station lists
freebsd411 yet.

## Open — what the next pass must finish

1. **Kopete**: finish the wizard (see the keyboard map above — make the wizard's
   buttons visible first), confirm the account appears in the Accounts list,
   prove a `17800` login in the gateway journal, and prove **HiveBot** by name in
   the contact list on the framebuffer. Then autostart it from
   `/root/.kde/Autostart/kopete.desktop` and confirm it reconnects silently after
   a `loadvm` wake (the win98se lesson: a restored socket is stale, so the client
   must heal itself or the exhibit shows a signed-out client).
2. **Roster**: `scripts/retronet/icq/roster.json` carries the row with
   `onboarded: false`. Flip it to `true` and run `seed_contacts.py ssi --apply`
   only once the client is proven signed in.
3. **Konqueror launcher**: a desktop icon / Kicker button pointing at
   `http://search.retronet/`, and the home page set to it.
4. **Golden**: the new NIC is a **new device set**, so the shipped `golden` is
   invalid against this launcher (rule 6). Bake a fresh one by COLD boot on the
   exact new launcher, restore-prove it, and stage it as
   `/data/gallery-guests/FREEBSD411/freebsd411.qcow2` +
   `/data/vms/streamhost/stations/freebsd411/disk.next.qcow2`. Until then the
   station must keep its current launcher and golden.
5. **Remove the port-8112 hole** and stop the mirror.
