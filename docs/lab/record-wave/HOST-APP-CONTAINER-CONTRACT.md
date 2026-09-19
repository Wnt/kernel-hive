# Shared host-application container contract — record wave

Applies to the non-QEMU/non-direct-MAME host applications in the new-station wave:
Genera VLM, EKA2L1, NP2kai, openMSX, WindEmu (if selected), Hercules/x3270,
DPS8M, SIMH/VAX and SIMH/ITS.

Use the proven Medley/Vision pattern rather than inventing containment per station.

## Invariants

The visitor-controlled program runs in its own systemd-nspawn container:

- private PID, mount, IPC, UTS and user namespaces
- private network by default
- read-only base rootfs / volatile overlay
- emulator/assets mounted read-only
- exactly one writable station work directory
- capabilities dropped
- no-new-privileges
- mount/sysadmin operations filtered
- Xvfb inside the container when the app needs X
- host-visible X socket exposed only for streamhost capture/input
- reset kills the complete container/process tree, wipes work state, and relaunches

A visitor must never be one emulator escape/menu feature away from a root shell on labhost.

## Shared rootfs idea

Do not build eight unrelated Debian roots if one package superset works.

A common record-wave host-app root can carry:

- Xvfb / xauth / x11-utils
- xdotool
- xterm
- telnet / netcat-openbsd
- x3270
- SDL2 runtime
- GTK runtime needed by selected apps
- libstdc++ / common X11 libraries
- Python 3 for tiny readiness helpers

Station-specific emulator binaries and ROM/media remain read-only station assets.

If EKA2L1/NP2kai/Genera need incompatible dependency generations, split only those out after proving the incompatibility.

## Outer launcher responsibilities

The outer station launcher should be generic:

1. verify asset/rootfs/inner-script existence
2. reap only processes/container belonging to this station
3. recreate the X socket bind directory
4. recreate the writable work directory
5. copy/reflink pristine mutable seed files into work
6. start systemd-nspawn with the station inner script
7. publish host-visible pids for idle-pause/stop tooling
8. refuse to start a second survivor
9. return only after the X socket/published framebuffer is real

The **inner** script owns emulator-specific boot and readiness.

## Why this matters for the record attempt

The four heritage terminals differ in emulated CPU and terminal protocol, but
their museum plumbing is the same. The mobile/host-app emulators differ in UI,
but their containment is also the same. Solve the container lifecycle once and
relay the exact working implementation to every sibling wave.

Do not merge an unproven generic launcher to main during the record attempt.
Treat this as a template: the first live station proves the bytes; then siblings
copy the measured version.
