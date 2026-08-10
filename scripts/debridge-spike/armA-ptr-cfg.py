#!/usr/bin/env python3
"""Arm A pointer polarity + gain, written into MAME's own input configuration.

Run INSIDE the arm A kiosk guest, against the cfg MAME generates for itself:

    scp -P 5793 armA-ptr-cfg.py root@127.0.0.1:/tmp/
    ssh -p 5793 root@127.0.0.1 \\
        'python3 /tmp/armA-ptr-cfg.py /opt/bridge/atarist-mame/cfg/st.cfg &&
         systemctl restart getty@tty1'

It EDITS the file MAME wrote rather than shipping a whole st.cfg: a hand-written
replacement carrying only the <input> section is silently ignored by MAME 0.289
(measured -- the ports load from the generated file and not from an equivalent
minimal one), and a config that is quietly not applied is exactly the failure
this rig keeps paying for. Idempotent: it strips any previous insert first, so
re-running after MAME has rewritten the file on exit is safe.

WHAT IT SETS, AND WHY EACH IS MEASURED RATHER THAN ASSUMED
----------------------------------------------------------
reverse="yes" on :ikbd:MOUSEX and :ikbd:MOUSEY. Driving the usb-tablet the
browser path ends at, and reading the EMULATED ioport latch back out of MAME
(stkbd's m_mouse_x/m_mouse_y save items, over a read-only mamectl ITEM), showed
a clean sign NEGATION on both axes: commanding the host pointer RIGHT 40 surface
px moved the ioport -257 counts, DOWN 40 px moved it -342. Linear in the
commanded distance, and a stationary pointer produced no change at all -- so it
is a polarity flip in the host -> SDL -> MAME axis path, and NOT the
relative-mode-warp pathology an absolute pointing device usually produces (that
one tracks the pointer's offset from the window centre and drifts while
stationary; this does neither). Ground truth for the sign comes from arm B,
where the ctlsock module writes the same two ioports directly: a POSITIVE delta
moves the GEM cursor RIGHT / DOWN.

sensitivity="1", down from the driver's PORT_SENSITIVITY(10). MAME's analog path
turned one surface pixel into 6.4 (X) / 8.6 (Y) ioport counts, and stkbd latches
an 8-BIT ioport keeping only the SIGN of the change -- so any motion past ~20 px
in one emulated frame wrapped the field and the guest read the direction
BACKWARDS. That is ordinary pointer speed, which is why the axis felt reversed
at some speeds and merely wrong at others. At sensitivity 1 the same wrap needs
~200 px per frame, which no hand reaches. It costs nothing in cursor speed: the
device delivers at most one quadrature step per latch whatever the magnitude.

Arm B is untouched by this. It has its own -cfg_directory, and it writes the
ioport through ioport_field::set_value, which lands in m_adjoverride and is
returned by analog_field::read BEFORE apply_settings -- i.e. before reverse and
sensitivity are applied at all.
"""

import re
import sys

PORTS = (
    '            <port tag=":ikbd:MOUSEX" type="P1_MOUSE_X" mask="255" '
    'defvalue="0" sensitivity="1" reverse="yes" />\n'
    '            <port tag=":ikbd:MOUSEY" type="P1_MOUSE_Y" mask="255" '
    'defvalue="0" sensitivity="1" reverse="yes" />\n'
)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    # utf-8-sig: MAME writes a BOM, and re-writing it without one is a
    # gratuitous diff against the file it will regenerate.
    with open(path, encoding="utf-8-sig") as fh:
        text = fh.read()
    text = re.sub(r'[ \t]*<port tag=":ikbd:MOUSE[XY]".*?/>\n', "", text)
    m = re.search(r"[ \t]*<input>\n", text)
    if not m:
        print(f"no <input> section in {path} -- is this MAME's own st.cfg?")
        return 1
    text = text[: m.end()] + PORTS + text[m.end() :]
    with open(path, "w", encoding="utf-8-sig") as fh:
        fh.write(text)
    print(f"patched {path}: :ikbd:MOUSEX/MOUSEY reverse=yes sensitivity=1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
