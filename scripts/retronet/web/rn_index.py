"""rn_index — build and query a tiny inverted index over the retronet corpus.

The corpus is a tree of static, already-downgraded HTML at
``/data/retronet/corpus/<host>/<path>`` (a directory serves its ``index.html``).
This module walks it, pulls the title + visible text out of every page with the
stdlib HTML parser, and builds an in-memory inverted index that ranks documents
for a query. No third-party anything: it runs inside the offline gateway CT,
which has Python 3 and nothing else.

Everything an era browser eventually sees (title, snippet, the ``http://<host>/``
URL a page lives at) is derived here; the rendering lives in ``rn_render``.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from html.parser import HTMLParser

# Corpus pages are Latin-1 by construction (era-press downgrades to it), so we
# decode as Latin-1 — it never raises — and tokenise over ASCII letters/digits
# plus the lowercase Latin-1 accented range. Accents are not folded; a period
# engine did not either.
_TOKEN_RE = re.compile(r"[0-9a-zß-ÿ]+")
_WS_RE = re.compile(r"\s+")
_INDEX_NAMES = ("index.html", "index.htm")
_HTML_EXTS = (".html", ".htm")
_SKIP_TAGS = {"script", "style"}
# Block-level tags whose boundaries must not glue two words together.
_MAX_BYTES = 1_500_000  # era pages are tiny; refuse to slurp a stray huge file.

# Ranking weights. A title hit is worth several body hits; matching more of the
# distinct query words matters more than matching one of them many times; an
# exact phrase is the strongest single signal.
_TITLE_BOOST = 5
_DISTINCT_BONUS = 3
_PHRASE_BOOST = 10


def tokenize(text: str) -> list[str]:
    """Lowercase, then split into indexable tokens."""
    return _TOKEN_RE.findall(text.lower())


def _collapse(text: str) -> str:
    return _WS_RE.sub(" ", text).strip()


class _Extractor(HTMLParser):
    """Pull the <title>, a meta description and the visible text out of a page.

    ``convert_charrefs`` is on (the default), so entities arrive already decoded
    in ``handle_data`` and we never see ``&amp;`` in the token stream.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.title_parts: list[str] = []
        self.body_parts: list[str] = []
        self.meta_desc = ""
        self._depth_skip = 0
        self._in_title = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in _SKIP_TAGS:
            self._depth_skip += 1
        elif tag == "title":
            self._in_title = True
        elif tag == "meta":
            a = {k.lower(): (v or "") for k, v in attrs}
            if a.get("name", "").lower() == "description" and a.get("content"):
                self.meta_desc = a["content"]
        # Any tag boundary is a word boundary: keep "one</td><td>two" from
        # becoming "onetwo".
        self.body_parts.append(" ")

    def handle_endtag(self, tag: str) -> None:
        if tag in _SKIP_TAGS and self._depth_skip:
            self._depth_skip -= 1
        elif tag == "title":
            self._in_title = False
        self.body_parts.append(" ")

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self.title_parts.append(data)
        elif self._depth_skip == 0:
            self.body_parts.append(data)

    def result(self) -> tuple[str, str, str]:
        return (
            _collapse("".join(self.title_parts)),
            _collapse("".join(self.body_parts)),
            _collapse(self.meta_desc),
        )


def extract(html: str) -> tuple[str, str]:
    """Return ``(title, visible_text)`` for one HTML string.

    Falls back to a meta description for the body when the page has no real
    text, and to the title when even that is empty, so every page contributes
    *something* searchable.
    """
    parser = _Extractor()
    try:
        parser.feed(html)
        parser.close()
    except Exception:
        # A malformed era page must never take the whole indexer down.
        pass
    title, body, desc = parser.result()
    if not body:
        body = desc or title
    return title, body


def url_for(host: str, relpath: str) -> str:
    """The corpus URL a page is reachable at through the proxy.

    ``about.html`` -> ``http://host/about.html``; a directory's ``index.html``
    -> ``http://host/`` (or ``http://host/sub/``), matching how the proxy maps a
    trailing-slash request back onto ``index.html``.
    """
    parts = [p for p in relpath.split(os.sep) if p]
    is_index = bool(parts) and parts[-1].lower() in _INDEX_NAMES
    if is_index:
        parts = parts[:-1]
    path = "/".join(parts)
    if is_index:
        return f"http://{host}/{path}/" if path else f"http://{host}/"
    return f"http://{host}/{path}"


@dataclass
class Doc:
    doc_id: int
    host: str
    url: str
    title: str
    text: str
    haystack: str  # lower(title + " " + text), for phrase (substring) matching


@dataclass
class Index:
    corpus_root: str
    docs: list[Doc] = field(default_factory=list)
    # token -> {doc_id: body term-frequency}
    postings: dict[str, dict[int, int]] = field(default_factory=dict)
    # token -> set(doc_id) where the token appears in the title
    title_index: dict[str, set[int]] = field(default_factory=dict)

    @property
    def n_docs(self) -> int:
        return len(self.docs)

    def _add(self, host: str, url: str, title: str, text: str) -> None:
        doc_id = len(self.docs)
        self.docs.append(Doc(doc_id, host, url, title, text, (title + " " + text).lower()))
        for tok in tokenize(text):
            self.postings.setdefault(tok, {})
            self.postings[tok][doc_id] = self.postings[tok].get(doc_id, 0) + 1
        for tok in set(tokenize(title)):
            self.title_index.setdefault(tok, set()).add(doc_id)


def build_index(corpus_root: str) -> Index:
    """Walk the corpus and return a fresh :class:`Index`.

    Tolerates an absent or empty corpus: the result simply has no documents,
    and every query against it is an honest "nothing matched".
    """
    idx = Index(corpus_root=corpus_root)
    if not corpus_root or not os.path.isdir(corpus_root):
        return idx
    for host in sorted(os.listdir(corpus_root)):
        host_dir = os.path.join(corpus_root, host)
        if not os.path.isdir(host_dir):
            continue
        for dirpath, _dirs, files in os.walk(host_dir):
            for name in sorted(files):
                if not name.lower().endswith(_HTML_EXTS):
                    continue
                full = os.path.join(dirpath, name)
                try:
                    if os.path.getsize(full) > _MAX_BYTES:
                        continue
                    with open(full, "rb") as fh:
                        html = fh.read().decode("latin-1")
                except OSError:
                    continue
                title, text = extract(html)
                relpath = os.path.relpath(full, host_dir)
                url = url_for(host, relpath)
                idx._add(host, url, title or url, text)
    return idx


# --- querying ---------------------------------------------------------------

_PHRASE_RE = re.compile(r'"([^"]+)"')


@dataclass
class Query:
    required: list[str] = field(default_factory=list)  # +term
    optional: list[str] = field(default_factory=list)  # bare term
    excluded: list[str] = field(default_factory=list)  # -term
    phrases: list[str] = field(default_factory=list)  # "quoted phrase"

    @property
    def positive(self) -> list[str]:
        return self.required + self.optional

    @property
    def is_empty(self) -> bool:
        return not (self.required or self.optional or self.phrases)


def parse_query(raw: str) -> Query:
    """Parse an AltaVista-ish query: ``"phrases"`` first, then +/- and bare words."""
    q = Query()
    rest = raw
    for m in _PHRASE_RE.finditer(raw):
        phrase = _collapse(m.group(1)).lower()
        if phrase:
            q.phrases.append(phrase)
    rest = _PHRASE_RE.sub(" ", rest)
    for word in rest.split():
        if word.startswith("+") and len(word) > 1:
            q.required.extend(tokenize(word[1:]))
        elif word.startswith("-") and len(word) > 1:
            q.excluded.extend(tokenize(word[1:]))
        else:
            q.optional.extend(tokenize(word))
    return q


@dataclass
class Hit:
    doc: Doc
    score: int
    snippet: str


def _score(idx: Index, doc_id: int, q: Query) -> int:
    score = 0
    matched_distinct = 0
    for tok in set(q.positive):
        tf = idx.postings.get(tok, {}).get(doc_id, 0)
        in_title = doc_id in idx.title_index.get(tok, ())
        if tf or in_title:
            matched_distinct += 1
            score += tf + (_TITLE_BOOST if in_title else 0)
    score += _DISTINCT_BONUS * matched_distinct
    haystack = idx.docs[doc_id].haystack
    for phrase in q.phrases:
        if phrase in haystack:
            score += _PHRASE_BOOST
    return score


def _passes_filters(idx: Index, doc_id: int, q: Query) -> bool:
    haystack = idx.docs[doc_id].haystack
    for tok in q.required:
        if not (idx.postings.get(tok, {}).get(doc_id) or doc_id in idx.title_index.get(tok, ())):
            return False
    for tok in q.excluded:
        if idx.postings.get(tok, {}).get(doc_id) or doc_id in idx.title_index.get(tok, ()):
            return False
    return all(phrase in haystack for phrase in q.phrases)


def _candidates(idx: Index, q: Query) -> set[int]:
    if q.positive:
        cand: set[int] = set()
        for tok in q.positive:
            cand |= set(idx.postings.get(tok, {}))
            cand |= idx.title_index.get(tok, set())
        return cand
    # Phrase-only query: everything is a candidate, the phrase filter decides.
    return set(range(idx.n_docs))


def search(idx: Index, raw_query: str, snippet_len: int = 160) -> list[Hit]:
    """Rank the corpus for ``raw_query``; best first."""
    q = parse_query(raw_query)
    if q.is_empty:
        return []
    hits: list[Hit] = []
    for doc_id in _candidates(idx, q):
        if not _passes_filters(idx, doc_id, q):
            continue
        sc = _score(idx, doc_id, q)
        if sc <= 0:
            continue
        doc = idx.docs[doc_id]
        hits.append(Hit(doc, sc, make_snippet(doc, q, snippet_len)))
    # Stable, deterministic order: score, then URL.
    hits.sort(key=lambda h: (-h.score, h.doc.url))
    return hits


def make_snippet(doc: Doc, q: Query, length: int = 160) -> str:
    """A window of body text around the first query hit (terms left un-marked).

    Rendering decides how to emphasise; this returns plain text so the same
    snippet is reusable and always Latin-1-safe.
    """
    text = doc.text
    if not text:
        return ""
    low = text.lower()
    needles = list(q.phrases) + q.positive
    pos = -1
    for needle in needles:
        if not needle:
            continue
        found = low.find(needle)
        if found != -1 and (pos == -1 or found < pos):
            pos = found
    if pos == -1:
        snippet = text[:length]
        return snippet + ("..." if len(text) > length else "")
    start = max(0, pos - length // 3)
    end = min(len(text), start + length)
    snippet = text[start:end]
    if start > 0:
        snippet = "..." + snippet
    if end < len(text):
        snippet = snippet + "..."
    return snippet
