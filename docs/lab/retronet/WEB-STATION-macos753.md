# macos753 on the retronet web — the bridge as-built

Mac OS 7.5.3 on an emulated Quadra 800 (m68k, TCG) joined the retronet web plane
on **2026-08-23**. It is the plane's first **foreign-architecture** member, its
first guest whose TCP/IP is **MacTCP**, and — like
[`chokanji`](WEB-STATION-chokanji.md) — a station that had **no NIC at all**, so
the golden had to be **cold re-baked** rather than carried forward.

Read [`WEB-PROXY.md`](WEB-PROXY.md) for the `:80` origin + wildcard-DNS plane this
joins, [`GATEWAY.md`](GATEWAY.md) for CT 951, and
[`WEB-STATION-chokanji.md`](WEB-STATION-chokanji.md) for the no-NIC / no-DHCP
precedent this follows almost exactly.

## The wiring, at a glance

| | |
|---|---|
| NIC | **`dp83932` (SONIC)** — `-nic tap,ifname=macosrn0,script=no,downscript=no,model=dp83932,mac="$RN_MACOS753_MAC"` |
| MAC | **Apple OUI `08:00:07:…`**, not the retronet `52:54:00:52:4e:<octet>` scheme. Real value in gitignored `registry/local.env` as `RN_MACOS753_MAC`; the committed launcher carries the scrubbed placeholder `02:00:00:00:00:17` and reads the one line at boot |
| Tap | `macosrn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/macos753/rn-tapnet.sh up`, called from the launcher on every start |
| Guard chain | `MACOS753RN-IN`, scoped to `10.99.0.23`, inserted above `RETRONET-IN`; **fail-closed** (launch aborts if it does not verify) |
| Address | **static, in-guest** `10.99.0.23`, DNS `10.99.0.2`, **no default route** |
| DHCP | **none, and none possible** — see below. The `08:00:07:00:00:17 -> 10.99.0.23` reservation exists **only to keep the address unique** on the plane and is never claimed |
| Browsing | the gateway's **`:80` origin**, seamlessly: wildcard DNS resolves every name to `10.99.0.2` and `Host:` picks the corpus site. **No proxy configured** |

## The NIC was not a choice — the machine has exactly one

Every other station on the plane picked a card to suit the guest's driver set.
This one could not, and did not have to:

```
$ qemu-system-m68k -M q800 ... -nic model=help
Available NIC models for this configuration:
dp8393x (aka dp83932)
```

**One model.** QEMU's `q800` machine instantiates the National Semiconductor
SONIC that the real Macintosh Quadra 800 had on its logic board, and nothing
else — there is no PCI bus to hang an alternative off. That removes the entire
class of problem the [`rhapsody`](WEB-STATION-rhapsody.md) stream hit (Apple's
`i82557b` driver needs a receive mode QEMU's eepro100 does not implement, so
`Ipkts` stayed 0 forever and the fix was to swap the card). Here there is no card
to swap to, so the receive path had to be **proven** rather than chosen — and it
works; see [Containment](#containment) for the ARP-reply and DNS-answer evidence.

**Mac OS 7.5.3 drives it with nothing installed.** On the first cold boot with
the NIC present, MacTCP's driver list showed **`Ethernet`** beside `LocalTalk`
with no driver installation, no extension and no Network Software Installer run:
the built-in Ethernet driver for this machine is already in the System. This is
the cheapest NIC bring-up on the whole plane.

## MacTCP has no DHCP — and this is the definitive evidence

MacTCP 2.0.6's **Obtain Address** choices, read off the framebuffer, are exactly
three:

| Option | What it is |
|---|---|
| **Manually** | static, what this station uses |
| **Server** | **BOOTP / RARP** — the 1993 mechanism, *not* DHCP |
| **Dynamically** | MacTCP's own scheme for allocating a node number within a configured network |

There is **no DHCP client anywhere in MacTCP**, so
[`WEB-PLANE-PLAN.md`](WEB-PLANE-PLAN.md)'s "no DHCP client" grouping of
chokanji / rhapsody / macos753 is **correct as written for this station** and
needs no correction. One nuance worth recording rather than losing: "Server"
mode is BOOTP, and the plane's `dnsmasq` does answer BOOTP, so this guest is not
strictly *incapable* of autoconfiguring the way Rhapsody (which ships no client
at all) is. It is configured statically anyway, deliberately: static is
deterministic, it matches the reserved address exactly, and it is the pattern the
plane already has two instances of.

The configuration, as stored (all of it re-read from the panel after a full guest
restart, which is what makes it safe to bake into a golden):

| Field | Value |
|---|---|
| Obtain Address | **Manually** |
| Address | `10.99.0.23` |
| Subnet Mask | `255.0.0.0` — see the note below |
| **Gateway Address** | **`0.0.0.0`** — this is what gives the guest no default route |
| Domain Name Server | domain `.` → `10.99.0.2` |

**On the mask.** MacTCP derives the mask from the address *class* and this is a
class-A address, so it reads `255.0.0.0` rather than the plane's `/24`. The
subnet slider that would narrow it is inert on this build, and switching the
Class popup to C is rejected for a `10.x` network. It was left as class A
deliberately: **nothing about containment depends on the mask.** The only host
the guest must reach, `10.99.0.2`, is on-link either way; `10.99.0.1` would be
on-link under `/24` as well and is refused by the guard chain, not by the mask;
and there is no default route under either. The registry records the address, not
a prefix.

## Where the guest's config actually lives, and the trap in it

MacTCP writes its settings into the **`MacTCP Prep`** file in the System Folder
(and the control panel's own resources), i.e. **on the disk**, not in PRAM and
not only in RAM. That is what makes them survive a cold boot and therefore
bakeable. Every change needs a guest **restart** — MacTCP says so itself with a
"you must restart" alert, and until you do, the old settings are what the stack
is using.

**The trap this station paid for:** the checkpoint was hiding two settings that
were only ever in the *checkpoint's RAM state*, never on disk. A cold boot — which
a device-set change forces — brought both back to their defaults:

- **32-bit addressing was OFF**, capping usable RAM at 8 MB of the 128 installed.
  Netscape needs 7 MB and there were 5.9 MB free, so it would not launch at all.
- **Disk cache was back at 32K**, not the 7680K the fixture records.

Both are in the **Memory** control panel, both need a restart, and both must be
re-applied as part of any cold re-bake of this station. `docs/guests/macos753.md`
lists them under the checkpoint because that is where they were set; they are
not automatically in the disk image.

## Containment

The guest reaches the retronet and nothing else. Measured on `macosrn0` with the
browser driving:

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2:53` (DNS) | `A? home17.netscape.com` → **`A 10.99.0.2`** | intra-bridge L2 (the point) |
| CT `10.99.0.2:80` (corpus origin) | SYN → SYN/ACK → `GET / HTTP/1.0` → **`HTTP/1.0 200 OK`**, ~17.9 KB, then `GET /images/home_igloo.jpg` → `200 OK`; `www.apple.com` renders | same |
| ARP for `10.99.0.2` | request out, **reply received and acted on** | proves the **receive** path |
| anything off `10.99.0.0/24` | the guest's stack **cannot form the packet** | **Gateway Address `0.0.0.0`** — no default route |
| the internet | unreachable by construction | `vmbr-rn` is `bridge-ports none`: its only members are station taps and the CT's veth. **No uplink exists** |
| labhost `10.99.0.1` | **not probed from inside this guest** — see below | `MACOS753RN-IN`, verified in the kernel, fail-closed |

The ARP row is the one that matters most here, because it is exactly where
rhapsody's NIC failed. The guest ARPs for `10.99.0.2`, the CT replies, and the
guest then completes a TCP handshake and a full HTTP transaction — none of which
is possible without a working receive path. The SONIC is fine.

**Being precise about the labhost row.** Every other station on the plane proves
it by typing `http://10.99.0.1/` into the guest's browser and watching the SYNs
die. That was attempted here and **not completed**: Netscape is intermittently
unstable on this machine (below), and each attempt cost a guest restart. What
*is* established for this station is:

- the chain is installed exactly as designed and **read back out of the kernel**
  (`rn-tapnet.sh` refuses to report `up` otherwise), scoped to `10.99.0.23`:
  `-A INPUT -s 10.99.0.23/32 -i vmbr-rn -j MACOS753RN-IN`, then
  `RELATED,ESTABLISHED -j RETURN`, then `-j DROP`;
- across every capture taken during this bring-up, **the guest never addressed
  anything but `10.99.0.2`** (DNS, HTTP) and broadcast ARP — its `MACOS753RN-IN`
  DROP counter is still `0` because it has never tried;
- the chain is byte-identical in shape to the one empirically proven on
  `chokanji` and `win98se`.

So the lock is in place and verified; the *empirical* guest-initiated refusal is
inherited from the shared design rather than measured on this station, and that
distinction is recorded here rather than papered over.

`retronet-fw` runs with `bridge-nf-call-iptables=0`, so guest↔CT traffic is pure
L2 and never touches these chains — the retronet reaching the retronet.

### MacTCP is dormant until an application opens it

**The station does not answer ping, and that is not a fault.** MacTCP loads its
driver on demand: with no TCP/IP application running, the stack is inactive and
the guest emits *nothing* — not even an ARP reply. `ping 10.99.0.23` from the
gateway CT gets 100 % loss at the checkpoint, and a tap sniffed from first
instruction to desktop is silent. The guest comes alive on the wire the moment a
browser opens, and not before.

This matters for anyone debugging this station later: **silence on the wire is
the expected resting state**, so it can never be used as evidence that the NIC,
the tap or the bridge is broken. Open a browser first.

## The browser — Netscape Navigator 3.04, and the two things that made it look broken

**The station browses the corpus in Netscape Navigator 3.04 (68K).** It renders
`home.netscape.com` (the 9 July 1997 Netscape home page, masthead graphic, nav
bar, tables, headlines and all) and, from a URL typed by hand into the Location
bar with **no proxy configured**, `www.apple.com` — Apple's 8 May 1998 iMac
"hello (again)" page, `Document : Done.` on the status bar. A 1998 Apple page on
a 1996 Macintosh is about as on-theme as this museum gets.

Getting there meant clearing two faults that both **look** like a broken network
and are neither:

1. **The default 9000K memory partition is too small.** Netscape died at launch
   with a **type 16** (floating-point) error, then a **type 1** (bus error) — the
   classic signature of classic-Mac heap exhaustion, not of an FPU problem, and
   nothing to do with the emulated 68040's FP support. Raising **Get Info →
   Preferred size to 24000K** fixed it. The machine has 128 MB and the exhibit
   has no other application to feed, so this is cheap.
2. **MacTCP does not survive a force-quit of an app holding it open.** After
   force-quitting Netscape, the *next* browser to start hung forever on its first
   name lookup **with nothing at all on the wire** — no DNS query, no ARP. That
   reads exactly like "the NIC is dead", and it is not: it is MacTCP's driver
   left wedged. **A guest restart is the only way back.** Both browsers hit this,
   which is what makes it a MacTCP fact rather than a browser one.

Neither fault produces an error message that points anywhere near its cause,
which is why they are written down here.

### MacWeb 2.0 cannot use the `:80` origin at all — it sends no `Host:`

MacWeb 2.0 is also installed (it is what the archive offered as a BinHex-wrapped
self-extracting `.sea`, and the copy sourced is the **French** build, `MacWeb F`).
It launches, resolves and connects — and then the origin refuses it:

```
GET /galaxy.html HTTP/1.0        <- from the guest, no Host: header
HTTP/1.0 400 Bad Request         <- from the gateway
```

**This is a plane-wide fact, not a macos753 one.** The seamless `:80` origin
selects a corpus site from the `Host:` header, so a browser old enough to predate
`Host:` (MacWeb 2.0, and by the same reasoning NCSA Mosaic 2.x) can never use it,
however healthy its networking is. Such a browser needs the **`:3128` forward
proxy** instead, where the site is named in the request line
(`GET http://host/path HTTP/1.0`) — which is exactly what a pre-`Host:` browser
does send once a proxy is configured. Netscape 3.04 sends `Host:` and so needs no
proxy, which is why it is the browser this station ships.

## Getting files into a guest with no network and no shell

System 7.5.3 has no shell, no telnet and no serial console, and before this work
no network either — so there was no way to hand it a file. The route used needs
no device-set change and no CD:

```bash
qemu-img convert -f qcow2 -O raw macos753-golden.qcow2 disk.raw
hmount disk.raw                      # hfsutils; understands the Apple Partition Map
hcopy -b netscape3.04_128.hqx :      # -b decodes BinHex, restoring the resource fork
hcopy -m some-macbinary.bin :        # -m for MacBinary
humount
qemu-img convert -f raw -O qcow2 disk.raw macos753-golden.qcow2
```

**The resource fork is the whole point.** A classic Mac application *is* its
resource fork; a `.zip` of a Mac app is useless. `hcopy -b` (BinHex) and
`hcopy -m` (MacBinary) both reconstruct it, and the proof it worked is that the
files appear in the Finder **with their real icons**. `hfsutils` is strict about
MacBinary CRCs and will refuse a file other tools accept.

## Driving System 7.5.3 from the framebuffer — what this cost

There is no exec channel and never will be, so everything went through QMP and
`scripts/install-vision/adb_pointer.py`. Four traps, each of which produced a
*plausible wrong answer* rather than an error:

- **A modal alert silently swallows every click and keystroke.** Several
  "the field will not focus" dead ends were a System 7 alert sitting unnoticed
  behind the crop being inspected. **Dismiss with Return first, always**, then
  interact. This one cost the most time by far.
- **Clicks need a deliberate hold.** `AdbPointer.click`'s down/up is too fast for
  System 7 dialogs under TCG; a ~0.35 s held press registers where a fast click
  does nothing. **For a default button, send Return instead of clicking it** —
  far more reliable.
- **Tab order is not what the layout suggests.** In MacTCP's *More* dialog the
  order is row-major (`Domain₁ → IP₁ → Domain₂ → IP₂`), the IP column cannot be
  reached by clicking at all on this build, and the field the pointer is over is
  not necessarily the field with focus. Detecting the focused field by its **bold
  border** in the framebuffer, then typing, is what worked.
- **Keystrokes are dropped under TCG load.** Typing needs pacing (~0.45 s/char in
  a busy dialog), and a number field silently caps its length, so a "wrong value"
  can be a *truncated* value rather than a mistyped one.

## Golden lineage & rollback (FULL paths)

Adding the NIC changed the device set, so the pre-change golden could not be
carried forward — it was **cold re-baked** on 2026-08-23.

**The vmstate for this station lives in the PRAM qcow2, not the disk.** QEMU
writes it to the first snapshot-capable drive, and on this machine that is the
256-byte PRAM (`if=mtd`, and it must be qcow2 — as raw, `savevm` refuses
outright). The two files are one unit: a backup of the disk alone carries a
`golden` tag with no machine state behind it, which is why both are backed up and
both must be restored together.

| | |
|---|---|
| Live disk | `/data/vms/streamhost/stations/macos753/macos753-golden.qcow2` |
| Live PRAM (**holds the vmstate**) | `/data/vms/streamhost/stations/macos753/pram-golden.qcow2` |
| **Pre-change backups** | `macos753-golden.qcow2.prern-2026-08-23` (sha256 `0abf90e2…8993a5`) and `pram-golden.qcow2.prern-2026-08-23` (sha256 `dcbda791…0697fe`) |
| Pre-change launcher | `qemu-streamhost.sh.prern-2026-08-23` |

Both backups were taken with **QEMU stopped** and verified byte-identical
(`cmp`) to the live images before anything was touched. They are kept **next to
the disk**, not in the bring-up sandbox, deliberately: `wt.sh gc` prunes merged
sandboxes, and a rollback artifact a routine cleanup can delete is not a rollback
artifact.

### The re-bake, as measured

| Step | Result |
|---|---|
| Cold boot with the new device set | straight to the fixture scene, no "not shut down properly" dialog (the source image was shut down cleanly) |
| `savevm golden` | **0.54 s**, **130 MiB** vmstate in the PRAM, 0 B tag on the disk |
| Launcher restore path | `-loadvm golden -S` present in the live cmdline, alongside `-nic tap,ifname=macosrn0,…,model=dp83932` |
| Boot state | `prelaunch` — frozen at the checkpoint, so a station nobody has visited has never run a guest instruction |
| **`labctl reset macos753`** | `ok: macos753 restored to golden snapshot (loadvm golden)` in **0.512 s** |
| NIC after the wake | `dp8393x.0: index=0,type=nic,model=dp8393x,macaddr=…` → `#net032: index=0,type=tap,ifname=macosrn0` |
| Framebuffer after the wake | the fixture scene, unchanged |

**One trap in the re-bake worth knowing.** The launcher decides whether to
restore by running `qemu-img snapshot -l` on the disk, and the *first* unit start
after the bake **cold-booted anyway** — the previous QEMU still held the image
when the launcher probed it, `qemu-img` failed, `2>/dev/null` swallowed the error
and the test came out false. A second `systemctl restart` picked the snapshot up
correctly. If a freshly baked station cold-boots when it should restore, this is
why: restart it once more before suspecting the bake.

**Rollback** (returns the station to its pre-retronet exhibit exactly):

```
ssh lab 'systemctl stop streamhost@macos753'
ssh lab 'cd /data/vms/streamhost/stations/macos753 &&
         cp -a macos753-golden.qcow2.prern-2026-08-23 macos753-golden.qcow2 &&
         cp -a pram-golden.qcow2.prern-2026-08-23     pram-golden.qcow2 &&
         cp -a qemu-streamhost.sh.prern-2026-08-23    qemu-streamhost.sh'
ssh lab 'systemctl start streamhost@macos753'
```

Both images must be restored **together**, and the launcher with them (the
pre-NIC launcher has no `rn-tapnet.sh` call and no `-nic`).

## Operating it

- `ssh lab '/data/vms/streamhost/stations/macos753/rn-tapnet.sh show'` — tap,
  master bridge and the guard chain as the kernel actually holds them.
- The tap is **persistent** and is the station's deliverable: it survives QEMU
  exiting and a host reboot, because the launcher calls `rn-tapnet.sh up`
  idempotently on every start. There is no separate systemd unit.
- `rn-tapnet.sh` is registered as a **box-sync pair**
  (`macos753-rn-tapnet` in `scripts/lib/box-sync-pairs.sh`). Without that pair the
  generic launcher sweep carries `qemu-streamhost.sh` but not the helper it calls,
  the file stops at the box checkout, and the station cannot start at all.
- To change the address, drive MacTCP in the guest, restart it, and **re-bake the
  golden** — the address is in the disk, not in the launcher.
