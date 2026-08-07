# helenos boot capture — zero-input prep

Status: **AUTHORED-UNTESTED**. The live shot showed the 1024×768 HelenOS compositor,
taskbar, and focused Bdsh terminal.

HelenOS 0.14.1 boots from its ia32 LiveCD without a login prompt. The tile-local
`golden.qcow2` is an IDE vmstate store and is copied before recording. The arm uses
a 60 s fixed hold, matching the golden manifest's ~50 s compositor wait. Ready means
the blue compositor desktop and taskbar are complete; the taskbar clock may tick.

The terminal fixture may have been created only in the prior RAM snapshot. A natural
cold boot without it is still recordable but changes the promoted golden; require a
poster review, or remaster/autostart Bdsh for exact fixture parity. Canvas is
1024×768/30 fps, intel-HDA audio to AAC. No input is sent.
