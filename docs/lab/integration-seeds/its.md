# Integration seed — MIT ITS on PDP-10

Tracking: #61  
Prep branch: `its`  
Exhibition copy: `docs/lab/spa-drafts/its.md`

## Proposed station shape

- **station id:** `its`
- **runtime:** SIMH-built ITS + separate telnet terminal inside nspawn/Xvfb
- **closest sibling:** `medley`
- **scene archetype:** `mono-terminal`
- **preferred emulator for first wave:** SIMH, because the maintained ITS project builds it automatically and publishes a clean user terminal on TCP 10004
- **operator console:** hidden
- **visitor terminal:** xterm/VT52-style client connected to the ITS user port

KLH10 remains a valid fallback, but SIMH has the cleanest documented build+terminal path for this station.

## Start here

```bash
scripts/dev/wt.sh new its-work --from origin/its
cd ../its-work
scripts/dev/wave.sh alloc its
python3 scripts/stations-registry.py new its   --like medley --production --slot auto
```

Change archetype to `mono-terminal`, keep nspawn/X11 capture, replace Medley with the ITS build output + terminal client.

## Source/media acquisition

The maintained ITS repository builds the system from source:

```bash
git clone --recursive https://github.com/PDP-10/its.git
cd its
make EMULATOR=simh
```

Pin the git commit in the builder. The resulting `out/` directory contains the generated ITS disk images and emulator artifacts.

This is preferable to importing a mystery prebuilt disk: the upstream project explicitly aims for a full automated build.

## First smoke command

After a successful build:

```bash
./start
```

If the console needs the documented bootstrap dance:

1. at simulator/boot prompt type `its`
2. press Escape-G when requested
3. wait for `SYSTEM JOB USING THIS CONSOLE`
4. Ctrl-Z logs in

Do not publish that console, because daemon messages share it.

## Visitor terminal

With the SIMH configuration from the maintained project, connect a separate terminal to **port 10004**:

```bash
telnet 127.0.0.1 10004
```

For the gallery:

```bash
DISPLAY=:<display> xterm -geometry 100x32 -e telnet 127.0.0.1 10004
```

Press Ctrl-Z in that terminal to log in.

If a VT52 terminal emulator gives visibly better fidelity and key mapping, use it instead of xterm once the plain telnet proof works.

## Container/runtime plan

The inner script should:
1. copy/build or stage the pinned `out/` system
2. start ITS/SIMH
3. poll TCP 10004
4. launch the fullscreen visitor terminal
5. supervise both processes

Build time should **not** happen on every station launch. The builder produces the disk/emulator artifacts; runtime only starts them.

## Intended rest scene

A logged-in DDT session or an early Emacs screen.

Preferred first demo:
- Ctrl-Z login
- start Emacs or inspect a file
- show one ITS-specific command
- reset

Keep special control-key help in the UI; do not alter ITS itself.

## Reset strategy

Relaunch from a pristine copy of the built ITS disk(s). A clean relaunch is preferable to snapshotting simulator process state.

## Proof checklist

- [ ] pinned upstream commit builds with `make EMULATOR=simh`
- [ ] `./start` reaches ITS unattended or with scripted bootstrap
- [ ] TCP 10004 visitor terminal works
- [ ] Ctrl-Z and Escape/control mappings work through browser keyboard path
- [ ] relaunch returns to clean DDT/login
- [ ] simulator console remains hidden
- [ ] measured build time and launch-to-terminal time recorded

## TOPS-20 fallback

If ITS itself becomes the wall, do not silently replace it in this issue. The Panda/TOPS-20 distribution is a separate historically valuable exhibit and should get its own station id/poster if chosen.
