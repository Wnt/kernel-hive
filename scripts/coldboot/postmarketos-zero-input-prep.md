# postmarketos boot capture — automated-input prep

Status: **AUTHORED-UNTESTED**. The live shot showed the 720×1440 phosh desktop with
GNOME Console focused.

Both writable state surfaces matter: the external OS qcow2 is copied through
`BR_EXTERNAL_DISKS`, and tile-local `OVMF_VARS.qcow2` is copied through `BR_DISKS`.
Conditional loadvm is removed only in the clone. The guest stops at the phosh greeter;
`postmarketos-record-driver.sh` waits for a real 720×1440 framebuffer, then enters the
clone login value from `POSTMARKETOS_RECORD_PIN` without logging it. No human input.

After login the disk-baked autostart should apply no-blank/no-lock settings and open
Console. The arm holds another 30 s; ready means maximized Console at the shell prompt,
with no greeter/tour/OSK. Canvas is portrait 720×1440/30 fps with intel-HDA AAC audio.
Never copy only one of the disk/varstore pair.
