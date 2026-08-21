"""OpenAI-compatible client for the caged `retronet-llm` llama-server, plus the
policy that keeps a slow model from ever becoming a hung exhibit.

Three rules, and all three exist because the box is GPU-less and shared with a
61-station production fleet:

1. **Hard deadline.** A reply that arrives after the visitor has walked away is
   worse than no reply. `timeout` is a wall clock, not a hope.
2. **No queueing.** llama-server has a fixed number of slots; a second visitor
   arriving mid-generation would otherwise wait behind the first AND behind the
   4-core CPU quota. Concurrency past the limit is refused instantly so the
   caller can fall through to ELIZA, which answers in microseconds.
3. **Every failure is a None.** Connection refused, 500, malformed JSON,
   deadline, busy — all one return value, one fallback path, no exceptions
   escaping into the bot's read loop.

The endpoint is `POST {base}/v1/chat/completions` (llama-server speaks the
OpenAI schema natively), so swapping in any other OpenAI-compatible worker later
is a URL change.
"""

from __future__ import annotations

import json
import logging
import re
import threading
import urllib.error
import urllib.request

LOG = logging.getLogger("retronet.llm")

_THINK = re.compile(r"<think>.*?</think>\s*", re.S | re.I)
_LEADING_LABEL = re.compile(r"^\s*(?:[A-Za-z0-9_]{1,16}\s*[:>]\s*)")

# 1999 IM clients (ICQ 2000b, climm, Mac AIM) render only their local codepage;
# the model's "smart" Unicode punctuation shows up as a stray vertical bar. Map
# the common offenders to ASCII so every era client can display the reply.
_SMART_PUNCT = str.maketrans(
    {
        "…": "...",
        "–": "-",
        "—": "-",
        "−": "-",
        "‘": "'",
        "’": "'",
        "‚": "'",
        "′": "'",
        "“": '"',
        "”": '"',
        "„": '"',
        "″": '"',
        " ": " ",
        "«": '"',
        "»": '"',
        "•": "*",
    }
)
_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def sanitize_ascii(text: str) -> str:
    """Force text to era-renderable ASCII: smart Unicode punctuation -> ASCII, drop
    control chars, collapse whitespace. A 1999 IM client (ICQ 2000b/2001b, climm)
    renders only its local codepage, so any stray Unicode (an em-dash, a smart quote)
    shows as a stray vertical bar. Applied to EVERY outbound bot message — canned
    greeting, LLM reply, ELIZA fallback — not just LLM output, so no path can leak one."""
    text = (text or "").translate(_SMART_PUNCT)  # smart quotes/dashes/ellipsis/bullet -> ASCII
    text = _CONTROL.sub("", text)  # drop stray control chars
    text = re.sub(r"\s+", " ", text)  # collapse every whitespace kind, incl. line breaks
    return text.encode("ascii", "ignore").decode("ascii").strip()  # era-renderable only


def tidy(text: str, max_chars: int) -> str:
    """Make model output look like something typed into an ICQ box in 1999."""
    text = _THINK.sub("", text or "")
    text = text.strip().strip('"').strip()
    text = _LEADING_LABEL.sub("", text)  # "SmarterChild: hi" -> "hi"
    text = sanitize_ascii(text)  # smart punct/control/whitespace -> era-renderable ASCII
    if len(text) <= max_chars:
        return text
    # Cut at the last sentence end that fits, else the last word.
    window = text[: max_chars + 1]
    cut = max(window.rfind(". "), window.rfind("! "), window.rfind("? "))
    if cut >= max_chars // 2:
        return window[: cut + 1].strip()
    cut = window.rfind(" ")
    return (window[:cut] if cut > 0 else window[:max_chars]).strip().rstrip(",;:") + "..."


class LlmClient:
    def __init__(
        self,
        base_url: str,
        model: str = "retronet",
        timeout: float = 20.0,
        max_concurrent: int = 1,
        max_tokens: int = 96,
        temperature: float = 0.8,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.timeout = timeout
        self.max_tokens = max_tokens
        self.temperature = temperature
        self._slots = threading.Semaphore(max_concurrent)
        self.stats = {"ok": 0, "busy": 0, "timeout": 0, "error": 0}

    def health(self) -> bool:
        try:
            with urllib.request.urlopen(f"{self.base_url}/health", timeout=5) as r:  # noqa: S310
                return r.status == 200
        except (urllib.error.URLError, OSError, ValueError):
            return False

    def chat(self, messages: list[dict[str, str]], max_chars: int = 200) -> str | None:
        """One completion, or None. Never raises, never blocks past `timeout`."""
        if not self._slots.acquire(blocking=False):
            self.stats["busy"] += 1
            LOG.info("LLM busy — falling back")
            return None
        try:
            body = json.dumps(
                {
                    "model": self.model,
                    "messages": messages,
                    "max_tokens": self.max_tokens,
                    "temperature": self.temperature,
                    "top_p": 0.9,
                    "stream": False,
                }
            ).encode("utf-8")
            req = urllib.request.Request(  # noqa: S310 (fixed loopback URL from config)
                f"{self.base_url}/v1/chat/completions",
                data=body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:  # noqa: S310
                payload = json.loads(resp.read().decode("utf-8"))
            text = payload["choices"][0]["message"]["content"]
            out = tidy(text, max_chars)
            if not out:
                self.stats["error"] += 1
                return None
            self.stats["ok"] += 1
            return out
        except TimeoutError:
            self.stats["timeout"] += 1
            LOG.warning("LLM timed out after %.1fs — falling back", self.timeout)
            return None
        except (urllib.error.URLError, OSError) as e:
            self.stats["timeout" if "timed out" in str(e).lower() else "error"] += 1
            LOG.warning("LLM unreachable (%s) — falling back", e)
            return None
        except (KeyError, IndexError, ValueError) as e:
            self.stats["error"] += 1
            LOG.warning("LLM returned junk (%s) — falling back", e)
            return None
        finally:
            self._slots.release()

    def warmup(self, system_prompt: str) -> bool:
        """Force the weights into page cache and prime the system-prompt KV block.

        Worth doing at start-up: the FIRST reply of the day otherwise pays both
        the mmap fault-in of a multi-GB GGUF and the full prompt prefill, which
        on 4 CPU cores is the difference between an 8 s reply and a 40 s one.
        """
        got = self.chat([{"role": "system", "content": system_prompt}, {"role": "user", "content": "hi"}])
        LOG.info("LLM warmup: %s", "ok" if got else "FAILED (bot will run on ELIZA until it recovers)")
        return got is not None
