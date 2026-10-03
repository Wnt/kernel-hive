"""The visitor protocol must never become a general Tcl command channel."""

import asyncio
import unittest

from adapter import Adapter


class ProtocolTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.adapter = Adapter(None)
        self.commands = []

        async def command(value):
            self.commands.append(value)
            if value == "machine_info VDP_frame_count":
                return str(3 * len(self.commands))
            return "2" if value == "hive_mouse" or (value.startswith("keymatrixup") and value.endswith(" 0")) else "0"

        self.adapter.command = command

    async def test_wire_acknowledgements_match_daemon_sequence_first_contract(self):
        reader = asyncio.StreamReader()
        reader.feed_data(b"17 KEY 1 0 1\n18 KEY 0 0 1\n19 exec evil\n")
        reader.feed_eof()

        class Writer:
            data = bytearray()

            def write(self, data):
                self.data.extend(data)

            async def drain(self):
                pass

            def close(self):
                pass

            async def wait_closed(self):
                pass

        writer = Writer()
        await self.adapter.client(reader, writer)
        self.assertEqual(
            writer.data.splitlines(),
            [b"HELLO mamectl/1 openmsx-native", b"17 OK", b"18 OK", b"19 ERR rejected"],
        )

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

    async def test_failed_guest_scan_still_releases_applied_key(self):
        async def command(value):
            self.commands.append(value)
            if value == "keymatrixup 0 0":
                raise ValueError("guest stopped scanning")
            return "0"

        self.adapter.command = command
        with self.assertRaises(ValueError):
            await self.adapter.inject("KEY 1 0 1".split())
        await self.adapter.release()
        self.assertEqual(self.commands[-1], "keymatrixup 0 1")
        self.assertEqual(self.adapter.keys, {})

    async def test_button_waits_for_application_frames_after_motion(self):
        frame = 10
        self.adapter.motion_frame = frame

        async def command(value):
            nonlocal frame
            self.commands.append(value)
            if value == "machine_info VDP_frame_count":
                frame += 1
                return str(frame)
            return "2" if value == "hive_mouse" else "0"

        self.adapter.command = command
        await self.adapter.inject(["DOWN1"])
        self.assertEqual(self.commands[:3], ["machine_info VDP_frame_count"] * 3)
        self.assertEqual(self.commands[3], "hive_mouse 0 0 1")

    async def test_absolute_targets_are_bounded_and_coherent(self):
        await self.adapter.inject("MOVEA 99999 -8".split())
        self.assertEqual(self.adapter.position, (255, 0))
        self.assertTrue(all("99999" not in c for c in self.commands))
        count = len(self.commands)
        await self.adapter.inject("MOVEA 639 0".split())
        self.assertEqual(self.commands[count:], [])


if __name__ == "__main__":
    unittest.main()
