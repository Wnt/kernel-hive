# Session handover — 2026-08-10 (bookworm → trixie guest migration)

> **SUPERSEDED IN PART, later the same day.** §1 and §2 were written at **3 of
> 28** tiles; waves 1(retry), 2 and 4 then landed and it is **15 of 28**. Do not
> take the state or the "next action" from this file any more:
> - **live state** → `scripts/dev/bridge-suite-status.sh`
> - **what to run next, and how** → [`MIGRATION-WAVE-BRIEF.md`](MIGRATION-WAVE-BRIEF.md)
> - **the procedure** → [`BRIDGE-TRIXIE-MIGRATION.md`](BRIDGE-TRIXIE-MIGRATION.md)
>
> §§3-9 (the system, the traps, the deferred tiles, the Iris findings, the open
> items) are still accurate and are why this file is kept. The three
> `migrate-tile.sh` bugs §5 warns about are **fixed** — three separate agents
> each rediscovered them the hard way, and each damaged a live tile doing it.

Written for a context compaction. Everything below is **pushed to
`origin/main`** at `ad83366`; nothing is uncommitted. Several background agents
were running at write time — see [§8](#8-open-items) for what they left.

Sibling doc for the same date:
[`SESSION-HANDOVER-2026-08-10.md`](SESSION-HANDOVER-2026-08-10.md) covers the
Xerox wave and is still accurate. This one is the guest-OS migration.

The plan of record is
[`BRIDGE-TRIXIE-MIGRATION.md`](BRIDGE-TRIXIE-MIGRATION.md) — read it before
touching a tile. This file is the *state*, that one is the *procedure*.

---

## 1. Where it stands

**3 of 28 bridge tiles migrated: `atarist`, `pdp11`, `gt40`.** Zero drift.

```
scripts/dev/bridge-suite-status.sh
  → bookworm 25 · trixie 3 · 11% migrated · DETACHED 1 · OK 27 · exit 0
```

The host finished bookworm → trixie on 2026-07-15. What remained was the
**guest** side: one frozen Debian 12 qcow2 that 28 overlays name by path as
their read-only backing file. That cannot be upgraded in place, so two bases now
coexist and tiles move between them one at a time.

`decos` was attempted and **rolled back** — it failed on a builder bug unrelated
to the suite (§5.1). It is correctly still declared `bookworm`.

---

## 2. Next action

**Wave numbering is `BRIDGE-TRIXIE-MIGRATION.md` §4's, not this file's.** An
earlier draft of this section renumbered them and that was a mistake — the plan
doc is the plan of record. §4 there reads: wave 2 = the seven MAME-in-chroot
tiles, wave 3 = `amstradcpc`/`alto`/`amiga`, wave 4 = the VICE seven, wave 5 =
`daybreak`/`nextstep`/`apple2`, wave 6 = `star`, wave 7 =
`sinclairql`/`zxspectrum`.

**Wave 2 — the seven MAME-in-chroot tiles**, using the driver. It is the
biggest structural win left (it retires the bookworm chroot's largest consumer)
and it is where the shared ccache pays: all seven pin `mame0289`, so the
`emu`/`osd`/`3rdparty` core is identical across trees.

> **Serialize the MAME builds.** All seven chroot into the *same*
> `/data/vms/soltest/trixie-chroot`, and two concurrent builds mounting API
> filesystems in one chroot is the failure class that took the host's
> `/dev/pts` down (§5.2). ccache, not parallelism, is what makes this wave
> cheap. Build the first tile alone and confirm the cache actually grew before
> continuing — it sits at ~0.1 GB of 32 GB, primed by a validation run only.

**What CAN safely run alongside it:** the VICE seven and the base-supplied
tiles need **no emulator build at all** (`x64sc`, cap32 and fs-uae come from the
trixie base; `alto` ships a self-contained .NET tree), so they never enter the
chroot. They are boot- and I/O-bound rather than compile-bound, which
complements a compile-bound wave. The binding constraint on running them
together is box load, not correctness.

**Concurrency is a load question, and the ceiling is real.** Four parallel
builds once took box load from 9 to 34 and starved everything else, including a
performance measurement that was running at the time. The box is 16 threads;
check `uptime` before starting a build and cap `JOBS` rather than letting the
builders take `nproc`.

Per tile:

```bash
scripts/dev/migrate-tile.sh <tile> --dry-run   # review the nine-step plan
scripts/dev/migrate-tile.sh <tile>             # stop → backup → build → bake → restart → assert
# then LOOK at the two PNGs it prints. It does not claim visual acceptance.
scripts/dev/migrate-tile.sh <tile> --flip      # ledger only; it prints what stays manual
```

**`amiga` is the one to watch.** Trixie's `fs-uae` has **no `Recommends:` field
at all**, so Mesa is not pulled in; `libgl1-mesa-dri` is named explicitly in the
trixie base build. If that is wrong the tile renders **black while every log,
exit code and assertion reports success**. This is the failure the driver
structurally cannot catch — look at the screenshot.

`decos` is a wave-1 leftover and independent of all of this: it failed on a
builder bug (§5.1), was correctly rolled back, and the fix plus its byte-exact
recovered `.ini` assets are committed. It is a SIMH source build, so it needs
neither ccache nor the MAME chroot and can run whenever.

---

## 3. The system, in one screen

| File | Role |
|---|---|
| `registry/bridge-suites.json` | **The ledger.** Per-tile suite map + both suite definitions. Hand-maintained, *not* generated — never run `tiles-registry.py` against it |
| `scripts/build-guests/lib/bridge-suite.sh` | Resolver. Fails closed on any unknown tile/suite; a missing key is an error, never `""`, because `""` would flow into a `qemu-img -b` argument |
| `scripts/build-guests/lib/bridge-base-for` | One-line shim for the 28 dense builders (they sit near the 600-line cap) |
| `scripts/build-guests/lib/bridge-base.sh` | `--suite bookworm\|trixie` |
| `scripts/dev/migrate-tile.sh` | The whole per-tile procedure as one command |
| `scripts/dev/bridge-suite-status.sh` | Ledger declares intent, box holds reality; non-zero on drift |
| `labctl facts <tile>` | Every per-tile fact in one call (§4.3) |

**The bookworm base keeps its original path** (`/data/vms/bridge/bridge-base.qcow2`).
An overlay records its backing file *by path*; rename or rebuild it and 28 tiles
break at once, surfacing as a corrupt boot rather than a clean error. The trixie
base is a **new file beside it**: `bridge-base-trixie.qcow2`.

**"Frozen" is declared *and derived*.** Any suite with a tile declared on it has
overlays in the field and is frozen in fact, whatever the ledger flag says — so
the guard armed itself when wave 1 landed. Nobody has to remember.

---

## 4. What was built today

### 4.1 Wave 0 — the trixie base, runtime-proven

Built in ~16 min. **Exact emulator parity with bookworm**:
`vice=yes hatari=yes linapple=no cap32=yes fsuae=yes`. LinApple fails on *both*
suites — a pre-existing flake, not a regression, which is only knowable now that
both bases exist.

A clone booted it under the **real tile device set** and settled what apt could
not: the cloud-kernel purge works (`uname -r` = `6.12.101+deb13-amd64`, generic),
`e1000` + `bochs-drm` bind, the bare-X kiosk chain fires, and hatari drew a real
EmuTOS GEM desktop. Trixie ships **hatari 2.5.0** (bookworm 2.4.1); every flag
the builder documents was accepted at identical geometry.

### 4.2 MAME builds — ccache, six separate trees

**Measured, trixie chroot, `JOBS=10`:** cold 1178 s → **second tile in a
brand-new tree 352 s, 98.0% hit rate, 3.35×**. Wave 3 projects ~118 → ~49 min.
Cold and cached binaries are **byte-identical**.

Trees stay separate on purpose (per-tile patch experiments), pins stay per-tile.
The single-binary/unified-pin route was **rejected** — it would have imported the
romset-revalidation problem that makes `sinclairql`/`zxspectrum` the hardest
tiles left.

> **The PCH was the whole game.** MAME compiles `emu` behind
> `-include emu.h`; ccache reported **337 of 340 PCH compiles permanently
> uncacheable** (28% of the build). `sloppiness = pch_defines,time_macros`
> dropped it to 2. Without finding it you measure a ~70% ceiling and never see
> why.

### 4.3 Platform

- **`coldboot` snapshots** — `qemu-img snapshot -c` on a *stopped* VM stores no
  RAM: **131 KB fresh, 65 KB and zero extra on-disk bytes** on a populated
  overlay. Effectively free; fleet-wide. (An earlier narrowing to 14 tiles was
  based on `savevm` VM-RAM figures that do not apply — the numbers are in the
  docs so it is not re-litigated from the wrong model.)
- **Offline disk mutation** + `docs/lab/OFFLINE-MUTATION-MATRIX.md`: 44
  MOUNTABLE-RW, 2 RO (haiku BFS, solariscde UFS), 11 NOT-SUPPORTED. The **eight
  FAT DOS/Win9x tiles are the highest-value row** — they have no exec channel,
  so today the only way in is the SLIRP http trick or typing at the framebuffer.
  Traps: `openvms`'s ext4 verdict is its *bridge* guest, not the ODS-5 volume;
  `win11` carries a BitLocker partition.
- **`data/media-archive`** — 150 G quota, 131 blobs / 15.8 G, content-addressed,
  never evicts.
- **`/data/kernel-hive`** — a real git checkout on the box, explicit `sync` only
  (a timed pull could swap `build-guests/` out mid-bake, and the image would
  carry no record of which source made it).
- **`labctl facts <tile>`** — takes either identity (`facts solaris` ==
  `facts solariscde`), flags divergence, resolves the disk from live process
  argv, and reports the checkout commit + DIRTY state.
- **`vms-wave-snapshot.sh`** — ZFS pre-wave net over `data/vms`. Its `rollback`
  deliberately **refuses**: `/data/vms` is a single dataset, so reverting takes
  all 37 tiles with it.

---

## 5. Traps found — read this section

### 5.1 A builder reported success while installing nothing

`decos.sh:499` did `install -m 644 /tmp/decos-rt11.ini … /opt/decos/ini/` —
`install` into a *directory* keeps basenames, so files landed as
`decos-rt11.ini` while the launcher read `rt11.ini`. `install_kiosk` logged
"three .ini files installed" **unconditionally**, no `|| die`.

**decos was not reproducible from scratch on any suite, and had not been for
months.** Nothing surfaced it because nothing ever tried to rebuild it. The
recovered `.ini` files' SIMH directives were byte-identical to the heredocs —
what had been lost was the *reasoning* in their headers.

> The migration's most valuable output was not a migrated tile. It was
> discovering which builders had quietly stopped working.

### 5.2 A chroot unmounted the host's `/dev/pts`

The host's `/dev` is `shared:2`. A chroot doing `mount --rbind /dev $ROOT/dev`
makes its `/dev/pts` a **peer** of the real one, so teardown propagates back out.
Symptom: `ssh root@lab` → `PTY allocation failed`, while non-interactive
`ssh lab '<cmd>'` kept working — so no automation noticed.

Recovery: `mount -t devpts devpts /dev/pts -o rw,nosuid,noexec,relatime,gid=5,mode=620,ptmxmode=000`.
Prevention: `scripts/lib/chroot-guard.sh` == `/usr/local/bin/chroot-guard`.
Proven by `tests/chroot-guard-selftest.sh`, which *reproduces* the incident with
the old pattern.

### 5.3 `pve-qemu-kvm` does not enforce the qcow2 image lock

With a `qemu-nbd` holding an image open read-write, `qemu-img snapshot -c`
returned **exit 0 and took the snapshot** — even with `file.locking=on` named
explicitly. Upstream QEMU refuses.

**"qemu-img will stop me if the VM is running" is FALSE on this box.** An absent
guard that reads like a present one, on the exact operation that would corrupt a
live tile. `bridge-coldboot` checks `/proc/<pid>/fd` for holders instead.

### 5.4 A golden contains the running emulator in RAM

A bridge tile's `golden` is a VM-state snapshot. Swap the emulator binary and
restore an older golden and you restore the *old* binary's memory image. So
**any emulator upgrade forces a golden re-bake.** Likewise `mutate` drops
`golden` unconditionally: the tile boots `-loadvm golden`, which restores the
snapshot's **disk** state too, so a surviving golden does not merely contradict
an offline mutation — it *erases* it at every boot.

### 5.5 Stale SSH host keys — silently fatal

A rebuilt overlay has new host keys. **`StrictHostKeyChecking=no` does NOT cover
a *changed* key** — only an unknown one. On `gt40` this was a silent wait in
`wait_for_ssh` to a 120 s timeout, reading exactly like a broken build. Fixed
structurally: every builder now passes `-o UserKnownHostsFile=/dev/null`. A
*human* running `ssh -p <port> root@127.0.0.1` will still be refused —
`ssh-keygen -f /root/.ssh/known_hosts -R "[127.0.0.1]:<port>"`.

### 5.6 Gates that pass by not looking

- `check-file-size.mjs` inspected **tracked files only**, so a new file always
  passed its own pre-commit check. That is how a red `main` got pushed. Now
  `tracked ∪ staged ∪ (untracked ∧ not-ignored)`.
- The pre-push hook was **never enabled**. Enabling it exposed two defects that
  made it unusable: the Rust stage could never pass locally
  (`streamhost/.cargo/config.toml` pins `target-dir` to a **box** path), and it
  linted the dirty worktree rather than the pushed range. Both fixed — a gate
  that blocks on things the pusher cannot fix only teaches people to bypass it.
- `bridge-base.sh`'s media fetches were all `curl … || true`. A rotted URL
  produced a media-less base that built, booted and passed acceptance
  identically. Now fatal, with md5s asserted and `media=` in the STATUS line.
  **Today's base got its media by luck of URL uptime, not by construction.**
- The old `labctl` repo default (`/data/vms/streamhost/build`) was a stale
  2026-07-15 mirror that answered `atarist`'s builder classification **wrong**,
  not merely unknown.

---

## 6. Deferred tiles

| Tile | Blocker |
|---|---|
| `sinclairql` `zxspectrum` | Pin guest-apt `mame 0.251`, absent from trixie (has 0.276, not in backports). Romsets were assembled by **sha1 against 0.251's own `-listxml`**; migrating means re-deriving them against 0.276 **and re-baking both goldens** |
| `star` | `nuget` is gone from trixie. The rest of Mono survives (6.12.0.199) — which is what keeps the tile alive at all, since Darkstar is .NET Framework 4.5 WinForms and CoreCLR cannot run it. Also carries a ViewPoint processor-id lock on the MAC |
| `c64` | Overlay was **flattened** 2026-08-07 (standalone 5.21 GiB, no backing file). A full rebuild, not a rebase. `migrate-tile.sh` refuses it by name |
| `indyr4400` | Deliberately **last** — mid performance investigation (§7) |
| `apple2` | Migratable but riskiest: trixie's SDL 1.2 is `sdl12-compat` over SDL2, and LinApple's build is already flaky. GEOS mouse must be re-verified on the framebuffer |
| `daybreak` | `openjdk-17` gone; move to 21 and verify Dwarf launches (its readme asks for Java 8, so 17 was already a stretch) |

---

## 7. Iris vs MAME (separate investigation)

`indyr4400` (Iris) feels far slower than `irix` (MAME). **The premise that Iris
is faster does not hold on this hardware**, for three reasons:

1. **Recompiler vs interpreter.** MAME's MIPS3 core is a native x86-64 DRC, on
   by default. Iris runs an **interpreter**: `lightning` only disables
   breakpoints, `rex-jit` is graphics-only — **neither is a CPU fast path.**
   Iris's v1 tiered JIT is mothballed, and its replacement `jitv2` is a cargo
   feature we do not enable. **We were never missing it** — jitv2 is commit
   `c340118`, an *ancestor* of our pin — and enabling it **wedges IRIX** (§7.1).
2. **The upstream claim was measured on an Apple M2.** This box is a Xeon
   D-2146NT @ 2.3 GHz. Our HUD reads **18.5 MIPS**, below upstream's own ~30 MIPS
   interpreter ceiling.
3. **Deployment asymmetry.** MAME runs on bare metal, `-video none`,
   `-frameskip 6`, `SH_CAPTURE=shm`. Iris runs in a **4-vCPU KVM guest** through
   llvmpipe software GL → guest X → dbus capture. At an *idle* desktop: 356% of
   4 vCPUs, **0.0% idle, 22.2% steal**.

Also: our pin `1e05210` is the commit that switched IP7 to a timer, and the
**next** commit (`43d2715`) is *"fix tick heuristic… latched to fast delta=1"* —
we are pinned one commit before a timing fix.

**No flag closes this gap.** If Iris must match MAME it has to stop being a
bridge tile and become an `x11-runtime` host tile capturing via `shm`, like
`irix`.

Benchmark caveat for whoever picks this up: **MAME runs throttled** (≤100% of a
real Indy) while Iris runs free, so a raw ratio flatters MAME. The repo has a
mature MAME measurement rig and **nothing** for Iris. The portable substitute is
the guest's own clock: `Δguest_s / Δhost_s`.

### 7.1 The tuning pass: concluded, nothing landed

Every lever broke the tile or came out neutral. `indyr4400` is rolled back and
verified byte-identical to its pre-session state (launcher `diff`-clean, guest
binary md5 match, service active, framebuffer at the golden desktop).

| Lever | Result |
|---|---|
| `jitv2` + `idle-pause` @`43d2715` | **IRIX never boots.** Bare blue root, `REX3 GO` frozen. `IRIS_NO_IDLE=1` does not save it |
| `-smp 4 → 8` | **Tile down.** vCPU count is part of the `golden` vmstate, so `-loadvm golden` fails and systemd restart-loops |
| Pin bump to `43d2715` alone | Boots clean, **no win** — 23.65 vs 25.82 MIPS, neutral-to-slightly-worse |

Three findings worth keeping:

- **The wedge is diagnosable.** On the jitv2 arm, `CP0 Status: 00000081`
  (`IM:________`, every interrupt masked) with `Cause: IP7` latched asserted and
  undeliverable. Upstream's own `jit-v2-design.md` carries an open audit item
  that names *our exact build combination*: `lightning` enables `opcodefusion`,
  so the interpreter samples in fused units while jitv2 samples per-instruction,
  "not yet reconciled". This is upstream-experimental, not our misconfiguration.
- **With `idle-pause` active the MIPS counter is a liar.** It read a beautiful
  `99.97 MIPS` while the `MIPS-CPU` thread sat at **1.5% CPU** — that is the
  nominal clock advancing while the thread is parked. Any Iris benchmark must be
  fixed-work wall-clock, never the HUD.
- **`-smp 8` is worth retrying properly.** The guest genuinely demands ~400% on
  4 vCPUs (iris main 99.9%, REX3 ~99%, MIPS-CPU ~90-99%, 4× llvmpipe ~28%). It
  is the one untested hypothesis with real headroom — but it needs a cold boot
  and a fresh `savevm golden` at the new vCPU count, not a launcher edit.

### 7.2 An exec channel into IRIX exists after all

The claim above that there is "no exec channel into Iris's IRIX" was **wrong**.
Iris exposes the Indy's two SCC serial ports as telnet listeners on
`127.0.0.1:8880/8881` inside the kiosk, and **IRIX runs a getty on `:8881`**.
`iexec.py` drives it and returns real stdout plus the guest's exit code —
preserved at [`streamhost/guest-agents/irix-iris/`](../../streamhost/guest-agents/irix-iris/).

**It is not durable.** The kiosk copy was never in the golden; a `systemctl
restart` deleted it (measured — the file survived earlier only because nothing
had reset the tile since the push). It is also **single-client**: one background
poller on `:8881` silently starves every other user. Cutover notes are in that
README; it is a behaviour change on a live exhibit, so it was left as a decision.

---

## 8. Open items

1. **Coldboot is not wired into the builders.** The helper exists and the
   one-line-per-builder change is recorded in its header; a briefing conflict
   stopped the agent from applying it. Small follow-up.
2. **libguestfs is not installed** (`libguestfs-tools` is in trixie). It handles
   more filesystems than the kernel and needs no `/dev/nbd` or root mounts —
   which sidesteps the propagation class in §5.2. Top recommended follow-up for
   offline mutation.
3. **A stale overlayfs is still mounted** — `overlay-xstarb` on
   `/data/vms/soltest/XEROX-star-b/root`, left from the Xerox wave. The ccache
   install wrote into what is currently its lowerdir (additive only, but
   formally undefined). Should be unmounted.
4. **`/root/kh-bridge`** — a hand-copy used to build the trixie base. Same
   stale-copy hazard as the `BUILD-gt40` script that was removed; retire it now
   that `/data/kernel-hive` exists.
5. **c128's CP/M `.d64` could not be archived** — it exists *only* inside the
   running overlay, zimmers.net its sole source. Needs the tile stopped. Listed
   in `NOT-POPULATED.md`.
6. **2.1 GB of dead MAME trees** in the bookworm chroot
   (`mame-mpf2-build-767435` is an aborted build; `-781121` is the provenance
   tree of the shipping binary). Reclaimable.
7. **`amiga.golden_snapshot` is `null`** in the harvested matrix. This file
   previously blamed "a transient QMP probe artifact from a busy fleet" — that
   was **wrong**. `streamhost@amiga` is simply **stopped**: cleanly, by systemd
   (`ExecMainStatus=15`, "Deactivated successfully"), at 2026-08-10 02:12:28,
   after running since Aug 5. A stopped tile has no `qmp.sock`, so the probe has
   nothing to ask. Consequence for wave 3, which migrates `amiga`: start it and
   confirm it is healthy on bookworm FIRST, or a pre-existing outage becomes
   indistinguishable from a migration regression.
8. **The IRIX-over-serial exec channel is not cut over** (§7.2). `iexec.py` is
   in the repo but not in any golden, so it must be hand-pushed. Baking it into
   the kiosk overlay from the tile builder is the repo-native fix; changing what
   `labctl exec indyr4400` *means* is the decision that gates it.
9. **`indyr4400`'s matrix `notes` are now wrong** — they assert the Indy "is
   driven only through the framebuffer + PS/2". True when written, false since
   §7.2. Fix with the registry source + `make tile-registry-generate`, never by
   hand-editing the generated matrix.
10. **Three tiles are deliberately STOPPED** — `indyr4400`, `star` and
    `nextstep`, the box's three largest CPU consumers (319%, 175%, 134% of a
    16-thread box). The operator stopped them to free capacity for the wave-2
    build campaign, which took the 1-minute load from 21.4 to ~15. **Restart
    them when the campaign ends**; they are healthy, not broken. Nothing else in
    the fleet was quiesced — the other 54 tiles are up.

---

## 9. Rules that earned their place today

- **Make a trap unrepresentable before documenting it.** The highest-ROI work
  was `chroot-guard`, `UserKnownHostsFile=/dev/null`, the derived `frozen` flag
  and `|| die` — each turns an hour-costing trap into something that cannot
  happen. A doc row helps whoever reads it; a guard helps everyone.
- **The framebuffer is the only proof.** `migrate-tile.sh` does every mechanical
  check and still refuses to claim visual acceptance. A tile can be healthy in
  every log, exit code and assertion and render a black screen.
- **A step that reports success while doing nothing is the worst bug shape.**
  §5.1, §5.3, §5.6 are all the same defect wearing different clothes.
- **Write the driver on the second occurrence.** Wave 1 was four agents
  improvising at ~100k tokens each; wave 2 should be one command and a glance.
- **Rebuild something you don't need to rebuild, periodically.** decos had been
  broken for months and only a from-scratch attempt found it.
