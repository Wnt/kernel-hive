# w2kalpha on the retronet — the WEB plane, as-built

**Status: LIVE.** `w2kalpha` (Windows 2000 RC2 build 2128 for Alpha AXP, on the
**es40** AlphaServer ES40 emulator) browses the retronet's period corpus web,
containment-fenced. Its `dec21143` NIC was **rehomed from the pre-retronet
host-only `172.31.64.0/30` veth onto the retronet bridge `vmbr-rn`**, DHCP-addressed
(**reserved 10.99.0.17**), DNS from the lease (10.99.0.2), **no default route**.
Open Internet Explorer, type a corpus URL, and the page renders from the museum's
internet with **no proxy configured**.

This is the **WEB plane only** (seamless corpus browsing). ICQ messaging is a
**separate, future** onboarding and is out of scope here. Parents:
[`WEB-PROXY.md`](WEB-PROXY.md) (the addressing plane this rides), the es40 NIC
rehoming pattern in [`ICQ-STATION-tru64.md`](ICQ-STATION-tru64.md) (the other es40
station), the Windows-2000 DHCP conversion in
[`ICQ-STATION-win2000.md`](ICQ-STATION-win2000.md), and the guest itself,
[`docs/guests/w2kalpha.md`](../../guests/w2kalpha.md).

## What is different here: es40, and the exec channel rides the NIC

Two facts shaped the whole procedure and make w2kalpha unlike every other retronet
station:

1. **es40 has no tap backend** — it captures a host interface with **libpcap**
   (`es40.cfg`: `dec21143 { type="pcap"; adapter="w2kalpha-g"; ... }`). So the host
   side is a **veth PAIR**, and only the host end is a bridge port:

       guest  <- es40 pcap ->  w2kalpha-g  <== veth ==>  w2kalpha-h  -> vmbr-rn

   es40 opens the **guest end** (`w2kalpha-g`) with pcap; `rn-tapnet.sh` enslaves
   the **host end** (`w2kalpha-h`) to `vmbr-rn`. This is the same L2-to-the-gateway
   a tap gives the QEMU stations, reached by a different backend. veth TX/RX
   checksum offload is disabled on **both** ends (`ethtool -K`), or es40's pcap
   reads locally-originated frames as corrupt.

2. **The exec channel rides the NIC** (telnet), not a serial line. tru64's exec is
   the emulated com2, independent of its NIC, so tru64 could reconfigure its network
   freely over serial. w2kalpha's `labctl exec` is the guest **W2K Telnet Server**
   (blank Administrator, NTLM off) — it rides the very NIC being re-addressed. So the
   reconfigure could NOT be driven over the channel it was changing. It was driven
   over the **ctlsock keyboard** (`ES40_CTL_SOCK`, NIC-independent) on a cold boot,
   and verified over telnet once the new address came up.

## The wiring, at a glance

| | |
|---|---|
| NIC | `pci0.4 = dec21143 { type="pcap"; adapter="w2kalpha-g"; mac="…"; queue=1024; crc=false; }` in `assets/w2kalpha/es40.cfg` — **unchanged device**; only a `mac=` was added and the host end re-homed |
| Host link | veth `w2kalpha-g` (pcap/guest end) `<==>` `w2kalpha-h` (bridge-port end, enslaved to `vmbr-rn`), created + guarded by `streamhost/stations/w2kalpha/rn-tapnet.sh up` from the launcher on every start |
| Guest IP | **DHCP — reserved `10.99.0.17/24`, DNS `10.99.0.2`, NO default route.** `retronet-dhcp` reserves `10.99.0.17` on the guest MAC and hands out mask + DNS + domain with **no option-3 router** (containment Lock 1, enforced by the *addressing*). Windows was switched to DHCP for **IP and DNS** (`netsh interface ip set address/dns … source=dhcp`) |
| MAC | unique, fleet scheme (`52:54:00:52:4e:<last-IP-octet>`, `.17` → `…:11`). **Real value in gitignored `registry/local.env` `RN_W2KALPHA_MAC`**; the committed launcher/registry carry the scrubbed placeholder `02:00:00:00:00:11`, and the real value is set directly in the box-only `es40.cfg`. **Baked by a COLD boot** (see below) |
| Exec | `labctl exec w2kalpha "<cmd>"` → the guest W2K Telnet Server at **`10.99.0.17:23` over the bridge** (`exec_kind telnet_e`; `scripts/labctl.d/guest.py` `W2K_TELNET_HOST`). labhost dials it; the guest only ever REPLIES toward labhost (ESTABLISHED), so the guard chain leaves the channel working |
| Seamless web | DNS = `10.99.0.2` (via DHCP) + **no IE proxy** → type any URL, the name resolves to the gateway and its `:80` origin serves the corpus. Proven: IE renders `http://spacejam.com/` with no proxy |
| Containment | fail-closed INPUT chain `W2KALPHARN-IN`, scoped to `10.99.0.17`, inserted above `RETRONET-IN`; `rn-tapnet.sh` reads it back and the launcher aborts (es40 never starts) if it does not verify |

## The MAC — configurable in es40, baked by a cold boot

es40's fork reads a `mac` config knob (`myCfg->get_text_value("mac")`; a malformed
value is a hard `FAILURE`), so `mac = "…"` in the `dec21143` block assigns one. But
the MAC lives in the es40 **savestate** (`SNIC_state.mac[6]`), so **restoring the
checkpoint restores the OLD MAC regardless of `es40.cfg`** — exactly like `loadvm`
on the QEMU stations. The unique MAC therefore had to be **baked by a cold boot**
(golden.axp moved aside so the launcher cold-boots), then re-captured. Proven
in-guest: `ipconfig /all` shows `Physical Address … 52-54-00-52-4E-11`.

## The reconfigure — one cold-boot run, driven over the ctlsock keyboard

Because the telnet exec channel rides the NIC, the whole switch was done in a
**single cold-boot run on the bridge**, driven over the ctlsock keyboard (which is
independent of the network), and verified over telnet once the lease came up:

1. **Stage for a cold boot.** Add `mac=` to `es40.cfg`; deploy the bridge launcher
   + `rn-tapnet.sh`; move `golden.axp` aside so the launcher cold-boots from
   `nt.img`.
2. **Cold boot on the bridge.** `rn-tapnet.sh up` (veth → `vmbr-rn` + `W2KALPHARN-IN`
   guard), then es40 cold-boots with the new MAC. The guest comes up on its old
   static `172.31.64.2` (from the seed) — unreachable on the bridge, which is fine:
   the ctlsock keyboard is the drive channel.
3. **Switch to DHCP over the keyboard.** Win+R → `cmd` (`ctltest.py` sends the key
   edges; `es40-gtype.py` types the URL/commands including `=` and `"`), then
   `netsh interface ip set address name="Local Area Connection" source=dhcp`. This
   drops the static IP and starts DHCP **live** — the guest immediately gets
   `10.99.0.17` from the reservation. DNS follows automatically (the static
   NameServer was empty, so Windows uses the DHCP-supplied `10.99.0.2`); a belt
   `netsh … set dns … source=dhcp` makes it explicit.
4. **Verify over telnet at the new address, then bake.** `10.99.0.17:23` is now
   reachable; the full acceptance suite runs over it.

**Why not `netsh` over telnet (the tru64 recipe's shape)?** `netsh … set address
source=dhcp` drops the live IP mid-command, killing a telnet session driving it —
and on the old host-only veth there is no DHCP server to re-address to. Driving it
over the ctlsock keyboard sidesteps the catch-22 entirely: the keyboard channel
never depends on the NIC. (`reg.exe` is absent on this build, so the registry `.reg`
path the win2000 doc favours was not available; `netsh` is present and works.)

## Containment — proven from inside the guest (`10.99.0.17`)

| From the guest to… | Result | Lock |
|---|---|---|
| gateway CT `10.99.0.2` (`:80` corpus origin, DNS) | **Reply** + serves | intra-bridge L2 (the point) |
| labhost bridge `10.99.0.1` (ICMP) | **100% loss** | the per-station guard chain `W2KALPHARN-IN` |
| internet `1.1.1.1` (ICMP) | **Destination host unreachable** | no default route (Lock 1) |

Same three-layer model as the other retronet stations (topology → no-default-route →
the fail-closed guard chain scoped to the guest IP). w2kalpha's telnet exec is a flow
**labhost initiates** to the guest, so the guest only ever replies toward labhost
(matched by `ESTABLISHED,RELATED RETURN`); every NEW flow the guest starts is dropped.

## Seamless web — IE renders the corpus, no proxy

DNS (`retronet-dns`) answers **every** name with `10.99.0.2`, the DHCP lease hands
that DNS out, and the gateway's `:80` origin (`proxy.py`) serves the corpus by
`Host`. So IE with **no proxy configured** renders any corpus URL: `nslookup
spacejam.com` → `10.99.0.2`, and IE at `http://spacejam.com/` renders the Space Jam
homepage from `/data/retronet/corpus/spacejam.com/` (HTTP 200). An un-mirrored site
still resolves to the gateway and gets the period miss page. Full addressing plane:
[`WEB-PROXY.md`](WEB-PROXY.md).

**IE "Work Offline" gotcha.** The seed's IE launches in Work Offline mode and shows
a modal *"Web page unavailable while offline → Connect / Stay Offline"* dialog. The
baked golden clears it: `HKCU\…\Internet Settings\GlobalUserOffline=0` (imported with
`regedit /s`), so a restored IE comes up online.

## Checkpoint lineage & rollback (FULL paths)

The station resets by restoring a **checkpoint** — `assets/w2kalpha/golden.axp` (an
es40 savestate) paired with `assets/w2kalpha/nt.img` (the disk it was baked from) +
`assets/w2kalpha/rom/`. The three are a coherent set from one bake (serial-menu
option 5 = save-and-exit: all device threads stopped, so no guest write lands after
the save).

- **LIVE checkpoint (2026-08-23):** `assets/w2kalpha/{golden.axp,nt.img,rom/}` —
  re-baked for the retronet: a **cold boot** on `vmbr-rn` baked the unique MAC, the
  guest was switched to DHCP (`10.99.0.17`, DNS `10.99.0.2`, no default route) and
  IE set online, then captured via serial IAC BREAK → option 5. A restore comes up
  networked at `10.99.0.17` in ~3 s without re-running DHCP. `SHA256SUMS.retronet-20260823`
  records the hashes.
- **Pre-retronet backup (the rollback for this whole change):**
  `assets/w2kalpha/{golden.axp,nt.img,es40.cfg}.bak-prern-20260823` +
  `rom.bak-prern-20260823/` + `SHA256SUMS.prern-20260823`, plus the station-dir
  `x11-runtime.sh.bak-prern-20260823` + `station.env.bak-prern-20260823`. Rollback =
  `systemctl stop streamhost@w2kalpha`, restore those over the live files, revert the
  launcher/registry/`local.env` reservation, `rn-tapnet.sh down`, start. (The
  host-only backup `golden.axp.premigration-20260823` is the same pre-retronet state,
  kept from the cold-boot staging.)

The device set did **not** change (the `dec21143` was already at `pci0.4`); only the
`mac=` savestate field and the guest config changed, so this is a MAC re-bake, not a
device-set change. A cold boot with the NIC present → reconfigure → recapture is the
same shape macos753 used for its NIC add.

## Preserved: instant restore + headless capture + idle-pause

Verified after the re-bake (production `systemctl restart` path):

- **Instant restore, ~6 s** systemd-start-to-live (framebuffer non-empty + es40 +
  both serial listeners bound); the restored guest comes up **networked at
  `10.99.0.17`** (no re-DHCP) and **contained** (10.99.0.2 replies, 1.1.1.1
  unreachable).
- **Full window paint** (the `a09816d` 8514/A accelerator-state gate): a new Notepad
  window paints title bar + menu bar + client area in full, not a fragment.
- **Headless capture** (`SH_CAPTURE=shm`) intact; **idle-pause** back at its prior
  setting (`SH_IDLE_PAUSE_SECS=60`) and confirmed working (es40 observed SIGSTOPped
  between visits, resumes on the next).

## Operating it

```bash
ssh lab 'labctl exec w2kalpha "ipconfig /all"'      # lease 10.99.0.17, DNS 10.99.0.2, no gw, the unique MAC
ssh lab 'bash /data/vms/streamhost/stations/w2kalpha/rn-tapnet.sh show'   # veth + guard chain
ssh lab 'curl -s http://10.99.0.2/ -H "Host: spacejam.com" | head'        # the :80 origin serves the corpus
ssh lab 'labctl reset w2kalpha'                      # relaunch → restore golden → networked clean desktop ~3 s
# re-bake the checkpoint: see docs/guests/w2kalpha.md (Checkpoint restore) + the recipe above
```
