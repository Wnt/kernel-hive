#!/usr/bin/env python3
"""cpg-mask: a declared exclusion must narrow the stability check, never soften it.

WHAT THESE PIN. checkpoint-guard will not bake a checkpoint whose idle
framebuffer moves, which is right and is what stops a half-drawn golden -- but it
made period-correct scenes unbakeable (www.apple.com's 1998 homepage carries a
37-frame animated GIF ticker, which kept `rhapsody` on www.wired.com until this
existed; it now declares that ticker and its golden is apple.com).
CPG_MASK excludes a DECLARED region. The danger in that idea is obvious: an
exemption nobody can see, or one that quietly buys slack for the rest of the
frame, turns the check into theatre. So:

  * a rectangle without a readable REASON is refused;
  * a mask that covers most of the screen is refused;
  * a declaration that does not fit the station's framebuffer is refused rather
    than clamped -- it was written for a different resolution and would mask the
    wrong place;
  * no scored tile ever overlaps a masked rectangle, which is what makes this a
    CROP and not a blank-and-compare (blanking would score the region a perfect
    match and inflate a whole-frame SSIM);
  * and anything that is not an actual comparison exits >1, because
    checkpoint-guard-proof.sh reads exit 1 as "the frames differ" and "differ" is
    what licenses it to believe the framebuffer moved.

The SSIM numbers themselves are proven on the framebuffer, on a sandbox rig --
ffmpeg is a labhost tool and these tests must run anywhere.
"""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location("cpg_mask", Path(__file__).resolve().parent / "lib" / "cpg-mask.py")
assert _SPEC and _SPEC.loader
cpg_mask = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(cpg_mask)

TICKER = "90,32,180x96 apple.com home/images/ticker.gif, a 37-frame animated GIF"


def ppm(tmp: str, name: str, w: int, h: int) -> str:
    """A PPM with a real header; ppm_size only ever reads the header."""
    p = Path(tmp) / name
    p.write_bytes(b"P6\n# checkpoint-guard test frame\n%d %d\n255\n" % (w, h))
    return str(p)


class DeclarationsAreRefusedNotGuessed(unittest.TestCase):
    def test_a_rectangle_without_a_reason_is_refused(self) -> None:
        with self.assertRaises(cpg_mask.MaskError) as e:
            cpg_mask.parse("90,32,180x96")
        self.assertIn("reason", str(e.exception))

    def test_a_token_reason_is_refused(self) -> None:
        with self.assertRaises(cpg_mask.MaskError):
            cpg_mask.parse("90,32,180x96 x")

    def test_gibberish_is_refused(self) -> None:
        for bad in ("", "  ;  ", "90,32 no size here", "90,32,0x96 zero width"):
            with self.assertRaises(cpg_mask.MaskError, msg=bad):
                cpg_mask.parse(bad)

    def test_several_rectangles_each_keep_their_reason(self) -> None:
        rects = cpg_mask.parse(f"{TICKER}; 8,8,96x16 the desktop clock ticks every second")
        self.assertEqual(len(rects), 2)
        self.assertIn("ticker.gif", rects[0].reason)
        self.assertIn("clock", rects[1].reason)

    def test_a_declaration_for_another_resolution_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            a, b = ppm(tmp, "a.ppm", 640, 480), ppm(tmp, "b.ppm", 640, 480)
            with self.assertRaises(cpg_mask.MaskError) as e:
                cpg_mask.score(a, b, "600,400,120x160 written for a bigger screen")
            self.assertIn("does not fit", str(e.exception))

    def test_frames_of_different_sizes_are_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            a, b = ppm(tmp, "a.ppm", 640, 480), ppm(tmp, "b.ppm", 720, 400)
            with self.assertRaises(cpg_mask.MaskError):
                cpg_mask.score(a, b, TICKER)


class MostOfTheScreenIsRefused(unittest.TestCase):
    def test_half_the_frame_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            a, b = ppm(tmp, "a.ppm", 640, 480), ppm(tmp, "b.ppm", 640, 480)
            with self.assertRaises(cpg_mask.MaskError) as e:
                cpg_mask.score(a, b, "0,0,640x240 the top half of the exhibit")
            self.assertIn("50.0%", str(e.exception))

    def test_the_rig_sized_ticker_is_allowed(self) -> None:
        rects = cpg_mask.parse(TICKER)
        _, excluded = cpg_mask.tiles(rects, 720, 400)
        self.assertLess(excluded / (720 * 400), cpg_mask.DEFAULT_MAX_FRACTION)


class ScoredTilesNeverTouchTheMask(unittest.TestCase):
    """The crop-not-blank guarantee, stated as geometry."""

    CASES = [
        (TICKER, 720, 400),
        ("0,0,64x64 top-left corner widget", 720, 400),
        ("656,336,64x64 bottom-right corner widget", 720, 400),
        (f"{TICKER}; 500,300,80x40 a second animating panel", 720, 400),
        ("100,100,33x27 deliberately unaligned to the 8px grid", 640, 480),
    ]

    def test_no_tile_overlaps_a_declared_rectangle(self) -> None:
        for decl, fw, fh in self.CASES:
            rects = cpg_mask.parse(decl)
            kept, _ = cpg_mask.tiles(rects, fw, fh)
            for tx, ty, tw, th in kept:
                for r in rects:
                    overlaps = tx < r.x + r.w and r.x < tx + tw and ty < r.y + r.h and r.y < ty + th
                    self.assertFalse(overlaps, f"{decl}: tile {(tx, ty, tw, th)} hits {r.text()}")

    def test_tiles_and_exclusion_account_for_the_whole_frame(self) -> None:
        """Nothing is scored twice and nothing is silently dropped."""
        for decl, fw, fh in self.CASES:
            rects = cpg_mask.parse(decl)
            kept, excluded = cpg_mask.tiles(rects, fw, fh)
            self.assertEqual(sum(w * h for _, _, w, h in kept) + excluded, fw * fh, decl)

    def test_tiles_do_not_overlap_each_other(self) -> None:
        for decl, fw, fh in self.CASES:
            kept, _ = cpg_mask.tiles(cpg_mask.parse(decl), fw, fh)
            for i, (ax, ay, aw, ah) in enumerate(kept):
                for bx, by, bw, bh in kept[i + 1 :]:
                    self.assertFalse(ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah, decl)

    def test_an_unmasked_frame_is_one_whole_tile(self) -> None:
        """With no mask there must be no behaviour change at all."""
        kept, excluded = cpg_mask.tiles([], 720, 400)
        self.assertEqual(kept, [(0, 0, 720, 400)])
        self.assertEqual(excluded, 0)


class ExitCodesCannotManufactureProof(unittest.TestCase):
    """Exit 1 means "the frames differ". Nothing else may ever return it."""

    def test_a_refused_declaration_exits_3(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            a, b = ppm(tmp, "a.ppm", 640, 480), ppm(tmp, "b.ppm", 640, 480)
            rc = cpg_mask.main(["check", a, b, "--mask", "0,0,640x400 far too much", "--min", "0.999"])
            self.assertEqual(rc, 3)

    def test_a_broken_comparison_exits_2_not_1(self) -> None:
        """A missing or failing ffmpeg must not read as "the framebuffer moved"."""
        original = cpg_mask._ffmpeg_ssim
        cpg_mask._ffmpeg_ssim = lambda *_: (_ for _ in ()).throw(RuntimeError("ffmpeg exploded"))
        try:
            with tempfile.TemporaryDirectory() as tmp:
                a, b = ppm(tmp, "a.ppm", 720, 400), ppm(tmp, "b.ppm", 720, 400)
                rc = cpg_mask.main(["check", a, b, "--mask", TICKER, "--min", "0.999"])
                self.assertEqual(rc, 2, "a broken comparison must never look like a difference")
        finally:
            cpg_mask._ffmpeg_ssim = original

    def test_a_below_threshold_comparison_exits_1(self) -> None:
        original = cpg_mask._ffmpeg_ssim
        cpg_mask._ffmpeg_ssim = lambda *_: 0.5
        try:
            with tempfile.TemporaryDirectory() as tmp:
                a, b = ppm(tmp, "a.ppm", 720, 400), ppm(tmp, "b.ppm", 720, 400)
                self.assertEqual(cpg_mask.main(["check", a, b, "--mask", TICKER, "--min", "0.999"]), 1)
                cpg_mask._ffmpeg_ssim = lambda *_: 1.0
                self.assertEqual(cpg_mask.main(["check", a, b, "--mask", TICKER, "--min", "0.999"]), 0)
        finally:
            cpg_mask._ffmpeg_ssim = original


class MaskingNarrowsTheAreaWithoutLoweringTheBar(unittest.TestCase):
    """The score is the mean over the pixels that ARE compared -- not the frame.

    Blanking the masked region in both frames would score it a perfect 1.0 and
    drag a whole-frame mean upwards, so a station could pass with the rest of the
    picture scoring below CPG_SSIM_MIN. These pin that the reported number is the
    area-weighted mean over the kept tiles only.
    """

    def test_the_masked_region_contributes_nothing(self) -> None:
        original = cpg_mask._ffmpeg_ssim
        cpg_mask._ffmpeg_ssim = lambda _a, _b, _t: 0.99
        try:
            with tempfile.TemporaryDirectory() as tmp:
                a, b = ppm(tmp, "a.ppm", 720, 400), ppm(tmp, "b.ppm", 720, 400)
                res = cpg_mask.score(a, b, TICKER)
                # Every kept tile scored 0.99, so the mean is 0.99 -- NOT the
                # 0.9906 a blank-and-compare would report by counting the
                # perfectly-matching masked 6% as part of the frame.
                self.assertAlmostEqual(res["ssim"], 0.99, places=9)
                self.assertGreater(res["excluded_fraction"], 0.0)
        finally:
            cpg_mask._ffmpeg_ssim = original


if __name__ == "__main__":
    unittest.main()
