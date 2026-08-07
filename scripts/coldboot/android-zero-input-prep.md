# android boot capture — zero-input prep

Status: **AUTHORED-UNTESTED**. The live 1024×768 shot showed Android-x86 Terminal
Emulator at a shell prompt with the navigation bar visible.

The arm safely copies the external `android.qcow2`, rewrites the launcher to that
copy, and strips its unconditional `-loadvm golden`. Android cold boot can take about
90 s; the arm uses that fixed hold with a 180 s cap. Ready means the unlocked Android
surface has finished booting and no Setup Wizard, lock screen, permission dialog, or
toast obscures it.

Stay-awake/animation settings persist on disk, but Terminal focus may exist only in
the old RAM snapshot. Before publishing, cold-boot a prep clone and add a disk-backed
autostart for the desired terminal surface if needed. Do not automate credentials in
the arm. Canvas is 1024×768/30 fps with intel-HDA AAC audio.
