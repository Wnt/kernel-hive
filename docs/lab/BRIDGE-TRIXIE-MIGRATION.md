# Bridge guest base: bookworm → trixie, one tile at a time

The lab **host** finished bookworm → trixie on 2026-07-15 and now runs Debian
13.6. The **guests** did not come with it. The shared emulator-bridge base
`/data/vms/bridge/bridge-base.qcow2` is still Debian 12 (bookworm, glibc 2.36),
and **18 tile overlays back onto it read-only** (28 before waves 1 and 4). That is the
whole problem in one sentence: the base is not a package set you upgrade, it is
a byte-for-byte backing file that every one of those qcow2 overlays names by
path and depends on block-for-block.

There is no flag day available. Rebuilding the base in place invalidates every
overlay at once, which means 28 overlay rebuilds, 28 golden re-bakes and 28
framebuffer acceptances in a single window — and at least six tiles need real
per-tile work *before* their overlay can even be rebuilt (`star` loses `nuget`,
`sinclairql`/`zxspectrum` lose their pinned MAME, `daybreak` loses its JRE,
`apple2` loses genuine SDL 1.2, `amiga` loses its Recommends). So the migration
is **gradual**, and this doc is the plan.

> **What is proven and what is not.** Every package fact below was checked
> against a real trixie 13.6 apt state — versions, presence, absence,
> dependency fields, backports. The **base itself is proven at runtime**, and
> **four tiles are proven end to end** (wave 1 below: `atarist`, `pdp11`,
> `gt40`, `decos`). Every *other* per-tile verdict is still apt-level. Treat
> "MIGRATABLE, no work" as "no work is visible from the package layer", not as
> "this tile will work" — those tiles' overlays have not been rebuilt and their
> goldens have not been re-baked.

### Wave 0 is done: the trixie base exists and boots (2026-08-10)

`bridge-base.sh --suite trixie` built `/data/vms/bridge/bridge-base-trixie.qcow2`
in ~16 min (6 GiB virtual / 1.8 GiB actual). It reached **exact emulator parity
with bookworm**: `vice=yes hatari=yes linapple=no cap32=yes fsuae=yes` — LinApple
fails on *both* suites, so it is a pre-existing flake, not a migration
regression. The frozen bookworm base was re-`stat`ed afterwards and is untouched
(size 3162308608, mtime 2026-07-15 10:52:41).

A clone under `/data/vms/soltest/` then booted an overlay of it under the real
**bridge tile device set**, which settled the four things apt could not:

| Question | Answer, from a real framebuffer |
|---|---|
| Did the cloud-kernel purge work on trixie? | **Yes.** `uname -r` = `6.12.101+deb13-amd64`, the generic kernel; no `*-cloud-amd64` package remains. This was the single biggest unproven risk — the genericcloud image ships a kernel with neither e1000 nor bochs-drm. |
| Do the tile devices bind? | **Yes.** std VGA `[1234:1111]`, `82801AA AC'97`, `82540EM` e1000 all present; `bochs-drm` found the VGA, `/dev/fb0` came up, e1000 linked at 1000 Mbps. |
| Does the bare-X kiosk chain still fire? | **Yes.** autologin tty1 → `startx` → `.xinitrc` → `/etc/bridge/launch.sh`, on a 1024x768 black root. |
| Does a real emulator render? | **Yes.** hatari + EmuTOS drew the GEM desktop at 1024x640 centred with the expected black bands — `--monitor mono --window --zoom 1.6`, the exact flags `atarist.sh` documents, accepted unchanged. |

One behavioural delta found: trixie ships **hatari 2.5.0** (bookworm has 2.4.1).
Every flag the `atarist` builder relies on was accepted and produced identical
geometry. Audio was **not** exercised (the clone ran `-audiodev none`; the dbus
audiodev needs the streamhost daemon), and no golden was baked — both belong to
the per-tile acceptance in the procedure below.

### Wave 1: all four landed (2026-08-10)

`atarist`, `pdp11`, `gt40` and `decos` are **migrated and accepted** — overlays
rebuilt on `bridge-base-trixie.qcow2`, goldens re-baked and `loadvm`-verified,
and each one accepted on a real `labctl shot` of the machine's own screen.
`atarist` runs trixie's **hatari 2.5.0** with the builder's flags unchanged and
identical geometry, and its golden restores pixel-identical. `pdp11` and `gt40`
build the same Open SIMH pin `a1f57fa3` clean under **gcc 14.2.0** with
`-Werror`; `gt40` links trixie's **SDL2 2.32.4** and its VT11 vector rendering is
unchanged. The ledger is flipped for all four, so the trixie base now carries
live overlays and `bridge-base.sh` refuses to rebuild it.

`decos` took two attempts and the difference between them is the interesting
part. Its first attempt **failed on a builder bug unrelated to the suite** and
was correctly rolled back to bookworm: `install_kiosk` had been installing the
three SIMH `.ini` files into a *directory* since the tile landed, so they arrived
as `/opt/decos/ini/decos-rt11.ini` while everything that reads them wants
`rt11.ini` — and it logged success unconditionally, so **decos had never been
reproducible from scratch on any suite**. The migration was simply the first
from-scratch build to try. Fixed in `73795a5` (assets under
`scripts/build-guests/assets/decos/`, one explicit destination per file, a
post-condition asserting all three are non-empty in the overlay), and the rebuild
on 2026-08-10 then ran clean end to end: SIMH built under **gcc 14.2.0** in the
trixie overlay linking `libSDL2`, all three packs re-prepared (**RSTS/E V9.6 in
~6 min**, against the ~45 min the guest doc records for bookworm), golden baked
and `loadvm`-verified, and the builder's own framebuffer keyboard proof passed —
pressing `1` booted RT-11 under SIMH, which exercises `rt11.ini` at runtime
rather than merely asserting its presence. The three files were then re-checked
**inside the running tile** over its production hostfwd: same names, non-empty,
and `sha256` byte-identical to the committed assets. **BEFORE and AFTER
framebuffer shots are 0 differing pixels** of 1024×768.

So wave 1 is 4/28. All three traps below were found on this wave, and the third
was found on `decos`'s retry.

### Wave 4: all six VICE tiles landed (2026-08-10)

`c128`, `vic20`, `plus4`, `pet2001`, `cbm8032` and `cbm2` are **migrated**, on
`migrate-tile.sh` rather than by hand. The wave was as cheap as predicted — VICE
is built into the base, so there is no per-tile emulator build and each tile is
boot- and I/O-bound. Every builder bakes its own golden, so step 7 was a no-op
confirmation on all six.

**The prediction that mattered held: trixie's gcc-14-built VICE 3.9 is
behaviourally identical here.** Each tile's own colour/ink predicate — the thing
that would catch a silently different renderer — returned the *same measured
numbers* as the bookworm build recorded:

| Tile | The exhibit's own predicate, on trixie |
|---|---|
| `c128` | 80-column VDC BASIC at **cyan=3860, magenta=0** — the exact value the builder header documents. `magenta=0` is the load-bearing half: it proves the deferred CP/M attach still lands *after* the KERNAL's boot-sector check, so the fixture is BASIC 7.0 and not a machine that autobooted CP/M. |
| `c128` | `BOOT`+RETURN reached **CP/M 3.0 on the Z80** (magenta=1899, cyan=0) — the whole reason this tile has a slot. |
| `c128` | The GO64 measurement **reproduces**: two byte-identical frames 10 s apart against a blinking-cursor control, so C64 mode still freezes the visible VDC canvas and the decision not to ship a C64 button stands. |
| `plus4` | Both halves of the 3-plus-1 route: F1+RETURN into the suite (white=131), then C= C + `tc` into the spreadsheet (ink=30036). |
| `cbm8032` | `RUN` filled all 80 columns of the times table (green=7342). |
| `cbm2` | The type-in demo grew the lit region rows 100..162 → 100..226 at unchanged columns. |
| `vic20` | Bright-pixel gate passed; `PRINT 3` changed the framebuffer. |
| `pet2001` | Ready screen lit=1841 inside the documented 1200..4000 band. |

Memory was the one open per-tile question and it is answered: `c128` reports
**MemAvailable 397 MB of 715 MB** with `x128` running at `-m 768` (bookworm
measured 385 of 725), and `cbm2` **414 MB** against the same 200 MB floor. The
trixie userspace costs nothing worth budgeting for on these tiles.

The CP/M 3.0 system disk — `c128`'s single external file, from the one surviving
zimmers.net mirror — was staged **entirely from the host copy, with zero upstream
fetches**, and both it and its `.gz` are now in the never-evicting media archive
(`sha256 6915922…` and `6ed0da2…`). Before this wave the only copies were in the
tile dir, which a `--force` rebuild is entitled to clear.

**`c64` was deliberately not attempted** — see §1: its overlay was flattened on
2026-08-07, so it is a rebuild rather than a rebase and `migrate-tile.sh` refuses
it by name. What this wave learned that bears on it is in the note below the
wave table.

### Wave 2: five of seven landed, and the chroot's job changed (2026-08-10)

`bbcmicro`, `armeval`, `zx81`, `dragon32` and `oricatmos` are **migrated
mechanically** — overlays rebuilt on `bridge-base-trixie.qcow2`, goldens re-baked
by their own builders and `loadvm`-verified, `/etc/bridge/suite` reporting
`trixie` in each guest, and each tile's BEFORE/AFTER frames captured for a human
to compare. `mpf2` and `kc854` were attempted, **failed and were rolled back**;
they stay bookworm, which is the correct state for them (see below).

All six MAME binaries were rebuilt in `/data/vms/soltest/trixie-chroot` first,
one at a time. **ccache is what made the wave cheap, and the measurement is the
headline:** the first build (`bbcb`, the widest SOURCES set) ran 16 min at a
59.1% hit rate and grew the cache 82 → 110 MB; every later build reused it —
`mpf2` 99.7%, `zx81` **100.0%** (1113/1113), `dragon32` 96.0%, `kc854` 98.9%,
`oricatmos` **100.0%** (1204/1204). Cross-tree hit rate is therefore not a hope,
it is 96-100% once one tree has been built, and the wave's cost assumption holds
for every remaining MAME tile.

**The chroot survives the migration, but its argument does not.** It existed
because a host-built binary linked against glibc 2.41 dies in a Debian 12 guest.
Guest and host are both Debian 13 for these tiles now, so what the chroot buys is
reproducibility and a pinned toolchain — the per-guest docs and builder headers
say so rather than repeating the ABI story.

**`mpf2` and `kc854` — the same shape, and it is not the suite.** Both builders
end with `stop_qemu; boot_tile; <framebuffer predicate>; guest "pgrep …"`, and
both died there as `MAME exited after cold reset/boot`. Two layers were wrong and
only the first is fixed:

- The probe had **no wait for SSH** after that second boot (the first boot has
  one). On trixie it connected into a reset or a timeout, so a transport failure
  was reported as a claim about the emulator. Both builders now call a shared
  `wait_for_ssh` there.
- With the wait in place the probe connects and **genuinely finds no MAME** —
  even though the same build had just accepted the frame (kc854: CAOS ready,
  bright 27868, nag-red 0) and, on mpf2, had drawn the real MPF-II banner and `>`
  prompt on its FIRST cold boot. So the emulators run on trixie; something about
  the SECOND cold boot does not. That is per-tile work on a soltest clone, not a
  chroot swap, and it is why these two are not in the table above.

`mpf2` has a second, independent defect the migration exposed: its readiness
predicate accepts any warning-free frame with more than 100 non-black pixels, so
a GRUB console passes it. On trixie it returned while the screen still read
`Loading Linux 6.12.101+deb13-amd64 ...`. It needs to assert the MPF-II's own
screen, the way `bbcmicro`/`dragon32`/`zx81` assert theirs.

Three defects in `scripts/dev/migrate-tile.sh` were found and fixed by running
it seven times; the first was destructive:

- **The poll read a line count as an exit code.** The status trailer was
  separated from the log tail by `echo '---'`, and a poll whose `tail` emitted
  nothing put that sentinel at offset 0, so neither expansion matched: the driver
  announced `builder exited 19` — the log's line count — and rolled back a
  perfectly healthy build 21 s before it baked its golden. Any build that goes
  quiet for one 20 s interval triggers it, which every bridge builder does while
  it waits for a guest. Fixed with a sentinel a log cannot contain, printed with
  a leading newline, plus a numeric assertion on the parsed length.
- **The rollback raced the builder it had abandoned.** It killed the tile's QEMU
  but not the detached builder, so on bbcmicro the surviving builder's next
  `savevm golden` reached the *production* QEMU through the recreated `qmp.sock`
  and re-baked the restored tile's golden. It landed on the right frame; that was
  luck. The builder's setsid process group is now recorded and terminated first.
- **Staging was incomplete in two ways** — the remote `mkdir -p` did not create
  the rsync destination's parent (every fresh per-tile stage died on the first
  rsync), and builders that read host-side sidecars from
  `streamhost/tiles/<tile>/` were never given them, so `zx81` died on
  `cd: …/streamhost/tiles/zx81: No such file or directory`.

The upstream image exists and the naming substitution is exact — the URL is the
bookworm one with `debian-12-` → `debian-13-`:

```
https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
  302 → umu.se mirror, 342032384 bytes, Last-Modified 2026-08-03
```

---

## 1. The two-base design

Two bases coexist. The migration moves tiles between them, one at a time.

| | bookworm | trixie |
|---|---|---|
| base qcow2 | `/data/vms/bridge/bridge-base.qcow2` | `/data/vms/bridge/bridge-base-trixie.qcow2` |
| MAME build chroot | `/data/vms/soltest/bookworm-chroot` | `/data/vms/soltest/trixie-chroot` |
| glibc / gcc | 2.36 / 12 | 2.41 / 14 |
| frozen | **yes** (25 live overlays) | **yes, in fact** (3 live overlays since wave 1; the ledger flag is still `false`, but `bridge-base.sh` derives frozen-ness from "any tile declares this suite") |

**The bookworm base keeps its original path.** This is the single most
load-bearing decision here and it is deliberately unglamorous: a qcow2 overlay
records its backing file *by path*, and the guest kernel, the baked golden
snapshot and every block the overlay does not itself hold all resolve through
it. Rename or rebuild that file and 28 tiles break simultaneously, with the
failure surfacing as a corrupt boot rather than as a clean error. So the new
base is a **new file beside it** and the old one is never touched again.
`bridge-base.sh --suite bookworm` refuses to rebuild without
`--i-know-this-breaks-every-overlay`, and the flag is spelled that way because
the person typing it should have to read what they are doing.

The ABI-matched **MAME chroot** exists for the same reason in the other
direction: a MAME built on the trixie host links against glibc 2.41 and dies in
a bookworm guest with `GLIBC_2.4x not found`. Until a tile's overlay is on the
trixie base, its MAME must be built in a bookworm chroot. That coupling is why
the suite, not the host, decides the chroot — see §2.

### The moving parts

| File | Role |
|---|---|
| `registry/bridge-suites.json` | **The ledger.** `defaultSuite`, both suite definitions (base path, MAME chroot, genericcloud URL, glibc/gcc, `frozen`), and the per-tile suite map. Hand-maintained; *not* a generated file — never run `tiles-registry.py` against it. |
| `scripts/build-guests/lib/bridge-suite.sh` | The sourceable resolver: `bridge_suite_for`, `bridge_base_for`, `bridge_mame_chroot_for`, `bridge_genericcloud_url_for`, `bridge_debian_version_for`, `bridge_suite_is_frozen`, `bridge_suite_tiles`, `bridge_suite_assert`. Fails closed on an unknown tile, an unknown suite or a malformed ledger — a missing key is an error, never `""`, because `""` would otherwise flow into a `qemu-img -b` argument. `BRIDGE_SUITE=trixie` in the environment overrides, for experiment clones only. |
| `scripts/build-guests/lib/bridge-base.sh` | Gains `--suite bookworm\|trixie`; builds either base from that suite's genericcloud URL to that suite's path. |
| the six `build-mame-*.sh` + `indyr4400.sh` | Pick their build chroot from the tile's suite instead of hardcoding bookworm. |
| `scripts/dev/bridge-suite-status.sh` | Compares the **declared** suite against the **real** backing file of each tile's overlay on the box. Non-zero on drift. |

### Ledger declares intent; the box holds reality

The ledger cannot migrate anything. Flipping an entry from `bookworm` to
`trixie` changes exactly zero bytes on the box — it is a claim about a qcow2
that already exists. That split is intentional, because the alternative
(inferring the suite from the box at build time) means a build silently adapting
to whatever it finds, which is how you get a tile that is half-migrated and
reports success.

So the two are checked against each other. `bridge-suite-status.sh` reads each
tile's `overlay.qcow2` backing file and compares it to the base path the ledger
implies. Disagreement is **drift** and exits non-zero. Run it after every
migration and before believing any claim in this document.

`c64` is the exception the checker reports separately: its overlay was
**flattened on 2026-08-07** into a standalone 5.21 GiB qcow2 with an internal
`golden` snapshot and **no backing file at all**, even though its launcher
comment still calls it a thin overlay. It is reported as `DETACHED`, not as
drift. Two consequences: migrating `c64` is a full rebuild rather than a rebase,
and in the meantime it is carrying ~2.5 GiB of blocks duplicated from the base.

---

## 2. The per-tile migration procedure

Do these in order. Steps 4 and 5 are the ones people skip, and they are the two
that make the migration real rather than declared.

1. **Do the per-tile work** listed in the table in §3. For most tiles this is
   empty. For `star`, `daybreak`, `sinclairql`, `zxspectrum`, `apple2` and
   `amiga` it is not, and it must land *before* the overlay is rebuilt.
2. **Rebuild the overlay against the trixie base.** Experiment on a clone under
   `/data/vms/soltest/` first (`BRIDGE_SUITE=trixie` forces the suite without
   touching the ledger), kill only via `clone-guard kill-pidfile`. Then
   `qemu-img create -f qcow2 -b /data/vms/bridge/bridge-base-trixie.qcow2 -F
   qcow2 …` and re-run the tile's builder. Device set must be byte-identical to
   what the golden will be baked with.
3. **Bake the golden.** `savevm golden` over QMP, then `loadvm golden` to prove
   the restore, per [`streamhost/docs/BRIDGE.md`](../../streamhost/docs/BRIDGE.md) §3d.
4. **Framebuffer acceptance.** `ssh lab 'labctl shot <tile>'`, scp it back, and
   **look at it**. The emulator's actual screen, not a boot console, not a black
   frame. A tile that renders black is the exact failure mode the `amiga` Mesa
   note below exists to prevent; disk and log inference will not catch it. If
   the tile has audio, re-prove it non-silent the same way the original build
   did.
5. **Update the registry prose — both copies.** Every migrated tile's
   placard still says "a captured **Debian 12** kiosk". That sentence lives in
   exactly two hand-written places now:
   - `registry/tiles/<tile>.json` → `.museum.notes`
   - `streamhost/tiles/<tile>/tile.env.fixture` → `SH_FIXTURE_DESC` (the
     fixture is the single source for its env keys; the registry entry no
     longer mirrors them)

   Then `make tile-registry-generate`. **Never hand-edit the generated files** —
   `streamhost/tiles-manifest.sh`, `scripts/serve/webroot/poster-docs.json` and
   the rest are outputs. `make tile-registry-check` is the gate and it goes red
   on any of these. The public lineup the visitor sees is rendered on demand
   (`tiles-registry.py render`), so a `.museum.notes` edit reaches the gallery
   with `serve-https-spa.sh manifests` and no rebuild.
6. **Flip the ledger in the same commit** as steps 2–5. A commit that flips the
   ledger without the rebuild, or rebuilds without the flip, produces drift that
   `bridge-suite-status.sh` will find later, out of context, with nobody who
   remembers why.
7. **Run `scripts/dev/bridge-suite-status.sh`.** Clean exit is the end of the
   procedure. Anything else means step 6 was wrong.

### Three traps this migration has walked into

The first two are in the gap between step 2 and step 3, and both cost time
because they look like something else. The third is in the driver rather than
in the migration, and it cost a production tile.

**1. The stale SSH host key — fatal, not cosmetic.** The trixie overlay is a
fresh guest filesystem with fresh host keys, so the box's
`/root/.ssh/known_hosts` still holds the *bookworm* overlay's key for the tile's
provisioning port (`[127.0.0.1]:<port>`). Every `guest()` call in the builder
then fails, and **`StrictHostKeyChecking=no` does not save you**: it suppresses
the prompt for an *unknown* key, not the hard refusal for a *changed* one.
The failure does not say "host key" anywhere useful — on `gt40` the builder sat
in `wait_for_ssh` printing nothing until its 120 s timeout fired and died with
`bridge SSH did not become ready on 127.0.0.1:5828`, which reads like a guest
that failed to boot. Two of us first filed this as cosmetic; the third lost an
hour to it.

**The builders are now structurally immune, so this should not bite a build
again.** Every ssh and scp in every bridge builder — all 28 tiles, plus
`lib/bridge-base.sh` on its own provisioning port and `lib/graphical-bridge.sh`
— passes `-o UserKnownHostsFile=/dev/null`, so none of them reads or writes
`known_hosts` at all: a stale entry cannot bite them, and they never leave one
behind either. That is the cause fixed rather than the symptom cleaned up, and
it costs nothing in security: every one of these connections is
`127.0.0.1:<hostfwd>` into a guest the builder itself just created, so there is
no MITM surface for host-key verification to protect.

**A human still hits it.** Your own `ssh -p 5828 root@127.0.0.1`, or anything
else that uses `/root/.ssh/known_hosts`, will still be refused after the overlay
is rebuilt — and, again, `-o StrictHostKeyChecking=no` will *not* rescue you,
because it suppresses the prompt for an *unknown* key and does nothing about a
*changed* one. The recovery is to drop the entry:

```bash
ssh lab 'ssh-keygen -f /root/.ssh/known_hosts -R "[127.0.0.1]:5828"'
```

Provisioning ports seen in wave 1: `atarist` 5816, `pdp11` 5827, `gt40` 5828,
`decos` 5829 (each builder's `SSH_PORT`).

**2. Six builders do not bake the golden — you do.** `atarist.sh` cold-boots
the overlay, stages the media, installs `/etc/bridge/launch.sh`, then **logs
the bake command and exits 0 with no snapshot in the overlay.** A successful
run is therefore not a finished tile, and step 3 is a separate bake.
`amiga`, `apple2`, `c64`, `daybreak`, `star` and `indyr4400` are the same shape
— all of them wait on a desktop whose "ready" state no builder can check, so
the bake is deliberately operator-triggered rather than slept-for.

It is no longer a copy-paste, though: each of those builders (except
`indyr4400`) now takes **`--bake`**, which hands the tile's `qmp.sock` and
overlay to `scripts/build-guests/lib/bridge-bake-golden` — drop any stale
golden, `savevm golden`, **assert the snapshot actually landed**, `loadvm
golden`, and assert the restored machine is `running` (a golden baked while the
VM was stopped restores paused, which screenshots perfectly and is dead). Run it
with the tile up under its own `streamhost/tiles/<tile>/qemu-streamhost.sh`:
the helper snapshots whatever QEMU owns that socket, so the golden is taken
under the production device set by construction.

**3. A progress poller that reads a line count as an exit code — and a rollback
that then runs under a live builder.** Found on `decos`, on `migrate-tile.sh`'s
first real run, and it is recorded here in full because the shape is general.

The 5/9 poller asked the box for "new log lines, then a `---` sentinel, then the
line count, then the exit code" and unpicked that with two `${var%%…}` strips.
On a poll where the build had logged **nothing**, the sentinel arrives with no
newline in front of it, both strips silently no-op, and the **line count is read
as the builder's exit code**. `decos` compiles Open SIMH for ~90 s in complete
silence, so poll 2 declared `builder exited 2` over a build that was 40 seconds
old and running perfectly.

That alone would have been a wasted run. What made it expensive is what happened
next: the driver rolled back — restored the bookworm overlay to `overlay.qcow2`
and restarted `streamhost@decos` — **while the builder was still alive**. A
bridge builder only ever addresses its guest as `127.0.0.1:<hostfwd>`, and the
restarted production tile answers on exactly that port. So the builder carried on
against the **live bookworm exhibit**: it installed the kiosk files, ran
`quiet_console` over its grub config, cold-booted it, and baked a fresh `savevm
golden` over the production fixture. It then died at the keyboard proof, because
the streamhost daemon had idle-paused the guest out from under it.

The tile survived intact — `loadvm golden` restored and the chooser came back
**byte-identical** to the pre-migration shot (same PNG md5), because the
recovered `.ini` assets are byte-exact copies of that guest's own files and the
builder's `boot_tile()` device set is byte-identical to `qemu-streamhost.sh`'s.
That is luck resting on two invariants, not a safety property.

Both halves are fixed in `scripts/dev/migrate-tile.sh`: the poller now sends one
fixed `RC <n>` header line **first** and advances its cursor by the lines it
actually consumed, so an empty tail parses exactly like a full one and nothing is
inferred from position; and the rollback's remote program now kills the builder
session group by the pidfile its own wrapper writes, **verifies through
`/proc/<pid>/exe` that it is gone**, and refuses to touch the overlay otherwise.
The general lesson is the one AGENTS.md already states and this hit anyway: the
hostfwd port is a shared global, and "the build must be over by now" is a guess,
not a claim.

The other 21 bridge builders bake inside the build, gated on a real pixel check
(`wait_for_cpc`, `wait_for_vectors`, the ink gates). Their catch is the mirror
image of the manual six: `pdp11.sh`, `gt40.sh` and the rest duplicate the
production device set inline in their own `boot_tile()`, so the builder's QEMU
line and the tile's `qemu-streamhost.sh` must stay byte-identical or the golden
they bake is unrestorable in production. Moving those bakes onto
`bridge-bake-golden` against the launcher-started QEMU would retire that whole
class of drift, and is the obvious follow-up.

### Two traps wave 4 found — in the driver, not in any tile

Both were in `migrate-tile.sh` itself, and both are fixed. They are recorded
because the second one nearly cost a production golden and the symptom pointed
squarely at the wrong thing.

**3. A quiet build was killed off as a failed one.** The poll loop streamed the
new log lines *first* and split them from the trailing metadata on a `---`
sentinel. When a poll interval found **no new lines** neither substitution
matched, so the log's line COUNT was parsed as the builder's exit code — and a
perfectly healthy build was declared `builder exited 3` and rolled back. Any tile
with a quiet stretch hit it every time: `plus4` spends ~46 s in `wait_for_ssh`
saying nothing. `vic20` survived only because it prints a framebuffer proof every
two seconds. The fix is to put the fixed-position metadata FIRST, where log
content cannot be confused with it.

**4. The rollback raced the builder it had abandoned.** The builder is launched
detached (`setsid`), so it is not a child of the driver and nothing reaps it. When
trap 3 fired, the rollback restored the bookworm overlay **underneath a builder
that was still running** — which carried on for another minute, re-baked a golden
into the restored PRODUCTION overlay, and then typed into the machine. `plus4`
recovered (the re-bake happened to land on the same untouched power-on fixture,
and `loadvm golden` was re-proved by hand on a real screenshot), but that was
luck, not design. Whoever abandons a detached build owes it a kill: the driver now
records the builder's **process group** and stops the group — builder *and* the
QEMU it started — before anything touches the overlay.

Both now live in `scripts/lib/box-detached-build.sh`, so the launch/poll/stop
contract is in one place rather than re-derived per caller.

### Acceptance gate

A tile is migrated when, and only when: the overlay's real backing file is the
trixie base; `loadvm golden` restores; `labctl shot` shows the machine's own
screen; audio (where the tile has it) is measured above the silence floor;
`make tile-registry-check` is green; `bridge-suite-status.sh` exits 0. Steps
short of that are progress, not completion.

Most of that list is now one command — `scripts/dev/tile-accept.sh <tile>
--before <the migration's before-bookworm.png>`. It runs the unit / daemon
health / stream-ticket / exec-channel / `loadvm golden` / fresh-framebuffer
bundle and prints a row per check, and its pixel half
(`scripts/dev/frame-compare.py`) replaces "open both PNGs and compare them" with
a differing-pixel count, its bounding box, and a **fail-closed emptiness floor**
that a black frame cannot pass — measured so that it does not reject the real
2-colour, 99.71%-black exhibits this fleet actually has. What it deliberately
does NOT do is claim the frame shows the machine's own screen: that judgement,
and the audio floor, are still the human's, and the tool says so instead of
printing ACCEPTED. It also refuses, rather than starting, a tile whose unit is
inactive — three of those are the operator's quiesce and one (amiga) is an
outage nobody declared.

### Rollback

Cheap, because the bookworm base was never touched. Rollback is repointing the
tile's overlay back at `/data/vms/bridge/bridge-base.qcow2` — in practice,
restoring the pre-migration overlay (keep it until acceptance passes) and
reverting the ledger flip. Nothing about an unmigrated tile ever changes, which
is the payoff for the two-base design and the reason the frozen base's path is
sacred.

---

## 3. The ledger table — per-tile verdicts

All package facts verified against trixie 13.6 apt state. Apt-level only,
except where a row says otherwise: the *base* is runtime-proven (wave 0), and
`atarist`, `pdp11` and `gt40` are fully migrated (wave 1). No other tile in this
table has been rebuilt or re-baked. See the warning at the top.

The seven VICE tiles can be upgraded from prediction to measurement by wave 0
(`x64sc` built from source clean under gcc-14, which was the open question for
all of them), but none has had its overlay rebuilt, so they stay in this table
rather than moving to "done".

### MIGRATABLE, no per-tile work (20 tiles)

| Tiles | Why it is clean |
|---|---|
| `atarist` | **DONE (wave 1).** `hatari 2.5.0+dfsg-1+b1` in trixie main; straight apt swap, builder flags unchanged, geometry identical. |
| `pdp11`, `gt40` | **DONE (wave 1).** Open SIMH pin `a1f57fa3` builds clean under gcc 14.2.0 with `-Werror`; `gt40` against `libsdl2-dev 2.32.4`, VT11 rendering unchanged. |
| `decos` | **DONE (wave 1, on the retry).** Same source-SIMH story; the first attempt failed on an unrelated builder bug (the `.ini` install, fixed in `73795a5`) and was rolled back. The rebuild landed all three packs, and the `.ini` files are now proven byte-identical inside the running tile. |
| `c128`, `vic20`, `plus4`, `pet2001`, `cbm8032`, `cbm2` | **DONE (wave 4).** VICE from source, unchanged (see the VICE note below — the apt package is a trap, not a shortcut). gcc-14's VICE 3.9 is behaviourally identical: every tile's own colour/ink predicate returned the bookworm numbers. |
| `c64` | **NOT attempted.** Same VICE story, but its overlay is detached, so it is a full rebuild rather than a rebase and `migrate-tile.sh` refuses it by name. |
| `amstradcpc` | `cap32` from source; deps fine. |
| `bbcmicro`, `armeval`, `zx81`, `dragon32`, `oricatmos` | **DONE (wave 2).** The MAME-in-chroot tiles (six `build-mame-*.sh` builders between them). Moving the build to the trixie chroot was exactly as mechanical as predicted, and ccache made the six rebuilds cost roughly one. |
| `mpf2`, `kc854` | Same family, **not migrated**: attempted in wave 2 and rolled back. Their emulators render correctly on trixie; their builders' second-cold-boot liveness probe does not pass. Per-tile work, see wave 2 above. |
| `alto` | Self-contained .NET publish. Neither distro end constrains it. |

`indyr4400` is in the ledger and its builder takes its chroot from the suite
like the MAME builders do, but it has **no verdict here yet** — it was not part
of the apt sweep. Treat it as unassessed, not as clean.

### MIGRATABLE with a caveat

**`apple2` — the riskiest tile in the "migratable" column.**
`libsdl1.2-dev 1.2.68-3` and `libsdl1.2-compat-shim` both exist, so the build
looks fine from apt. They now come from source package **`sdl12-compat`** —
`libsdl1.2-dev` *Depends on* `libsdl2-dev`. That is the SDL 1.2 API emulated
over SDL2, not the SDL 1.2 that LinApple was written against.
`libsdl-image1.2-dev 1.2.12-14` is still genuine. LinApple should compile, but
**input and video now run through SDL2**, so the kiosk patch and the GEOS mouse
tracking must be re-verified on the framebuffer, never assumed. LinApple's base
build is already documented as flaky (`Video.o` under modern g++); this stacks
on top of that.

### NEEDS-WORK

**`daybreak` — small.** `openjdk-17-jre` is **gone** from trixie; only 17's
successors remain (21 and 25), and `default-jre` resolves to
`openjdk-21-jre 21.0.11+10-1~deb13u2`. Move to `openjdk-21-jre` and re-verify
that the Dwarf/Draco jar actually launches, via `labctl shot`. Dwarf's own
readme asks for Java 8; 17 was already a bump and 21 is a further one, so this
is a real runtime question, not a version-string edit.

**`nextstep` — small; recommendation is to do nothing.** The tile currently
builds **SDL3 3.4.14 from source** because bookworm has no SDL3 at all. Trixie
packages `libsdl3-dev 3.2.10+ds-1`, which satisfies Previous 4.4's `>= 3.2`
floor — so the apt route is now *available*. It is not an *improvement*: the
build script documents SDL3-version-specific workarounds found against 3.4.x
(the `XSetInputFocus` / focus-`None` keyboard issue, and forcing a software
presentation path), and 3.2.10 is not the version they were derived on.
**Recommendation: keep the pinned source build.** It is the lower-risk choice
and it is already known to work.

**`star` — `nuget` is absent from trixie.** No candidate, not in
trixie-backports, and no replacement path (`msbuild`, `mono-msbuild`,
`dotnet-sdk` all absent too). `star.sh` installs `nuget` and runs
`nuget restore D.sln` before `xbuild`, so it fails at that line.

The rest of the Mono stack is **fully intact** in trixie main:
`mono-complete` / `mono-xbuild` / `mono-runtime` / `mono-devel`
`6.12.0.199+dfsg-6` and `libgdiplus 6.1+dfsg-1.1`. That matters more than the
`nuget` gap: Darkstar is .NET Framework 4.5 WinForms and **genuinely needs
Mono** — dotnet/CoreCLR cannot run it — so Mono surviving in trixie is the only
reason this tile has a future at all.

Fix: drop the apt `nuget` and either bootstrap `nuget.exe` from `dist.nuget.org`
and run it under `mono`, or vendor the already-restored packages into the
overlay.

**`sinclairql` and `zxspectrum` — the hardest, and the reason they are last.**
Both pin guest-apt `mame 0.251+dfsg.1-1`, which does not exist in trixie.
Trixie has `mame 0.276+dfsg.1-1+deb13u1`, and mame is **not** in
trixie-backports (full `Packages.xz` checked). Both scripts `die` loudly on a
version mismatch **by design** — `sinclairql.sh:207` (`dpkg-query`) and
`zxspectrum.sh:475` (`mame -version`) — so nothing here fails silently.

The pin is not the expensive part. **Both romsets were assembled by SHA1
against 0.251's own `-listxml`**, and MAME renames and moves ROM members
between releases. Migrating means re-deriving the wanted `(name, sha1)` pairs
from 0.276 and **re-baking both goldens**. While doing that, also re-check two
assertions that were true of 0.251 and may not be of 0.276: `sinclairql`'s
documented nodump-PLD warning (its text and placement can move) and
`zxspectrum`'s assertion that the `spectrum` driver is `status="good"`.

**`amiga` — a one-line apt change with a black-screen failure mode.**
`fs-uae 3.1.66-2+b1` is in trixie main, but it has **no `Recommends:` field at
all**. `bridge-base.sh` installs fs-uae *with* recommends today, specifically to
pull in libopenal (Paula audio) and Mesa (llvmpipe software GL — this box has no
GPU). On trixie, `libopenal1` arrives via a hard `Depends`, so audio is safe.
**Mesa does not.** `libgl1-mesa-dri` must be installed explicitly. Skip that and
the tile renders black while every log looks healthy — which is precisely why
step 4 of the procedure is a screenshot.

### Out of scope

- **`openvms`** — not on this base. It has its own graphical-bridge image
  (`openvms-decwindows-bridge.sh`) and shares only `/data/vms/bridge/bridge_key`.
- **`irix`** — not a bridge guest at all: `SH_TILE_RUNTIME=x11`, MAME on the
  **host** against a `.chd`. Already trixie by definition.

### Stale fact worth correcting: VICE *is* back in Debian

`bridge-base.sh` says "**VICE IS NOT IN DEBIAN**" (removed over ROM/DFSG
licensing). For trixie that is now wrong: `vice 3.9+dfsg-1` is in
**trixie/contrib** and ships `/usr/bin/x64sc`.

And it still does not help us. The Debian package is the **GTK3 UI build**
(pulls `libgtk-3-0t64`, `libpulse0`); the kiosk needs the **SDL2 fullscreen**
build running with no window manager. So the from-source build stays for all
seven VICE tiles. Both halves of that go in the comment when it is updated —
the half-truth ("VICE is packaged now, just apt it") is what would mislead the
next person.

### One more trixie-wide change

ImageMagick on trixie is **IM7**. `convert` still resolves through the
alternatives system, so existing scripts keep working, but `magick` is the
non-deprecated entry point for anything new.

---

## 4. Suggested wave ordering

Cheapest and lowest-risk first, so the trixie base gets real boot evidence
before any expensive tile depends on it.

| Wave | Tiles | Rationale |
|---|---|---|
| **0** | build `bridge-base-trixie.qcow2`; boot it once, bare | The first real runtime evidence for anything on this page. Confirms the e1000/`linux-image-amd64` and static-IP gotchas from BRIDGE.md §1 still hold on trixie *before* a tile depends on them. |
| **1** | `pdp11` ✅, `gt40` ✅, `atarist` ✅, `decos` ✅ | Pure source-SIMH plus one apt emulator. Smallest blast radius. **All four landed 2026-08-10**; `decos` needed a second attempt after an unrelated builder bug, and is the tile that first exposed the driver's own bugs. |
| **2** | `bbcmicro` ✅, `armeval` ✅, `zx81` ✅, `dragon32` ✅, `oricatmos` ✅, `mpf2` ↩︎, `kc854` ↩︎ | The MAME-in-chroot tiles. **Five landed 2026-08-10** and the chroot swap was indeed mechanical; ccache carried **96-100% of every build after the first** (which was 59.1%), so six MAME builds cost about one. `mpf2` and `kc854` rolled back on a second-cold-boot failure that is theirs, not the suite's. The bookworm chroot's biggest consumer is mostly retired, but it cannot be deleted until those two follow. |
| **3** | `amstradcpc`, `alto`, `amiga` | Source builds and the .NET publish; `amiga` carries the explicit `libgl1-mesa-dri` fix and the black-screen check. |
| **4** | `c128` ✅, `vic20` ✅, `plus4` ✅, `pet2001` ✅, `cbm8032` ✅, `cbm2` ✅; `c64` ⏸ | **Six landed 2026-08-10.** Identical procedure ×6, no per-tile emulator build. `c64` is NOT part of it and is not a seventh repeat — see below. |
| **5** | `daybreak`, `nextstep`, `apple2` | Real per-tile work with real runtime risk. `apple2` needs a genuine framebuffer + GEOS-mouse re-verification under sdl12-compat. |
| **6** | `star` | Blocked on the `nuget` bootstrap; independent of every other tile. |
| **7** | `sinclairql`, `zxspectrum` | Romset re-derivation against MAME 0.276 plus two golden re-bakes. Do these when nothing else is in flight. |

### What wave 4 settled about `c64`, and what it did not

Six sibling tiles now run the same source-built VICE 3.9 on the trixie base, so
the **emulator question is closed for `c64` before anyone starts it**: gcc-14's
VICE renders identically, the ROM tree the base retains at
`/usr/local/src/vice-3.9/data` is complete (asserted for C64, C128, VIC20, PET,
PLUS4, CBM-II and DRIVES), and `x64sc` is present and already proven by wave 0.
Nothing about the emulator is left to discover. What remains is entirely about
`c64` being **detached**, and it is worth being precise about why that is not a
seventh repetition of this wave.

One specific pre-check is already done: **the `make install` ROM gap that bit the
original `c64` build does not exist on the trixie base.** That trap — VICE's
`make install` silently skipping ROM data files, after which the emulator
segfaults on startup with no output at all — first bit `c64` on the C64 BASIC ROM
and later `vic20` on `basic-901486-01.bin`. On `bridge-base-trixie.qcow2` the
installed tree `/usr/local/share/vice/C64/` already contains all three ROMs a
stock C64 loads (`basic-901226-01.bin`, `kernal-901227-03.bin`,
`chargen-901225-01.bin`), and the source tree it repairs from is intact. The
remaining work is about the disk image, not the emulator:

- **There is no overlay to rebase and no rollback to fall back on.** For these
  six, `migrate-tile.sh` moved a delta aside and could put it back byte-for-byte
  because the bookworm base is frozen. `c64`'s 5.21 GiB standalone image is the
  only copy of its state; the equivalent safety net is an explicit **full copy
  taken first** (and ~2.5 GiB of its blocks are duplicated base content that a
  rebuilt thin overlay would stop carrying — the migration is a disk-space win).
- **`c64.sh` does not bake its golden.** It is one of the six manual builders,
  so it takes `--bake` and the golden is a separate operator step through
  `lib/bridge-bake-golden`, under the tile's own launcher. Every tile in wave 4
  self-baked, so wave 4 exercised *none* of that path.
- **Its fixture is a booted application, not a power-on screen.** `c64` rests in
  the **GEOS 2.0 deskTop**, loaded from `GEOS.D64` (which is in the media
  archive, labelled `bridge-base/GEOS.D64`). Its siblings' predicates all assert
  a ROM banner that appears within seconds; the GEOS acceptance is a desktop that
  has to finish loading off an emulated 1541, which is why the builder waits for
  an operator rather than sleeping. Budget for that, and accept it on a real
  screenshot of the deskTop — not on "the tile is up".
- **It is the one VICE tile with a pointer.** `c64` is `pointer_mode rel`:
  streamhost translates absolute browser coordinates to PS/2 relative for VICE's
  1351 mouse path. The other six are keyboard-only (`pointer none`), so wave 4
  proved nothing about mouse tracking under a trixie-built VICE. The GEOS mouse
  must be re-verified on the framebuffer the way `apple2`'s is called out at §3.

---

## 5. What "done" looks like

The migration is finished when the ledger's `tiles` map is all `trixie` and
`defaultSuite` is `trixie`. The payoff is deletion:

- **`/data/vms/bridge/bridge-base.qcow2`** — the frozen bookworm base — becomes
  deletable, once no overlay's backing file names it. That is a
  `bridge-suite-status.sh` question, not a judgement call.
- **`/data/vms/soltest/bookworm-chroot`** goes with it. The chroot exists only
  to build binaries for a guest older than the host; when guest and host are
  both trixie, a host-built binary runs in the guest unchanged and the
  ABI-matching machinery has nothing left to match.
- **`indyr4400`'s throwaway debootstrap** goes too, for the same reason.
- `bridge-suite.sh` and the ledger can then collapse to a single suite — but
  leave them in place until the deletions above are actually done, because they
  are what proves the deletions are safe.
