-- bench-agent.lua — the PRODUCTION irixagent.lua plus an emulated-time trace.
--
-- Why a wrapper and not a fork: the whole point of the baseline is that the
-- guest is driven by exactly the agent the exhibit ships, so the input path is
-- not a variable. This file loads that agent verbatim (IRIX_BENCH_AGENT) and
-- adds ONE thing: a periodic line pairing host wall-clock with emulated time.
--
-- That pairing is what makes WITHIN-RUN windowing possible. Differencing two
-- separate runs is invalid on this exhibit (IRIX boot diverges from ~t=120 s),
-- so every speed figure has to come from two marks inside ONE run.
--
--   IRIX_BENCH_AGENT  path to the production irixagent.lua   (required)
--   IRIX_BENCH_TRACE  path to write "<host_epoch> <emu_seconds>" lines
--   IRIX_BENCH_PERIOD trace interval in emulated seconds (default 0.5)

local agent = assert(os.getenv("IRIX_BENCH_AGENT"), "IRIX_BENCH_AGENT unset")
dofile(agent)

local trace = os.getenv("IRIX_BENCH_TRACE")
if trace then
  local period = tonumber(os.getenv("IRIX_BENCH_PERIOD") or "") or 0.5
  local f = io.open(trace, "w")
  -- os.time() is whole seconds, so anchor once and carry sub-second precision
  -- with the emulator's own monotonic host tick source from there on.
  local tps = emu.osd_ticks_per_second()
  local t0_ticks = emu.osd_ticks()
  local t0_wall = os.time()
  local next_at = 0
  emu.register_periodic(function()
    local et = manager.machine.time.seconds
    if et < next_at then return end
    next_at = et + period
    local wall = t0_wall + (emu.osd_ticks() - t0_ticks) / tps
    f:write(string.format("%.3f %.3f\n", wall, et))
    f:flush()
  end)
end
