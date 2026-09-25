# nokia9300 — facts for release notes

**What arrived:** the Nokia 9300 (announced September 2004, sold from 2005),
Nokia's smaller Series 80 v2 phone that opens to a 640x200 screen above a full
keyboard. The station runs the 9300's own firmware 5.22 (Symbian OS 7.0s,
Series 80 v2) in our fork of the open-source Symbian emulator EKA2L1
(github.com/Wnt/EKA2L1). On the full ROM stack, the firmware's own window
server, font and bitmap server and Eikon application framework draw the
screen. The emulator does not substitute its own versions of them.

**Year:** 2005 (firmware 5.22 is dated 16 November 2005; the 9300 was
announced on 8 September 2004 with sales planned for Q1 2005).

**Listed:** in the public gallery since 25 September 2026, at /os/nokia9300
(it ran unlisted while the full ROM stack was proven).

**What a visitor can do:** use the phone from its keyboard, which is the only
way the device itself worked. There is no pointer and no touchscreen. The
page draws the 9300 open with its Nordic key legends, and the drawn keys or
your own keyboard both work. F1–F4 are the four command buttons and F5–F12 the
application keys (Desk, Telephone, Messaging, Web, Contacts, Documents,
Calendar, My own). You can type in Documents, fill in a Sheet, and browse the
museum's archived web in Web, the 9300's Opera-based browser. Reset returns the
Desk.

**What was hard:**
1. Upstream EKA2L1 targets S60 and N-Gage games and runs Symbian's system
   servers as its own C++ reimplementations. Series 80 v2 had almost no
   support. Its wide 640x200 screen, its command-button layout and its
   keyboard all needed work in the fork before Desk would paint and take keys.
2. The largest part was getting the firmware's own window server, font and
   bitmap server and Eikon to run from the ROM in place of the emulator's
   versions. That is what makes every pixel the 9300's own.
3. Networking: Opera on Series 80 opens its connection through Symbian's
   comms database and HTTP framework. Those had to be answered well enough
   for the browser to reach the museum's archived-web network without
   showing a connection dialog.
