# win95-clean — the clean-desktop golden re-bake pipeline (win95 boot video)

Byte-copies of the four `/root/win95-clean-*.sh` scripts that produced the
win95 tile's current clean-desktop golden + boot video (landed 2026-07-13;
`goldenSha 48edfc63…` in `/boot/index.json`). They implement the disk-side
portion of `../win95-zero-input-prep.md` and hand off to `../record-boot.sh`.

Order (all on the box; never touches the live tile until the final swap):

1. `win95-clean-offline-prep.sh` — copy the live golden to
   `/data/vms/soltest/win95-clean-prep/`, then offline via qemu-nbd: empty the
   `WIN.INI [windows] run=` line (kills the Notepad auto-launch) + clear
   StartUp `.lnk/.pif`.
2. `win95-clean-build-launch.sh` — rewrite the live launcher for the prep
   clone (same device set, cold boot, hostfwd 57791→59791) and boot it; the
   GUI-side prep (Primary Network Logon → "Windows Logon", clean shutdown) is
   done here per the prep notes.
3. `win95-clean-stage.sh` — stage the prepped disk + a Tier-2
   `boot-ref-desktop.png` under `/data/vms/soltest/win95-clean-stage/win95/`
   as a `BOOTREC_TILES_ROOT` override for `record-boot.sh win95` (which then
   records, bakes `savevm golden`, and verifies on the clone).
4. `win95-clean-swap.sh` — PHASE B: stop daemon, kill live QEMU by pidfile,
   back up the live golden, swap in the validated clone golden, relaunch.
   **One-shot as written**: `CLONE_GOLDEN` is hardcoded to the specific
   validated bootrec clone dir (`bootrec-win95-4037869`) — point it at your
   new clone's disk before reuse.
