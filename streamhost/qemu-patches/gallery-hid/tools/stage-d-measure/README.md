# Solaris Stage-D spike observer

This standalone, spike-grade tool attaches a second QEMU D-Bus display
listener, timestamps display callbacks with `CLOCK_MONOTONIC`, and copies two
32x32 cursor ROIs in the callback handler. It drives one persistent TCP input
connection, calibrates cursor/background templates at `(1200,250)` and
`(1700,800)`, performs 50 warmups, then writes one JSON object per attempt.

It is intentionally not the production T2 `lli-bench` harness. For native-sink
remeasurement, point it at streamhost's loopback-only `SH_INPUT_BENCH_ADDR`.
That ingress keeps the harness's existing `M x y` wire and T0 timestamp while
feeding the same process-wide router and selected sink as WebTransport. Do not
point the primary measurement at the device socket or the old Python bridge.
The tool still does one live-boot sample rather than three restored 1,000-trial
runs. QMP screendumps are periodic audit evidence only.

Build on the lab box:

    nice -n 10 cargo build --release

Example:

    target/release/stage-d-measure \
      /data/vms/streamhost/stations/soltest-ghid/qmp.sock \
      127.0.0.1:57822 ghid-native loaded 320 \
      /data/vms/streamhost/stations/soltest-ghid/stage-d/native-loaded.jsonl \
      /data/vms/streamhost/stations/soltest-ghid/stage-d/audits

Summarize four JSONL cells:

    ./summarize.py warpd-idle.jsonl ghid-idle.jsonl \
      warpd-loaded.jsonl ghid-loaded.jsonl \
      --json summary.json --csv summary.csv

Percentiles use the explicit nearest-rank definition. Timeouts and wrong
targets remain failures and never receive invented latency values.
