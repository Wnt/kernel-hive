# es40 fork: how it is pinned, built and deployed

**Status: DONE.** The fork is under version control as a submodule with a pinned
builder, and both stations run one binary built from that pin. This document
records what the lab does with es40 and why; it is no longer a decision brief.

Two live stations run the es40 Alpha emulator — [`w2kalpha`](../guests/w2kalpha.md)
and [`tru64`](../guests/tru64.md). This brief says where the source lives, how a
binary is produced from it, what each station runs, what a rebuild really costs,
and the defect that started the investigation.

---

## 1. How it is pinned, in one screen

The es40 source is **not vendored**. It comes in the way this repo adds every
other external emulator: a `third_party/` submodule on our own fork, plus a
builder script that pins a commit and asserts it.

| | |
|---|---|
| fork | `github.com/Wnt/es40`, branch `main` |
| submodule | `third_party/es40`, gitlink pinned to the builder's commit |
| builder | [`scripts/build-guests/emulators/build-es40.sh`](../../scripts/build-guests/emulators/build-es40.sh) |
| pin | `ES40_FORK_PIN` in that builder — **`19678ad`** |
| declared | `registry/release-notes/sources.json`, `pinnedBy` the builder, `.gitmodules` and both station entries |

`scripts/release-notes.py check` now enforces this in both directions: the
declaration must still parse to `Wnt/es40 main`, and no undeclared `Wnt/*` pin
may appear. Until this landed, es40 was the only one of the four declared forks
with **no** commit pin anywhere in the repo.

**One build serves both stations.** The binary is byte-identical for `w2kalpha`
and `tru64` — everything that differs between them is launcher environment
(`ES40_TILE_NAME`, `ES40_POINTER_GAIN`, ports, disks), not compiled code. The
builder compiles once and installs the same product to each station named on its
command line. That is how the two were converged; see §3.

**The provenance is now true, not merely present.** `configure.ac` declares
`ES40_GIT_COMMIT` as an `AC_ARG_VAR`, so the builder passes the pin explicitly
at configure time and then **runs the built binary and asserts the hash it
prints is the pin**. It also always re-runs `configure`, never reusing a
`config.h` from an earlier pin — doing exactly that is how both production
binaries came to advertise a commit four pins out of date (§3).

**Two build inputs live outside this repo and are not optional.**

- **The sysroot**, `/data/vms/soltest/ALPHA-nt/root` (overridable with
  `ES40_SYSROOT`): SDL3, libpcap and pipewire's `.pc` file, which SDL3's
  pkg-config wants. None are installed on labhost, deliberately. Its libdir is
  also the binary's `RUNPATH`, matching how both production binaries were linked.
- **Each station's library mirror**, `<assets>/root/usr/lib/x86_64-linux-gnu`,
  which its launcher puts on `LD_LIBRARY_PATH`. The builder's install gate runs
  the new binary under exactly that path per station, so "this station can
  actually execute this binary" is proven at build time rather than at 03:00 on
  the gallery floor.

**Installing is not deploying.** The builder backs up any binary already in
place to `es40.bak-<UTC stamp>`, writes `es40.sha256` and `es40.provenance.txt`
beside the new one, and **restarts nothing** — the running emulator holds the old
inode until the station is restarted, which is a station decision.
`systemctl restart streamhost@<x>` stops the guest.

### Why the tree is not vendored

| | |
|---|---|
| **Precedent** | The repo has **never** committed an upstream source tree. Every external emulator — MAME, VICE, QEMU, SIMH, ContrAlto2, SeaBIOS — is a pinned commit cloned at build time, optionally with a `Wnt/*` fork submodule under `third_party/`. Vendoring would be the first of its kind. |
| **Licence** | es40 is **GPL-2.0-or-later** (`COPYING`, and every source header). This repo is **MIT**, with one documented GPL carve-out (`streamhost/`, for libx264) whose README states the trees are independent. A vendored GPL C++ tree would be a second, much larger carve-out — for no benefit the submodule does not already give. |
| **Gates** | C/C++ has no dialect in `check-file-size.mjs`, so the sources would pass ungated — but the repo-wide **bash and python** gates (`shfmt`, `shellcheck`, `ruff`, and the 600-line bash cap) *do* scan `third_party/` (the ignore regex covers `vendor/`, not `third_party/`). A real tree there would drag es40's own autotools shell into our lint. A **gitlink does not**: `git ls-files` never descends into it. |
| **Size / nesting** | The tree is ~460 MB as checked out, and upstream es40 itself carries a nested `third_party/asmjit` submodule (which the builder checks out recursively — the JIT needs it). |
| **Operator's standing decision** | Recorded in `docs/lab/research/alpha-nt-add.md`: *"Source edits go onto the fork as commits (operator: no .patch files)."* That rules out a patch-series for es40 specifically. |

The one thing vendoring would buy — durability if GitHub vanishes — the
submodule buys too, because the fork is pushed. The builder prefers the
checked-out submodule as its source precisely so a build needs no network; it
falls back to cloning the fork, loudly and only when the submodule is unreadable,
and asserts the pin either way. (That fallback is not theoretical: the builder
runs as root on labhost, and git's ownership check refuses a submodule gitdir
owned by a normal user — a refusal that is deliberately **not** satisfiable from
`-c safe.directory=` or the `GIT_CONFIG_*` environment on clone's source path.)

## 2. Where the fork lives, and under what version control

- **Working checkout:** `/data/vms/sandbox/ALPHA-nt/es40src` on labhost (also
  reachable from CT950 at the same path). This is the tree every doc points at
  and the tree both production binaries were built from.
- **It is a git repo**, with two remotes: `origin` = upstream
  `github.com/ES40-Emu/es40`, `fork` = `github.com/Wnt/es40`.
- **`main` is 17 commits ahead of upstream `a9bda96`**, and **those commits are
  published**: `git ls-remote` shows `Wnt/es40 refs/heads/main = 936760c…`,
  identical to the local HEAD. The lab's es40 work is **not** trapped on one
  disk. (The local clone has no `refs/remotes/fork/*` and no `FETCH_HEAD`, which
  makes it *look* unpushed — it is not. Check the remote, not the local refs.)
- **The `SAVEST` hunk is committed and published** as `0a7af85` (2026-08-24).
  Those 24 lines in `src/gui/ctlsock.h` had been running **uncommitted** in
  `w2kalpha`'s deployed binary — which is what made that binary reproducible
  from nothing. It is not a scratch edit: it adds the `SAVEST <file>` verb that
  is the only way to checkpoint a station while it is actually being served,
  because `pumps.py` owns es40's first serial socket so the SRM menu's
  save-and-exit never sees the keystrokes. See §3.
- **Author history from CT950, never over `ssh lab`.** `/data/vms` is
  bind-mounted into CT950, so `/data/vms/sandbox/ALPHA-nt/es40src` is the *same
  files* here — `git -C …` works directly and **no rsync or second checkout is
  involved**. CT950 has `~/.ssh/id_github`, a git identity and push rights;
  labhost has no credential helper, no `gh` and no git identity, so a push from
  there needs an explicit `GIT_SSH_COMMAND` and `-c user.name` — which is the
  smell telling you that you are on the wrong machine. The remotes are HTTPS, so
  push by SSH URL: `git push git@github.com:Wnt/es40.git HEAD:main`. **Stage
  explicit paths, never `git add -A`** — the tree is full of untracked build
  artefacts (`src/es40.O3`, `src/es40.baseline`, …).
- Other copies: `/home/wnt/es40` (clean CT950 clone at `936760c`), and this
  investigation's sandbox copy. The two directories the production binaries were
  actually built in (recovered from DWARF `DW_AT_comp_dir`:
  `/data/vms/soltest/w2krestore-wrst/es40src`, `…/tru64res-p7q/es40src`) **no
  longer exist**.
- **Licence: GPL-2.0-or-later.** `src/gui/ctlsock.h` is wholly lab-authored and
  carried **no licence header at all** until `19678ad`, which gave it the
  project's standard GPL-2.0-or-later header along with the fix below.

---

## 3. Per-station build provenance

**Both stations now run the same binary**, built by
`scripts/build-guests/emulators/build-es40.sh` from `19678ad` and installed
2026-08-24: sha256 `adf5a359cde43cff50308529f49305f088ddce34dc1d95e71a8ffb5c47ca67fb`,
reporting `ES40 0.80 (GitHub commit 19678ad…)`. Three separate builds of the pin
produced that same sha256, so the build is reproducible. Each station carries an
`es40.provenance.txt` and `es40.sha256` beside the binary, and the binary it
replaced is kept alongside as `es40.bak-<stamp>`.

### What they ran before, and why nobody could tell

Neither deployed binary corresponded to a published commit, and neither
corresponded to the other. They were one commit and one uncommitted hunk apart,
in *opposite* directions.

| | `w2kalpha` | `tru64` |
|---|---|---|
| size / mtime | 19 863 288 B, 2026-08-16 17:48 | 19 864 176 B, 2026-08-16 20:59 |
| sha256 (taken with the emulator stopped, at swap time) | `c4045c4d…` | `0f88a3ef…` |
| `ES40_POINTER_GAIN` (`936760c`) | **absent** | **present** |
| `SAVEST` verb | **present** (uncommitted hunk) | **absent** |
| inferred source | `a09816d` **+ the uncommitted hunk** | `936760c` clean |

**How would anyone have known? Only by `strings`.** es40 *does* have a
provenance mechanism — `configure.ac` bakes `ES40_GIT_COMMIT` and
`AlphaSim.cpp` prints it — but **both binaries carried the same stale hash
`e4a96e3`**, because `config.h` was generated by one old `configure` run and
never regenerated. §1 says how the builder fixes that and then proves it.

### Three lies in one binary

The stale `ES40_GIT_COMMIT` was not an isolated slip. This one emulator's
control plane asserted three things that were not true, and all three are now
closed:

| the claim | the truth | closed by |
|---|---|---|
| `ES40_GIT_COMMIT` names the commit this was built from | a hash four pins out of date, in **both** binaries | the builder passes the pin and asserts what the binary prints (§1) |
| HELLO `caps=natkbd,savest` on `tru64` | answered `ERR unknownverb` — the literal was committed, the handler was not | `0a7af85`, and `tru64` now builds from the pin |
| `OK` to a `MOVEA` | the target was silently discarded during the corner-home (§4) | `19678ad` |

They share a shape worth naming, because it is the shape that costs the most
time to debug: **a control plane that answers rather than reports.** A wrong
answer that arrives promptly is more expensive than no answer at all — it ends
the investigation. `SAVEST` was the cheapest of the three (nothing called it)
and `MOVEA` the most expensive (it sent an investigation after a visitor-facing
pointer defect that did not exist). The general defence is the one the builder
now applies: do not record a claim, record a **check** — bake the value, then run
the artefact and assert what it says.

**One provenance gap remains open.** es40 has no binary↔savestate guard. The
irix station writes `provenance-golden.md5` binding a savestate to the binary
md5 that made it, and `x11-runtime.sh` refuses to restore across a binary
change; the es40 launchers restore blindly. §5 explains why that matters more
than the docs assumed.

## 4. The defect: `OK` that meant nothing

In `src/gui/ctlsock.h`, every `accept()` re-arms a paced corner-home
(`m_home_polls = max(w,h)/96 + 4` — 17 polls, ~340 ms at 1280×1024), and
`move_abs()` opened with:

```cpp
  void move_abs(int tx, int ty)
  {
    if (m_home_polls > 0)
      return;                    // silent drop — and handle_line still acks OK
```

The old comment defended the drop: streamhost restates its target continuously,
so its first post-home move lands anyway. That reasoning is sound **only for a
long-lived connection**. A tool that connects, sends one `MOVEA` and hangs up —
the natural shape of a one-shot CLI, and exactly what `labctl mctl` is — re-arms
the home with its own `accept()`, has its move discarded, gets `OK`, and leaves
the cursor wherever the home slam parked it.

**This bites tools, not people.** A visitor's pointer is fine, and treating this
as a visitor-facing pointer defect is the mistake this investigation exists to
correct.

### The fix, and how closely it follows the in-repo reference

The reference is `scripts/build-guests/emulators/mamectl/src/osd/modules/ctlsock/ctlsock.cpp`,
where the contract is explicit — `reply_ok(ack); // MOVEA acks on target-accept;
completion is EV MOVEA` — and a target is *never* silently dropped: even one that
gives up emits an event, and targets deferred behind an in-flight move are
applied rather than discarded.

The patch adopts **the structure**:

- `move_abs()` **latches** the target instead of dropping it (latest-wins
  coalescing, as the reference coalesces targets), so `OK` honestly means
  *accepted*.
- `poll()` applies the latched target once the home finishes — **and it runs
  even if the client has already hung up**, which is precisely the broken case.
- A completion event `EV MOVEA <seq> applied <x> <y>` is broadcast when it lands,
  giving the same two-phase contract as the reference. `streamhost`'s
  `mame_sock.rs` already routes `EV ` lines as non-ack async events, so this is a
  drop-in on the client side.

It deliberately does **not** adopt the reference's **vocabulary**. The reference
says `converged`, because it closes its loop over a hardware-cursor *reading*.
es40 has no cursor readback, so it can only assert that the delta was injected —
hence `applied`. Claiming convergence would trade one dishonest ack for another.

Two things found while fixing it, both real:

- **A settle window is load-bearing.** `mouse_motion` accumulates into one async
  delta, so a move injected in (or too near) the poll that made the final home
  step **merges** with it and lands ~96 px short. First attempt did exactly that;
  the symptom was intermittent, which is how a merge race presents. Four quiet
  polls (~80 ms, paid once per connection) fixed it.
- **A `MOVEA` further than ~255 px from the current belief still lands short —
  NOT fixed, and pre-existing.** One PS/2 packet carries a 9-bit signed delta.
  Measured on the clone: `MOVEA 300 220` from the corner landed at **x=255,
  y=220** — x saturated, y (inside the range) exact. A **held-open** client hits
  this identically, so it is not an ack-honesty bug; streamhost is unaffected
  only because it restates continuously and the cursor walks there in hops. I
  built and tested an open-loop pacer for it and **it does not converge** — the
  guest's pointer response is non-linear at those per-sample deltas. That is
  exactly why the reference module closes its loop over a reading. Left as a
  documented follow-on rather than an unproven change to a live pointer path.

### The proof

On a **clone** of `w2kalpha` (own dir, own serial pair, own veth, own socket and
shm; production untouched), restoring the real `golden.axp`, driven by a
strictly one-connection-per-verb client. Position was read back from the shm
framebuffer — the guest's arrow renders into it, so the white core sits at a
fixed `target + (1,2)`.

| binary | one-shot `MOVEA` | ack | cursor |
|---|---|---|---|
| production `w2kalpha` (`a09816d` + hunk) | 3 targets | `1 OK` every time | **(0,0)** every time — move discarded |
| patched (`936760c` + hunk + this fix) | 8 targets in-range | `1 OK` every time | **exactly on target**, 8/8 |

and the two-phase contract, with the `MOVEA` sent *during* the home window:

```
  +0.03s  7 OK
  +0.27s  EV MOVEA 7 applied 300 220
```

The fix is confined to `src/gui/ctlsock.h` and, per the standing decision, lives
as a **commit on `Wnt/es40`** rather than a `.patch` in this repo:
**`19678ad`**, which is what `ES40_FORK_PIN` points at. Read it there — the
commit message carries the contract, the error cases and the measurements.

---

## 5. Rebuild cost per station — measured, in production

The docs used to say a rebuild **orphans the golden** and forces a cold re-bake.
That is **false** for these builds, and as of 2026-08-24 it is false *in
production*, not only on a clone.

Both stations were swapped onto `19678ad` and **both goldens survived**. Per
station: the emulator was stopped, the binary and **both halves of the golden
pair** were SHA256'd and byte-copied, the new binary was installed, the station
was started, and the restore was proven on the framebuffer. Both golden pairs
re-hashed **byte-identical after the swap** — the deploy never opens them for
write.

| | `w2kalpha` | `tru64` |
|---|---|---|
| golden pair | `golden.axp` + `nt.img` | `checkpoint/tru64.axp` + `checkpoint/tru64.img` |
| orphaned? | **No** — restored to the full 1280×1024 desktop, ICQ signed in as `50010` | **No** — restored to the CDE desktop with Gaim as `10000` |
| re-bake needed? | **No** | **No** |
| rollback | `es40.bak-20260824T131956Z` (`c4045c4d…`) | `es40.bak-20260824T130531Z` (`0f88a3ef…`) |

`w2kalpha` was the one carrying real risk: it jumped `a09816d → 19678ad`, which
adds `ES40_POINTER_GAIN` **and** changes PS/2 `0xe6` (Set Scaling 1:1) handling.
The gain defaults to 1 and that launcher does not export it, and the pointer was
re-verified after the swap: eight one-shot targets, 8/8 exact.

**Why the goldens survive:** an es40 savestate is a per-component
`fwrite(&state, sizeof(state))` dump guarded by magic + version — it is tied to
**struct layout**, not to the binary. `ctlsock` is GUI-layer and registers no
saved component, and every commit crossed here touches only `ctlsock`.

**The caveat that keeps this honest:** "layout-identical" is a property of
*which commits you cross*, not of rebuilding as such. A future commit that
touches any saved component's struct **will** orphan both checkpoints,
silently — es40 has no guard, it just loads. Read the fork's log before moving
`ES40_FORK_PIN`, and note that a restore proving fine on one station is not
evidence for the other: prove it per station, as the deploy did.

**A restart is not free even when the golden survives.** Both stations restore
to the checkpoint, so anything that happened *since* the last bake is gone —
`tru64`'s live Gaim conversation, `w2kalpha`'s ICQ session. Both reconnect on
their own (that is what proved the restore was a restore and not a resume: the
live-only chat line was absent), but a swap during a visitor's session is a
visible interruption. Restart deliberately.

## 6. Open, and deliberately not fixed

- **A `MOVEA` further than one PS/2 packet from the current belief lands short.**
  One packet carries a 9-bit signed delta, so the single-injection reach is ~255
  px, scaled by `ES40_POINTER_GAIN` — ~255 px on `w2kalpha` (gain 1), ~510 px on
  `tru64` (gain 2). Measured on both live stations: the in-range axis is exact
  and the out-of-range axis saturates (`tru64` `MOVEA 640 420` → x≈510, y=420
  exact). **Pre-existing, and a held-open client hits it identically**, so it is
  not an ack-honesty defect; streamhost is unaffected because it restates the
  target continuously and the cursor walks there in hops. An open-loop pacer was
  built and tested and does **not** converge — the guest's pointer response is
  non-linear at those per-sample deltas, which is exactly why the reference
  module (mamectl `ctlsock.cpp`) closes its `MOVEA` loop over a cursor READING.
  Fixing it needs a readback es40 does not have.
- **Why that response is non-linear.** Not investigated. It needs the guest-side
  measurement `tru64` has (`xptr`) and `w2kalpha` lacks.
- **No binary↔savestate guard** (§3, §5). Cheap to add, modelled on irix's
  `provenance-golden.md5`; not done here because this deploy crossed only
  ctlsock commits, which is exactly the case the guard would wave through.
- **Historical attribution of the two retired binaries** rests on feature
  strings, not on the hash they carried: both baked the stale `e4a96e3`, and the
  directories they were built in are gone. They are preserved as
  `es40.bak-<stamp>` beside each station's binary, so the artefacts survive even
  though their provenance cannot be reconstructed. This is the problem the
  builder exists to prevent recurring.

## 7. Where the code is

The fix is `19678ad` on `github.com/Wnt/es40`, branch `main` — the commit
`ES40_FORK_PIN` names. The diff is not reproduced here on purpose: the fork is
where that code lives, a copy in this repo would be a second source of truth
free to drift from the first, and the commit message already carries the
contract, the error cases and the measurements in more detail than a diff does.

`git -C third_party/es40 show 19678ad` after `git submodule update --init
third_party/es40`.
