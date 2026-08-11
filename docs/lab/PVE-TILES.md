# Proxmox-backed streamhost stations

PVE-backed stations use the normal streamhost capture and input path. PVE launches
and owns QEMU; streamhost attaches to a dedicated second QMP socket and asks
QEMU's D-Bus display for the framebuffer, audio, keyboard, and pointer objects.
There is no VNC/SPICE bridge and no QEMU launcher in the station directory.

The second QMP is intentional. PVE's primary monitor belongs to `pvedaemon` and
`qmeventd`; sharing it would introduce client contention. The only runtime
coupling is `/data/vms/streamhost/tiles/<tile>/qmp.sock`.

## Add a PVE station

1. Build the VM on the PVE host. For a Linux ISO or existing disk, use
   `scripts/provision/pve-tiles/linux.sh` with a fresh VMID. Heavy operating systems may
   use their own gated builder, but must add the same display and QMP arguments:

   ```bash
   qm set <vmid> --vga std --args \
     "-display dbus,p2p=on -qmp unix:/data/vms/streamhost/tiles/<tile>/qmp.sock,server=on,wait=off"
   ```

   Valid VGA choices are `std`, `vmware`, and `qxl`. For audio, use
   `-display dbus,p2p=on,audiodev=snd0` plus
   `-audiodev dbus,id=snd0 -device intel-hda -device
   hda-output,audiodev=snd0`.

2. Capture the device ledger after the final `qm set`:

   ```bash
   qm config <vmid>
   ```

   Put those output lines in `runtime.qemu.deviceSetSummary`. The PVE config is
   the device ledger; do not create a stand-in launcher. Never commit or print
   secret-bearing argument values (for example an OSK or product key): replace
   only that value with its opaque credential reference.

3. Add the registry entry with `runtime.qemu.mode: "pve"`, the VMID, PVE emit
   arguments, and the PVE reset policy. A minimal runtime fragment is:

   ```json
   {
     "runtime": {
       "pve": { "vmid": 990 },
       "qemu": {
         "mode": "pve",
         "emitArgs": [
           "--tile", "example", "--udp", "54990",
           "--pointer", "abs", "--audio", "off", "--fps", "60",
           "--pve-vmid", "990"
         ],
         "deviceSetId": "example-pve-v1",
         "deviceSetSummary": ["args: ...", "boot: order=ide0", "..."],
         "launcherParity": {
           "status": "hand-managed",
           "reason": "PVE config is the authoritative device ledger"
         }
       },
       "tileEnv": {
         "SH_TILE": "example",
         "SH_QMP": "/data/vms/streamhost/tiles/example/qmp.sock",
         "SH_QEMU_MODE": "pve",
         "SH_PVE_VMID": "990",
         "SH_QEMU_PIDFILE": "/var/run/qemu-server/990.pid"
       }
     },
     "reset": {
       "tileDir": "example",
       "resetMode": "pve-rollback",
       "snapshot": "golden"
     }
   }
   ```

   The real entry also carries the usual stream, museum, UI, operator, build,
   and render fields. PVE mode requires `runtime.pve.vmid` and forbids
   `runtime.qemu.launcher`.

4. Generate and install the non-Rust artifacts:

   ```bash
   make station-registry-generate
   make station-registry-check
   bash streamhost/stations-manifest.sh
   ```

   The emitter writes `tile.env` and `ROLLBACK.md`, and emits no
   `qemu-streamhost.sh`. `SH_QEMU_PIDFILE` points the streamhost RSS guard at
   PVE's `/var/run/qemu-server/<vmid>.pid`.

5. Start the VM, curate the guest, and create its one-time checkpoint RAM snapshot:

   ```bash
   qm start <vmid>
   qm snapshot <vmid> golden --vmstate 1
   systemctl enable --now streamhost@<tile>.service
   ```

   `ExecStartPre` starts a stopped VM and waits up to 30 seconds for the
   dedicated QMP. Restarting or stopping only the daemon never restarts or
   stops the PVE guest.

6. Prove the station through the streamed framebuffer: connect a WebTransport
   client, assert decoded non-blank pixels, inject keyboard and pointer input,
   and assert the resulting streamed-frame change. Then run
   `scripts/serve/reset-tile.sh <os-id>` and assert the streamed framebuffer
   returns to the checkpoint state. Disk state or service logs are not a substitute
   for this check. `scripts/e2e/direct-stream-proof.mjs` is the catalog-free
   framebuffer/keyboard harness for a throwaway station's `signaling.json`.

## Heavy exhibits

This mode readmits the deleted macOS VM 925 and Windows 11 VM 900 exhibits as
first-class streamed stations. Their existing builders remain separate, gated
workflows because they involve licensed media, platform-specific firmware,
and substantially heavier resources. When intentionally rebuilt, add the same
dedicated D-Bus display/QMP arguments and follow the six steps above; do not
reuse those VMIDs for proof or development VMs.
