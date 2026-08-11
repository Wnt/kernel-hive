# NT4 Cirrus loadvm corruption — vmstate root cause + fix (angle: trace)

Date: 2026-07-28. Verdict: **FIXED and proven** (framebuffer byte-identical on
KVM + TCG, 3x each). Patch: `streamhost/qemu-patches/0005-cirrus-isa-vmstate-descend-substruct.patch`.

## The bug

nt4's i440fx + ISA-Cirrus hybrid (`-machine pc-i440fx-11.0,vmport=on`,
`-device isa-cirrus-vga,global-vmstate=on`, 1024x768x16bpp) cold-boots to a
clean desktop, but `-loadvm golden` deterministically restored a blue/lavender
framebuffer on BOTH KVM and TCG. Second, distinct Cirrus bug (independent of the
already-deployed ROP1-fill fix `0004`).

## Root cause (traced, not guessed)

The ISA Cirrus device class sets `dc->vmsd = &vmstate_cirrus_vga` **directly**.
`vmstate_cirrus_vga`'s fields are declared against `CirrusVGAState`
(`VMSTATE_UINT8(cirrus_hidden_dac_data, CirrusVGAState)`, …), but a device's
`dc->vmsd` is resolved against the **device object**. The ISA device object is:

```c
struct ISACirrusVGAState { ISADevice parent_obj; CirrusVGAState cirrus_vga; };
```

so `cirrus_vga` sits **160 bytes** past the device base (measured on this
build). Every vmstate field therefore saved/restored 160 bytes off. The PCI
variant avoids this with a wrapper (`vmstate_pci_cirrus_vga` →
`VMSTATE_STRUCT(cirrus_vga, PCICirrusVGAState, 0, vmstate_cirrus_vga, …)`); the
ISA device was simply **missing its wrapper**.

### Instrumented trace (three points: pre-save, serialized, post-load)

Dumped the full Cirrus/VGA state (CRTC/SEQ/GR/AR, the hidden DAC, shadow GRs,
bank map, geometry, and a full-vram FNV hash) at savevm `pre_save` and loadvm
`post_load`, plus the live draw-time format decision in `vga_draw_graphic`.

Baseline (no fix), fresh-process `-loadvm golden`, real device pointer:

| field | pre-save (correct) | post-load (corrupt) |
|---|---|---|
| `get_bpp` | **16** (565) | **15** (555) |
| `cirrus_hidden_dac_data` | **0xe1** (`&0xf=1`→565) | **0x00** (reset) |
| `cirrus_hidden_dac_lockindex` | 0 | 5 (reset) |
| `sr[0x07]`, SR/GR/CR banks, resolution, `line_offset`, vram FNV hash | (all) | **identical** |

So the vram content and the VGACommonState-relative registers round-tripped, but
the **hidden-DAC depth selector** (a `CirrusVGAState`-direct field) was lost.
`cirrus_get_bpp16_depth()` then fell back 16bpp(565)→15bpp(555), reinterpreting
the restored framebuffer one green-bit off = the blue/lavender corruption.

Confirming the mechanism: a delta probe printed
`g_cirrus_dbg - vmstate_opaque = 160` in both `pre_save` and `post_load`, and
`dac_via_opaque=0x00` vs `dac_via_real=0xe1` at save — i.e. the framework read
the DAC from the wrong (160-early) location. Why SR still round-tripped while
the DAC did not: the VGACommonState fields' offsets-from-the-wrong-base happened
to land on stable overlapping memory, so they survived; the far-out
cirrus-direct fields did not. This is also why the low-colour **nt351**
(isapc + isa-cirrus) station's `loadvm golden` looked byte-identical — it never
exercised the hi-colour hidden-DAC path.

## The fix

Mirror the PCI variant: give the ISA device a wrapper vmsd that descends into
the embedded `cirrus_vga` so the substate opaque is the real `CirrusVGAState`.

```c
static const VMStateDescription vmstate_isa_cirrus_vga = {
    .name = "cirrus_vga", .version_id = 2, .minimum_version_id = 1,
    .fields = (const VMStateField[]) {
        VMSTATE_STRUCT(cirrus_vga, ISACirrusVGAState, 0,
                       vmstate_cirrus_vga, CirrusVGAState),
        VMSTATE_END_OF_LIST()
    }
};
...
dc->vmsd = &vmstate_isa_cirrus_vga;
```

Wire format and section name (`"cirrus_vga"`) are unchanged; the inner VMSD's
`.post_load` (`cirrus_post_load`) still runs. After the fix the probe shows
`delta=0`, DAC restores to `0xe1`, `get_bpp=16`.

## Build + acceptance

- Base: labhost `pve-qemu-kvm-11.0.2` source (debian series applied) + ROP1 patch
  `0004` + this fix. Minimal `--target-list=i386-softmmu` build.
- Deterministic repro without an NT4 install: a 512-byte bootsector sets VBE
  mode `0x117` (1024x768x16bpp 565 — the exact Cirrus hi-colour hidden-DAC
  path NT4's 544x driver uses) and fills vram with per-bank colour bands, on the
  identical device set (`isa-cirrus-vga,global-vmstate=on`, i440fx, vmport).
- Acceptance: cold-boot → `savevm golden` → fresh-process `-loadvm golden`
  screendump, **3x each on KVM and TCG**. All eight PPMs byte-identical
  (`sha256 38fb575f98d92416c27bb7fe368cba39017e145824b8ca4980a0107d23616286`):
  presave == every loadvm restore. Baseline (no fix) loadvm =
  `4bef18831de203df…` (the corrupt 555 render).

Proof PNGs: `docs/lab/nt4-cirrus-vmstate-proofs/`
(`01` presave-correct, `02` baseline-loadvm-CORRUPT, `03/04` fixed KVM/TCG).

## Notes for convergence

- The fix is display-vmstate-only; orthogonal to the ROP1 fill fix (both are
  compiled into the validated binary) and to vmmouse (input path untouched).
- Repro used the exact hybrid device set from `nt4-cirrus-hires-investigation.md`
  minus `-device vmmouse` (needs an i8042 link not relevant to the display bug).
- To promote nt4: build labhost QEMU with `0004`+`0005`, then recapture the nt4
  checkpoint with the fixed binary (the pre-fix checkpoint was saved with the buggy
  vmstate and must be re-savevm'd, not reused).
- This is a genuine upstream QEMU bug (`isa-cirrus-vga` migration/snapshot);
  the patch is submittable upstream as-is.

## Independent convergence (three parallel angles, 2026-07-28)

This fix was reached by three bounded parallel agents (method:
[HARD-PROBLEM-METHODOLOGY.md](HARD-PROBLEM-METHODOLOGY.md)); the `trace` angle
above is the canonical writeup, and the other two corroborate it:

- **`hypofix` (independent PASS).** Blind to the trace work, it reached the
  *identical* root cause and *byte-identical* code change (`vmstate_isa_cirrus_vga`
  wrapper via `VMSTATE_STRUCT`). It also empirically ruled out the two "obvious"
  hypofix targets — `cirrus_post_load` already does the full-invalidate +
  `graphic_mode=-1` refresh, and no mode-determining register was missing from
  the vmstate — so the defect is *only* the wrong vmstate opaque. Proven
  byte-identical loadvm on KVM+TCG on its own clone. Two blind angles landing on
  the same line is strong confirmation the fix is correct and complete.
- **`upstream` (FAIL — nothing to backport).** Diffed the exact Cirrus
  vmstate/restore path against a clean upstream master already built on the box
  (`v11.0.0-3298-g299e7557ed`): the code is semantically identical (only API
  renames + two 24bpp-only ROP fixes since v11.0.0). `git log v11.0.0..HEAD` and
  `cirrus_post_load` history (last semantic change years ago, `b7ee9e4970`)
  confirm this is a **long-standing latent bug, not a regression** — there is no
  good version to bisect to, and a clean upstream build reproduces it. So the
  patch must be (and is) authored fresh.

## Deploy / promote checklist (nt4 → 1024×768×16bpp)

1. Rebuild the pinned `/opt/qemu-cirrusfix` QEMU with the full display series
   `0003`+`0004`+`0005` (0005 is display-vmstate-only; strictly additive to the
   ROP1 binary nt351 already runs). Back up the current binary paired with the
   checkpoint(s) it captured.
2. **nt351 is the only other `isa-cirrus-vga` production station.** Its existing
   checkpoint was `savevm`'d under the buggy vmstate and is self-consistent only with
   the *buggy* binary — loading it under the fixed binary restores garbage. If
   `/opt/qemu-cirrusfix` is rebuilt in place, **nt351's checkpoint must be recaptured**
   (cold-boot → clean → `savevm golden`) under the fixed binary and verified live
   before touching nt4. (In practice nt351's live reset is an in-process `loadvm`
   whose correct-offset DAC was set at cold boot, which is why the corruption was
   never visible on nt351 — but a fresh-process service restart would hit it.)
3. Re-create the nt4 1024×768×16bpp Cirrus checkpoint (the reaped candidate must be
   rebuilt per `nt4-cirrus-hires-investigation.md`: NT4 SP6 `cirrus.sys`/
   `cirrus.dll`, select the CL 5430 1024×768×16 mode), `savevm golden` under the
   fixed binary, verify fresh-process `-loadvm golden` byte-identical + the
   adversarial scroll/drag repro clean + vmmouse 1:1 (the cold-boot recipe
   already proved 1:1 within 1px).
4. Promote nt4: launcher → `/opt/qemu-cirrusfix/bin/qemu-system-i386
   -L /usr/share/kvm` with the hybrid device set; registry `1024×768`/`65536`
   colors + `deviceSetId`; `docs/guests/nt4.md`; regenerate; drift-clean; restart
   `streamhost@nt4`; live-verify in the UI.
