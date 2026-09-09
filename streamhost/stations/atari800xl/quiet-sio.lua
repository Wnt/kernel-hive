-- quiet-sio.lua — bakes SOUNDR=0 into the atari800xl golden savestate.
--
-- WHY: the XL OS's disk-loader SIO routine drives the speaker for every SIO
-- frame while SOUNDR ($0041) is non-zero (default 3 on power-up) — "beep
-- concert" during a MyPicoDos load (dozens of beeps over the ~15 s load of
-- a title like LASTWORD.XEX). Authentic 800XL behaviour, silenced here by
-- operator choice (2026-09-08, see docs/lab/ATARI800XL-WAVE.md "Quiet SIO").
-- MyPicoDos loads go through the OS SIO vector, so SOUNDR governs it too.
--
-- USE (one-shot bake on a sandbox rig, never the live station dir):
--   1. Cold-boot the station's rig command (docs/lab/ATARI800XL-WAVE.md
--      "Setup"/"§Checkpoint") WITHOUT this script, confirm the menu is
--      settled (poll STAT/SHOT), THEN kill and relaunch the SAME rig with
--      `-autoboot_delay 23 -autoboot_script <rig>/quiet-sio.lua` added —
--      OR relaunch straight from a fresh cold boot with the flags baked in
--      from the start, since the poke only touches RAM, not any disk state.
--   2. Read /soundr_poke.txt (written next to this script's own path) to
--      confirm the byte read back as 0.
--   3. Over ctlsock: PAUSE, then `SAVEST golden` (mtimeout >= 60 — SAVEST
--      is a ~12 s stop-the-world save on this build).
--   4. Restage the resulting sta/a800xlp/golden.sta to
--      streamhost/stations/atari800xl/sta/a800xlp/golden.sta (chmod 644),
--      sha256 it, then `ssh lab 'labctl reset atari800xl'` to prove the
--      live station picks it up (LOADST, in-process).
--
-- REVERSIBLE: to restore the authentic SIO noise, recapture the golden
-- WITHOUT running this script (SOUNDR stays at the OS default, 3, on a
-- plain cold boot) — see checkpoint-guard / docs/lab/checkpoint-guard.md.
--
-- Why a script and not a ctlsock verb: the mamectl ctlsock protocol
-- (scripts/build-guests/emulators/mamectl/src/osd/modules/ctlsock/ctlsock.cpp)
-- has no memory read/write verb (checked 2026-09-08, quiet-sio stream) — a
-- one-shot MAME Lua autoboot script is the smallest fix that stays inside
-- this stream's brief; adding a POKE verb to the shared ctlsock module is
-- out of scope here.
--
-- Address ($0041, SOUNDR): Atari OS memory map, "sound status while reading
-- cassette/disk via SIO" — non-zero drives the speaker on every SIO frame.

local mem = manager.machine.devices[':maincpu'].spaces['program']
mem:write_u8(0x41, 0)

local dir = (function()
  local src = debug.getinfo(1, 'S').source:sub(2)
  return src:match('(.*/)') or './'
end)()

local f = io.open(dir .. 'soundr_poke.txt', 'w')
if f then
  f:write('SOUNDR after poke = ' .. tostring(mem:read_u8(0x41)) .. '\n')
  f:close()
end
