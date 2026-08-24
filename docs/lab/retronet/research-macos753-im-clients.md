# macos753 IM client recon — what could put it on the retronet ICQ gateway

**Status: RESEARCH ONLY.** No station touched, nothing installed. This answers
"what client, on what door" for the fleet's Tier-D station
([`ICQ-ONBOARDING-PLAN.md`](ICQ-ONBOARDING-PLAN.md)) now that the Tier-D
blocker — no NIC — is gone: `macos753` joined the retronet **web** plane on
2026-08-23 ([`WEB-STATION-macos753.md`](WEB-STATION-macos753.md)), with a
working MacTCP stack on a real bridged tap. This document is the ICQ/AIM
follow-on to that bring-up, not a repeat of it.

## The machine, restated as constraints on every candidate

From [`WEB-STATION-macos753.md`](WEB-STATION-macos753.md) and
[`docs/guests/macos753.md`](../../guests/macos753.md):

- **68k only.** `qemu-system-m68k -M q800 -cpu m68040`. No PPC code will run —
  this eliminates the great majority of Mac IM clients, whose useful lifespan
  is almost entirely PowerPC.
- **MacTCP 2.0.6, not Open Transport.** Static `10.99.0.23`, DNS `10.99.0.2`,
  **gateway `0.0.0.0` — no default route.** MacTCP is dormant until an
  application opens it (no ARP, no traffic, until then), and does not survive
  a force-quit of the app holding it (guest restart is the only recovery).
- **A real bridged NIC, not slirp.** This is the single most consequential
  fact for the door choice below. `macos753` has a persistent tap on
  `vmbr-rn`, wired exactly like `beos`, **not** behind a QEMU `guestfwd`
  pinhole like the Windows fleet. `GATEWAY.md`'s entire "two doors" design
  (5190 vs 5191, BOS-address mismatch across slirp) exists **only** for
  slirp-behind stations. It does not apply here. Whatever door a client
  speaks, the guest dials `10.99.0.2` on it directly — TCP 5190 (OSCAR), UDP
  4000 (legacy), and TCP 9898 (TOC) are all equally reachable, the same as
  they are for `beos`.
- **128 MB RAM, 32-bit addressing ON, 7680K disk cache** — all baked into the
  golden. Netscape 3.04 needs a 24000K partition to avoid heap-exhaustion
  crashes; any IM client competing for RAM should be sized with that fact in
  mind, though IM clients of this era are far lighter than a browser.
- **No shell, no exec channel, no telnet, no ftpd.** Files go in only via the
  offline `hmount`/`hcopy -b`/`hcopy -m` route against a raw disk copy
  (`WEB-STATION-macos753.md` §"Getting files into a guest"). This is *harder*
  than `beos` (which grew a telnetd) — every install and every config edit is
  either baked in offline or driven through the ADB-pointer/QMP framebuffer
  loop, with all four traps `WEB-STATION-macos753.md` documents (modal alerts
  swallow input, clicks need a ~0.35s hold, MacTCP's tab order is row-major,
  keystrokes drop under TCG load).

## Is the already-sourced media usable? — Yes, and it was sourced correctly

[`ASSETS-MANIFEST.md`](../ASSETS-MANIFEST.md) §"`macos753` — retronet AIM
client media (Tier D, media-only so far)" already holds
**`AIM_installer_2.01.617.sit`** (AOL Instant Messenger 2.01.617, 1999,
2 538 648 bytes, sha256 `965f5c9c…f71cec`, from
[macintoshrepository.org/1213](https://www.macintoshrepository.org/1213-aol-instant-messenger-2-x-68k-)).

**The manifest row's own text is now stale in one specific way and correct in
every other.** It says networking "doesn't exist on this station today" and
gates the whole row on a "NIC add → cold rebuild" that is "separate future
work" — that gate **fired and closed** on 2026-08-23. The media itself was not
sourced against a wrong assumption: the manifest's own prior analysis already
did the hard part right —

- **68K-native, confirmed by binary inspection, not label alone.** `unar`-
  extracted, the `InstallAIM` binary's data fork literally says *"The Thead
  [sic] Manager extension is required to run AIM. It is built into all MacOS
  computers running system 7.5 or later"* — exactly this guest's OS — and its
  internal CPU-family tags are `68K Only` / `68020`/`68030`/`68040`, matching
  the Quadra 800's 68040.
- **It is a genuine period OSCAR client**, and it is also the **last 68K-
  compatible AIM build** (`AOL Instant Messenger 2.0.531` / `2.01.617` — the
  next architectural jump, AIM Phoenix / 4.x, needs the CFM-68K 4.0 runtime
  extensions and is the point the lineage goes PPC-first).
- The manifest's own reasoning for AIM over any Mac ICQ build (Mac ICQ topped
  out at 68K version 1.7.2, and *that specific claim needs a correction* — see
  below) still holds as the reason to prefer AIM as the **primary** candidate,
  just not as the only one worth recording.

**What I could not verify from any source: whether AIM 2.01.617 requires Open
Transport at runtime, or works over MacTCP.** No system-requirements page,
period review, or readme found in this pass states it explicitly either way.
Two weak positive signals, neither conclusive: (1) the installer declares
System 7.5 as its floor, which is the era MacTCP was still the default stack
on most machines (Open Transport shipped with 7.5 but wasn't universally
adopted until later, and Apple's OT ships its own MacTCP-compatible
emulation layer regardless, so most software of this vintage runs on either);
(2) the manifest's own binary audit turned up no Open-Transport-specific
import or string. Neither is proof. **Mark UNVERIFIED — this is the one thing
an install attempt must check first**, precisely the way `WEB-STATION-
macos753.md` had to check MacWeb's `Host:` header behavior empirically rather
than assume it.

## New candidate found this pass: MacICQ 1.7.2b0 (1999)

Not in the manifest. Found via [Macintosh Repository's ICQ
page](https://www.macintoshrepository.org/578-icq), which lists two Mac ICQ
downloads:

| Version | Year | Arch | Requirements | Size |
|---|---|---|---|---|
| MacICQ v3.4 | 2003 | **PPC only** | Mac OS 9.x–X | 3.56 MiB |
| **MacICQ v1.7.2b0** | 1999 | **68K + PPC (FAT binary)** | **Mac OS 7.1.1 – 9.2.2**, min **5 MB free RAM** | 878.39 KiB / 899.47 KB |

`ASSETS-MANIFEST.md`'s existing note that "Mac ICQ topped out at 68K version
1.7.2" is **essentially right but one digit short of the full picture**: the
actual last 68K release is **1.7.2b0** (a beta, per the FAT-binary listing
above), not a plain 1.7.2. Not a material correction to the manifest's
argument — 1.7.2/1.7.2b0 is still pre-OSCAR either way — but worth recording
precisely, since a later agent chasing "1.7.2" by that exact string might miss
the file that actually exists.

**Availability, verified within this pass's read-only limits:**

- Product page `https://www.macintoshrepository.org/578-icq` — **GET, HTTP
  200**, confirmed reachable.
- Download interstitial `https://www.macintoshrepository.org/download.php?id=990`
  — **GET, HTTP 200**, confirmed reachable, but the response is a click-
  through/token HTML page, not the `.sit` itself (the site gates the actual
  binary behind a further in-page action, not a directly-curlable URL). The
  878.39 KiB size above is the figure the *listing page* reports, not one
  independently measured from the bytes — **UNVERIFIED against the actual
  file**, and I did not chase the click-through further: the brief is to
  establish availability, not stage media, and this is a small, clearly-
  described, single-purpose listing (SHA1 `906697e2827d0b50c4018207944749c0d7145c58`
  published on the same page) — low-risk to fetch properly whenever a
  build agent actually needs the bytes.

**Protocol version — the open question that matters most here, and it is
UNVERIFIED.** `GATEWAY.md` has only proven the legacy UDP-4000 door for **v4**
(`beos`/ICBM .71) and **v5** (`os2warp`/ICQ-2 1.503i); **v2 remains
unproven**, and the doc is explicit that a v2 client's compatibility with this
specific server build is an open question. Mac ICQ 1.x's exact wire-protocol
version was not established in this pass — its era (1997–1999, contemporary
with Mirabilis's own ICQ 97/98/99a Windows line, all pre-99b) makes v2, v3 or
v4 all plausible, and only extracting strings from the actual binary (or a
live handshake) would settle it. Given beos already proved v4 works, an
install attempt should check for a v4 signature first as the best-odds guess,
but **do not assume it** — this needs the same "check explicitly" treatment
`WEB-STATION-macos753.md` gave MacTCP-vs-DHCP and MacWeb's `Host:` behavior.

## TOC (9898) — no period Mac client found

Both non-Windows precedents considered TOC and found nothing: os2warp's own
doc states flatly "there is **no OS/2 TOC client at all**." I searched
specifically for a classic-Mac TOC client this pass and found the same result.
TOC's own clients were AOL's reference implementations — **TiK** and **TAC**
(Tcl/Tk), **TNT** (Emacs Lisp), and a Java applet (**TIC**/Quick Buddy) — none
of them a native Mac application, and none 68k-capable in any form that would
give this exhibit a real GUI. Gaim (the direct ancestor of what `tru64` runs)
started as a TOC client but is X11/GTK, not Mac. **No native 68k Mac TOC
client is known to exist.** Recorded as a negative result so the next agent
does not re-search this: TCP 9898 is a live door on the gateway, but it has no
candidate for this machine, same as it has none for `os2warp`.

## Ranked recommendation

### 1. AIM 2.01.617 (already sourced) — recommend as primary

| | |
|---|---|
| Name / version / year / author | America Online Instant Messenger 2.01.617, 1999, AOL |
| 68k / 7.5.3 / MacTCP | **68k: confirmed** (binary CPU tags + Thread Manager string). **System 7.5.3: confirmed** (installer's own floor). **MacTCP: UNVERIFIED** — no explicit requirement found either way; see reasoning above |
| Door | **TCP 5190, OSCAR** — reachable directly, no slirp complications on this station |
| Roster model | **Client-local.** AIM's buddy list of this era is a local prefs file, not SSI. `ICQ-ONBOARDING-PLAN.md` already anticipated this exact client and named it "an AIM client, so a client-local alias" — this pass confirms that plan is still the right shape. It does **not** join the SSI cross-list; it would need the same one-contact, client-local seeding pattern as `beos`/ICBM and `os2warp`/ICQ-2 |
| Identity model | **AIM screenname, not ICQ UIN.** The fleet's reserved identity for this station is UIN `75300`, but AIM 2.01.617 cannot use a UIN — it authenticates as a screenname. This is **not a blocker per the brief's own framing** ("an AIM-screenname client is not automatically disqualified... a coordinator decision, not a blocker"), and `rn-tool.py`'s own account model already distinguishes `is_icq` from AIM accounts and keys `feedbag`/SSI by `screenName` regardless of which kind it is — the gateway was built to carry both. Flagging explicitly: shipping this client means macos753 is the fleet's first identity exception, a screenname sitting where every other station carries a UIN |
| Reconnect | **UNVERIFIED.** No period documentation of AIM 2.x's reconnect behavior was found this pass. Given the fleet's pattern (three stations now decided by exactly this question — ICQ 2001b self-heals, Gaim autoreconnects, ICBM .71 needs a watchdog), this must be measured empirically before committing to a golden shape. Budget for the possibility this station needs its own watchdog, the way `beos` did |
| Download | **Already verified** in `ASSETS-MANIFEST.md`: 2 538 648 bytes, sha256 `965f5c9c4f6d796e1c3f347fc5ec05693b9aa27848679bda98f2cb3fc4f71cec`, matches the site's own published sha1. Staged in the content-addressed media archive, never committed |
| Exhibit value | **High.** A real 1999 Mac AIM window — buddy list, chat windows, the actual client teenagers used — on a machine running a 1996 OS. Directly comparable to what `beos` delivers with ICBM, and stronger than a text-mode or Java client |

### 2. MacICQ 1.7.2b0 (new candidate) — recommend as a considered alternative, not a replacement

| | |
|---|---|
| Name / version / year / author | MacICQ 1.7.2b0, 1999, Mirabilis (ICQ Inc.) |
| 68k / 7.5.3 / MacTCP | **68k: confirmed** (FAT binary, listing states 68K+PPC). **System 7.5.3: confirmed** (listing floor is 7.1.1). **MacTCP: UNVERIFIED**, same caveat as AIM — no explicit statement found |
| Door | **UDP 4000, legacy pre-OSCAR — exact version UNVERIFIED** (v2/v3/v4 all plausible for this era; v4 is the best-odds guess since `beos` already proved it, but this is a guess, not a finding) |
| Roster model | **Client-local**, consistent with every pre-2001b ICQ generation on this fleet (matches the Windows fleet's ICQ 2000b row, and `os2warp`'s ICQ/2) |
| Identity model | **ICQ UIN** — matches the fleet's reserved `75300` naturally, unlike AIM. This is its one structural advantage over the AIM candidate |
| Reconnect | **UNVERIFIED** — nothing found this pass; would need the same empirical check as AIM |
| Download | **Page and download-interstitial both verified reachable (HTTP 200)**; the actual `.sit` bytes were **not** fetched — the site gates them behind a click-through the brief doesn't warrant chasing for an availability check. Listed size 878.39 KiB / 899.47 KB, SHA1 `906697e2827d0b50c4018207944749c0d7145c58` per the listing page (not independently re-measured) |
| Exhibit value | Plausible but unmeasured — pre-OSCAR ICQ clients of this vintage are typically a plainer contact-list-plus-message-window UI than AIM's, but this is a guess without having seen it run |

**Why AIM ranks first despite the UIN mismatch:** its media is fully sourced
and independently hash-verified today, its 68k/System-7.5.3 fit is proven at
the binary level (not just a version-string claim), and it satisfies the
brief's stated preference — "prefer period-authentic and native," "a native
Mac GUI client beats... other things equal" — at least as well as MacICQ does,
while removing the one variable MacICQ still carries (unresolved legacy
protocol version). The screenname-vs-UIN mismatch is real but the brief itself
says explicitly this is a coordinator call, not a technical disqualifier — and
the gateway's own account model was built to carry it.

**If the UIN match matters more to the coordinator than a bird-in-hand media
source, MacICQ 1.7.2b0 is the fallback worth fetching next** — small file,
clear provenance, but budget time to (a) actually pull the bytes through the
site's click-through, (b) extract protocol-version evidence from the binary
before assuming v4, and (c) verify MacTCP compatibility the same way
`WEB-STATION-macos753.md` verified everything else on this station: by trying
it and reading the framebuffer, not by assuming a spec sheet.

## What I could not determine

- **MacTCP vs. Open Transport for either candidate.** No definitive source
  found. This is the single highest-value thing an install attempt should
  check first, since MacTCP incompatibility would eliminate the candidate
  outright regardless of every other property.
- **MacICQ 1.7.2b0's exact legacy protocol version** (v2/v3/v4/v5). Would
  need binary inspection (`strings`/`nm`-style audit, the same technique
  `STATION-beos.md` used on ICBM.x86) or a live handshake against the gateway.
- **Either candidate's reconnect behavior** after an idle-pause/`labctl
  reset`. This has been the deciding operational fact on three stations
  already (`beos` needed a watchdog; `os2warp`'s golden-before-launch
  workaround; ICQ 2001b self-heals) and nothing found this pass answers it for
  AIM 2.01.617 or MacICQ 1.7.2b0.
- **Actual byte-verified size/hash for MacICQ 1.7.2b0** — the listing page's
  figures were not independently confirmed against downloaded bytes.

## Rejected / not viable

| Candidate | Why not |
|---|---|
| MacICQ v3.4 (2003) | **PPC only.** Fails the hardest filter outright |
| AIM 4.x / AIM Phoenix | Needs the CFM-68K 4.0 runtime extensions and targets 7.5–7.5.5 as a stretch, not a floor; 2.01.617 is the same lineage's clean, confirmed-68k, confirmed-OSCAR predecessor with no such dependency risk |
| Any native Mac TOC client | **None found to exist.** TOC's own reference clients (TiK/TAC/TNT/TIC) are Tcl/Tk, Emacs Lisp, and Java — none a native 68k Mac app. Same negative result the `os2warp` doc already recorded for OS/2 |
| A Java-based Mac IM client (e.g. the Mirabilis ICQ Java client used on `os2warp`) | Not investigated in depth — `os2warp`'s own verdict on the same Java client family ("sluggish"... "trades the responsive native desktop... for authorship provenance") applies at least as strongly here: a 68040 under TCG is a harder AWT target than the Warp 4 box that already found it wanting |

## Sources

- [macintoshrepository.org/1213-aol-instant-messenger-2-x-68k-](https://www.macintoshrepository.org/1213-aol-instant-messenger-2-x-68k-) — AIM 2.x 68K listing (already the manifest's source)
- [macintoshrepository.org/578-icq](https://www.macintoshrepository.org/578-icq) — MacICQ listing, both versions
- [macintoshgarden.org/apps/icq-34](https://macintoshgarden.org/apps/icq-34) — cross-reference, broader Mac ICQ version table
- [en.wikipedia.org/wiki/TOC_protocol](https://en.wikipedia.org/wiki/TOC_protocol) — TOC reference-client list (TiK/TAC/TNT/TIC)
- `docs/lab/retronet/WEB-STATION-macos753.md`, `docs/guests/macos753.md`,
  `docs/lab/retronet/GATEWAY.md`, `docs/lab/retronet/ICQ-ONBOARDING-PLAN.md`,
  `docs/lab/retronet/STATION-beos.md`, `docs/lab/retronet/ICQ-STATION-os2warp.md`,
  `docs/lab/ASSETS-MANIFEST.md`, `docs/catalog/os-media-catalog.md` — all read
  in full or by targeted section this pass
