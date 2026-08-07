# msdoswin1 boot capture — zero-input prep

Status: **AUTHORED-UNTESTED**. The live 640×350 shot showed Windows 1.01 MS-DOS
Executive with Calculator and Notepad.

The single external qcow2 is copied and its launcher path rewritten before boot.
The recorder comments out the launcher's post-QMP `loadvm golden` call so AUTOEXEC.BAT
actually cold-boots DOS and starts Windows. No input is needed. The arm holds 20 s;
ready means the EGA MS-DOS Executive and its configured applications are completely
painted. Reject a DOS prompt or Windows splash.

The exact device set retains PC-speaker audio on the dbus backend, std VGA, IDE, and
PS/2 input. Canvas is 640×350/30 fps and the PC-speaker stream is encoded to AAC.
Confirm the clone poster before any golden promotion.
