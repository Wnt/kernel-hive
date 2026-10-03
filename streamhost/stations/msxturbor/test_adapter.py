"""The visitor protocol must never become a general Tcl command channel."""

import unittest

from adapter import Adapter


class ProtocolTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.adapter = Adapter(None)
        self.commands = []

        async def command(value):
            self.commands.append(value)
            return "2" if value == "hive_mouse" or (value.startswith("keymatrixup") and value.endswith(" 0")) else "0"

        self.adapter.command = command

    async def test_rejects_tcl_and_invalid_matrix_bits(self):
        for line in (
            "exec touch /tmp/bad",
            "KEY 1 0 3",
            "KEY 1 12 1",
            "KEY 2 0 1",
            "MOVEA 2;exit 4",
            "MOVEP 99999 0",
        ):
            with self.assertRaises(ValueError):
                await self.adapter.inject(line.split())
        self.assertEqual(self.commands, [])

    async def test_disconnect_releases_keys_and_both_buttons(self):
        await self.adapter.inject("KEY 1 6 1".split())
        await self.adapter.inject(["DOWN1"])
        await self.adapter.inject(["DOWN2"])
        await self.adapter.release()
        self.assertIn("hive_mouse 0 0 3", self.commands)
        self.assertEqual(self.commands[-2:], ["hive_mouse 0 0 0", "keymatrixup 6 1"])
        self.assertEqual(self.adapter.keys, {})
        self.assertIsNone(self.adapter.position)

    async def test_absolute_targets_are_bounded_and_coherent(self):
        await self.adapter.inject("MOVEA 99999 -8".split())
        self.assertEqual(self.adapter.position, (255, 0))
        self.assertTrue(all("99999" not in c for c in self.commands))
        count = len(self.commands)
        await self.adapter.inject("MOVEA 639 0".split())
        self.assertEqual(self.commands[count:], ["hive_mouse 0 0 0", "hive_mouse"])


if __name__ == "__main__":
    unittest.main()
