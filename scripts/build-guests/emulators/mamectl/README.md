# mamectl — the compiled-in MAME guest-control module (issue #45)

## Patch vs. fork — which one to edit

The `.patch` files in `scripts/build-guests/` (including the one this
directory regenerates) are **the maintained source**. The published fork
(`github.com/Wnt/mame`, consumed here as the `third_party/mame-irix` and
`third_party/mame-mpf2` git submodules, branches `irix` and `mpf2`) is **the
published, consumable form** — one commit per patch file. They are not two
independent copies to keep in sync by hand:

1. Edit the patch (here: `src/…/ctlsock.cpp` + `./regen-patch.sh`, or by hand
   for the other patches in `scripts/build-guests/*.patch`).
2. Apply the regenerated patch to a checkout of the fork and update the
   corresponding commit on its branch (`irix` or `mpf2`), then push.
3. Run `git submodule update --remote third_party/mame-irix` (or `-mpf2`) in
   this repo and commit the bumped gitlink.

Never edit the fork's checked-out tree directly and call that the source of
truth — the patch files are. `build-mame-irix.sh` / `build-mame-macos.sh` /
`build-mame-mpf2.sh` build from the submodule when it's initialized (the
patches already land as commits there) and fall back to a fresh upstream
clone + `patch -p1` from the loose `.patch` files otherwise — both paths
produce the same tree.

The OSD module that gives a MAME tile a unix control socket (`mamectl/1`:
pointer, keys, buttons, savestate verbs) and runs the MOVEA closed loop that
puts the guest cursor under the visitor's cursor. It replaced the Lua
`irixagent.lua` agent and its 1 kHz command-file poll.

**`src/` is the source of truth.** `scripts/build-guests/patches/mame-ctlsock.patch`
is GENERATED from it by `regen-patch.sh` — never hand-edit the patch.

    src/osd/modules/ctlsock/    the module — ctlsock.cpp is the whole engine
    a/                          the three UPSTREAM files the module has to
                                touch (modules.lua, osdobj_common.cpp,
                                save.cpp), pristine
    b/                          those same three, edited
    regen-patch.sh              a/ + b/ + src/  ->  ../mame-ctlsock.patch
    build-module.sh             apply the stack + build, ON the box
    BUILD-NOTES.md              build-phase history and the flag set

`a/` and `b/` exist because those three hunks are a DIFF against stock MAME:
keeping the pristine side in the repo is what lets the patch be regenerated
without a MAME checkout. They hold ONLY those three files. The module's own
sources are emitted whole from `src/` against /dev/null and are deliberately
not duplicated under `b/` — two copies of a 2900-line file in one repo is an
invitation to edit the wrong one.

## Iterating on the engine

Edit `src/…/ctlsock.cpp`, then:

    ./regen-patch.sh                                  # patch <- src
    scp mame-ctlsock.patch lab:/root/mame-stack-v3/
    ssh lab '/root/build-module.sh /data/vms/soltest/movea-v2-build/sgi-vN'

`build-module.sh` applies the full 14-patch stack to the pinned trixie chroot
tree, builds, and restores the tree on EVERY exit — a failed run that leaves
the stack applied poisons the next one with "TREE NOT PRISTINE".

## Deploying does NOT need a golden rebake

MAME validates a savestate against its registration signature, which `STAT`
reports as `sig=`/`entries=`. COVENANT 1 in the module header keeps every
byte of engine state OUT of the save registration, so the signature is
invariant across engine versions — `2236991a`/`3897` has held from v1 to
today. `x11-runtime.sh` guards on the MAME binary's md5, which is a
conservative belt on top of that, so an engine iteration is:

    systemctl stop streamhost@irix
    install -m 755 sgi-vN "$A/mame/sgi"
    sed -i "1i $(md5sum "$A/mame/sgi")" "$A/state/provenance-golden.md5"
    systemctl start streamhost@irix        # ~20 s, no rebake

A rebake is mandatory only when the signature actually moves: a second
persistent timer, a renamed module class, or any device/machine-config
change. Check `STAT sig=` after the restart — if it changed, rebake.

`mame-vc2-cursor-swap.patch` is exactly such a change: it adds three save
items to the VC2 so the cursor hotspot can be read (see the block over
`glyph_sample`), which moved the signature from `2236991a`/3897 to
`3f091a26`/3900 and required one rebake. Anything touching a device's save
registration costs the same.

## Verifying the sensors resolved

The module logs one setup line to `mame.log`:

    ctlsock: setup btns=1 axes=1 movea=1 devxy=1 glyph=1/32768 sig=… entries=…

`movea=0` means the cursor registers did not resolve and MOVEA degrades to
open-loop dead reckoning; `glyph=0/0` means the sprite items did not resolve
and the glyph-hotspot measurement is off, so the pointer lands a hotspot off
under any non-arrow cursor. Both are silent failures without this line —
`save_pointer(NAME(&m_ram[0]), …)` registers the item as `&m_ram[0]`,
ampersand and subscript included, which is exactly the kind of typo the line
exists to catch.
