#!/usr/bin/env python3
"""persona-sim.py — stand in for a station's ICQ client, from a shell.

The greeting mechanic is "persona signs on -> bot says hello ~30 s later". That
is normally proven on a framebuffer, and the framebuffer stays the only proof
that a GUEST reacted. This tool proves the other half — that the SERVER and the
BOT do their part — without booting a guest, which is what you want when you are
debugging the bot at 2 a.m. or when the station is mid-install.

  persona-sim.py --server 127.0.0.1:5190 --uin 19898 --password xxxxxxxx \\
                 --listen 60 --say 'hey whats this network?' --say-after 40

Prints every inbound message with the seconds elapsed since sign-on, so
"greeting arrived at +30.4s" is a number you can paste into a report.
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import oscar  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description="Sign a persona UIN into an OSCAR server and log what it receives.")
    ap.add_argument("--server", default=os.environ.get("RN_BOT_SERVER", "10.99.0.2:5190"))
    ap.add_argument("--uin", default="98980")
    ap.add_argument("--password", default=os.environ.get("RN_PERSONA_PASSWORD", ""))
    ap.add_argument("--buddy", default="10000", help="the bot UIN to watch and talk to")
    ap.add_argument("--listen", type=float, default=60.0, help="seconds to stay signed on")
    ap.add_argument("--say", action="append", default=[], help="message to send to --buddy (repeatable)")
    ap.add_argument("--say-after", type=float, default=5.0, help="seconds after sign-on before the first --say")
    ap.add_argument("--say-gap", type=float, default=20.0, help="seconds between successive --say lines")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    if not args.password:
        print("persona-sim: --password (or RN_PERSONA_PASSWORD) required", file=sys.stderr)
        return 2

    host, _, port = args.server.partition(":")
    client = oscar.OscarClient(host, int(port or 5190), args.uin, args.password, buddies=[args.buddy])
    received: list[tuple[float, str, str]] = []
    t0 = time.monotonic()

    def on_message(sender: str, text: str) -> None:
        dt = time.monotonic() - t0
        received.append((dt, sender, text))
        print(f"  +{dt:6.1f}s  <{sender}>  {text}", flush=True)

    client.on_message = on_message
    client.connect()
    t0 = time.monotonic()
    print(f"signed on as {args.uin} at {args.server}; listening {args.listen:.0f}s", flush=True)
    threading.Thread(target=client.run_forever, daemon=True).start()

    def talk() -> None:
        time.sleep(args.say_after)
        for i, line in enumerate(args.say):
            if i:
                time.sleep(args.say_gap)
            print(f"  +{time.monotonic() - t0:6.1f}s  ->{args.buddy}   {line}", flush=True)
            client.send_im(args.buddy, line)

    if args.say:
        threading.Thread(target=talk, daemon=True).start()

    time.sleep(args.listen)
    client.close()
    print(f"\nreceived {len(received)} message(s):", flush=True)
    for dt, sender, text in received:
        print(f"  +{dt:6.1f}s  <{sender}>  {text}", flush=True)
    return 0 if received else 1


if __name__ == "__main__":
    sys.exit(main())
