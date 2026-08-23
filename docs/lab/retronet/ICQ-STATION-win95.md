# win95 ICQ — deferred, and why

**Status: DEFERRED.** `win95` is **on the retronet** — bridged, DHCP'd,
contained, pointer and exec re-homed onto the bridge, browsing the corpus in
IE 3.01. All of that shipped with the **web** plane and is documented in
[`WEB-STATION-win95.md`](WEB-STATION-win95.md), which is the as-built for this
station. What did **not** ship is **messaging**: the ICQ 2000b client on this
guest never opens its OSCAR connection. This doc records that blocker so the
next attempt starts where the last one stopped, and does not repeat it.

**There is no ICQ persona live on win95.** No UIN is registered, no client is
installed on the shipping golden, and `scripts/retronet/icq/roster.json` does not
list this station.

## What the network side already gives a future ICQ retry

Everything below the client is done and proven — see
[`WEB-STATION-win95.md`](WEB-STATION-win95.md) for the detail. A retry inherits:

- a real L2 link to the gateway CT `10.99.0.2` on `vmbr-rn` (tap `win95rn0`),
  carrying ICMP, UDP and multi-connection TCP — everything slirp's
  single-connection guestfwd could not;
- **DHCP** (`10.99.0.13`, DNS = the gateway, no router option), a unique MAC (`RN_WIN95_MAC`, fleet scheme
  `52:54:00:52:4e:<last-IP-octet>`) baked cold into the golden;
- containment via the fail-closed `WIN95RN-IN` guard chain and no default route;
- the **warpnet pointer agent re-homed onto the bridge** (`10.99.0.13:7777`) and
  a second warpnet build for **exec** (`C:\WARPX.EXE`, `10.99.0.13:7788`).

The OSCAR door itself is up: `rn-tool.py login 10.99.0.2 5190 …` authenticates
and BOS advertises `10.99.0.2:5190`.

## The blocker: ICQ 2000b never reaches `connect()`

Driven to *Existing User → UIN → Next* (and, separately, *New ICQ#*), the client
sits at **"Registering User"** and emits **zero** packets toward the gateway — no
SYN to `10.99.0.2:5190`, no DNS query, no ARP beyond ambient NetBIOS.
`tcpdump -ni win95rn0 ether host "$RN_WIN95_MAC" and host 10.99.0.2` captures
nothing; the gateway's `/session` never shows the UIN.

It is **not** network, config or credentials — each was independently proven:

- **L2 works both ways:** gateway ↔ guest ping, 0% loss.
- **Guest outbound TCP works:** IE reaches the gateway's `:80` corpus.
- **`DefaultPrefs` is right:** `HKCU\Software\Mirabilis\ICQ\DefaultPrefs`
  "Default Server Host"=`10.99.0.2`, "Default Server Port"=`dword:00001446` (5190).
- **The persona authenticates** from a host-side client against the same server.

So the failure is inside the client's own connection thread.

## The runtime theory is exhausted — and it damaged the golden

The obvious cause was the 2000-era runtime a 2000-era client assumes and bare
Win95 OSR2.5 lacks (win98se/win2000/nt4 ship it). The **full win98se-equivalent
stack** was installed, in order, each sourced from the lab's archival sources and
recorded in [`ASSETS-MANIFEST.md`](../ASSETS-MANIFEST.md):

1. **Common Controls 5.80** (`50comupd.exe`) — without it the ICQ installer
   aborts outright; after it, ICQ 2000b installs cleanly.
2. **Winsock 2** (`w95ws2setup.exe`) — base Win95 has only Winsock 1.1.
3. **DCOM95 1.3** (`C:\IE55SP2\DCOM95.EXE`, already staged on the golden).
4. **Internet Explorer 5.5 SP2** (full offline installer, 78 CABs).

The zero-packet symptom was **identical after every one** — unsurprising in
hindsight for step 4, since the OSCAR socket is raw Winsock 2 and architecturally
independent of IE's WinInet.

**Step 4 also made the golden unfit as an exhibit**, which is the second reason
this line is closed: IE 5.5 SP2 adds a multi-minute first-boot finalization, a
**network-login prompt on every boot** (the shell and `WIN.INI load=` — hence both
warpnet agents — only start *after* it), and a modernised desktop. Even a working
ICQ would not be worth that. **Do not install IE 5.5 SP2 on this station.**

## Where a retry should start

In rough order of promise, and none of them is "install more runtime":

- **Build the golden the win98se way** — a base with the client **pre-installed
  and pre-configured**, rather than a bare OSR2.5 golden retrofitted, so the
  client's runtime is native and the desktop stays period-clean.
- **Move to ICQ 2001b**, which the Windows fleet has since standardised on
  ([`ICQ-STATION-win2000.md`](ICQ-STATION-win2000.md)): it is the first generation
  with a **server-stored SSI roster** (no client-UI seeding, no golden recapture)
  and it **self-reconnects** after a `loadvm` wake, retiring the per-station nudge
  entirely. It is a different client binary, so the 2000b connection-thread
  blocker may simply not apply.
- **Client-side debugging on the preserved WIP disk** — ICQ 2000b's own
  Preferences → Connections proxy/firewall setting, a clean reinstall, or diffing
  the working win98se ICQ registry against win95's.

**Preserved bring-up disk** (comctl32 5.80 + Winsock 2 + DCOM95 + IE 5.5 SP2 +
ICQ 2000b installed, static `10.99.0.13`, both warpnet agents baked, **no**
`golden` snapshot):
`/data/gallery-guests/Win95/win95-golden-retronet-wip-20260821.qcow2`. It carries
the IE 5.5 damage, so it is a **laboratory for the client question only** — never
the basis of a shipping golden.

**Not in the repo:** the earlier attempt's `win95-icq-nudge.{py,service,timer}`
(a labhost timer that spoofed the gateway's RST to heal 2000b's zombie socket)
were written on branch `rn-win95` and deliberately **not landed** — ICQ 2001b
self-heals, so the fleet is retiring that mechanism rather than adding to it.
