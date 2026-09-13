# magiccap guest — General Magic's Magic Cap for Windows (pre-release build 327)

Status: **production, landed 2026-09-13** (Tier 1, QEMU, `--like win98se`). See
`docs/lab/MAGICCAP-WAVE.md` for the wave that produced this station — the
ledger, the WIN.INI trap, the mouse-move trap, and the first-run name-card gate.

**Guest:** General Magic's **Magic Cap for Windows**, PRE-RELEASE **build 327**
(1995), run as a Windows application (`C:\MAGICCAP\MCW.EXE`) inside a
win98se-class Windows 98 SE guest — not a native OS station. Same emulated
i440fx device set as win98se; the only device-level difference is the NIC
backend (slirp here, not the retronet tap).

## Identity and source

- Public ID / tile directory: `magiccap`
- Reserved slot / UDP port / VMID: `197` / `54197` / `197`
- Archetype: `beige-tower-crt`
- Guest media: archive.org item `magic-cap`, file `magic-cap.zip`, sha256
  `56aab195329b71739796682c946bf118b594c6f9afb61f735a4aac6cba9f147f`, size
  1,987,906 bytes. Unpacks to `MCW.EXE` (3,812,864 bytes, PE32 GUI i386,
  dated 1995-11-21) plus its support DLLs, help/data, `README.WRI` /
  `ATTPLS.WRI`, a `MODEM/` directory of 34 `.MDM` profiles, and an empty
  `DATA/`.
- **MEDIA VERDICT — OPEN operator item, do not soften**: the **Magic Cap 3.1
  Windows simulator (`MagicCAP-USA.exe`) is NOT sourceable at any open
  origin** — it exists only inside the Virtual OS Museum (reference only,
  CC BY-NC-SA, never copied) and behind login-gated forum accounts. What
  ships in this station is the 1995 pre-release build 327 instead. Every
  museum-facing description of this station must say "pre-release build
  327", never "3.1", until the operator sources `MagicCAP-USA.exe` from a
  login-gated forum account they control.

## Build and device set

- Builder: `scripts/build-guests/tiles/magiccap.sh` (order 82, `class: retro`,
  `~10-15m`, `automation: 1-click`) — fetches, verifies, and composes Magic
  Cap onto a win98se-base C: image; produces `magiccap-c.qcow2` +
  `magiccap-d.qcow2`.
- Launcher: `streamhost/stations/magiccap/qemu-streamhost.sh`. Device set id
  `magiccap-current` (golden + binary + device set are ONE combination —
  rule 6):
  - `qemu-system-x86_64` (pve-qemu-kvm 11.0.2), `-machine
    pc-i440fx-11.0,acpi=on -enable-kvm -cpu pentium3`
  - 384 MB RAM, `-smp 1`, `-rtc base=localtime`, `-boot c`
  - `-vga std`, display `dbus,p2p=on,audiodev=snd0`
  - Storage: two IDE qcow2 disks, `if=ide` index 0 (C:, `magiccap-c.qcow2`)
    and index 1 (D:, `magiccap-d.qcow2`); the `savevm golden` vmstate lives
    inside `magiccap-c.qcow2` itself, same mechanism as every other
    qcow2-backed streamhost tile
  - Audio: `sb16` on the dbus audiodev
  - NIC: `pcnet` on `-netdev user,id=n0,restrict=on` — fleet **slirp**, not
    the retronet tap win98se uses (see §Sandbox)
  - Input: `-usb -device usb-tablet,id=tab0`
- Ready framebuffer: the Desk room (clock, In/Out message trays, telephone,
  notepad, datebook, file cabinet, Hallway door) at 640x480, autostarted from
  the `HKLM\...\CurrentVersion\Run` value `MagicCap` = `C:\MAGICCAP\MCW.EXE`
  (see the WIN.INI trap below) — no bounded automation needed once the golden
  loads.

## §Pointer

**Absolute, `qemu-usb-tablet` on a fleet-standard USB tablet device.**
`SH_POINTER=abs`, `stream.pointer.transport` = `abs`. No `kh-ramabs` trick
needed here — Magic Cap, hosted as a Windows application, reads the standard
Windows mouse driver over the USB tablet like win98se.

**Trap (see `docs/lab/MAGICCAP-WAVE.md`): the HMP `mouse_move` helper is a
no-op against this station's `usb-tablet` device** on this QEMU 11.0.2 build
— three consecutive calls with different targets produced byte-identical
screendumps. The working path is the QMP protocol-level `input-send-event`
with `abs` axis events scaled `round(px / 640 * 32767)` /
`round(py / 480 * 32767)`, then separate `btn` down/up events for a click.

**Proof (2026-09-13), five targets, two laps, on a clone:**

| commanded | landed |
|---|---|
| (20,20) | (20,19) |
| (620,20) | (619,19) |
| (20,460) | (20,459) |
| (620,460) | (619,459) |
| (320,240) | (320,240) |

Worst error **1.41 px**; both laps byte-identical (no drift between passes).
A click at **(478,262)** opened the Datebook (`fb-react` changed=92423 —
the guest visibly reacted).

## §WIN.INI trap

`WIN.INI`'s `run=` line takes a **space-separated list** of programs, so
`run=regedit /s C:\MC.REG` launches `regedit` and then tries to run a program
literally called `s`, producing a "Could not load or run 's'" dialog on every
boot. The golden does **not** use this line. Autostart is instead the
registry Run key
(`HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Run` value
`MagicCap` = `C:\MAGICCAP\MCW.EXE`), applied once via `regedit /s C:\MC.REG`.
The same `.reg` sets the guest's `Resolution` to `640,480` and removes the
inherited win98se "Mirabilis ICQ" autostart. Do not "fix" this by adding a
`run=` line back.

## §Checkpoint

- Reset mode: `loadvm golden`, resetMode as declared in `reset.resetMode`.
- **Restore proof, live measurement**: `loadvm golden` restore settles in
  **~1.5 s**. A residual 69-px framebuffer diff against the pre-kill frame is
  the cursor overlay / a modal repaint, not state drift.
- **Idle-pause**: verified paused at the fleet default **60 s** of no input.
- First-run gate: the golden was re-baked past Magic Cap's first-click
  "Filling out your name card" modal — a click on any desk object now opens
  it directly, no modal. See `docs/lab/MAGICCAP-WAVE.md` §Proofs for the
  wizard walkthrough that cleared it and the keyboard proof (`Visitor` typed
  into the Name dialog's first-name field via `qmp-type.py`).
- Golden fixture: `reset.fixture` / `museum.notes` — the Desk room described
  above, both IDE qcow2 disks intact. **Never delete or replace either qcow2
  without recapturing golden first** (`checkpoint-guard recapture magiccap`)
  — doing so throws away the only copy of the fixture.
- Credentials reference only (never values): `guest/magiccap`.
- Rollback: keep golden + binary + device set (`magiccap-current`) together
  as one combination (rule 6) until any replacement is restore-proven.

## §Sandbox

**Emulated machine under the fleet QEMU — nothing runs outside it.** No
9p/virtfs/SMB share and no `fat:` host-directory drive (the two IDE disks are
qcow2 files opened by QEMU itself). No hostfwd port and no host
virtio-serial channel. QMP is a unix socket under the station's own host dir
(`/data/vms/streamhost/stations/magiccap/qmp.sock`), never reachable from
inside the guest. The NIC is fleet **slirp** with `restrict=on`, not the
win98se retronet tap — this station has **no retronet join** (rule 15: a
committed `rn-tapnet.sh` ships fleet-wide on the next `box-deploy --apply`,
and there is none for this station), so there is nothing on the other end of
the wire even if a guest process tried.

## Known gaps / next

- **Magic Cap 3.1 is not sourceable** — see §Identity and source. Operator
  item.
- Retronet web plane: none — see §Sandbox and §WIN.INI trap above; no
  `rn-tapnet.sh` committed for this station.
- IM plane: n/a, no client is installed for this guest.
- `/os/magiccap` smoke rig not published (`smoke-rig.sh` not run).
- Cosmetic: the C: image still carries win98se's inherited desktop icons
  (ICQ, Opera, AOL) alongside Magic Cap.
