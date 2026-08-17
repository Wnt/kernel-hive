# Adding pre-reset Windows Longhorn (and the WinFS question)

Status: **research, 2026-08-09.** Nothing is built, no registry entry exists, no
slot is claimed. This is the feasibility study
[`ADD-NEW-OS-PLAYBOOK.md`](../ADD-NEW-OS-PLAYBOOK.md) §1 expects before a
candidate enters the backlog.

**Verdict: Tier 3. Feasible as a desktop, NOT as a "WinFS machine".** It boots
under plain QEMU/KVM on the first try and takes a stock `usb-tablet` absolute
pointer — but it costs **1.09 GB RSS and a full core at idle**, and WinFS is
invisible to a visitor. Recommendation: **do not build it as pitched.** If built,
it ships as a pre-reset Longhorn *desktop* with WinFS as placard prose.

---

## 1. The premise, corrected

The request was "Longhorn that uses WinFS as the root FS". **That never
existed.** Longhorn always booted NTFS. WinFS was a storage *service* on a SQL
Server "Yukon"-derived relational engine whose store lived as ordinary files on
an NTFS volume, and the user-visible mount illusion was a **shell namespace
extension**, not a filesystem mount.

Not just sourced — **measured**. A real Longhorn 4074 installation mounted
read-only on labhost has the store exactly where the architecture predicts:

```
/System Volume Information/WinFS/{C11E8244-9F02-44F2-9541-CF9775EE75ED}/
    database.mdf  database.ldf  filestream/  filestream_log/  ftdata/config.xml
```

116 MB of SQL Server database files inside `System Volume Information` on an
NTFS C:, with three host processes in `%SystemRoot%\system32\WinFS\`:
`WinFS.exe -s WinFS`, `WinFPM.exe` (File Promotion Manager), `WinFS-Rules.exe`.
Quentin Clark, WinFS PM: *"from that point forward the semantics were exactly
like NTFS. Because it **was** NTFS at that point."*

## 2. Which build — and the reference screenshot needs re-reading

| | **4051** PDC 2003 | **4074** WinHEC 2004 | **4093** last pre-reset |
|---|---|---|---|
| Tag | `6.0.4051.idx02.031001-1340` | `6.0.4074.idx02.040425-1535` | `6.0.4093.0.main.040819-1215` |
| WinFS | **NO — service does not exist** (measured) | **YES**, `Start=2`, store present (measured) | present but broken |
| Key | `CKY24-Q8QRH-X3KMR-C6BCY-T847Y` | `TCP8W-T8PQJ-WWRRH-QH76C-99FBW` | same as 4074 |
| Timebomb | +180 d **from install**, blocks login not boot | +180 d | +180 d |
| Installs today | yes (relative bomb) | yes | *"often fails"*, safe mode bugchecks `0x7B` |

**Later is worse, not better.** WinFS peaked around 4020–4029 and degraded
through 4074 to 4093. 4093 is out (unstable). 4051 is out for a WinFS exhibit
(no engine at all).

**Unresolved, and it decides the build:** the operator's reference screenshot
shows the **Plex** visual style with an Aero sidebar. Per
[BetaWiki](https://betawiki.net/wiki/Plex), Plex was replaced by **Slate** in
build 4042 (Lab06_n) — and the study's own running 4051 rendered grey Slate
chrome with no sidebar, consistent with that. If the Plex reading is right the
screenshot is a **~4008–4042 build, most likely 4020/4029**, not 4074.

That would be convenient: **4020 is also the better WinFS build** (BetaWiki's
4020 gallery captions a screenshot "Working WinFS libraries") and its timebomb is
**+445 days from install**, the most forgiving of any candidate; key
`CKY24-Q8QRH-X3KMR-C6BCY-T847Y`.

**Read the watermark in the screenshot before choosing.** The bottom-right
evaluation watermark states the build verbatim, and it beats any inference from
theme. If it says 4074, then Plex on 4074 needs explaining (a modified repack
would do it) — and that itself is a reason to prefer vanilla media.

## 3. It boots under KVM, first try

**Positive result, framebuffer-proven.** Build 4051 reached a full autologon
desktop under plain QEMU/KVM — no TCG, no CPU masking, no HAL fiddling. Desktop
up in ~120 s; watermark `Build 4051.idx02.031001-1340`; `cmd` reports
`Microsoft Windows [Version 6.0.4051]`.

```
qemu-system-x86_64 -machine pc-i440fx-11.0 -enable-kvm -cpu host \
  -m 1024 -smp 1 -rtc base=2003-10-01T09:00:00,clock=vm \
  -drive file=WL4051.qcow2,if=ide,index=0,media=disk,cache=unsafe \
  -vga cirrus -usb -device usb-tablet \
  -netdev user,id=n0 -device rtl8139,netdev=n0 -display none
```

Constraints to pin in the builder:

- **`-vga cirrus` is required** — `std`/qxl/virtio glitch severely. Note this
  **diverges from `win2000`/`winxp`/`win98se`, which all ship `-vga std`.**
- **`-smp 1`, mandatory.** Multi-core hangs the OS seconds after login.
- **IDE only.** No AHCI, no SCSI; mixing yields `Error loading operating system`.
- **F5 → "Standard PC"** at text-mode setup when installing from ISO.
- **PS/2 mouse is broken in the 4074/4093 WinPE installer** — USB pointing must
  be present from the very first boot, not just post-install.
- `-rtc base=<date>,clock=vm` is the honest timebomb handling.

**The negative result: do not build on someone else's prebuilt image.** The
archive.org prebuilt 4074 VDI — the obvious shortcut — **boots but cannot hold a
session.** It reaches the logon UI cleanly, then on logon the video mode drops
800×600 → 640×480 and it bounces straight back to `Press Ctrl+Alt+Delete`.
Reproduced 4×, with the obvious causes eliminated: Administrator password
already `*BLANK*` (`chntpw -l SAM`), `InstallDate` = 2004-04-28 so the RTC was
inside the 180-day window, retried at 2004-04-29, and `AutoAdminLogon=1`
injected offline via `hivexregedit`. A real station needs a real install from ISO.

## 4. WinFS is not demonstrable — and this is what breaks the pitch

**(a) 4051 shows WinFS chrome with no engine behind it.** `Computer` displays a
`Storage (1)` group → `Games`, Type `Storage` — the shell namespace extension —
and opening it gives a **green** toolbar band with schema-typed columns
**`Title | Genre | Publisher | Developer`**. Unmistakably a relational item type.
But it is **empty**:

```
C:\> tasklist | find /i "winfs"     → (no output)
C:\> sc query WinFS
[SC] EnumQueryServicesStatus:OpenService FAILED 1060:
The specified service does not exist as an installed service.
```

`My Documents` in the same session is a plain NTFS folder — **blue** band,
`Name | Size | Type | Date Modified`. **That blue-vs-green contrast is the
cleanest single visual the exhibit could offer**, and on 4051 the green side is
hollow.

**(b) On 4074 the engine is real but off by default.** Registry shows `WinFS`
and `WinFPM` at `Start=2` on the mounted image with a live 116 MB store — but a
*stock* 4074 requires setting **`SAM WinFS Account Store`** and **`Computer Data
Synchronization Manager`** to Automatic. BetaWiki also warns of *"major memory
leaks"* when WinFS is enabled.

**(c) The honest sentence:** *a visitor standing in front of a stock Longhorn
station sees a slightly odd Windows XP.* WinFS is a background service whose only
shell surface is a folder whose columns say `Genre` and `Publisher` instead of
`Size` and `Date Modified`. Lovely for someone who knows; nothing at all to
anyone else.

**The alternative that actually shows WinFS: WinFS Beta 1** (2005-08-29) is the
only configuration with a deliberate UI — stores as top-level objects in My
Computer, My Documents redirectable into a store, plus the **StoreSpy** browser
(Items, Relationships, MultiSets, saved searches, graphical Rules view) and the
**WinFS Type Browser**. It runs on **Windows XP SP2 + .NET 2.0** — and the
gallery already has a `winxp` station with a builder. ISO fetched and hashed below.
If the thesis is "see WinFS", this is cheaper and more honest than any Longhorn
build, at the cost of a strange pitch: WinFS running on the OS it was meant to
replace.

## 5. Media and licence

**Class: preservation-source / unlicensed.** Every image is an unauthorised copy
of pre-release Microsoft software; none carry a licence tag; bundled NFOs are
warez-scene notes. Posture unchanged: **URL + measured sha256 + size + class in
`ASSETS-MANIFEST.md`, never the bits.** Repo public, gallery passkey-private,
streaming pixels is fine.

**archive.org is directly fetchable from labhost — no operator action, no
BetaArchive dependency.** All five fetched and hashed:

| File | sha256 | Size |
|---|---|---|
| `lh_usa_4074_x86fre_pro-dvd.iso` | `1799588a…4b6dcd` | 832 563 200 |
| `Windows Longhorn 4051.7z` | `8d981c53…7fc23cf` | 737 914 629 |
| `Windows Longhorn Build 4074.vdi` | `f49e5e2c…97ef0e` | 3 383 754 752 |
| `lh_usa_4093_x86fre_pro.iso` | `fc4de243…c84eab` | 1 090 004 992 |
| `WinFS_Beta1.iso` | `231e7790…e76c59f` | 153 804 800 |

Located but not fetched: `lh_usa_4074_x86fre_repack` (786 MB) — **prefer this
vanilla koawmfot repack** over the procksomaterman ISO above, which advertises
"Aero, explorer fixes, services fixes" and is therefore modified and unsuitable
for a museum piece; the 4051 PDC ISOs; and `windows-longhorn-4020-i386-repack`
for the 4020 route. **Avoid `LH4074Debombed`** — a de-timebombed ISO is a
provenance problem when `-rtc base=…` is clean and honest.

## 6. Cost — the strongest argument against

Measured on the running 4051 desktop, idle, `-m 1024 -smp 1 -enable-kvm`:
**RSS 1 111 936 kB = 1.09 GB**, and **1.04 CPU cores sustained doing nothing.**

| Station | `-m` | `-vga` | live RSS |
|---|---|---|---|
| `win95` | — | — | 101 MB |
| `win98se` | 384 | std | 137 MB |
| `win2000` | 512 | std | 337 MB |
| `winxp` | 768 | std | 358 MB |
| **`longhorn` (measured 4051)** | **1024** | **cirrus** | **1112 MB** |

**3.1× the heaviest classic Windows station in RAM, and an order of magnitude worse
in idle CPU** — every other station in that table idles near zero. A 4074 station with
WinFS actually enabled would be worse on both axes. Budget **1.5–2.0 GB RSS and
~1 core permanently**. On labhost already at load 15–20, that is a material
commitment for an exhibit whose headline feature is invisible.

## 7. Pointer — no exception needed

**`-device usb-tablet` works out of the box**, verified rather than assumed:
every interaction in the study was an absolute QMP `input-send-event` with
`{"type":"abs"}` axes at 32767, and every double-click landed first try with no
calibration and no delta accumulation. NT 6.0 pre-reset inherits the XP-era USB
HID stack. **`stream.pointer` = absolute, same as `winxp`** — none of
[`NEXTSTEP-ABSOLUTE-POINTER.md`](../NEXTSTEP-ABSOLUTE-POINTER.md) applies. The
only hazard is the inverse: USB pointing must exist at first boot because the
installer's PS/2 driver is broken.

## 8. Rest state, interaction, and the experiment that retires the risk

**Rest state (measured, 4051):** autologon straight to the desktop — Slate grey
taskbar, wheat-field wallpaper, the standard icon set, and the bottom-right
watermark `Windows® Code Name "Longhorn" — Evaluation copy. Build 4051.idx02…`.
**That watermark is the exhibit's best single asset**: visible proof this is a
machine that never shipped. No login screen, no keystroke needed. (A real 4074
install lands on a classic `Press Ctrl+Alt+Delete` GINA, so autologon must be
injected offline the way `winxp.sh` step 5 does it.)

**30 seconds:** double-click `Computer` → the `Storage` group appears beside
`Local Disk` → double-click → columns read `Title | Genre | Publisher |
Developer`. Two clicks, no typing, the whole WinFS story in one screen — *if*
the engine is running and the store has rows. On stock 4051 it is empty.

**Cheapest experiment, half a day, clone-only:** real install of **vanilla
4074** (`lh_usa_4074_x86fre_repack.iso`), `-rtc base=2004-08-01,clock=vm`, F5 →
Standard PC, key `TCP8W-…-99FBW`, IDE + cirrus + usb-tablet + 1 vCPU + 1.5 GB;
then set `SAM WinFS Account Store` and `Computer Data Synchronization Manager`
to Automatic, reboot, screendump `Computer`. Three unknowns fall out at once:
whether a real install holds a session where the prebuilt VDI did not, whether
the WinFS libraries populate, and the true RSS/CPU with the engine running. Run
the same on **4020** if the Plex look is confirmed as the target.

**Anything short of a populated WinFS library view means the exhibit ships as
"pre-reset Longhorn desktop", with WinFS on the placard.**

## Sources

[BetaWiki 4074](https://betawiki.net/wiki/Windows_Longhorn_build_4074) ·
[4051](https://betawiki.net/wiki/Windows_Longhorn_build_4051) ·
[4093](https://betawiki.net/wiki/Windows_Longhorn_build_4093_(main)) ·
[4020](https://betawiki.net/wiki/Windows_Longhorn_build_4020) ·
[BetaWiki WinFS](https://betawiki.net/wiki/WinFS) ·
[BetaWiki Plex](https://betawiki.net/wiki/Plex) ·
[Wikipedia WinFS](https://en.wikipedia.org/wiki/WinFS) ·
[OSnews "Where Is WinFS Now?"](https://www.osnews.com/story/19756/where-is-winfs-now/) ·
[Computernewb QEMU/Longhorn](https://computernewb.com/wiki/QEMU/Guests/Windows_Longhorn) ·
[NTFS.com WinFS Architecture](https://www.ntfs.com/winfs_arch.htm)

Cross-reference: the Virtual OS Museum catalogues five pre-reset builds (3683,
4008, 4020, 4032.Lab06, 4051.idx02) as working installations — see
[`vom-reference.md`](vom-reference.md). Notably **4074 is not among them**, and
**4020 is**.

Evidence: `/data/vms/sandbox/LH-4074-a7f3/` on labhost (7.3 GB, inert) — five
hashed images, converted qcow2s, 20 framebuffer screendumps, and namespaced
helpers. Delete if the candidate is dropped.
