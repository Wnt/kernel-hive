# amigaos (AROS) boot capture — zero-input prep

Status: **AUTHORED-UNTESTED**. The live read-only shot showed 1024×768 Wanderer
with the AROS shell/window surface.

The x86 AROS LiveCD auto-selects its GRUB entry and self-lands on Wanderer; builder
evidence gives roughly 30–60 s depending on the image. `golden-scratch.qcow2` is an
IDE vmstate store only. No guest input is required. The arm holds 65 s (150 s cap),
then freezes. Ready means Wanderer backdrop, desktop icons, and workbench windows
are fully painted; reject GRUB, boot text, a blank workbench, or a modal requester.

The cold boot may not reproduce windows that existed only in the old RAM snapshot.
That is a deliberate new-golden rebase unless the ISO is remastered to autostart the
same fixture. Canvas is 1024×768/30 fps with AC97 AAC audio. Clone and savevm operate
only on the copied scratch qcow2.
