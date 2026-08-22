#!/usr/bin/env python3
"""rn_proxy_pages -- the retronet proxy's own notice pages, and the toolbar-search rescue.

Everything the proxy AUTHORS rather than serves: the period 404/400 notices, the
search box that turns a miss into the museum's own search, and the rule for
recognising a modern browser's built-in search so its query can be carried over
instead of dead-ending. Kept apart from proxy.py because it is presentation, not
proxying -- the same separation the search service already has in rn_render.py.

Deployed alongside proxy.py into /opt/retronet-proxy by install-proxy.sh.
"""

from __future__ import annotations

from urllib.parse import parse_qs

TEXT_CHARSET = "iso-8859-1"  # what a period browser assumes, and what these pages declare


def era_page(title: str, heading: str, paras: list[str], extra: str = "") -> bytes:
    """A tiny HTML 3.2 page, Latin-1, in the spirit of a 1990s server notice.

    `extra` is optional pre-built HTML (e.g. the miss page's search box), placed
    after the text and before the closing rule. Laid out in one centered,
    fixed-width column so the notice reads as a page, not a wall of full-width
    text — all HTML 3.2 a period browser (Netscape 4, IE5) renders."""
    body = "\n".join(f"<P>{p}</P>" for p in paras)
    html = (
        '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">\n'
        f"<HTML><HEAD><TITLE>{title}</TITLE></HEAD>\n"
        '<BODY BGCOLOR="#FFFFFF" TEXT="#000000" LINK="#0000EE" VLINK="#551A8B">\n'
        '<TABLE ALIGN="CENTER" WIDTH="560" BORDER="0" CELLPADDING="0" CELLSPACING="0">\n'
        "<TR><TD>\n"
        f"<H1>{heading}</H1>\n{body}\n{extra}<HR>\n"
        "<ADDRESS>retronet proxy &#151; an offline museum of the 1990s web. "
        "No live internet.</ADDRESS>\n</TD></TR></TABLE>\n</BODY></HTML>\n"
    )
    return html.encode(TEXT_CHARSET, "replace")


def search_nav(search_host: str) -> str:
    """The miss page's search box + directory/search links — turns a dead end into
    the museum's own search. Points at the reserved search host, which resolves
    back to this gateway (wildcard DNS) and is routed to the local search backend;
    no live internet is involved."""
    base = f"http://{search_host}"
    return (
        "<HR>\n"
        f'<FORM ACTION="{base}/search" METHOD="GET">\n'
        "<B>Search the museum</B><BR>\n"
        '<INPUT TYPE="TEXT" NAME="q" SIZE="34"> '
        '<INPUT TYPE="SUBMIT" VALUE="Search">\n'
        "</FORM>\n"
        "<P>Or browse by hand: "
        f'<A HREF="{base}/search">AltaVista-style search</A> &#149; '
        f'<A HREF="{base}/dir">Yahoo!-style directory</A></P>\n'
    )


# Modern search engines a browser's built-in search box points at — none of which
# belong to an era corpus. When such a toolbar search lands here (a query string
# carrying a `q`/`p`), we 302 it to the museum's own search with the terms kept,
# instead of a dead 404. Era engines that ARE archived (altavista, yahoo, lycos,
# excite) are deliberately absent here — they serve their real corpus pages.
REDIRECT_ENGINES = frozenset(
    {
        "google.com",
        "bing.com",
        "duckduckgo.com",
        "ask.com",
        "dogpile.com",
        "search.msn.com",
        "search.aol.com",
        "search.brave.com",
    }
)


def is_search_engine(host: str) -> bool:
    """True for a modern search-engine host whose toolbar query we redirect."""
    h = host[4:] if host.startswith("www.") else host
    return h == "google" or h.startswith("google.") or h in REDIRECT_ENGINES


def search_query_of(query: str) -> str | None:
    """The user's terms from a toolbar query string — `q`, or the older
    `p`/`query`/`search` — or None if there are none to carry over."""
    if not query:
        return None
    qs = parse_qs(query, keep_blank_values=False)
    for key in ("q", "query", "p", "search"):
        vals = qs.get(key)
        if vals and vals[0].strip():
            return vals[0]
    return None
