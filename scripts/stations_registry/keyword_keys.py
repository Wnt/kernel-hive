"""Key tables for the type-in editor's KEYWORD TRANSCODER (zxspectrum, zx81).

On a keyword-entry machine one key IS a keyword (P in K mode gives PRINT), so an
ASCII listing typed letter by letter arrives as garbage. The editor therefore
turns a listing into key CHORDS (spa/src/ui/typein/keywordEntry.ts). This module
builds the table it tokenises against -- keyword or symbol -> the chords that
enter it -- MECHANICALLY from the station's own generated keymap
(streamhost/stations/<id>/<id>.keymap). Each keymap field name is MAME's key
legend, e.g. `p    P    "      TAB      (c)    PRINT` for the Spectrum's P key,
and the scancode in the same row is what the daemon maps to that key, so the
chords come out in exactly the codes the SPA has to send.

Hand-entered facts are limited to the two places where MAME's names are not
enough, each cross-checked against the ROM's own key tables on 2026-10-04:

  * MAME 0.289 names the Spectrum's 8 and 9 keys with CAT and POINT swapped.
    The 48K ROM's extended-mode digit table (0x0284) reads 8=POINT, 9=CAT, and
    E mode + SYMBOL SHIFT + 8 typed POINT on a rig.
  * MAME's zx81 names carry no FUNCTION-mode legends at all, and no K-mode
    keyword for Z X C V. Both come from the key legends in the ZX81 manual
    (Sinclair ZX81 BASIC Programming, Vickers 1981), and match the
    second-revision ROM's FUNCTION table (0x00CC) and its K-mode rule
    (keyword token = letter code + 0xC0) key for key.
"""

from __future__ import annotations

import json
import re
from collections import OrderedDict
from typing import Any

from .constants import REPO

KEYWORD_DIALECTS = ("sinclair-basic", "zx81-basic")

# MAME abbreviates some token names in its field names; the table carries the
# ROM's own token text (what LIST prints), and keeps the abbreviation as an
# accepted ASCII spelling.
SPECTRUM_ROM_SPELLING = {
    "GOTO": "GO TO",
    "GOSUB": "GO SUB",
    "CONT": "CONTINUE",
    "RAND": "RANDOMIZE",
    "OPEN#": "OPEN #",
    "CLOSE#": "CLOSE #",
}
# (key, column) -> (what MAME 0.289 calls it, what the ROM types). Asserted, so
# a MAME that fixes its names fails generation instead of silently double-fixing.
SPECTRUM_MAME_FIXES = {("8", "eSymbol"): ("CAT", "POINT"), ("9", "eSymbol"): ("POINT", "CAT")}

ZX81_FUNCTION = {
    "Q": "SIN", "W": "COS", "E": "TAN", "R": "INT", "T": "RND", "Y": "STR$", "U": "CHR$", "I": "CODE",
    "O": "PEEK", "P": "TAB", "A": "ASN", "S": "ACS", "D": "ATN", "F": "SGN", "G": "ABS", "H": "SQR",
    "J": "VAL", "K": "LEN", "L": "USR", "Z": "LN", "X": "EXP", "C": "AT", "N": "NOT", "M": "PI",
    "B": "INKEY$",
}  # fmt: skip
ZX81_MISSING_KEYWORDS = {"Z": "COPY", "X": "CLEAR", "C": "CONT", "V": "CLS"}
# Shift legends that are editing keys, not something a listing can contain.
ZX81_EDIT_KEYS = {"EDIT", "Left", "Down", "Up", "Right", "GRAPHICS", "DELETE", "FUNCTION"}

PRINTABLE = re.compile(r"[\x20-\x7e]+")
# MAME spells the Spectrum's copyright glyph (E mode + SYMBOL SHIFT + P) "(c)":
# a character no ASCII listing can mean.
NOT_ASCII = {"(c)"}


class KeymapError(ValueError):
    pass


def keymap_file(row: dict[str, Any]):
    """The station's keymap (an x11 aux file named *.keymap), or None."""
    for rel in ((row.get("runtime") or {}).get("x11") or {}).get("auxFiles", []):
        if rel.endswith(".keymap"):
            return REPO / rel
    return None


def read_keymap(path) -> OrderedDict[str, int]:
    """field name -> its FIRST (lowest) scancode, in file order."""
    fields: OrderedDict[str, int] = OrderedDict()
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t", 2)
        if len(cols) != 3:
            raise KeymapError(f"{path}: malformed row {line!r}")
        code = int(cols[0], 16)
        if cols[2] not in fields or code < fields[cols[2]]:
            fields[cols[2]] = code
    return fields


def _field(fields: dict[str, int], name: str, path) -> int:
    if name not in fields:
        raise KeymapError(f"{path}: no {name!r} key")
    return fields[name]


def _ascii(legend: str) -> bool:
    return bool(PRINTABLE.fullmatch(legend)) and legend not in NOT_ASCII


def spell(legend: str) -> str:
    return SPECTRUM_ROM_SPELLING.get(legend, legend)


class _Table:
    def __init__(self, path):
        self.path = path
        self.statements: OrderedDict[str, list[list[int]]] = OrderedDict()
        self.tokens: OrderedDict[str, list[list[int]]] = OrderedDict()
        self.chars: OrderedDict[str, list[list[int]]] = OrderedDict()

    def add(self, where: OrderedDict, text: str, chords: list[list[int]]) -> None:
        if text in self.statements or text in self.tokens:
            raise KeymapError(f"{self.path}: {text!r} is on two keys")
        where[text] = chords


def _spectrum_digit_columns(rows: list[tuple[str, int]], path) -> list[tuple[str, int, list[str]]]:
    """Digit-row names are column-aligned with a blank E legend on 8 and 9, so
    they are split by column offset rather than by whitespace."""
    spans = [(name, code, [(m.start(), m.group()) for m in re.finditer(r"\S+(?: \S+)*", name)]) for name, code in rows]
    full = {tuple(start for start, _ in parts) for _, _, parts in spans if len(parts) == 5}
    if len(full) != 1:
        raise KeymapError(f"{path}: digit-row legends are not column-aligned")
    starts = list(next(iter(full)))
    out = []
    for name, code, parts in spans:
        cols = [""] * 5
        for start, text in parts:
            if start not in starts:
                raise KeymapError(f"{path}: cannot place {text!r} in {name!r}")
            cols[starts.index(start)] = text
        out.append((name, code, cols))
    return out


def spectrum_table(path) -> dict[str, Any]:
    fields = read_keymap(path)
    caps, sym = _field(fields, "CAPS SHIFT", path), _field(fields, "SYMBOL SHIFT", path)
    extend = [caps, sym]  # CAPS SHIFT + SYMBOL SHIFT together: E mode
    table = _Table(path)
    letters = [(n, c) for n, c in fields.items() if re.match(r"[a-z]\s", n)]
    digits = [(n, c) for n, c in fields.items() if re.match(r"[0-9]\s", n)]
    if len(letters) != 26 or len(digits) != 10:
        raise KeymapError(f"{path}: expected 26 letter and 10 digit keys, found {len(letters)} and {len(digits)}")
    for name, code in letters:
        parts = name.split()
        if len(parts) != 6:
            raise KeymapError(f"{path}: letter key {name!r} needs 6 legends (key CAPS SYMBOL E E+SYMBOL K)")
        key, upper, symbol, e, e_symbol, k = parts
        table.chars[key] = [[code]]
        table.chars[upper] = [[caps, code]]
        table.add(table.statements, spell(k), [[code]])
        for legend, chords in ((symbol, [[sym, code]]), (e, [extend, [code]]), (e_symbol, [extend, [sym, code]])):
            if _ascii(legend):
                table.add(table.tokens, spell(legend), chords)
    for _name, code, cols in _spectrum_digit_columns(digits, path):
        key, _caps_legend, symbol, _colour, e_symbol = cols
        fix = SPECTRUM_MAME_FIXES.get((key, "eSymbol"))
        if fix:
            if e_symbol != fix[0]:
                raise KeymapError(f"{path}: expected MAME's {fix[0]!r} on {key}; drop the fix in keyword_keys.py")
            e_symbol = fix[1]
        table.chars[key] = [[code]]
        table.add(table.tokens, symbol, [[sym, code]])
        table.add(table.tokens, spell(e_symbol), [extend, [sym, code]])
    table.chars[" "] = [[_field(fields, "SPACE", path)]]
    aliases = {k: v for k, v in SPECTRUM_ROM_SPELLING.items() if k.replace(" ", "") != v.replace(" ", "")}
    return _out("sinclair-basic", table, _field(fields, "ENTER", path), aliases)


def zx81_table(path) -> dict[str, Any]:
    fields = read_keymap(path)
    shift, enter = _field(fields, "SHIFT", path), _field(fields, "ENTER  FUNCTION", path)
    table = _Table(path)
    keys = [(n.split(), c) for n, c in fields.items() if re.match(r"[A-Z0-9.]\s", n)]
    if sum(1 for parts, _ in keys if parts[0].isalpha()) != 26:
        raise KeymapError(f"{path}: expected 26 letter keys")
    for parts, code in keys:
        key, legends = parts[0], parts[1:]
        if key.isalpha():
            if len(legends) == 1:
                legends.append(ZX81_MISSING_KEYWORDS.get(key, ""))
            elif key in ZX81_MISSING_KEYWORDS:
                raise KeymapError(f"{path}: {key} now names its keyword; drop it from ZX81_MISSING_KEYWORDS")
            shifted, k = legends
            if not k:
                raise KeymapError(f"{path}: no K-mode keyword for {key}")
            table.chars[key] = table.chars[key.lower()] = [[code]]
            table.add(table.statements, k, [[code]])
            if key in ZX81_FUNCTION:
                table.add(table.tokens, ZX81_FUNCTION[key], [[shift, enter], [code]])
        else:
            table.chars[key] = [[code]]
            shifted = legends[0]
        if shifted not in ZX81_EDIT_KEYS and _ascii(shifted):
            table.add(table.tokens, shifted, [[shift, code]])
    table.chars[" "] = [[_field(fields, "SPACE  £", path)]]
    return _out("zx81-basic", table, enter, {"GO TO": "GOTO", "GO SUB": "GOSUB"})


def _out(dialect: str, table: _Table, enter: int, aliases: dict[str, str]) -> dict[str, Any]:
    return OrderedDict(
        (
            ("dialect", dialect),
            ("statements", table.statements),
            ("tokens", table.tokens),
            ("chars", table.chars),
            ("aliases", OrderedDict(sorted(aliases.items()))),
            ("enter", [enter]),
        )
    )


BUILDERS = {"sinclair-basic": spectrum_table, "zx81-basic": zx81_table}


def keyword_tables(rows: list[dict[str, Any]], errors: list[str] | None = None) -> OrderedDict[str, Any]:
    """station id -> its table, for every station whose typeIn dialect is keyword entry."""
    out: OrderedDict[str, Any] = OrderedDict()
    for row in sorted(rows, key=lambda r: r["id"]):
        dialect = (row.get("typeIn") or {}).get("dialect")
        if dialect not in BUILDERS:
            continue
        path = keymap_file(row)
        try:
            if path is None or not path.is_file():
                raise KeymapError("no station keymap (runtime.x11.auxFiles *.keymap) to build the key table from")
            out[row["id"]] = BUILDERS[dialect](path)
        except KeymapError as exc:
            if errors is None:
                raise
            errors.append(f"{row.get('_path', row['id'])}: typeIn.dialect {dialect}: {exc}")
    return out


def _obj(entries: dict[str, Any], indent: str) -> str:
    body = ",\n".join(f"{indent}  {json.dumps(k)}: {json.dumps(v, separators=(',', ':'))}" for k, v in entries.items())
    return "{\n" + body + "\n" + indent + "}"


def render_keyword_keys(rows: list[dict[str, Any]]) -> bytes:
    tables = keyword_tables(rows)
    blocks = []
    for os_id, table in tables.items():
        parts = [f'    "dialect": {json.dumps(table["dialect"])}']
        for key in ("statements", "tokens", "chars", "aliases"):
            parts.append(f"    {json.dumps(key)}: {_obj(table[key], '    ')}")
        parts.append(f'    "enter": {json.dumps(table["enter"])}')
        blocks.append(f"  {json.dumps(os_id)}: {{\n" + ",\n".join(parts) + "\n  }")
    return (
        "// DO NOT EDIT — generated by scripts/stations-registry.py generate from the keymaps\n"
        "// of the keyword-entry stations (typeIn.dialect sinclair-basic / zx81-basic), whose\n"
        "// field names are MAME's key legends; run `make station-registry-generate`.\n"
        "// How a legend becomes chords: scripts/stations_registry/keyword_keys.py.\n"
        "import type { KeywordTable } from '../types';\n\n"
        "const KEYWORD_TABLES = {\n" + ",\n".join(blocks) + "\n} as const satisfies Record<string, KeywordTable>;\n\n"
        "/** The keyword transcoder's key table for a station, or undefined. */\n"
        "export function keywordTableFor(osId: string): KeywordTable | undefined {\n"
        "  return (KEYWORD_TABLES as Record<string, KeywordTable>)[osId];\n"
        "}\n\n"
        "/** Every station's table (the highlighter's keyword lists). */\n"
        "export function keywordTables(): readonly KeywordTable[] {\n"
        "  return Object.values(KEYWORD_TABLES);\n"
        "}\n"
    ).encode()
