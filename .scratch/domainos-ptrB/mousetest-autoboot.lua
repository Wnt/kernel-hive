local R = "/data/vms/sandbox/domainos-ptrb/rig"
local logf = io.open(R.."/lua.log", "w")
local function log(s) logf:write(tostring(s).."\n"); logf:flush() end

local m = manager.machine
local nk = m.natkeyboard

local state = "wait_login"
local t0 = m.time.seconds
local step_i = 0
local last_action = m.time.seconds

emu.register_frame_done(function()
  local now = m.time.seconds
  if state == "wait_login" and now - t0 > 118 then
    log("posting login at t="..now)
    nk:post("user\n")
    state = "wait_pw"
    last_action = now
  elseif state == "wait_pw" and now - last_action > 3 then
    log("posting password at t="..now)
    nk:post("-apollo-\n")
    state = "wait_dm"
    last_action = now
  elseif state == "wait_dm" and now - last_action > 25 then
    log("assuming DM up at t="..now.." -- locating mouse ports")
    local ports = m.ioport.ports
    local mtag2, mtag3
    for k,v in pairs(ports) do
      if k:find("mouse2") then mtag2 = k end
      if k:find("mouse3") then mtag3 = k end
    end
    log("mtag2="..tostring(mtag2).." mtag3="..tostring(mtag3))
    if mtag2 and mtag3 then
      local p2, p3 = ports[mtag2], ports[mtag3]
      local f2, f3
      for fname,field in pairs(p2.fields) do f2 = field; log("field2 name="..fname) end
      for fname,field in pairs(p3.fields) do f3 = field; log("field3 name="..fname) end
      _G.__f2 = f2
      _G.__f3 = f3
      state = "drive"
      last_action = now
      step_i = 0
    else
      log("MOUSE PORTS NOT FOUND -- dumping all ports")
      for k,v in pairs(ports) do log("port: "..k) end
      state = "done"
    end
  elseif state == "drive" and now - last_action > 0.1 then
    -- walk +20 every 100ms for 20 steps (plain analog, under 20Hz device sampler)
    if step_i < 20 then
      step_i = step_i + 1
      local val = (step_i * 20) % 256
      _G.__f2:set_value(val)
      _G.__f3:set_value(val)
      log("step "..step_i.." set_value x=y="..val)
      last_action = now
    else
      log("drive done at t="..now)
      state = "settle"
      last_action = now
    end
  elseif state == "settle" and now - last_action > 2 then
    log("DONE at t="..now)
    state = "finished"
  end
end)
