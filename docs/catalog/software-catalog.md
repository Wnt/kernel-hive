# Kernel Hive — Master Software & Games Catalog

A curated roster of era- and platform-appropriate software and games to stock each OS tile in the browser Kernel Hive (streamhost + QEMU, streamed over WebTransport on a private LAN gallery — HTTPS :8443).

---

## Rendering reality (applies everywhere)

Guests run **QEMU-TCG with no GPU / no 3D acceleration**. Winning picks are 2D, TUI, DOS-era software renderers, or SDL software surfaces. All 3D titles listed use **software renderers** (WinQuake/TyrQuake/Chocolate Doom/GoldSrc-software, never GLQuake/vkQuake/Direct3D). Titles that will be **heavy or marginal under TCG** are flagged ⚠️.

**Standard QEMU devices by era:** DOS/Win9x → `-vga cirrus` (Cirrus GD5446) + `-device sb16`; native Win apps → `-device AC97`; X11 BSD/Linux → `-vga std` + `modesetting`/`vesa`/`wsfb`. A couple of DOS demos prefer `-device gus` (Gravis Ultrasound).

---

## Top 12 must-have showcase tiles (across all OSes)

1. **Doom via FastDoom + Freedoom** (DOS) — fully-free Doom, zero legal caveats, tuned to fly on slow CPUs. Best "it's smooth!" tile.
2. **WinDoom + WinG** (Win 3.11) — "Doom, in a window, on Windows 3.1." Jaw-dropping, genuine computing history, software-rendered by design.
3. **Second Reality — Future Crew** (DOS) — the most famous PC demo ever, public domain, Finnish authors. "All this on a 486, software-only."
4. **Half-Life: Uplink demo** (Win 95/98) ⚠️ — landmark 1998 3D shooter, official free demo, GoldSrc software mode. Biggest wow, heaviest CPU load.
5. **GTA 1 + GTA 2** (Win9x/2000/XP/ReactOS) — officially free from Rockstar, top-down 2D, marquee name with clean-ish legal status.
6. **ScummVM + Beneath a Steel Sky + Flight of the Amazon Queen** (Amiga/BSD/Modern) — gorgeous point-and-click adventures, officially freeware, zero legal asterisks.
7. **Arachne** (DOS) — a graphical web browser running in DOS. Ultimate "wait, that's a web browser?!" tile.
8. **Netscape Navigator 2.02 + Trumpet Winsock** (Win 3.11) — the "online in 1996" pair; the definitive period-browser story.
9. **TyrQuake software-rendered Quake shareware** (BSD) — true texture-mapped 3D at playable fps entirely on CPU. The best "no-GPU?!" tile.
10. **Winamp** (Win9x/XP/ReactOS) — "it really whips the llama's ass." The single most nostalgic 90s app; exercises the WebTransport/Opus audio path.
11. **Icaros Desktop + State of the Art demo** (Amiga/AROS) — a whole Amiga world in one ISO; the most famous Amiga demo, A500-safe under TCG.
12. **cmatrix + asciiquarium** (BSD/Linux) — mesmerizing, near-zero-bandwidth animated "attract-mode" thumbnails for terminal tiles.

---

## FreeDOS / MS-DOS

Everything is 16/32-bit real-mode or DOS-extender software rendering to VGA/VESA in the CPU — no GPU needed. Give the guest a **Sound Blaster 16**. Default install = "DOS drop-in": unzip into `C:\GAMES\name` and run the `.EXE`. Runs identically on FreeDOS and MS-DOS 5.0/6.22.

| Title | Type | Source | Legal | Install | Why |
|---|---|---|---|---|---|
| Wolfenstein 3D (shareware ep.1) | game | [archive.org/details/wolf3dsw](https://archive.org/details/wolf3dsw) | id shareware, redistributable | drop-in, `WOLF3D.EXE` | The game that invented the FPS; instantly recognizable, tiny. |
| Doom (FastDoom + Freedoom) | game | [FastDoom](https://github.com/viti95/FastDoom/releases) (GPL) + [Freedoom WAD](https://freedoom.github.io/download.html) (BSD) | 100% free, no shareware needed | drop `FDOOM*.EXE` + `freedoom1.wad` in one folder | Fully-free Doom, zero caveats, DOS port tuned for slow CPUs. Top "it's smooth!" tile. |
| Duke Nukem 3D (shareware ep.1) | game | [archive.org/details/duke-3d-sw](https://archive.org/details/duke-3d-sw) | 3D Realms shareware, free | drop-in, `DUKE3D.EXE` | Peak-90s attitude, destructible world; the crowd-pleaser FPS. |
| Quake (shareware ep.1) | game | [archive.org/details/Quake_802](https://archive.org/details/Quake_802) | id shareware, free | drop-in, `QUAKE.EXE` (DOS4GW) | First real-time software-rendered 3D. ⚠️ Wants Pentium-class guest. |
| Commander Keen 1 | game | [commander-keen.com](https://www.commander-keen.com/game-downloads.php) | id/Apogee shareware, free | drop-in, `KEEN1.EXE` | Birth of smooth EGA scrolling on PC; bright, iconic, family-friendly. |
| Commander Keen 4 | game | [commander-keen.com](https://www.commander-keen.com/game-downloads.php) | free episode | drop-in, `KEEN4E.EXE` | Polished VGA + parallax; great motion for a stream. |
| Jazz Jackrabbit (shareware ep.1) | game | [archive.org/details/jazzjackrabbitversionshareware](https://archive.org/details/jazzjackrabbitversionshareware) | Epic shareware, free | drop-in, `JAZZ.EXE` | Blistering Sonic-style speed + gorgeous VGA. |
| Jill of the Jungle (shareware) | game | [dosgamesarchive.com](https://www.dosgamesarchive.com/download/jill-of-the-jungle) | Epic shareware, free | drop-in, `JILL.EXE` | Charming, light, instantly playable in a demo. |
| One Must Fall: 2097 | game | [archive.org/details/OneMustFall2097](https://archive.org/details/OneMustFall2097) | declared freeware by Epic (1999) | drop-in, `OMF.EXE` | Beloved mech-fighting game; distinctive non-FPS tile. |
| ZZT | game/creative | [archive.org/details/ZztByEpicMegagames](https://archive.org/details/ZztByEpicMegagames) | made free by Sweeney/Epic (1997); source MIT | drop-in, `ZZT.EXE` | Epic's first title + a game-creation tool. "Make your own" tile. |
| Second Reality — Future Crew (1993) | demo | [github.com/mtuomi/SecondReality](https://github.com/mtuomi/SecondReality) | public domain (Unlicense, 2013) | drop-in prebuilt `.EXE` | The most famous PC demo ever (Finnish). Prefers GUS; SB works. |
| Arachne | browser | [glennmcc.org](https://www.glennmcc.org/) | GPL / free since 2003 | installer; needs NE2000 NIC + DOS packet driver | A graphical web browser in DOS. Best "that's a browser?!" tile. Point at retro pages (limited modern HTTPS). |
| As-Easy-As 5.7 | util | [archive.org](https://archive.org/details/as-easy-as-version-5.7-for-dos) | TRIUS released free w/ full license | installer / drop-in, `ASEASY.EXE` | Legit-free Lotus 1-2-3 work-alike; DOS "did real work." |
| WordPerfect 5.1 | util | [winworldpc.com](https://winworldpc.com/product/wordperfect/5x-dos) | **abandonware** (not relicensed) | installer, `WP.EXE` | The iconic DOS word processor; blue screen + Reveal Codes nostalgia. |
| Norton Commander 5.51 | util | [winworldpc.com](https://winworldpc.com/product/norton-commander/55x) | **abandonware** | drop-in, `NC.EXE` | The two-pane orange file manager; makes the desktop feel lived-in. |

**Excluded (commercial):** Civilization / SimCity 2000 / Master of Orion (sold on GOG); Prince of Persia (Ubisoft; Apple II source grants no distribution rights). For the swordfighting vibe use SDLPoP on a Linux tile.

---

## Windows 3.1 / 3.11

16-bit environment. Native Win16 apps run fine; Win32 apps need the free **Win32s** add-on. Use `-vga cirrus` (Cirrus 5446 driver → 800×600×256) + `-device sb16`. **Best delivery: ship one preloaded Win 3.11-for-Workgroups hard-disk image** with everything installed and Program Manager icons arranged — "boot and it's there."

| Title | Type | Source | Legal | Install | Why |
|---|---|---|---|---|---|
| Solitaire / Minesweeper | game | built into Win 3.1 | MS (bundled) | none — preloaded image | The definitive "I remember this" tiles. |
| Write / Paintbrush / Cardfile / Calendar / Clock / Notepad | creative/util | built in | MS (bundled) | none | The classic Accessories productivity showcase. |
| Media Player + Sound Recorder | media | built in | MS (bundled) | none; needs SB16 | Prove audio works: play WAV/MIDI, watch the VU meter. |
| MS Entertainment Pack (JezzBall, Chip's Challenge, TriPeaks, SkiFree, Tetris…) | game | [archive.org/details/wep_20200803](https://archive.org/details/wep_20200803) · [WinWorld](https://winworldpc.com/product/microsoft-entertainm/4) | **abandonware** | drop-in folder, standalone 16-bit `.EXE`s | One folder = a dozen authentic Windows-gaming tiles. |
| SkiFree (16-bit) | game | [archive.org/details/win3_WINSKI](https://archive.org/details/win3_WINSKI); 32-bit rebuild [ski.ihoc.net](http://ski.ihoc.net/) | 16-bit abandonware; 32-bit author-freeware | drop-in, `WINSKI.EXE` | The Abominable Snowman meme; universally recognized. |
| WinDoom + WinG | game/demo | [bundle](https://archive.org/details/Windows-3.1-WING-doom) · [WinG runtime](https://archive.org/details/WING10) · [walkthrough](https://virtuallyfun.com/2011/03/29/windoom-wing-win32s-on-windows-3-1-on-qemu/) | WinG = free MS redist; Doom WAD shareware free; WinDoom binary abandonware | Win32s → WinG → drop WinDoom folder + shareware WAD | **Huge** — "Doom in a window on Windows 3.1." Software-rendered (WinG's whole point). |
| Netscape Navigator 2.02 (Win16) | browser | [WinWorld](https://winworldpc.com/product/netscape-navigator/2x) · [mirrors](http://sdfox7.com/netscape/win16.htm) | **abandonware** | 16-bit installer; needs Trumpet Winsock | The definitive period browser; "N" throbber + a period page = 1996. Modern TLS won't load — pair with a local retro page. |
| Trumpet Winsock 3.0 | util | [WinWorld](https://winworldpc.com/product/trumpet-winsock/3x) | shareware, free | drop-in `WINSOCK.DLL` + `TCPMAN.EXE`, configure to QEMU NIC | Explains "how a 1994 PC got online." |
| Paint Shop Pro 3 (16-bit v3.0) | creative | [WinWorld](https://winworldpc.com/product/paint-shop-pro/3x) | shareware, free | installer | The image editor everyone used before Photoshop was affordable. |
| WinZip 6.x (16-bit) | util | [WinWorld](https://winworldpc.com/product/winzip) | shareware, free | 16-bit installer | The "every Windows user had this" utility. |

---

## Windows 95 / 98 SE / ME

Use `-vga cirrus` for authentic Win9x drivers; `-device sb16` (DOS-era) or `-device AC97` (native apps). The three 3D titles use **software renderers** — playable but CPU-heavy ⚠️.

| Title | Type | Source | Legal | Install | Why |
|---|---|---|---|---|---|
| Netscape Communicator 4.x | browser | [WinWorld](https://winworldpc.com/product/netscape-navigator/40x) | abandonware (WinWorld museum) | installer | Definitive late-90s web tile. Pair with built-in IE5 for browser-wars shot. |
| Doom95 | game | [archive.org/details/DOOM_95](https://archive.org/details/DOOM_95) | shareware ep.1, redistributable | installer or drop-in, `DOOM95.EXE` | Most iconic PC game, native Win95 build — just works. |
| Quake (WinQuake, shareware) | game | [archive.org/details/Quake_802](https://archive.org/details/Quake_802) | shareware ep.1, free | drop-in; run **WinQuake** (software), NOT GLQuake | Landmark 3D; software mode proves no-GPU 3D. ⚠️ Heaviest DOS-era CPU load. |
| Duke Nukem 3D (shareware) | game | [archive.org](https://archive.org/details/3D_Realms_Duke_Nukem_3D_Shareware) | shareware ep.1, free | DOS drop-in; software Build engine | Huge nostalgia + attitude; great attract-mode tile. |
| Command & Conquer: Tiberian Dawn (Gold) | game | [cncnet.org/download](https://cncnet.org/download) · [cncnz.com](https://cncnz.com/features/freeware-classic-command-conquer-games/) | **official freeware** (EA, 2007–10) | installer | Genre-defining RTS, pure 2D, trivial under TCG. Red Alert 1 is an easy bonus. |
| GTA 1 + GTA 2 | game | [archive.org/details/rockstar-classics](https://archive.org/details/rockstar-classics) | **official free release** (Rockstar) | installer (GTA1 via DOSBox launcher; GTA2 native) | Marquee franchise, officially free — cleanest legal status. Top-down 2D. |
| StarCraft (shareware) | game | [archive.org](https://archive.org/details/StarCraftUSAShareware) | shareware, free | installer | One of the most important RTS titles; 2D sprites run great. |
| Age of Empires: Rise of Rome (demo) | game | [archive.org](https://archive.org/details/AgeofEmpiresTheRiseofRome_1020) | official free demo, standalone | installer | Gorgeous period RTS eye-candy; 2D isometric. |
| Half-Life: Uplink (demo) | game | [archive.org/details/Half-lifeUplink](https://archive.org/details/Half-lifeUplink) | official free demo (Valve) | installer; **software renderer** (avoid D3D/OpenGL) | Biggest wow tile — landmark 1998 shooter, exclusive demo mission. ⚠️ Most CPU-hungry; modest framerate. |
| Winamp 2.95 | media | [archive.org/details/winamp295](https://archive.org/details/winamp295) | freeware (Nullsoft) | installer | The definitive 90s MP3 player. Seed royalty-free MP3s so it visibly plays. |
| Paint Shop Pro 5.x | creative | [WinWorld](https://winworldpc.com/product/paint-shop-pro/5x) | shareware/trial abandonware | installer | The era's go-to affordable image editor. |
| mIRC | util | [mirc.com/get.html](https://www.mirc.com/get.html) | shareware, free to try | installer | IRC was *the* 90s chat client; authentic "connected desktop." |
| WinZip 7–8 | util | WinWorld / vendor trial | shareware evaluation | installer | The universal 90s archiver; you'll want it to unpack the rest. |

**Excluded (commercial and/or GPU-bound):** GLQuake/Direct3D builds, Warcraft II retail, Half-Life retail, Need for Speed, retail AoE.

---

## Windows 2000 / XP

**No GPU / no 3D** kills the marquee seed titles (GTA III/VC/SA, HL2, Max Payne, Deus Ex, Portal, Warcraft III — all Direct3D *and* commercial). Sweet spot = 2D games, software-renderer FPS, and the free apps that defined the XP desktop. Use `-vga std` + AC97/SB16.

| Title | Type | Source | Legal | Install | Why |
|---|---|---|---|---|---|
| GTA 1 + GTA 2 | game | [archive.org/details/rockstar-classics](https://archive.org/details/rockstar-classics) | official free (Rockstar) | installer / drop-in (GTA1 via DOSBox) | Legitimately free AAA name; top-down 2D, perfect software-rendered. |
| Quake (shareware) | game | [archive.org/details/Quake_802](https://archive.org/details/Quake_802) | shareware, free | drop-in; WinQuake/software port, NOT GLQuake | The game that defined 3D; software renderer looks great on CPU. |
| Duke Nukem 3D (shareware via eDuke32) | game | [eduke32.com](https://www.eduke32.com) + shareware `DUKE3D.GRP` | shareware GRP free (⚠️ Atomic Edition is commercial) | portable folder; set eDuke32 to **Classic 8-bit software** renderer | Build-engine set-pieces, software-rendered. |
| Doom / Doom II (Freedoom + Crispy/Chocolate) | game | [freedoom.github.io](https://freedoom.github.io) + [chocolate-doom.org](https://www.chocolate-doom.org) | Freedoom BSD; engines GPL | portable folder (engine + `freedoom2.wad`) | Most iconic FPS, fully legal end-to-end, pure software rasterizer. |
| Cave Story (2004) | game | [archive.org/details/Cave_Story_DM](https://archive.org/details/Cave_Story_DM) · [cavestory.one](https://www.cavestory.one/download/cave-story.php) | freeware (Pixel) | portable, `Doukutsu.exe` | Legendary one-man indie masterpiece, gorgeous 2D. |
| OpenTTD + OpenGFX | game | [openttd.org](https://www.openttd.org) | open source (GPL); OpenGFX free | Windows installer (bundles graphics) | Deep, endlessly playable 2D strategy; visitors linger. |
| Battle for Wesnoth 1.14.x | game | [SourceForge](https://sourceforge.net/projects/wesnoth/files/wesnoth-1.14/) | open source (GPL) | Windows installer (use 1.12.x on Win2000) | Beautiful hand-painted 2D fantasy strategy, huge campaign library. |
| Firefox 3.6 (or 2.0) | browser | [archive.mozilla.org](https://archive.mozilla.org/pub/firefox/releases/3.6.28/win32/en-US/) | free (MPL) | installer | Definitive alt-browser of the era. Pair with built-in IE6. |
| Winamp 5.666 | media | [archive.org/details/Winamp5666](https://archive.org/details/Winamp5666) | freeware (final Nullsoft/AOL) | installer | Most nostalgic XP app. ⚠️ Milkdrop needs OpenGL — use the built-in bar visualizer. |
| VLC 0.9.x / 1.1.x | media | [download.videolan.org](https://download.videolan.org/pub/videolan/vlc/) | open source (GPL) | installer / portable | Plays anything; software decode fine at SD. |
| 7-Zip (9.x/15.x) | util | [7-zip.org](https://www.7-zip.org/download.html) | free (LGPL) | installer | The utility everyone installed first. |
| Notepad++ (5.x/6.x) | util | [notepad-plus-plus.org](https://notepad-plus-plus.org/downloads/) | free (GPL) | installer / portable | The era's default code/text editor. |
| GIMP 2.6 | creative | [download.gimp.org](https://download.gimp.org/mirror/pub/gimp/v2.6/windows/) | free (GPL) | installer | Full Photoshop-class editor, software-rendered canvas. |

**Excluded:** GTA III/VC/SA, HL2+CS:S, Max Payne, Deus Ex, Warcraft III, Portal (all commercial + GPU); AoE II (great 2D fit but no legit free release).

---

## Amiga — AROS / Icaros Desktop

**Base recommendation: ship Icaros Desktop Live 2.3** (i386 live ISO) instead of a bare AROS nightly — it preinstalls Janus-UAE with the license-free AROS 68k ROM, ScummVM, OWB browser, and games. Source: [icarosdesktop.org](https://www.icarosdesktop.org/p/download.html). Keep the bare AROS nightly as a fast-boot fallback. Three lanes: **A** = AROS x86 native, **B** = 68k via Janus-UAE (double emulation ⚠️, keep to OCS/ECS/light-AGA), **C** = demoscene (timing-sensitive ⚠️, prefer A500/OCS).

| Title | Type | Lane | Source | Legal | Install | Why |
|---|---|---|---|---|---|---|
| Odyssey Web Browser (OWB) 2.1 | browser | A | [archives.arosworld.org](https://archives.arosworld.org/) | free (AROS project) | extract `.lha`/`.zip`, run | Working WebKit browser on an Amiga-API OS. ⚠️ Slow under software TCG — render light pages. |
| ScummVM + Beneath a Steel Sky + Flight of the Amazon Queen | game | A | [scummvm.org/games](https://www.scummvm.org/games/) | officially free | drop game folder, "Add Game" | Best "legit + beautiful" tile: full point-and-click adventures, zero asterisks. |
| Hurrican | game | A | [winterworks.de](https://www.winterworks.de/project/hurrican/) + AROS port | freeware, source released | extract `.lha`, run | The legal Turrican II substitute — run-and-gun spectacle, native. |
| SQRXZ 2 | game | A | [sqrxz.de](http://www.sqrxz.de/) / Aminet | freeware (Retroguru) | extract, run native | Crisp, brutal jump-'n'-run; modern homebrew shipping native AROS builds. |
| XRick | game | A | AROS Archives | open source (Rick Dangerous reimplementation) | extract, run native | Late-'80s platform nostalgia, tiny and fast under TCG. |
| Frets on Fire | game | A | bundled in Icaros 2.3 | open source (GPL) | preinstalled | Motion + audio + scrolling note highway; proves the audio path. |
| HivelyTracker | creative | A | [hivelytracker.co.uk](http://www.hivelytracker.co.uk/) | open source (BSD) | extract, run; load a `.hvl` | The legal, native answer to ProTracker/OctaMED — chiptune, no ROM. |
| Personal Paint 7.1 | creative | B | [archive.org](https://archive.org/details/cloanto-personal-paint-v7.1) | **Cloanto released free** | drop into Amiga-compat drawer, launch via Janus-UAE | The legal Deluxe Paint stand-in; quintessential creative Amiga tile. |
| Payback (demo) | game | B | [demo](https://archive.org/details/payback-demo) (⚠️ prefer demo; [full CD](https://archive.org/details/payback-amiga-cd-image) is abandonware) | abandonware — use demo | Janus-UAE | The Amiga's top-down GTA answer. ⚠️ Avoid the `Payback.lha` rip (malware). |
| ProTracker / OctaMED | creative | B | community mirrors | community-freeware (not formal release) | ship a couple `.mod`s + player | Authentic Amiga music heritage. For fully-clean, prefer HivelyTracker. |
| State of the Art — Spaceballs (1992) | demo | C | [demozoo.org/productions/2](https://demozoo.org/productions/2/) | scene-distributed | mount ADFs in Janus-UAE, boot | The most famous Amiga demo; targets plain A500 1MB — safest under TCG. |
| Desert Dream — Kefrens (1993) | demo | C | [demozoo.org/productions/142](https://demozoo.org/productions/142/) | scene-distributed | mount ADFs, boot | Gorgeous vectors + soundtrack, A500-class, stays watchable. |

**Excluded (still copyrighted, no free release):** Turrican II (→ Hurrican), Lemmings (→ Pingus, no AROS port), Another World, Shadow of the Beast, Sensible Soccer, Cannon Fodder, Worms; Deluxe Paint (→ Personal Paint); Directory Opus Magellan (still sold). Skip heavy AGA demos (Nexus 7, Rink a Dink Redux) — need cycle-exact timing.

---

## BSD — NetBSD / OpenBSD

Both run X with software rendering (Xorg `modesetting`/`vesa`/`wsfb`). NetBSD = `pkgin install`; OpenBSD = `pkg_add`. Many terminal classics are already in **base** (zero install). Keep Quake/Doom at low res (e.g. 400×300) for smooth streaming.

| Title | Type | Source | Legal | Install | Why |
|---|---|---|---|---|---|
| BSD base games (tetris, robots, snake, hack, trek, hunt, sail) | game (TUI) | base OS ([intro.6](https://man.openbsd.org/intro.6)) | BSD-licensed, in-tree | already in `/usr/games` | The definitive "this is a real BSD" tile. |
| NetHack | game (TUI) | pkgsrc `games/nethack` / `pkg_add nethack` | NetHack GPL, free | `pkgin install` / `pkg_add` | Most famous roguelike, pure ASCII, low-bandwidth. |
| Moon-buggy | game (TUI) | [pkgsrc games/moon-buggy](https://ftp.netbsd.org/pub/pkgsrc/current/pkgsrc/games/moon-buggy/index.html) | GPL | `pkgin`/`pkg_add` | Charming Moon-Patrol homage in terminal chars, animated. |
| Freedoom + Chocolate Doom | game (X, software) | [freedoom.github.io](https://freedoom.github.io/download.html) + `chocolate-doom` | Freedoom BSD; engine GPL | `pkg_add chocolate-doom freedoom` | Full FPS with no GPU is a jaw-dropper; 100% legally clean. |
| Quake (shareware) on TyrQuake | game (X, software 3D) | [shareware pak0](https://archive.org/details/quake_pak_202306) + [TyrQuake](https://disenchant.net/tyrquake) | shareware pak0 free (NOT pak1); engine GPL | `pkg_add tyrquake`, drop `id1/pak0.pak`, `tyr-quake -window` | The single best "no-GPU?!" tile — texture-mapped 3D on CPU. ⚠️ Keep res modest. |
| XBoard + GNU Chess | game/util (X) | pkgsrc `games/xboard` + `games/gnuchess` | GNU, GPL | `pkg_add xboard gnuchess` | Classy "it's a workstation" counterweight to the shooters. |
| XBill | game (X) | pkgsrc `games/xbill` | GPL, free | `pkg_add xbill` | Peak-90s Unix in-joke; period-perfect BSD culture. |
| NetSurf (GTK) | browser (X) | [netsurf-browser.org](https://www.netsurf-browser.org/) | GPLv2/MIT | `pkg_add netsurf` | Graphical browser with tabs, snappy on no-GPU BSD — best "usable desktop" proof. |
| Dillo 3.1 (revived) | browser (X, FLTK) | [dillo-browser.org/release](https://dillo-browser.org/release/) | GPLv3 | `pkg_add dillo` or build 3.1 tarball | Tiny, instant-loading; left for dead 2016, resurrected 2024 with HTTPS. |
| Links (-g) / w3m / Lynx | browser (TUI + X-fb) | pkgsrc `www/links`, `www/w3m`, `www/lynx` | GPL/free | `pkg_add links w3m lynx` | "Browsing from a text console" curiosity; near-zero streaming cost. |
| cmatrix + sl + cowsay + figlet + fortune | demo/util (TUI) | pkgsrc `misc/cowsay`, `misc/figlet`; `fortune` in base | GPL/BSD | `pkg_add cmatrix cowsay figlet` | The instant "hacker terminal"; cmatrix rain = mesmerizing attract-mode. |
| Asciiquarium | demo (TUI) | [pkgsrc games/asciiquarium](https://ftp.netbsd.org/pub/pkgsrc/current/pkgsrc/games/asciiquarium/index.html) | Artistic/GPL | `pkg_add asciiquarium` | Gently animated ASCII reef; delightful live thumbnail. |
| GNU Emacs / mg + Vi | creative/util | base (`vi`, `mg`) or pkgsrc `editors/emacs` | BSD/GPL | base or `pkg_add emacs` | Shows a genuine dev workstation; `mg` = Emacs look, base footprint. |

**Note:** A "pkgsrc/ports showcase" caption (`pkgin avail | wc -l`) is a nice BSD differentiator. **Skip cool-retro-term** — QML/OpenGL, will crawl. Only shareware `pak0` is redistributable, never `pak1`.

---

## Minimal Linux — Alpine / TinyCore

Native Linux; the wow is a 20–30 MB OS doing real, pretty things. TinyCore installs `.tcz` extensions; Alpine uses `apk add` (enable `community`). Excluded all GL titles (OpenArena/Sauerbraten fall to single-digit fps on llvmpipe).

| Title | Type | Source | Legal | Install | Why |
|---|---|---|---|---|---|
| Dillo | browser (GUI) | [dillo-browser.github.io](https://dillo-browser.github.io) | FOSS (GPLv3) | `dillo.tcz` (1.6 MB) / `apk add dillo` | A graphical browser in a few megs of RAM — the "tiny but real" showcase. |
| NetSurf | browser (GUI) | [netsurf-browser.org](https://www.netsurf-browser.org) | FOSS (MIT/GPL) | `.tcz` / `apk add netsurf` | Renders modern-ish CSS far better than Dillo, still light. |
| NetHack | game (TUI) | [nethack.org](https://www.nethack.org) | free (NetHack GPL) | package / `.tcz` | Canonical Unix roguelike, pure ncurses, "real Unix box." |
| Chocolate Doom + DOOM1.WAD | game (SDL software) | [chocolate-doom.org](https://www.chocolate-doom.org) + [shareware WAD](https://archive.org/details/DoomsharewareEpisode) | engine GPL; WAD free-to-distribute | `apk add chocolate-doom`, drop WAD | Doom running natively on Linux via SDL software surface, smooth no-GPU. |
| DOSBox + Duke Nukem 3D shareware | game (DOS-in-Linux) | [dosbox.org](https://www.dosbox.org) + [shareware](https://archive.org/details/3D_Realms_Duke_Nukem_3D_Shareware) | DOSBox GPL; shareware free | `apk add dosbox`, mount folder | Tiny Linux booting DOS booting a 1996 FPS — "look how deep this goes." |
| asciiquarium + cmatrix | demo (TUI) | [asciiquarium](https://robobunny.com/projects/asciiquarium/html/) + [cmatrix](https://github.com/abishekvashok/cmatrix) | GPL/Artistic | package / `.tcz` | Motion with near-zero bandwidth; best ambient thumbnail. |
| btop / htop | util/demo (TUI) | [btop](https://github.com/aristocratos/btop) / [htop.dev](https://htop.dev) | Apache-2.0 / GPL | `apk add btop htop` | btop's braille graphs are beautiful and constantly animate; "this VM is alive." |

*Optional filler:* ninvaders / moon-buggy / bsdgames (FOSS, Alpine community).

---

## ReactOS

Targets Server-2003-level Win32; still alpha. Prefer 2D/GDI/DirectDraw, treat Direct3D as risky. Verify against the [ReactOS Compatibility DB](https://reactos.org/project-news/reactos-compatibility-database-beta-status/).

| Title | Type | Source | Legal | Install | Why |
|---|---|---|---|---|---|
| SpaceCadetPinball (3D Pinball Space Cadet) | game | [github.com/k4zmu2a/SpaceCadetPinball](https://github.com/k4zmu2a/SpaceCadetPinball) | engine FOSS; data (`PINBALL.DAT`) proprietary abandonware | portable exe + drop in data files | Most nostalgic bundled Windows game; pure DirectDraw 2D, no GPU. |
| OpenTTD (+OpenGFX/OpenSFX) | game | [openttd.org](https://www.openttd.org/downloads/opengfx-releases/latest) | fully free (GPLv2 + free graphics) | installer / portable, bundle OpenGFX | Deep colorful 2D sim, all software, zero licensing asterisks. |
| Grand Theft Auto 2 | game | [rockstargames.com/downloads](https://www.rockstargames.com/downloads) · [mirror](https://archive.org/details/grand-theft-auto-2-pc_202107) | official free re-release | installer; **select software renderer** | Recognizable name, genuinely free, top-down 2D. Confirm on compat DB. |
| Winamp 2.95 | media | [archive.org/details/winamp2.95](https://archive.org/details/winamp2.95) | freeware/abandonware (Nullsoft) | tiny installer / portable | "Whips the llama's ass"; software spectrum visualizer exercises audio path. |
| K-Meleon | browser | [kmeleonbrowser.org](http://kmeleonbrowser.org) · [SourceForge](https://sourceforge.net/projects/kmeleon/) | FOSS (GPL), Gecko | installer / portable | Lightweight native Windows browser fitting the era, Gecko-friendly. Alt: Opera 12 (proprietary-free). |
| mtPaint | creative | [github.com/wjaguar/mtPaint](https://github.com/wjaguar/mtPaint) | FOSS (GPLv3) | portable / installer | Fast, useful pixel-art/image editor; a "creative" tile without weight. |
| 7-Zip + Notepad++ | util | [7-zip.org](https://www.7-zip.org) · [notepad-plus-plus.org](https://notepad-plus-plus.org) | FOSS (LGPL / GPL) | installers / portable | ReactOS doing everyday Windows work with the exact free tools people use. |

---

## Windows 11

*(Status: the win11 exhibit was a **remote-RDP bridge** to a KVM-accelerated PVE VM — not a TCG QEMU tile; its backing VM 900 has been deleted, so the exhibit is currently showcase-only pending a streamhost-era rebuild.)* Strategy: show off the modern desktop + a current browser, plus 2D / retro / emulated titles. On Win11 Edge is pre-bundled.

| Title | Type | Source | Legal | Install | Why |
|---|---|---|---|---|---|
| Mozilla Firefox | browser | [mozilla.org/firefox](https://www.mozilla.org/firefox/) | free (MPL 2.0) | installer (.exe) | Current browser = period-correct on a modern OS; buttery without GPU. |
| Microsoft Edge | browser | pre-installed | MS (bundled) | none | The default modern browser; "current OS, current web." |
| VLC media player | media | [videolan.org/vlc](https://www.videolan.org/vlc/) | free (GPL) | installer | Plays anything, software decode; demonstrates the audio path. |
| VS Code / VSCodium | creative/util | [code.visualstudio.com](https://code.visualstudio.com/) / [vscodium.com](https://vscodium.com/) | VSCodium MIT (prefer) | installer / portable | The definitive modern editor; reads as a real workstation. |
| DOSBox Staging | retro platform | [dosbox-staging.org](https://www.dosbox-staging.org/) | free (GPL) | installer | Turns any tile into a retro arcade; 100% software-rendered. |
| ScummVM + BASS + Flight of the Amazon Queen | game platform + games | [scummvm.org/games](https://www.scummvm.org/games/) | free engine; games officially freeware | install, unzip game, "Add Game" | Gorgeous 320×200 adventures, verifiably free — safest "wow" game. |
| Battle for Wesnoth | game | [wesnoth.org](https://www.wesnoth.org/) | free (GPL, GPL art) | installer | Deep 2D turn-based fantasy strategy, software-rendered. |
| OpenTTD (+OpenGFX) | game | [openttd.org](https://www.openttd.org/) | free (GPL) | installer, accept OpenGFX prompt | Endlessly demo-able 2D tycoon, fully free end-to-end. |
| 7-Zip | util | [7-zip.org](https://www.7-zip.org/) | free (LGPL) | tiny installer | The archetypal "first thing you install on Windows." |
| Minecraft Classic (browser) | game | [classic.minecraft.net](https://classic.minecraft.net/) | free, official (Mojang/MS) | none — open in browser | Huge name recognition, zero install, zero GPU (software canvas). |
| Solitaire / MS Casual Games | game | pre-installed | MS (bundled) | none | The universally-recognized "everyone knows this" comfort tile. |
| Doom shareware / Freedoom + Crispy Doom | game | [freedoom.github.io](https://freedoom.github.io/) + [chocolate-doom.org](https://www.chocolate-doom.org/) | shareware WAD free; Freedoom BSD; port GPL | drop port .exe + WAD, run | Most iconic PC game, software-rendered by design, legally spotless. |

⚠️ **GTA 1/2 flagged:** historically official-free, but Rockstar's page is dead and the archive.org mirror is uncertain provenance. Lead with ScummVM/Doom instead; treat GTA as optional.

---

## macOS Sequoia (macOS 15) — showcase-only; former guest deleted 2026-07-14

If recreated, the no-Metal/no-GPU guest makes virtually all Mac App Store games, Game Porting Toolkit, and the iOS Simulator unusable or slow. Lean toward **apps and desktop polish, not games.** Safari is pre-bundled. Cross-platform picks #1–8 below (Firefox, VLC, VS Code/VSCodium, DOSBox Staging, ScummVM, Wesnoth, OpenTTD) all have macOS builds.

| Title | Type | Source | Legal | Install | Why |
|---|---|---|---|---|---|
| Safari | browser | pre-installed | Apple (bundled) | none | The native, period-correct modern browser; centerpiece of the tile. |
| Mozilla Firefox | browser | [mozilla.org/firefox](https://www.mozilla.org/firefox/) | free (MPL 2.0) | .dmg | Recognizable value-add browser; software-fine. |
| IINA | media | [iina.io](https://iina.io/) | free (GPL-3) | .dmg, drag to Applications | Beautiful Mac-native mpv-based player; reinforces "real current Mac," exercises audio. |
| VLC | media | [videolan.org/vlc](https://www.videolan.org/vlc/) | free (GPL) | .dmg | Plays anything, software decode. |
| VS Code / VSCodium | creative/util | [vscodium.com](https://vscodium.com/) | MIT (prefer VSCodium) | .dmg | Real-workstation editor, CPU-rendered. |
| DOSBox Staging | retro platform | [dosbox-staging.org](https://www.dosbox-staging.org/) | free (GPL) | .dmg | Retro arcade vehicle, software-rendered. |
| ScummVM + freeware adventures | game platform | [scummvm.org/games](https://www.scummvm.org/games/) | free engine; games freeware | .dmg + add game | Clean-license 2D adventures despite the no-Metal limit. |
| Battle for Wesnoth / OpenTTD | game | [wesnoth.org](https://www.wesnoth.org/) / [openttd.org](https://www.openttd.org/) | free (GPL) | .dmg | Real full 2D games that run software-rendered. |

---

## Cross-OS notes

- **Recurring free-everywhere staples:** Freedoom + a software Doom port, ScummVM freeware adventures, OpenTTD (+OpenGFX), Battle for Wesnoth, 7-Zip, Notepad++, VLC, Firefox, NetSurf/Dillo, cmatrix/asciiquarium. Deduplicated per tile to the era-appropriate build.
- **Recurring shareware/free-release staples:** Quake shareware ep.1, Duke Nukem 3D shareware ep.1, GTA 1/2 (Rockstar), Doom shareware WAD, C&C Tiberian Dawn (EA freeware).
- **Software-rendering ⚠️ flags:** Quake/WinQuake/TyrQuake (Pentium-class, keep res low), Half-Life: Uplink (heaviest, modest fps), OWB/WebKit on AROS (slow), 68k-via-UAE double emulation (light titles only), AGA demos (skip), any GL title (Milkdrop, GLQuake, cool-retro-term, OpenArena — excluded).
- **Best delivery model:** for the older Windows tiles especially, ship a **single preloaded hard-disk image** with everything installed and icons arranged — "boot and it's there" beats any install step for the gallery experience.
