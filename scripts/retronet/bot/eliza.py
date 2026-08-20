"""ELIZA — the canned fallback that means the bot NEVER hangs.

The retronet's promise is that a visitor who opens a station gets talked to.
An LLM on a GPU-less, 61-station production box is a best-effort resource: it
can be cold, saturated by another reply, or restarting. When it is, the visitor
must still get an answer inside a second — so every LLM failure falls through to
here, and the exhibit degrades from "smart bot" to "1966 bot", which is the most
period-appropriate degradation imaginable.

Weizenbaum's DOCTOR script, trimmed to the patterns a museum visitor actually
types at a chat window. Zero dependencies, zero network, microseconds.
"""

from __future__ import annotations

import random
import re

# Second-person <-> first-person flip applied to whatever the user said before it
# is echoed back. Order matters: longest first, and the pass is single-shot over
# word boundaries so "you" in "your" is not rewritten twice.
_REFLECT = {
    "am": "are",
    "are": "am",
    "were": "was",
    "was": "were",
    "i": "you",
    "i'd": "you would",
    "i've": "you have",
    "i'll": "you will",
    "i'm": "you are",
    "me": "you",
    "my": "your",
    "mine": "yours",
    "myself": "yourself",
    "you": "me",
    "your": "my",
    "yours": "mine",
    "you're": "I am",
    "you've": "I have",
    "yourself": "myself",
}

# (pattern, [responses]) — {0} is the reflected capture group.
_RULES: list[tuple[re.Pattern[str], list[str]]] = [
    (
        re.compile(r"\b(hello|hi|hey|greetings|yo)\b", re.I),
        [
            "Hello. How are you feeling today?",
            "Hi there. What is on your mind?",
            "Hello... what would you like to talk about?",
        ],
    ),
    (
        re.compile(r"\bi need (.+)", re.I),
        ["Why do you need {0}?", "Would it really help you to get {0}?", "Are you sure you need {0}?"],
    ),
    (
        re.compile(r"\bi(?:'m| am) (?:feeling )?(.+)", re.I),
        ["Why do you think you are {0}?", "How long have you been {0}?", "How does being {0} make you feel?"],
    ),
    (
        re.compile(r"\bi (?:can'?t|cannot) (.+)", re.I),
        ["How do you know you can't {0}?", "Perhaps you could {0} if you tried.", "What is stopping you from {0}?"],
    ),
    (
        re.compile(r"\bi (?:want|would like) (.+)", re.I),
        ["What would it mean to you if you got {0}?", "Why do you want {0}?", "What would you do if you got {0}?"],
    ),
    (
        re.compile(r"\bi (?:think|believe|feel) (.+)", re.I),
        ["Do you really think so?", "But you are not sure you {0}?", "Why do you feel that way?"],
    ),
    (
        re.compile(r"\b(?:are you|r u) (.+)", re.I),
        ["Why does it matter whether I am {0}?", "Would you prefer it if I were not {0}?", "What if I were {0}?"],
    ),
    (
        re.compile(r"\bdo you (.+)", re.I),
        ["Why do you ask whether I {0}?", "Would it matter to you if I did?", "What would it mean if I did {0}?"],
    ),
    (
        re.compile(r"\b(?:what|who|where|when|why|how) (.+)\?", re.I),
        [
            "Why do you ask?",
            "What do you think?",
            "What answer would please you most?",
            "Does that question interest you?",
        ],
    ),
    (
        re.compile(r"\bbecause\b", re.I),
        ["Is that the real reason?", "What other reasons come to mind?", "Does that reason explain anything else?"],
    ),
    (
        re.compile(r"\b(?:sorry|apolog)", re.I),
        [
            "There is no need to apologise.",
            "Apologies are not necessary here.",
            "What feelings do you have when you apologise?",
        ],
    ),
    (
        re.compile(r"\b(?:computer|machine|pc|windows|internet|modem|icq)\b", re.I),
        [
            "Do machines worry you?",
            "What do you think machines have to do with your problem?",
            "Are you talking about me in particular?",
            "Does it trouble you that I am a machine?",
        ],
    ),
    (
        re.compile(r"\b(?:yes|yeah|yep|sure)\b", re.I),
        ["You seem quite positive.", "Are you sure?", "I see. Go on.", "Why do you say so?"],
    ),
    (
        re.compile(r"\b(?:no|nope|nah)\b", re.I),
        ["Why not?", "Are you saying no just to be negative?", "You are being a bit negative."],
    ),
    (
        re.compile(r"\b(?:bye|goodbye|cya|later|gtg)\b", re.I),
        ["Goodbye. It was nice talking to you.", "Bye for now. Come back soon.", "Take care. Talk again?"],
    ),
]

_FALLBACK = [
    "Please go on.",
    "Can you elaborate on that?",
    "I see. And what does that tell you?",
    "Tell me more.",
    "That is interesting. Please continue.",
    "Does talking about this bother you?",
    "What does that suggest to you?",
    "Why do you say that?",
    "How does that make you feel?",
]


def reflect(fragment: str) -> str:
    """Swap first/second person so a fragment can be echoed back at the speaker."""
    words = re.split(r"(\W+)", fragment)
    return "".join(_REFLECT.get(w.lower(), w) if w.strip() else w for w in words).strip(" .!?,")


def reply(text: str, rng: random.Random | None = None) -> str:
    """A DOCTOR-style reply to `text`. Always returns something, always instantly."""
    r = rng or random
    cleaned = (text or "").strip()
    if not cleaned:
        return r.choice(_FALLBACK)
    for pattern, responses in _RULES:
        m = pattern.search(cleaned)
        if not m:
            continue
        chosen = r.choice(responses)
        if "{0}" in chosen:
            captured = m.group(1) if m.groups() else ""
            chosen = chosen.format(reflect(captured))
        return chosen
    return r.choice(_FALLBACK)
