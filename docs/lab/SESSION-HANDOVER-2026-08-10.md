# Session handover — 2026-08-10

Written for a context compaction. Everything below is **pushed to
`origin/main`**; nothing is uncommitted and no agent is still running.

`git log --oneline -1`: `81303e5 merge: land the Xerox Star — the four-tile
wave is integrated`.

Supersedes [`SESSION-HANDOVER-2026-08-09.md`](SESSION-HANDOVER-2026-08-09.md),
which is still accurate for anything not restated here.

---

## 1. State of the lineup

**61 entries: 59 production streamhost stations + 2 posters.** Five landed this
session, all live, all in all three runtime documents, all serving `signal=200`:

| Station | Machine | UDP | Notes |
|---|---|---|---|
| `indyr4400` | SGI Indy R4400, Iris emulator | 54136 | second Indy; idle-pausable (Iris burns ~310 % CPU) |
| `alto` | Xerox Alto II XM, ContrAlto 2 | 54137 | **absolute** pointer; portrait 608×808 |
| `star` | Xerox Star 8010, Darkstar | 54138 | relative pointer, no fork needed |
| `daybreak` | Xerox 6085 + ViewPoint 2.0.5, Dwarf/Draco | 54139 | cheapest of the three Xerox stations |
| `nextstep` | — | 54134 | **promoted to an absolute pointer** |

Fleet verified after deploy: `all 59 stations accept their own tickets`,
`systemctl is-system-running` = running, 0 failed, 57 `streamhost@` active.

---

## 2. Open items, highest value first

1. **Split `spa/src/scene/machines.ts`.** It is over the 600-line hard cap on a
   tracked exclusion, and the exclusion records the real reason: **three station
   branches in a row conflicted there**, because every new station appends an
   assembly at the same spot. Move `ASSEMBLIES_BY_TILE` to its own module. No
   longer blocked — the wave has landed.
2. **Re-check the playbook against a retraction.** `ADD-NEW-OS-PLAYBOOK.md`
   §5.1 says Darkstar needs a ~350 ms modifier lead and that it works. The Star
   agent later **retracted** that: shifted punctuation on Darkstar is *genuinely
   flaky*, not merely slow. The rule (a modifier is a key; fix event shape
   first) still stands; the Darkstar number may not.
3. **Delete the merged branches**: `agent-a-alto`, `agent-b-star`,
   `agent-c-daybreak`, `feat/irisindy`, `star-tile` — all merged into `main`.
4. **`amiga` coldboot watcher is broken and the station is stopped.** See §4.
5. **Promote the streamhost canary** if wanted: `star` runs a verified canary
   (`streamhost-9537cd6…`) and was deliberately not `--promote`d, because that
   restarts all 57 stations.
6. Deferred research, unchanged: MAME build consolidation, the variant policy
   (`c16`/`dragon64`/`zx80` → posters), Longhorn and Alpha candidate studies
   (`longhorn-add.md`, `alpha-nt-add.md`).

---

## 3. Things that will bite the next wave

**Integration hazards, all now documented in-repo:**

- **`serve-https-spa.sh manifests` AND `deploy` wholesale-replace all three
  serve documents** (and `deploy` also replaces the UI bundle). With parallel
  station work that silently deletes siblings — it happened **twice**. The symptom
  is evil: the victim's `/signal/<tile>.json` returns 404 and
  `POST /restore/<tile>` returns `unknown osId` while the station runs perfectly
  and nothing logs a warning. Use `scripts/serve/merge-serve-manifests.py`
  (added this session) for additive publishing; the integrator does one
  wholesale publish after the merge. Deploy the bundle with
  `--exclude='*.json'` so rsync cannot take the manifest with it.
- **`make station-registry-generate` ABORTS on a validation error**, so it never
  rewrites the generated files — and `tsc` then reports "merge conflict marker
  encountered" in a *generated* file. That reads as an unresolved merge but is
  really a registry validation failure two steps upstream. Fix the validation
  error and the marker errors evaporate.
- **Generated artifacts auto-merge cleanly and are then wrong.** Regenerate
  after **every merge**, not once at the end (`AGENT-CI-EXIT-RULE.md`).
- **Parallel branches collide on ordering fields.** Each allocates
  `runtime.bringUpOrder` / `render.bindingOrder` against a `main` that lacks its
  siblings. Three collisions in four merges. `bringUpOrder` lives under
  `runtime`, `bindingOrder` under `render` — fixing one does not fix the other.
- **Every agent needs its own worktree, including promotion agents.** Two
  agents sharing the main checkout caused one agent's staged work to be swept
  into another's commit, and blocked integration for hours.
- **`.gitignore` slash patterns match directories only.** A worktree that
  symlinks `spa/node_modules` slips past `node_modules/`; bare-name patterns
  were added.

**Emulator/input lessons (all in `xerox-build-log.md` and the playbook):**

- **Synthetic input fails silently at TWO focus layers in a WM-less kiosk**, and
  it looks exactly like a dead emulator. X focus is `PointerRoot` (a non-issue
  when the window covers the whole root, fatal when it does not) and toolkit
  focus (confirmed on Avalonia, Swing and winit). Use the emulator's own key log
  as the oracle.
- **Key pacing has at least two models — measure, never inherit.** ContrAlto is
  frame-quantised (66/66 ms); Dwarf/Swing coalesces (400/150 ms); Darkstar wants
  ~300 ms and only on its WinForms top-level window.
- **A modifier is a key**: give it its own earlier event, held across. The lead
  is per-machine (Dwarf ≥ any non-zero value; Darkstar ~350 ms — see §2.2).
- **`xset m 1 0` does not disable pointer acceleration under libinput.** The
  core control reports `1/1 threshold 0` while the device applies its own ~1.8×
  profile. Needs an `AccelProfile "flat"` InputClass.
- **`xdotool windowclose` is not a clean exit for Darkstar** — it discards the
  disk image silently. Only `System → Exit` saves.
- **`xvfb-alloc`'s exit trap does not fire under `setsid nohup`**; and
  `release :N` silently does nothing (use a pidfile or pid).
- **NeXTSTEP's relative pointer is exactly 1:1 at a 1 px step** and enters an
  acceleration curve above that — which is why single-pixel walking solved a
  problem four closed-loop controllers could not.

---

## 4. Box state and housekeeping

- **`/sys/fs/cgroup` had been unmounted**, silently breaking every
  `systemctl start` with `219/CGROUP`. Remounted this session; it also caused an
  image corruption (a `systemctl stop` that did not stop, then `qemu-img
  snapshot` on a live image), recovered from a backup. Watch for a recurrence.
- **`amiga` is STOPPED and its coldboot watcher must NOT be enabled yet.** The
  watcher drives `/usr/local/bin/amiga-emu` **which does not exist in the kiosk
  guest**, so enabling it yields a permanently black exhibit. It had burned
  1 d 14 h of CPU over 4.5 days before being stopped. Safe sequence:
  `systemctl start streamhost@amiga` → `labctl exec amiga "ls -l
  /usr/local/bin/amiga-emu /etc/bridge/launch.sh"` → if missing, run
  `scripts/coldboot/install-amiga-coldboot.sh` first.
- **Disk**: `sandbox` swept 359 G → 131 G. Note the pool only gained **19 G**:
  most of the deleted bulk was ZFS **block-cloned** from production checkpoints
  (`bclonesaved` 173 G), so `du` was counting shared blocks. Kept deliberately:
  `bookworm-chroot` (live overlay lowerdir + referenced by 8 builders),
  `trixie-chroot`, and three immutable-flagged files (~1.6 G, operator's call).
- **Box-sync is green** (191 MATCH) and there is now a **conditional pre-push
  gate**: it hard-fails on drift when labhost is reachable and skips cleanly
  when it is not. The checker is placeholder-aware — scrubbing happens **on
  labhost**, so real values never reach a local artifact.
- Not in git, needed by fresh labhost: per-station canary symlinks
  `/usr/local/lib/streamhost/stations/{alto,…}/current`.

---

## 5. Reference docs written this session

| Doc | What it is |
|---|---|
| [`research/xerox-add.md`](research/xerox-add.md) | Alto / Star / Daybreak feasibility — all three built |
| [`research/xerox-build-log.md`](research/xerox-build-log.md) | The wave's shared findings, with retractions left visible |
| [`research/longhorn-add.md`](research/longhorn-add.md) | Longhorn + WinFS: feasible as a desktop, not as a WinFS machine |
| [`research/alpha-nt-add.md`](research/alpha-nt-add.md) | Win2000 RC2 on DEC Alpha via es40 — feasible, Tier 3 |
| [`research/vom-reference.md`](research/vom-reference.md) | Virtual OS Museum as a research reference + its licence boundary |

**One methodological note worth carrying forward.** Three separate conclusions
were published and then retracted this session — an MP-code timing, a "no key
produces a colon" keymap claim, and my own Alto geometry trap. Each was caught
by someone measuring instead of inheriting. The retractions were left **visible
in place** rather than quietly amended, and that is the house style: a number
you cannot defend is worse than no number.
