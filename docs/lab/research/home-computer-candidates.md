# Home-computer candidates: Commodore, the Britons, and the GDR

Status: **research, 2026-08-08 — one machine has since been built.** This is the
feasibility study behind an operator-proposed expansion of the lineup, in the
form [`ADD-NEW-OS-PLAYBOOK.md`](../ADD-NEW-OS-PLAYBOOK.md) §1 expects.

**Built since:** the **VIC-20** (§4.1) is live as the production station `vic20`
(slot 85, udp 54085) — see [`docs/guests/vic20.md`](../../guests/vic20.md). It
was taken first because it is the cheapest item in the whole study: `xvic` is
already in the frozen bridge base (VICE is built from source there for the `c64`
station and `make install` ships the entire family), VICE bundles the Commodore
ROMs, and an unexpanded VIC-20 needs no media at all — so it required no staged
asset, no checksum gate and no new emulator build, only a launcher, a checkpoint and
a registry entry. §2's "VICE covers the whole Commodore 8-bit wishlist" claim is
now proven rather than predicted. Two costs the study did not predict are
recorded in the guest doc: VICE segfaults when its stdout is not a terminal, and
the base's installed VIC20 ROM set is missing its BASIC ROM. Everything else
below remains unbuilt.

Companion study for the minicomputer end of the same wishlist:
[`pdp11-add.md`](pdp11-add.md).

Headline findings:

1. **Emulation is not the constraint.** MAME 0.276 is already installed on
   labhost (`/usr/games/mame`) and its driver list, queried directly, contains
   *every* machine on the wishlist — including the regional VIC-20 and C64
   variants, all four big Amigas, the Acorn/Archimedes line, the whole Sinclair
   line, and the GDR machines.
2. **Memory is the constraint.** Measured RSS of the six live kiosks is
   0.70–1.65 GB each (mean ≈ 1.2 GB). labhost has ~40 GB available. Thirty more
   stations at the measured mean is ~36 GB — the lineup is **memory-bound long
   before it is effort-bound**. §6 costs this properly.
3. **Most of the collector-level variants are not separate exhibits.** Keyboard
   mould and label variants are invisible to an emulator; regional variants
   (VIC-1001, VIC-20 SE, C64 SE) differ in *charset ROM and keyboard layout*,
   which this repo can already express per station. §3 proposes the policy.
4. **The engineering work is one shared builder, not thirty scripts.** After
   `mpf2` the MAME-in-a-kiosk pattern is proven; the leverage is a
   registry-parameterised `mame-bridge.sh`. §5.

## 1. What the lineup already has

| Station | Machine | Backend |
|---|---|---|
| `c64` | Commodore 64 (breadbin) — GEOS 2.0, 1982 | VICE `x64sc`, built from source in the bridge base |
| `amiga` | Amiga 500 — Workbench 1.3, 1987 | FS-UAE, installed into the station overlay |
| `aros` | AROS on x86 | native QEMU — *not* a 68k Amiga |
| `atarist` | Atari ST — EmuTOS GEM, 1985 | hatari |
| `apple2` | Apple II — GEOS, 1988 | LinApple |
| `amstradcpc` | Amstrad CPC 6128 — Locomotive BASIC, 1985 | cap32 |
| `mpf2` | Multitech Microprofessor II, 1982 | **MAME** in a kiosk |

So: Amstrad is covered (CPC 6128). Commodore is covered only at the C64/A500
midpoint. Everything else on the wishlist is new.

## 2. Backend strategy

Three emulators, chosen per family, all inside the existing captured-Linux
bridge pattern (`streamhost/docs/BRIDGE.md`):

- **VICE** for the Commodore 8-bits. One codebase covers PET (`xpet`), VIC-20
  (`xvic`), C64 (`x64sc`), C128 (`x128`), the 264 line (`xplus4`) and CBM-II
  (`xcbm2`). Decisively: **upstream VICE source bundles the Commodore ROMs**,
  which is precisely why Debian cannot ship it and why `bridge-base.sh` already
  builds it from source. The C64 station's ROM problem is therefore already solved
  for the *entire* Commodore 8-bit wishlist except the KIM-1.
- **MAME** for everything VICE does not cover: KIM-1, the Britons, the GDR
  machines, and the big Amigas if FS-UAE is not used. Already on labhost, and
  the daemon already has MAME-specific input plumbing
  (`SH_INPUT_BACKEND=mamecmd`/`mamesock`, `mame_input.rs`, `scripts/build-guests/emulators/mamectl`).
- **FS-UAE** for the Amigas, continuing the `amiga` station's path. Its model list
  covers A1000, A3000, A4000 and A4000T — but **not the A2000** (§4.4).

Specialist alternatives exist per family (XRoar for Dragon, Oricutron for Oric,
B-Em/BeebEm for the BBC, Arculator/RPCEmu/ArcEm for Archimedes, Fuse for
Spectrum, sQLux for the QL, KCemu for KC 85). They are generally more accurate
for *games*; for a museum exhibit that must reach one deterministic idle screen
and survive `loadvm golden`, the operational cost of five more emulators
outweighs it. **Default to MAME/VICE; reach for a specialist only where MAME's
driver is demonstrably not good enough** — Archimedes is the one place that is
a live question (§4.7).

## 3. Variant policy — the part the wishlist forces us to decide

The wishlist asks for machines at collector granularity: VIC-20 label types,
printed versus moulded keycaps, both C64 case forms. In emulation those
distinctions collapse, but not all of them, and this repo happens to have the
machinery for the ones that survive:

| Kind of variant | Visible in emulation? | Proposed treatment |
|---|---|---|
| Case form (C64 breadbin vs C64C, PET chiclet vs full keyboard) | No — identical stream | **The 3D scene, not a second station.** `spa/src/scene/machines.ts` binds one assembly per station, so a second case form is a modelling job, or a poster (`registry/posters/`). A second stream of the same emulator is pure waste. |
| Keycap print vs mould, badge/label revisions | No | **Placard text and a photograph.** `museum.notes` / poster prose. |
| Regional ROM + keyboard (VIC-1001 Japan, VIC-20 SE, C64 SE, C128 DE/SE, QL SE) | **Yes** — different charset ROM, different key matrix | **A real station is defensible**, and the repo already supports the hard part: `spa.demoProgram.keyMap` and `SH_KEY_MAP` remap ASCII to a guest's own matrix (the MPF-II add proved this), and `keyboardProfiles.ts` gives it the right on-screen keyboard. A VIC-1001 typing katakana is a genuinely different exhibit. |
| Model generations (VIC-20 → C64 → C128; KC 85/2 → /3 → /4) | Yes | One station per generation where the *software* differs; otherwise pick the canonical one. |

Recommendation: **one station per machine-with-different-software**, regional and
cosmetic variants carried by placards, posters and scene assets. That turns a
~45-item wishlist into roughly 20 streamed stations plus a poster set.

## 4. Per-family findings

All driver short names below were verified against `/usr/games/mame -listfull`
on labhost (MAME 0.276), not from memory.

### 4.1 Commodore — the pre-64 machines

| Machine | Year | Driver / emulator | Notes |
|---|---|---|---|
| **KIM-1** | 1976 | MAME `kim1` | **No video at all**: six seven-segment LEDs and a hex keypad, which MAME renders as an artwork panel. A superb, genuinely strange exhibit — and the correct starting point for "everything Commodore", since MOS Technology's KIM-1 is what Commodore bought its way into. Keyboard-only, hex keypad → needs a `keyMap`. Pairs with the GDR **LC 80** (§4.9). |
| **PET 2001** | 1977 | MAME `pet2001`, `pet20018`; VICE `xpet` | The chiclet-keyboard original with the built-in cassette. Green phosphor, 40 columns. |
| **PET 2001-N / -B, CBM 3032, 4032 "Fat 40", 8032, 8296** | 1979–84 | `pet2001n`, `pet2001b`, `cbm3032`, `cbm4032f`, `cbm8032`, `cbm8296` (+ `_de`, `_se`, `_fr` regional sets) | The business line. `cbm8032` at 80 columns is the most "office computer" of them; the `_se`/`_de` sets show how far the regional ROM story goes. One station (`cbm8032`) plus placard coverage of the family is the sane call. |
| **VIC-20 (NTSC)** | 1980 | MAME `vic20`; VICE `xvic` | The first computer to sell a million. 22 columns, 5 KB. |
| **VC-20 / VIC-20 (PAL)** | 1981 | MAME `vic20p` | Same machine, European timing. Cosmetic in the stream → placard. |
| **VIC-1001 (Japan)** | 1980 | MAME `vic1001` | **Different charset ROM (katakana) and key legends** → a defensible separate station under §3, and a striking one. |
| **VIC-20 (Sweden/Finland)** | 1981 | MAME `vic20_se` | Swedish charset/keyboard (å ä ö). Local interest for this lab; same argument as above. |

### 4.2 Commodore 64 and 128

| Machine | Year | Driver | Notes |
|---|---|---|---|
| C64 breadbin | 1982 | live as `c64` | Already an exhibit (GEOS 2.0). |
| C64C / C64G | 1986/87 | `c64c`, `c64cp`, `c64g` | Same machine, wedge case (and later the 8580 SID's subtly different sound). **Scene asset or poster, not a station** (§3). |
| C64 SE / VIC-64S, C64 JP | 1983 | `c64_se`, `c64_jp` | Regional ROM variants; placard unless the Swedish keyboard is wanted as its own exhibit. |
| SX-64 Executive | 1984 | `sx64`, `sx64p` | The luggable with the built-in 5" CRT and drive. Visually unique → a good *scene* piece, and a plausible station if the exhibit shows it as a portable. |
| **C128** | 1985 | `c128`, `c128p`, `c128d`, `c128dcr`, `c128_de`, `c128_se`; VICE `x128` | **The strongest single candidate in the Commodore set.** Three machines in one box: native C128 mode with the VDC's 80-column RGBI output, C64 mode, and **CP/M on the Z80**. An exhibit that boots CP/M on a Commodore tells a story no other station in the lineup tells. |

### 4.3 The 264 line — C16, C116, Plus/4

| Machine | Year | Driver | Notes |
|---|---|---|---|
| **C16** | 1984 | `c16`, `c16p`, `c16_hu` | The budget machine aimed at the Sinclair/Spectrum end of the market. |
| **C116** | 1984 | `c116` | Rubber-keyed, Europe-only (chiefly Germany and Hungary) — the rarest of the three and the one a visitor will never have seen. |
| **Plus/4** | 1984 | `plus4`, `plus4p`; VICE `xplus4` | Built-in "3-plus-1" office software in ROM: word processor, spreadsheet, database, graphing. **That ROM software is the exhibit** — it is what makes the Plus/4 more than a failed C64. |

The story is worth getting right on the placard, because it explains the whole
line: the 264 family was developed as a cheap, TED-based answer to the low end,
Jack Tramiel **resigned from Commodore in January 1984** — before the machines
shipped — and what followed was a range that was incompatible with the C64,
priced against its own bestseller, and marketed by people who could not explain
what it was for. The C16 sold respectably in Europe against the Spectrum; the
Plus/4 is the canonical Commodore misfire. One station (Plus/4, for the ROM
software) plus C16/C116 as placard-and-poster coverage is the efficient split;
all three as stations is defensible if the line's *failure* is itself the exhibit.

### 4.4 Amiga 1000 / 2000 / 3000 / 4000

| Machine | Year | MAME | FS-UAE | Notes |
|---|---|---|---|---|
| **A1000** | 1985 | `a1000`, `a1000n` | yes | **The one to build.** Kickstart loads *from floppy* into writable control store — a boot sequence no later Amiga has, and a real exhibit moment. Signature-moulded case, garage for the keyboard. |
| A2000 | 1987 | `a2000`, `a2000n` | **no model** | An A500 chipset in a big Zorro box. FS-UAE cannot model it; MAME can. Lowest exhibit value of the four → poster. |
| **A3000** | 1990 | `a3000` | yes | 68030 + ECS, Kickstart 3.1, the Unix-capable one (Amiga UNIX / SVR4). A genuinely different exhibit from the A500. |
| **A4000** | 1992 | `a4000`, `a400030`, `a4000t` | yes | AGA chipset, Workbench 3.1 — the end of the line, and visually the most capable Amiga desktop. |

Kickstart ROMs are the gating input, exactly as for the existing `amiga` station:
licensed material fetched at build time, hash-verified, never committed
(`.gitignore` already covers `*.rom`, `*.adf`). The clean commercial path is
Cloanto **Amiga Forever** Plus/Premium, which licenses Kickstarts for every
supported model.

Recommendation: **A1000 first** (best story, cheapest media), **A4000 second**
(best desktop), A3000 optional, A2000 as a poster.

### 4.5 Dragon 32

MAME `dragon32` / `dragon64` (also `dragon200`, `dragon200e` for the Spanish
machines); specialist alternative **XRoar**, which is actively maintained with
SDL2. Welsh-built, 6809-based, near-compatible with the Tandy CoCo, Microsoft
Extended Color BASIC in ROM. ROMs are preservation-class: Dragon Data is long
gone, the BASIC lineage is Microsoft's. Tier 2, cheap.

### 4.6 Oric-1 and Oric Atmos

MAME `oric1` / `orica`; specialist alternative **Oricutron**. The Oric-1 (1983)
was the Spectrum's most direct British rival; the Atmos (1984) fixed the
keyboard and was a substantial success in France, where the machine has a
living scene to this day. One station (Atmos) plus a placard covering the Oric-1
is the efficient split.

### 4.7 Acorn — BBC Micro, Electron, and the ARM story

This family carries the single best narrative in the entire wishlist, and
labhost's MAME can already tell all three acts of it:

| Act | Machine | Driver |
|---|---|---|
| 1. The machine that taught Britain to program | **BBC Micro Model B** | `bbcb` (also `bbca`, `bbcbp`, `bbcm` Master 128, `bbcmc` Master Compact, `electron`) |
| 2. **The first ARM product ever sold** | **ARM Evaluation System** — an ARM 2nd processor on the BBC Micro's Tube | `bbc_tube_arm` (a Tube co-processor option on the `bbcb`/`bbcm` drivers), plus `bbcmarm` "BBC Master (ARM Evaluation)" and `aa500` "Acorn A500 Development System" |
| 3. The ARM desktop | **Archimedes A310**, RISC OS | `aa310` (also `aa305`, `aa440`, `aa3000`, `aa4`, `aa5000`) |

The anecdote the wishlist asks for is real and well documented: the first ARM
silicon arrived on **26 April 1985**, worked first time, and the ammeter in
series with its supply read **zero** — the development board had a fault and no
current was reaching the chip at all. It was running on leakage drawn through
its I/O lines. A processor designed by a team of a few people, for a machine
nobody outside Britain noticed, that was so frugal it ran on what leaked in
through its pins — and whose descendants now ship in the billions. That is the
placard, and act 2 above means it can sit next to the actual hardware that did
it.

**Open technical question — the Archimedes emulator.** MAME's `aa310` exists
but its Archimedes driver is widely regarded as behind the specialists;
**Arculator** (actively developed, covers A305–A5000, ARM2/ARM3, has a WASM
port) and **RPCEmu** are the community's choices, with **ArcEm** as a
register-level third. Since the exhibit only needs the RISC OS desktop idle and
input-responsive, MAME may well suffice — but this must be settled **on a
clone, by framebuffer**, before the station is designed. Acorn ROMs are
preservation-class with a genuinely murky rights history (there is doubt that
Acorn holds clean assignment of all the original MOS work); record provenance
and hashes, do not redistribute.

### 4.8 Sinclair — ZX80, ZX81, Spectrum, QL

| Machine | Year | Driver | Notes |
|---|---|---|---|
| **ZX80** | 1980 | `zx80` | 1 KB, black-and-white, and the display *blanks while it computes* — the exhibit is the flicker. |
| **ZX81** | 1981 | `zx81` | SLOW/FAST modes, the machine that put a computer in a British newsagent. |
| **ZX Spectrum 48K** | 1982 | `spectrum` | The rubber keyboard and attribute clash. The icon. |
| Spectrum 128 / +2 / +3 | 1985–87 | `spec128`, `specpls2`, `specpls3` | The Amstrad-era machines — a neat link to the existing `amstradcpc` station, since Amstrad bought Sinclair's computer business in 1986. |
| **Sinclair QL** | 1984 | `ql` (+ `ql_se`, `ql_de`, `ql_fr`, `ql_es`, `ql_it`, `ql_us`, …) | 68008, Microdrives, QDOS, SuperBASIC, and a bundled office suite. Alternatives: sQLux, Q-emuLator. |

**The Sinclair ROMs are the cleanest licensing story on the British side.**
Amstrad, which owns the Sinclair ROM copyrights, has long permitted
redistribution of the ZX ROM images for use with emulators, provided the
copyright messages are unaltered and the distribution is non-commercial — the
World of Spectrum permissions archive is the canonical record. Note the stated
scope covers the Spectrum 48/128 and the machines Amstrad itself made; the ZX80
and ZX81 sit outside what Amstrad claims, so treat those as preservation-class.

**QL caveat before anything goes on a placard.** The QL's launch kludges are
famous and the *external* one is well attested: early machines shipped with
firmware that did not fit, hanging out of the back on a ROM "dongle". The
piggyback-RAM story — DRAM chips soldered stacked on top of one another to
double memory without respinning the PCB — is a genuine and widespread QL
practice, but the sources I can find describe it as **aftermarket and
upgrade-service work rather than a factory production shortcut**. Verify
against a hardware reference (or a photographed board) before the museum text
asserts it as Sinclair's own doing.

### 4.9 The GDR machines

MAME's coverage here is better than expected — the whole East German
educational-computer landscape is present:

| Machine | Year | Driver | Notes |
|---|---|---|---|
| **KC 85/2 (HC 900)** | 1984 | `kc85_2` | VEB Mikroelektronik "Wilhelm Pieck" Mühlhausen. The wishlist's named machine. |
| **KC 85/3, /4, /5** | 1986–89 | `kc85_3`, `kc85_4`, `kc85_5` | CAOS, the module slots, colour. The /4 is the canonical one to exhibit. |
| **KC 87 / Z9001** | 1984–87 | `kc87_10`, `kc87_11`, `kc87_20`, `kc87_21` | Robotron Dresden's line — a *different* machine from the Mühlhausen KC 85s despite the shared "KC". Worth saying so on the placard, since the naming confuses everyone. |
| **Z1013** | 1985 | `z1013`, `z1013a2`, `z1013k69`, `z1013k76` | A kit computer sold to citizens over the counter, with a membrane keypad. The most socially interesting of the set. |
| **LC 80** | 1984 | `lc80`, `lc80_2`, `lc80e` | "Lerncomputer": seven-segment display and a hex keypad — the GDR's answer to the KIM-1, and its natural exhibit partner. |
| **BIC A5105** | 1989 | `a5105` | Robotron's education machine, arriving just in time for the country to end. |

Alternative emulator: **KCemu** (KC 85 series plus Z1013, LC 80 and A5105 —
essentially this whole table). ROMs are preservation-class: the manufacturers
are dissolved, the images circulate freely, and MAME carries the sets. Record
provenance, hash locally, do not redistribute.

**Recommendation:** two stations — **KC 85/4** (the colour, module-slot machine)
and **LC 80** (paired with the KIM-1, one exhibit on each side of the Wall) —
with Z1013, KC 87 and A5105 as placard/poster coverage.

## 5. The engineering leverage: one parameterised builder

Thirty machines must not become thirty copies of `c64.sh`. After `mpf2`, the
MAME-in-a-kiosk pattern is proven end to end (X root sizing, `-keepaspect`,
seed capture from a cold boot, key pacing derived from the emulated frame
period). The proposal is a single
`scripts/build-guests/mame-bridge.sh --driver <name> --media <path> …` (and a
sibling `vice-bridge.sh` for the Commodore 8-bits) driven entirely by fields
already in the registry entry.

That respects the playbook's rule — *per-station behaviour belongs in the registry
entry, never in a case statement in shared code* — because the shared script
takes parameters, it does not branch on station names. Per-machine specifics that
genuinely vary are already registry-expressible: `SH_KEY_MIN_HOLD_MS` /
`SH_KEY_MIN_GAP_MS` from the machine's frame period, `SH_KEY_MAP` and
`spa.demoProgram.keyMap` from the driver's `PORT_CHAR` table, display geometry,
audio device, `reset.fixture` prose.

Two facts that make this cheaper than it looks:

- MAME's `PORT_CHAR` pairs in each driver source give the exact key matrix, so
  the keymap work is mechanical rather than experimental (this is how mpf2's
  `=`/`-`/`+` remaps were derived).
- Every machine here is keyboard-only or keyboard-plus-joystick, so the whole
  pointer-transport decision tree in playbook §5 collapses to
  `--pointer none --input-backend disabled`.

## 6. What it costs — the real constraint

Measured on labhost, 2026-08-08, RSS of the live kiosks:

| Station | RSS |
|---|---|
| `mpf2` | 1.66 GB |
| `c64` | 1.65 GB |
| `amiga` | 1.61 GB |
| `apple2` | 1.00 GB |
| `atarist` | 0.78 GB |
| `amstradcpc` | 0.70 GB |

Mean ≈ 1.2 GB per station, and labhost reports **~40 GB available** of 128 GB.
So:

- ~10 new stations ≈ 12 GB — comfortable.
- ~20 new stations ≈ 24 GB — tight but possible.
- ~30 new stations ≈ 36 GB — **does not fit** with headroom for builds, clones and
  measurement campaigns.

Three levers, in order of preference:

1. **Right-size each kiosk.** An 8-bit MAME/VICE kiosk does not need the 1.5 GB
   the current stations are given; `amstradcpc` already runs at 0.70 GB. Setting
   `--mem 512` for this class would put 30 stations near ~18 GB.
2. **Start stations on demand.** `streamhost@<tile>` is one systemd service per
   station and the fleet is already routinely paused; a lineup of 60+ exhibits
   argues for starting a station when a visitor opens it rather than keeping every
   one hot. That is an architectural change, not a station change — and it is the
   only lever that scales past ~50 exhibits.
3. **More RAM.** The cheapest fix in money, the least interesting in design.

Non-memory costs to budget for, per station, all hand-managed: a scene assembly in
`spa/src/scene/machines.ts` (**registry order, not alphabetical**), a
`machineIdentity.ts` row (fails only under `npm run build`), a
`keyboardProfiles.ts` family, a guest doc, an assets-manifest row, a coldboot
arm, and — if wanted — a boot video. Slots 125+ are free, with gaps at 85–88,
109, 111 and 115.

## 7. Suggested phasing

Each phase is independently shippable and ends with a green quality gate.

| Phase | Stations | Why this order |
|---|---|---|
| **0** | Nothing new — build `mame-bridge.sh` / `vice-bridge.sh` and prove them by **rebuilding an existing station** | The abstraction gets proven against a known-good fixture before it is trusted with new machines. |
| **1 — the stories** | **C128** (CP/M on a Commodore), **BBC Micro + ARM Evaluation System**, **ZX Spectrum 48K**, **Amiga 1000** | Four exhibits, four narratives a visitor can be told in one sentence each. Highest value per gigabyte. |
| **2 — the origins** | **KIM-1**, **PET 2001/CBM 8032**, **VIC-20**, **LC 80** | The pre-64 Commodore arc, and the KIM-1/LC-80 pairing across the Wall. |
| **3 — the Britons** | **Archimedes A310**, **Oric Atmos**, **Dragon 32**, **Sinclair QL**, **ZX81** | Depends on settling the Archimedes emulator question first. |
| **4 — the misfires and the GDR** | **Plus/4** (+ C16/C116 as posters), **KC 85/4**, **Z1013** | The most niche, and the most fun to write placards for. |
| **5 — regional and cosmetic** | **VIC-1001**, **VIC-20 SE**; C64C / SX-64 / A2000 as **scene assets and posters** | Only after §3's policy is agreed, and only if memory allows. |

## 8. Open questions for the operator

1. **Variant policy (§3)** — accept "one station per machine-with-different-
   software, variants as placards/posters/scene assets", or does the collection
   deliberately want the collector-level granularity as separate streams?
2. **Scale target** — how many exhibits is this lineup ultimately for? The
   answer picks between right-sizing (≈50) and on-demand station start (>50).
3. **Archimedes backend** — is a MAME `aa310` bake-off against Arculator worth
   a clone campaign, or ship whichever reaches an idle RISC OS desktop first?
4. **Amiga breadth** — A1000 alone, or A1000 + A4000 (+ A3000)?
5. **QL placard claim** — can the piggyback-RAM story be verified from a
   hardware source before it is published (§4.8)?

## Sources

- MAME driver names: `/usr/games/mame -listfull` on labhost, MAME 0.276.
- [MAME `aa310.cpp`](https://github.com/mamedev/mame/blob/master/src/mame/acorn/aa310.cpp) ·
  [MAME `c64.cpp`](https://github.com/mamedev/mame/blob/master/src/mame/commodore/c64.cpp)
- [VICE](https://vice-emu.sourceforge.io/) · [VICE ROM licensing / Debian's removal](https://rr.pokefinder.org/wiki/VICE_ROMs)
- [FS-UAE `amiga_model`](https://fs-uae.net/docs/options/amiga-model/) ·
  [FS-UAE Kickstart ROMs](https://fs-uae.net/docs/kickstart-roms/)
- [World of Spectrum copyright & distribution permissions](https://worldofspectrum.net/permits/) ·
  [Amstrad ROM permission thread](https://groups.google.com/g/comp.sys.amstrad.8bit/c/HtpBU2Bzv_U/m/HhNDSU3MksAJ)
- ARM first silicon: [The Register, "40 years ago, Acorn fired up the first Arm processor"](https://www.theregister.com/on-prem/2025/04/29/40-years-ago-acorn-fired-up-the-first-arm-processor/511882) ·
  [WikiChip ARM1](https://en.wikichip.org/wiki/acorn/microarchitectures/arm1) ·
  [A Brief History of Arm, Part 1](https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/a-brief-history-of-arm-part-1)
- [Arculator](https://b-em.bbcmicro.com/arculator/) · [ArcEm](https://arcem.sourceforge.net/) ·
  [RISC OS emulators overview](https://emulation.gametechwiki.com/index.php/RISC_OS_emulators)
- [KC 85 — Wikipedia](https://en.wikipedia.org/wiki/KC_85) ·
  [Robotron KC 87 — Wikipedia](https://en.wikipedia.org/wiki/Robotron_KC_87) ·
  [KCemu](https://kcemu.sourceforge.net/)
- [Acorn ROM rights discussion, stardot](https://stardot.org.uk/forums/viewtopic.php?t=30265)
- QL RAM upgrades: [Sinclair QL Forum, internal memory upgrade](https://qlforum.co.uk/viewtopic.php?t=2314)
- Station RSS figures: measured on labhost, 2026-08-08.
