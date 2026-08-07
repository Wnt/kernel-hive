# kolibrios boot capture — zero-input prep

Status: **AUTHORED-UNTESTED**. The read-only shot showed the 1024×768 KolibriOS
desktop with TINYPAD open and clock/CPU animation disabled.

The LiveCD self-boots to the KolibriOS desktop; `state.qcow2` is only its copied
virtio vmstate store. The arm removes the array-form conditional loadvm (a form the
old recorder missed), records AC97 audio, and holds 20 s. Ready means wallpaper,
taskbar, edge icons, and pointer are painted. Reject the boot logo or half-painted UI.

TINYPAD and the animation tweaks live in the existing RAM golden, not necessarily
the ISO. Natural cold boot therefore may rebase to the plain desktop. To preserve
fixture parity, automate TINYPAD/clock setup in a remastered ISO before publishing.
The authored arm itself sends no input and is bounded at 60 s.
