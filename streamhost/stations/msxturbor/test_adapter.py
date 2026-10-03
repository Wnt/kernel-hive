"""The visitor protocol must never become a general Tcl command channel."""

import asyncio
import unittest

from adapter import Adapter


class Writer:
    def __init__(self):
        self.data = bytearray()

    def write(self, data):
        self.data.extend(data)

    async def drain(self):
        pass

    def close(self):
        pass

    async def wait_closed(self):
        pass


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

        writer = Writer()
        await self.adapter.client(reader, writer)
        self.assertEqual(
            writer.data.splitlines(),
            [b"HELLO mamectl/1 openmsx-native", b"17 OK", b"18 OK", b"19 ERR rejected"],
        )

    async def test_coalesces_motion_without_crossing_ordered_edges(self):
        reader = asyncio.StreamReader()
        reader.feed_data(b"1 MOVEA 100 100\n2 MOVEA 200 200\n3 DOWN1\n4 MOVEA 300 300\n5 MOVEA 400 400\n6 UP1\n")
        reader.feed_eof()
        applied = []

        async def inject(parts):
            applied.append(parts)

        self.adapter.inject = inject
        writer = Writer()
        await self.adapter.client(reader, writer)
        self.assertEqual(
            applied,
            [["MOVEA", "200", "200"], ["DOWN1"], ["MOVEA", "400", "400"], ["UP1"]],
        )
        self.assertEqual(writer.data.splitlines()[1:], [f"{i} OK".encode() for i in range(1, 7)])

    async def test_invalid_motion_is_rejected_not_coalesced_away(self):
        reader = asyncio.StreamReader()
        reader.feed_data(b"1 MOVEA 100 100\n2 MOVEA invalid 200\n3 MOVEA 300 300\n")
        reader.feed_eof()
        applied = []

        async def inject(parts):
            int(parts[1]), int(parts[2])
            applied.append(parts)

        self.adapter.inject = inject
        writer = Writer()
        await self.adapter.client(reader, writer)
        self.assertEqual(applied, [["MOVEA", "100", "100"], ["MOVEA", "300", "300"]])
        self.assertEqual(writer.data.splitlines()[1:], [b"1 OK", b"2 ERR rejected", b"3 OK"])

    async def test_disconnect_does_not_block_cancelling_a_full_receiver(self):
        reader = asyncio.StreamReader()
        reader.feed_data(b"invalid\n" + b"1 DOWN1\n" * 256)
        writer = Writer()
        await asyncio.wait_for(self.adapter.client(reader, writer), 1)
        self.assertEqual(self.commands, ["hive_mouse 0 0 0"])

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
