#!/usr/bin/env python3
"""mgtfs.py -- read/compose MGT (SAM Coupe / SAMDOS) 800K floppy images.

An MGT image is 819200 bytes: 80 tracks x 2 sides x 10 sectors x 512 bytes,
stored in one of TWO sector orders, and which one is in use depends on the
container, not on the machine:

  MGT   ("interleaved", what .mgt/.dsk carry and what MAME's samcoupe floppy
        device expects)   offset = ((track*2 + side)*10 + sector-1) * 512
  SAD   ("side-major", Aley's disk backup, .sad, behind a 22-byte header)
                          offset = ((side*80 + track)*10 + sector-1) * 512

Nothing in the image declares this, so load() DETECTS it: it walks every
file's sector chain under both orders and keeps the one where the chains
terminate at exactly the declared sector counts. On our sixteen source disks
that test is unanimous every time (e.g. SAMDOSVersion2.0.dsk 15/15 for MGT
and 0/15 for SAD), and guessing wrong silently truncates every file to one
sector -- which is how this was found.

Tracks 0..3 of side 0 are the directory: 40 sectors x 2 entries of 256 bytes
= 80 slots. The remaining 1560 sectors hold file data. A directory entry:

    0        file type (bits 0..5; bit 7 hidden, bit 6 protected)
    1..10    file name, space padded
    11..12   sectors used (MSB, LSB)
    13       first track   (bit 7 set => side 1)
    14       first sector  (1..10)
    15..209  sector address map -- 195 bytes = 1560 bits, one per DATA sector
             in side-major order starting at track 4 side 0 sector 1
    220..    the file's own 9-byte SAM header (type, length, start address...)

File data is a chain: 510 bytes of payload then a 2-byte link (next track,
next sector); 0,0 ends the chain.

A .sad image is the same content behind a 22-byte "Aley's disk backup" header.
"""

SECTOR = 512
PAYLOAD = 510
TRACKS = 80
SIDES = 2
SPT = 10
DIR_TRACKS = 4
DIR_SLOTS = DIR_TRACKS * SPT * 2  # 80
DATA_START_TRACK = DIR_TRACKS  # track 4, side 0
TOTAL_SECTORS = TRACKS * SIDES * SPT  # 1600
DATA_SECTORS = TOTAL_SECTORS - DIR_TRACKS * SPT  # 1560
IMAGE_SIZE = TOTAL_SECTORS * SECTOR  # 819200
SAD_HEADER = b"Aley's disk backup"

TYPES = {
    16: "BASIC",
    17: "D.ARRAY",
    18: "S.ARRAY",
    19: "CODE",
    20: "SCREEN$",
    21: "MIDI OUT",
    22: "MIDI TRK",
    23: "DFILE",
    24: "SUBDIR",
    25: "DRIVER",
}


MGT_LAYOUT = "mgt"  # .mgt / .dsk -- track-major, sides interleaved
SAD_LAYOUT = "sad"  # .sad -- side-major


def offset(track, side, sector, layout=MGT_LAYOUT):
    """Byte offset of one 512-byte sector. track 0..79, side 0..1, sector 1..10."""
    if not (0 <= track < TRACKS and 0 <= side < SIDES and 1 <= sector <= SPT):
        raise ValueError(f"bad CHS {track!r}/{side!r}/{sector!r}")
    if layout == MGT_LAYOUT:
        return ((track * SIDES + side) * SPT + (sector - 1)) * SECTOR
    return ((side * TRACKS + track) * SPT + (sector - 1)) * SECTOR


def split_track(raw_track):
    """Directory 'first track' byte -> (track, side); bit 7 selects side 1."""
    return raw_track & 0x7F, 1 if raw_track & 0x80 else 0


def join_track(track, side):
    return track | (0x80 if side else 0)


def dir_slot_offset(slot, layout=MGT_LAYOUT):
    """Byte offset of directory slot 0..79.

    The directory is tracks 0..3 of SIDE 0 -- 40 sectors, two 256-byte slots
    each. Under the SAD layout those sectors happen to be the first 40 in the
    file, so slot k sits at k*256; under MGT they are interleaved with side 1
    and slot 20 jumps to offset 10240. Reading the directory linearly on an
    MGT image therefore shows the first 20 files and then side 1's file data
    misread as entries -- which looks exactly like stale junk after the end of
    the directory, and is how this went unnoticed until SAMDOS itself put a
    newly SAVEd file in slot 20 and the composed disk lost eight files."""
    if not 0 <= slot < DIR_SLOTS:
        raise ValueError(f"directory slot {slot!r} out of range")
    track, rest = divmod(slot, SPT * 2)
    sector, half = divmod(rest, 2)
    return offset(track, 0, sector + 1, layout) + half * 256


def data_chs(index):
    """CHS of the Nth DATA sector. Allocation runs side 0 track 4..79, then
    side 1 track 0..79 -- the order SAMDOS's 195-byte sector address map uses,
    independent of how the container stores those sectors on disk."""
    n = index + DIR_TRACKS * SPT
    side, rest = divmod(n, TRACKS * SPT)
    track, sec = divmod(rest, SPT)
    return track, side, sec + 1


def _chains_ok(img, layout):
    """How many files walk to exactly their declared length under `layout`."""
    ok = 0
    total = 0
    for e in read_dir(img):
        if not 3 <= e.sectors <= DATA_SECTORS:
            continue
        total += 1
        track, side, sector = e.start
        seen = set()
        walked = 0
        good = True
        for _ in range(e.sectors):
            if not (1 <= sector <= SPT) or track >= TRACKS or (track, side, sector) in seen:
                good = False
                break
            seen.add((track, side, sector))
            base = offset(track, side, sector, layout)
            walked += 1
            nxt_track, nxt_sector = img[base + PAYLOAD], img[base + PAYLOAD + 1]
            if nxt_track == 0 and nxt_sector == 0:
                break
            track, side = split_track(nxt_track)
            sector = nxt_sector
        if good and walked == e.sectors:
            ok += 1
    return ok, total


class Image:
    """A loaded image plus the sector order it turned out to use."""

    def __init__(self, data, layout, path=None):
        self.data = data
        self.layout = layout
        self.path = path

    def __getitem__(self, k):
        return self.data[k]

    def __len__(self):
        return len(self.data)


def load(path):
    """Read an .mgt/.dsk/.sad file, detecting its sector order (see module doc)."""
    with open(path, "rb") as fh:
        blob = fh.read()
    if blob.startswith(SAD_HEADER):
        blob = blob[22:]
    if len(blob) < IMAGE_SIZE:
        raise ValueError(f"{path}: {len(blob)} bytes, not an 800K MGT image")
    data = bytearray(blob[:IMAGE_SIZE])
    scores = {lay: _chains_ok(data, lay) for lay in (MGT_LAYOUT, SAD_LAYOUT)}
    best = max(scores, key=lambda lay: scores[lay][0])
    ok, total = scores[best]
    if total and ok * 2 < total:
        raise ValueError(f"{path}: neither sector order walks its files ({scores!r})")
    return Image(data, best, path)


class Entry:
    """One directory slot."""

    def __init__(self, slot, raw):
        self.slot = slot
        self.raw = bytearray(raw)

    @property
    def ftype(self):
        return self.raw[0] & 0x3F

    @property
    def name(self):
        return self.raw[1:11].decode("latin-1").rstrip()

    @property
    def sectors(self):
        return (self.raw[11] << 8) | self.raw[12]

    @property
    def start(self):
        track, side = split_track(self.raw[13])
        return track, side, self.raw[14]

    def type_name(self):
        return TYPES.get(self.ftype, f"type{self.ftype}")

    def __repr__(self):
        return f"<{self.name} {self.type_name()} {self.sectors} sectors>"


def read_dir(img, stop_at_gap=True):
    """Directory entries of an image.

    SAMDOS stops scanning at the first empty slot, so by default this does
    too. It also stops on an entry that cannot be real -- a length past the
    disk or a start sector outside 1..10. Several of the World of SAM disks
    have no zeroed slot after their last file, just stale bytes from whatever
    the disk held before, and reading those invents files with 54467-sector
    lengths and mojibake names."""
    layout = getattr(img, "layout", MGT_LAYOUT)
    out = []
    for slot in range(DIR_SLOTS):
        base = dir_slot_offset(slot, layout)
        raw = img[base : base + 256]
        if (raw[0] & 0x3F) == 0:
            if stop_at_gap:
                break
            continue
        entry = Entry(slot, raw)
        track, _side, sector = entry.start
        if not (1 <= sector <= SPT) or track >= TRACKS or entry.sectors > DATA_SECTORS:
            if stop_at_gap:
                break
            continue
        out.append(entry)
    return out


def find(img, name):
    for e in read_dir(img):
        if e.name.lower() == name.lower():
            return e
    have = ", ".join(x.name for x in read_dir(img))
    raise KeyError(f"no file {name!r} on this image (have: {have})")


def read_file(img, entry):
    """Follow the sector chain and return the file's payload bytes."""
    track, side, sector = entry.start
    data = bytearray()
    seen = set()
    layout = getattr(img, "layout", MGT_LAYOUT)
    for _ in range(entry.sectors):
        key = (track, side, sector)
        if key in seen or not (1 <= sector <= SPT) or track >= TRACKS:
            raise ValueError(f"{entry.name}: broken sector chain at {key!r} after {len(seen)}/{entry.sectors} sectors")
        seen.add(key)
        base = offset(track, side, sector, layout)
        data += img[base : base + PAYLOAD]
        nxt_track, nxt_sector = img[base + PAYLOAD], img[base + PAYLOAD + 1]
        if nxt_track == 0 and nxt_sector == 0:
            break
        track, side = split_track(nxt_track)
        sector = nxt_sector
    return bytes(data)


class Composer:
    """Build a fresh MGT image, appending files from track 4 onward.

    Allocation is strictly sequential, so the sector address map is exact and
    there is no free-list to get wrong -- the reason this writes a NEW disk
    rather than grafting files into an existing one.
    """

    def __init__(self, layout=MGT_LAYOUT):
        self.layout = layout
        self.img = bytearray(IMAGE_SIZE)
        self.next_index = 0  # next free position in the data area
        self.slot = 0  # next free directory slot
        self.names = []

    @property
    def free_sectors(self):
        return DATA_SECTORS - self.next_index

    def add(self, entry, payload, name=None):
        """Append a file, reusing the source entry's type and SAM header.

        `name` renames it on the way in (max 10 characters). That matters more
        than it looks: SAMDOS boots the first file whose name begins with
        "auto", case-insensitively, so a source disk's own launcher -- The
        Secretary's "Auto.Sec", say -- will hijack the boot away from our menu
        unless it is renamed here."""
        need = (len(payload) + PAYLOAD - 1) // PAYLOAD
        if need > self.free_sectors:
            raise ValueError(f"{entry.name} needs {need} sectors, {self.free_sectors} free")
        if self.slot >= DIR_SLOTS:
            raise ValueError(f"directory full ({DIR_SLOTS} slots)")

        first = self.next_index
        smap = bytearray(195)
        for i in range(need):
            index = first + i
            track, side, sector = data_chs(index)
            base = offset(track, side, sector, self.layout)
            chunk = payload[i * PAYLOAD : (i + 1) * PAYLOAD]
            self.img[base : base + len(chunk)] = chunk
            if i + 1 < need:
                nt, ns, nsec = data_chs(index + 1)
                self.img[base + PAYLOAD] = join_track(nt, ns)
                self.img[base + PAYLOAD + 1] = nsec
            smap[index // 8] |= 1 << (index % 8)

        raw = bytearray(entry.raw)
        if name is not None:
            if len(name) > 10:
                raise ValueError(f"name {name!r} is longer than 10 characters")
            raw[1:11] = name.ljust(10).encode("latin-1")
        raw[11] = (need >> 8) & 0xFF
        raw[12] = need & 0xFF
        t0, s0, sec0 = data_chs(first)
        raw[13] = join_track(t0, s0)
        raw[14] = sec0
        raw[15:210] = smap
        dir_base = dir_slot_offset(self.slot, self.layout)
        self.img[dir_base : dir_base + 256] = raw

        self.next_index += need
        self.slot += 1
        self.names.append((name or entry.name, entry.type_name(), need))

    def write(self, path):
        with open(path, "wb") as fh:
            fh.write(self.img)
        return path
