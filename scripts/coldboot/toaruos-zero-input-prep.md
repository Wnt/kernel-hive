# toaruos boot capture — zero-input prep

Status: **AUTHORED-UNTESTED**. `labctl shot toaruos` showed the expected 1920×1080
desktop with a focused terminal.

This is a restart-backed tile: the remastered `image.iso` is the golden artifact
and there is no snapshottable disk. Its baked yutan configuration suppresses the
tutorial/login toasts, removes clock/weather animation, and autostarts Terminal,
so cold boot is zero-input. Ready means the wallpaper, panel, desktop icons, and
focused terminal prompt are all visible. Tier 3 holds 45 s (120 s cap).

`BR_BOOT_KIND=restart` deliberately skips `savevm`/`loadvm`; the record still
freezes a lossless poster and emits the same H.264/AAC assets. Promotion must compare
the poster with a second fresh-boot framebuffer because no vmstate seam proof exists.
Audio is AC97 48 kHz stereo; canvas is 1920×1080 at 30 fps.

Reject a tutorial, toast, login screen, or panel clock. Then postprocess and use
trim only after its final-frame MD5 gate passes.
