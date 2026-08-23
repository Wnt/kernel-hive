# rhapsody's web browser — OmniWeb 3.0, as-built

**Status: PROVEN on a bring-up rig, not yet in the golden.** `rhapsody` (Apple
Rhapsody 5.1 DR2 for Intel, 1998) now has a real graphical web browser —
**OmniWeb 3.0 final (July 1999)** — installed into `/Local/Applications`,
launchable from an icon in the open `guest` home window, and rendering the
local web corpus through the retronet gateway's **`:80` origin door with no
proxy**. Framebuffer proof: the 1996 Space Jam page, images and all, at
`http://spacejam.com/index.cgi`.

The network half of this station is [`WEB-STATION-rhapsody.md`](WEB-STATION-rhapsody.md);
the guest's own history is [`docs/guests/rhapsody.md`](../../guests/rhapsody.md).

## The finding that started this

`registry/stations/rhapsody.json` declared `"periodBrowser": "OmniWeb 3"`. That
was **metadata, not fact**. DR2 ships no web browser at all:

- `/Local/Applications` — empty (two directory-icon dotfiles, nothing else)
- `/System/Applications` — `Clock`, `Grab`, `HelpViewer`, `MailViewer`,
  `Preferences`, `PrintManager`, `Preview`, `TextEdit`
- `/NextApps`, `/LocalApps` — do not exist on this release

OmniWeb was the *only* native browser the NEXTSTEP/OPENSTEP/Rhapsody line ever
had, so the declared browser was also the only real candidate.

## What was installed, and from where

| | |
|---|---|
| Browser | **OmniWeb 3.0 final**, Omni Group, July 1999, for Mac OS X Server 1.x / Rhapsody, **Intel** |
| Source | `http://apps.rhapsodyos.org/rhapsody/OmniGroup_Apps/OmniWeb/OmniWeb-3.0-MXS-IP.gnutar.gz` — David Shaw's rhapsodyos.org mirror of the vanished Omni Group FTP |
| File | `OmniWeb-3.0-MXS-IP.gnutar.gz`, **3,170,339 B**, md5 `d90bb9a174b588c456d4c77b9d1603e5`, sha256 `30ffc4294c487fd175f8f66205b7f537634d054472da37c18ac948cf8e2a2fba` |
| Shape | a plain gnutar of one `OmniWeb.app` (9.5 MB installed, 773 entries). **Not** a `.pkg` — no `Installer.app`, no GUI keystrokes |
| Binaries | fat Mach-O, **i486 + ppc**. Outer `OmniWeb.app/OmniWeb` is a launcher wrapper; the real browser is `Resources/OmniWeb.app/OmniWeb` |
| Self-contained | **11 Omni frameworks** (`OmniFoundation`, `OmniAppKit`, `OmniBase`, `OmniHTML`, `OWF`, `OIF`, `OmniNetworking`, `OmniJPEG`, `OmniPNG`, `OmniZlib`, `OmniZuul`) and 10 plugins (gif, jpeg, png, xbm, inflate, Gopher, appkit-render, mailto, Preferences, OmniBundlePreferences) live **inside the bundle**, all version 1999C. DR2's own frameworks are not a factor and nothing else needs installing |
| Licence | `OmniWeb-FreeSingleUser.omnilicense` ships in the bundle — "Free 1-user license courtesy of Omni" |

### Take the 3.0 final, never the 3.0b8b that is easier to find

The build most mirrors carry (and the one on the `omniweb_rhapsodyDR2.iso`
floating around, md5 `3419f5b8865bc3b2117d7dc5a413125e`) is **OmniWeb 3.0b8b**,
whose own `.info` says it *"expires on Jan 31, 1999"* and whose binary contains
`%@ [Expiring Beta Release]`. It only runs with the guest clock rolled back, and
that CD ships frameworks `1998G` while the app demands `1998G2` — a version
mismatch on the media itself. The 3.0 final pinned above contains **no**
expiry string and needs no companion framework install. `OmniFrameworks-1998G2`
exists and is *not* required; fetch it only if OmniPDF/OmniImage are ever
wanted.

## How the bits get in — a raw second IDE disk

The guest had no network when this work started, and there is **no ISO tooling
on the box** (`xorriso`, `genisoimage`, `mkisofs`, `pycdlib` are all absent), so
authoring an ISO9660 would have added a build dependency the coordinator may not
have. DR2 also opens **no usable raw node for an ATAPI CD**: the drive is
detected (`hc1: Drive 0: ATAPI CD-ROM`) and `/dev/od0a`/`/dev/rod0a` exist, but
reads from them fail without a real filesystem on the medium.

What works, with zero host dependencies and no filesystem at all:

```
truncate -s 8M payload.img && dd if=OmniWeb-3.0-MXS-IP.gnutar.gz of=payload.img conv=notrunc
qemu ... -drive file=payload.img,format=raw,if=ide,index=1
# in the guest, over the serial root shell:
dd if=/dev/rhd1a bs=8192 count=1024 | gzip -dc | gnutar xf -
```

`/dev/rhd1a` reads from **offset 0 of the disk** and needs no disklabel — the
gzip magic `037 213 \b` is the first thing `od -c` shows. `gzip -dc` stops at the
end of the stream and `gnutar` stops at the end-of-archive blocks, so the
trailing zero padding costs nothing.

> **The payload disk is a bring-up device only.** The production launcher's
> device set is unchanged. Attach it for the install, detach it, then cold-bake
> the golden. `loadvm golden` requires the same device set, so a golden baked
> with the payload disk attached would permanently require that disk.

**It provokes a modal panel.** Workspace sees an unformatted disk and puts up
*"The scsi disk is unreadable. Click Initialize to completely erase the disk and
format it for Rhapsody"*. It is harmless — Initialize would erase the **payload**
disk (`hd1`), never the system disk — and it never reaches the golden, because
the disk is detached before the bake. Dismiss it with **Return** (the default
button is *Ignore*); do not try to click it with the pointer while other work is
in flight. Setting `Workspace AllowUnformattedDisks NO` does **not** suppress it
— measured, both ways.

Fallbacks, noted and deliberately not built: base64 over the serial getty (a
9600-baud line, ~90 minutes for this payload) and, now that the retronet is up,
an FTP pull from the gateway.

## Making it discoverable from the desktop

The Platinum desktop is Workspace Manager: a right-edge **Dock** (`rhapsody`
disk, `guest` home, `Applications`, `MailViewer.app`, `TextEdit.app`,
`Preferences.app`, `Trash`) plus the `guest` home window open in the middle of
the screen. Three things were measured here, and two of them are traps.

### The Dock cannot be scripted, and its `Applications` icon is the wrong folder

Workspace exposes the Dock only through
`getDockSize:launchFlags:hideFlags:wmSlot:trashSlot:` — a packed structure
behind a Distributed Objects call. It is **not** a user default: the `Workspace`
domain is empty on a stock login, gains nothing when Workspace is asked to
save, and the stock Dock tiles come from somewhere no defaults write reaches.
Worse, the Dock's `Applications` tile opens **`/System/Applications`**, not
`/Local/Applications`, so a browser installed in the standard place is three
clicks deep (`Local` → `Applications` → `OmniWeb.app`) from the one Dock icon a
visitor would try.

### A symlink in the home window launches as "damaged"

The obvious cheap icon — `ln -s /Local/Applications/OmniWeb.app ~guest/` — puts
a **generic** icon in the home window and, on double-click, produces
*"Couldn't start up this application because it is damaged."* Workspace will not
launch a bundle through a symlinked path. The home-window entry must be a **real
bundle copy** (9.5 MB, `gnutar cf - | gnutar xf -`); copied that way it shows
OmniWeb's own globe icon and launches normally.

### Autolaunched apps start hidden

`Workspace` domain key **`LaunchPaths`** (an array of app paths) does autolaunch
the browser at login — the process is running, `~/Library` and
`OmniWeb.defaults` appear — but **no window is ever drawn**, with or without
`HomePage`/`ShowHomePage` set. Autolaunching the *document* instead of the app
draws nothing either. There is no defaults path to an autolaunched app with an
open window.

And the window cannot be opened from the serial shell: `open` and OmniWeb's own
`openURL` both die with `bootstrap_look_up returned bootstrap unknown service` —
a serial login is not in the console session's Mach bootstrap namespace.

### So: what ships

- Canonical install at **`/Local/Applications/OmniWeb.app`** (the standard place;
  this is also what registers OmniWeb as the handler for `.html`, which gives
  every HTML file on the desktop an OmniWeb document icon).
- A **real bundle copy at `/Local/Users/guest/OmniWeb.app`**, so the visitor sees
  an OmniWeb globe icon in the home window that is already open on the fixture
  screen, one double-click from a browser. Costs 9.5 MB of a 1.5 GB-free disk.
- `LaunchPaths` pointed at that copy, so the app is already warm (a cold OmniWeb
  launch under TCG takes ~60 s; activating a running one is immediate).
- **The golden is baked with the OmniWeb window open on the corpus home page.**
  The golden is a RAM snapshot, so a single pointer double-click before the bake
  is what every visitor sees forever after. This is the step that actually
  delivers "discoverable", and it is a coordinator action — see below.

## Which gateway door, and why

**The `:80` origin door, seamlessly, with no proxy configured.**

OmniWeb's `OWF` framework implements `hostHeaderStringForURL:` — it sends a
`Host:` header — so the gateway's origin door can select the corpus site from
the request the way the Windows stations' browsers do. Confirmed end to end on
the framebuffer: with only `HomePage = http://spacejam.com/index.html` set and
no proxy anywhere, OmniWeb resolved `spacejam.com` through the wildcard DNS,
followed the redirect to `/index.cgi` and rendered the 1996 page with its
images.

This is the **opposite** of the os2warp result
([`WEB-STATION-os2warp.md`](WEB-STATION-os2warp.md)), where IBM WebExplorer 1.2
sends no `Host:` header at all and the origin door can only answer `400`,
forcing the classic proxy door on `10.99.0.2:3128`. Do not copy the os2warp
proxy configuration here; it is not needed and would only add a failure mode.

If a proxy is ever genuinely required, the key is `OWProxyServers` in the
`OmniWeb` domain — an array of dictionaries read by
`+[OWProxyServer proxyServersFromDefaults]`. **That format was not reverse
engineered and is not scripted**, because the station does not need it; the
supported route is the GUI, Preferences → Proxies.

## The script

`scripts/dev/rhapsody-install-browser.sh` — idempotent, self-verifying,
**17 checks**.

```
rhapsody-install-browser.sh image   <out.img> [payload.gnutar.gz]
rhapsody-install-browser.sh install <rig-dir> [--homepage URL] [--no-home-icon]
rhapsody-install-browser.sh verify  <rig-dir> [--homepage URL]
```

`image` fetches the pinned payload if absent, **asserts its sha256 and byte
size**, and writes the raw 8 MiB payload disk. `install` drives the guest over
the serial getty in `<rig-dir>` (a bring-up rig, or the station directory), and
re-running it is a no-op that still verifies: the extraction is skipped when the
inner executable is already in place, and the copy is skipped when the home
bundle is already a real directory. `--homepage` is the parameter that carries
the corpus address, so Stream B's addressing plugs straight in; it defaults to
the fleet landmark `http://spacejam.com/index.html`.

The checks cover the payload device and its gzip magic, both executables, the
**i386 slice**, the bundled licence, the **absence of the beta expiry string**,
the bundled frameworks, installed size, the home copy *including that it is not
a symlink*, its ownership, all three preference keys, and free disk space.

### Two constraints the script encodes

- **Every guest command is one line.** The root getty is **tcsh** and
  `serialexec` sends a single line; a heredoc pushed down this channel is parsed
  line-by-line by tcsh, which silently mangles the file it was supposed to
  write and leaves `defaults write` calls half-applied. This cost a full debug
  cycle: `HomePage` looked set and was not.
- **Verification is slow.** Each check is its own serial login (the getty
  respawns between commands), so a full `verify` takes several minutes. That is
  the exec channel's shape, not a bug.

## What was measured, and what was not

**Proven on the bring-up rig** (`/data/vms/sandbox/rn-rhapsody-browser`):

- OmniWeb 3.0 installs from the raw payload disk and the guest's own `file`
  reports `Mach-O executable i386` for the inner binary.
- It launches from the home-window icon and renders **`http://spacejam.com`
  from the retronet corpus, with images**, through the `:80` origin door with no
  proxy. This is the framebuffer proof.
- The GIF plugin works (the Space Jam page is entirely GIFs).
- Pointer dead reckoning at **0.15 s pacing** lands clicks on the exact pixel;
  at 0.05 s the DR2 PS/2 driver sign-flips and the cursor bolts to a corner.
  Anything driving this desktop by pointer must pace at ~150 ms, and should
  prefer `send-key ret` for modal panels with a default button.

**Not proven / left open:**

- Nothing was done to the **live station** and no golden was baked. The
  coordinator owns that.
- HTTPS, CSS, frames beyond the corpus, and any page heavier than the 1996
  corpus are untested. OmniWeb 3.0 is an IE4/Netscape4-era engine.
- Audio, downloads, Gopher plugin, and the mailto plugin are untested.
- The Dock remains un-scripted (see above); the exhibit relies on the home-window
  icon and the baked-open window instead.

## Running it during integration

1. Cold-boot the station's disk on the production launcher's device set **plus**
   `-drive file=<payload>.img,format=raw,if=ide,index=1`. `loadvm` is not
   possible with the extra disk — this must be a cold boot.
2. `rhapsody-install-browser.sh image /path/payload.img` (once), then
   `rhapsody-install-browser.sh install <station-dir> --homepage <corpus URL>`.
3. Dismiss the *"scsi disk is unreadable"* panel with **Return**.
4. Double-click `OmniWeb.app` in the open home window (it sits at roughly
   **x=238, y=310** at 1024×768 when `Mailboxes` is the only other entry) and
   wait for the home page to render.
5. Shut the guest down, **detach the payload disk**, cold boot on the production
   device set, bring OmniWeb up on screen once more, and bake the golden with
   the browser window open.
