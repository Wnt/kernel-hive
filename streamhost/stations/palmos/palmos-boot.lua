-- palmos-boot.lua — the station's scene, scripted.
--
-- WHY THIS EXISTS INSTEAD OF A GOLDEN SAVESTATE. Every other MAME-native
-- station restores a checkpoint (`-state golden`) and is at its scene in about
-- a second. palmpro cannot: restoring ANY savestate in a fresh process
-- segfaults inside zlib's inflate() under save_manager::read_file(). MEASURED
-- 2026-09-20 and run to ground -- the .sta is complete (it inflates cleanly in
-- Python to exactly the 7,198,225 bytes the machine registers), the savestate
-- signature matches, and the entry list walked live under gdb is structurally
-- identical (1001 entries) -- but zlib's own internal_state is already
-- corrupt by the 343rd inflate() call, 1288 bytes into the stream, and dies on
-- a runaway store with RCX=0xFFFFFFFF. That is heap corruption somewhere in
-- palmpro's own setup, not savestate bookkeeping, so there is no contained
-- patch to carry. The station therefore ships with NO checkpoint
-- (MAME_NATIVE_CHECKPOINT=0) and reaches its scene the only other way MAME
-- offers: by being driven.
--
-- WHY FIXED FRAME NUMBERS ARE DETERMINISTIC HERE. This is a cold boot from
-- mask ROM into zeroed RAM with no NVRAM device and no disk -- palm.cpp's
-- machine_reset() memsets RAM and copies the boot ROM, so the machine takes
-- the identical path every time. The frame numbers below were measured on
-- this binary and hold regardless of wall-clock speed, because they count
-- EMULATED frames, not seconds.
--
-- WHAT IT DOES. Palm OS 2.0 boots to Welcome, then to the digitizer
-- calibration flow, which cannot be skipped and which needs three accurate
-- pen taps. It then lands in Preferences; one tap on the silkscreen
-- Applications button opens the Applications Launcher, which is the exhibit.
--
-- WHY THESE PEN COORDINATES. The values are RAW pen-field units (the driver's
-- PORT_MINMAX(0,0xa0)), and each one is exactly what
-- mame-ctlsock-abs-fields.patch computes for the surface pixel the target is
-- drawn at: raw = round(px * 0xa0 / (surface - 1)), i.e. x*160/159 and
-- y*160/219 on the published 160x220. Calibrating with the patch's OWN map
-- makes the pointer self-consistent by construction: whatever affine map Palm
-- OS derives from these three taps is the exact inverse of the map every
-- later MOVEA goes through. Targets are at surface (10,10), (149,149) and
-- (79,60) -- read off the framebuffer, not guessed -- and the silkscreen
-- Applications button at (14,175), in the unlit Graffiti strip below the LCD.

local n = 0
local m = manager.machine
local px = m.ioport.ports[":PENX"].fields["Pen X"]
local py = m.ioport.ports[":PENY"].fields["Pen Y"]
local pb = m.ioport.ports[":PENB"].fields["Pen Button"]

local function pen(x, y) px:set_value(x); py:set_value(y) end
local function down()    pb:set_value(1) end
local function up()      pb:set_value(0) end

-- {frame, action}. A tap is pen-position, then ~0.5 s of held pen: Palm OS
-- samples the digitizer through the 68328's SPI ADC and needs several samples
-- before it accepts a touch, so a one-or-two-frame poke is silently dropped.
local SEQ = {
  { 420, function() pen(10, 7)    end}, { 440, down}, { 470, up},   -- target 1 (10,10)
  { 620, function() pen(150, 109) end}, { 640, down}, { 670, up},   -- target 2 (149,149)
  { 820, function() pen(79, 44)   end}, { 840, down}, { 870, up},   -- target 3 (79,60)
  {1100, function() pen(14, 128)  end}, {1120, down}, {1150, up},   -- silkscreen Applications (14,175)
  {1250, function() pen(80, 110)  end},                             -- park the pen mid-surface, button up
  {1400, function() print("palmos-boot: Applications Launcher reached at frame " .. n) end},
}

-- The notifier token MUST stay referenced: an anonymous one is garbage
-- collected and the callback then silently never fires again.
KH_PALMOS_BOOT = emu.add_machine_frame_notifier(function()
  n = n + 1
  for _, e in ipairs(SEQ) do
    if e[1] == n then e[2]() end
  end
end)

print("palmos-boot: scene script armed")
