# es40 fork: bring it in, or pin it? — decision brief

**Status: DECISION PENDING (operator).** Everything below is investigation and a
tested patch. Nothing was deployed; no live binary and no golden was touched.

Two live stations run the es40 Alpha emulator — [`w2kalpha`](../guests/w2kalpha.md)
and [`tru64`](../guests/tru64.md) — on **two different builds**, from a source
tree that lives outside this repo. This brief answers: where that tree is, what
each station actually runs, whether the fork should come into the repo, what a
rebuild really costs, and it carries a tested fix for the defect that started
the investigation.

---

## 1. The recommendation, in one screen

**Do NOT vendor the es40 source tree. Add it the way this repo already adds every
other external emulator: a `third_party/` submodule on our own fork, plus a
builder script that pins a commit and asserts it.**

Concretely, three steps, in this order:

1. **Commit the orphan hunk.** `src/gui/ctlsock.h` in the working checkout has a
   24-line uncommitted `SAVEST` verb that is **compiled into w2kalpha's live
   binary**. Until it is a commit, w2kalpha's deployed binary cannot be
   reproduced from anything. Land it on `Wnt/es40` and push.
2. **`third_party/es40` as a submodule** of `github.com/Wnt/es40`, pinned. The
   fork is already published and already declared in
   `registry/release-notes/sources.json` — it is the **only** one of the four
   declared forks with no commit pin, and the registry entries for both stations
   literally say `"github.com/Wnt/es40 main — no commit pinned in the repo"`.
3. **`scripts/build-guests/emulators/build-es40.sh`**, modelled on
   `build-vice-native.sh`: `ES40_FORK_URL`/`ES40_FORK_BRANCH` constants (the
   shape `scripts/release_notes_pins.py` already parses), a hard
   `git rev-parse HEAD` assertion against the pin, and a
   `<binary>.provenance.txt` + `.sha256` epilogue in the shape of
   `build-seabios-int16if.sh`. There is **no es40 builder in the repo today** —
   the build is a sentence in a doc (`cd es40src/src && make -j6`).

### Why not vendor the tree

| | |
|---|---|
| **Precedent** | The repo has **never** committed an upstream source tree. Every external emulator — MAME, VICE, QEMU, SIMH, ContrAlto2, SeaBIOS — is a pinned commit cloned at build time, optionally with a `Wnt/*` fork submodule under `third_party/`. Vendoring would be the first of its kind. |
| **Licence** | es40 is **GPL-2.0-or-later** (`COPYING`, and every source header). This repo is **MIT**, with one documented GPL carve-out (`streamhost/`, for libx264) whose README states the trees are independent. A vendored GPL C++ tree would be a second, much larger carve-out — for no benefit the submodule does not already give. |
| **Gates** | C/C++ has no dialect in `check-file-size.mjs`, so the sources would pass ungated — but the repo-wide **bash and python** gates (`shfmt`, `shellcheck`, `ruff`, and the 600-line bash cap) *do* scan `third_party/` (the ignore regex covers `vendor/`, not `third_party/`). A real tree there would drag es40's own autotools shell into our lint. A **gitlink does not**: `git ls-files` never descends into it. |
| **Size / nesting** | The tree is ~460 MB as checked out, and upstream es40 itself carries a nested `third_party/asmjit` submodule. |
| **Operator's standing decision** | Already recorded in `docs/lab/research/alpha-nt-add.md`: *"Source edits go onto the fork as commits (operator: no .patch files)."* That rules out the patch-series option for es40 specifically. |

**The one thing vendoring would buy — durability if GitHub vanishes — the
submodule buys too, because the fork is already pushed.** What is genuinely at
risk today is not the tree; it is the *uncommitted* hunk (step 1) and the
*unrecorded* build provenance (step 3).

---

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
- **The tree is dirty.** `src/gui/ctlsock.h` carries **24 uncommitted lines**
  adding a `SAVEST <file>` verb. This is not a scratch edit: it is compiled into
  a live station's binary. See §3.
- Other copies: `/home/wnt/es40` (clean CT950 clone at `936760c`), and this
  investigation's sandbox copy. The two directories the production binaries were
  actually built in (recovered from DWARF `DW_AT_comp_dir`:
  `/data/vms/soltest/w2krestore-wrst/es40src`, `…/tru64res-p7q/es40src`) **no
  longer exist**.
- **Licence: GPL-2.0-or-later.** Note `src/gui/ctlsock.h` — a wholly
  lab-authored file — carries **no licence header at all**. Worth fixing when it
  is next touched.

---

## 3. Per-station build provenance

**Neither deployed binary corresponds to a published commit, and neither
corresponds to the other.** They are one commit and one uncommitted hunk apart,
in *opposite* directions.

| | `w2kalpha` | `tru64` |
|---|---|---|
| binary | `assets/w2kalpha/es40` | `assets/tru64/es40` |
| size / mtime | 19 863 288 B, 2026-08-16 17:48 | 19 864 176 B, 2026-08-16 20:59 |
| md5 | `3dea44e8a7080793c5224faafd453f34` | `d36c83bc1193c660f26ba18211f515cb` |
| GNU build-id | `7d510997…` | `ffa59382…` |
| `ES40_POINTER_GAIN` (`936760c`) | **absent** | **present** |
| `SAVEST` verb (uncommitted hunk) | **present** | **absent** |
| inferred source | `a09816d` **+ the uncommitted hunk** | `936760c` clean |

**How would anyone know? Today: only by `strings`.** es40 *does* have a
provenance mechanism — `configure.ac` bakes `ES40_GIT_COMMIT` from
`git rev-parse HEAD` and `AlphaSim.cpp` prints it — but **both binaries carry the
same stale hash `e4a96e3`**, because `config.h` was generated by one old
`configure` run and never regenerated. The mechanism exists and is lying. Step 3
of the recommendation fixes this; re-running `configure` in the builder is the
cheap half.

Two more provenance holes worth naming:

- **`tru64`'s binary advertises a capability it does not implement.** Its HELLO
  banner says `caps=natkbd,savest` (that literal is committed), but the `SAVEST`
  handler is the *uncommitted* hunk, which its build predates — so it answers
  `ERR unknownverb`. `docs/guests/tru64.md` said the opposite; corrected in this
  branch. Harmless today (the bake path uses the serial menu), but it is the
  same disease as §4: **saying yes and meaning no.**
- **es40 stations have no binary↔savestate provenance guard.** The irix station
  writes `provenance-golden.md5` binding a savestate to the binary md5 that made
  it, and `x11-runtime.sh` refuses to restore across a binary change. The es40
  launchers restore blindly. Cheap to add, and §6 explains why it matters more
  than the docs assumed.

---

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

The patch is 95 added lines, confined to `src/gui/ctlsock.h`. It is kept at
`/data/vms/sandbox/es40-scope/ack-honesty.diff` and reproduced in §7 so it
survives the sandbox. Per the standing decision it should land as a **commit on
`Wnt/es40`**, not as a `.patch` in this repo.

---

## 5. Rebuild cost per station — much lower than recorded

The docs said a rebuild **orphans `golden.axp`** and forces a cold re-bake. That
is now **measured to be false** for these builds.

**Evidence:** `w2kalpha`'s live `golden.axp` (2026-08-24, the fresh ICQ one) was
restored on the clone under a binary built from `936760c` + the `SAVEST` hunk +
this patch — i.e. **a build w2kalpha has never run, one fork commit ahead of its
own**. It restored to the full 1280×1024 desktop with ICQ signed in as `50010`,
correct in the framebuffer. No cold boot, no corruption.

**Why:** an es40 savestate is a per-component `fwrite(&state, sizeof(state))`
dump guarded by magic + version — it is tied to **struct layout**, not to the
binary. `ctlsock` is GUI-layer and registers no saved component, and `936760c`
touches only ctlsock. So the checkpoint is portable across these builds.

| | `w2kalpha` | `tru64` |
|---|---|---|
| orphans the golden? | **No** — proven by restore | **No** — patch is ctlsock-only, and its binary is already `936760c` |
| re-bake needed? | **No** | **No** |
| sequence | commit the hunk → build at pin → stage binary beside the old one → `systemctl restart streamhost@w2kalpha` → verify framebuffer + pointer | same |
| rollback | `es40.bak-preinstant-20260816`, `es40.O2/O3/pgo/lto` preserved beside the binary | `es40.bak-pregain-20260817`, `es40.bak-preinstant-20260816` |
| real risk | w2kalpha jumps `a09816d → 936760c`, which adds `ES40_POINTER_GAIN`. It **defaults to 1** and the launcher does not export it, so behaviour is unchanged — but `936760c` also changed PS/2 `0xe6` (Set Scaling 1:1) handling, so **re-verify the pointer** after the swap. | none beyond the patch |

**The caveat that keeps this honest:** "layout-identical" is a property of *which
commits* you cross, not of rebuilding as such. A future commit that touches any
saved component's struct **will** orphan the checkpoint, silently — es40 has no
guard, it just loads. That is the argument for the `provenance-*.md5` guard in
§3, and it is why the builder should record the pin.

---

## 6. What I could not determine

- **The exact commit for each deployed binary is not recoverable from the
  binary.** The embedded `ES40_GIT_COMMIT` is stale (`e4a96e3`) in both. §3's
  attribution rests on feature strings, and the original build dirs are gone.
- **Whether the `SAVEST` hunk exists anywhere but these working trees and
  w2kalpha's binary.** `ls-remote` shows only `main` and
  `tlb-hint-experimental`; it appears not to.
- **Why the guest's pointer is non-linear at large per-sample deltas** (§4). Not
  investigated — it needs the guest-side measurement `tru64` has (`xptr`) and
  `w2kalpha` lacks.

## 7. The patch

Against `src/gui/ctlsock.h` at `936760c` + the uncommitted `SAVEST` hunk.

```diff
--- a/src/gui/ctlsock.h
+++ b/src/gui/ctlsock.h
@@ -116,8 +116,39 @@
       {
         m_bx = 0;
         m_by = 0;
+        // The belief was just re-synced against the guest's own edge clamp,
+        // so a gain residual carried from before the home describes a
+        // position that no longer exists. Drop it with the belief.
+        m_resid_x = 0;
+        m_resid_y = 0;
+        m_homed = true;
+        m_settle_polls = kSettlePolls;
       }
     }
+    else if (m_settle_polls > 0)
+    {
+      --m_settle_polls;  // inject nothing: let the guest drain the home packet
+    }
+    else if (m_pend_valid)
+    {
+      // Apply the MOVEA that was acked OK while the home was pacing. This
+      // runs even if the client that sent it has already hung up — the target
+      // belongs to the guest cursor, not to the connection that named it.
+      // That is the whole point: a one-shot tool is gone by now.
+      const int px = m_pend_x, py = m_pend_y;
+      const long pseq = m_pend_seq;
+      m_pend_valid = false;
+      move_abs(px, py, pseq);
+      // Completion signal, mamectl-style: OK meant ACCEPTED, this means
+      // APPLIED. Deliberately NOT the reference module's "converged": es40's
+      // pointer engine is open-loop and has no cursor readback, so it cannot
+      // honestly assert the guest cursor arrived — only that the delta was
+      // injected. Claiming convergence would trade one dishonest ack for
+      // another.
+      char ev[96];
+      snprintf(ev, sizeof(ev), "EV MOVEA %ld applied %d %d\n", pseq, px, py);
+      broadcast(ev);
+    }
     accept_clients();
     for (Client& c : m_clients)
       drain_client(c);
@@ -158,6 +189,23 @@
   int m_gain = 1;
   int m_resid_x = 0, m_resid_y = 0;
 
+  // Quiet polls between the last corner-home injection and a latched MOVEA,
+  // so the guest's PS/2 controller has consumed the home packet before the
+  // move is injected. mouse_motion accumulates into ONE async delta, so a
+  // move injected too soon MERGES with the home step and lands ~96 px short
+  // (measured on a w2kalpha clone: MOVEA 200 150 arriving at 104,54 on some
+  // runs and exactly on others — one poll of separation is not reliably
+  // enough). ~80 ms at the gui thread's ~50 Hz, paid once per connection.
+  static constexpr int kSettlePolls = 4;
+  int m_settle_polls = 0;
+
+  // Absolute target accepted (acked OK) while the corner-home was still
+  // pacing, applied by poll() once the home and its settle have finished.
+  // Latest-wins: only the newest target is worth applying. See move_abs().
+  bool m_pend_valid = false;
+  int m_pend_x = 0, m_pend_y = 0;
+  long m_pend_seq = 0;
+
   static const char* tile_name()
   {
     const char* n = getenv("ES40_TILE_NAME");
@@ -290,6 +338,18 @@
     (void)!write(c.fd, out, (size_t)len);
   }
 
+  // Async server->client line, delivered to every attached client.
+  // MSG_NOSIGNAL because the natural consumer of an EV is a one-shot tool
+  // that has already hung up: a departed client must not take the emulator
+  // down with SIGPIPE.
+  void broadcast(const char* line)
+  {
+    const size_t n = strlen(line);
+    for (Client& c : m_clients)
+      if (c.fd >= 0)
+        (void)!send(c.fd, line, n, MSG_NOSIGNAL);
+  }
+
   void handle_line(Client& c, const std::string& line)
   {
     // "<seq> VERB args..."
@@ -307,7 +367,7 @@
       int x = 0, y = 0;
       if (sscanf(verb + 6, "%d %d", &x, &y) == 2)
       {
-        move_abs(clampi(x, 0, (int)m_w - 1), clampi(y, 0, (int)m_h - 1));
+        move_abs(clampi(x, 0, (int)m_w - 1), clampi(y, 0, (int)m_h - 1), seq);
         ack(c, seq, true);
       }
       else
@@ -408,14 +468,41 @@
   // Absolute move, open-loop against the believed position. One delta per
   // target: the guest is configured for 1:1 pointer motion (no acceleration,
   // baked into the golden), so the exact remaining delta lands exactly and
-  // the believed position stays true. A move issued while the corner-home is
-  // still pacing is dropped (believed is not yet valid); the streamhost
-  // resends the current target continuously, so the first post-home move
-  // lands correctly.
-  void move_abs(int tx, int ty)
+  // the believed position stays true.
+  //
+  // ACK HONESTY. handle_line acks MOVEA with OK, so OK must mean ACCEPTED —
+  // the target WILL be applied. While the corner-home is pacing the belief is
+  // not yet valid, so the target cannot be applied NOW; it is LATCHED and
+  // applied by poll() once the home and its settle finish. Latest-wins.
+  //
+  // This replaces a silent drop. The drop was invisible to a client that
+  // holds its connection open (streamhost restates the current target
+  // continuously, so its first post-home move landed anyway), but it
+  // discarded EVERY move from a client that connects, sends one MOVEA and
+  // hangs up — one process per verb is one connection per verb, and each
+  // connection re-arms the home. Such a tool got OK for every move while the
+  // cursor never left the corner the home slam parked it in.
+  //
+  // KNOWN LIMIT, not fixed here: one PS/2 packet carries a 9-bit signed
+  // delta, so a single injection cannot express a move longer than ~255 px.
+  // A one-shot MOVEA further than that from the current belief lands short
+  // (measured: MOVEA 300 220 from the corner -> x=255, y=220 exact).
+  // streamhost is unaffected because it restates the target continuously and
+  // the cursor walks there in hops. Pacing the move here was tried and does
+  // NOT converge open-loop: the guest's pointer response is non-linear at
+  // these per-sample deltas, which is exactly why the reference module
+  // (mamectl ctlsock.cpp) closes its MOVEA loop over a cursor READING. es40
+  // has no such readback.
+  void move_abs(int tx, int ty, long seq)
   {
-    if (m_home_polls > 0)
+    if (m_home_polls > 0 || m_settle_polls > 0)
+    {
+      m_pend_x = tx;
+      m_pend_y = ty;
+      m_pend_seq = seq;
+      m_pend_valid = true;
       return;
+    }
     if (m_gain <= 1)
     {
       inject_mouse(tx - m_bx, ty - m_by);
```
