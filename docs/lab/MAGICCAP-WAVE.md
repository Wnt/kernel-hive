# Magic Cap for Windows (pre-release build 327) integration wave — 2026-09-13

General Magic's Magic Cap for Windows, PRE-RELEASE build 327 (1995), a Windows
application (`MCW.EXE`) run as the sole autostarted app inside a win98se-class
Windows 98 SE guest — Tier 1, `--like win98se`. Repo-side work (this doc,
registry row, streamhost launcher, tile builder) was done by a repo-only agent
while the station lead owned the guest/QEMU bake and proofs directly on the box
under `/data/vms/sandbox/magiccap/{smoke,inject,build}`.

## Ledger

| Field | Value |
|---|---|
| slot / UDP port / VMID | 197 / 54197 / 197 |
| x11warp display | `:97` (claimed, but **unused** — this is a `dbus,p2p=on` display-plane guest like win98se, not an x11warp station) |
| retronet address | none — this station does not join retronet (see §Sandbox) |
| retronet MAC | n/a |
| retronet tap / chain | n/a — no `rn-tapnet.sh` for this station (AGENTS.md rule 15: a tap script ships fleet-wide the next `box-deploy --apply`, and there is no proven retronet join here) |
| ICQ UIN | n/a |
| sibling (`--like`) | `win98se` |
| render orders (signal/stationsManifest/binding/golden/actionMap/bringUp) | as scaffolded — not hand-edited |
| device set | tuple `pizzaBoxB,crtC,keyboardB,paramMouseB` (distinct from win98se's `towerC,crtC,keyboardB,paramMouseB`); storage: 2x IDE qcow2 (`if=ide`, index 0/1); NIC: `pcnet` on **slirp** `-netdev user,id=n0,restrict=on` (win98se uses a bridged tap — see §Sandbox for why this station differs) |
| media | archive.org item `magic-cap`, file `magic-cap.zip`; sha256 `56aab195329b71739796682c946bf118b594c6f9afb61f735a4aac6cba9f147f`; size 1987906 bytes |

## Media

**What ships**: the archive.org item `magic-cap` unpacks to `MCW.EXE`
(3812864 bytes, PE32 GUI i386, dated 1995-11-21) plus its support DLLs
(`MCCOM16.DLL`, `MCCOM32.DLL`, `MCCOM32S.DLL`, `MCMAIL16.DLL`, `MCMAIL32.DLL`,
`MCWLRPC.DLL`), help/data (`MCW.HLP`, `MCW.ICO`, `CALC.PKG`, `HELPBOOK.PKG`,
`IMPORT.PKG`, `MERGEMR.PKG`), `README.WRI` / `ATTPLS.WRI`, a `MODEM/` directory
of 34 `.MDM` modem profiles, and an empty `DATA/`. `README.WRI` states the
minimum host is Windows 3.1 / WfW 3.11 / Windows 95, 486dx-33+, 8 MB RAM, 8 MB
disk, and Win32s 1.25 on the 16-bit hosts — we host it on Windows 98 SE, where
Win32s is not needed.

**MEDIA VERDICT — OPEN operator item, do not soften**: the **Magic Cap 3.1
Windows simulator (`MagicCAP-USA.exe`) is NOT sourceable at any open origin.**
It exists only inside the Virtual OS Museum (reference only, CC BY-NC-SA, never
copied — see `virtual-os-museum-reference.md`) and behind login-gated forum
accounts. The coordinator's full search log is on LABHOST at
`/data/assets-staging/magiccap/SOURCES.md`; the short version is that every
open mirror, archive.org search, and abandonware index that carries Magic Cap
material has only this 1995 pre-release build 327, never the 3.1 retail
simulator. What ships in this station is build 327 instead.

**OPEN for the operator**: source `MagicCAP-USA.exe` (3.1) from a login-gated
forum account the operator controls, then re-bake this station on the real
3.1 simulator. Until then, every museum-facing description of this station
must say "pre-release build 327", never "3.1".

## Sandbox

**Verdict: emulated machine under the fleet QEMU.** The visitor's reach ends
at the emulated i440fx PC — there is no path from the guest to the host or to
anything else on the box:

- No 9p/virtfs/SMB share and no `fat:` host-directory drive — the two IDE
  disks are qcow2 files opened by QEMU itself, never a host path exposed
  inside the guest.
- No hostfwd port and no host virtio-serial channel.
- QMP is a unix socket under this station's own dir on the host
  (`/data/vms/streamhost/stations/magiccap/qmp.sock`), never reachable from
  inside the guest.
- The NIC is fleet **slirp** with `restrict=on`, not the win98se retronet tap
  — this station has no retronet join (see the ledger and rule 15 above), so
  there is nothing on the other end of the wire even if a guest process tried.

Launcher line (the load-bearing part):

```
-netdev user,id=n0,restrict=on -device pcnet,netdev=n0,mac=02:00:00:00:00:c5
```

Full device set (same as win98se's, apart from the NIC backend):

```
-enable-kvm -m 384 -smp 1 -machine pc-i440fx-11.0,acpi=on -cpu pentium3 \
-rtc base=localtime -boot c -vga std -display dbus,p2p=on,audiodev=snd0 \
-audiodev dbus,... -device sb16,audiodev=snd0 \
-drive file=<C>,format=qcow2,if=ide -drive file=<D>,format=qcow2,if=ide,index=1 \
-usb -device usb-tablet,id=tab0
```

**Pointer**: `qemu-usb-tablet`, absolute — same as win98se. Proven this
session: an abs click at guest coordinate (553,221) landed on target.

## WIN.INI trap

WIN.INI's `run=` line takes a **space-separated list** of programs, so
`run=regedit /s C:\MC.REG` launches `regedit` and then tries to run a program
literally called `s` — it produces a "Could not load or run 's'" dialog on
every boot. Only a single-token command belongs on that line. Autostart is
instead the registry Run key
(`HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Run` value
`MagicCap` = `C:\MAGICCAP\MCW.EXE`), applied once via `regedit /s C:\MC.REG`
(imported from Start > Run, never from WIN.INI). The same `.reg` sets
`HKEY_LOCAL_MACHINE\Config\0001\Display\Settings` `Resolution`="640,480" and
removes the inherited win98se "Mirabilis ICQ" autostart. Frame:
`/data/vms/sandbox/magiccap/smoke/f-boot2.png`.

## Streams

| Stream | Owns | Model | Status |
|---|---|---|---|
| `build` | `scripts/build-guests/tiles/magiccap.sh` (fetch+verify+compose), registry row, streamhost launcher/fixture, this doc | Sonnet 5 (repo-side agent) | done this wave |
| `golden` | bake + restore proof + framebuffer proofs, owned entirely by the station lead on the box | Opus (station lead) | **golden baked and restore-proven this wave** — see §Proofs |
| `spa` | poster, hero, scene rows (`assembliesByTile.ts`/`machineIdentity.ts`) | Sonnet 5 (repo-side agent, via `spa-scene-rows.py --row-from`) | landed this wave; hero (`spa/public/posters/magiccap/desktop.webp`, 1024x768) supplied by the station lead from the restore frame, confirmed NOT overwritten by the scaffold's placeholder |
| `docs` | `docs/guests/magiccap.md` | scaffold stub only — **[PLACEHOLDER — needs the lead's measured facts before this is more than a stub]** |

## Walls hit

None recorded that needed a raced theory. The one boot-time surprise (the
WIN.INI `run=` trap, see above) was diagnosed directly from the framebuffer,
not raced — it is a single-token misuse, not an ambiguous failure.

## Landing

Not yet run through `station-land.sh`. The station lead's golden and both
disks were promoted this session: `/data/vms/sandbox/magiccap/smoke/disk-c.qcow2`
(carries the re-baked `golden`, past the first-run name-card gate) and
`disk-d.qcow2` are copied to `/data/vms/streamhost/assets/magiccap/magiccap-c.qcow2`
and `magiccap-d.qcow2` (the path `qemu-streamhost.sh` assumes), `qemu-img
snapshot -l` on the promoted copy confirms `golden` at `2026-09-13 09:57:15`.
The sandbox copy is kept as the `--golden` argument for
`station-land.sh magiccap --golden /data/vms/sandbox/magiccap/smoke/disk-c.qcow2`.

## Proofs (measured by the station lead, frames on labhost)

- **Cold boot, no manual step**: Magic Cap splash then the expected "Your
  modem isn't setup correctly" dialog (no modem is configured — expected and
  harmless) — `/data/vms/sandbox/magiccap/smoke/f-desk.png`. Timings: Win98
  splash settled 138.8 s after power-on; the Magic Cap dialog settled a
  further 63.4 s after that.
- **Desk view, autostarted from the HKLM Run key**: `/data/vms/sandbox/magiccap/smoke/desk2/cur.png` — 640x480, matches the fixture description above.
- **`savevm golden` succeeded**: vmstate 130 MiB, tag `golden`, captured
  2026-09-13 09:37:17, stored inside `disk-c.qcow2` (the same qcow2-carries-
  the-snapshot mechanism every streamhost tile uses). `info snapshots` also
  lists a stale, non-loadable partial `icqinstalled` snapshot on `ide0-hd1`,
  inherited from the win98se base disk — harmless, not used.
- **Restore proof**: process killed, relaunched with `-loadvm golden -S` +
  `cont`, came back to the identical Magic Cap desk —
  `/data/vms/sandbox/magiccap/smoke/restore/cur.png`.
- **Pointer, two-target readback** (`qemu-usb-tablet`, absolute): commanded
  (120,140) → cursor drawn at (119,141); commanded (520,360) → drawn at
  (520,361). ±1 px, no drift. Frames:
  `/data/vms/sandbox/magiccap/smoke/ptA/cur.png`,
  `/data/vms/sandbox/magiccap/smoke/ptB/cur.png`.
- **Click opens a desk object**: a click at (478,262) on the desk's datebook
  made Magic Cap react — it opened the first-run "Filling out your name card"
  card. Frame: `/data/vms/sandbox/magiccap/smoke/obj/cur.png`.
- **WIN.INI trap, confirmed with a frame**:
  `/data/vms/sandbox/magiccap/smoke/f-boot2.png` shows the resulting "Cannot
  find the file 's'" dialog.
- **First-run name-card gate cleared and golden re-baked** (this session):
  relaunched `-loadvm golden -S` + `cont`, clicked the datebook (478,262) to
  raise the "Filling out your name card" modal
  (`/data/vms/sandbox/magiccap/smoke/click1.png`), clicked "fill out" at
  (356,222) (`click2.png`), then walked the resulting 5-step "Add your card"
  wizard: step 1 click the name-card collection (`click3.png`), step 2 "next"
  (`click4.png`), step 3 "new" (`click5.png`), step 4 "person" (`click6.png`),
  the Name dialog's first-name field — **this is the keyboard proof**: typed
  `Visitor` via `qmp-type.py`, landed correctly in the field
  (`/data/vms/sandbox/magiccap/smoke/typed/cur.png`), clicked "done"
  (`click8.png`), step 5 "done" (`click9.png`), landing back on the Desk
  (`click9.png`). Confirmed the gate is gone: the Notebook opens directly on
  click (`click10.png`) and the Datebook opens directly on click
  (`click12.png`), no modal either time. `savevm golden` recaptured the same
  tag at `2026-09-13 09:57:15` (overwriting the earlier pre-gate golden),
  `info snapshots` confirms only the one loadable `golden` tag.
- **Restore proof, post-recapture**: process killed by `/proc/<pid>/exe`
  (never `pkill -f` — this session's own ssh command line contains the
  strings "magiccap" and "qemu" and would have matched itself), relaunched
  `-loadvm golden -S` + `cont`, came back to the identical Magic Cap desk
  (`/data/vms/sandbox/magiccap/smoke/restore2.png`), and a click on the
  datebook opens it directly with no modal
  (`/data/vms/sandbox/magiccap/smoke/restore3.png`) — the gate stays cleared
  across a restore.
- **Keyboard**: measured this session (see above) — `Visitor` typed cleanly
  into the Name dialog's first-name field at the fleet floor gap (qmp-type.py
  default 0.12 s/key).

### Mouse-move trap (new this session)

`qmp-type.py --mouse DX DY` issues HMP `mouse_move`, which on this station's
QEMU 11.0.2 build is a no-op against the `usb-tablet` absolute device: three
consecutive calls with different targets produced byte-identical screendumps
(cursor never moved). The working path is the QMP protocol-level
`input-send-event` with `abs` axis events scaled `round(px / 640 * 32767)` /
`round(py / 480 * 32767)`, then separate `btn` down/up events for a click —
this is what produced every click/type frame in this session
(`/tmp/qclick.py` on labhost, ad hoc). The wave doc's earlier "two-target
readback" proof (commanded (120,140) → drawn (119,141)) must have used this
same abs-event path, not the HMP helper's `--mouse` flag; worth fixing in
`qmp-type.py` itself so future stations do not lose time on this.

## OPEN items

- **Magic Cap 3.1 is not sourceable** (see §Media) — operator must source
  `MagicCAP-USA.exe` from a login-gated forum account before this station can
  ship the real 3.1 simulator instead of the 1995 pre-release.
- **First-run name-card gate — CLEARED this session**: the "Add your card"
  wizard was completed once against the golden and `savevm golden` recaptured
  past it; restore-proven (see §Proofs). No longer open.
- **Keyboard — measured this session** (see §Proofs). No longer open.
- **`/os/magiccap` smoke rig not published** — `smoke-rig.sh` has not been
  run for this station.
- x11warp display `:97` is claimed but **unused** — this is a `dbus,p2p=on`
  display-plane guest, not an x11warp station (see §Sandbox).
- **Disk promotion — DONE this session**: promoted to
  `/data/vms/streamhost/assets/magiccap/{magiccap-c,magiccap-d}.qcow2` (see
  §Landing). The sandbox smoke copy is kept for `station-land.sh --golden`.
- **Cosmetic**: the C: image still carries win98se's inherited desktop icons
  (ICQ, Opera, AOL) alongside Magic Cap.
- `docs/guests/magiccap.md` is a scaffold stub; needs the lead's measured
  facts (the same shape as `docs/guests/win9x.md` but for the Magic Cap
  fixture specifically) before promotion.

## Measured timeline

**[PLACEHOLDER — run `scripts/dev/session-timeline.py` on the full session
transcript once both streams (repo + lead) have landed; this repo-only stream
does not have visibility into the lead's wall-clock on the box.]**
