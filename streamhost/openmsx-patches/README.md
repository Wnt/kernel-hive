# openMSX native station adapter

Apply `0001-native-outputs.patch` to openMSX release 21.0 commit
`cb61db762aba16752ff649990bf85e40627777af`, then copy `HiveOutput.hh` into
`src/video/`. `scripts/build-guests/emulators/build-openmsx-native.sh` performs
both actions idempotently and rejects any other source revision.

The opt-in environment variable `OPENMSX_SHM_PATH` exports the completed
native FrameSource from the upstream postprocessor. Its standard field
selection and deinterlacing remain intact. The launcher uses SDL's offscreen
driver and Mesa software rendering without a display server. Streaming
reads fixed 640×480 IFB1 BGRA with an acquire/release sequence lock directly
from shared memory; it does not capture a window or poll screenshots.
The ordinary renderer remains available when the opt-in variable is absent.
This is scoped to the standard V99x8 video path used by the FS-A1GT;
V9990 and LaserDisc are outside this station's declared hardware.

`OPENMSX_AUDIO_FIFO` opts into S16LE stereo from the SDL dummy callback.
The launcher sets 48000 Hz explicitly; a blocked or missing consumer never
blocks the emulator. FIFO writes are bounded and atomic. No microphone or
MIDI host connection is opened by the station configuration.

The `hive_mouse dx dy buttons` command checks all bounds before emitting
ordinary openMSX mouse events. The XML endpoint is local to the instance;
`streamhost/stations/msxturbor/adapter.py` exposes only a narrow private
mamectl-compatible protocol to the existing streamhost input backend.
Keyboard matrix operations extend the existing upstream commands with a
guest row-read counter; a zero-bit release queries that counter without
changing any key. Mouse commands similarly report actual sampling cycles.
The adapter waits for guest consumption, not a guessed wall-clock delay.

Upstream project and licence: https://github.com/openMSX/openMSX (GPL-2.0).
The upstream source and proprietary machine/media assets are not vendored.
