"""rn_render — period HTML for the retronet search engine.

Everything here emits HTML an era browser (Netscape 4, IE5) renders without a
whimper: an HTML 3.2 doctype, ``<table>``/``<font>`` layout, **no JavaScript and
no CSS**, and a Latin-1 (ISO-8859-1) byte stream. The results page wears an
AltaVista coat; the directory wears a Yahoo! one. Pure functions — no IO — so
they are trivial to unit-test and the same output is reproducible byte for byte.
"""

from __future__ import annotations

import re
from collections.abc import Iterable

from rn_index import Hit, Query, parse_query

DOCTYPE = '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">'
CHARSET = "iso-8859-1"


def esc(text: str) -> str:
    """HTML-escape for text content and (double-quoted) attribute values.

    Deliberately leaves ``'`` alone: an apostrophe needs no escaping in text or
    inside a double-quoted attribute, and the oldest era browsers predate the
    ``&apos;`` / hex ``&#x27;`` forms a generic escaper would emit.
    """
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def to_bytes(markup: str) -> bytes:
    """Encode a finished page as Latin-1, turning any stray char into an entity.

    ``xmlcharrefreplace`` guarantees the result is valid ISO-8859-1 even when a
    title or blurb carried a stray UTF-8 character — an era browser sees a
    numeric entity, never a mojibake byte.
    """
    return markup.encode(CHARSET, "xmlcharrefreplace")


def page(title: str, body: str, *, bgcolor: str = "#ffffff") -> str:
    """Wrap body markup in a period document shell."""
    return (
        f"{DOCTYPE}\n"
        "<html><head>\n"
        f'<meta http-equiv="Content-Type" content="text/html; charset={CHARSET}">\n'
        f"<title>{esc(title)}</title>\n"
        "</head>\n"
        f'<body bgcolor="{bgcolor}" text="#000000" link="#0000cc" '
        'vlink="#551a8b" alink="#ff0000">\n'
        f"{body}\n"
        "</body></html>\n"
    )


def _needle_regex(needles: Iterable[str]) -> re.Pattern[str] | None:
    parts = [re.escape(n) for n in sorted({n for n in needles if n}, key=len, reverse=True)]
    if not parts:
        return None
    return re.compile("(" + "|".join(parts) + ")", re.IGNORECASE)


def mark_terms(snippet: str, q: Query) -> str:
    """Escape a snippet, then bold the query terms/phrases inside it."""
    escaped = esc(snippet)
    rx = _needle_regex(list(q.phrases) + q.positive)
    if rx is None:
        return escaped
    return rx.sub(r"<b>\1</b>", escaped)


# --- search UI --------------------------------------------------------------

_TAGLINE = "the retronet search &mdash; every page here lives on our own internet"


def _searchbox(q: str = "", size: int = 45) -> str:
    return (
        '<form action="/search" method="get">\n'
        f'<input type="text" name="q" size="{size}" value="{esc(q)}">\n'
        '<input type="submit" value="Search">\n'
        "</form>\n"
    )


def _masthead(brand: str, color: str, tagline: str) -> str:
    return (
        '<table border="0" cellpadding="2" cellspacing="0" width="100%">\n'
        "<tr><td>\n"
        f'<font size="7" face="Helvetica,Arial" color="{color}"><b>{brand}</b></font>\n'
        f'<br><font size="1" face="Helvetica,Arial" color="#666666">{tagline}</font>\n'
        "</td></tr></table>\n"
    )


def home_page() -> str:
    """The AltaVista-style front door."""
    body = (
        _masthead("AltaVista", "#0000cc", _TAGLINE)
        + "<hr>\n"
        + '<table border="0" cellpadding="6"><tr><td>\n'
        + _searchbox("")
        + "</td></tr></table>\n"
        + '<p><font size="2" face="Helvetica,Arial">'
        + "Tip: <b>+word</b> requires a word, <b>-word</b> excludes it, "
        + "<b>&quot;a phrase&quot;</b> matches it exactly.</font></p>\n"
        + '<p><font size="2" face="Helvetica,Arial">'
        + 'Or <a href="/dir">browse the directory by category</a>.</font></p>\n'
        + _footer()
    )
    return page("AltaVista: Main Page", body)


def _footer() -> str:
    return (
        "<hr>\n"
        '<font size="1" face="Helvetica,Arial" color="#666666">'
        "retronet &middot; an offline museum web &middot; no connection to the "
        "outside world</font>\n"
    )


def _result_item(hit: Hit, q: Query) -> str:
    snippet = mark_terms(hit.snippet, q) if hit.snippet else "<i>(no preview available)</i>"
    return (
        "<p>\n"
        f'<b><a href="{esc(hit.doc.url)}">{esc(hit.doc.title)}</a></b><br>\n'
        f'<font size="2" face="Helvetica,Arial">{snippet}</font><br>\n'
        f'<font size="2" color="#008000">{esc(hit.doc.url)}</font>\n'
        f'<font size="1" color="#666666">&nbsp;&nbsp;[score {hit.score}]</font>\n'
        "</p>\n"
    )


def _pagination(query: str, page_no: int, per_page: int, total: int) -> str:
    last = max(1, (total + per_page - 1) // per_page)
    if last <= 1:
        return ""
    out = ['<hr><font size="2" face="Helvetica,Arial">Result Pages: ']
    if page_no > 1:
        out.append(f'<a href="/search?q={esc_url(query)}&amp;pg={page_no - 1}">[&lt;&lt; Prev]</a> ')
    for p in range(1, last + 1):
        if p == page_no:
            out.append(f"<b>{p}</b> ")
        else:
            out.append(f'<a href="/search?q={esc_url(query)}&amp;pg={p}">{p}</a> ')
    if page_no < last:
        out.append(f'<a href="/search?q={esc_url(query)}&amp;pg={page_no + 1}">[Next &gt;&gt;]</a>')
    out.append("</font>\n")
    return "".join(out)


def esc_url(text: str) -> str:
    """Percent-encode a query for use inside an href (and escape for HTML)."""
    from urllib.parse import quote

    return esc(quote(text, safe=""))


def results_page(query: str, hits: list[Hit], page_no: int, per_page: int) -> str:
    q = parse_query(query)
    header = _masthead("AltaVista", "#0000cc", _TAGLINE) + "<hr>\n"
    header += '<table border="0" cellpadding="4"><tr><td>\n' + _searchbox(query) + "</td></tr></table>\n"

    if not query.strip():
        body = header + '<p><font face="Helvetica,Arial">Please enter a query above.</font></p>\n' + _footer()
        return page("AltaVista: Search", body)

    total = len(hits)
    if total == 0:
        body = (
            header
            + f'<p><font face="Helvetica,Arial">No documents match <b>{esc(query)}</b>.</font></p>\n'
            + '<p><font size="2" face="Helvetica,Arial">Try fewer or more general words, '
            + 'or <a href="/dir">browse the directory</a>.</font></p>\n'
            + _footer()
        )
        return page(f"AltaVista: {query}", body)

    start = (page_no - 1) * per_page
    shown = hits[start : start + per_page]
    lo = start + 1
    hi = start + len(shown)
    summary = (
        f'<p><font size="2" face="Helvetica,Arial">Documents <b>{lo}-{hi}</b> '
        f"of about <b>{total}</b> matching the query "
        f"<b>{esc(query)}</b>.</font></p>\n"
    )
    items = "".join(_result_item(h, q) for h in shown)
    body = header + summary + items + _pagination(query, page_no, per_page, total) + _footer()
    return page(f"AltaVista: {query}", body)


# --- directory (Yahoo!) -----------------------------------------------------

_UNCATEGORISED = "Web Sites"


def directory_page(sites: list[dict]) -> str:
    """The Yahoo!-style directory, built from sites.json entries."""
    brand = '<font size="7" face="Times,serif" color="#7700aa"><b><i>Yahoo!</i></b></font>'
    head = (
        f"{brand}\n"
        '<br><font size="1" face="Helvetica,Arial" color="#666666">retronet directory '
        "&mdash; the sites on our internet</font>\n<hr>\n"
        + '<table border="0" cellpadding="4"><tr><td>\n'
        + _searchbox("", size=40)
        + "</td></tr></table>\n"
    )

    if not sites:
        body = (
            head
            + '<p><font face="Times,serif">The directory is empty &mdash; no sites have '
            + "been catalogued yet.</font></p>\n"
            + _footer()
        )
        return page("Yahoo! - Retronet Directory", body)

    groups: dict[str, list[dict]] = {}
    for site in sites:
        cat = str(site.get("category") or _UNCATEGORISED).strip() or _UNCATEGORISED
        groups.setdefault(cat, []).append(site)

    sections = []
    for cat in sorted(groups):
        entries = sorted(groups[cat], key=lambda s: str(s.get("title") or s.get("host") or "").lower())
        rows = "".join(_dir_entry(s) for s in entries)
        sections.append(
            f'<h2><font face="Times,serif" color="#7700aa">{esc(cat)}</font></h2>\n'
            + '<table border="0" cellpadding="3">\n'
            + rows
            + "</table>\n"
        )

    count = len(sites)
    body = (
        head
        + f'<p><font size="2" face="Helvetica,Arial">{count} site(s) in the directory.</font></p>\n'
        + "".join(sections)
        + _footer()
    )
    return page("Yahoo! - Retronet Directory", body)


def _dir_entry(site: dict) -> str:
    host = str(site.get("host") or "").strip()
    title = str(site.get("title") or host or "(untitled)").strip()
    blurb = str(site.get("blurb") or "").strip()
    added = str(site.get("added") or "").strip()
    url = f"http://{host}/" if host else "#"
    line = '<tr valign="top"><td><font face="Times,serif">\n'
    line += f'<a href="{esc(url)}"><b>{esc(title)}</b></a>'
    if blurb:
        line += f" - {esc(blurb)}"
    line += f'\n<font size="1" color="#008000">({esc(host)})</font>' if host else ""
    if added:
        line += f' <font size="1" color="#cc0000">[added {esc(added)}]</font>'
    line += "\n</font></td></tr>\n"
    return line


# --- misc pages -------------------------------------------------------------


def text_page(title: str, message: str) -> str:
    body = (
        _masthead("AltaVista", "#0000cc", _TAGLINE)
        + "<hr>\n"
        + f'<p><font face="Helvetica,Arial">{esc(message)}</font></p>\n'
        + '<p><font size="2" face="Helvetica,Arial"><a href="/">search</a> &middot; '
        + '<a href="/dir">directory</a></font></p>\n'
        + _footer()
    )
    return page(title, body)
