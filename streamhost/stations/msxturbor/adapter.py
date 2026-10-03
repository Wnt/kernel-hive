#!/usr/bin/env python3
"""Private mamectl/1 -> openMSX XML bridge; the visitor never supplies Tcl."""

import asyncio
import os
from pathlib import Path
import sys
import struct
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape


class Adapter:
    def __init__(self, process):
        self.process = process
        self.replies = asyncio.Queue()
        self.lock = asyncio.Lock()
        self.buttons = 0
        self.position = None
        self.keys = {}
        self.last_release = 0.0
        self.motion_frame = None
        self.button_frame = None

    async def read_xml(self):
        parser = ET.XMLPullParser(["start", "end"])
        root = None
        while data := await self.process.stdout.read(65536):
            parser.feed(data)
            for event, element in parser.read_events():
                if root is None:
                    root = element
                if event != "end":
                    continue
                if element.tag == "reply":
                    await self.replies.put((element.get("result"), element.text or ""))
                if element.tag in ("reply", "log", "update"):
                    element.clear()
                    root.remove(element)
        await self.replies.put(("nok", "openMSX exited"))

    async def command(self, command):
        self.process.stdin.write(f"<command>{escape(command)}</command>\n".encode())
        await self.process.stdin.drain()
        result, message = await asyncio.wait_for(self.replies.get(), 5)
        if result != "ok":
            raise ValueError(message)
        return message

    async def frame(self):
        return int(await self.command("machine_info VDP_frame_count"))

    async def settle_before_edge(self):
        # Port sampling precedes VSHELL's application cursor/menu processing.
        # Let three completed guest frames pass after motion or a button edge.
        recent = [f for f in (self.motion_frame, self.button_frame) if f is not None]
        if not recent:
            return
        target = max(recent) + 3
        deadline = asyncio.get_running_loop().time() + 2
        while await self.frame() < target:
            if asyncio.get_running_loop().time() >= deadline:
                raise ValueError("guest video clock stalled")
            await asyncio.sleep(0.002)

    async def mouse_packet(self, dx, dy):
        first = int(await self.command(f"hive_mouse {dx} {dy} {self.buttons}"))
        # Wait for two actual joystick-port mouse samples. VDP frames alone
        # do not prove a busy application has consumed the movement packet.
        deadline = asyncio.get_running_loop().time() + 2
        while (int(await self.command("hive_mouse")) - first) & 0x7FFFFFFF < 2:
            if asyncio.get_running_loop().time() >= deadline:
                raise ValueError("guest is not sampling its mouse")
            await asyncio.sleep(0.002)

    async def mouse(self, dx=0, dy=0):
        # VSHELL's signed movement path wraps large deltas. Keep every sample
        # small and wait for the guest to consume it before issuing another.
        while dx or dy:
            x, y = max(-64, min(64, dx)), max(-64, min(64, dy))
            await self.mouse_packet(x, y)
            dx -= x
            dy -= y
        await self.mouse_packet(0, 0)

    async def release(self):
        self.buttons = 0
        await self.command("hive_mouse 0 0 0")
        for row, mask in self.keys:
            await self.command(f"keymatrixup {row} {mask}")
        self.keys.clear()
        self.position = None
        self.motion_frame = self.button_frame = None

    async def inject(self, parts):
        if not parts:
            raise ValueError("empty command")
        verb = parts[0]
        if verb == "KEY" and len(parts) == 4:
            down, row, mask = map(int, parts[1:])
            if down not in (0, 1) or not 0 <= row <= 11 or mask not in [1 << i for i in range(8)]:
                raise ValueError("invalid matrix edge")
            loop = asyncio.get_running_loop()
            modifier = row == 6 and mask <= 16
            if down and not modifier:
                await asyncio.sleep(max(0, self.last_release + 0.04 - loop.time()))
            if not down and (row, mask) in self.keys:
                await asyncio.sleep(max(0, self.keys[(row, mask)] + 0.04 - loop.time()))
            first = int(await self.command(f"keymatrix{'down' if down else 'up'} {row} {mask}"))
            # The edge already applied even if the guest stops scanning.
            if down:
                self.keys[(row, mask)] = loop.time()
            deadline = loop.time() + 5
            while (int(await self.command(f"keymatrixup {row} 0")) - first) & 0x7FFFFFFF < 2:
                if loop.time() >= deadline:
                    raise ValueError("guest is not scanning its keyboard")
                await asyncio.sleep(0.002)
            if not down:
                self.keys.pop((row, mask), None)
                if not modifier:
                    self.last_release = loop.time()
        elif verb == "MOVEA" and len(parts) == 3:
            x, y = map(int, parts[1:])
            # VSHELL's 256x212 pointer space is doubled in IFB1, with
            # its active picture starting at (64,28). openMSX divides by two.
            x, y = max(0, min(255, (x - 64) // 2)), max(0, min(211, (y - 28) // 2))
            if self.position == (x, y):
                return
            if self.position is None:
                await self.mouse(-640, -480)
                self.position = (0, 0)
            px, py = self.position
            await self.mouse(2 * (x - px), 2 * (y - py))
            self.position = (x, y)
            self.motion_frame = await self.frame()
        elif verb == "MOVEP" and len(parts) == 3:
            dx, dy = map(int, parts[1:])
            if abs(dx) > 1024 or abs(dy) > 1024:
                raise ValueError("relative motion out of bounds")
            await self.mouse(dx, dy)
            self.position = None
            self.motion_frame = await self.frame()
        elif verb in ("DOWN1", "UP1", "DOWN2", "UP2", "DOWN3", "UP3") and len(parts) == 1:
            await self.settle_before_edge()
            bit = {"1": 1, "2": 2, "3": 0}[verb[-1]]
            self.buttons = self.buttons | bit if verb.startswith("DOWN") else self.buttons & ~bit
            await self.mouse()
            self.button_frame = await self.frame()
        else:
            raise ValueError("unsupported verb")

    @staticmethod
    def request(line):
        parts = line.decode("ascii").strip().split()
        if len(parts) < 2:
            raise ValueError("empty request")
        seq = parts.pop(0)
        if not seq.isdecimal() or len(seq) > 20:
            raise ValueError("invalid sequence")
        return seq, parts

    @classmethod
    def move_request(cls, line):
        if line is None:
            return None
        try:
            seq, parts = cls.request(line)
            if len(parts) == 3 and parts[0] == "MOVEA":
                int(parts[1]), int(parts[2])
                return seq, parts
        except ValueError:
            pass
        return None

    async def client(self, reader, writer):
        writer.write(b"HELLO mamectl/1 openmsx-native\n")
        await writer.drain()
        queue = asyncio.Queue(maxsize=128)

        async def receive():
            try:
                while line := await reader.readline():
                    await queue.put(line)
            except (ValueError, ConnectionError):
                pass
            await queue.put(None)

        receiver = asyncio.create_task(receive())
        empty = object()
        pending = empty
        try:
            while True:
                line = await queue.get() if pending is empty else pending
                pending = empty
                if line is None:
                    break
                seq, parts = self.request(line)
                if self.move_request(line):
                    # Only adjacent absolute motion is replaceable. Stop at
                    # every key/button edge: it must use its preceding target.
                    while not queue.empty():
                        following = queue.get_nowait()
                        move = self.move_request(following)
                        if move is None:
                            pending = following
                            break
                        writer.write(f"{seq} OK\n".encode())
                        seq, parts = move
                try:
                    async with self.lock:
                        await self.inject(parts)
                    writer.write(f"{seq} OK\n".encode())
                except ValueError:
                    self.position = None
                    writer.write(f"{seq} ERR rejected\n".encode())
                await writer.drain()
        except (ValueError, ConnectionError, asyncio.TimeoutError):
            pass
        finally:
            receiver.cancel()
            await asyncio.gather(receiver, return_exceptions=True)
            async with self.lock:
                await self.release()
            writer.close()
            await writer.wait_closed()


async def main():
    socket_path, pidfile, *command = sys.argv[1:]
    process = await asyncio.create_subprocess_exec(
        *command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE
    )
    Path(pidfile).write_text(str(process.pid))
    adapter = Adapter(process)
    xml = asyncio.create_task(adapter.read_xml())
    process.stdin.write(b"<openmsx-control>\n")
    # Readiness is a command acknowledgement, never a guessed boot delay.
    await adapter.command("set pause false")
    if os.environ.get("MSX_PROFILE") == "view":
        # A blue BIOS field can settle for several seconds before the desktop.
        # Do not home a mouse against that transient screen. VSHELL's white
        # content pane is much larger than any white lettering in the intro.
        frame = Path(os.environ["OPENMSX_SHM_PATH"])
        deadline = asyncio.get_running_loop().time() + 90
        while True:
            data = frame.read_bytes() if frame.exists() else b""
            if len(data) > 64 and not struct.unpack_from("<Q", data, 24)[0] & 1:
                if data[64:].count(b"\xff\xff\xff\xff") > 50000:
                    break
            if process.returncode is not None or asyncio.get_running_loop().time() > deadline:
                raise RuntimeError("VSHELL framebuffer did not become ready")
            await asyncio.sleep(0.05)
    server = await asyncio.start_unix_server(adapter.client, socket_path, limit=2048)
    os.chmod(socket_path, 0o600)
    async with server:
        await process.wait()
    await xml
    return process.returncode


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
