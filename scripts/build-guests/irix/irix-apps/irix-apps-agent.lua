-- IRIX MAME install agent (issue #20, Track A).
-- Superset of the tile's irixagent.lua: adds CD-ROM media swapping and MAME
-- snapshots so a multi-CD `inst` run can be driven without restarting MAME.
--
-- Command channel: append one command per line to $IRIX_CMD; the agent
-- consumes and truncates the file.
--
--   POST <text>     natkeyboard text (a shell line; add {ENTER} via CODE)
--   CODE <coded>    natkeyboard coded text, e.g. {ENTER} {ESC} {TAB}
--   CLICK1/2/3      left / right / middle click
--   DCLICK1         left double-click
--   DOWN1 / UP1     left button hold / release (SGI menus need press-drag-release)
--   KBDINFO         log the natkeyboard devices
--   KBSGI / KBPS2   enable exactly one keyboard (see KBSGI: fixes lost shift)
--   LUA <code>      run arbitrary Lua (extend the agent without a restart)
--   CDLOAD <path>   insert an ISO into the emulated SCSI CD-ROM (scsibus:6)
--   CDEJECT         eject it
--   CDINFO          log every image device tag/instance MAME exposes
--   SNAP            write a framebuffer snapshot to the MAME snapshot dir
--   RESET           guest hard reset       EXIT   clean MAME shutdown
--   DUMP            log agent state
--
-- Everything here bypasses SDL, which never delivers keys/buttons on a WM-less
-- full-screen Xvfb (see /data/vms/soltest/irix-mame/RECIPE.txt).

local CMD = os.getenv("IRIX_CMD") or "/tmp/irix_apps_cmd"
local LOG = CMD .. ".agent.log"

local function log(s)
  local f = io.open(LOG, "a")
  if f then f:write(os.date("%H:%M:%S ") .. tostring(s) .. "\n"); f:close() end
end

local nat = nil
local mport = nil
local cd = nil
local queue = {}
local cur = nil

local function find_cd()
  for _, img in pairs(manager.machine.images) do
    local t = tostring(img.device and img.device.tag or "")
    if t:find("cdrom") then return img end
  end
  return nil
end

local function setup()
  local m = manager.machine
  nat = m.natkeyboard
  if nat then nat.in_use = true end
  mport = m.ioport.ports[":ioc2:aux:hle_ps2_mouse:mouse_buttons"]
  cd = find_cd()
  log("setup nat=" .. tostring(nat ~= nil) ..
      " mport=" .. tostring(mport ~= nil) ..
      " cd=" .. tostring(cd ~= nil))
end

local function set_button(name, val)
  if not mport then return end
  local fld = mport.fields[name]
  if fld then fld:set_value(val) end
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

local function exec_line(line)
  local c, rest = line:match("^(%S+)%s?(.*)$")
  if not c then return end
  if c == "POST" then
    if nat then nat:post(rest) end
  elseif c == "CODE" then
    if nat then nat:post_coded(rest) end
  elseif c == "CLICK1" then enqueue_click("Left Button", 10, 6)
  elseif c == "DCLICK1" then
    enqueue_click("Left Button", 10, 8)
    enqueue_click("Left Button", 10, 6)
  elseif c == "DOWN1" then set_button("Left Button", 1)
  elseif c == "UP1" then set_button("Left Button", 0)
  elseif c == "CLICK2" then enqueue_click("Right Button", 10, 6)
  elseif c == "CLICK3" then enqueue_click("Middle Button", 10, 6)
  elseif c == "KBDINFO" then
    log("KBDINFO canpost=" .. tostring(nat and nat.can_post))
    local kbs = nat and nat.keyboards
    if kbs then for i, k in pairs(kbs) do
      log("  kbd[" .. tostring(i) .. "] tag=" .. tostring(k.tag) ..
          " name=" .. tostring(k.name) .. " enabled=" .. tostring(k.enabled))
    end end
  elseif c == "KBSGI" then
    -- Keep ONLY the :ioc2 SGI keyboard. With both keyboards enabled the
    -- natkeyboard splits shift and the character across the two devices, so
    -- every SHIFTED character is lost ("_", "|", "~", uppercase -> lowercase).
    local kbs = nat and nat.keyboards
    if kbs then for _, k in pairs(kbs) do
      k.enabled = (tostring(k.tag) == ":ioc2")
    end end
    log("KBSGI: only :ioc2 enabled")
  elseif c == "KBPS2" then
    local kbs = nat and nat.keyboards
    if kbs then for _, k in pairs(kbs) do
      k.enabled = (tostring(k.tag) ~= ":ioc2")
    end end
    log("KBPS2: only the PS/2 keyboard enabled")
  elseif c == "LUA" then
    -- Escape hatch: run arbitrary Lua so the agent can be extended without a
    -- restart (a cold IRIX boot costs minutes). Logs the result.
    local fn, err = load(rest)
    if fn then
      local ok, res = pcall(fn)
      log("LUA ok=" .. tostring(ok) .. " res=" .. tostring(res))
    else
      log("LUA compile error: " .. tostring(err))
    end
  elseif c == "CDINFO" then
    for k, img in pairs(manager.machine.images) do
      log("  image key=" .. tostring(k) ..
          " tag=" .. tostring(img.device and img.device.tag) ..
          " inst=" .. tostring(img.instance_name) ..
          " brief=" .. tostring(img.brief_instance_name) ..
          " file=" .. tostring(img.filename))
    end
  elseif c == "CDLOAD" then
    if not cd then cd = find_cd() end
    if cd then
      cd:unload()
      local ok, err = pcall(function() cd:load(rest) end)
      log("CDLOAD " .. rest .. " ok=" .. tostring(ok) .. " err=" .. tostring(err) ..
          " now=" .. tostring(cd.filename))
    else
      log("CDLOAD: no cdrom image device found")
    end
  elseif c == "CDEJECT" then
    if cd then cd:unload(); log("CDEJECT done") end
  elseif c == "SNAP" then
    manager.machine.video:snapshot()
    log("SNAP taken")
  elseif c == "EXIT" then manager.machine:exit()
  elseif c == "RESET" then manager.machine:hard_reset()
  elseif c == "DUMP" then
    log("DUMP canpost=" .. tostring(nat and nat.can_post) ..
        " isposting=" .. tostring(nat and nat.is_posting) ..
        " qlen=" .. tostring(#queue) ..
        " cd=" .. tostring(cd and cd.filename))
  end
  log("exec: " .. line)
end

local function poll()
  local f = io.open(CMD, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()
  if content and #content > 0 then
    local w = io.open(CMD, "w"); if w then w:close() end
    for line in content:gmatch("[^\n]+") do exec_line(line) end
  end
end

emu.register_periodic(function()
  if not nat then setup() end
  process_queue()
  poll()
end)

log("install agent loaded, cmd=" .. CMD)
