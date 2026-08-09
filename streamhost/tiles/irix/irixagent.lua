-- IRIX MAME input agent (issue #20) — the Lua ROLLBACK arm of the compiled-in
-- mamectl module (issue #45, scripts/build-guests/patches/mame-ctlsock.patch).
-- File-driven injection straight onto the emulated ioports, bypassing SDL
-- entirely (a WM-less full-screen Xvfb never mouse-captures, so SDL drops
-- everything): buttons and keys set ioport fields, and pointer MOTION is
-- driven the same way — MOVE/MOVEP dead reckoning, MOVEA closed loop over
-- the VC2 cursor registers; nothing arrives via XTEST. streamhost's mamecmd
-- backend appends commands to SH_X11_CMD_FILE, which this agent consumes.
-- MUTUALLY EXCLUSIVE with mamectl: the launcher runs this agent only while
-- MAME_CTL_SOCK is unset — two injectors would fight over the pacing budgets
-- and accumulators below.
-- Command channel: write one command per line to CMD; agent consumes+truncates.
-- Commands: POST <text> | CODE <coded> | CLICK1 | DCLICK1 | DOWN1 | UP1 |
--           CLICK2 | CLICK3 | DOWN2 | UP2 | DOWN3 | UP3 |
--           MOVE <dx> <dy> | MOVEP <dx> <dy> | MOVEA <x> <y> | DUMP |
--           KEY <0|1> <port> <field> | KEYDUMP | RESET | EXIT
-- CMD path comes from $IRIX_CMD (set by x11-runtime.sh to SH_X11_CMD_FILE).

local CMD = os.getenv("IRIX_CMD") or "/tmp/irix_cmd"
local LOG = (os.getenv("IRIX_CMD") or "/tmp/irix_cmd") .. ".agent.log"

local function log(s)
  local f = io.open(LOG, "a")
  if f then f:write(os.date("%H:%M:%S ") .. tostring(s) .. "\n"); f:close() end
end

local nat = nil
local mport = nil
-- Pointer AXES, driven the same way as the buttons: straight into the emulated
-- PS/2 mouse's ioport, never through SDL. MAME-SDL only delivers host mouse
-- input when its window is mouse-CAPTURED, which needs an SDL_WINDOWEVENT_ENTER
-- the pointer can never generate on a WM-less Xvfb the MAME window exactly
-- fills -- so capture intermittently fails to engage and NOTHING reaches the
-- guest. That takes the keyboard with it, because 4Dwm is pointer-focus: with
-- no pointer there is no focused window to type into. Going through the ioport
-- makes guest input independent of SDL capture entirely.
--
-- IPT_MOUSE_X/Y are RELATIVE: the device differentiates successive field
-- values, so we keep our own accumulators and hand it a moving absolute number.
--
-- The accumulators START AT ZERO, and that is not cosmetic. `hle_ps2_mouse`
-- differentiates against `m_mouse_x`, which it seeds from these very ioports
-- (`update()`) at device reset and after every host command — and the fields'
-- MAME default is 0. The guest sends its last mouse command during boot, long
-- before a visitor's first mouse move, so `m_mouse_x` is 0 and frozen from then
-- on. Seeding our accumulator at 32768 therefore made the FIRST pointer motion
-- of every session present a delta of ~32768 counts to a device whose wire
-- field is 9 bits: measured on a clean boot as
-- `OVERFLOW dx=-32668 dy=32708` on the very first `MOVEP`. See the wire-field
-- discussion under MOVEP below for why that is not survivable.
local xport, yport = nil, nil
local mx, my = 0, 0
-- MOVEA's SENSOR: emu.item handles onto the Newport VC2's hardware-cursor
-- registers (m_cursor_x/m_cursor_y, upstream save-state items since forever —
-- newport.cpp vc2_device::device_start). Reading them is what turns pointer
-- motion from dead reckoning into a closed loop: see the MOVEA block below.
-- Filled by setup(); movea_ok is the single "can we sense the cursor" flag.
local vc2x, vc2y, vc2en = nil, nil, nil
local movea_ok = false
-- OBSERVABILITY. `MOVEP`/`MOVEA` and `KEY` arrive at pointer/typing rate and
-- must never be logged one line per event: this is a CPU-bound exhibit and
-- every log line
-- is an io.open in the hot path (the same cost that was measured at ~13
-- percentage points of a core and removed from poll()). They are COUNTED
-- instead, and the counts go out on one periodic line — which also doubles as
-- the agent's HEARTBEAT.
--
-- That heartbeat is the point. The first time this exhibit lost all input, the
-- investigation concluded the agent had died because its log had gone quiet —
-- but the log was quiet by construction, since pointer motion and keystrokes
-- were the only traffic and neither was ever logged. A silent log has to mean
-- something now: a `stats` line every STAT_PERIOD seconds says the periodic
-- callback is still running, and its counters say whether commands are arriving
-- and whether they are being drained onto the ioports.
local STAT_PERIOD = tonumber(os.getenv("IRIX_STAT_PERIOD") or "") or 15
local st_movep, st_move, st_movea, st_key = 0, 0, 0, 0 -- parsed since last line
local st_qx, st_qy = 0, 0                 -- counts queued into mq (MOVEP+MOVEA)
local st_ax, st_ay = 0, 0                 -- counts APPLIED to the ioports
local st_last = 0
local queue = {}      -- sequential button actions {name=, val=, ticks=}
local cur = nil
local esc_ticks = 0   -- when >0, post {ESC} periodically (catch PROM prompt)
local probe = 0       -- button read-back probe countdown

local function setup()
  local m = manager.machine
  nat = m.natkeyboard
  if nat then nat.in_use = true end
  mport = m.ioport.ports[":ioc2:aux:hle_ps2_mouse:mouse_buttons"]
  xport = m.ioport.ports[":ioc2:aux:hle_ps2_mouse:mouse_x_axis"]
  yport = m.ioport.ports[":ioc2:aux:hle_ps2_mouse:mouse_y_axis"]
  -- The VC2 cursor items. `dev.items` walks EVERY save entry on each access
  -- (luaengine's own FIXME calls it slow), so the walk happens exactly once
  -- here; the emu.item handles it yields cache a raw base pointer, which makes
  -- the per-tick position read a plain memory load. setup() runs on the first
  -- periodic tick — after save registration has closed and the entry list has
  -- been sorted — so the indices resolved here are final for the session.
  local vc2 = m.devices[":gio64_gfx:xl24:vc2"]
  if not vc2 then
    -- The literal tag encodes how indy_4610 wires the xl24 GIO64 card; if a
    -- MAME bump reshuffles the slot chain, the one VC2 on this machine still
    -- ends in ":vc2".
    for tag, dev in pairs(m.devices) do
      if tostring(tag):sub(-4) == ":vc2" then vc2 = dev break end
    end
  end
  if vc2 then
    local items = vc2.items
    local ix, iy = items["0/m_cursor_x"], items["0/m_cursor_y"]
    local ie = items["0/m_enable_cursor"]
    if ix and iy then
      vc2x, vc2y = emu.item(ix), emu.item(iy)
      vc2en = ie and emu.item(ie) or nil
      -- A handle that cannot produce a value is no handle at all.
      if vc2x:read(0) == nil then vc2x, vc2y, vc2en = nil, nil, nil end
    end
  end
  movea_ok = vc2x ~= nil
  log("setup nat=" .. tostring(nat ~= nil) ..
      " canpost=" .. tostring(nat and nat.can_post) ..
      " mport=" .. tostring(mport ~= nil) ..
      " axes=" .. tostring(xport ~= nil and yport ~= nil) ..
      " movea=" .. tostring(movea_ok))
end

local function set_button(name, val)
  if not mport then return end
  local fld = mport.fields[name]
  if fld then fld:set_value(val) end
end

-- Relative move by (dx, dy) emulated mouse counts. Wraps inside the field's
-- 0..65535 range; the device only ever looks at the difference.
local function move_rel(dx, dy)
  if not xport or not yport then return end
  st_ax = st_ax + math.abs(dx)
  st_ay = st_ay + math.abs(dy)
  mx = (mx + dx) % 65536
  my = (my + dy) % 65536
  local fx = xport.fields["Mouse X"]
  local fy = yport.fields["Mouse Y"]
  if fx then fx:set_value(mx) end
  if fy then fy:set_value(my) end
end

-- PACED relative move. hle_ps2_mouse::sample() runs at the guest-programmed
-- sample rate (100 Hz by default), reads these same fields, and transmits the
-- difference as ONE 8-BIT value -- so any delta outside -256..255 between two
-- samples is truncated on the wire and the cursor lands somewhere else. Sending
-- several small MOVE lines does not help: they all land in one tick and the
-- device only ever sees the final field value. So MOVEP accumulates instead, and
-- the periodic tick bleeds the pending delta out at most MOVE_STEP counts per
-- axis per tick. A move within one step is applied in the SAME tick it was
-- parsed, so ordering against a following button command is unchanged; only an
-- oversized jump (the streamhost sink's one-time homing slam) spans ticks.
--
-- The budget is per EMULATED-TIME WINDOW, not per tick: this callback fires far
-- more often than the mouse samples, so a per-tick budget merges several steps
-- into one oversized device delta and the cursor lands somewhere else entirely
-- (measured: a -8192 homing slam plus a +200 move produced +148 px instead of a
-- corner slam). Merging is harmless as long as the merged total stays inside the
-- 8-bit wire field, so an ordinary small move is still applied on the very tick
-- it arrives — with no added latency — and only a jump larger than the window
-- budget is spread across windows. 120 counts per 40 ms leaves room for two
-- windows to merge into one device sample and still stay inside the 8-bit field.
--
-- Pending moves are a QUEUE, not one accumulator. The guest CLAMPS the cursor at
-- the screen edge, so the counts an over-large homing slam spends past the corner
-- are meant to be thrown away — but in a single accumulator the next real move is
-- summed into that same overshoot and CANCELS part of it instead of moving the
-- cursor. Measured: a walk of 4-px steps started while a -8192 home was still
-- draining landed 13 px short. Draining head-first keeps each move whole.
local MOVE_STEP = 120
local MOVE_WINDOW = 0.04
local mq = {} -- FIFO of {x=,y=} relative moves still to apply
local win_t0, win_x, win_y = -1, 0, 0

local function emu_now()
  local t = manager.machine.time
  local ok, v = pcall(function() return t:as_double() end)
  if ok and v then return v end
  return t.seconds + (t.attoseconds or 0) / 1e18
end

local function move_paced(dx, dy)
  st_qx = st_qx + math.abs(dx)
  st_qy = st_qy + math.abs(dy)
  mq[#mq + 1] = { x = dx, y = dy }
end

local function clamp_budget(pend, used)
  local room = MOVE_STEP - used
  if room <= 0 then return 0 end
  return math.max(-room, math.min(room, pend))
end

-- Spend this window's budget on the head of the queue, and keep going while
-- budget is left: an ordinary small move still lands on the tick it arrives.
local function drain_move()
  if #mq == 0 then return end
  local now = emu_now()
  if win_t0 < 0 or (now - win_t0) >= MOVE_WINDOW then
    win_t0, win_x, win_y = now, 0, 0
  end
  while #mq > 0 do
    local h = mq[1]
    local sx = clamp_budget(h.x, win_x)
    local sy = clamp_budget(h.y, win_y)
    if sx == 0 and sy == 0 then return end
    win_x = win_x + math.abs(sx)
    win_y = win_y + math.abs(sy)
    h.x = h.x - sx
    h.y = h.y - sy
    move_rel(sx, sy)
    if h.x == 0 and h.y == 0 then table.remove(mq, 1) end
  end
end

-- KEYBOARD: the emulated key MATRIX, never natkeyboard.
--
-- `natkeyboard:post` is unusable on this machine and that is not a tuning
-- problem: indy_4610's keyboard is a PC "Microsoft Natural" behind an SGI
-- keymap, so every SHIFTED character is silently dropped — uppercase arrives
-- lowercase and `_ | ~ " < > ? :` never arrive at all. POST therefore looks like
-- it works right up until someone types a real path or a shell redirect. So the
-- browser's keys drive `:ioc2:kbd:ms_naturl`'s ioport fields directly, one field
-- per physical key, exactly as the pointer drives the PS/2 axes: shift is not
-- synthesised here at all, it is simply another field the browser already tells
-- us to press (the SPA sends a real Shift make/break around a shifted char).
-- That also gives Ctrl-C for free. Proven first in
-- scripts/build-guests/irix/irix-apps/keys.py, which this ports.
--
-- TIMING lives in the guest, because a burst of command lines is consumed inside
-- ONE periodic tick: setting a field down and up in the same tick is invisible to
-- the emulated keyboard, which polls the matrix on its own clock. So key events
-- are a FIFO drained at most one per tick, and never faster than KEY_HOLD (after
-- a press) / KEY_GAP (after a release) of EMULATED time — the same per-emulated-
-- time-window rule the pointer pacing needs, since this callback fires far more
-- often than the devices sample. A queue also means nothing is ever dropped when
-- a visitor types faster than the guest scans.
local KPORT = ":ioc2:kbd:ms_naturl:"
local KEY_HOLD = tonumber(os.getenv("IRIX_KEY_HOLD") or "") or 0.10
local KEY_GAP = tonumber(os.getenv("IRIX_KEY_GAP") or "") or 0.05
local kq = {}    -- FIFO of {p=<full port tag>, n=<field>, v=0|1}
local kwant = {} -- field -> last value ENQUEUED (not yet applied)
local k_next = -1

-- Coalesce against the queued state, not the applied one: browser auto-repeat
-- resends keydown with no intervening keyup, and re-pressing a field that is
-- already down does nothing except cost the queue KEY_HOLD. IRIX does its own
-- auto-repeat from the held matrix bit, so dropping those is what makes repeat
-- behave like real hardware.
local function key_enqueue(port, name, val)
  if (kwant[name] or 0) == val then return end
  kwant[name] = val
  kq[#kq + 1] = { p = KPORT .. port, n = name, v = val }
end

local function drain_keys()
  if #kq == 0 then return end
  local now = emu_now()
  if k_next >= 0 and now < k_next then return end
  local e = table.remove(kq, 1)
  local pt = manager.machine.ioport.ports[e.p]
  if pt then
    local f = pt.fields[e.n]
    if f then f:set_value(e.v) end
  end
  k_next = now + (e.v == 1 and KEY_HOLD or KEY_GAP)
end

local function enqueue_click(name, downticks, upticks)
  queue[#queue + 1] = { name = name, val = 1, ticks = downticks }
  queue[#queue + 1] = { name = name, val = 0, ticks = upticks }
end

local function process_queue()
  if not cur and #queue > 0 then
    cur = table.remove(queue, 1)
    set_button(cur.name, cur.val)
  end
  if cur then
    cur.ticks = cur.ticks - 1
    if cur.ticks <= 0 then cur = nil end
  end
end

-- CLOSED-LOOP ABSOLUTE POSITIONING: MOVEA <x> <y>, in emulated framebuffer
-- pixels (0..1287 x 0..1023). MOVEP is dead reckoning — streamhost turns the
-- browser's absolute position into deltas and trusts the guest to apply every
-- count 1:1 — so any count that dies between here and Xsgi (an edge clamp the
-- model missed, a modal grab eating motion, acceleration briefly re-enabled)
-- becomes a PERMANENT offset. Accumulated loss is exactly what pinned the
-- guest cursor to a screen edge while a phone visitor's finger was mid-screen.
-- MOVEA closes the loop instead: the VC2 items read in setup() say where the
-- cursor ACTUALLY is, so each tick computes err = target - actual and bleeds
-- the correction out through the same pacing MOVEP uses. A lost count is
-- simply re-measured and re-sent on the next pass; drift is structurally
-- impossible. MOVEP/MOVE keep their exact old behavior — ops scripts use
-- them, and SH_MAMECMD_ABS=0 rolls the whole tile back to dead reckoning.
--
-- actual = vc2_register + CAL. The VC2 registers hold the BOTTOM-RIGHT corner
-- of the 32x32 cursor sprite (newport.cpp is_cursor_active: x in [reg-31,
-- reg]), and Xsgi programs them as position + 31 - hotspot — so the standard
-- IRIX arrow (hotspot 0,0) puts the pointer at reg - 31 on both axes.
-- Non-arrow glyphs (I-beam, resize, watch) have nonzero hotspots and show as
-- a transient residual of up to ~16 px in the stats line while such a cursor
-- is up; the constants are env-tunable so an empirical clone calibration can
-- land elsewhere without editing this file.
-- Floored, because these exist precisely to be field-tuned: a fractional env
-- value would put floats into the error terms, and the stats line's res=%d
-- then throws inside the periodic callback every stats period (Lua 5.4 "%d"
-- refuses numbers with no integer representation) — total observability loss
-- from the tuning knob itself. Verified against the sim harness.
local CAL_X = math.floor(tonumber(os.getenv("IRIX_CURS_CAL_X") or "") or -31)
local CAL_Y = math.floor(tonumber(os.getenv("IRIX_CURS_CAL_Y") or "") or -31)
-- The visarea the VC2 coordinates live in, and the surface streamhost already
-- clamps its targets to. Re-clamped here because ops scripts write this file
-- too, and a target outside the surface could never converge.
local SURF_W, SURF_H = 1288, 1024
-- Give-up cap, counted in INJECTION WINDOWS, not periodic ticks: ticks fire
-- far faster than the wire drains, so a raw-tick cap would expire mid-flight
-- on a legitimate corner-to-corner jump (~14 windows at MOVE_STEP each). 40
-- windows is ~3x that worst case, and it is what turns a cursor pinned by a
-- modal grab — or hidden outright — into a counted give-up after 1.6 s of
-- emulated time instead of a wedged pointer with buttons parked behind it.
local MOVEA_TRIES = tonumber(os.getenv("IRIX_MOVEA_TRIES") or "") or 40

local ta = nil            -- in-flight target {x=, y=, tries=, t_next=}
local aq = {}             -- actions deferred behind ta, in arrival order
local flx, fly = nil, nil -- open-loop fallback: last commanded target
local fb_logged = false   -- the fallback announcement goes out ONCE
local st_giveups = 0      -- CUMULATIVE, unlike the per-period counters:
                          -- give-ups are rare, and whichever stats line
                          -- someone eventually reads must still show them
local res_x, res_y = 0, 0 -- residual at the last target completion

-- ORDERING. With MOVEP, a move within budget lands on the tick it is parsed,
-- so a button verb right behind it fires with the cursor already in place —
-- only the homing slam ever spans ticks, and nothing clicks during homing.
-- MOVEA gives that up: every sizeable jump now converges across windows, and
-- the common mobile TAP is precisely a sizeable jump with DOWN1/UP1 right
-- behind it — applied at parse time they would click wherever the cursor
-- happened to be mid-flight. So while a target is converging, button verbs
-- are deferred into aq and released, still in arrival order, when the target
-- completes (converged or gave up). A newer MOVEA coalesces into the pending
-- target — UNLESS a deferred button sits between them, because press-at-A
-- then move-to-B is a drag and coalescing across the press would reorder
-- what the guest does. streamhost restates the target before every button
-- edge on purpose, so a click always rides behind a fresh target.
local function movea_target(x, y)
  x = math.max(0, math.min(SURF_W - 1, x))
  y = math.max(0, math.min(SURF_H - 1, y))
  if not movea_ok then
    -- Degraded mode (VC2 items unavailable): interpret each target as a
    -- DELTA from the previous one — the same open-loop dead reckoning MOVEP
    -- carries — and say so once, so nobody debugs a "converging" loop that
    -- cannot read the cursor.
    if not fb_logged then
      fb_logged = true
      log("MOVEA unsupported (vc2 cursor items unavailable); " ..
          "interpreting MOVEA as open-loop relative from the last target")
    end
    if not flx then
      -- No origin to difference from yet: home into the top-left clamp
      -- first, like the streamhost sink's one-time slam, then move as if
      -- from (0,0). TWO queue entries on purpose — the overshoot must be
      -- spent against the guest's edge clamp before the real move starts
      -- (see the mq comment above). The slam is a whole number of windows,
      -- unlike the sink's -2048: a partial last window would leave the drain
      -- loop room to start the real move in the SAME window, and the device
      -- samples the merged sum — the slam's tail then cancels counts of the
      -- real move instead of dying against the clamp (measured in the sim
      -- harness: 2048 % 120 = 8 px short, permanently, being open loop).
      move_paced(-(18 * MOVE_STEP), -(18 * MOVE_STEP))
      move_paced(x, y)
    else
      move_paced(x - flx, y - fly)
    end
    flx, fly = x, y
    return
  end
  if ta == nil then
    ta = { x = x, y = y, tries = MOVEA_TRIES, t_next = -1 }
  elseif #aq == 0 then
    -- Nothing deferred behind the pending target: the newer target replaces
    -- it, tries and all. A finger in motion streams targets faster than they
    -- converge, and it must never ride the give-up cap down to zero mid-drag.
    ta.x, ta.y, ta.tries, ta.t_next = x, y, MOVEA_TRIES, -1
  else
    local tail = aq[#aq]
    if tail.k == "t" then
      tail.x, tail.y = x, y
    else
      aq[#aq + 1] = { k = "t", x = x, y = y }
    end
  end
end

-- Complete the in-flight target and release what queued up behind it, up to
-- the next target (which then takes over). The residual feeds the stats
-- line: at convergence it is inside the deadband, after a give-up it is the
-- error the guest refused to close — and a steady nonzero residual across
-- stats lines is the calibration signal IRIX_CURS_CAL_X/Y exists to tune out.
local function movea_done(ex, ey, gaveup)
  local tx, ty = ta.x, ta.y
  res_x, res_y = ex, ey
  if gaveup then st_giveups = st_giveups + 1 end
  ta = nil
  while #aq > 0 do
    local a = table.remove(aq, 1)
    if a.k == "b" then
      set_button(a.n, a.v)
    elseif a.k == "c" then
      enqueue_click(a.n, a.d, a.u)
    elseif not movea_ok then
      -- The closed loop died with targets still queued: apply them open-loop
      -- so neither the motion nor the buttons behind it are ever dropped.
      move_paced(a.x - flx, a.y - fly)
      flx, fly = a.x, a.y
    elseif gaveup and math.abs(a.x - tx) <= 1 and math.abs(a.y - ty) <= 1 then
      -- The target that just GAVE UP, restated. streamhost restates the
      -- target before every button edge, so a pinned cursor would otherwise
      -- park each click behind a fresh full cap — N restatements, N x 1.6 s.
      -- No new information can exist in the same instant the original
      -- verdict was reached, so the restatement inherits it and the buttons
      -- behind it release now. A LATER fresh target starts clean, which is
      -- what lets the loop recover the moment a grab lifts.
      st_giveups = st_giveups + 1
    else
      ta = { x = a.x, y = a.y, tries = MOVEA_TRIES, t_next = -1 }
      break
    end
  end
end

-- Every button verb routes through these so a click can wait for the cursor.
-- With no MOVEA in flight they are the old behavior to the byte: edges apply
-- at parse time, clicks enter the ticks queue at parse time.
local function btn_edge(name, val)
  if ta then
    aq[#aq + 1] = { k = "b", n = name, v = val }
  else
    set_button(name, val)
  end
end

local function btn_click(name, downticks, upticks)
  if ta then
    aq[#aq + 1] = { k = "c", n = name, d = downticks, u = upticks }
  else
    enqueue_click(name, downticks, upticks)
  end
end

-- The convergence tick: ONE bounded step per MOVE_WINDOW, and only when mq
-- is idle. The loop must never inject while its previous correction is still
-- in flight (queued in mq, or on the ioport but not yet sampled by the
-- 100 Hz device), or the same error is counted twice and the cursor
-- overshoots and rings around the target. A window is four device samples,
-- so by the next injection the previous step is IN the VC2 registers and the
-- fresh err accounts for it. Clamping each step to MOVE_STEP shares the wire
-- budget with MOVEP — and it is why a superseded target needs no mq flush:
-- at most one bounded step is ever queued, and the next measurement absorbs
-- whatever it did.
local function movea_tick()
  if ta == nil then return end
  if not movea_ok then
    -- Unreachable by construction (ta is only ever set while movea_ok), but
    -- if it ever happens the buttons parked behind ta must still be
    -- released — a wedge here is total pointer loss. Seed the open-loop
    -- origin first: movea_done differences queued targets against flx/fly,
    -- and this path is the one place they could still be nil.
    flx, fly = flx or ta.x, fly or ta.y
    movea_done(0, 0, true)
    return
  end
  local rx, ry = vc2x:read(0), vc2y:read(0)
  if rx == nil or ry == nil then
    -- The cached handle went bad mid-session — should be impossible while
    -- the machine lives, but a wedged pointer must never be how we find out.
    -- Drop to open-loop mode for good, seeded from the last target (the best
    -- position estimate left), and count the target as given up.
    movea_ok = false
    fb_logged = true
    log("MOVEA: vc2 item read failed; falling back to open-loop relative")
    flx, fly = ta.x, ta.y
    movea_done(0, 0, true)
    return
  end
  local ex = ta.x - (rx + CAL_X)
  local ey = ta.y - (ry + CAL_Y)
  -- Deadband: the wire is integer counts, so within one pixel IS arrived —
  -- chasing the last pixel would ring against the guest forever.
  if math.abs(ex) <= 1 and math.abs(ey) <= 1 then
    movea_done(ex, ey, false)
    return
  end
  local now = emu_now()
  if ta.t_next >= 0 and now < ta.t_next then return end
  ta.t_next = now + MOVE_WINDOW
  ta.tries = ta.tries - 1
  if ta.tries < 0 then
    movea_done(ex, ey, true)
    return
  end
  -- While the cursor is hidden the registers do not track the pointer, so a
  -- correction would only wind counts into a parked value. Spend the window
  -- doing nothing; the try counter keeps running, so a cursor that never
  -- comes back becomes a give-up, not a wedge.
  if vc2en and vc2en:read(0) == 0 then return end
  if #mq > 0 then return end
  move_paced(math.max(-MOVE_STEP, math.min(MOVE_STEP, ex)),
             math.max(-MOVE_STEP, math.min(MOVE_STEP, ey)))
end

local function exec_line(line)
  local c, rest = line:match("^(%S+)%s?(.*)$")
  if not c then return end
  if c == "POST" then
    if nat then nat:post(rest) end
  elseif c == "CODE" then
    if nat then nat:post_coded(rest) end
  elseif c == "CLICK1" then btn_click("Left Button", 10, 6)
  elseif c == "DCLICK1" then
    btn_click("Left Button", 10, 8)
    btn_click("Left Button", 10, 6)
  elseif c == "DOWN1" then btn_edge("Left Button", 1)
  elseif c == "UP1" then btn_edge("Left Button", 0)
  -- Right and middle get REAL press/release edges, like the left button.
  -- CLICK2/CLICK3 (a synthetic press-then-release) stay for the ops scripts
  -- that use them, but they cannot drive 4Dwm: its root and Toolchest menus are
  -- SPRING-LOADED — the menu stays posted only while the button is held, and
  -- the selection happens on release over an item. A synthetic click opens the
  -- menu and closes it again a few frames later, which is exactly what a
  -- visitor saw when they right-clicked the desktop.
  elseif c == "DOWN2" then btn_edge("Right Button", 1)
  elseif c == "UP2" then btn_edge("Right Button", 0)
  elseif c == "DOWN3" then btn_edge("Middle Button", 1)
  elseif c == "UP3" then btn_edge("Middle Button", 0)
  elseif c == "CLICK2" then btn_click("Right Button", 10, 6)
  elseif c == "CLICK3" then btn_click("Middle Button", 10, 6)
  elseif c == "MOVE" then
    local dx, dy = rest:match("^(-?%d+)%s+(-?%d+)")
    if dx then
      st_move = st_move + 1
      move_rel(tonumber(dx), tonumber(dy))
    end
  elseif c == "MOVEP" then
    local dx, dy = rest:match("^(-?%d+)%s+(-?%d+)")
    if dx then
      st_movep = st_movep + 1
      move_paced(tonumber(dx), tonumber(dy))
    end
  elseif c == "MOVEA" then
    local x, y = rest:match("^(-?%d+)%s+(-?%d+)")
    if x then
      st_movea = st_movea + 1
      movea_target(tonumber(x), tonumber(y))
    end
  elseif c == "KEY" then
    -- KEY <0|1> <port> <field name>. The field name is the rest of the line
    -- because MAME's names contain spaces ("Left Shift", "Page Down").
    local v, p, n = rest:match("^([01])%s+(%S+)%s+(.+)$")
    if v then
      st_key = st_key + 1
      key_enqueue(p, n, tonumber(v))
    end
  elseif c == "KEYDUMP" then
    -- Every keyboard port/field MAME exposes, so the host-side scancode table
    -- can be built from the machine rather than guessed.
    for tag, pt in pairs(manager.machine.ioport.ports) do
      if tostring(tag):find(":kbd:") then
        for fname, _ in pairs(pt.fields) do
          log("KEYDUMP " .. tostring(tag) .. " | " .. tostring(fname))
        end
      end
    end
  elseif c == "PROBE" then probe = 14
  elseif c == "ESCON" then esc_ticks = 3600
  elseif c == "ESCOFF" then esc_ticks = 0
  elseif c == "EXIT" then manager.machine:exit()
  elseif c == "RESET" then manager.machine:hard_reset()
  elseif c == "DUMP" then
    log("DUMP canpost=" .. tostring(nat and nat.can_post) ..
        " isposting=" .. tostring(nat and nat.is_posting) ..
        " qlen=" .. tostring(#queue))
  end
  -- Motion is the ONE verb family that arrives at pointer rate (~30/s while a
  -- visitor is moving the mouse). Logging it per event would reopen this file
  -- dozens of times a second forever — the exact per-tick io.open cost that
  -- was measured at ~13 percentage points of a core and removed from poll()
  -- above. KEY is excluded for the same reason plus one more: it would write
  -- every character a visitor types into a file on disk. All are COUNTED
  -- instead and reported by stat_tick(), so a quiet log now means a dead
  -- agent and nothing else.
  if c ~= "MOVE" and c ~= "MOVEP" and c ~= "MOVEA" and c ~= "KEY" then
    log("exec: " .. line)
  end
end

-- Command-file reader. This runs on EVERY periodic tick, dozens of times a
-- second, forever — so it must not open the file each time. It used to
-- io.open/read/close (plus a second open to truncate) per tick, which showed up
-- as ~10% of the process's children in a profile at a completely idle desktop.
-- Instead hold one read handle open and track our own position: seek("end") is
-- a bare lseek, and streamhost only ever APPENDS to this file
-- (x11_input.rs opens it with .append(true)), so reading forward is correct.
-- Truncation is only needed to stop the file growing without bound, so do it
-- once per megabyte rather than once per command.
local fh = nil
local pos = 0

local function poll()
  if not fh then
    fh = io.open(CMD, "r")
    if not fh then return end
    pos = 0
  end
  local size = fh:seek("end")
  if not size then return end
  -- Someone truncated the file under us (a relaunch does `: >$CMD`): restart.
  if size < pos then pos = 0 end
  if size == pos then return end
  fh:seek("set", pos)
  local content = fh:read("*a")
  pos = size
  if content and #content > 0 then
    for line in content:gmatch("[^\n]+") do exec_line(line) end
  end
  if pos > 1048576 then
    fh:close()
    fh = nil
    local w = io.open(CMD, "w"); if w then w:close() end
  end
end

-- Optional screen-geometry trace (set IRIX_GEO_LOG). Off by default; when on it
-- writes ONE line per wall second. It exists because cold boots intermittently
-- wedge on a permanently black framebuffer, and the leading hypothesis is that
-- MAME's VC2 re-derives its readout bounds only on a write to register 0x00, so
-- a timing-table update that is never followed by one leaves set_size() with a
-- degenerate rectangle. A healthy boot goes 1280x1024 -> 1288x1024; a hung boot
-- showing a degenerate size confirms it. Arming this on the live tile makes
-- every production reset a sample instead of a wasted one.
local GEO = os.getenv("IRIX_GEO_LOG")
local geo_f = GEO and io.open(GEO, "a") or nil
local geo_last = 0
local geo_scr = nil

local function geo_tick()
  if not geo_f then return end
  local t = os.time()
  if t == geo_last then return end
  geo_last = t
  if not geo_scr then
    pcall(function()
      for _, s in pairs(manager.machine.screens) do geo_scr = s break end
    end)
  end
  local g, e = "?", -1
  pcall(function()
    if geo_scr then g = geo_scr.width .. "x" .. geo_scr.height end
    e = manager.machine.time.seconds
  end)
  geo_f:write(string.format("%d emu=%d geo=%s\n", t, e, g))
  geo_f:flush()
end

-- One line per STAT_PERIOD wall seconds: what arrived, what was applied, and
-- what is still queued. Printed even when every counter is zero, because an
-- unchanging heartbeat with empty queues is exactly the evidence that was
-- missing the first time this went wrong — "the agent is alive and idle" and
-- "the agent is dead" must not look the same in the log.
local STAT_LOG_MAX = 4 * 1024 * 1024
local st_lines = 0

local function stat_tick()
  local t = os.time()
  if st_last == 0 then st_last = t end
  if (t - st_last) < STAT_PERIOD then return end
  st_last = t
  -- A heartbeat that never stops needs a bound. Checked once an hour, so this
  -- costs one extra open per 240 lines and the log can never fill the tile dir.
  st_lines = st_lines + 1
  if (st_lines % 240) == 0 then
    local f = io.open(LOG, "r")
    if f then
      local sz = f:seek("end")
      f:close()
      if sz and sz > STAT_LOG_MAX then
        local w = io.open(LOG, "w")
        if w then
          w:write(os.date("%H:%M:%S ") .. "log truncated at " .. tostring(sz) .. " bytes\n")
          w:close()
        end
      end
    end
  end
  log(string.format(
    "stats movep=%d move=%d movea=%d key=%d queued=%d,%d applied=%d,%d " ..
      "mq=%d kq=%d aq=%d tgt=%s res=%d,%d giveups=%d emu=%d",
    st_movep, st_move, st_movea, st_key, st_qx, st_qy, st_ax, st_ay,
    #mq, #kq, #aq, ta and (ta.x .. "," .. ta.y) or "-",
    res_x, res_y, st_giveups, math.floor(emu_now())))
  st_movep, st_move, st_movea, st_key = 0, 0, 0, 0
  st_qx, st_qy, st_ax, st_ay = 0, 0, 0, 0
end

-- The tick is held in a module-local (and a global) on purpose. MAME's Lua
-- notifier subscriptions are garbage-collected when nothing references them —
-- `emu.add_machine_frame_notifier` was observed here firing exactly once and
-- then silently stopping for that reason. `emu.register_periodic` keeps its own
-- reference today, but "the agent silently stopped ticking" is precisely the
-- failure this file must never have, so the reference is made explicit rather
-- than assumed.
local function agent_tick()
  if not nat then setup() end
  geo_tick()
  if esc_ticks > 0 then
    esc_ticks = esc_ticks - 1
    if (esc_ticks % 20) == 0 and nat then nat:post_coded("{ESC}") end
  end
  if probe > 0 then
    probe = probe - 1
    if probe > 7 then set_button("Left Button", 1) else set_button("Left Button", 0) end
  end
  process_queue()
  poll()
  -- After poll() so a MOVEA parsed this tick takes its first step this tick,
  -- and before drain_move() so that step reaches the ioport this tick — the
  -- same no-added-latency-for-the-common-case rule MOVEP's drain follows.
  movea_tick()
  -- After poll(), so a MOVEP parsed this tick is applied this tick.
  drain_move()
  drain_keys()
  stat_tick()
end

_G.__irix_agent_tick = agent_tick
emu.register_periodic(agent_tick)

log("agent script loaded; cmd=" .. CMD)
