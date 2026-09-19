# Integration seed — Symbolics Genera / Open Genera

Tracking: #57  
Prep branch: `genera`  
Exhibition copy: `docs/lab/spa-drafts/genera.md`

## Proposed station shape

- **station id:** `genera`
- **runtime:** Open Genera VLM inside the host-application/nspawn + Xvfb path
- **closest sibling:** `medley`
- **scene archetype:** `beige-tower-crt`
- **capture/input:** X11 root capture + XTEST absolute pointer/keyboard
- **network:** off for the first smoke; add only after the X screen is stable
- **reset:** relaunch from a pristine saved world / VLM disk set

This is structurally much closer to Medley than to an emulated workstation: a host Linux process produces the Lisp-machine display.

## Start here

```bash
scripts/dev/wt.sh new genera-work --from origin/genera
cd ../genera-work
scripts/dev/wave.sh alloc genera
python3 scripts/stations-registry.py new genera   --like medley --production --slot auto
```

Keep the Medley nspawn/Xvfb/XTEST architecture. Replace only the inner application and assets.

## Media/runtime acquisition

Use the OG2VLM setup path:

- setup project: https://github.com/JMlisp/og2vlm
- Open Genera archive: `opengenera2.tar.bz2`
- known MD5 from the setup guide: `753411fbf964b15369b3a46997100ffa`
- VLM kit supplies x86/Xeon `genera` binaries, `.VLM` template, fonts and helper material
- use the supplied `Genera-8-5e.vlod`/prepared-world path for the first smoke

The builder should stage:
- VLM binary
- `.VLM`
- chosen `.vlod` world
- FEP/LMFS disk files if that world requires them
- Genera X fonts
- X keyboard mapping

Pin all of these by hash.

## First smoke setup

Inside a disposable Debian/nspawn root:

```bash
mkdir -p ~/vlm ~/og2
# unpack og2vlm kit into staging
# choose genera-x86 or genera-xeon according to the labhost CPU
cp genera-x86 ~/vlm/genera
chmod 755 ~/vlm/genera
cp dot.VLM ~/vlm/.VLM
# edit .VLM to point at the prepared Genera-8-5e world
```

Install fonts into the container and run `mkfontdir`, then under Xvfb:

```bash
export DISPLAY=:<display>
xset fp+ /usr/share/fonts/genera
xmodmap -e 'keysym Alt_L = Meta_L Alt_L'
xmodmap -e 'add mod1 = Meta_L'
cd ~/vlm
./genera
```

Do **not** start with TAP/NFS/network setup. First prove a local X screen, Lisp Listener and mouse/keyboard.

## Station launcher

Adapt `medley/nspawn-inner.sh`:

1. start/prepare Xvfb outside the container as the shared runtime already does
2. enter nspawn
3. add Genera fonts to the X server path
4. run the VLM against a station-private copy of the world/disk set
5. if the VLM exits, the whole station exits and relaunches

The visitor framebuffer must be the Genera X screen, not Debian LXDE or a host terminal.

## Input concerns

Genera expects a richer keyboard than a PC:
- Meta must work
- Control must work
- Function keys used by Genera commands should be mapped
- ordinary text input must not lose modifier state

Start with the og2vlm PC keyboard Xmodmap and then add an on-screen-keyboard profile for missing Symbolics keys only if a real workflow needs them.

## Intended rest scene

A Dynamic Lisp Listener plus Zmacs/Inspector or another unmistakable Genera window.

Guided demo:
1. evaluate a small Lisp expression in the Listener,
2. open/activate Zmacs or Inspector,
3. reset to the pristine world.

## Proof checklist

- [ ] VLM starts inside isolated container
- [ ] native Genera X screen visible under Xvfb
- [ ] Meta/Control/text input proven
- [ ] absolute pointer proven
- [ ] relaunch returns to the same saved world
- [ ] no Debian desktop/window chrome is visible
- [ ] final world/VLM hashes recorded

## Stop condition

If the prepared OG2 world cannot launch without extensive FEP/LMFS reconstruction, prove the supplied setup guide once in a scratch VM/container before writing any Kernel Hive-specific VLM patches.
