#!/usr/bin/env python3
# Generates Windows .lnk desktop shortcuts for the WinXP gallery guest.
# Usage: make_shortcuts.py <output_desktop_dir>
import os
import sys

import pylnk3

DEST = sys.argv[1]
os.makedirs(DEST, exist_ok=True)

# name, target (Windows path), args, workdir, icon(optional), icon_index
SHORTCUTS = [
    (
        "DOOM (Shareware)",
        r"C:\Games\Doom\zdoom.exe",
        "-iwad doom1.wad",
        r"C:\Games\Doom",
        r"C:\Games\Doom\zdoom.exe",
        0,
    ),
    (
        "Quake (Shareware)",
        r"C:\Games\Quake\fteqw.exe",
        "-window +vid_renderer sw",
        r"C:\Games\Quake",
        r"C:\Games\Quake\fteqw.exe",
        0,
    ),
    (
        "3D Pinball - Space Cadet",
        r"C:\Program Files\Windows NT\Pinball\PINBALL.EXE",
        "",
        r"C:\Program Files\Windows NT\Pinball",
        r"C:\Program Files\Windows NT\Pinball\PINBALL.EXE",
        0,
    ),
    (
        "Minesweeper",
        r"C:\WINDOWS\system32\winmine.exe",
        "",
        r"C:\WINDOWS\system32",
        r"C:\WINDOWS\system32\winmine.exe",
        0,
    ),
    ("Solitaire", r"C:\WINDOWS\system32\sol.exe", "", r"C:\WINDOWS\system32", r"C:\WINDOWS\system32\sol.exe", 0),
    (
        "Internet Explorer",
        r"C:\Program Files\Internet Explorer\iexplore.exe",
        "",
        r"C:\Program Files\Internet Explorer",
        r"C:\Program Files\Internet Explorer\iexplore.exe",
        0,
    ),
    (
        "Winamp",
        r"C:\Program Files\Winamp\winamp.exe",
        "",
        r"C:\Program Files\Winamp",
        r"C:\Program Files\Winamp\winamp.exe",
        0,
    ),
]


def make_lnk(name, target, args, workdir, icon, icon_idx, out):
    lnk = pylnk3.for_file(
        target,
        lnk_name=None,
        arguments=(args or None),
        work_dir=workdir,
        icon_file=icon,
        icon_index=icon_idx,
        description=name,
    )
    # FIX: pylnk3.for_file's local branch emits ONLY a shell LinkTargetIDList
    # PIDL and leaves link_info=None (its HasLinkInfo line is commented out).
    # That PIDL is built by PathSegmentEntry.create_for_path(), which os.stat()s
    # the Windows target on the Linux build host — every C:\ segment fails, so
    # interior dirs get mistyped TYPE_FILE and XP can't resolve the IDList. With
    # no LinkInfo fallback the shortcut shows an EMPTY "Target:". Drop the bogus
    # IDList and attach a real local LinkInfo whose LocalBasePath is the absolute
    # Windows target so XP resolves the Target and launches it.
    lnk.shell_item_id_list = None
    lnk.link_flags.HasLinkTargetIDList = False
    li = pylnk3.LinkInfo()
    li.local = 1
    li.remote = 0
    li.drive_type = "Fixed (Hard disk)"  # key in pylnk3._DRIVE_TYPE_IDS
    li.drive_serial = 0
    li.volume_label = ""
    li.local_base_path = target
    li.make_path()
    lnk.link_info = li  # setter also sets HasLinkInfo=True
    lnk.save(out)


for name, target, args, workdir, icon, icon_idx in SHORTCUTS:
    out = os.path.join(DEST, name + ".lnk")
    make_lnk(name, target, args, workdir, icon, icon_idx, out)
    print("wrote", out)
