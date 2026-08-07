# QNX Neutrino 6.5 `galleryhid` spike

QNX analogue of `streamhost/guest-agents/solaris-galleryhid/`. The intended
driver supplies only an absolute pointer over `gallery-hid-pci` (`1b36:0015`);
the keyboard remains on the stock PS/2 path.

## Status: abs-Y GO; driver implementation partial

The decisive Photon output-path gate passed on the namespaced 640x480 clone
`/data/vms/soltest/qnx-ghid-spike-3112` (VMID 3112). The full PCI module is
design source only: it has not been compiled, loaded, or framebuffer-verified.

Preflight, captured in `evidence/preflight-qcc-ddk.png`:

- `which qcc` and `which gcc`: both absent, return code 1.
- `/usr/include/devi.h` and `/usr/include/sys/devi.h`: both absent, `ls` return
  code 2.
- The official QNX 6.5 SDP installer reached its license-key prompt. No license
  was available or bypassed. QNX documents the Input DDK as a separate download,
  so the SDP alone would not provide the required DDK source/header set.

Consequently the requested custom `fake-abs.so` could not be built. To keep the
gate focused on the actual uncertainty, the clone instead used a fake host-side
Elo SmartSet serial source feeding the shipping `devi-elo` protocol module:

    devi-elo -G smartset -R fd -d/dev/ser1 -s abs -c &

This exercises the same decisive output stage as the planned module:
`packet_abs` -> stock `abs` filter -> Photon. It does not prove that the
uncompiled custom module ABI or PCI front end is correct.

## Framebuffer evidence

All results below are screendumps, not log inference.

| Test | Commanded result | Framebuffer result | Evidence |
|---|---|---|---|
| Centre | `(320,240)` | Cursor at centre | `evidence/abs-center.png` |
| Four corners | `(30,30)`, `(610,30)`, `(30,455)`, `(610,455)` | Cursor at all four positions; top and bottom Y are distinct | `evidence/abs-corners.png` |
| Press hit-test | tap `(560,427)` | The Volume widget at Y=427 expanded | `evidence/abs-click-volume-Y427.png` |
| Drag | `(260,35)` to `(120,160)` | Window moved with the pointer | `evidence/abs-drag-window.png` |

Button-free streaming samples also moved the cursor. The result is therefore a
hard **GO for the Photon absolute-Y output path** and retires the earlier
`usb-tablet`/`devi-hid` result as path-specific. The `packet_rel` fallback and
AROS fallback were not needed.

## Driver source and remaining work

`galleryhid.c` is an unbuilt porting draft containing PCI attach, BAR mapping,
the gallery-hid ready/epoch handshake, interrupt-driven ring drain, 16-byte
`POINTER_ABS_STATE` decode, and `packet_abs` forwarding. Its documented
`input_module_t` layout and callbacks were reconciled against the published QNX
6.5 Input DDK guide, but the following still require the actual DDK and its
sample sources:

- compile and correct any QNX 6.5 PCI/Input-DDK ABI differences;
- confirm the shared-module export/loader convention;
- verify interrupt threading and filter up-calls in the real runtime;
- build the second ATAPI source ISO, cold-boot the changed device set, and bake
  a fresh clone-only golden;
- inject gallery-hid records and framebuffer-verify the PCI path end to end.

Build only after supplying a licensed QNX 6.5 SDP and the separate Input DDK:

    source /path/to/qnx650-env.sh
    make

The full streamhost test also depends on the native `GalleryHidSink` and
`SH_INPUT_BACKEND=gallery` work landing from the `ghid-native-sink` worktree.
That dependency is owned by the orchestrator; it is intentionally not copied or
landed here.

## Files

- `galleryhid.c`, `Makefile`: unbuilt PCI driver draft and cross-build recipe.
- `elo_ctrl.py`, `verify_abs.py`, `ctrl.py`, `qmphelp.py`: fake Elo/QMP spike
  harness.
- `evidence/`: framebuffer proof and preflight screendump.

Do not promote this to the live QNX tile yet. Iterate on a namespaced clone once
the licensed SDP and Input DDK are available; the live device set and golden
must remain untouched until an explicit orchestrator/user promotion decision.
