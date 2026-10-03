# No host window, network cartridge, MIDI connection, or microphone input.
set renderer SDLGL-PP
set frequency 48000
set sound_driver sdl
set throttle on
set speed 100
set maxframeskip 0
set minframeskip 0
set save_settings_on_exit false
set pause false
plug joyporta mouse
set firmwareswitch [expr {$env(MSX_PROFILE) eq "view"}]
set power on
reset
