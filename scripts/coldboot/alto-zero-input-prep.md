# alto boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip is recorded and `spa.bootVideo` is unset;
this file and the `alto)` arm in `bootrec-tiles.conf` exist so the cold-boot path
is audited, as the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared base stays read-only)
and rewrites SSH 5843→6843. Before recording it stops `getty@tty1` and kills
`Contralto` over clone SSH; after capture it starts the kiosk again. Bridge kind
intentionally skips `savevm`.

**The canvas is PORTRAIT, 608×808, and this is the only arm in the file that is.**
That is not an adaptation for the recorder's benefit — it is the Alto's own
bitmap (606 visible pixels inside a 608-wide row, 808 lines), and the live tile
captures exactly it with no letterbox. Anything downstream that assumes a
landscape clip will pillarbox this one and the result will not match what the
exhibit shows.

**Zero input is genuine, and a cold boot reaches the fixture.** The kiosk starts
X, ContrAlto loads `nonprog.dsk`, and its own boot script issues one `Command
start` two seconds in; the Alto then boots to the Executive unattended. Nothing
is typed and nothing is pointed at, which is exactly the state the golden holds,
so a clip's last frame would hand off to the golden's first frame cleanly.

Ready means the two Executive banner lines painted across the top with the `>`
prompt below them — measured as 2345 ink pixels in the rect `0 88 608 40`.
**Bound that measurement above as well as below** if you automate it: a black
screen measures 24320 there (the whole rectangle) and reads as "very ready" to a
`greater-than` test, which is how one build declared a guest that had not started
X yet.

**No audio.** The Alto has no sound hardware of any kind; the AC97 card in the
device set exists only so the golden's device set matches its siblings. A
recorder that gates on non-silent audio will hang here.
