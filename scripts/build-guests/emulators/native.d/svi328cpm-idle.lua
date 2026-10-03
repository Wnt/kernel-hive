-- Pinned CP/M 2.24 / SV-806 delayed-read regression. No warm boot or BIOS edits.
-- F078 is this BIOS's motor countdown. A banner-only test misses its expiry.
local machine = manager.machine
local memory = machine.devices[":maincpu"].spaces["program"]
local display = machine.devices[":exp:sv601:0:sv806"]
local video = assert(display.items["0/m_ram"], "SV-806 display RAM unavailable")
local cells = emu.item(video)
local mapped = emu.item(display.items["0/m_ram_enabled"])
local keys = {}
for tag, port in pairs(machine.ioport.ports) do
    if tag:match("^:KEY%.") then
        for name, field in pairs(port.fields) do
            if name:sub(2, 3) == "  " then keys[name:sub(1, 1)] = field end
        end
    end
end
keys["\n"] = machine.ioport.ports[":KEY.6"].fields["Enter"]
keys[" "] = machine.ioport.ports[":KEY.8"].fields["Space"]
local shift = machine.ioport.ports[":KEY.6"].fields["Shift"]
local pending = ""
local held = nil
local next_key = 0
local step = 0
local done_at = 0
local function type_line(text)
    assert(pending == "" and not held, "keyboard still busy")
    pending = text
end

emu.register_periodic(function()
    local now = emu.time()
    -- Use the physical matrix: natural keyboard's default 50ms drops letters.
    -- 150ms down + 350ms gap respects the proven 100ms hold/gap floors.
    if held and now >= next_key then
        held:set_value(0)
        shift:set_value(0)
        held = nil
        next_key = now + 0.35
    elseif not held and pending ~= "" and now >= next_key then
        local char = pending:sub(1, 1)
        pending = pending:sub(2)
        if char == "+" then shift:set_value(1); char = "=" end
        held = assert(keys[char], "unmapped key " .. char)
        held:set_value(1)
        next_key = now + 0.15
    end
    -- SV-806 glyph indexes are ASCII minus 0x20; ignore inverse-video bit 7.
    local text = cells:read_block(0, 0x800):gsub(".", function(c)
        return string.char((c:byte() & 0x7f) + 0x20)
    end)
    if step == 0 and now > 10 and mapped:read(0) == 0 and memory:read_u16(0xf078) == 0 and text:find("A>", 1, true) then
        print("SV801 motor countdown expired at " .. now)
        type_line("mbasic\n")
        step = 1
    elseif step == 1 and pending == "" and not held and text:find("BASIC-80 Rev. 5.21", 1, true) and text:find("Ok", 1, true) then
        type_line("print 300+28\n")
        step = 2
    elseif step == 2 and text:find(" 328", 1, true) then
        -- The expression's input contains no 328: this is the guest's result.
        done_at = now + 1
        step = 3
    elseif step == 3 and now >= done_at then
        print("SV801-IDLE-MBASIC-PASS: BASIC executed 300+28 after motor-off")
        machine:exit()
        step = 4
    end
end)
