-- slow-agent.lua — the baseline rig's bench agent plus a guest-PC/ASID sampler.
--
-- Layering, deliberately: this file loads scripts/build-guests/irix-bench/
-- bench-agent.lua (IRIX_SLOW_BENCH), which in turn loads the PRODUCTION
-- irixagent.lua. So the input path and the emulated-time trace are shared with
-- the baseline rig rather than forked, and the only thing this file adds is a
-- sampler that answers "WHICH guest code is doing this".
--
-- WHY A LUA SAMPLER AND NOT AN INSTRUMENTED MAME. An instrumented build cost
-- this project a 2.35x slowdown and distorted every host-time number it
-- produced. The Lua periodic runs on the emulator's existing periodic callback:
-- no recompilation, no emitted code, and it runs against the SHIPPED binary.
-- It is host-time-biased sampling, which is exactly the right weighting for
-- "where is the host time going", and it is far too coarse to attribute single
-- instructions — it is used here only to name the ASID and the text region.
--
--   IRIX_SLOW_BENCH   path to bench-agent.lua                       (required)
--   IRIX_SLOW_PCLOG   file to append "<emu_seconds> <pc> <entryhi>" to
--   IRIX_SLOW_PCGATE  file whose presence enables sampling (touch/rm to gate)
--
-- The gate file exists so that sampling is confined to the census sub-windows
-- and never runs during a speed window: a sampler inside a speed window makes
-- the speed a measurement of the sampler.

local bench = assert(os.getenv("IRIX_SLOW_BENCH"), "IRIX_SLOW_BENCH unset")
dofile(bench)

local pclog = os.getenv("IRIX_SLOW_PCLOG")
local pcgate = os.getenv("IRIX_SLOW_PCGATE")

if pclog then
  local f = io.open(pclog, "w")
  local cpu = nil
  local st = nil
  local names = {}
  local gate_open = false
  local next_gate_check = 0

  -- One-shot discovery: MAME's state-register NAMES for this CPU are printed
  -- once so the analyser never has to guess them. The MIPS3 core exposes the
  -- COP0 file under names like "EntryHi"; if that ever changes, the header line
  -- says so in the log instead of the sampler silently writing zeros.
  local function bind()
    local ok = pcall(function()
      cpu = manager.machine.devices[":maincpu"]
      st = cpu.state
      for k in pairs(st) do names[#names + 1] = k end
    end)
    if not ok or not st then return false end
    table.sort(names)
    f:write("# state: " .. table.concat(names, ",") .. "\n")
    f:flush()
    return true
  end

  emu.register_periodic(function()
    if not st and not bind() then return end
    local now = manager.machine.time.seconds
    if pcgate and now >= next_gate_check then
      next_gate_check = now + 1
      local g = io.open(pcgate, "r")
      gate_open = g ~= nil
      if g then g:close() end
    end
    if pcgate and not gate_open then return end
    local t = manager.machine.time
    local pc, hi = -1, -1
    pcall(function()
      pc = st["PC"].value
      if st["EntryHi"] then hi = st["EntryHi"].value end
    end)
    f:write(string.format("%.4f %x %x\n",
      t.seconds + t.attoseconds / 1e18, pc, hi))
  end)
end
