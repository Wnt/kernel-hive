# tinycore boot capture — zero-input prep

Status: **AUTHORED-UNTESTED**. Live framebuffer inspection showed the 1024×768
FLWM desktop, wbar, and focused aterm fixture.

The tile boots TinyCore 15 from a LiveCD; tile-local `state.qcow2` is only the
virtio vmstate store. The natural cold boot is unattended and reaches FLWM/wbar,
but the curated aterm/steady-caret arrangement lives in the old RAM snapshot.
Recording intentionally rebases the clone golden at the naturally reached desktop;
if exact fixture parity is required, remaster the ISO to autostart aterm before
publishing. No keyboard/mouse input is sent by the arm.

The arm uses a conservative 35 s Tier-3 hold. Ready means FLWM and wbar have fully
painted and stopped rearranging; inspect `poster.png` before promotion. The clone
copies `state.qcow2`, removes conditional loadvm, and rewrites the post-launch SSH
forward 5882→6882. Audio is AC97 48 kHz stereo; canvas is 1024×768 at 30 fps.

Run record → postprocess → optional trim. Reject any poster showing only the
TinyCore boot console, X startup, or a partially painted dock.
