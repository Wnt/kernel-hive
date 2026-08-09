# Windows 2000 `winnt.sif` unattended-install spike

Date: 2026-07-14/15 UTC

Branch: `codex/research-win2000-unattend`

Trial namespace: `/data/vms/soltest/repro-win2000-unattend-1784064580/`

## Verdict

**Native fully-unattended Setup is not proved and could not be run.** The input
gate failed before Setup: the repository and lab contain neither a Windows 2000
installation ISO nor a Windows 2000 product key already authorized for this
builder. The current builder consumes an already-installed WinWorld VMware disk;
it does not consume installation media and has no product credential. The task's
product-key boundary therefore requires stopping the installer experiment.

`winnt.sif` should **not** replace the current runtime Cancel step on this
evidence. That step occurs after the already-installed image boots and is a PnP
wizard for an unknown device, previously identified as `ACPI\QEMU0002`. An
install-time answer file cannot change the existing image and
`DriverSigningPolicy=Ignore` cannot supply a missing driver. The immediate
production direction is to suppress that exact device before its first QEMU
enumeration, or retain the existing post-Cancel `golden` snapshot. A native ISO
mode must remain opt-in until an operator supplies and pins authorized media and
the existing key, stages any necessary tile-device drivers, and a new run proves
zero input through every Setup phase.

The spike did prove the current tile's residual interaction and golden snapshot
round-trip on one isolated clone. It did **not** treat that control experiment as
a substitute for an unattended install.

## Input audit and blocker

Repository findings:

- `scripts/build-guests/tiles/win2000.sh` downloads a WinWorld Windows 2000
  Professional SP4 VMware `.7z`, converts its preinstalled VMDK, and applies
  offline disk/registry repairs. Its automation-honesty section explicitly says
  there is no installer, answer file, or install-time input.
- `streamhost/tiles-manifest.sh` boots `win2k-pro.qcow2` as an IDE disk on
  `pc`, one vCPU, 512 MB, Cirrus VGA, AC97, USB tablet, and RTL8139.
- `docs/lab/ASSETS-MANIFEST.md` lists only the WinWorld preinstalled VM archive
  for Win2000. It lists no Win2000 ISO, key file, or Win2000 key environment
  variable. The cache is recorded as purged.
- A masked current-tree and git-history search found no `WIN2000_PRODUCT_KEY`,
  `WIN2K_PRODUCT_KEY`, or historical Win2000 `winnt.sif` implementation.
- A read-only lab search under `/data`, `/root`, and `/opt` found no candidate
  Win2000 ISO or `winnt.sif`; a masked search under lab configuration paths found
  no Win2000 key variable.

No key was decoded from the installed guest, copied from another Windows
edition, searched for online, generated, or printed.

### Hash and capacity evidence

There was no install media to hash. These hashes identify the disk artifacts
that were actually inspected and must not be mislabeled as ISO hashes:

| artifact | SHA-256 | role |
|---|---|---|
| current `/data/gallery-guests/Win2000/win2k-pro.qcow2` | `fbc1215d7183b997879a081702a519dec71f2cb18ac437e07750c80703f8bbce` | read-only inventory only |
| pre-boot lineage `win2k-pro.qcow2.bak-preboot-20260714-024613` | `583615267b1a425e820d969d27157c766dff44c5a6f23aab3b25c04fef17d887` | read-only source for the trial clone |
| namespaced `win2k-trial.qcow2` immediately after clone | `583615267b1a425e820d969d27157c766dff44c5a6f23aab3b25c04fef17d887` | byte-identical isolated trial |

`zpool list data` showed 15.1 GiB free at the initial audit, 19.6 GiB before
cloning, 18.7 GiB after the offline registry edit, and 16.0 GiB after the final
internal snapshots. The final cleanup audit showed 14.8 GiB free while other
namespaced work was also active; the committed-state audit later showed 14.1
GiB. It never approached the 8 GiB stop threshold.

## Candidate answer file and delivery

The secret-free candidate is
`scripts/build-guests/assets/win2000/WINNT.SIF.in`. It contains the requested
sections:

| section | intended coverage | status |
|---|---|---|
| `[Data]` | unattended CD setup and automatic target selection | authored, unrun |
| `[Unattended]` | `FullUnattended`, EULA skip, repartition, NTFS conversion, driver-signing acceptance, `\WINNT` | authored, unrun |
| `[GuiUnattended]` | Administrator password token, regional/welcome skip, one automatic logon | authored, unrun |
| `[UserData]` | operator-supplied existing `ProductID`, owner/org/computer name | authored, unrun |
| `[Identification]` | `RETRO` workgroup | authored, unrun |
| `[Networking]` | default networking components | authored, unrun |
| `[Display]` / `[RegionalSettings]` | tile resolution and US-English defaults | authored, unrun |

The product key and Administrator password remain tokens. A future guarded
builder must render them only to a mode-0600 scratch file and secret-bearing
floppy, then delete both after the run unless the operator explicitly requests a
secure retained artifact.

The proposed delivery is `A:\WINNT.SIF` on a 1.44 MB FAT12 virtual floppy via
QEMU `-fda`. This fits raw QEMU and mirrors the repository's already-validated XP
mechanism. It preserves the operator ISO byte-for-byte and makes the answer file
available to text-mode and GUI-mode Setup without patching `I386`. No `$OEM$`
payload is proposed yet: the repository has no authorized Win2000 AC97/RTL8139
driver bundle to stage, and no driver payload was tested.

Microsoft's general deployment documentation describes answer files as the way
to remove Setup interaction and `$OEM$\$1` as files copied to the installed
system, but the surviving current documentation targets newer Setup engines.
The Windows 2000 directives in this candidate therefore still require validation
against the operator's exact media.

References:

- <https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-scenarios-and-best-practices>
- <https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/wsim/distribution-shares-and-configuration-sets-overview>

## Phase-by-phase interaction map

### Native ISO path requested by the spike

| phase | expected `winnt.sif` control | observed result |
|---|---|---|
| ISO boot | QEMU boots CD with answer floppy attached | **not run**: ISO absent |
| text-mode Setup | EULA skip, partition, format, copy | **not run**: ISO/key absent |
| text-to-GUI reboot | unattended continuation from disk | **not run** |
| GUI Setup | user data, product ID, regional, network, workgroup | **not run** |
| first automatic logon | welcome skip and one auto-logon | **not run** |
| production hardware discovery | answer file plus staged OEM drivers, if any | **not run**; no driver bundle exists |
| first desktop with zero input | framebuffer proof required | **not proved** |
| internal `golden` fresh-process load | exact tile profile and screendump | **not proved for an installed result** |

No native-install checkpoint names or screenshots are claimed because QEMU was
never launched with installation media.

### Existing-image control experiment

No keyboard or pointer input was sent before the residual dialog capture.

| phase | interaction | framebuffer result |
|---|---:|---|
| cold boot of hashed pre-boot clone | 0 | Explorer and focused Notepad reached; modal **Found New Hardware Wizard** present |
| offline set `ConfigFlags=2` for `ACPI\QEMU0002` in ControlSet001/002, then cold boot | 0 | wizard still present on this already-enumerated/pending lineage |
| advance wizard once for identification | Enter, diagnostic branch only | page identifies device only as **Unknown** |
| reload residual checkpoint and Cancel | one Escape (Cancel) | clean 1024×768 desktop, Notepad focused, no wizard/taskbar button |
| `savevm golden`; quit; new QEMU process; `-loadvm golden` | 0 after save | golden PNG byte-identical to post-Cancel PNG |

This narrows the timing constraint: the registry flag exists in active
`ControlSet001` and last-known-good `ControlSet002`, but setting it after the
wizard has already entered a pending state does not clear that state. The
builder now carries the same pre-seed payload so a freshly converted VMware
source can receive it before its first QEMU boot; that builder timing still needs
its own from-source validation. Computer vision could click Cancel, but would
remain the existing best-effort workaround. No further answer-file key can
install a driver that is absent.

## Framebuffer evidence

All guest-state claims above came from QMP/HMP `screendump` frames that were
converted to PNG and visually inspected.

| evidence path in trial namespace | SHA-256 | visible content |
|---|---|---|
| `evidence/control-settled.png` | `131bef5e50bddf3ffec90518c4baa271144a0489fe3df72b80361ede9ca53cc5` | full desktop, Notepad, Found New Hardware welcome page |
| `evidence/residual-next.png` | `561739156fefd04f603f554ec904ceac75259bd2f2160bc3fd9e1a41f4eaf57d` | driver-selection page naming the device `Unknown` |
| `evidence/postcancel.png` | `9ce657c27835b30962deb7975639b6fd71eccf5661c77fc8424285477f499b92` | full desktop and focused Notepad; wizard absent |
| `evidence/golden-roundtrip.png` | `9ce657c27835b30962deb7975639b6fd71eccf5661c77fc8424285477f499b92` | fresh-process `loadvm golden`; byte-identical to post-Cancel frame |

An intermediate post-fix capture contained incomplete Cirrus redraw regions and
was rejected rather than used as evidence. A later settled frame showed the
wizard and is the basis for the residual result.

## Checkpoint tree

All checkpoints are QEMU internal snapshots in the single namespaced qcow2. No
qcow2 copies were used as checkpoints.

```text
hashed pre-boot clone
└── cp-control-boot
    └── cp-preclick-dialog             zero input; wizard visible
        └── offline ConfigFlags experiment on working state
            ├── cp-fixed-boot
            └── cp-residual-after-flag zero input; wizard still visible
                ├── diagnostic load/advance branch (not saved)
                └── loadvm cp-residual-after-flag
                    └── Cancel
                        └── cp-postcancel
                            └── golden
                                └── fresh QEMU process loadvm golden + screendump
```

Abandoned `cp-firstboot` and its first invalid `golden` were deleted with
`delvm`; `golden` was recreated only after a visibly clean post-Cancel frame.

## Proposed `win2000.sh` production gate

Keep the preinstalled-image recipe as the default. Do not silently switch an
existing reproducible builder to unvalidated media. The follow-up change should
add an explicit flag or environment mode and fail closed before creating a disk:

```diff
+INSTALL_MODE="${WIN2000_INSTALL_MODE:-preinstalled}"
 while [ $# -gt 0 ]; do
   case "$1" in
+    --unattended) INSTALL_MODE=unattended; shift;;
     ...
   esac
 done

+if [ "$INSTALL_MODE" = unattended ]; then
+  : "${WIN2000_ISO:?set WIN2000_ISO to operator-supplied media}"
+  : "${WIN2000_ISO_SHA256:?pin the exact operator-supplied ISO}"
+  : "${WIN2000_PRODUCT_KEY:?reuse the existing authorized Win2000 key}"
+  [ -f "$WIN2000_ISO" ] || die "WIN2000_ISO not found"
+  actual="$(sha256sum "$WIN2000_ISO" | awk '{print $1}')"
+  [ "$actual" = "$WIN2000_ISO_SHA256" ] || die "Win2000 ISO hash mismatch"
+  run_unattended_install_from_iso  # render mode-0600 SIF, build FAT12 floppy,
+                                   # attach ISO/floppy, blank qcow2, checkpoints,
+                                   # framebuffer phase gates, golden round-trip
+  exit
+fi
```

`run_unattended_install_from_iso` should not be merged until it is validated. It
must:

1. Render `WINNT.SIF.in` without putting the key on a command line or in logs.
2. Verify the rendered product-ID field is populated while keeping its value
   masked.
3. Build `unattend.flp`, launch `nice -n15` QEMU with unique QMP/pid paths, and
   use the production tile's machine/storage/display/device profile.
4. Save `cp-media-boot`, `cp-textsetup-done`, `cp-guisetup-done`,
   `cp-firstboot`, and any `cp-preclick-*` residual checkpoints.
5. Inspect a real framebuffer at every phase; never infer success from disk
   growth or logs.
6. Stage authorized AC97/RTL8139 drivers if the exact media lacks them, or prove
   their absence causes no prompt. `DriverSigningPolicy=Ignore` only controls
   signature policy.
7. Save `golden`, exit QEMU, start a fresh process, `loadvm golden`, and compare
   a new screendump before the mode can replace the default builder.

## Files produced by the spike

- `scripts/build-guests/assets/win2000/WINNT.SIF.in` — secret-free candidate.
- `scripts/build-guests/assets/win2000/README.md` — rendering/delivery rules.
- `scripts/build-guests/assets/win2000/qemu0002-failedinstall.reg` — offline
  pre-seed payload for the known QEMU PnP device.
- `scripts/build-guests/tiles/win2000.sh` — uses the pre-seed payload and corrects the
  older claim that the recurring dialog was caused by AC97/RTL8139.
- This findings note.

## Resume criteria

Resume the native-install line only when the operator supplies all of:

- an authorized Windows 2000 Professional installation ISO;
- that ISO's expected SHA-256;
- the exact existing Win2000 product key through a non-logged environment/file
  boundary; and
- any authorized drivers required by the production AC97/RTL8139 profile.

Until then, the crisp feasibility conclusion is **unknown for native Setup and
no for replacement now**. The current golden snapshot remains reproducible after
the one residual Cancel, and the candidate answer file is ready for a properly
authorized checkpointed experiment, not production use.
