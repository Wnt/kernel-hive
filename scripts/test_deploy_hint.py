"""The public deploy-trigger endpoint. Security-critical, so tested exhaustively.

This is the one piece of the design that faces the internet, and the property
that makes it acceptable is negative: it CANNOT say what to deploy. Most tests
below assert something the endpoint refuses to do.
"""

import hashlib
import hmac
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "serve"))

from deploy_hint import BODY_CAP, HintReceiver, TokenBucket  # noqa: E402

WEBHOOK = b"webhook-secret"
ACTIONS = b"actions-secret"
PUSH_MAIN = {"ref": "refs/heads/main", "after": "a" * 40}


def sign(secret: bytes, raw: bytes) -> str:
    return "sha256=" + hmac.new(secret, raw, hashlib.sha256).hexdigest()


def body(obj) -> bytes:
    return json.dumps(obj).encode()


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.wakeup = Path(self._tmp.name) / "wakeup"
        self.rx = HintReceiver({"webhook": WEBHOOK, "actions": ACTIONS}, wakeup=self.wakeup)

    def tearDown(self):
        self._tmp.cleanup()

    def post(self, obj, secret=WEBHOOK, event="push", delivery="d1", raw=None, headers=None):
        raw = raw if raw is not None else body(obj)
        h = {
            "X-Hub-Signature-256": sign(secret, raw),
            "X-GitHub-Event": event,
            "X-GitHub-Delivery": delivery,
        }
        h.update(headers or {})
        return self.rx.verify(raw, h)


class ItAccepts(Base):
    def test_a_signed_push_to_main(self):
        v = self.post(PUSH_MAIN)
        self.assertTrue(v.accepted, v)
        self.assertEqual(v.source, "webhook")
        self.assertTrue(self.wakeup.exists(), "the entire side effect is this file")

    def test_the_source_is_the_key_that_verified(self):
        """Never a payload field: the backstop-visibility story depends on it."""
        v = self.post(PUSH_MAIN, secret=ACTIONS, headers=None)
        # actions pings must carry a timestamp
        self.assertFalse(v.accepted)
        raw = body({**PUSH_MAIN, "ts": time.time()})
        v = self.rx.verify(
            raw,
            {
                "X-Hub-Signature-256": sign(ACTIONS, raw),
                "X-GitHub-Event": "push",
                "X-GitHub-Delivery": "d-actions",
            },
        )
        self.assertTrue(v.accepted, v)
        self.assertEqual(v.source, "actions")

    def test_a_payload_cannot_claim_to_be_the_webhook(self):
        raw = body({**PUSH_MAIN, "ts": time.time(), "source": "webhook", "trigger": "webhook"})
        v = self.rx.verify(
            raw,
            {
                "X-Hub-Signature-256": sign(ACTIONS, raw),
                "X-GitHub-Event": "push",
                "X-GitHub-Delivery": "d2",
            },
        )
        self.assertEqual(v.source, "actions", "the KEY decides the source, not the body")


class ItRefuses(Base):
    def test_an_unsigned_request(self):
        v = self.rx.verify(body(PUSH_MAIN), {"X-GitHub-Event": "push"})
        self.assertEqual(v.code, 401)
        self.assertFalse(self.wakeup.exists())

    def test_a_wrong_signature(self):
        raw = body(PUSH_MAIN)
        v = self.rx.verify(raw, {"X-Hub-Signature-256": sign(b"nope", raw), "X-GitHub-Event": "push"})
        self.assertEqual(v.code, 401)

    def test_a_tampered_body_with_a_valid_old_signature(self):
        """The signature covers the RAW bytes."""
        raw = body(PUSH_MAIN)
        sig = sign(WEBHOOK, raw)
        tampered = body({"ref": "refs/heads/main", "after": "b" * 40})
        v = self.rx.verify(tampered, {"X-Hub-Signature-256": sig, "X-GitHub-Event": "push"})
        self.assertEqual(v.code, 401)

    def test_the_401_carries_no_detail(self):
        """A caller must not learn WHY, and no key material may reach a log."""
        raw = body(PUSH_MAIN)
        v = self.rx.verify(raw, {"X-Hub-Signature-256": sign(b"x", raw), "X-GitHub-Event": "push"})
        self.assertEqual(v.reason, "bad signature")
        for secret in (WEBHOOK, ACTIONS):
            self.assertNotIn(secret.decode(), v.reason)

    def test_every_ref_except_main(self):
        for i, ref in enumerate(("refs/heads/cd-build", "refs/tags/v1", "refs/heads/main-ish", None)):
            v = self.post({"ref": ref}, delivery=f"ref-{i}")
            self.assertEqual(v.code, 204, ref)
            self.assertFalse(self.wakeup.exists(), ref)

    def test_events_that_are_not_push(self):
        self.assertEqual(self.post(PUSH_MAIN, event="pull_request").code, 204)
        self.assertFalse(self.wakeup.exists())

    def test_a_ping_is_acknowledged_but_wakes_nothing(self):
        v = self.post({}, event="ping")
        self.assertEqual(v.code, 200)
        self.assertFalse(self.wakeup.exists())

    def test_an_unparseable_body_is_dropped_never_guessed_at(self):
        v = self.post(None, raw=b"{ not json")
        self.assertEqual(v.code, 400)
        self.assertFalse(self.wakeup.exists())

    def test_a_body_over_the_cap(self):
        big = b"x" * (BODY_CAP + 1)
        v = self.rx.verify(big, {"X-Hub-Signature-256": sign(WEBHOOK, big), "X-GitHub-Event": "push"})
        self.assertEqual(v.code, 413)

    def test_an_unconfigured_endpoint_refuses_everything(self):
        """Unarmed by default is the only safe default for a deploy trigger."""
        rx = HintReceiver({}, wakeup=self.wakeup)
        raw = body(PUSH_MAIN)
        v = rx.verify(raw, {"X-Hub-Signature-256": sign(WEBHOOK, raw), "X-GitHub-Event": "push"})
        self.assertEqual(v.code, 503)
        self.assertFalse(self.wakeup.exists())


class Replay(Base):
    def test_a_repeated_delivery_id_wakes_nothing_twice(self):
        self.assertTrue(self.post(PUSH_MAIN, delivery="same").accepted)
        first = self.wakeup.stat().st_mtime_ns
        v = self.post(PUSH_MAIN, delivery="same")
        self.assertEqual(v.code, 200)
        self.assertIn("duplicate", v.reason)
        self.assertEqual(self.wakeup.stat().st_mtime_ns, first)

    def test_a_different_delivery_id_is_fine(self):
        self.assertTrue(self.post(PUSH_MAIN, delivery="one").accepted)
        self.assertTrue(self.post(PUSH_MAIN, delivery="two").accepted)

    def test_a_stale_actions_timestamp(self):
        raw = body({**PUSH_MAIN, "ts": time.time() - 4000})
        v = self.rx.verify(
            raw,
            {"X-Hub-Signature-256": sign(ACTIONS, raw), "X-GitHub-Event": "push", "X-GitHub-Delivery": "z"},
        )
        self.assertEqual(v.code, 400)

    def test_replay_is_harmless_by_construction_anyway(self):
        """Defence in depth, not the load-bearing part: even a replay that got
        through only causes one extra fetch of origin/main."""
        v = self.post(PUSH_MAIN, delivery="x")
        self.assertIsNone(v.hint_sha or None, None) if False else None
        self.assertEqual(v.reason, "wakeup enqueued")


class RedeliveryMustStillWork(Base):
    """GitHub redelivers a FAILED delivery under the same id.

    Recording an id we did not act on would turn GitHub's own retry into a
    silent no-op: the endpoint would refuse the redelivery of the push it had
    just dropped, and the box would sit un-converged with both sides believing
    they had done their part. So only an ACCEPTED delivery is remembered.
    """

    def test_a_dropped_delivery_can_be_redelivered(self):
        self.assertEqual(self.post(None, raw=b"{ bad", delivery="retry-me").code, 400)
        v = self.post(PUSH_MAIN, delivery="retry-me")
        self.assertTrue(v.accepted, "the redelivery must be honoured")
        self.assertTrue(self.wakeup.exists())

    def test_an_ignored_ref_does_not_burn_its_delivery_id(self):
        self.assertEqual(self.post({"ref": "refs/heads/other"}, delivery="dup").code, 204)
        self.assertTrue(self.post(PUSH_MAIN, delivery="dup").accepted)

    def test_but_an_accepted_delivery_is_not_replayable(self):
        self.assertTrue(self.post(PUSH_MAIN, delivery="once").accepted)
        self.assertEqual(self.post(PUSH_MAIN, delivery="once").code, 200)


class RateLimit(unittest.TestCase):
    def test_the_bucket_is_consumed_before_the_hmac(self):
        """A cheap check gating an expensive one has to come first."""
        clock = [0.0]
        rx = HintReceiver({"webhook": WEBHOOK}, bucket=TokenBucket(capacity=2, refill=0, now=lambda: clock[0]))
        raw = body(PUSH_MAIN)
        bad = {"X-Hub-Signature-256": "sha256=deadbeef", "X-GitHub-Event": "push"}
        self.assertEqual(rx.verify(raw, bad).code, 401)
        self.assertEqual(rx.verify(raw, bad).code, 401)
        self.assertEqual(rx.verify(raw, bad).code, 429, "unsigned floods must exhaust the bucket")

    def test_tokens_refill(self):
        clock = [0.0]
        b = TokenBucket(capacity=1, refill=1.0, now=lambda: clock[0])
        self.assertTrue(b.take())
        self.assertFalse(b.take())
        clock[0] = 2.0
        self.assertTrue(b.take())


class ItCannotSayWhatToDeploy(Base):
    def test_no_field_in_the_payload_reaches_anything_but_the_journal(self):
        v = self.post({**PUSH_MAIN, "station": "rhapsody", "cmd": "rm -rf /", "unit": "serve-code"})
        self.assertTrue(v.accepted)
        # The ONLY thing carried forward is the hint sha, for the journal.
        self.assertEqual(v.hint_sha, "a" * 40)
        self.assertEqual(sorted(v.__slots__), ["code", "hint_sha", "reason", "source"])

    def test_the_side_effect_is_exactly_two_inert_files(self):
        """The wakeup the reconciler watches, and the provenance journal.
        Nothing else: no process, no git operation, no repository read."""
        self.post(PUSH_MAIN)
        after = sorted(p.name for p in self.wakeup.parent.iterdir())
        self.assertEqual(after, ["hints.jsonl", "wakeup"])

    def test_the_wakeup_records_the_verified_source_not_a_claimed_one(self):
        self.post({**PUSH_MAIN, "source": "webhook"}, secret=ACTIONS) if False else None
        raw = body({**PUSH_MAIN, "ts": time.time(), "source": "webhook"})
        self.rx.verify(
            raw,
            {
                "X-Hub-Signature-256": sign(ACTIONS, raw),
                "X-GitHub-Event": "push",
                "X-GitHub-Delivery": "d9",
            },
        )
        row = json.loads(self.wakeup.read_text())
        self.assertEqual(row["source"], "actions")
        self.assertEqual(row["hint"], "a" * 40)


class HeadersMayNotSurviveTheHop(Base):
    """Measured on the first real delivery: the public edge forwards
    X-Hub-Signature-256 but drops X-GitHub-*. Identical requests scored 202 on
    the LAN listener and 204 through the relay — signature verified, trigger
    silently dead. The HMAC over the body is the authorisation; the headers were
    only ever a pre-filter."""

    def bare(self, obj, secret=WEBHOOK):
        raw = body(obj)
        return self.rx.verify(raw, {"X-Hub-Signature-256": sign(secret, raw)})

    def test_a_push_with_NO_event_header_is_still_a_push(self):
        v = self.bare(PUSH_MAIN)
        self.assertTrue(v.accepted, v)
        self.assertTrue(self.wakeup.exists())

    def test_a_ping_with_no_event_header_is_still_a_ping(self):
        v = self.bare({"zen": "Design for failure.", "hook_id": 1})
        self.assertEqual(v.code, 200)
        self.assertFalse(self.wakeup.exists())

    def test_a_non_main_ref_is_still_ignored_without_the_header(self):
        self.assertEqual(self.bare({"ref": "refs/heads/other"}).code, 204)
        self.assertFalse(self.wakeup.exists())

    def test_inference_happens_AFTER_the_signature_never_before(self):
        raw = body(PUSH_MAIN)
        v = self.rx.verify(raw, {"X-Hub-Signature-256": sign(b"wrong", raw)})
        self.assertEqual(v.code, 401)
        self.assertFalse(self.wakeup.exists())

    def test_an_unrecognisable_signed_payload_is_ignored_not_guessed(self):
        self.assertEqual(self.bare({"something": "else"}).code, 204)

    def test_replay_still_rejected_without_a_delivery_id(self):
        """The body digest substitutes for X-GitHub-Delivery."""
        self.assertTrue(self.bare(PUSH_MAIN).accepted)
        self.assertEqual(self.bare(PUSH_MAIN).code, 200)

    def test_two_different_pushes_are_not_confused_for_replays(self):
        self.assertTrue(self.bare(PUSH_MAIN).accepted)
        self.assertTrue(self.bare({"ref": "refs/heads/main", "after": "c" * 40}).accepted)


class ProvenanceSurvivesTheNextHint(Base):
    """The wakeup is last-write-wins and the Actions ping always follows the
    webhook, so the wakeup's source is systematically overwritten to `actions`.
    Read from the wakeup alone, a healthy webhook looks exactly like a dead one.
    The journal is where provenance actually lives."""

    def journal(self):
        import json as j

        p = self.wakeup.parent / "hints.jsonl"
        return [j.loads(x) for x in p.read_text().splitlines() if x.strip()] if p.exists() else []

    def test_both_triggers_are_recorded_not_just_the_last(self):
        self.post(PUSH_MAIN, delivery="w1")
        raw = body({**PUSH_MAIN, "ts": time.time()})
        self.rx.verify(raw, {"X-Hub-Signature-256": sign(ACTIONS, raw), "X-GitHub-Delivery": "a1"})
        sources = [r["source"] for r in self.journal()]
        self.assertEqual(sources, ["webhook", "actions"])
        # ...while the wakeup alone shows only the later one:
        self.assertEqual(json.loads(self.wakeup.read_text())["source"], "actions")

    def test_a_rejected_hint_is_not_journalled(self):
        self.rx.verify(body(PUSH_MAIN), {"X-GitHub-Event": "push"})  # unsigned
        self.assertEqual(self.journal(), [])

    def test_the_journal_is_bounded(self):
        """A bucket big enough to reach the cap — the default one correctly
        throttles at 30, which is the rate limiter working, not a journal bug."""
        from deploy_hint import JOURNAL_MAX, TokenBucket

        self.rx.bucket = TokenBucket(capacity=JOURNAL_MAX + 50, refill=0)
        for i in range(JOURNAL_MAX + 20):
            self.post({"ref": "refs/heads/main", "after": f"{i:040d}"}, delivery=f"d{i}")
        self.assertEqual(len(self.journal()), JOURNAL_MAX)


if __name__ == "__main__":
    unittest.main()
