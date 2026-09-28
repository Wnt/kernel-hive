# nokia9300-content — facts for release notes

**What arrived:** the Nokia 9300 station now carries software and media a
2005 owner could have installed. On Desk, with their own icons: RMR Software's
card games RMRSol and RMRGolf and its Othello game RMRReverse, Steve
Litchfield's falling-blocks game Atomic (all four written in OPL, the
programming language Symbian inherited from Psion, running on the OPL
runtime), ProTour Golf in the MMC Apps folder, DataViz's Documents To Go
(Word To Go, Sheet To Go), MobiMate's WorldMate, the e-book reader iSilo and
PuTTY. In Images: NASA's Blue Marble (Apollo 17, 1972) and Hubble's Pillars of
Creation (1995). In Music player: Kevin MacLeod's "8bit Dungeon Boss"
(CC BY 3.0), a LibriVox podcast episode and three Mutopia Project MIDI pieces
(Für Elise, Bach's Minuet in G, Chopin's Minute Waltz).

**When:** live on 2026-09-28 at /os/nokia9300 (golden v4, emulator fork
s80-integration @ 0c22e86bb).

**What a visitor can do:** open any of the new programs from its Desk icon
with the arrow keys and Enter, play the games from the keyboard, read the
iSilo manual, type in Word To Go, look at the NASA pictures, and watch the
Music player count through a track. Reset returns the Desk as shipped, with
every shareware trial back on day 1.

**What is not there, and why:**
1. No sound: the exhibit has no audio output, so the Music player plays
   silently.
2. No video: the 9300 decoded video on the signal processor beside its main
   processor, and the emulator does not recreate that chip, so RealPlayer
   has nothing to play and no films were installed.

**What was hard:**
1. The emulator's command-line installer only knew memory-card installs and
   crashed on the first icon outside ROM; the fork now installs straight to
   the C: drive.
2. The installed programs showed a generic puzzle piece until the fork read
   their own icons, and the media apps listed no files until their file
   type lookup, folder scan and file dates were fixed.
3. Desk could not start an OPL program: it named the program file, and the
   emulator tried to load that file as machine code. The fork now hands OPL
   programs to the OPL runtime, as the real phone does.
4. Two programs needed their data fixed rather than the emulator: ProTour
   Golf's sound files were re-encoded to a format the emulator's decoder
   reads, and RMRReverse ships with a settings file, because a fresh install
   saves an invalid board type and then crashes.

**Credits (mandatory for the CC BY item):** "8bit Dungeon Boss" by Kevin
MacLeod (incompetech.com), licensed under Creative Commons: By Attribution 3.0
(https://creativecommons.org/licenses/by/3.0/). Public domain: NASA (The Blue
Marble; Pillars of Creation, Jeff Hester and Paul Scowen), LibriVox, the
Mutopia Project.
