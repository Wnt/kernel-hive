# c64basic — facts for release notes

**What arrived:** a second Commodore 64, at `/os/c64basic`. The first one
(`c64`) boots the GEOS desktop and stays that way. This one stops where every
C64 started in 1982: `**** COMMODORE 64 BASIC V2 ****`, 38911 BASIC bytes
free, `READY.` and a blinking cursor. The emulated machine is a PAL breadbin
(the original 6569 VIC-II and 6581 SID).

**Why a second one:** so the type-in code editor (☰ → ✎ Code editor) has the
museum's most famous home computer to type into. It joins the editor's
Commodore set: VIC-20, C64, PET 2001, CBM 8032, C128, Plus/4 and CBM-II.

**What a visitor can do:**
- Type BASIC on the keyboard, or paste a listing into the editor and watch it
  go in at the machine's own pace.
- Run three short programs written for this exhibit: Diamond Rings (all
  sixteen C64 colours as rings, drawn with a thousand POKEs because BASIC V2
  has no graphics commands), Border Colours (type 0–15 and the border changes)
  and Quick Draw (a reaction test on the jiffy clock).
- Open the Commodore 64 User's Guide and Programmer's Reference Guide from the
  editor or the exhibit notes.

**What was hard / worth saying:**
- It runs the GEOS station's exact emulator binary, byte for byte, copied into
  its own directory: the station launcher kills whatever runs from its own
  directory on reset, so sharing one would have reset both machines together.
- Keys were measured, not assumed: 60 ms hold / 60 ms gap delivered every
  plain key intact over long listings. The one known fault is shared with the
  other VICE machines: `:` or `*` occasionally arrives wrong (about 1 in 20 on
  the C64). That is being fixed in the emulator's key module, and the examples
  keep those characters few.

**Link:** https://kernelhive.madekivi.fi/os/c64basic
