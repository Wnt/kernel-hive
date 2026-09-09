# Kernel Hive

**A living computer museum. Ninety-odd machines, from 1970 to today, running
right now — and you can move their mice.**

<a href="https://kernelhive.madekivi.fi">
  <img src="docs/media/hero.webp" alt="Twenty desktops from the collection, side by side" width="100%">
</a>

![A machine opening, the pointer moving, a line being typed](docs/media/demo.gif)

*Not a video of an old computer. That is a real guest, booted, at the other end
of a browser tab — the pointer and the keystrokes are going back into it.*

[![rust](https://img.shields.io/github/actions/workflow/status/Wnt/kernel-hive/rust.yml?branch=main&label=rust)](https://github.com/Wnt/kernel-hive/actions/workflows/rust.yml)
[![spa](https://img.shields.io/github/actions/workflow/status/Wnt/kernel-hive/spa.yml?branch=main&label=spa)](https://github.com/Wnt/kernel-hive/actions/workflows/spa.yml)
[![quality](https://img.shields.io/github/actions/workflow/status/Wnt/kernel-hive/quality.yml?branch=main&label=quality)](https://github.com/Wnt/kernel-hive/actions/workflows/quality.yml)
[![licence: MIT](https://img.shields.io/badge/licence-MIT-informational)](LICENSE)
[![streamhost: GPL-2.0-or-later](https://img.shields.io/badge/streamhost-GPL--2.0--or--later-informational)](streamhost/LICENSE)

## Why this is interesting

- **Every machine here is live, not a recording.** Open one and you are driving
  a running guest: click a menu, launch an application, break something. There
  is no scripted path and nothing pre-rendered.
- **The pointer lands where you point — even on a 1990s Unix workstation.**
  Most of these systems only understand *motion*, not position, so a browser's
  coordinates used to turn into a cursor that crawled behind your hand. On the
  hardest machines the emulator now reads the cursor back out of the graphics
  chip's own registers and steers until the two agree. Click to photon is
  around 20–25 ms on the LAN
  ([`docs/INPUT-LATENCY.md`](docs/INPUT-LATENCY.md)).
- **The machines are wired to a 1990s internet that has no way out.** Sign into
  **ICQ** on Windows 98 and message someone at a Solaris workstation; open
  **Internet Explorer 5** and land on archived 1998 pages exactly as they were,
  nothing later than the end of 2000. A chatbot lives on that network and says
  hello about thirty seconds after a machine wakes up. Nothing on it can reach
  today's internet.
- **You can have one to yourself.** No invitation needed: sign up and the
  museum hands you a private copy of Windows 3.11, OS/2 Warp or Rhapsody. Wreck
  it, close the tab — the next visitor still gets a pristine one.

## Visit the museum

**[kernelhive.madekivi.fi](https://kernelhive.madekivi.fi)**

Walk in and you can register an account on the spot and be given a private
machine for the visit — three to choose from, yours to install things on and
ruin. Signing in on an invited account opens the whole floor instead: every
live machine in the collection, its write-up, photographs of the real hardware
it is imitating, and the private 1990s internet several of them are joined to.
Sign-in is a passkey, so there is no password to pick.

The full public path — the edge, the three gates, the media plane — is
[`docs/PUBLIC-GALLERY.md`](docs/PUBLIC-GALLERY.md).

## The lineup

Every machine on the floor, by the decade it came from. Each one is a link
straight into the running system.

<!-- lineup:start -->
### 1970s

<table>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/decos"><img src="spa/public/posters/decos/desktop.webp" width="150" alt="DEC PDP-11 — RT-11, RSX-11M, RSTS/E"></a><br><sub>DEC PDP-11 — RT-11, RSX-11M, RSTS/E · 1970</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/alto"><img src="spa/public/posters/alto/desktop.webp" width="150" alt="Xerox Alto II"></a><br><sub>Xerox Alto II · 1973</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/gt40"><img src="spa/public/posters/gt40/desktop.webp" width="150" alt="DEC GT40"></a><br><sub>DEC GT40 · 1973</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/pdp11"><img src="spa/public/posters/pdp11/desktop.webp" width="150" alt="DEC PDP-11/70 — 2.11BSD"></a><br><sub>DEC PDP-11/70 — 2.11BSD · 1975</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/pet2001"><img src="spa/public/posters/pet2001/desktop.webp" width="150" alt="Commodore PET 2001"></a><br><sub>Commodore PET 2001 · 1977</sub></td>
</tr>
</table>

### 1980s

<table>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/cbm8032"><img src="spa/public/posters/cbm8032/desktop.webp" width="150" alt="Commodore CBM 8032"></a><br><sub>Commodore CBM 8032 · 1980</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/vic20"><img src="spa/public/posters/vic20/desktop.webp" width="150" alt="Commodore VIC-20"></a><br><sub>Commodore VIC-20 · 1980</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/bbcmicro"><img src="spa/public/posters/bbcmicro/desktop.webp" width="150" alt="Acorn BBC Micro Model B"></a><br><sub>Acorn BBC Micro Model B · 1981</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/star"><img src="spa/public/posters/star/desktop.webp" width="150" alt="Xerox Star 8010"></a><br><sub>Xerox Star 8010 · 1981</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/zx81"><img src="spa/public/posters/zx81/desktop.webp" width="150" alt="Sinclair ZX81"></a><br><sub>Sinclair ZX81 · 1981</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/c64"><img src="spa/public/posters/c64/desktop.webp" width="150" alt="Commodore 64"></a><br><sub>Commodore 64 · 1982</sub></td>
</tr>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/cbm2"><img src="spa/public/posters/cbm2/desktop.webp" width="150" alt="Commodore CBM 610"></a><br><sub>Commodore CBM 610 · 1982</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/dragon32"><img src="spa/public/posters/dragon32/desktop.webp" width="150" alt="Dragon 32"></a><br><sub>Dragon 32 · 1982</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/mpf2"><img src="spa/public/posters/mpf2/desktop.webp" width="150" alt="Multitech Microprofessor II"></a><br><sub>Multitech Microprofessor II · 1982</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/zxspectrum"><img src="spa/public/posters/zxspectrum/desktop.webp" width="150" alt="Sinclair ZX Spectrum 48K"></a><br><sub>Sinclair ZX Spectrum 48K · 1982</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/atari800xl"><img src="spa/public/posters/atari800xl/desktop.webp" width="150" alt="Atari 800XL"></a><br><sub>Atari 800XL · 1983</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/oricatmos"><img src="spa/public/posters/oricatmos/desktop.webp" width="150" alt="Oric Atmos"></a><br><sub>Oric Atmos · 1984</sub></td>
</tr>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/plus4"><img src="spa/public/posters/plus4/desktop.webp" width="150" alt="Commodore Plus/4"></a><br><sub>Commodore Plus/4 · 1984</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/sinclairql"><img src="spa/public/posters/sinclairql/desktop.webp" width="150" alt="Sinclair QL"></a><br><sub>Sinclair QL · 1984</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/a1000"><img src="spa/public/posters/a1000/desktop.webp" width="150" alt="Amiga 1000"></a><br><sub>Amiga 1000 · 1985</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/amstradcpc"><img src="spa/public/posters/amstradcpc/desktop.webp" width="150" alt="Amstrad CPC 6128"></a><br><sub>Amstrad CPC 6128 · 1985</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/apple2e"><img src="spa/public/posters/apple2e/desktop.webp" width="150" alt="Apple //e"></a><br><sub>Apple //e · 1985</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/atarist"><img src="spa/public/posters/atarist/desktop.webp" width="150" alt="Atari ST (EmuTOS GEM)"></a><br><sub>Atari ST (EmuTOS GEM) · 1985</sub></td>
</tr>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/c128"><img src="spa/public/posters/c128/desktop.webp" width="150" alt="Commodore 128"></a><br><sub>Commodore 128 · 1985</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/daybreak"><img src="spa/public/posters/daybreak/desktop.webp" width="150" alt="Xerox 6085"></a><br><sub>Xerox 6085 · 1985</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/armeval"><img src="spa/public/posters/armeval/desktop.webp" width="150" alt="Acorn ARM Evaluation System"></a><br><sub>Acorn ARM Evaluation System · 1986</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/amiga"><img src="spa/public/posters/amiga/desktop.webp" width="150" alt="Amiga 500"></a><br><sub>Amiga 500 · 1987</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/medley"><img src="spa/public/posters/medley/desktop.webp" width="150" alt="Interlisp Medley"></a><br><sub>Interlisp Medley · 1987</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/apple2"><img src="spa/public/posters/apple2/desktop.webp" width="150" alt="Apple II"></a><br><sub>Apple II · 1988</sub></td>
</tr>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/kc854"><img src="spa/public/posters/kc854/desktop.webp" width="150" alt="KC 85/4"></a><br><sub>KC 85/4 · 1988</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/samcoupe"><img src="spa/public/posters/samcoupe/desktop.webp" width="150" alt="SAM Coupé"></a><br><sub>SAM Coupé · 1989</sub></td>
</tr>
</table>

### 1990s

<table>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/a3000"><img src="spa/public/posters/a3000/desktop.webp" width="150" alt="Amiga 3000"></a><br><sub>Amiga 3000 · 1990</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/newsos"><img src="spa/public/posters/newsos/desktop.webp" width="150" alt="NEWS-OS 4.1R"></a><br><sub>NEWS-OS 4.1R · 1991</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/amix"><img src="spa/public/posters/amix/desktop.webp" width="150" alt="Amiga UNIX (AMIX)"></a><br><sub>Amiga UNIX (AMIX) · 1992</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/aux"><img src="spa/public/posters/aux/desktop.webp" width="150" alt="A/UX 3.0.1"></a><br><sub>A/UX 3.0.1 · 1993</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/indyr4400"><img src="spa/public/posters/indyr4400/desktop.webp" width="150" alt="SGI Indy R4400"></a><br><sub>SGI Indy R4400 · 1993</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/irix"><img src="spa/public/posters/irix/desktop.webp" width="150" alt="SGI Indy"></a><br><sub>SGI Indy · 1993</sub></td>
</tr>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/pcgeos"><img src="spa/public/posters/pcgeos/desktop.webp" width="150" alt="PC/GEOS Ensemble"></a><br><sub>PC/GEOS Ensemble · 1993</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/win311"><img src="spa/public/posters/win311/desktop.webp" width="150" alt="Windows 3.11"></a><br><sub>Windows 3.11 · 1993</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/freedos"><img src="spa/public/posters/freedos/desktop.webp" width="150" alt="FreeDOS"></a><br><sub>FreeDOS · 1994</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/msdoswin1"><img src="spa/public/posters/msdoswin1/desktop.webp" width="150" alt="MS-DOS 6.22 + Windows 1.0"></a><br><sub>MS-DOS 6.22 + Windows 1.0 · 1994</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/solaris"><img src="spa/public/posters/solaris/desktop.webp" width="150" alt="Solaris CDE"></a><br><sub>Solaris CDE · 1994</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/sunos414"><img src="spa/public/posters/sunos414/desktop.webp" width="150" alt="SunOS 4.1.4 / OpenWindows"></a><br><sub>SunOS 4.1.4 / OpenWindows · 1994</sub></td>
</tr>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/nextstep"><img src="spa/public/posters/nextstep/desktop.webp" width="150" alt="NeXTSTEP 3.3"></a><br><sub>NeXTSTEP 3.3 · 1995</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/nt351"><img src="spa/public/posters/nt351/desktop.webp" width="150" alt="Windows NT 3.51"></a><br><sub>Windows NT 3.51 · 1995</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/win95"><img src="spa/public/posters/win95/desktop.webp" width="150" alt="Windows 95"></a><br><sub>Windows 95 · 1995</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/hpuxvue"><img src="spa/public/posters/hpuxvue/desktop.webp" width="150" alt="HP-UX 10.20 / HP VUE"></a><br><sub>HP-UX 10.20 / HP VUE · 1996</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/macos753"><img src="spa/public/posters/macos753/desktop.webp" width="150" alt="Mac OS 7.5.3"></a><br><sub>Mac OS 7.5.3 · 1996</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/nt4"><img src="spa/public/posters/nt4/desktop.webp" width="150" alt="Windows NT 4.0"></a><br><sub>Windows NT 4.0 · 1996</sub></td>
</tr>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/os2warp"><img src="spa/public/posters/os2warp/desktop.webp" width="150" alt="OS/2 Warp 4"></a><br><sub>OS/2 Warp 4 · 1996</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/slackware"><img src="spa/public/posters/slackware/desktop.webp" width="150" alt="Slackware 3.4"></a><br><sub>Slackware 3.4 · 1997</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/rhapsody"><img src="spa/public/posters/rhapsody/desktop.webp" width="150" alt="Rhapsody DR2"></a><br><sub>Rhapsody DR2 · 1998</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/aix432"><img src="spa/public/posters/aix432/desktop.webp" width="150" alt="IBM RS/6000 — AIX 4.3.3"></a><br><sub>IBM RS/6000 — AIX 4.3.3 · 1999</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/amigaos35"><img src="spa/public/posters/amigaos35/desktop.webp" width="150" alt="AmigaOS 3.5"></a><br><sub>AmigaOS 3.5 · 1999</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/netbsd14"><img src="spa/public/posters/netbsd14/desktop.webp" width="150" alt="NetBSD 1.4.1"></a><br><sub>NetBSD 1.4.1 · 1999</sub></td>
</tr>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/w2kalpha"><img src="spa/public/posters/w2kalpha/desktop.webp" width="150" alt="Windows 2000 for Alpha"></a><br><sub>Windows 2000 for Alpha · 1999</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/win98se"><img src="spa/public/posters/win98se/desktop.webp" width="150" alt="Windows 98 SE"></a><br><sub>Windows 98 SE · 1999</sub></td>
</tr>
</table>

### 2000s

<table>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/beos"><img src="spa/public/posters/beos/desktop.webp" width="150" alt="BeOS R5"></a><br><sub>BeOS R5 · 2000</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/debian22"><img src="spa/public/posters/debian22/desktop.webp" width="150" alt="Debian GNU/Linux 2.2"></a><br><sub>Debian GNU/Linux 2.2 · 2000</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/redhat62"><img src="spa/public/posters/redhat62/desktop.webp" width="150" alt="Red Hat Linux 6.2"></a><br><sub>Red Hat Linux 6.2 · 2000</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/suse64"><img src="spa/public/posters/suse64/desktop.webp" width="150" alt="SuSE Linux 6.4"></a><br><sub>SuSE Linux 6.4 · 2000</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/win2000"><img src="spa/public/posters/win2000/desktop.webp" width="150" alt="Windows 2000"></a><br><sub>Windows 2000 · 2000</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/macos9"><img src="spa/public/posters/macos9/desktop.webp" width="150" alt="Mac OS 9.2.2"></a><br><sub>Mac OS 9.2.2 · 2001</sub></td>
</tr>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/winxp"><img src="spa/public/posters/winxp/desktop.webp" width="150" alt="Windows XP"></a><br><sub>Windows XP · 2001</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/chokanji"><img src="spa/public/posters/chokanji/desktop.webp" width="150" alt="Chokanji (超漢字)"></a><br><sub>Chokanji (超漢字) · 2002</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/tru64"><img src="spa/public/posters/tru64/desktop.webp" width="150" alt="Tru64 UNIX"></a><br><sub>Tru64 UNIX · 2003</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/kolibrios"><img src="spa/public/posters/kolibrios/desktop.webp" width="150" alt="KolibriOS"></a><br><sub>KolibriOS · 2004</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/ubuntu"><img src="spa/public/posters/ubuntu/desktop.webp" width="150" alt="Ubuntu 4.10 Warty Warthog"></a><br><sub>Ubuntu 4.10 Warty Warthog · 2004</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/alpine"><img src="spa/public/posters/alpine/desktop.webp" width="150" alt="Alpine Linux"></a><br><sub>Alpine Linux · 2005</sub></td>
</tr>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/freebsd411"><img src="spa/public/posters/freebsd411/desktop.webp" width="150" alt="FreeBSD 4.11"></a><br><sub>FreeBSD 4.11 · 2005</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/helenos"><img src="spa/public/posters/helenos/desktop.webp" width="150" alt="HelenOS"></a><br><sub>HelenOS · 2006</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/android"><img src="spa/public/posters/android/desktop.webp" width="150" alt="Android"></a><br><sub>Android · 2008</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/pcbsd"><img src="spa/public/posters/pcbsd/desktop.webp" width="150" alt="PC-BSD 1.5.1"></a><br><sub>PC-BSD 1.5.1 · 2008</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/redstar2"><img src="spa/public/posters/redstar2/desktop.webp" width="150" alt="Red Star OS 2.0"></a><br><sub>Red Star OS 2.0 · 2009</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/tinycore"><img src="spa/public/posters/tinycore/desktop.webp" width="150" alt="Tiny Core Linux"></a><br><sub>Tiny Core Linux · 2009</sub></td>
</tr>
</table>

### 2010s–2020s

<table>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/qnx"><img src="spa/public/posters/qnx/desktop.webp" width="150" alt="QNX Neutrino 6.5"></a><br><sub>QNX Neutrino 6.5 · 2010</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/ninefront"><img src="spa/public/posters/ninefront/desktop.webp" width="150" alt="9front (Plan 9)"></a><br><sub>9front (Plan 9) · 2011</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/toaruos"><img src="spa/public/posters/toaruos/desktop.webp" width="150" alt="ToaruOS"></a><br><sub>ToaruOS · 2011</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/redstar3"><img src="spa/public/posters/redstar3/desktop.webp" width="150" alt="Red Star OS 3.0 Desktop"></a><br><sub>Red Star OS 3.0 Desktop · 2013</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/sailfishos"><img src="spa/public/posters/sailfishos/desktop.webp" width="150" alt="Sailfish OS"></a><br><sub>Sailfish OS · 2013</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/templeos"><img src="spa/public/posters/templeos/desktop.webp" width="150" alt="TempleOS"></a><br><sub>TempleOS · 2013</sub></td>
</tr>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/postmarketos"><img src="spa/public/posters/postmarketos/desktop.webp" width="150" alt="postmarketOS"></a><br><sub>postmarketOS · 2017</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/serenityos"><img src="spa/public/posters/serenityos/desktop.webp" width="150" alt="SerenityOS"></a><br><sub>SerenityOS · 2018</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/bootos"><img src="spa/public/posters/bootos/desktop.webp" width="150" alt="bootOS"></a><br><sub>bootOS · 2019</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/win11"><img src="spa/public/posters/win11/desktop.webp" width="150" alt="Windows 11"></a><br><sub>Windows 11 · 2021</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/aros"><img src="spa/public/posters/aros/desktop.webp" width="150" alt="AROS"></a><br><sub>AROS · 2024</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/haiku"><img src="spa/public/posters/haiku/desktop.webp" width="150" alt="Haiku R1/beta5"></a><br><sub>Haiku R1/beta5 · 2024</sub></td>
</tr>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/openvms"><img src="spa/public/posters/openvms/desktop.webp" width="150" alt="OpenVMS x86-64 9.2"></a><br><sub>OpenVMS x86-64 9.2 · 2024</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/reactos"><img src="spa/public/posters/reactos/desktop.webp" width="150" alt="ReactOS 0.4.14"></a><br><sub>ReactOS 0.4.14 · 2024</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/ravynos"><img src="spa/public/posters/ravynos/desktop.webp" width="150" alt="ravynOS"></a><br><sub>ravynOS · 2025</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/openbsd"><img src="spa/public/posters/openbsd/desktop.webp" width="150" alt="OpenBSD 7.9"></a><br><sub>OpenBSD 7.9 · 2026</sub></td>
</tr>
</table>

### Placards

Backends retired; the SPA renders a static placard rather than dialing a dead service.

<table>
<tr>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/riscos"><img src="spa/public/posters/riscos/desktop.webp" width="150" alt="RISC OS 5.30"></a><br><sub>RISC OS 5.30 · 2022</sub></td>
<td align="center"><a href="https://kernelhive.madekivi.fi/os/macos"><img src="spa/public/posters/macos/desktop.webp" width="150" alt="macOS Sequoia"></a><br><sub>macOS Sequoia · 2024</sub></td>
</tr>
</table>
<!-- lineup:end -->


## How it works

![Browser, streaming daemon and emulator, with the retronet plane beside them](docs/media/architecture.svg)

A browser tab decodes H.264 and Opus arriving over WebTransport, and sends the
pointer and keyboard back the same way. Behind it, one small Rust daemon per
machine captures the screen only when it actually changes, encodes it, and
injects your input into the guest by whichever channel that guest understands.
Behind *that* is a period-correct emulator — QEMU, MAME, FS-UAE or an Alpha
simulator — and, for some machines, the museum's own private network.
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) is the map into the rest.

### Six things that turned out to be hard

- **Nobody wants to watch a boot.** A machine is launched already restored to a
  captured full machine state — RAM, devices and disk together — and left
  paused; the first visitor to arrive resumes it. Which is why a Tru64 Alpha
  puts a CDE desktop on screen in seconds rather than minutes.
  ([`docs/GUEST-TIERS.md`](docs/GUEST-TIERS.md),
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md))
- **The closed-loop pointer.** Where a guest exposes no absolute pointing
  device, the emulator reads the cursor position back — from the graphics
  chip's registers, or from the address the operating system itself keeps its
  pointer at — and corrects until it matches. Arithmetic and hope was not
  enough; a feedback loop was.
  ([`docs/lab/INPUT-DEBUGGING.md`](docs/lab/INPUT-DEBUGGING.md))
- **Encoding a screen that mostly does not move.** An idle desktop should cost
  nothing, and a dragged window should still be smooth. Capture is gated on the
  emulator signalling damage rather than run at a fixed rate, encoding happens
  on its own thread at constant quality, and an unwatched machine is paused
  outright. ([`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md),
  [`streamhost/docs/DESIGN.md`](streamhost/docs/DESIGN.md),
  [`streamhost/docs/IDLE-PAUSE.md`](streamhost/docs/IDLE-PAUSE.md))
- **Giving the 1990s machines an internet.** Period browsers and period chat
  clients speaking real HTTP/1.0 and real OSCAR to services inside the lab,
  against an archive of pages as they were — with no route to the modern web
  anywhere in the design, because half of what makes it convincing is that it
  cannot cheat. ([`docs/lab/RETRONET-BRIEF.md`](docs/lab/RETRONET-BRIEF.md),
  [`docs/lab/retronet/`](docs/lab/retronet/))
- **Handing a stranger a machine of their own.** A private copy per visitor,
  spun off a shared starting state onto its own throwaway overlay and its own
  isolated network, reaped when the visit ends.
  ([`docs/lab/WALKIN-BRIEF.md`](docs/lab/WALKIN-BRIEF.md))
- **Patching the emulators.** Several exhibits only exist because the emulator
  was changed: an SGI Indy that panics under hardware virtualisation, an Amiga
  that had to publish its frames into shared memory, an Alpha, and a Cirrus
  card that restored a saved Windows NT desktop in the wrong colours for
  reasons that took a trace to find. The patches are published, one commit per
  patch. ([`docs/lab/ES40-FORK-BRIEF.md`](docs/lab/ES40-FORK-BRIEF.md),
  [`docs/lab/FSUAE-NATIVE-BRIEF.md`](docs/lab/FSUAE-NATIVE-BRIEF.md),
  [`streamhost/qemu-patches/`](streamhost/qemu-patches/))

## This week at the museum

The museum keeps a written account of every week. The latest one:

<!-- release-notes:start -->
## Release notes

### Week 5 · Nine Unixes in one night · 2026-08-30 09:00 – 2026-09-06 09:00

#### New stations

<u>Nine Unix and Linux machines arrived in a single night.</u> [Slackware 3.4](https://kernelhive.madekivi.fi/os/slackware) brings 1997's **fvwm95**, the desktop that made a Unix workstation look like Windows 95; [NetBSD 1.4.1](https://kernelhive.madekivi.fi/os/netbsd14) follows from 1999. The year 2000 gives three at once — [Red Hat Linux 6.2 "Zoot"](https://kernelhive.madekivi.fi/os/redhat62) with **GNOME 1.0**, [Debian 2.2 "potato"](https://kernelhive.madekivi.fi/os/debian22), and [SuSE Linux 6.4](https://kernelhive.madekivi.fi/os/suse64) with **KDE 1**, from the last spring SuSE spelled itself with a small u. [Ubuntu 4.10 "Warty Warthog"](https://kernelhive.madekivi.fi/os/ubuntu) is the very first Ubuntu, running off its live CD, so every reset returns to the same instant. [FreeBSD 4.11](https://kernelhive.madekivi.fi/os/freebsd411) closes the 4.x line with the full **KDE 3.3.2**; [PC-BSD 1.5.1](https://kernelhive.madekivi.fi/os/pcbsd) is FreeBSD made point-and-click; [OpenBSD 7.9](https://kernelhive.madekivi.fi/os/openbsd) stands at the modern end. Earlier in the week came [Amiga UNIX](https://kernelhive.madekivi.fi/os/amix), Commodore's *System V Release 4* with **OPEN LOOK**, in colour on the **A2410** card most owners never bought; [ravynOS](https://kernelhive.madekivi.fi/os/ravynos); [PC/GEOS Ensemble](https://kernelhive.madekivi.fi/os/pcgeos), a 1990 desktop in *640 KB on a 286*; and [bootOS](https://kernelhive.madekivi.fi/os/bootos), a whole operating system in *512 bytes*. That makes 87 machines, 85 of them open to visitors.

#### Major features

Eight of the new arrivals joined the museum's private 1990s internet, browsing the archived web through the browser each would really have had, from **Netscape 4.77** on [Debian](https://kernelhive.madekivi.fi/os/debian22) to **Lynx** on [NetBSD](https://kernelhive.madekivi.fi/os/netbsd14). Seven signed on to the chat network too, taking it from eleven machines to nineteen. [Windows 3.11](https://kernelhive.madekivi.fi/os/win311) joined through the **AOL Instant Messenger** already sitting on its disk, and a bridge now relays between the AIM and ICQ halves, so a 1993 desktop can answer a message from a 2000 Linux box. A machine you have just reset signs itself back in, unprompted. The cursor landed on many more machines as well: [AIX](https://kernelhive.madekivi.fi/os/aix432) and [HP-UX](https://kernelhive.madekivi.fi/os/hpuxvue) read it back out of the graphics chip's own registers and steer until it agrees, while [Rhapsody](https://kernelhive.madekivi.fi/os/rhapsody), [Mac OS 7.5.3](https://kernelhive.madekivi.fi/os/macos753) and [BeOS](https://kernelhive.madekivi.fi/os/beos) have the coordinate written straight into the place each system keeps its own pointer. Cursor and hand now agree exactly.

#### Quality improvements

[AIX](https://kernelhive.madekivi.fi/os/aix432) had stopped taking the keyboard and would lock itself out; [HP-UX](https://kernelhive.madekivi.fi/os/hpuxvue) looked broken the same way and turned out to be a focus trap, not a fault. Both type again. A key still held down when you close the tab is released now, so nobody arrives to a machine stuck on shift. The private machines handed to signed-in visitors used to leave everyone else on a blank front page; the museum renders one hall for all.

#### Also this week

- Each new arrival chats with its era's own client — **GtkICQ** on SuSE, **GnomeICU** on Debian, **mICQ** on NetBSD, **Kopete** on PC-BSD, **Gaim** on Ubuntu
- The network's resident bot says hello about a minute after a machine signs in, and every station carries every other one in its contact list
- [FreeBSD 4.11](https://kernelhive.madekivi.fi/os/freebsd411)'s network card went silent after every reset, so it was swapped for one that survives — the fault shows only on the wire
- [NetBSD 1.4.1](https://kernelhive.madekivi.fi/os/netbsd14) needed a kernel built inside the guest: the stock 1999 one hangs on this hardware before it ever reaches the disk
- [Slackware 3.4](https://kernelhive.madekivi.fi/os/slackware)'s 1997 boot floppy still wedges under a modern emulator, so the museum boots its kernel from a GRUB2 rescue disc instead
- [FreeBSD 4.11](https://kernelhive.madekivi.fi/os/freebsd411) reads a CD one 16-bit word at a time, so it had to be installed on the slow software emulator and only then run at full speed
- [Debian 2.2](https://kernelhive.madekivi.fi/os/debian22) writes an emulated disk just as slowly, so its root filesystem was assembled outside the machine and handed over finished
- [Red Hat Linux 6.2](https://kernelhive.madekivi.fi/os/redhat62) installs itself from a kickstart file and [OpenBSD](https://kernelhive.madekivi.fi/os/openbsd) from a scripted installer — nobody answers a prompt
- [SuSE Linux 6.4](https://kernelhive.madekivi.fi/os/suse64) is installed by SuSE's own graphical **YaST2** — what its CD really boots, not the text YaST everyone remembers
- [Amiga UNIX](https://kernelhive.madekivi.fi/os/amix) installs from a 29-segment tape image, the way an *A3000UX* really did — roughly two hours of emulated restore
- **OPEN LOOK** is the desktop Sun and AT&T backed against **Motif**; Amiga UNIX is the only machine here that runs it
- [bootOS](https://kernelhive.madekivi.fi/os/bootos)'s floppy carries chess, a Doom, a BASIC and a Flappy Bird, each one sector long; you run one by typing its name
- Type `enter` on bootOS and it takes a program as lines of hex; the 'Hello, world' from its own manual is the exhibit's demo button
- [PC/GEOS Ensemble](https://kernelhive.madekivi.fi/os/pcgeos) boots straight into its desktop from FreeDOS, and its word processor stopped crashing once one font was dropped
- [AIX](https://kernelhive.madekivi.fi/os/aix432)'s graphics card had to be identified from a driver's file name before its cursor could be read back at all
- [Mac OS 7.5.3](https://kernelhive.madekivi.fi/os/macos753) keeps its pointer in low memory, and the museum writes it there the same way the system's own mouse driver does
- [Rhapsody](https://kernelhive.madekivi.fi/os/rhapsody)'s pointer lives at an address belonging to one saved disk, so the emulator checks it before every write and refuses if it moved
- A new tool finds the cursor in a captured frame, which is how each of these loops was proved rather than assumed
- [OpenBSD](https://kernelhive.madekivi.fi/os/openbsd)'s tablet pointer needed one fix after X registered the same device twice, once with no calibration range
- [ravynOS](https://kernelhive.madekivi.fi/os/ravynos) 0.6.1 is the last of its kind — days after this build, its makers threw the FreeBSD kernel away and deleted the line

*76,663 lines of code.*

### Earlier weeks

- [Week 4 · The doors open to everyone](docs/RELEASE-NOTES.md#week-4) · 2026-08-23 09:00 – 2026-08-30 09:00
- [Week 3 · The museum gets its own internet](docs/RELEASE-NOTES.md#week-3) · 2026-08-16 09:00 – 2026-08-23 09:00
- [Week 2 · Twenty-two machines in one week](docs/RELEASE-NOTES.md#week-2) · 2026-08-09 09:00 – 2026-08-16 09:00
- [Week 1 · The museum opens its source](docs/RELEASE-NOTES.md#week-1) · 2026-08-07 14:37 – 2026-08-09 09:00
- [Week 0 · The month the museum was built](docs/RELEASE-NOTES.md#week-0) · 2026-07-07 21:39 – 2026-08-07 14:37

Full archive: [`docs/RELEASE-NOTES.md`](docs/RELEASE-NOTES.md).

Every machine named here is live at [kernelhive.madekivi.fi](https://kernelhive.madekivi.fi).
<!-- release-notes:end -->
## A reading tour

Five documents worth reading even if you never run any of this.

1. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — the whole system in one
   sitting, including the awkward truth that for a large part of the collection
   the thing being captured is not the machine you came to see, but a bare
   Linux screen with a period emulator filling it edge to edge.
2. [`docs/INPUT-LATENCY.md`](docs/INPUT-LATENCY.md) — where every millisecond
   between a key press and the pixel changing actually goes, stage by stage,
   measured rather than assumed, with what is left to win.
3. [`docs/lab/nt4-cirrus-vmstate-trace-fix.md`](docs/lab/nt4-cirrus-vmstate-trace-fix.md)
   — a detective story: Windows NT 4 cold-boots to a clean desktop but always
   restores a blue-lavender one, and the culprit is a struct being read at the
   wrong offset. The before-and-after screenshots are in
   [`docs/lab/nt4-cirrus-vmstate-proofs/`](docs/lab/nt4-cirrus-vmstate-proofs/).
4. [`docs/lab/RETRONET-BRIEF.md`](docs/lab/RETRONET-BRIEF.md) — the design for
   an internet that only goes backwards: what a 1997 browser needs, why every
   service is offline by construction, and what it costs to put a real machine
   on it without breaking it.
5. [`docs/guests/irix.md`](docs/guests/irix.md) — one machine, at length. An
   SGI Indy with no window, no virtual machine and no display at all, publishing
   frames into shared memory, and the long list of performance angles that were
   measured and closed — including the one closed in error and reopened.

If a word in any of these is unfamiliar,
[`docs/GLOSSARY.md`](docs/GLOSSARY.md) is the whole vocabulary on one page.

---

<details>
<summary><b>Status — a home lab, not a product</b></summary>

<br>

Personal home-lab project. Everything here is built against one specific
machine ("the lab box"), a single Proxmox host. The code is published for
reading, reuse and reference; reproducing the full gallery is real work, and
the docs describe that work rather than hiding it behind an installer.

The public gallery is reachable over the internet, but every session is
authenticated — by passkey, on an invited account or a self-registered one.

</details>

<details>
<summary><b>Building the pieces</b></summary>

<br>

**SPA** (works on any machine with Node.js and npm):

```sh
cd spa
npm ci
npm run build     # a placeholder src/data/credentials.ts is created
                  # automatically from credentials.example.ts
npm run dev       # local dev server
```

**streamhost** (Linux; links the system libx264):

```sh
sudo apt-get install libx264-dev libopus-dev libclang-dev pkg-config cmake
cd streamhost
cargo build --release
cargo test
```

Everything else — station launchers, seed-image builders, `labctl` — assumes
the Proxmox lab host and its VM inventory. Follow the
[reproduction quickstart](docs/REPRODUCE-QUICKSTART.md) for the required
external inputs and the ordered full-box runbook chain.

</details>

<details>
<summary><b>Hardware and scope</b></summary>

<br>

This assumes a single Linux host (Proxmox VE in production) with enough CPU and
RAM to run the fleet plus a per-station encoder — the lab box is a Supermicro
server, not a laptop. There is no cloud deployment path and no installer: the
[reproduction quickstart](docs/REPRODUCE-QUICKSTART.md) separates what builds on
any machine (the SPA, the `streamhost` daemon) from what only makes sense
against the Proxmox host and its VM inventory (station launchers, seed-image
builders, `labctl`).

</details>

<details>
<summary><b>Repository layout</b></summary>

<br>

| Path | What lives there |
| --- | --- |
| `streamhost/` | Rust streaming daemon (WebTransport + in-process libx264/Opus), per-station launchers, in-guest agents, crate docs in `streamhost/docs/` — **GPL-2.0-or-later** |
| `spa/` | The gallery front-end: Vite + React + TypeScript, WebCodecs decode |
| `tests/e2e-live/` | Playwright suite that drives the *live* lab box — not run in CI |
| `scripts/` | Ops tooling: `labctl` (unified box CLI), `build-guests/` (per-OS seed-image builders), `serve/` (HTTPS server for the SPA), `dev/` (build-and-deploy loop) — indexed in [`scripts/README.md`](scripts/README.md) |
| `registry/` | The station registry (source of truth for the roster) and per-station poster prose |
| `docs/` | `lab/` runbooks and hardware notes, `guests/` per-OS notes, `catalog/` media and software catalogs, `history/` retired status docs — indexed in [`docs/README.md`](docs/README.md) |
| `.github/workflows/` | CI: Rust fmt/clippy/test, SPA lint/build, shell + Python + workflow lint |

</details>

<details>
<summary><b>Addresses and hostnames in these docs are placeholders</b></summary>

<br>

Every IP, hostname and domain shown in this repository (`192.0.2.10`,
`labhost.lan`, `example.com`, and similar RFC 5737 / `.example` values) is a
stand-in for the operator's real lab box, substituted throughout before this
repo was published. The one deliberate exception is the gallery's own public
address, `kernelhive.madekivi.fi`.

Placeholders are not wrong values to fix, and they will not resolve —
reproducing the stack means supplying your own via `registry/local.env` (see
`registry/local.env.example` and [`registry/README.md`](registry/README.md)) and
the other gitignored, operator-local files listed in `.gitignore`. A deployment
left on the placeholders builds but is unreachable. Please don't submit patches
that put real addresses, hostnames or credentials back into the repo.

</details>

<details>
<summary><b>The MAME fork</b></summary>

<br>

Several exhibits (SGI IRIX, the Microprofessor II) need MAME patches that are
not upstream. Those patches are published, one commit per patch, on a fork of
MAME at [github.com/Wnt/mame](https://github.com/Wnt/mame), on branches `irix`,
`irix-experimental` (working patches deliberately not shipped in the default
stack), and `mpf2`. The fork exists to support Kernel Hive.

</details>

<details>
<summary><b>Contributing</b></summary>

<br>

See [`CONTRIBUTING.md`](CONTRIBUTING.md): what can be built and verified
without lab hardware, the CI quality gate, and PR expectations.

</details>

<details>
<summary><b>License</b></summary>

<br>

The repository is MIT-licensed (see `LICENSE`), with two exceptions:

- `streamhost/` is **GPL-2.0-or-later** (see `streamhost/LICENSE`) because the
  daemon links the system libx264, which is GPL. The two trees are independent
  — nothing outside `streamhost/` links against it.
- The historical photographs under `spa/public/posters/*/gallery/` are
  third-party works reused under free licenses (public domain, CC0, CC BY,
  CC BY-SA) and remain their authors' property. Every image's author, license
  and source page is listed in [`docs/IMAGE-CREDITS.md`](docs/IMAGE-CREDITS.md);
  the licenses are enforced mechanically against the Wikimedia Commons API by
  `scripts/tools/fetch-poster-gallery.py` (re-check with
  `make poster-gallery-verify`). CC BY-SA images carry share-alike obligations
  on modified redistribution.

</details>
