# tru64 ICQ station (Gaim / OSCAR) — the es40 bridge as-built

**Status: LIVE.** `tru64` (Tru64 UNIX 5.1B on the **es40** AlphaServer ES40
emulator, CDE) is the **second non-Windows** station on the retronet OSCAR
gateway and the **first es40** one — so its networking differs from every other
ICQ station. It runs **Gaim 0.59.9** (the last GTK+1.2 release of the client
that became Pidgin), built on the guest with the native Compaq C compiler, as a
**real desktop application on the CDE desktop**: a GTK buddy list and GTK
conversation windows managed by `dtwm`, not a terminal program in a `dtterm`.
It auto-signs-in as UIN `64000` over the guest's `dec21143` NIC, homed on the
retronet bridge `vmbr-rn`. Open the station and — after Gaim's own reconnect
fires on wake — the greeter bot (UIN `10000`, **HiveBot**) messages it, and the
message opens a chat window on the desktop. Parents:
[`ICQ-ONBOARDING-PLAN.md`](ICQ-ONBOARDING-PLAN.md) (Tier C),
[`ICQ-STATION.md`](ICQ-STATION.md) (the win98se pathfinder — the containment
model is shared), [`GATEWAY.md`](GATEWAY.md), [`BOT.md`](BOT.md), and the guest
itself, [`docs/guests/tru64.md`](../../guests/tru64.md).

## What is different here: es40, not QEMU

Every other ICQ station is a QEMU guest whose NIC is a **tap** attached straight
to `vmbr-rn`. tru64 runs on es40, which has **no tap backend** — it captures a
host interface with **libpcap** (`es40.cfg`:
`dec21143 { type = "pcap"; adapter = "tru64-g"; ... }`). So the host side is a
**veth PAIR**, not a tap:

    guest  <- es40 pcap ->  tru64-g  <== veth ==>  tru64-h  -> vmbr-rn (bridge)

es40 opens the **guest end** `tru64-g` with pcap; `rn-tapnet.sh` enslaves the
**host end** `tru64-h` to `vmbr-rn`. Frames the guest sends egress `tru64-g` ->
ingress `tru64-h` -> the bridge forwards them to the gateway CT's `veth951i0`;
frames for the guest's MAC leave the bridge on `tru64-h` -> `tru64-g` -> es40's
pcap -> the guest. That is the same real L2-to-the-gateway a tap gives the QEMU
guests (working UDP + ICMP + multi-connection TCP for OSCAR), reached by a
different backend. veth TX/RX checksum offload is disabled on **both** ends
(`ethtool -K`), or es40's pcap reads locally-originated frames as corrupt.

**This station used to be the one with real internet.** Before the swap the same
`dec21143` was NAT'd outbound (`172.31.66.0/30` MASQUERADE, the exhibit was a
2003 UNIX browsing the live web). The retronet swap **dropped the WAN path**:
`rn-tapnet.sh up` tears down the `/30` address on `tru64-h` and the MASQUERADE
rule, re-homes `tru64-h` onto `vmbr-rn`, and installs the fail-closed guard
chain. There is no route off the retronet any more.

## The wiring, at a glance

| | |
|---|---|
| NIC | `pci0.4 = dec21143 { type = "pcap"; adapter = "tru64-g"; mac = "52:54:00:52:4e:0f"; ... }` in `assets/tru64/es40.cfg` — **unchanged device**; only the `mac` was added and the host end re-homed |
| Host link | veth `tru64-g` (pcap/guest end) `<==>` `tru64-h` (bridge-port end, enslaved to `vmbr-rn`), created + guarded by `streamhost/stations/tru64/rn-tapnet.sh up` from the launcher on every start |
| Guest IP | **DHCP — reserved `10.99.0.15/24`, DNS `10.99.0.2`, NO default route** — `rcmgr set IFCONFIG_0 DYNAMIC` makes `/sbin/init.d/inet` run the Tru64 DHCP client (`joinc` + `dhcpconf`); `retronet-dhcp` reserves `10.99.0.15` on MAC `52:54:00:52:4e:0f` and hands out DNS `10.99.0.2` + domain `retronet.lab` with **no option-3 router** (containment Lock 1). `/etc/hosts` maps `10.99.0.15 tru64`, `/etc/svc.conf` = `hosts=local,bind`. See §DHCP below |
| MAC | **`52:54:00:52:4e:0f`** — the fleet scheme (`52:54:00:52:4e:<last-IP-octet>`, `.15` -> `0f`). Set in `es40.cfg` and **baked by a cold boot** (see below) |
| OSCAR server | gateway CT `10.99.0.2:5190` (the labhost door; advertises BOS `10.99.0.2:5190`, routable from the guest over the bridge) |
| Persona / bot | UIN `64000` (tru64) / UIN `10000` (HiveBot); passwords in `registry/local.env` `RETRONET_ICQ_TRU64_PASS` / `RETRONET_ICQ_BOT_PASS` |
| ICQ client | **Gaim 0.59.9** (`/usr/local/bin/gaim`, 2 886 400 bytes), config `/home/guest/.gaimrc`, buddy-list cache `/home/guest/.gaim/64000.3.blist`. A **GTK+1.2 desktop app under `dtwm`** — buddy list and conversation windows are real X toplevels. **The contact list is the server-side SSI/feedbag roster**, which this build downloads at sign-on and renders by nickname. See §SSI contacts |
| Exec | `labctl exec tru64 "<cmd>"` rides the emulated **com2 serial line** (`serial-exec.sock`), **not** the NIC (docs/guests/tru64.md). Rehoming the network never touches the exec channel — the whole reconfigure + build was driven over serial |

## The MAC — configurable in es40, baked by a cold boot

es40 is NOT the fleet-scheme exception. The fork's `DEC21143.cpp` reads a `mac`
config knob (`myCfg->get_text_value("mac")`, `xx:xx:xx:xx:xx:xx`; a malformed
value is a hard `FAILURE`), defaulting to `08-00-2B-E5-40-<nic#>` if absent. So
`mac = "52:54:00:52:4e:0f"` in the `dec21143` block is all it takes to assign
one.

But the MAC lives in the es40 **savestate**: `struct SNIC_state` carries
`u8 mac[6]`, and `SaveState`/`RestoreState` `fwrite`/`fread` the whole struct —
so restoring the checkpoint restores the **old** MAC regardless of `es40.cfg`,
exactly like `loadvm` on the QEMU stations. The new MAC therefore had to be
**baked by a cold boot**, then re-captured. Proven in-guest: `netstat -in` shows
`tu0 <Link> 52:54:0:52:4e:f` (Tru64 prints octets without leading zeros).

## DHCP — a reserved lease, DNS from the lease, no default route

The guest joins the retronet on **DHCP**, not a hand-set static address.
`rcmgr set IFCONFIG_0 DYNAMIC` makes `/sbin/init.d/inet` run the Tru64 DHCP
client on `tu0`: it brings the device up on `0.0.0.0 broadcast
255.255.255.255`, starts `joinc`, and `dhcpconf -w 60 tu0 start` requests the
lease. The gateway's `retronet-dhcp` answers from a **per-MAC reservation**
(`registry/local.env` `RETRONET_DHCP_RESERVATIONS`,
`52:54:00:52:4e:0f=10.99.0.15`), so the guest keeps the SAME `10.99.0.15` the
guard chain (`TRU64RN-IN`) and the serial exec channel already assume. The reply
carries the mask, DNS `10.99.0.2`, domain `retronet.lab`, and — deliberately —
**no option 3 (router)**, so the guest gets no default route (containment Lock
1, enforced by the *addressing*).

- **The resolver.** Tru64's `joinc` does NOT rewrite `/etc/resolv.conf` from the
  lease here (proven: a wrong `nameserver` re-leased stayed wrong;
  `.resolv.conf.dhcp.saved`/`.dynamic` never appear). The lease DOES carry the
  DNS + domain, so the resolver is pinned to the DHCP-supplied values:
  `/etc/resolv.conf` = `nameserver 10.99.0.2` + `domain retronet.lab`, with
  `hosts=local,bind` in `/etc/svc.conf` (Tru64 will not consult DNS without that
  switch). This is what makes the **seamless web** work: `httpfetch spacejam.com
  / out 80` resolves to `10.99.0.2` and the `:80` origin serves the corpus
  (re-verified 2026-08-22, 470 bytes of the Space Jam index). Full addressing
  plane: [`WEB-PROXY.md`](WEB-PROXY.md).
- **The two `default default` route artifacts.** Tru64's DHCP bootstrap
  (`ifconfig tu0 0.0.0.0 broadcast 255.255.255.255`) leaves two link-scope
  `default`/`default` entries on `tu0` (a net + a host route, **no gateway**),
  even on a clean boot. They are not a path off-subnet, but they are deleted
  before the golden is baked so the exhibit shows a clean "no default route"
  table: `route -n delete -net 0.0.0.0 -netmask 0.0.0.0` then `route -n delete
  -host 0.0.0.0`. **Do NOT** use `ifconfig tu0 0.0.0.0 delete` to drop the
  bootstrap address — it deletes BOTH `0.0.0.0` and the leased `10.99.0.15`; the
  boot path itself removes it with `ifconfig tu0 -alias 0.0.0.0`.
- **Restore vs boot.** The exhibit **restores** the checkpoint (a RAM snapshot)
  that already holds `tu0 = 10.99.0.15` + the clean route table — restore does
  NOT re-run DHCP, so it stays instant and the artifacts never reappear on the
  hot path. Only a **cold boot** re-runs the DHCP client.

## Gaim 0.59.9 — why this version, and why it needed a patch

The requirement is a **desktop-integrated GUI client** that still keeps the
fleet's **server-side SSI/feedbag** contact list. Those two pull in opposite
directions on this machine:

- Gaim **0.60 and later** have SSI for ICQ, but are **100% GTK+2**. There is no
  GTK+2 for Tru64/Alpha, and building that stack from source with a vendor C89
  compiler was judged out of proportion.
- Gaim **0.59.9** (March 2003) is the **last GTK+1.2 release**, and GTK+1.2 *is*
  obtainable for this machine (below). But stock 0.59.9 **explicitly refuses to
  use SSI on ICQ accounts.**

The shipped answer is 0.59.9 **plus a patch that removes that refusal**:
`streamhost/stations/tru64/gaim-0.59.9-icq-ssi.patch`, applied to the source
before it reaches the guest (so the guest needs no `patch` binary). This follows
the precedent of `climm-0.6.4-ssi-login.patch` — keep the patch as a file in the
station dir, reference the archived tarball, and record the reasoning.

Source tarball: `gaim-0.59.9.tar.gz`, 2 126 466 bytes, sha256
`268b630bfab1096b1cff4e02c97ea6bb2bf22b3be387d3c222cfe0453c86dbd8`, GPLv2,
staged in the content-addressed media archive at that hash
(`docs/lab/ASSETS-MANIFEST.md`).

### What the patch changes, and why each part is load-bearing

**1 + 2. The ICQ gate on SSI, both halves.** Stock 0.59.9 decides ICQ-vs-AIM by
`isdigit(*user->username)` (oscar.c ~490) — our numeric UIN `64000` sets
`odata->icq = TRUE`. Two places then skip SSI for exactly that case: the
*request* in `gaim_bosrights()` (`if (!odata->icq) { aim_ssi_reqrights();
aim_ssi_reqdata(); }`) and the *parse* in `gaim_ssi_parselist()`
(`if (odata->icq) return 1;`). Both are removed. It is a client-side historical
assumption from 2003, not a server limitation: **our gateway serves the feedbag
to an ICQ-flagged UIN perfectly well** — proven live, see §SSI contacts.

**3. The nickname TLV.** With the gate gone, the roster arrives but every
contact renders as a **bare UIN**, because 0.59.9 never reads the buddy item's
display-name TLV — it calls `add_buddy(gc, group, curitem->name, 0)` with a NULL
alias. The gateway stores the fleet nickname in TLV **`0x0131`** (`rn-tool.py
ssi-seed` writes it; `rn-tool.py buddies` reads it back). The patch adds a small
exported accessor `aim_ssi_getalias()` in `ssi.c` and passes its result as the
`show` field, so the list renders **HiveBot / win98se / win2000 / nt4 /
solaris** instead of five numbers. Without this part, requirement "contacts by
name" fails even though SSI itself works.

**4. Auto-reconnect, moved into the core.** Gaim 0.59.9 ships auto-reconnect
**only as a plugin** (`plugins/autorecon.c`, a dlopen'd GModule). This build is
`--disable-plugins` (one static binary is a smaller thing to keep working here
than a module loader), so that behaviour would simply be absent — and it is what
makes the exhibit self-healing. The logic is ported into `multi.c` instead, with
two deliberate corrections to the original:
- `GPOINTER_TO_INT`/`GINT_TO_POINTER` instead of the plugin's `(int)` casts —
  this is an **LP64** machine and casting a `gpointer` through `int` truncates.
- `MIN`, not the plugin's `MAX`, when doubling the delay: `MAX(2*del, MAXTIME)`
  jumps straight to the ceiling on the first retry, which is not a backoff.
  Retries now run 2 s, 4 s, 8 s … capped at 60 s, and reset once online.

**5. The buddy list came back in the corner on every wake.** `move_blist_window()`
stores the window's **absolute** position into `blist_pos.xoff`/`yoff` on a
size-configure event (it literally assigns `xoff = x; yoff = y`), so those
fields are not the frame offsets the placement code assumes. The create path
then does `set_uposition(blist_pos.x - blist_pos.xoff, blist_pos.y -
blist_pos.yoff)`, which is **(0,0)** as soon as a size event has landed at the
same place as the last position event. That bites this exhibit specifically:
every wake reconnect signs off (destroying the buddy list) and signs back on
(recreating it here), so the composed layout collapsed into the top-left corner
on **every** wake. The patch places the window at the saved position directly.

**6. No login prompt on an unattended exhibit.** A reconnect that does not
succeed on its first attempt is normal — the veth and the gateway may not be
ready the instant a restored guest resumes. Stock Gaim treats that like a user
sitting at the machine: it raises a **"Connection Error"** dialog and then the
**Gaim Login window, with the account's password already filled in**, and both
stay on the desktop forever because nothing is there to dismiss them. Observed
exactly once on a real wake, and it survives every subsequent successful
reconnect, so the exhibit ends up showing a password box next to a working
buddy list. The patch records that the account has been online at least once
(`rn_have_been_online`) and, while a drop is reconnectable (`!gc->wants_to_die`),
suppresses both the dialog and the login window — the auto-reconnect is what
brings the persona back, and it needs no UI. An explicit sign-off still shows
them.

## The build — on the guest, against a Freeware-CD GTK+ 1.2.8

### The toolkit came off the CD as RPM payloads, never as a package install

GTK+1.2/glib1.2 for this machine are on the HP/Compaq **"Open Source Software
Collection for Tru64 UNIX v5.1" Disc 5** — archive.org item `compaqtru64unix51`,
file `AG-RHAYC-BS.iso`, 629 368 832 bytes, sha1
`e153fb36c595575ce5c3013e3c3610eec7c131bc` (verified on download). The disc is
**archived** — media archive sha256
`1f3cc0f79f902a0776c959b43a3d2b6f039b50a309b3fb16d1d3e2a56c8f21ce` — so this
build never depends on archive.org still serving it.

The disc is **RPM, not `setld`**, and its own README says every package installs
under **`/usr/local`** and warns that RPM on Tru64 is unsupported and can
clobber files outside its database. So no package manager was ever run on the
guest. The three payloads — `glib-1.2.8`, `gtk+-1.2.8`, `gettext-0.10` (all
`-3.alpha`) — were extracted **on labhost** and delivered as one plain
`usr/local`-rooted tarball. These are RPM 3.0 with a gzipped SVR4 cpio payload
that modern `rpm2cpio` will not read; the gzip member was located by magic
number and inflated directly. The guest's `/usr/local` was checked for
collisions first and had **none** (it held only `bin`, `etc`, `share` from the
earlier climm/Lynx builds — no `lib`, no `include`). There is no RPM database on
this guest and none was created.

Result on the guest: `gtk-config --cflags --libs` answers
`-I/usr/local/lib/glib/include -I/usr/local/include` /
`-L/usr/local/lib -lgtk -lgdk -lgmodule -lglib -lXext -lXext -lX11 -ldnet_stub -lm`.

### Configure and make

Same shape as the climm and Lynx builds already proven here: `/bin/sh` on Tru64
is the legacy Bourne shell and dies on a modern `configure`, so
`CONFIG_SHELL=/bin/ksh` is mandatory, and the compiler is the native **Compaq C
V6.5-011** (`/usr/bin/cc`) — there is still no gcc on this station, and Disc 5's
gcc was never needed.

```
PATH=/usr/local/bin:$PATH LD_LIBRARY_PATH=/usr/local/lib \
CONFIG_SHELL=/bin/ksh CC=/usr/bin/cc /bin/ksh ./configure \
  --prefix=/usr/local \
  --disable-prpls --disable-plugins --disable-perl --disable-gnome \
  --disable-pixbuf --disable-esd --disable-artsc --disable-nls \
  --disable-screensaver
make LIBS="-liconv" && make install     # see the iconv note below
```

- **`--disable-prpls`** links the OSCAR protocol into the binary instead of
  building it as a loadable module.
- **`--disable-plugins`** is why auto-reconnect had to move into the core
  (patch part 4).
- Both toolkit probes passed on the vendor compiler with no fallback:
  `checking for GLIB - version >= 1.2.5... yes`,
  `checking for GTK - version >= 1.2.5... yes` — Compaq C compiled **and ran**
  the GTK/glib test programs.

**`configure` takes ~100 minutes** on the emulated Alpha (~300 autoconf probes at
15-20 s each; climm's took ~35 min). Run it **detached with a log and polled** —
a `labctl exec` that outlives its timeout strands the serial line.

### Three build traps, all of which cost real time here

- **The link fails on `iconv_open` / `iconv` / `iconv_close`.** Tru64 keeps
  iconv in **`/usr/shlib/libiconv.so`**, not libc, and gaim's configure detects
  `iconv` without recording a library for it. The fix is `-liconv` — but
  **Tru64's `make` does not propagate a command-line `LIBS=` override into the
  recursive sub-make**, so `make LIBS="-liconv"` at the top level silently
  changes nothing. It has to reach `src/Makefile`'s own `LIBS` line (or be set
  as `LIBS=-liconv` in the environment *before* `configure`, which is the
  cleaner recipe if you are starting over).
- **Source files authored off-box carry future mtimes.** This guest's clock is
  period-correct **2003**; files edited on labhost arrive dated **2026**. `make`
  then sees them as eternally newer than every object that depends on them and
  rebuilds the whole tree on *every* invocation — which looked exactly like a
  build that would not converge. `touch` the delivered files after copying them
  in.
- **Poll the serial line from ONE place.** Several concurrent pollers each
  opening `labctl exec` collide on the station's single `serial-exec.sock` and
  it starts answering `Resource temporarily unavailable`. It recovers on its own
  once the extra pollers stop, but while it lasts it is indistinguishable from a
  wedged guest.

Gaim itself **runs on the CDE desktop, never through the exec channel** — it is
a long-lived GUI program and would wedge the fire-and-forget serial relay.

## The fixture and the composed desktop

The exhibit autologs in the unprivileged `guest` (uid 300); Gaim runs in that
session with its config under `/home/guest/`.

`/etc/dt/config/Xsession.d/9999.icq-fixture` (reference copy
`streamhost/stations/tru64/9999.icq-fixture`) exports
`LD_LIBRARY_PATH=/usr/local/lib` — Tru64's loader will not find the Disc-5
shared libraries otherwise, and a CDE `Xsession.d` script inherits almost
nothing — and launches **`/usr/local/bin/cmaphold &` then `/usr/local/bin/gaim
&`** (cmaphold first, so the colormap anchor cells exist before Gaim allocates —
see §window chrome). This is the **cold-boot fallback path only**: on the normal
checkpoint-restore path both cmaphold and Gaim are already running inside the
baked RAM snapshot and `Xsession.d` does not run, so it cannot double-launch.
The previous climm fixture is kept on the guest as `9999.icq-fixture.bak-climm`.

**Silent sign-in** comes from `/home/guest/.gaimrc`, hand-authored to the exact
byte layout `gaimrc.c` writes (the parser is tab-exact — it compares against
literal `"\t\t}"`). The account block is:

```
users {
	user {
		ident { 64000 } { <RETRONET_ICQ_TRU64_PASS> }
		user_info {
		}
		user_opts { 5 } { 1 }
		proto_opts { 10.99.0.2 } { 5190 } {  } {  } {  } {  } {  }
		iconfile {  }
		alias {  }
	}
}
```

- `user_opts { 5 }` = `OPT_USR_AUTO | OPT_USR_REM_PASS` — gaim's own
  `auto_login()` connects at startup with the saved password: no login window,
  no wizard, no keystroke. `{ 1 }` is `PROTO_OSCAR`.
- `proto_opts` slots 0 and 1 are the OSCAR **Auth Host** and **Auth Port**,
  which 0.59.9 exposes as ordinary per-account fields (`oscar_user_opts()`).
  `10.99.0.2` / `5190` replaces the compiled-in `login.oscar.aol.com:5190`.
- The password is stored in plaintext, exactly as climm's `climmrc` did. Real
  value lives only in gitignored `registry/local.env`.

Four option words in the same file shape the exhibit, and each was set
deliberately:

| setting | value | why |
|---|---|---|
| `blist_pos` | `{ 952 } { 64 } { 300 } { 640 }` | pins the buddy list to the right-hand side so the station opens composed under `dtwm` instead of wherever the WM drops it. Only reliable **because** of patch part 5 |
| `conv_size` | `{ 360 } { 240 } { 40 }` | a conversation window small enough to sit beside the buddy list rather than bury it |
| `misc_options` | `8` | `OPT_MISC_COOL_LOOK` on, **`OPT_MISC_BUDDY_TICKER` off** — the default `12` opens a second "Buddy Ticker" toplevel that just clutters the desktop |
| `im_options` | `8203` | adds `OPT_IM_ALIAS_TAB`, so a chat window is titled **"HiveBot"** and not "10000" |
| `away_options` | `2` | `OPT_AWAY_AUTO` is **NOT** set, so Gaim never auto-aways. climm did, and an away persona is one the bot will not greet |

**Two prefs that bit the sibling `solaris` station do not apply here.** Gaim
0.59.9 has **no "require authorization" option and no auth-required SSI TLV at
all** — `aim_ssi_addbuddies()` predates the feature — so it cannot publish the
flag that makes the greeter blind. And 0.59.9 has **no show/hide-offline
concept**: the buddy list's "Online" tab is simply presence-filtered and the
group header carries the count (`contacts-icq8-64000 (1/5)`), so nothing has to
be toggled to keep peers visible.

## SSI contacts — the full roster comes from the server, by name

The contact list is **not** shipped in a local file. It is seeded server-side,
once, with the gateway's tool (the retronet SSI-fabric pass does this for every
station):

    pct exec 951 -- python3 /opt/ras/rn-tool.py ssi-seed 64000 \
      10000=HiveBot 98980=win98se 20000=win2000 30000=solaris 40000=nt4

With the patch in place, the patched Gaim asks for that roster on an ICQ login
and renders it by nickname. Its own debug log on first sync, verbatim:

    ssi: requesting ssi list
    ssi: syncing local list and server list
    ssi: activating server-stored buddy list
    ssi: adding buddy 20000 (win2000) to group contacts-icq8-64000 to local list
    ssi: adding buddy 30000 (solaris) to group contacts-icq8-64000 to local list
    ssi: adding buddy 40000 (nt4)     to group contacts-icq8-64000 to local list
    ssi: adding buddy 98980 (win98se) to group contacts-icq8-64000 to local list
    ssi: adding buddy 10000 (HiveBot) to group contacts-icq8-64000 to local list

`rn-tool.py buddies 64000` reads the same roster back server-side, and Gaim's
own export `/home/guest/.gaim/64000.3.blist` holds `b 20000:win2000`,
`b 30000:solaris`, `b 40000:nt4`, `b 98980:win98se`, `b 10000:HiveBot` — the
names, not the numbers.

**The `.blist` is a cache, not the source of truth.** Because SSI works, a
station added to the fleet later needs only a re-run of `ssi-seed`; the next
sign-on picks it up. There is no hand-authored contact file to maintain and no
checkpoint to re-bake for a roster change — which is the whole reason the ICQ
gate was worth patching out rather than living with a local list.

**What the buddy list shows.** The "Online" tab is presence-filtered, so it
lists the peers that are actually signed in and carries the total in the group
header. With the rest of the fleet idle it reads `contacts-icq8-64000 (1/5)`
with **HiveBot** under it; peers appear by name as their stations wake.

## Containment — re-proven from inside the guest (`10.99.0.15`), 2026-08-22

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2` (ICMP) | **3/3 replies**, 13/16/20 ms | intra-bridge L2 (the point) |
| CT `10.99.0.2:5190` (OSCAR) | **OPEN** — Gaim signed in, roster synced, bot greeted | the point |
| `spacejam.com:80` via DNS `10.99.0.2` | **470 bytes of corpus HTML** | the seamless web plane |
| labhost bridge `10.99.0.1` (ICMP) | **100% loss** | the guard chain `TRU64RN-IN` |
| internet `1.1.1.1` (ICMP) | **100% loss (unreachable)** | no default route (Lock 1) |
| route table | only on-link `10.99.0/24` + `10.99.0.15` + loopback — **no default**, no `default default` artifacts | Lock 1 |

The guard chain is not inferred — it was read back with its counters while the
pings ran, and the DROP rule had caught exactly those three packets:

    Chain TRU64RN-IN (1 references)
     pkts bytes target  prot  source        destination
        0     0 RETURN  all   0.0.0.0/0     0.0.0.0/0    ctstate RELATED,ESTABLISHED
        3   252 DROP    all   0.0.0.0/0     0.0.0.0/0
    INPUT:  3   252 TRU64RN-IN  all  --  vmbr-rn  *  10.99.0.15  0.0.0.0/0

Same three-layer model as solaris/win98se (topology -> no-default-route -> the
fail-closed `TRU64RN-IN` INPUT chain scoped to the guest IP, inserted above
`RETRONET-IN`). tru64's exec channel is **serial**, not IP, so the guest never
legitimately initiates a flow toward labhost at all; the guard's
`ESTABLISHED,RELATED RETURN` is there only to match the proven pattern, and
every NEW flow the guest starts is dropped. `rn-tapnet.sh` reads the chain back
out of the kernel and the launcher aborts (es40 never starts) if it does not
verify. Checksum offload confirmed **off on both** `tru64-g` and `tru64-h`.

## The reconnect mechanism — how "open the station" greets you

Gaim sends a keepalive every **60 s** (`server.c`, `g_timeout_add(60000, …)`).
The golden holds Gaim connected on an **ephemeral** BOS source port; by the time
a visitor wakes the station the gateway has long since dropped that session, so
the first overdue keepalive draws an error, the socket dies, and **the
core auto-reconnect from patch part 4 signs the persona straight back on** — new
port, fresh sign-on, fresh SSI sync. The bot sees the new presence and greets.
**No nudge is used or needed.**

**Measured (production restore path, 2026-08-22):**

| | |
|---|---|
| `systemctl start streamhost@tru64` | 19:40:57 |
| Gaim self-re-signed-on (gateway `presence: 64000 ONLINE`) | **19:41:33 — ~36 s** |
| HiveBot's greeting delivered (`RN_BOT_GREET_DELAY=30`) | **19:42:03 — ~66 s end-to-end** |

and it rendered on the framebuffer in a GTK chat window: `HiveBot logged in.` /
`HiveBot: hi! was it you that runs the Tru64 OS? - nice hardware.` The ~36 s is
the keepalive interval plus the 2 s first backoff, so it is bounded by design
rather than lucky. The wake must find the guest **running** (a visitor's resume,
or the operator watching a reset); a still-idle-paused guest stays frozen and
Gaim cannot fire its keepalive.

**The layout survives the reconnect** — which is the whole point of patch part
5. Forcing a sign-off/sign-on cycle (evict the session, let the keepalive notice)
and re-shooting the framebuffer shows the buddy list still pinned on the right
and the new chat window opening beside it, not a buddy list collapsed into the
corner. Verified 2026-08-22 before the golden was baked.

**A trap when you measure this yourself.** es40 exiting tears the veth down
**without a TCP FIN**, so the gateway keeps the old session **half-open** and
does not notice the station left. Restore the checkpoint within a minute or two
and the restored socket still matches that half-open session — the persona
simply stays online, nothing reconnects, and nothing gets greeted, which looks
like a broken reconnect but is the opposite. To measure the real path, make the
baked-era session genuinely gone first — signing in as the same UIN from the
gateway (`rn-tool.py login 10.99.0.2 5190 64000 <pass>`) evicts it, which is
what the numbers above were taken against.

**Two things to know when you verify a restore yourself.**

- **`labctl shot` reads `fb.shm`, which keeps the last painted frame even when
  es40 is dead.** A screenshot alone is therefore NOT proof the guest is
  running: a stale frame looks exactly like a healthy restore. Prove liveness
  with something that must round-trip through the guest — `labctl exec tru64
  "date"` — or check the emulator pid.
- **After a bake, `systemctl start` is a no-op.** The unit stays `active`
  (that is the streamhost daemon, which outlives es40), so starting it again
  changes nothing and es40 never relaunches; the symptom is the daemon looping
  on `connect/HELLO … ctl.sock … Connection refused` while `systemctl
  is-active` cheerfully says `active`. Use `systemctl restart`.

**Measured on a plain production restart (2026-08-22, the final one):**
`systemctl restart` 20:48:27 -> persona ONLINE **20:48:41 (~14 s)** -> HiveBot
greeted **20:49:11 (~44 s)**. Faster than the ~36 s reconnect above because the
gateway had already dropped the baked session, so the sign-on is a fresh one
rather than a keepalive timeout followed by a retry.

**A cosmetic nit left in place.** When a wake recreates the chat window before
the SSI roster has repopulated, `set_convo_title()` finds no buddy yet and
titles the window with the bare UIN (`10000 - Gaim`) instead of `HiveBot`; a
window opened after the roster lands is titled correctly. The buddy list itself
always renders names. Not worth another ~40-minute build cycle on the emulated
Alpha to chase.

## The window chrome — 8-bit colormap exhaustion, pinned and anchored

The es40 CDE desktop is an **8-bit PseudoColor** display: one hardware colormap,
**256 cells**, `number of colormaps: minimum 1, maximum 1` (`xdpyinfo`, root
depth 8 planes). Gaim's chat text, smileys and the white text areas allocate
fine there, but the neutral **widget-background grey** is fragile, and it failed
in a specific, cumulative way.

**The symptom (operator report, 2026-08-23).** After the station had been open a
while the Gaim window **chrome rendered solid BLACK** — every menubar, toolbar
and notebook-tab background on both the buddy list and the conversation window —
while the white text areas and the coloured chat text stayed correct. A freshly
restored golden was fine; the black only appeared after the guest had run a long
time.

**The cause.** Every wake reconnect signs Gaim off and back on, which
**destroys and recreates the buddy list** and re-syncs SSI. Each cycle leaks
roughly a full widget style's worth of colormap cells. Once the 256-cell map is
exhausted, GTK+1.2 can no longer allocate its widget grey and the fallback
resolves to the **black pixel** — so the chrome goes black. Pure exhaustion, not
a wrong colour and not a theme. **Reproduced** from a fresh restore by dropping
Gaim's OSCAR socket on the gateway to force reconnects
(`pct exec 951 -- ss -K dst 10.99.0.15 sport = 5190`): grey through ~7 cycles,
solid black by **cycle 8**, total by cycle 16.

**Why pinning the colour is not enough.** A `~/.gtkrc` that pins the widget grey
to a fixed value does **not** fix it alone: on a full colormap the allocation of
that (correct) grey still fails and still falls back to black. Proven — pinning
alone went black at the same ~8-cycle threshold.

**The fix — pin AND anchor.** Two pieces, both baked onto the checkpoint disk:

1. **`/home/guest/.gtkrc`** (reference:
   `streamhost/stations/tru64/gaim-chrome.gtkrc`) pins Gaim's widget palette to
   fixed CDE/Motif greys — `bg[NORMAL] #d7d7d7` (the stock GTK+1.2 grey this
   station shipped with) plus the ACTIVE/PRELIGHT/INSENSITIVE variants and
   fg/base/text — applied to the `GtkWidget` base class so it reaches every
   widget. Authored only while Gaim is stopped (the parser is tab-exact and Gaim
   rewrites the file on exit).

2. **`/usr/local/bin/cmaphold`** (source:
   `streamhost/stations/tru64/cmaphold.c`) is a tiny X client launched in the
   CDE session **before** Gaim. It pre-allocates the exact colours the pin names
   — the greys, the light/dark/mid shadow shades GTK derives from each bg
   (`LIGHTNESS_MULT 1.3` / `DARKNESS_MULT 0.7`; for a grey the HLS shade reduces
   to a per-channel scale, so the values are bit-exact with Gaim's), and the
   red/blue/yellow chat primaries — **read-only and shared**, then never exits.
   `XAllocColor` of an already-allocated shareable colour returns the existing
   pixel **without consuming a free cell**, so Gaim's every later
   (re)allocation of those exact rgb values succeeds even when the colormap is
   otherwise exhausted. The chrome can no longer fall back to black. It logs
   `held=19 failed=0` at start.

The pin makes Gaim request the *exact* values `cmaphold` holds (the GTK default
grey is a hair off `#d7d7d7`, so without the pin the shares miss); `cmaphold`
keeps those cells alive across Gaim's window churn. **Both are load-bearing —
either alone regresses.**

**Proven.** With both in place the same `ss -K` reconnect loop that blacked the
chrome by cycle 8 left it fully grey through **24 cycles** (3× the threshold) on
both windows, and again through a post-bake stress on the restored golden.

`cmaphold` is built on the guest (native Compaq C,
`cc -o /usr/local/bin/cmaphold cmaphold.c -lX11`). The cold-boot fixture
(`9999.icq-fixture`) launches it before Gaim; on the normal restore path both
are already running in the baked RAM.

**Residual — the leak itself is NOT fixed.** `cmaphold` makes the chrome (and
the held chat primaries) immune to exhaustion, but Gaim still leaks the rest of
a style's cells per reconnect, so over a very long unbroken run other, un-held
colours (a new smiley shade, a status icon) could still degrade. The proper
long-term fix is to stop the per-reconnect leak in Gaim (init GdkRGB once /
reuse the buddy-list style instead of re-realising it) — a source change plus a
~40-min rebuild, recorded here as follow-up. A station relaunch resets the
colormap to the golden's fresh state, so a periodic reset is the other lever.

## Golden lineage & rollback (FULL paths)

This station's "golden" is an es40 **checkpoint** (savestate + the disk it was
baked from + `rom/`), not a QEMU snapshot. See
[`docs/guests/tru64.md`](../../guests/tru64.md#checkpoint-restore).

- **LIVE checkpoint:** `assets/tru64/checkpoint/{tru64.axp,tru64.img,rom/}` —
  re-baked **2026-08-23 to add the web browser** (a CDE Front-Panel "Web" icon
  launching Netscape 4.76 on the corpus —
  [`WEB-BROWSER-tru64.md`](WEB-BROWSER-tru64.md)) on top of the window-chrome fix:
  the disk carries the browser launcher bits (`RetronetWeb.{dt,fp}`,
  `/etc/dt/config/C/sys.dtwmrc`, `/usr/local/bin/webbrowser`, guest
  `.netscape/preferences.js` homed on `http://search.retronet/`) alongside
  `/home/guest/.gtkrc` + `/usr/local/bin/cmaphold`, and the baked RAM holds
  cmaphold + Gaim with **grey** chrome, the buddy list composed top-right (HiveBot
  online by name), the greeting chat window, and the Web icon on the panel. Baked
  via the serial menu's save-and-exit (option 5), so state and disk are an atomic
  pair.
  - `tru64.axp` sha256 `030b726af4a644198741e16d9f1d1ee87fdd5827dd692508d46a6855f7debe2d` (274 641 799 bytes)
  - `tru64.img` sha256 `14730c97986a585ce2e09b267bc84f7853a2ee70c5e35611adebcc6c2de4dab1`
- **Pre-browser backup** (the window-chrome-fixed Gaim golden — the rollback for
  the browser change): `assets/tru64/checkpoint.bak-prebrowser-20260823/`,
  byte-verified against the source before anything was touched, with a
  `SHA256SUMS` beside it.
  - `tru64.axp` sha256 `622b9383e60d9c2d5be1e69b42669cf29422b8e16230b7658e78dea360304582` (273 622 947 bytes)
  - `tru64.img` sha256 `d31d820048d283199b39aa662613be249fd7c8f9320ba646d4331d2bc69bb41b`
  - **Rollback:** `systemctl stop streamhost@tru64`, copy that dir's
    `tru64.axp`/`tru64.img`/`rom` over `checkpoint/`, `systemctl start
    streamhost@tru64`.
- **Pre-chrome-fix backup** (the previous Gaim golden — the rollback for the
  chrome change): `assets/tru64/checkpoint.bak-preblackfix-20260823/`,
  byte-verified against the source before anything was touched, with a
  `SHA256SUMS` beside it. This is the golden that restores grey but degrades to
  black chrome over a long run.
  - `tru64.axp` sha256 `f2a14cdc24cdc4d8f731fc2ab974ffa4f4694d62c61951704ba8bd149ad37659` (311 419 163 bytes)
  - `tru64.img` sha256 `9cf71c95d001bdd28c9b823aa12e2158f06c80fb33fb6cd82bc716cb33881512`
  - **Rollback:** `systemctl stop streamhost@tru64`, copy that dir's
    `tru64.axp`/`tru64.img`/`rom` over `checkpoint/`, `systemctl start
    streamhost@tru64`.
- **Pre-Gaim backup** (the climm checkpoint — the rollback for the Gaim change):
  `assets/tru64/checkpoint.bak-pregaim-20260822/`, byte-verified against the
  source before anything was touched, with a `SHA256SUMS` beside it.
  - `tru64.axp` sha256 `e03aa48583a2dd6cb159586bd8e0e2f3c126748c93130f1a22e1504a670edac9`
  - `tru64.img` sha256 `70802347277b33913a25a68484d199e0743c5347c184ceb5b7e41b89be7345c0`
  - **Rollback:** `systemctl stop streamhost@tru64`, copy that dir's
    `tru64.axp`/`tru64.img`/`rom` over `checkpoint/`, `systemctl start
    streamhost@tru64`. climm 0.6.4 and its `~/.climm/` are still installed on
    the disk and `9999.icq-fixture.bak-climm` is still beside the live fixture,
    so the terminal exhibit comes back exactly as it was.
- **Pre-DHCP backup:** `assets/tru64/checkpoint.bak-predhcp-20260821/`.
- **Pre-swap backup** (the WAN/internet checkpoint):
  `assets/tru64/checkpoint.bak-prern-20260821/` — the outbound-NAT golden.
  Rollback additionally restores `es40.cfg.bak-prern-20260821`,
  `x11-runtime.sh.bak-prern-20260821` and `rn-tapnet.sh down`.

**Baking on the live station must block the daemon's relaunch.** Option 5 makes
es40 exit; the unit's `Restart=on-failure` would then relaunch it and
`rm -rf work/` (fresh reflink copy) **before** you stage `work/autosave.axp`.
Set a `Restart=no` systemd drop-in (`+ daemon-reload`) BEFORE the bake, then
copy `work/{autosave.axp,img/tru64.img,rom/}` into `checkpoint/` (temp name +
`mv`, so a running es40 never has its mapped image truncated), then remove the
drop-in and `start`. Also set `SH_IDLE_PAUSE_SECS=0` in the live `station.env`
for the working session so the guest cannot freeze mid-reconfigure, and put it
back to `60` afterwards.

## Gotchas that cost real time

- **The MAC is in the savestate** — a `mac=` change needs a **cold boot** to
  bake; a checkpoint restore brings the old MAC back.
- **Two ICQ clients on one UIN fight.** Leaving climm running while testing Gaim
  produced a perfect flapping loop — auth succeeded, the gateway evicted one
  session, the other reconnected, forever. The symptom is `major connection
  error` immediately after `BOSIP:` in gaim's `-d` log. Stop the old client
  first.
- **`gaim -d` is the whole diagnostic story.** Without `-d` the SSI trace,
  reconnect backoff and buddy-add lines are simply not printed. Launch it that
  way while working, and without it for the baked golden.
- **`.gaimrc` is parsed tab-exactly** and gaim **rewrites it on exit and on any
  pref change** — so author the file only while gaim is stopped, or the running
  client will overwrite the edits.
- **`ifconfig tu0 <new>` then `ifconfig tu0 <old> delete` can drop BOTH
  addresses.** Set the address once and delete the default route separately.
- **The serial exec line dislikes long, quote-heavy commands** — keep each
  `labctl exec` short, and never chain with `&&`.
- **Serve build inputs from the CT `10.99.0.2`, not labhost `10.99.0.1`.** The
  guard chain drops guest->labhost, so a throwaway `python3 -m http.server` on
  the CT (`10.99.0.2:8099`) is how the tarballs, the patched sources and the
  config reach the guest, via the guest's own `/usr/local/bin/httpfetch`.
- **`cmaphold` must be running before Gaim, and must never be killed.** It is the
  colormap anchor (see §window chrome); if it dies, Gaim's chrome greys are no
  longer held and the next reconnect storm will black the chrome again. It is in
  the baked RAM on the restore path and launched first by the cold-boot fixture.
  Force a Gaim reconnect for testing with
  `pct exec 951 -- ss -K dst 10.99.0.15 sport = 5190` (dropping its OSCAR socket)
  — `rn-tool.py login 64000` does **not** evict Gaim, the gateway allows the
  duplicate.
- **The buddy list drifts down-right under many rapid reconnects.** A separate,
  pre-existing cosmetic quirk (each recreate stores a frame-offset-inflated
  position); harmless at the exhibit's normal reconnect rate but visible after a
  stress loop. Reset it in `/home/guest/.gaimrc` (`blist_pos { 952 } { 64 } {
  300 } { 640 } ...`) while Gaim is stopped, then relaunch, before baking.

## Operating it

```bash
# is the persona online?
ssh lab 'pct exec 951 -- python3 -c "import urllib.request,json;d=json.loads(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read());print([s[\"screen_name\"] for s in d[\"sessions\"]])"'
# exec over the serial line (NOT the NIC)
ssh lab 'labctl exec tru64 "netstat -in | grep tu0"'
# DHCP state in the guest (leased IP + resolver)
ssh lab 'labctl exec tru64 "ifconfig tu0 | grep inet; cat /etc/resolv.conf"'
# the server-side SSI contact roster Gaim downloads (HiveBot + 4 stations)
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py buddies 64000'
# what Gaim itself cached from that roster, by name
ssh lab 'labctl exec tru64 "cat /home/guest/.gaim/64000.3.blist"'
# the veth link + guard chain
ssh lab 'bash /data/vms/streamhost/stations/tru64/rn-tapnet.sh show'
# re-bake the checkpoint: see docs/guests/tru64.md (serial IAC BREAK -> option 5)
```
