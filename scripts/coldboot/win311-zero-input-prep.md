# win311 boot capture — zero-input prep

Status: **AUTHORED-UNTESTED**. The live shot showed WfW 3.11 at 640×480 with
maximized, focused Notepad.

Both tile-local qcow2 disks are copied because the vmstate spans them. DOS boots C:,
Windows starts from AUTOEXEC, and `WIN.INI`/`runonc16` opens Notepad without input.
The arm holds 40 s (90 s cap). Ready means Program Manager and maximized empty
Notepad are fully painted; reject a DOS prompt, network dialog, or partial Windows
splash. Screensaver is off and the caret is effectively steady on disk.

The device set remains pc/acpi-off/usb-off, Pentium, std VGA, SB16, two IDE disks,
NE2000, and the namespaced COM1 socket. Canvas is 640×480/30 fps with SB16 AAC audio.
Trim only after the poster/loadvm invariant passes across both copied disks.
