-- armeval-boot.lua — re-curate the ARM Evaluation System scene on EVERY boot.
--
-- bbcb has no MACHINE_SUPPORTS_SAVE, so the golden-savestate path that other
-- converted stations use restores garbage here (measured: the process died).
-- Reset is therefore a cold boot — but this station's documented scene has
-- two supervisor lines typed past the A* prompt ("*LIB $" then "AB": the
-- ADFS library is Unset on a cold boot, and ARM BBC Basic is $.AB on Disc
-- 3), so the launcher hands MAME this -autoboot_script and the machine
-- types its own way to the exhibit. Frame counts are deterministic in
-- emulated time (50 Hz): the A* prompt is ready well before frame 650
-- (~13 s); AB's floppy load takes a few seconds more.
local n = 0
_G.dbr_armeval_sub = emu.add_machine_frame_notifier(function()
    n = n + 1
    if n == 650 then
        manager.machine.natkeyboard:post("*LIB $\n")
    elseif n == 800 then
        manager.machine.natkeyboard:post("AB\n")
    end
end)
