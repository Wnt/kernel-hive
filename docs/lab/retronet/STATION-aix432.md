# aix432 on the retronet — the web plane, and the fleet's first PReP/PowerPC guest

**Status: CONFIGURED, NOT YET VERIFIED.** `aix432` — IBM AIX 4.3.3 on an
emulated RS/6000 7020 (40p) — is *allocated* a place on the retronet bridge
`vmbr-rn` at **10.99.0.28**, statically addressed, on the persistent tap
**`aixrn0`**, and its period browser is **Netscape Communicator 4.08 for AIX**,
installed from the 4.3.2 Bonus Pack and proven to render on the emulated
GXT130P. Nothing on this page is a measurement yet: every line below is either
*claimed by the registry* or *what the bring-up must prove*, and each is
labelled. Do not quote it as evidence.

**Web plane only. No ICQ, deliberately:** there is no OSCAR/ICQ client for
AIX 4.3/PowerPC in this lab, so the station declares `planes: ["web"]` and has
**no** row in [`../../../scripts/retronet/icq/roster.json`](../../../scripts/retronet/icq/roster.json).
The registry gate checks that in both directions — declaring `icq` without a
persona fails validation, and so does an onboarded persona without the plane.

Parents: [`../RETRONET-BRIEF.md`](../RETRONET-BRIEF.md) §4 (the web plane),
[`GATEWAY.md`](GATEWAY.md) (the CT and its two containment locks),
[`WEB-STATION-irix.md`](WEB-STATION-irix.md) (the closest analogue — a bridged
UNIX workstation whose browser is **the same Netscape 4 generation**; read its
"quiet browser" section before seeding any prefs here). The guest itself:
[`../../guests/aix432.md`](../../guests/aix432.md).

## The wiring, as declared

| | Declared | State |
|---|---|---|
| Link | tap **`aixrn0`**, persistent, enslaved to `vmbr-rn`, to be created and guarded by `streamhost/stations/aix432/rn-tapnet.sh up` from the launcher on **every** start | **not written** — neither the station directory nor the helper exists in the repo yet |
| Guard | chain **`AIXRN-IN`** at INPUT position 1, scoped to the guest IP, per the fleet scheme | **not built.** Deliberately NOT declared in `registry/stations/aix432.json` — `retronet.guard` is omitted until the chain exists, because the gate cross-checks the declared chain name against the helper that installs it |
| Guest IP | **10.99.0.28/24, static**, configured in the guest's own ODM (`chdev -l en0`), DNS `10.99.0.2`, **no default route** | claimed in the registry; unproven in the guest |
| MAC | fleet scheme — the last octet of the address in the last octet of the MAC. The real value lives only in gitignored `registry/local.env` as `RN_AIX432_MAC`; the committed launcher carries the scrubbed placeholder and reads the one line at boot | not yet allocated in `local.env` |
| Seamless web | `/etc/resolv.conf` = `10.99.0.2` + **no Netscape proxy** → any URL resolves to the gateway, whose `:80` origin serves the corpus by `Host` | to be seeded |
| Browser | **Netscape Communicator 4.08** (`Netscape.communicator-us.rte`, 4.3.2 Bonus Pack), rendering proven on the emulated card — see [`../research/candidate-aix.md`](../research/candidate-aix.md) §4.5 | the *rendering* is proven; **nothing about it over the bridge is** |
| NIC model | **OPEN — the one real unknown.** See below | must be settled before the golden is baked |
| Exec | **none.** No network exec path exists or is planned: the guest has no route off the bridge, and labhost must never dial it. The 40p's super-I/O serial port is the candidate channel | not wired |
| Audio | `paud0` (emulated Crystal CS4231) configures itself from the real firmware's residual data and is held open by real applications, but the stream carries **no audio** (`stream.audio: false`) until a capture proves it | guest-side proven, stream-side not |

## The NIC is not chosen yet, and that gates the golden

Every other bridged station knew its adapter before it joined. This one does
not, and it must not be guessed: **a checkpoint, its binary and its device set
are one combination** (AGENTS.md rule 6), so attaching or changing a NIC after
the golden is baked invalidates the golden.

The constraint is the same wall the display hit. AIX 4.3 binds a PCI device by
a fileset whose name is the **byte-swapped vendor+device id** — that is how
`devices.pci.2b102005` was decoded to `0x102B:0x0520`, the Matrox behind the
GXT130P ([`../research/candidate-aix.md`](../research/candidate-aix.md) §4). So
the question "which QEMU NIC can this guest drive" is answered by decoding every
`devices.pci.*` **Ethernet** fileset on the 4.3.3 and 4.3.2 media the same way,
and intersecting that list with what `qemu-system-ppc -M 40p` will accept —
**not** by trying adapters until one appears in `lsdev`.

Until that intersection is written down here, `runtime.qemu.deviceSetSummary`
in the registry carries the NIC as `<NIC>` on purpose.

## Containment — the design this station inherits

Unchanged from every bridged station; nothing here is aix432-specific, and
nothing here is proven for aix432 yet. Layered so no single failure opens
anything:

1. **Topology.** `aixrn0` is enslaved ONLY to `vmbr-rn`, which has
   `bridge-ports none` and **no uplink**. The guest is never on the LAN's L2.
2. **Routing.** No default route in the guest, so AIX cannot form a packet to
   anything off `10.99.0.0/24`. labhost's `retronet-fw` `RETRONET-FWD` chain
   drops anything trying to route *through* the box regardless.
3. **Filter.** `AIXRN-IN`, scoped to `10.99.0.28`, inserted at INPUT position 1
   above `RETRONET-IN`: every NEW flow the guest starts toward labhost is
   dropped. Without it the guest could open labhost's `0.0.0.0` listeners — the
   gallery included — by dialling the bridge address `10.99.0.1`, which
   `retronet-fw` deliberately leaves reachable and which no-default-route does
   **not** close, because `10.99.0.1` is on the guest's own subnet.

Two traps this bridge has already charged other stations for, both of which
apply here the moment the helper is written:

- **`rn-tapnet.sh` must read its rules back out of the kernel** and refuse to
  report the link up if they are not there. A lost `xtables` race otherwise
  brings the tap up fail-OPEN while every message still says "up".
- **Derive the chain name from the interface.** A rig's teardown once deleted
  the live exhibit's chain because both taps carried the same guest IP. `aixrn0`
  keeps the bare `AIXRN-IN`; any other tap gets `AIXRN-IN-<if>`. See
  [`WEB-STATION-irix.md`](WEB-STATION-irix.md).
- **A `box_sync_add_pair aix432-rn-tapnet` row** in
  [`../../../scripts/lib/box-sync-pairs.sh`](../../../scripts/lib/box-sync-pairs.sh)
  is required, or the helper reaches the box checkout and never the station
  directory and the launcher dies on start. The registry gate fails the entry
  without it — beos, w2kalpha and rhapsody each lost a boot cycle to this.

## Netscape 4 — read the irix bake before seeding anything

The browser is a different port of **the same Netscape 4 generation** that
`irix` shipped, so the same first-run behaviour should be expected and designed
out before a visitor sees it. From that station, already paid for:

- **`browser.startup.homepage_override: false`** is the pref that actually
  gates the first-run tour. With it absent, Netscape 4 overrides the configured
  home page exactly once and opens `home.netscape.com/home/first.html` →
  `su_setup.html` — two corpus misses and a long wait as the exhibit's first
  frame. Seeding a home page alone does **not** prevent this.
- **Seed every interactive account**, and **chown each profile to its account**:
  Netscape rewrites `preferences.js` on exit and cannot when the file is
  root-owned. On this station the visitor's session is likely `root` (the
  checkpoint restores a logged-in CDE session), which makes it easy to seed the
  wrong home directory and never notice.
- **Remove `.netscape/lock`** from every profile in the bake. It is a symlink
  naming `host:pid` that Netscape leaves behind on an unclean exit — a killed
  process, a station relaunch — and it opens a modal dialog on the next start.
- **Turn the era's four modal security warnings off**
  (`security.warn_entering_secure` and friends). The plane serves no https at
  all, so they can only ever fire spuriously.
- `network.proxy.type 0` — the gateway's wildcard DNS is the whole mechanism;
  there is no proxy to configure.

Untested here and worth checking early: Quake needs
`LIBPATH=/usr/lpp/som/lib:/usr/lib` because it links `som.dll` and `UMSobj.dll`
— Netscape 4.08 on AIX has its own runtime expectations, and the station's
`/usr` was grown by hand at install time, so a browser that fails to start for
want of a library is a likelier failure mode here than a rendering one.

## Acceptance — what must be measured, and none of it has been

The bring-up is not done until all of these are captured **from inside the
guest** and pasted into this section, replacing this list:

```
netstat -rn                # NO default route: only 10.99.0.0/24 and loopback
ifconfig en0               # inet 10.99.0.28 netmask 0xffffff00
ping -c3 10.99.0.2         # the gateway CT answers
ping -c2 hamsterdance.com  # ANY name resolves to 10.99.0.2 (wildcard DNS)
ping -c3 10.99.0.1         # 100% loss — the AIXRN-IN guard chain
ping -c3 1.1.1.1           # Network is unreachable — no default route
```

And then the only proof that counts (AGENTS.md rule 9): **the framebuffer** —
Netscape Communicator 4.08 painting a corpus page on the emulated GXT130P, from
the production checkpoint, with **no dialogs in any frame**, from the first
painted one.

A state that RENDERS is not a state that WORKS: prove the restored golden is
still live on the bridge afterwards (the guest answers a ping itself), not
merely that the pixels came back.

## Rollback

The station is not deployed, so the rollback is the absence of the join: the
registry entry's `retronet` block and this document are the only things that
exist. Removing the block and this file returns aix432 to a guest with no
network at all, which is what
[`scripts/build-guests/tiles/aix432.sh`](../../../scripts/build-guests/tiles/aix432.sh)
builds today (`-net none`).

Once the station is live, the rollback is the fleet's usual one and it is a
**device-set change**: dropping the NIC re-bakes the golden. Plan for that
before attaching one.
