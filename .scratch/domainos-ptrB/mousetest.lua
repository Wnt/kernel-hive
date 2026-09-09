-- racer B theory test: drive mouse2/mouse3 ports directly via Lua, bypass ctlsock
local m = manager.machine
local ports = m.ioport.ports
local function find_port(tag)
  for k,v in pairs(ports) do
    if k == tag then return v end
  end
  return nil
end

-- Domain/OS kbd device is likely tagged ":kbd" with subtags mouse1/mouse2/mouse3
local candidates = {}
for k,v in pairs(ports) do
  if k:find("mouse") then
    candidates[#candidates+1] = k
  end
end

local f = io.open("/data/vms/sandbox/domainos-ptrb/scratch/ports.log", "w")
for _,k in ipairs(candidates) do
  f:write(k .. "\n")
  local p = ports[k]
  for fname, field in pairs(p.fields) do
    f:write("  field: " .. fname .. "\n")
  end
end
f:close()
