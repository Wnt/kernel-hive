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
| `golden` | bake + restore proof + framebuffer proofs, owned entirely by the station lead on the box | Opus (station lead) | **[PLACEHOLDER — lead fills in: golden bake result, frame paths, restore proof]** |
| `spa` | poster, hero, scene rows (`assembliesByTile.ts`/`machineIdentity.ts`) | Sonnet 5 (repo-side agent, via `spa-scene-rows.py --row-from`) | landed this wave |
| `docs` | `docs/guests/magiccap.md` | scaffold stub only — **[PLACEHOLDER — needs the lead's measured facts before this is more than a stub]** |

## Walls hit

None recorded by the repo-side stream. **[PLACEHOLDER — the station lead
records any bring-up walls hit during the bake here, with the theories raced
and the framebuffer evidence, per rule 14.]**

## Landing

Not yet landed to a `station-up.sh`/`station-land.sh` pass. **[PLACEHOLDER —
paste `station-land.sh magiccap --golden <staged.qcow2>` output here once the
lead's golden is staged.]**

## Proofs

**[PLACEHOLDER — station lead fills in, per the wave template's proof list:
`labctl shot magiccap` before/after a key send, restore-from-golden proof,
and anything else rule 9 (the framebuffer is the only proof) requires. Do not
invent frame paths or proof results here — this section is empty until the
lead reports them.]**

## OPEN items

- **Magic Cap 3.1 is not sourceable** (see §Media) — operator must source
  `MagicCAP-USA.exe` from a login-gated forum account before this station can
  ship the real 3.1 simulator instead of the 1995 pre-release.
- Golden bake, restore proof, and keyboard/pointer proofs are the station
  lead's open work — see the placeholders above.
- `docs/guests/magiccap.md` is a scaffold stub; needs the lead's measured
  facts (the same shape as `docs/guests/win9x.md` but for the Magic Cap
  fixture specifically) before promotion.
- Disk paths in `qemu-streamhost.sh` (`magiccap-c.qcow2` / `magiccap-d.qcow2`
  under `/data/vms/streamhost/assets/magiccap/`) are inferred from the
  win98se pattern, not yet confirmed against where the lead's bake actually
  wrote them — confirm and correct before this station goes live.

## Measured timeline

**[PLACEHOLDER — run `scripts/dev/session-timeline.py` on the full session
transcript once both streams (repo + lead) have landed; this repo-only stream
does not have visibility into the lead's wall-clock on the box.]**
