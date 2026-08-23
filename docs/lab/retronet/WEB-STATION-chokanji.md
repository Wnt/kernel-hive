# chokanji on the retronet web — the bridge as-built

超漢字 / B-right/V 4.202 (BTRON3) joined the retronet web plane on **2026-08-23**.
It is the first station in the wave that had **no NIC and no audio device at all**,
so joining was not an options-only netdev swap: adding the card changed the device
set, `loadvm golden` binds to exactly that set, and the golden had to be **cold
re-baked from scratch**. It is also the first station on the plane with **no DHCP
client in the guest** and **no exec channel** — everything below was driven and
proven through the framebuffer, the keyboard and a relative pointer.

Read [`WEB-PROXY.md`](WEB-PROXY.md) for the `:80` origin + wildcard DNS plane this
joins, [`GATEWAY.md`](GATEWAY.md) for CT 951, and [`ICQ-STATION.md`](ICQ-STATION.md)
for the win98se pathfinder whose bridge-swap and containment recipe this follows.

## The wiring, at a glance

| | |
|---|---|
| NIC | `rtl8139`, `-netdev tap,id=rn0,ifname=chokanjirn0` |
| Tap | `chokanjirn0`, persistent, enslaved to `vmbr-rn` (no uplink) |
| MAC | `RN_CHOKANJI_MAC` in gitignored `registry/local.env` (committed placeholder `02:00:00:00:00:15`) |
| Address | **static, in-guest** `10.99.0.21/24`, DNS `10.99.0.2`, **no default route** |
| Guard chain | `CHOKANJIRN-IN`, scoped to `10.99.0.21`, inserted above `RETRONET-IN` |
| Browser | **基本ブラウザ (BBB) R4.500** — UA `Mozilla/2.0 BBB/4.500 (BrightV/4.500)` |
| Helper | `streamhost/stations/chokanji/rn-tapnet.sh`, called `up` from the launcher |

## The NIC model was in the media all along — rtl8139

BTRON3's driver set is narrow and every wrong guess costs a cold boot, so the model
was **not** guessed. The archived media blob (`chokanji.zip`, sha256 `b8fd99a9…`)
contains `qemuckj.7z` — the QEMU-0.14-for-Windows port the original packagers
distributed *alongside this very `mc.img`* — and its launch script `q.bat` reads,
in full:

```
qemu -L . -m 256m -boot dc   -hda mc.img  -soundhw sb16,adlib -net nic,model=rtl8139 -net user
```

`pxe-rtl8139.bin` is also the only NIC option ROM in that port. So `rtl8139` is the
card this disk's B-right/V driver was shipped expecting, and it worked on the first
cold boot — ARP, ICMP and TCP all came up with no in-guest driver installation at
all. (`q.bat` is also where the station's `-soundhw sb16,adlib` audio lead comes
from; audio is still unwired.)

## No DHCP client — static on the reserved address

The guest obtains nothing automatically. B-right/V 4.202's network panel
(小物箱 → **ネットワーク環境設定**) is a fixed-size, static-only dialog: its single
**アドレス** tab offers 自ホスト / DNSサーバ1 / DNSサーバ2 / ドメイン名 /
ゲートウェイ / サブネットマスク and **no DHCP option anywhere**, and the guest emits
**no DHCP DISCOVER at boot** — with the tap sniffed from first instruction to
desktop, zero frames left the guest until the address was typed in by hand.

So chokanji is configured statically, which the plane accommodates:

| Field | Value |
|---|---|
| 自ホスト | `chokanji` / `10.99.0.21` |
| DNSサーバ1 | `10.99.0.2` |
| サブネットマスク | `255.255.255.0` |
| ゲートウェイ「使用する」 | **left UNCHECKED** |

Leaving the ゲートウェイ box unchecked is what gives the guest **no default route** —
the same no-WAN posture the other stations get from a DHCP reservation that
withholds option 3. The reservation for `10.99.0.21` still exists, and is still
worth having: it stops anything else on the plane being handed the address.

The panel writes to disk on 保存 (its right-button menu) and the settings survive a
cold reboot, which is what makes them safe to bake into a golden.

## Containment — the guest reaches the retronet and nothing else

Re-proven from inside the guest, by typing each address into the browser and
sniffing `chokanjirn0` at the same time:

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2` (`:80` corpus origin, `:53` DNS) | **serves** | intra-bridge L2 (the point) |
| `www.chokanji.com` → `10.99.0.2` | **resolves + renders**, no proxy | wildcard DNS (`retronet-dns`) |
| `personal-media.co.jp` → `10.99.0.2` | **resolves + renders** the period 404 | same |
| labhost bridge `10.99.0.1:80` | **SYN ×3, no reply**, browser hangs then サーバが見つかりません | the `CHOKANJIRN-IN` guard chain |
| internet `1.1.1.1` (by IP) | サーバが見つかりません, **zero frames on the tap** | no default route |

The internet row is the strongest of the three: the guest's stack could not even
form a packet, so nothing reached the wire to be filtered. The labhost row shows
the opposite shape — the guest *can* ARP for `10.99.0.1` (pure L2, expected) and
does emit SYNs, and the guard chain drops every one.

`retronet-fw` runs with `bridge-nf-call-iptables=0`, so guest↔CT traffic is pure L2
and never touches these chains — the retronet reaching the retronet.

## The browser — 基本ブラウザ, not "超漢字ブラウザ"

The registry declared `periodBrowser: "超漢字ブラウザ"`. That was curated metadata
and it was wrong in the same way winxp's "Internet Explorer 6" was wrong. What is
actually in this disk, as the guest itself reports it on the wire:

```
User-Agent: Mozilla/2.0 BBB/4.500 (BrightV/4.500)
```

`BBB` is Personal Media's **基本ブラウザ** ("Basic Browser") — confirmed from their
own site inside our corpus, which ships a page literally named `bbb4_012.html`
describing the「超漢字４ 基本ブラウザ R4.012 更新パッケージ」. So the browser is
**基本ブラウザ (BBB) R4.500**, and the registry now says so. Note the browser
reports 4.500 while the kernel in this disk is 4.202 — they version separately.

It is HTTP/1.0, opens several connections in parallel (the gateway logged nine
overlapping image GETs for one page load), speaks ISO-2022-JP natively, and needs
**no proxy configuration at all** — it resolves the typed host through DNS and
connects to the answer on `:80`, which is exactly what the wildcard-DNS plane is
built for.

### Launching it

The browser is one double-click away on the fixture desktop, with nothing to
install or arrange: the **原紙箱：B-right/V** window is already open on the right of
the golden, and **ブラウザ用紙** is its third row. Double-click it → BTRON asks
`新しい実身の名称を入力してください` → click 設定 → the browser opens **already on
`http://www.chokanji.com/`**, its shipped home page, which the corpus serves. A
visitor lands on the 超漢字 web site inside 超漢字 without typing anything.

## Driving BTRON from the framebuffer — what this cost

There is no exec channel, so everything went through QMP. Two traps are worth
recording because both produce *plausible wrong answers* rather than errors:

- **The pointer is accelerated.** BTRON scales relative deltas non-linearly, so
  open-loop positioning drifts badly (a 400,300 move landed at 485,325). The rig
  driver (`ptr.py`, kept in the sandbox) closes the loop instead: it parks the
  cursor in the bottom-left status bar once, keeps that frame as a baseline, and
  locates the cursor in each new frame by differencing against it. Two things that
  cost real time: the baseline's own parked cursor is a blind spot, so it must be
  parked somewhere already masked (the status bar) rather than in the top-left
  corner where it hides the 超漢字 window's icon column; and `screendump` returns
  **before** the file is flushed, so reading it early yields a truncated frame and
  a confidently bogus cursor fix.
- **The keyboard is JIS.** `:` is its own key (where a US board has the
  apostrophe); sending `shift-semicolon` yields `+`. This silently turned
  `http://…` into `http+//…` and produced a browser *URL-syntax* error that looked
  exactly like a failed connection — a containment "proof" that proved nothing.
  `scripts/dev/qmp-type.py`'s US map is wrong here for `:` and `=`.

Keyboard input itself is **verified working** on this station now (ASCII lands
clean), which `docs/guests/chokanji.md` previously recorded as UNVERIFIED.

## Golden lineage & rollback (FULL paths)

Adding the NIC changed the device set, so the pre-change `golden` could not be
carried forward — it was **cold re-baked**.

| | |
|---|---|
| Live disk (golden lives inside it) | `/data/gallery-guests/Chokanji/chokanji.qcow2` |
| **Pre-change backup** (disk + its golden) | `/data/gallery-guests/Chokanji/chokanji.qcow2.prern-2026-08-23` |
| Pre-change launcher | `/data/gallery-guests/Chokanji/qemu-streamhost.sh.prern-2026-08-23` |
| Pre-change disk sha256 | `cbdd7e2d44dbd557a5336e6cf2fe1f35d11d63333fc3f67c1c06900db5a7f088` |

The backup was taken with QEMU **stopped** and verified byte-identical to the live
disk before anything was touched. It is kept **next to the disk**, not in the
bring-up sandbox, deliberately: `wt.sh gc` prunes merged sandboxes, and a rollback
artifact that a routine cleanup can delete is not a rollback artifact.

**Rollback** (returns the station to its pre-retronet exhibit exactly):

```
ssh lab 'systemctl stop streamhost@chokanji'
ssh lab 'cp -a /data/gallery-guests/Chokanji/chokanji.qcow2.prern-2026-08-23 \
                /data/gallery-guests/Chokanji/chokanji.qcow2'
# revert streamhost/stations/chokanji/qemu-streamhost.sh to its pre-NIC form
ssh lab 'systemctl start streamhost@chokanji'
```

The disk is *also* reproducible from the archived media via
`scripts/build-guests/tiles/chokanji.sh`, but that is a rebuild, not a rollback —
it would not carry the network configuration.

## Operating it

- `ssh lab '/data/vms/streamhost/stations/chokanji/rn-tapnet.sh show'` — tap, master
  bridge and the guard chain as the kernel actually holds them.
- The tap is **persistent** and is the station's deliverable: it survives QEMU
  exiting and a host reboot, because the launcher calls `rn-tapnet.sh up`
  idempotently on every start. There is no separate systemd unit.
- `labctl reset chokanji` restores the golden — network up, static config intact,
  pointer working, browser one double-click away.
- To change the address, drive the guest's own panel (小物箱 →
  ネットワーク環境設定), 保存 from the right-button menu, and **re-bake the golden**;
  the address is in the disk, not in the launcher.
