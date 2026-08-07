/* warpd_os2.c - in-guest pointer agent for OS/2 Warp (Presentation Manager).
 *
 * STATUS 2026-07-13: MOVE tracking VERIFIED 1:1 by framebuffer and BAKED LIVE on
 * the os2warp gallery tile (SH_POINTER=warpd). Two fixes turned the long-
 * "move-only-in-theory" agent into a working one: (1) WinCreateMsgQueue after
 * WinInitialize (required before this thread may drive PM pointer APIs), and
 * (2) a DosDevIOCtl SET_DCBINFO forcing MODE_NOWAIT_READ_TIMEOUT on COM1 — COM.SYS
 * otherwise opens the port in a blocking read mode where DosRead never returns our
 * short newline-delimited commands (root cause: zero bytes ever reached the loop).
 *
 * Native absolute cursor via WinSetPointerPos(HWND_DESKTOP, x, y); buttons via
 * correctly paired WM_BUTTONxDOWN/UP messages posted to the PM window under the
 * pointer.  Coordinates in mouse messages are CLIENT coordinates, not desktop
 * coordinates.  A held button retains its original/captured target and receives
 * WM_MOUSEMOVE until release; the second nearby press inside SV_DBLCLKTIME is a
 * WM_BUTTONxDBLCLK.  Those details are required by frame sizing, menus, and games.
 * WinSetPointerPos alone is decoupled from the PS/2 driver's button position.
 * MouSetPtrPos mirrors every warp into OS/2's mouse subsystem, so production uses
 * SH_WARPD_BUTTONS=qemu: real PS/2 buttons then get native PM capture, frame sizing,
 * menu, and double-click semantics at the warped coordinate.  P/R remain a working
 * synthetic fallback with separate state, capture-aware motion, client-coordinate
 * mapping, and explicit WM_BUTTONxDBLCLK generation.
 * Wheel buttons are different: protocol buttons 4/5 are translated to PM
 * WM_VSCROLL SB_LINEUP/SB_LINEDOWN at the window under the pointer.  Treating
 * them as an ordinary button used to collapse both directions to WM_BUTTON3.
 *
 * OS/2 PM origin is BOTTOM-LEFT (y grows upward), unlike the daemon's TOP-LEFT
 * guest pixels, so we flip: pm_y = ScreenH - 1 - y.  Screen height from
 * WinQuerySysValue(HWND_DESKTOP, SV_CYSCREEN).
 *
 * Transport: COM1 serial (QEMU isa-serial chardev socket). OS/2 exposes it as
 * COM1 -> open "COM1" with DosOpen and DosRead, or raw @0x3F8 in a ring-0 driver.
 * The simplest user-mode path is DosOpen("COM1",...) + DosRead (below). OS/2's
 * COM.SYS must be loaded (default). TCP is also possible (OS/2 has a full TCP/IP
 * stack + BSD sockets) but serial avoids configuring the guest network.
 *
 * Build (OpenWatcom, 32-bit OS/2 PM EXE, cross from Linux):
 *   wcl386 -bt=os2 -l=os2v2_pm -fe=WARPD.EXE warpd_os2.c
 *
 * Delivery: attach a FAT/ISO with WARPD.EXE, run from an OS/2 command window, or
 * add to STARTUP.CMD for autostart in the golden.
 */
#define INCL_WIN
#define INCL_DOSPROCESS
#define INCL_DOSFILEMGR
#define INCL_DOSDEVICES
#define INCL_DOSDEVIOCTL
#define INCL_MOU
#include <os2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static HAB  hab;
static LONG scr_h;
static HMOU hmou;
static BOOL have_mou;
static HWND down_hwnd[4];
static BOOL is_down[4];
static ULONG last_down_time[4];
static LONG last_down_x[4], last_down_y[4];
static HWND last_down_hwnd[4];

static POINTL desktop_point(LONG x, LONG y) {
    POINTL pt;
    pt.x = x;
    pt.y = scr_h - 1 - y;
    return pt;
}

static MPARAM window_point(HWND hwnd, LONG x, LONG y) {
    POINTL pt = desktop_point(x, y);
    WinMapWindowPoints(HWND_DESKTOP, hwnd, &pt, 1);
    return MPFROM2SHORT((SHORT)pt.x, (SHORT)pt.y);
}

static void button_messages(LONG btn, PULONG dn, PULONG up, PULONG dbl) {
    if (btn == 1) {
        *dn = WM_BUTTON1DOWN; *up = WM_BUTTON1UP; *dbl = WM_BUTTON1DBLCLK;
    } else if (btn == 3) { /* wire btn3 = right; PM calls right button 2 */
        *dn = WM_BUTTON2DOWN; *up = WM_BUTTON2UP; *dbl = WM_BUTTON2DBLCLK;
    } else {
        *dn = WM_BUTTON3DOWN; *up = WM_BUTTON3UP; *dbl = WM_BUTTON3DBLCLK;
    }
}

static void pt_move(LONG x, LONG y) {
    LONG btn;
    HWND hwnd;
    PTRLOC pos;
    WinSetPointerPos(HWND_DESKTOP, x, scr_h - 1 - y);   /* flip to PM origin */
    if (have_mou) {
        pos.row = (USHORT)y;
        pos.col = (USHORT)x;
        MouSetPtrPos(&pos, hmou);
    }
    for (btn = 1; btn <= 3; btn++) {
        if (!is_down[btn])
            continue;
        hwnd = WinQueryCapture(HWND_DESKTOP);
        if (!hwnd)
            hwnd = down_hwnd[btn];
        if (hwnd)
            WinPostMsg(hwnd, WM_MOUSEMOVE, window_point(hwnd, x, y), 0);
    }
}

/* --- latest-wins move coalescing (mirror win9x/warpnet.c + win311/agent.c) -----
 * Hold only the NEWEST pending 'M' position and apply it once via flush_move(),
 * instead of replaying every buffered move through WinSetPointerPos/MouSetPtrPos.
 * See the drain loop in main() for why this is required on os2warp. */
static LONG pend_x, pend_y;
static BOOL have_pend;
static void flush_move(void) {
    if (have_pend) {
        pt_move(pend_x, pend_y);
        have_pend = FALSE;
    }
}

static void pt_wheel(LONG btn, LONG x, LONG y) {
    HWND hwnd; POINTL pt; USHORT action;
    pt_move(x, y);
    pt.x = x; pt.y = scr_h - 1 - y;
    hwnd = WinWindowFromPoint(HWND_DESKTOP, &pt, TRUE);
    action = (btn == 4) ? SB_LINEUP : SB_LINEDOWN;
    if (hwnd)
        WinPostMsg(hwnd, WM_VSCROLL, 0, MPFROM2SHORT(0, action));
}
static void pt_button(LONG btn, LONG x, LONG y, BOOL down) {
    HWND hwnd; POINTL pt; ULONG dn, up, dbl, msg, now, dbl_ms;
    if (btn < 1 || btn > 3)
        return;
    button_messages(btn, &dn, &up, &dbl);
    pt_move(x, y);
    if (down) {
        pt = desktop_point(x, y);
        hwnd = WinWindowFromPoint(HWND_DESKTOP, &pt, TRUE);
        if (!hwnd)
            return;
        now = WinGetCurrentTime(hab);
        dbl_ms = (ULONG)WinQuerySysValue(HWND_DESKTOP, SV_DBLCLKTIME);
        msg = dn;
        if (last_down_hwnd[btn] == hwnd && now - last_down_time[btn] <= dbl_ms &&
            abs(x - last_down_x[btn]) <= 4 && abs(y - last_down_y[btn]) <= 4) {
            msg = dbl;
            last_down_time[btn] = 0;
        } else {
            last_down_time[btn] = now;
            last_down_x[btn] = x;
            last_down_y[btn] = y;
            last_down_hwnd[btn] = hwnd;
        }
        down_hwnd[btn] = hwnd;
        is_down[btn] = TRUE;
        WinPostMsg(hwnd, msg, window_point(hwnd, x, y), 0);
    } else {
        hwnd = WinQueryCapture(HWND_DESKTOP);
        if (!hwnd)
            hwnd = down_hwnd[btn];
        if (hwnd)
            WinPostMsg(hwnd, up, window_point(hwnd, x, y), 0);
        is_down[btn] = FALSE;
        down_hwnd[btn] = NULLHANDLE;
    }
}

static void pt_click(LONG btn, LONG x, LONG y) {
    if (btn == 4 || btn == 5) {
        pt_wheel(btn, x, y);
        return;
    }
    pt_button(btn, x, y, TRUE);
    pt_button(btn, x, y, FALSE);
}

int main(void) {
    HFILE h; ULONG act, br, i, plen; char buf[256], line[64]; int li = 0;
    APIRET rc; HMQ hmq; DCBINFO dcb;
    hab = WinInitialize(0);
    /* A message queue is required before this thread may drive PM pointer /
     * window APIs (WinSetPointerPos, WinWindowFromPoint, WinPostMsg). Without
     * it those calls silently no-op. */
    hmq = WinCreateMsgQueue(hab, 0);
    scr_h = WinQuerySysValue(HWND_DESKTOP, SV_CYSCREEN);
    have_mou = (MouOpen(NULL, &hmou) == 0);

    rc = DosOpen("COM1", &h, &act, 0, FILE_NORMAL,
                 OPEN_ACTION_OPEN_IF_EXISTS,
                 OPEN_FLAGS_FAIL_ON_ERROR | OPEN_SHARE_DENYNONE | OPEN_ACCESS_READWRITE,
                 NULL);
    if (rc) { printf("open COM1 failed rc=%lu\n", rc); return 1; }
    /* CRITICAL: COM.SYS opens COM1 in a blocking read-timeout mode (fbTimeout
     * ~0xd2) where DosRead waits indefinitely and never returns our short
     * newline-delimited commands. Force MODE_NOWAIT_READ_TIMEOUT so DosRead
     * returns immediately with whatever bytes have arrived, and drop DSR/CTS
     * handshaking (QEMU's socket chardev asserts no modem-control lines).
     * QEMU ignores baud/parity for a socket chardev, so we leave the line
     * params at their opened defaults. Without this the agent never sees a
     * byte and the pointer never moves. */
    dcb.usWriteTimeout = 6000;
    dcb.usReadTimeout  = 100;
    dcb.fbCtlHndShake  = MODE_DTR_CONTROL;   /* DTR on; no DSR sensitivity/HS */
    dcb.fbFlowReplace  = MODE_RTS_CONTROL;   /* RTS on; no XON/XOFF          */
    dcb.fbTimeout      = MODE_NOWAIT_READ_TIMEOUT | MODE_NO_WRITE_TIMEOUT;
    dcb.bErrorReplacementChar = 0; dcb.bBreakReplacementChar = 0;
    dcb.bXONChar = 0x11; dcb.bXOFFChar = 0x13;
    plen = sizeof(dcb);
    DosDevIOCtl(h, IOCTL_ASYNC, ASYNC_SETDCBINFO, &dcb, sizeof(dcb), &plen, NULL, 0, NULL);

    /* --- per-drain move coalescing (mirror win9x/warpnet.c + win311/agent.c) ----
     * os2warp runs under -accel tcg (slow emulation), so COM.SYS RX + this agent
     * apply moves far slower than the daemon's paced ~33 fresh positions/s. Replaying
     * every buffered 'M' one-by-one (WinSetPointerPos + MouSetPtrPos + capture posts
     * per line) lets an unbounded backlog pile up in the COM RX buffer, and the cursor
     * rubber-bands ever farther behind (settle grew 261ms->563ms over an 18s hover).
     * Fix: within a drain PEND only the newest 'M' and apply it once via flush_move();
     * a button/wheel/drag verb (P/R/B/C/D/U/W) first flushes the pending move so
     * click/drag ordering + position stay correct. Keep draining while DosRead keeps
     * returning a full buffer so a mid-processing burst also collapses; flush the final
     * pended position once the port is drained (short read, or no data). */
    for (;;) {
        rc = DosRead(h, buf, sizeof(buf), &br);
        if (rc || br == 0) { flush_move(); DosSleep(15); continue; }
        for (i = 0; i < br; i++) {
            char c = buf[i];
            if (c == '\n' || c == '\r') {
                int x, y, n; char cmd;
                line[li] = 0; li = 0;
                if (!line[0]) continue;
                cmd = line[0];
                if (cmd == 'M' && sscanf(line+1, "%d %d", &x, &y) == 2) {
                    pend_x = x; pend_y = y; have_pend = TRUE;   /* newest wins */
                }
                else if (cmd == 'P' && sscanf(line+1, "%d %d %d", &n,&x,&y)==3) {
                    flush_move(); pt_button(n, x, y, TRUE);
                }
                else if (cmd == 'R' && sscanf(line+1, "%d %d %d", &n,&x,&y)==3) {
                    flush_move(); pt_button(n, x, y, FALSE);
                }
                else if ((cmd=='B'||cmd=='C') && sscanf(line+1,"%d %d %d",&n,&x,&y)>=2) {
                    if (cmd=='C'){ sscanf(line+1,"%d %d",&x,&y); n=1; }
                    flush_move(); pt_click(n, x, y);
                }
                else if ((cmd=='D'||cmd=='U'||cmd=='W') &&
                         sscanf(line+1,"%d %d",&x,&y)==2) {
                    flush_move();
                    if (cmd=='D') pt_button(1, x, y, TRUE);
                    else if (cmd=='U') pt_button(1, x, y, FALSE);
                    else pt_move(x, y);
                }
            } else if (li < (int)sizeof(line)-1) {
                line[li++] = c;
            }
        }
        /* port drained for now (short read) => apply the final pended move once */
        if (br < sizeof(buf)) flush_move();
    }
}
