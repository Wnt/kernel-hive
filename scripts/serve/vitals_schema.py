"""The vitals store's schema, its catalogue, and the migrations that reshape it.

THE FOURTH PILLAR, AND WHY IT IS NOT A TABLE IN ONE OF THE OTHER THREE. A
stream is CONTINUOUS. There is no call to time and no event to count: the
question is "was the picture 30 fps and 2 Mbit/s for the last ten minutes, and
did the audio ever run dry", which is a TIME SERIES. Spans cannot answer it —
per-frame spans would be thousands a second — and `analytics.db`'s counters
cannot either, because they carry no per-sample timestamp at all, only a day
bucket (`scripts/observability/instana_metrics.py` says so in its own
docstring). So this is a third shape beside them, and it is the ONLY store in
the plane whose primary key question is "what was the value at time T".

WIDE, NOT TALL, and that is the one design decision worth arguing here. The
obvious shape for a metric store is `(ts, name, value)`. It was rejected:

  * ONE SAMPLE IS ONE OBSERVATION. Every number below is measured at the same
    instant by the same tick of the same client. "What was the fps when the RTT
    peaked" is a column comparison on one row here, and a self-join over there.
  * SIZE. Measured on a real sample: a wide row is ~250 bytes with its indexes;
    the same sample tall is 28 rows repeating a timestamp, a station, a session
    and a metric NAME each — about six times the bytes, for data whose whole
    problem is that sub-minute resolution is heavy.

THE COST OF WIDE, stated rather than discovered: adding a vital is a MIGRATION,
not an INSERT. That is what `migrate()` below is for, and the rule it inherits
verbatim from `logs_schema.py` and `traces_schema.py` is the one that took the
serving plane down on 2026-09-01:

    `executescript(SCHEMA)` runs on EVERY open, and `CREATE TABLE IF NOT
    EXISTS` does not reshape a table that already exists. So SCHEMA may never
    name a column a migration adds, and indexes over migrated columns are
    created by the migration, after the ALTER, on every path.

TWO PRODUCERS, ONE TABLE, HALF-NULL ROWS ON PURPOSE. The browser measures what
only the browser can see (decode latency, the audio play head, RTT); the daemon
measures what only it can see (encode time, capture rate, bytes out). Their
column sets barely overlap, so a browser row leaves the daemon columns NULL and
vice versa, and `source` says which kind of row it is. A NULL costs one byte in
sqlite; two tables would cost every reader a UNION and every writer a decision.

CARDINALITY IS DELIBERATELY LOW. Station, session and source. No per-frame
label, no tier label, no error-message label — those live in the log and trace
lanes, which are built for unbounded strings. A metric label is a dimension you
pay for forever in every backend that ingests it, ours included.

`seq INTEGER PRIMARY KEY AUTOINCREMENT` for the same reason `logs_schema.py`
gives: it is the watermark the Instana forwarder resumes from, and AUTOINCREMENT
buys monotonicity that survives any delete.
"""

from __future__ import annotations

#: THE CATALOGUE — the single source for what a vital is called on the wire,
#: in the store and in OTLP. Four fields: the store column, the OTLP metric
#: name, its unit, and its instrument kind.
#:
#: KIND IS NOT DECORATION. Instana's OTLP metrics acceptor takes Gauge, Sum and
#: Histogram and nothing else (0307-opentelemetry-signals.md:90-94; exponential
#: histograms are not mentioned anywhere in the corpus, so they are treated as
#: unsupported). A `gauge` is a value that means something on its own — fps is
#: 30 now. A `sum` is a MONOTONIC CUMULATIVE COUNTER the client has been adding
#: to since the session began — frames dropped is 41 SO FAR — and exporting one
#: as a gauge would make "41" look like a rate. Getting this wrong is silent:
#: both render as a line, and only the axis lies.
#:
#: UNITS ARE UCUM, which is what OTLP asks for: `ms`, `%`, `1` (dimensionless),
#: `kbit/s`, `By`.
CATALOGUE: tuple[tuple[str, str, str, str], ...] = (
    # ---- video, as the browser sees it -----------------------------------
    ("fps", "kh.stream.video.fps", "1", "gauge"),
    ("recv_kbps", "kh.stream.video.recv_kbps", "kbit/s", "gauge"),
    ("target_kbps", "kh.stream.video.target_kbps", "kbit/s", "gauge"),
    ("decode_ms", "kh.stream.video.decode_ms", "ms", "gauge"),
    ("decode_queue", "kh.stream.video.decode_queue", "1", "gauge"),
    ("loss_pct", "kh.stream.video.loss_pct", "%", "gauge"),
    ("window_loss_pct", "kh.stream.video.window_loss_pct", "%", "gauge"),
    # PAINT fps is not decode fps and the difference is the whole point of
    # keeping both: frames can decode and never reach the screen. `fps` is the
    # decoder's output rate, `paint_fps` the compositor's.
    ("paint_fps", "kh.stream.video.paint_fps", "1", "gauge"),
    ("tier", "kh.stream.video.tier", "1", "gauge"),
    ("crf", "kh.stream.video.crf", "1", "gauge"),
    ("width", "kh.stream.video.width", "1", "gauge"),
    ("height", "kh.stream.video.height", "1", "gauge"),
    ("fps_cap", "kh.stream.video.fps_cap", "1", "gauge"),
    # Cumulative since the session began — see the KIND note above.
    # `frames_dropped` is counted from frame_id GAPS, not from a WebCodecs
    # drop counter: no such counter exists (videoDecode.ts:380-383 says so).
    ("frames_dropped", "kh.stream.video.frames_dropped", "1", "sum"),
    ("freeze_count", "kh.stream.video.freezes", "1", "sum"),
    ("decode_errors", "kh.stream.video.decode_errors", "1", "sum"),
    ("session_rebuilds", "kh.stream.session.rebuilds", "1", "sum"),
    # Key access units seen. The KEYFRAME INTERVAL is a rate over this, not a
    # column: the configured `keyframeMs` is a setting and would tell us only
    # what we asked for, while the derivative of this counter is what arrived.
    ("key_aus", "kh.stream.video.key_aus", "1", "sum"),
    # ---- transport --------------------------------------------------------
    # `WebTransport.getStats()` does NOT exist in the Chrome this gallery
    # serves — measured, not assumed — so every number here comes from the
    # application-level ping already on `input.wire`, and from frame_id gaps.
    # There is no datagram-loss counter to read and none is invented.
    ("rtt_ms", "kh.transport.rtt_ms", "ms", "gauge"),
    ("rtt_floor_ms", "kh.transport.rtt_floor_ms", "ms", "gauge"),
    ("rtt_excess_ms", "kh.transport.rtt_excess_ms", "ms", "gauge"),
    ("rtt_peak_ms", "kh.transport.rtt_peak_ms", "ms", "gauge"),
    ("rtt_breach_ticks", "kh.transport.rtt_breach_ticks", "1", "gauge"),
    # ---- audio ------------------------------------------------------------
    # Before this lane, audio continuity was UNFALSIFIABLE: `audioPlayer.ts`
    # reported the first sample heard and the first sample blocked, and nothing
    # afterwards, ever. A session that went silent thirty seconds in looked
    # identical to one that played for an hour.
    ("audio_running", "kh.stream.audio.context_running", "1", "gauge"),
    ("audio_lead_ms", "kh.stream.audio.lead_ms", "ms", "gauge"),
    ("audio_underruns", "kh.stream.audio.underruns", "1", "sum"),
    ("audio_gaps", "kh.stream.audio.packet_gaps", "1", "sum"),
    ("audio_frames", "kh.stream.audio.frames", "1", "sum"),
    # ---- A/V sync ---------------------------------------------------------
    # MEASURABLE, and the reason is one line in `audioPlayer.ts`: the Opus
    # packet header's `ts_us` is "server µs epoch (shared with the video
    # capture ts)". Both media therefore carry a capture stamp off ONE clock,
    # so their skew through our pipeline is a subtraction. See `vitals.ts` for
    # the u32 wrap and the one-frame imprecision this inherits.
    ("av_skew_ms", "kh.stream.av_skew_ms", "ms", "gauge"),
    # ---- the daemon's own view, relayed BY the browser ---------------------
    # THE DAEMON NEEDS NO CODE CHANGE FOR ANY OF THIS, which is why the first
    # cut of this lane ships without a fleet rollout. `transport/mod.rs:521`
    # already spawns a 1 Hz task per session that sends KIND_PARAMS subtype 2
    # (`transport/egress.rs:102`), and the browser already parses it into
    # `serverStats`. It has been arriving at 1 Hz all along and being read only
    # by the ABR skip-credit and the Ctrl+N overlay. Relaying it here costs one
    # field read per sample and puts the SERVER's measurement of the same
    # stream beside the CLIENT's — which is the pair that settles "is it the
    # network or the box" without a repro.
    ("send_kbps", "kh.stream.send_kbps", "kbit/s", "gauge"),
    ("path_rtt_ms", "kh.transport.path_rtt_ms", "ms", "gauge"),
    ("skipped_frames", "kh.stream.skipped_frames", "1", "sum"),
    ("score_overall", "kh.stream.abr.score", "1", "gauge"),
)

#: WHAT IS NOT HERE, and why — so the next reader does not spend an afternoon
#: rediscovering an absence. Every one of these was checked, not assumed.
#:
#:  * WebTransport byte/packet counters, estimated send rate, smoothed/min RTT,
#:    datagram loss. `WebTransport.prototype.getStats` is UNDEFINED in the
#:    Chrome this gallery serves (measured 2026-09-01, Chrome 150 —
#:    `spa/src/three/streamClient/transportFacts.ts:19-27`). Not observable.
#:  * QUIC congestion window and lost-packet count on the daemon side. The
#:    wire field exists and is hardcoded 0: wtransport 0.7 exposes only
#:    `rtt()`, and cwnd/lost need an unenabled `quinn` feature
#:    (`transport/mod.rs:535-536`). A column here would be a column of zeroes.
#:  * x264 QP. The wire byte exists and is hardcoded 0xFF "unknown"
#:    (`transport/egress.rs:104-106`); x264's `pic_out` could supply it and
#:    never has.
#:  * ENCODE LATENCY and CAPTURE RATE. Both are genuinely measured on the box —
#:    a 120-frame window in `encode/worker.rs:434-449` prints p50/p95/max and
#:    fps — and both go to JOURNALD as text and nowhere else. They are the one
#:    real gap this lane leaves, and closing it needs a daemon change plus a
#:    fleet rollout, so it is named as follow-up rather than half-built. The
#:    columns are deliberately absent until something fills them: an always-
#:    NULL column reads as "measured, and it was nothing".
#:  * Audio packet LOSS as distinct from packet GAPS. `audio_gaps` counts
#:    discontinuities in the Opus `seq` the client already receives and
#:    currently discards; whether a gap was a loss or a server-side silence is
#:    not distinguishable from the client, and is not claimed to be.

#: Column -> (metric, unit, kind), for the readers that want it that way.
BY_COLUMN = {c: (m, u, k) for c, m, u, k in CATALOGUE}
COLUMNS = tuple(c for c, _, _, _ in CATALOGUE)

#: SCHEMA IS ASSEMBLED FROM `CATALOGUE`, not written out by hand — the only
#: generated DDL in the plane, and the reason is that a hand-written column
#: list and a catalogue WILL drift, and the failure is silent: a vital arrives,
#: has no column, and is dropped by a store that reports success. Building the
#: one from the other makes that unrepresentable. Everything structural — the
#: keys, the dimensions, every index — is literal below, so the part a reader
#: needs to reason about is still on the page.
SCHEMA = (
    """
CREATE TABLE IF NOT EXISTS vital (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  -- TWO CLOCKS, exactly as the log store keeps two, and for a sharper reason
  -- here: a vitals sample is USELESS without a trustworthy time, and the
  -- browser's clock is not ours. `ts_ms` is what the producer says the sample
  -- is of; `observed_ms` is when we took delivery. A batch that sat in a
  -- keepalive queue through a pagehide arrives minutes late, and only the pair
  -- can tell that from a stream that was actually bad minutes ago.
  ts_ms INTEGER NOT NULL, observed_ms INTEGER NOT NULL,
  -- THE THREE DIMENSIONS, and there are deliberately only three.
  -- `station` is the exhibit and becomes the OTLP `service.instance.id`, which
  -- is what makes each station its OWN OpenTelemetry entity in Instana
  -- (0311-...-infrastructure-correlation.md:236-248). `session` is one tab's
  -- visit. `source` is 'spa' or 'daemon'.
  station TEXT NOT NULL, session_id TEXT NOT NULL, source TEXT NOT NULL,
  build TEXT NOT NULL,
  day TEXT NOT NULL"""
    + "".join(f",\n  {c} REAL" for c in COLUMNS)
    + """);
-- The three reads this store exists to serve, in the order they are run:
-- a station's recent series, one session's series, and the forwarder's walk.
CREATE INDEX IF NOT EXISTS vital_station ON vital(station, ts_ms DESC);
CREATE INDEX IF NOT EXISTS vital_session ON vital(session_id, ts_ms DESC);
CREATE INDEX IF NOT EXISTS vital_ts ON vital(ts_ms DESC);
CREATE INDEX IF NOT EXISTS vital_day ON vital(day);

-- IDEMPOTENCY for a producer that ships from a SPOOL, which the browser's live
-- sink does not and a future daemon shipper will. Identical to `log_batch` and
-- for the identical reason: a sample has no natural key (two samples a
-- millisecond apart are two real observations, not a duplicate), so the BATCH
-- names itself and a second sight of that name stores nothing. Without it, the
-- documented re-ship path duplicates every row on every retry — and a
-- duplicated vitals sample is worse than a duplicated log line, because it
-- silently doubles the count a rate is computed from.
CREATE TABLE IF NOT EXISTS vital_batch (
  batch_id TEXT PRIMARY KEY, seen_ms INTEGER NOT NULL) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS vital_batch_seen ON vital_batch(seen_ms);
"""
)


def migrate(db) -> None:
    """Add any catalogue column a live store predates, and nothing else.

    This is the one migration a WIDE metric table will ever need repeatedly, so
    it is written once, generically, rather than as a new hand-rolled `ALTER`
    per vital. It reads the live table and adds what the catalogue has and the
    table does not — which is exactly the shape `CREATE TABLE IF NOT EXISTS`
    cannot express, and exactly the gap that crash-looped the serving plane on
    2026-09-01 when an index in SCHEMA named a column no ALTER had added yet.

    A column is only ever ADDED. Removing a vital from CATALOGUE leaves its
    column in place, holding the history that was already recorded under it —
    dropping it would silently delete measurements, which is not a thing a
    schema function should be able to do on a restart.
    """
    cur = db.cursor()
    have = {r[1] for r in cur.execute("PRAGMA table_info(vital)")}
    if not have:  # pragma: no cover - SCHEMA ran first, so this cannot be empty
        raise RuntimeError("vital table missing after SCHEMA")
    for col in COLUMNS:
        if col not in have:
            # No index is created here because no vital column is indexed: a
            # value column is never a WHERE clause in this store, only a
            # SELECT list. If one ever is, its index belongs on this line and
            # NOT in SCHEMA.
            cur.execute(f"ALTER TABLE vital ADD COLUMN {col} REAL")
