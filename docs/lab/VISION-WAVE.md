# VisiCorp Visi On 1.0 integration wave — 2026-09-13

Visi On (VisiCorp, released December 1983) is the first integrated graphical
desktop shipped for the IBM PC: overlapping windows, a mouse, a "Services"
window that installs and launches Visi On Calc/Word/Graph, all on an 8088 with
CGA a year before the Macintosh. Part of the five-station wave of 2026-09-13
(`vision`, `oberon`, `fmtowns`, `magiccap`, `perq`; common contract in the
coordinator's `WAVE-COMMON.md`). Branch `vision`.

The Virtual OS Museum (reference only, CC BY-NC-SA — facts read, nothing
copied) runs it under PCE as an IBM 5160 XT; that is theory B below. The fleet
tier would be MAME's `ibm5160` host-native (theory A). Per rule 14 the two were
raced from minute 0, one `sonnet` runner each, on their own dirs under
`/data/vms/sandbox/vision/race/<theory>/`.

## Ledger — from `wave.sh alloc vision --x11warp`

| Field | Value |
|---|---|
| slot / UDP port / VMID | 194 / 54194 / 194 |
| x11warp display | `:94` (loopback `127.0.0.1:6094`) — allocated; unused unless the winner is an X11-captured sandbox |
| retronet | **none** — skipped on purpose: Visi On has no TCP/IP stack (PC-DOS 2.00, 1983) |
| ICQ UIN | none |
| sibling (`--like`) | see §Race verdict |
| render orders | as scaffolded by `stations-registry.py new` — never hand-edited |
| device set | IBM 5160 XT: 8088 @ 4.77 MHz, 640 KB, CGA, two 360 KB floppies, 10 MB XT fixed disk (306/4/17), serial card on COM1 carrying a Mouse Systems-protocol serial mouse (the "VisiCorp mouse Model M1"), 83-key XT keyboard |
| media | see `scripts/build-guests/tiles/vision.sh` (URL + sha256 + byte size per file); staged by the `vision-media` agent under `/data/assets-staging/vision/` |

### Facts that shape the station (from the VOM readme + the 0.289 source, verified)

- Visi On needs PC-DOS 2.00 on a FAT16 10 MB hard disk, 640 KB, CGA and the
  serial mouse. It drives the 8250 itself: **no DOS mouse driver**.
- Copy protection: `VOAPP1` (Application Manager disk 1) is the **key disk** and
  must be in A: whenever Visi On starts. The disks ship as TransCopy `.tc`
  flux-ish images; PCE reads `.tc` but cannot write it, its `psi` tool
  converts to `.psi` which keeps the protection.
- Install, once: at `C:\>` type exactly `A:VINSTALL`, choose VisiCorp mouse
  Model M1 on COM1, swap to disk 2 when asked, put disk 1 back; then `VISION`.
- Visi On is unreliable on faster CPUs — the emulated machine stays XT-class
  (PCE `cpu.speed` multiplier is the only throttle knob worth touching).
- MAME `ibm5160` (0.289, `src/mame/pc/ibmpc.cpp`): slots default to
  `isa1 cga`, `isa2 com`, `isa3 fdc_xt`, `isa4 hdc`; the `hdc` card carries
  its own `wdbios.rom`; the rs232 option `msystems_mouse` is the Mouse
  Systems HLE mouse (`src/devices/bus/rs232/rs232.cpp`).
- PCE (VOM's shape, rewritten): `system { model = "5160" boot = 128 }` boots
  C: directly so the key disk can stay in A:; `serial { driver =
  "mouse:protocol=msys" }` on 0x3f8/IRQ4; `terminal { driver = "x11" }`.

## Race — rule 14

| Theory | Runner | Where | Result | Frame |
|---|---|---|---|---|
| A. MAME `ibm5160` host-native (fleet tier, `--like samcoupe`) | sonnet | `/data/vms/sandbox/vision/race/mame/` | pending | |
| B. PCE `pce-ibmpc` in systemd-nspawn (VOM-proven, `--like lisa`) | sonnet | `/data/vms/sandbox/vision/race/pce/` | pending | |

### Race verdict

Pending.

## Sandbox

Pending the verdict. If A wins: emulated machine under the fleet MAME, the
visitor's reach ends at the emulated 5160 — the launcher line goes here. If B
wins: PCE is a stock host application and runs under the full nspawn contract
(uid base 2162688, `--private-network`, `--volatile=overlay`, capability drop,
`~@mount` filter, Xvfb inside); the audit block from the running rig goes here.

## Proofs (framebuffer only — rule 9)

Pending.

## OPEN items

Pending.

## Measured timeline

| Milestone | Wall clock (UTC) | Minute |
|---|---|---|
| `wave.sh alloc` | 2026-09-13T05:13:46Z | 0 |

## Teardown

Pending.
