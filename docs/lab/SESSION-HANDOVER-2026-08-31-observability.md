# Session handover — observability, 2026-08-31 (end of the rollout session)

**Read this before touching `scripts/dev/fleet_rollout.py`,
`scripts/dev/fleet_rollout_policy.py`, `scripts/host/fleet-rollout-probe.sh`,
`scripts/observability/`, or the trace/probe planes.**

The previous session built the analytics and APM planes and left the Rust half
merged but never executed. **This session executed it.** The binary was built,
canaried and rolled across the fleet, the daemon's spans now reach the store,
and the docs were corrected to match. What remains is listed in §3, and two
decisions are yours (§5).

**Start here:** §1 for what is true now, §5 for what needs YOU, §4 for the traps
— every one of them was found by running the thing, not by reading it.

---

## 1. What is true now

| Plane | State |
|---|---|
| Feature reach, flows, metrics (browser) | live |
| Server-side branch probes (Python) | live |
| OTel traces (browser, Python) | live |
| **Rust `streamhost` probes + spans** | **LIVE on 66 stations — first execution ever** |
| **Daemon span → store carrier** | **`scripts/observability/trace-ship.py`, run by hand on the box** |
| Observability UI `/admin/observability` | live, admin-only |
| Line coverage lane | built, NOT armed |
| Instana forwarding | works, by hand, not on a timer; visibility still unproven (§3) |

Binary now on the fleet: `streamhost-3546b768762d1262bfc92a45a9df49cad681ca9e`.
Box deploy state is whatever `scripts/dev/box-deploy.sh --status` says; it was
`main@93644621` at handover.

**The store holds all three planes for the first time.** 66 stations × 4
boot spans (`streamhost.start`, `guest.launch`, `guest.attach`,
`guest.first_frame`), exactly matching the 66 stations on the new binary, with
no duplicates and nothing malformed.

**No trace has JOINED yet, and that is not a bug.** Both ends are deployed —
`signal_route.py` appends `?traceparent=`, `trace/context.rs` reads it. But
`kh.trace.joined` rides `streamhost.session`, which exists only when a REAL
VISITOR connects. Every span recorded so far is a boot-time root. **The first
visitor to any rolled station proves the hop; nothing else can.** Check it with
`SELECT json_extract(attrs,'$."kh.trace.joined"') FROM span WHERE
name='streamhost.session'` (single quotes — see §4).

## 2. The rollout, and the five stations that are not on the new binary

66 of 71 live stations rolled. 57 passed the tool's full framebuffer gate; the
rest were proven by direct capture (§4 explains why the gate could not see
them). The five that did NOT roll, and why each is correct:

| station | why | to finish it |
|---|---|---|
| `irix` | a visitor was connected — the tool defers, deliberately | re-run when clear, or `--include-busy` |
| `win95`, `beos`, `sunos414`, `hpuxvue` | held by another session's kh-claim (retained evidence) | roll after those claims are released |

`sailfishos` is a failed unit, parked on purpose, and was skipped as designed.
`amigaos` and `solariscde` appear in `/usr/local/lib/streamhost/stations/` on an
old pointer but are NOT live registry stations — stale directories, not a miss.

## 3. What is still NOT built

- **`reach-report.py` does not read `probes.json`.** The deployment half is done
  and every station now dumps real counts; joining them to the SPA catalogue is
  the remaining step, and it is now the only thing between us and a fleet-wide
  answer to "which daemon code earns its keep".
- **Instana visibility is still unproven, and the next experiment is now
  possible.** §4 of the previous handover established that Instana only builds a
  trace from an ENTRY span; the serving plane and the daemon both emit
  `server`-kind roots now, with real children, which is the shape that was never
  testable before. `--check` confirms the credential is accepted. **What I did
  NOT establish: whether the forwarder actually picks up daemon spans and how it
  labels them.** `--dry-run` samples one trace and showed only browser spans, so
  I could neither confirm nor refute a labelling problem — do not repeat my
  first guess that it is broken. The specific question: daemon spans carry no
  `kh.service` attribute (only the Python plane stamps one), so check what
  `service.name` they leave under before reading anything into a result.
- **Instana forwarding on a timer** — still deliberate, still by hand.
- **The line-coverage lane is not armed.**
- **The agent key was pasted into a chat transcript in a previous session.
  Still worth rotating.**

## 4. Traps, all found by running it

Every rollout-mechanics trap this session hit — the canary-only wave
deadlock, the fixed non-black floor failing on `alpine` and `mpf2`, the
paused-shm seqlock, `c128`'s dead-pid resume-retry loop, and the
`labctl shot` vs. the gate's own probe misdiagnosis — is now the operating
practice in
[`FLEET-ROLLOUT.md`](FLEET-ROLLOUT.md#running-a-rollout-end-to-end) and its
"health gate is the framebuffer" section, not restated here: read those
before the next rollout, not this handover.

- **SQLite's double-quote fallback** still applies: single quotes for string
  literals, always.

## 5. Decisions waiting for you

1. **`irix`** — roll it when its visitor leaves, or bump them with
   `--include-busy`. It is the only live station still on the old binary by
   circumstance rather than by claim.
2. **Converge `shmshot` on the frozen read (option b), or leave the fork?**
   The rollout probe currently duplicates shmshot's header parsing rather than
   loosening the shared reader for every caller. The cost of leaving it: two
   copies of a wire format, and `labctl shot`/`assert` keep failing on any
   paused shm exhibit — demonstrated, not hypothetical. The cost of converging:
   the relaxed read affects every `labctl` capture consumer. My recommendation
   is to converge, gated on the same `/proc` proof, so both call sites agree.
3. **`c128` deserves an eyeball.** It is serving again (856×576, 2.1% non-black,
   consistent with its sibling VICE stations) but it is the one station that
   actually broke today.

## 6. Sandboxes

`fleet-roll-fix` and `gate-baseline` held this session's work; both are merged
to `main` and both sandboxes were RELEASED at the end of it. The
previous session's `otel-prop`, `otel-python`, `otel-rust` and `fleet-roll` are
also merged and releasable — note that `otel-rust` does NOT contain a built
binary despite the previous handover saying so; its `target/` is empty.

## 7. If you do one thing next

**Open a station in a browser and look for a joined trace.** Everything else is
landed; the one claim this system makes that has never been observed end to end
is that a single trace id crosses browser → serving plane → daemon. All three
emit, the hop is deployed on both sides, and it takes one visit to find out.
Then run `trace-ship.py` on the box and read `/admin/observability`.
