"""Tests for corpus_completeness -- the scorer that would have caught the hollow spacejam mirror."""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import corpus_completeness as cc  # noqa: E402


def write(root, host, path, body=""):
    full = os.path.join(root, host, path.lstrip("/"))
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", encoding="latin-1") as handle:
        handle.write(body)


class ScoreHostTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def test_whole_site_scores_100(self):
        write(
            self.root,
            "whole.example",
            "index.html",
            "<title>Whole</title><body background='bg.gif'><img src='nav.gif'><input type=image src='/go.gif'>",
        )
        for asset in ("bg.gif", "nav.gif", "go.gif"):
            write(self.root, "whole.example", asset, "GIF89a")
        row = cc.score_host(self.root, "whole.example")
        self.assertEqual(row["assets"], 3)
        self.assertEqual(row["broken"], 0)
        self.assertEqual(row["complete_pct"], 100.0)
        self.assertEqual(row["title"], "Whole")

    def test_missing_nav_bitmap_is_counted_broken(self):
        """The spacejam shape: the page is 200, the navigation bitmap is simply absent."""
        write(self.root, "hollow.example", "index.html", "<body><img src='img/nf-planets.gif'>")
        row = cc.score_host(self.root, "hollow.example")
        self.assertEqual(row["broken"], 1)
        self.assertEqual(row["complete_pct"], 0.0)
        self.assertIn("hollow.example/img/nf-planets.gif", row["missing"])

    def test_ad_server_miss_is_not_held_against_the_site(self):
        write(
            self.root,
            "adsy.example",
            "index.html",
            "<img src='logo.gif'><img src='http://ad.doubleclick.net/banner.gif'>",
        )
        write(self.root, "adsy.example", "logo.gif", "GIF89a")
        row = cc.score_host(self.root, "adsy.example")
        self.assertEqual(row["broken"], 0)
        self.assertEqual(row["ad_misses"], 1)
        self.assertEqual(row["complete_pct"], 100.0)

    def test_frameset_documents_are_scored_too(self):
        write(
            self.root,
            "framed.example",
            "index.html",
            "<frameset><frame src='top.html'><frame src='body.html'></frameset>",
        )
        write(self.root, "framed.example", "top.html", "<img src='banner.gif'>")
        write(self.root, "framed.example", "body.html", "<img src='gone.gif'>")
        write(self.root, "framed.example", "banner.gif", "GIF89a")
        row = cc.score_host(self.root, "framed.example")
        self.assertEqual(row["frames"], 2)
        self.assertEqual(row["assets"], 2)
        self.assertEqual(row["broken"], 1)

    def test_cross_host_asset_resolves_against_the_other_host(self):
        write(self.root, "a.example", "index.html", "<img src='http://b.example/shared.gif'>")
        write(self.root, "b.example", "shared.gif", "GIF89a")
        row = cc.score_host(self.root, "a.example")
        self.assertEqual(row["broken"], 0)

    def test_demands_flags_what_an_era_browser_cannot_do(self):
        write(
            self.root,
            "modern.example",
            "index.html",
            "<script>document.write('<a>nav</a>')</script><table><table></table></table><img src='x.gif' usemap='#m'>",
        )
        row = cc.score_host(self.root, "modern.example")
        self.assertIn("docwrite", row["demands"])
        self.assertIn("js", row["demands"])
        self.assertIn("imagemap", row["demands"])
        self.assertEqual(row["table_depth"], 2)

    def test_directory_reference_resolves_to_its_index(self):
        write(self.root, "dir.example", "index.html", "<img src='/art/'>")
        write(self.root, "dir.example", "art/index.html", "<html>")
        row = cc.score_host(self.root, "dir.example")
        self.assertEqual(row["broken"], 0)

    def test_host_without_a_landing_page_is_skipped(self):
        os.makedirs(os.path.join(self.root, "empty.example"))
        self.assertIsNone(cc.score_host(self.root, "empty.example"))

    def test_scan_orders_nothing_but_returns_every_scorable_host(self):
        write(self.root, "one.example", "index.html", "<img src='a.gif'>")
        write(self.root, "two.example", "index.htm", "<img src='b.gif'>")
        os.makedirs(os.path.join(self.root, "three.example"))
        hosts = {row["host"] for row in cc.scan(self.root)}
        self.assertEqual(hosts, {"one.example", "two.example"})

    def test_latin1_bytes_do_not_raise(self):
        write(self.root, "jp.example", "index.html", "<title>\xe6\x97\xa5</title><img src='a.gif'>")
        self.assertIsNotNone(cc.score_host(self.root, "jp.example"))


class FollowsWhereTheVisitorActuallyLandsTest(unittest.TestCase):
    """spacejam.com's shape: a splash that bounces to the real page."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def test_a_meta_refresh_splash_is_scored_at_its_destination(self):
        write(
            self.root,
            "splash.example",
            "index.html",
            '<meta http-equiv="REFRESH" content="25; URL=index.cgi"><img src=\'splash.jpg\'>',
        )
        write(self.root, "splash.example", "splash.jpg", "JPEG")
        write(self.root, "splash.example", "index.cgi", "<img src='nav.gif'><img src='gone.gif'>")
        write(self.root, "splash.example", "nav.gif", "GIF89a")
        row = cc.score_host(self.root, "splash.example")
        # Scored the destination (two bitmaps, one missing), not the one-image splash.
        self.assertEqual(row["assets"], 2)
        self.assertEqual(row["broken"], 1)

    def test_a_refresh_to_a_page_we_do_not_have_keeps_the_splash(self):
        write(
            self.root,
            "dead.example",
            "index.html",
            "<meta http-equiv=refresh content='0; url=/nowhere.html'><img src='a.gif'>",
        )
        write(self.root, "dead.example", "a.gif", "GIF89a")
        row = cc.score_host(self.root, "dead.example")
        self.assertEqual(row["assets"], 1)
        self.assertEqual(row["broken"], 0)

    def test_a_refresh_loop_terminates(self):
        write(self.root, "loop.example", "index.html", "<meta http-equiv=refresh content='0; url=index.html'>")
        self.assertIsNotNone(cc.score_host(self.root, "loop.example"))


class PresentIsNotTheSameAsRealTest(unittest.TestCase):
    """The captured-error-page trap: the file exists and is the server's error text."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def test_a_captured_imagemap_error_is_reported(self):
        write(
            self.root,
            "ismap.example",
            "index.html",
            "<a href='bin/index.map'><img src='nav.gif' ismap></a>",
        )
        write(self.root, "ismap.example", "nav.gif", "GIF89a")
        write(
            self.root,
            "ismap.example",
            "bin/index.map",
            "<TITLE>Imagemap Error</TITLE><H1>Imagemap Error</H1>Your client did not send any coordinates.",
        )
        row = cc.score_host(self.root, "ismap.example")
        # The page DRAWS whole -- the defect is one click deep, so it is its own count.
        self.assertEqual(row["complete_pct"], 100.0)
        self.assertEqual(row["error_docs"], 1)

    def test_a_real_map_file_is_not_flagged(self):
        write(self.root, "good.example", "index.html", "<a href='m.map'><img src='n.gif' ismap></a>")
        write(self.root, "good.example", "n.gif", "GIF89a")
        write(self.root, "good.example", "m.map", "default /index.html\nrect /a.html 0,0 10,10")
        row = cc.score_host(self.root, "good.example")
        self.assertEqual(row["error_docs"], 0)

    def test_a_long_html_page_is_not_mistaken_for_an_error_stub(self):
        write(self.root, "big.example", "index.html", "<a href='p.html'><img src='n.gif' ismap></a>")
        write(self.root, "big.example", "n.gif", "GIF89a")
        write(self.root, "big.example", "p.html", "<html>" + ("<p>error handling in 1996</p>" * 40))
        row = cc.score_host(self.root, "big.example")
        self.assertEqual(row["error_docs"], 0)


if __name__ == "__main__":
    unittest.main()
