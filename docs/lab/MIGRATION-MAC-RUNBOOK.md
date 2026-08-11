# Mac-session runbook — driving the NVMe migration from the Mac

> **COMPLETED 2026-07-15.** This is now a historical execution runbook. The Mac
> successfully drove Phases 1–4; CT950 then drove Phases 5–6. The BMC credential
> pointer below is current and the credential itself remains private.

**If you are a Claude session started on the user's Mac to do the NVMe migration:
start here.** labhost's dev container CT950 — which normally hosts the Claude
session — is being wiped in this migration, so you drive from the Mac (via `ssh lab`
+ the BMC) until CT950 is restored in Phase 4, then the seat moves back.

Read order (historical): **this file → the (now-removed) full phase runbook →
`docs/history/migration-reference.md` (the pre-wipe known-good config) →
`docs/lab/REMOTE-PROVISIONING-NOTES.md` (BMC/Redfish gotchas).** The migration this
runbook describes is complete; the sections below are kept as an execution record.

## PRIME DIRECTIVE — get CT950 back and move the seat off the Mac ASAP
**Your first and overriding goal is to restore CT950 (the dev box) and hand the Claude
session back to it. The Mac is a disposable bootstrap bridge, nothing more.**

- **The Mac's entire scope is Phases 1–4** of the plan: shut the old box down, install
  PVE on the NVMe, create the pool, and **restore CT950**. The moment `ssh osgallery-dev`
  works again, STOP driving from the Mac — resume the session inside CT950 and do
  everything else (Phase 5 gallery rebuild onward) from there.
- **The fastest seat-return path**: after PVE is installed and the `data` pool exists
  (Phase 3 start), immediately `pct restore 950` from the Mac-held vzdump (precondition
  6) — this needs neither the old pool imported nor the bulk data copied. Bring CT950 up
  FIRST, before the rest of the Phase-3 curated transfer, then let CT950 finish that and
  drive the gallery rebuild.
- **Do NOT reproduce the full dev environment on the Mac.** No Node/cargo/Playwright,
  no cloning the whole toolchain. The Mac needs only: `ssh`, `ipmitool`, `python3`
  (for `scripts/provision/isoserver.py`), and `rsync`/`scp`. All heavy work resumes
  on CT950 where it already lives. If you catch yourself installing dev tooling on
  the Mac, stop — that work belongs on CT950.

## State of the world (why this is safe to attempt)
The repo is now self-reproducing: **no derived artifacts transfer** — guest images,
checkpoints, and boot videos all rebuild from the repo on the new box. The gap-closure
program (`docs/history/REPRO-GAP-CLOSURE.md`) is green through L2: 11 builders proven end
to end, all 28 launchers emit from `stations-manifest.sh` (verify-emit gate), checkpoint-capture
helpers + the provisioning kit + the fast-poll pve-qemu recipe all vendored, and the
licensed/abandonware inputs are staged as a sha-verified bundle. The migration itself
(a full rebuild on the NVMe box) is L3 — the final proof.

## Preconditions — do these on the Mac WHILE CT950 IS STILL ALIVE
CT950 holds the secrets and the Claude memory; grab them before labhost goes down.

1. **Repo current**: `cd ~/osgallery && git pull` — must be on `main`, in sync with origin.
2. **SSH to labhost**: `~/.ssh/lab_key` + a `lab` alias in `~/.ssh/config`
   (`Host lab` → `HostName 192.0.2.10`, `User root`, `IdentityFile ~/.ssh/lab_key`).
   Historical pre-wipe test result: `ssh lab hostname` → `pve-dryrun.lan`. Also
   confirm `ssh osgallery-dev` (CT950).
3. **Sync the gitignored secrets** from CT950 into the Mac clone (they are NOT in git):
   ```
   cd ~/osgallery
   scp osgallery-dev:~/osgallery/uptoken osgallery-dev:~/osgallery/unifitoken .
   scp osgallery-dev:~/osgallery/docs/gallery-credentials.md docs/
   scp osgallery-dev:~/osgallery/spa/src/data/credentials.ts spa/src/data/
   scp -r osgallery-dev:~/osgallery/scripts/serve/pki scripts/serve/
   ```
   The PKI copy is incomplete unless it contains both `rootCA.key` (CA private key,
   mode 600) and its matching `rootCA.pem`. The leaf can be reissued, but losing the CA
   key forces a root rotation and browser re-trust. Confirm both files are present on
   the Mac before CT950 or the old pool is taken offline.
4. **Sync the Claude memory** (path differs by home dir — CT950 `~` → Mac `~`):
   ```
   rsync -a osgallery-dev:~/.claude/projects/-home-wnt-osgallery/memory/ \
     ~/.claude/projects/-Users-wnt-osgallery/memory/
   ```
   (Create the Mac project dir first if absent. This gives the Mac Claude session continuity.)
5. **Copy the staged assets bundle off labhost** (2.5 G — the licensed/abandonware inputs
   that can't be re-fetched cleanly): `rsync -a lab:/data/assets-staging/ ~/osgallery-assets-staging/`
   then verify: `scripts/build-guests/check-assets.sh --root ~/osgallery-assets-staging`.
6. **vzdump CT950** as a belt-and-braces copy of the dev seat:
   `ssh lab 'vzdump 950 --dumpdir /data --mode snapshot --compress zstd'` → scp the
   resulting tarball to the Mac.
7. **BMC tooling**: `brew install ipmitool`; BMC is **192.0.2.13** (the rotated
   credential is in gitignored `docs/gallery-credentials.md`, section `## BMC`). Give
   the Mac a DHCP reservation (the iPXE chain URL pins the Mac's IP). Rotation was
   completed in-band on 2026-07-15; the chassis “PWD” sticker is obsolete.
8. **Media**: download the latest-stable **PVE 9.2 ISO** and **SystemRescue 13.01** to a
   dir the Mac's `isoserver.py` will serve. The Range-capable server + iPXE/answer-file
   templates are already vendored at **`scripts/provision/`** (do NOT re-create them).

## Verify readiness BEFORE taking labhost offline
Once the preconditions above are done, run the preflight **while CT950 is still up** —
it checks every handoff item (ssh to labhost + CT950, the BMC-critical Range serving on the
Mac's own python3, secrets, memory, assets bundle, vzdump, ISOs, provisioning kit, BMC
reachability) and exits non-zero on any blocker:

```
scripts/provision/mac-preflight.sh
# override paths if needed:
#   ASSETS_DIR=~/where-you-put-it ISO_DIR=~/isos VZDUMP_DIR=~/dumps scripts/provision/mac-preflight.sh
```

Fix every **[FAIL]** and re-run until it prints "Mac is ready" — a FAIL after labhost is
offline means a secret or the memory you can no longer fetch. **Do not power down labhost
until this passes.**

## First actions once hardware is fitted (Kingston + WD SN7100 + new CR2032)
1. Read the plan + reference + provisioning notes (above).
2. Confirm the preconditions checklist is done.
3. Execute the migration plan's **Phases 1–4 only** — that is the whole Mac job:
   - **Phase 1** shutdown + final capture (+ the `@migrate` snapshot).
   - **Phase 2** PVE install on the Kingston via BMC/Redfish (`scripts/provision/`).
   - **Phase 3** create the `data` pool — then **jump straight to restoring CT950**
     (`pct restore 950` from the Mac-held vzdump) before the bulk transfer.
   - **Phase 4** CT950 up → `ssh osgallery-dev` works → **hand the seat back and stop.**
   Phase 0 is already complete (do not redo it); Phases 5–8 (gallery rebuild,
   verification, backups, decommission) run **from CT950**, not the Mac.
4. On CT950: `cd ~/osgallery`, `git pull`, resume the migration plan's Phase 5.
   The full dev toolchain is already there — use it as before. The Mac's role is over.

## Key facts to keep in front of you
| Thing | Value |
|---|---|
| Box identity | **`labhost` (`labhost.lan`)**, IP **192.0.2.10** |
| BMC | 192.0.2.13 (Redfish + ipmitool; `mc watchdog off` before booting media) |
| Machine-pin target | `pc-i440fx-11.0` / `pc-q35-11.0` — emit with `SH_PIN_MACHINE=1` |
| Name-collision hazard | old SSD's ZFS pool `data` **and** VG `pve` clashed with the fresh install → old VG was renamed live to `pve_poc` immediately before poweroff; import old pool by GUID readonly (plan §4) |
| Provisioning kit | `scripts/provision/` (Range server + iPXE + answer-file templates + Redfish README) |
| Assets bundle | staged copy from labhost `/data/assets-staging/`; verify with `check-assets.sh --root <dir>` |
| Dev seat return | Phase 4: restore CT950 (`zfs recv` the subvol, or the vzdump, or `scripts/provision/provision-dev-ct.sh`) → Claude session moves back to CT950 |
| SSD | stays cabled + untouched as the rollback medium until Phase 8 sign-off |

## Historical pre-migration input gap (user-supplied)
**WinXP** (G16) — no authorized XP ISO + product key is in the repo/labhost (licensed; can't
be redistributed). winxp builds only if the user stages their own licensed media/key (or
a Win7-licensed XP Mode VHD). `build-all.sh` skips it with a notice; **27/28 stations rebuild
without it**. Everything else is Tier-A/B reproducible from the repo + the assets bundle.
