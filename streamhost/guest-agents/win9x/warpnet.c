/* warpnet.c - in-guest absolute-cursor agent for Windows 95 / 98 SE.
 *
 * Positions the Win32 system cursor directly with SetCursorPos(x,y) -- true
 * full-screen absolute positioning, immune to the QEMU PS/2 *relative*-only mouse
 * (the win95 tile runs usb=off, so no absolute tablet; live win95 runs
 * SH_POINTER=warpd with THIS agent baked into the golden. win98se no longer
 * uses it: that tile is SH_POINTER=abs via usb-tablet under acpi=on).
 * This is the Win9x analogue of the Solaris warpd XTEST/XWarpPointer agent, and it
 * speaks the SAME newline M/P/R/B protocol, so the streamhost daemon drives it
 * UNCHANGED (Pointer::Warpd + warpd.rs), reached over a QEMU hostfwd exactly like
 * Solaris (host 127.0.0.1:PORT -> guest 10.0.2.15:7777).
 *
 * Transport: Winsock 1.1 TCP listener on :7777. The Win95 OSR2 golden already has
 * the MSTCP stack bound to the AMD PCnet adapter (DHCP -> SLIRP 10.0.2.15) and
 * ships wsock32.dll, so no guest config is needed and -- crucially -- adding a
 * hostfwd to the existing user netdev changes NO emulated device, so `loadvm golden`
 * stays valid (unlike a serial port, which the golden does not enumerate anyway).
 *
 * Protocol (guest pixels 0..w/0..h), identical to warpd.py:
 *   M x y      move cursor to (x,y)
 *   C x y      move to (x,y) then left click
 *   P n x y    move to (x,y) then PRESS button n   (1=L 2=M 3=R)
 *   R n x y    move to (x,y) then RELEASE button n
 *   B n x y    move to (x,y) then CLICK button n; n=4 wheel up, n=5 wheel down
 *   E <cmd>    run <cmd> through COMSPEC, reply ON THIS CONNECTION (warpd 'E'):
 *                O <base64 of stdout, first 16KB>\n
 *                X <exit code>\n
 *                .\n
 *              Byte-identical framing to solaris/warpd.py, so the host client
 *              streamhost/guest-agents/solaris/gexec.py (labctl exec_kind
 *              "warpd_e") drives this agent UNCHANGED.
 *   V          re-set the display mode (see note 2). Sent automatically after
 *              every 'E'; also usable on its own to un-wedge a framebuffer.
 *   QUIT       close this connection
 *
 * Two Win9x-specific limits on 'E', both deliberate:
 *   1. COMMAND.COM has no `2>&1` (that is an NT cmd.exe feature), so only
 *      STDOUT is captured. DOS tools write most errors to stdout anyway.
 *   2. Every 'E' ends with a forced display-mode reset, and that is load-bearing.
 *      MEASURED on the live win98se station 2026-08-20: ANY transient DOS box
 *      ("COMMAND.COM /c ...") leaves the guest's VBE-miniport display driver
 *      with a misprogrammed CRTC -- QEMU then reports a garbled 1600x176
 *      framebuffer instead of the 1600x1200 desktop, and it never comes back on
 *      its own. It is NOT about hiding the window (SW_HIDE, SW_SHOWMINNOACTIVE
 *      and a plain visible box all wedge it) and NOT about how it is launched
 *      (CreateProcess, Start>Run and a .PIF all wedge it): it is the transient
 *      VDM's video grab. Only a REAL mode program fixes it, so once the child
 *      is reaped the agent calls ChangeDisplaySettings(NULL, CDS_RESET), which
 *      re-sets the registry mode even though Windows believes nothing changed.
 *      The child runs SW_SHOWMINNOACTIVE so it never steals focus from the
 *      checkpoint fixture.
 *      Manual recovery, if a display ever wedges anyway: Start > Run > command
 *      (a PERSISTENT DOS box does not wedge it), then Alt+Enter TWICE -- full
 *      screen, then back to a window -- then `exit`. `loadvm golden` also works
 *      but discards everything done since the checkpoint. Or, over the wire:
 *      printf 'V\n' | nc 127.0.0.1 57792   (the 'V' verb below).
 *
 * Build (host, Debian):
 *   i686-w64-mingw32-gcc -O2 -s -mwindows -Wl,--no-insert-timestamp -o warpnet.exe warpnet.c -lwsock32
 * -mwindows => GUI subsystem, so no DOS box appears in the guest.
 */

#include <winsock.h>   /* Winsock 1.1 (wsock32.dll) - present on base Win95 */
#include <windows.h>

#ifndef MOUSEEVENTF_WHEEL
#define MOUSEEVENTF_WHEEL 0x0800
#endif
#ifndef WHEEL_DELTA
#define WHEEL_DELTA 120
#endif

/* Listener port. Default 7777 is win95's LIVE pointer port -- do not change it
 * for that station. Build a second binary for a station that wants its own port
 * (e.g. the retronet exec agent on win98se) with -DWARP_PORT=7788. */
#ifndef WARP_PORT
#define WARP_PORT 7777
#endif

/* 'E' verb sizing. EXEC_OUT is a fixed path because the accept loop is serial
 * (one client at a time), so there is never a second exec in flight. */
#define EXEC_OUT        "C:\\WNEXEC.OUT"
#define EXEC_MAX        16384
#define EXEC_TIMEOUT_MS 120000

static void logline(const char *s) {
    HANDLE h = CreateFileA("C:\\WARPNET.LOG", GENERIC_WRITE, FILE_SHARE_READ, NULL,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    SetFilePointer(h, 0, NULL, FILE_END);
    DWORD w; WriteFile(h, s, lstrlenA(s), &w, NULL); WriteFile(h, "\r\n", 2, &w, NULL);
    CloseHandle(h);
}

static void press(int n) {
    if (n == 1)      mouse_event(MOUSEEVENTF_LEFTDOWN,   0, 0, 0, 0);
    else if (n == 2) mouse_event(MOUSEEVENTF_MIDDLEDOWN, 0, 0, 0, 0);
    else if (n == 3) mouse_event(MOUSEEVENTF_RIGHTDOWN,  0, 0, 0, 0);
}
static void release(int n) {
    if (n == 1)      mouse_event(MOUSEEVENTF_LEFTUP,   0, 0, 0, 0);
    else if (n == 2) mouse_event(MOUSEEVENTF_MIDDLEUP, 0, 0, 0, 0);
    else if (n == 3) mouse_event(MOUSEEVENTF_RIGHTUP,  0, 0, 0, 0);
}
static void wheel(int dir) {
    mouse_event(MOUSEEVENTF_WHEEL, 0, 0, (DWORD)(dir > 0 ? WHEEL_DELTA : -WHEEL_DELTA), 0);
}
static void click(int n) {
    if (n == 4) { wheel(+1); return; }
    if (n == 5) { wheel(-1); return; }
    press(n); Sleep(15); release(n);
}

/* Force the display driver to program the video mode again. CDS_RESET is the
 * whole point: without it Windows compares the requested mode against what it
 * believes is current, finds no difference, and does nothing -- while the VGA
 * hardware is actually left misprogrammed by a transient DOS VDM. */
#ifndef CDS_RESET
#define CDS_RESET 0x40000000
#endif
static void video_kick(void) {
    ChangeDisplaySettingsA(NULL, CDS_RESET);
}

static void handle(char *line) {
    char *p = line;
    while (*p == ' ' || *p == '\t') p++;
    char c = *p;
    if (c == 0) return;
    if (c == 'Q' || c == 'q') return;   /* QUIT handled by caller (close conn) */
    int nums[3] = {0,0,0}, ni = 0, sign = 1, have = 0; long val = 0;
    for (p = p + 1; ; p++) {
        char ch = *p;
        if (ch == '-') { sign = -1; have = 1; }
        else if (ch >= '0' && ch <= '9') { val = val*10 + (ch - '0'); have = 1; }
        else {
            if (have && ni < 3) nums[ni++] = (int)(val*sign);
            val = 0; sign = 1; have = 0;
            if (ch == 0) break;
        }
    }
    switch (c) {
        case 'M': case 'm': if (ni >= 2) SetCursorPos(nums[0], nums[1]); break;
        case 'C': case 'c': if (ni >= 2) { SetCursorPos(nums[0], nums[1]); click(1); } break;
        case 'P': case 'p': if (ni >= 3) { SetCursorPos(nums[1], nums[2]); press(nums[0]); } break;
        case 'R': case 'r': if (ni >= 3) { SetCursorPos(nums[1], nums[2]); release(nums[0]); } break;
        case 'B': case 'b': if (ni >= 3) { SetCursorPos(nums[1], nums[2]); click(nums[0]); } break;
        case 'V': case 'v': video_kick(); break;
        default: break;
    }
}

/* ---- 'E' exec verb ------------------------------------------------------- */

static const char B64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* Encode n bytes of in[] into out[] (NUL-terminated). out must hold
 * ((n+2)/3)*4 + 1 bytes. Returns the encoded length. */
static int b64enc(const unsigned char *in, int n, char *out) {
    int i = 0, o = 0;
    while (n - i >= 3) {
        unsigned long v = ((unsigned long)in[i] << 16) |
                          ((unsigned long)in[i+1] << 8) | in[i+2];
        out[o++] = B64[(v >> 18) & 63]; out[o++] = B64[(v >> 12) & 63];
        out[o++] = B64[(v >>  6) & 63]; out[o++] = B64[v & 63];
        i += 3;
    }
    if (n - i == 1) {
        unsigned long v = (unsigned long)in[i] << 16;
        out[o++] = B64[(v >> 18) & 63]; out[o++] = B64[(v >> 12) & 63];
        out[o++] = '='; out[o++] = '=';
    } else if (n - i == 2) {
        unsigned long v = ((unsigned long)in[i] << 16) | ((unsigned long)in[i+1] << 8);
        out[o++] = B64[(v >> 18) & 63]; out[o++] = B64[(v >> 12) & 63];
        out[o++] = B64[(v >>  6) & 63]; out[o++] = '=';
    }
    out[o] = 0;
    return o;
}

/* send() can return short on Win9x's Winsock; loop until the whole buffer is out. */
static int sendall(SOCKET c, const char *b, int n) {
    int off = 0;
    while (off < n) {
        int w = send(c, b + off, n - off, 0);
        if (w <= 0) return -1;
        off += w;
    }
    return 0;
}

/* Run cmd via COMSPEC with stdout redirected to EXEC_OUT, hidden and windowed.
 * Fills out[] with up to outmax captured bytes, stores the child's exit code in
 * *rc, and returns the captured length (0 if the command produced nothing). */
static int run_exec(const char *cmd, char *out, int outmax, int *rc) {
    char comspec[MAX_PATH];
    char cl[2048];
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    DWORD code = 127, got = 0;
    int len = 0;
    HANDLE h;

    *rc = 127;
    if (!GetEnvironmentVariableA("COMSPEC", comspec, sizeof(comspec)))
        lstrcpyA(comspec, "COMMAND.COM");

    DeleteFileA(EXEC_OUT);
    wsprintfA(cl, "%s /c %s >%s", comspec, cmd, EXEC_OUT);

    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    /* MINIMIZED + NOT ACTIVATED. Never SW_HIDE: Win9x answers that by giving the
     * VDM the whole screen, which wedges the display driver -- see the header. */
    si.wShowWindow = SW_SHOWMINNOACTIVE;   /* windowed + never steals focus */
    ZeroMemory(&pi, sizeof(pi));

    if (!CreateProcessA(NULL, cl, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        logline("exec: CreateProcess failed");
        lstrcpyA(out, "warpnet: CreateProcess failed\r\n");
        *rc = 127;
        return lstrlenA(out);
    }
    if (WaitForSingleObject(pi.hProcess, EXEC_TIMEOUT_MS) == WAIT_TIMEOUT) {
        TerminateProcess(pi.hProcess, 124);
        WaitForSingleObject(pi.hProcess, 5000);
    }
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    *rc = (int)code;

    video_kick();   /* the VDM has exited: put the CRTC back -- see header note 2 */

    h = CreateFileA(EXEC_OUT, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                    NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        if (ReadFile(h, out, (DWORD)outmax, &got, NULL)) len = (int)got;
        CloseHandle(h);
    }
    return len;
}

/* Frame one 'E' reply back to the caller: O <b64>\n X <rc>\n .\n */
static void exec_reply(SOCKET c, const char *cmd) {
    static char out[EXEC_MAX];
    static char b64[((EXEC_MAX + 2) / 3) * 4 + 8];
    char hdr[48];
    int rc = 127;
    int n = run_exec(cmd, out, EXEC_MAX, &rc);
    if (n < 0) n = 0;
    b64enc((unsigned char *)out, n, b64);
    if (sendall(c, "O ", 2) != 0) return;
    if (sendall(c, b64, lstrlenA(b64)) != 0) return;
    wsprintfA(hdr, "\nX %d\n.\n", rc);
    sendall(c, hdr, lstrlenA(hdr));
}

/* True if the line is an 'E' exec request ("E " or "E\t"). */
static int is_exec(const char *s) {
    while (*s == ' ' || *s == '\t') s++;
    if (*s != 'E' && *s != 'e') return 0;
    return s[1] == ' ' || s[1] == '\t';
}

/* Return the command part of an 'E' line (skip blanks, the verb, then blanks). */
static const char *exec_arg(const char *s) {
    while (*s == ' ' || *s == '\t') s++;
    s++;                                        /* the E */
    while (*s == ' ' || *s == '\t') s++;
    return s;
}

/* True if the first non-blank char of a line is a bare move (M/m). */
static int is_move(const char *s) {
    while (*s == ' ' || *s == '\t') s++;
    return (*s == 'M' || *s == 'm');
}

/* LAYER 2 coalescing: Win95's Winsock1.1+PCnet drains slowly, so a single recv
 * chunk often carries dozens of queued moves. Replaying every M one-by-one makes
 * the cursor rubber-band across all the stale positions. Instead we hold only the
 * LAST pending M ("pend") and defer applying it: a non-move command flushes the
 * pending M first (so button/click order stays correct relative to the moves that
 * preceded it), then runs itself; at the end of each recv chunk we apply whatever
 * final M is still pending. Net: a chunk of 50 M's snaps once to the final point,
 * while any interleaved P/R/B/C still fire in the right order at the right spot. */
/* Options every accepted client socket gets. SO_KEEPALIVE is defence in depth
 * for the half-open peer described above: Win95's default keepalive is ~2 h, far
 * too slow to rescue a visitor, but it does stop an orphan surviving forever if
 * the daemon never reconnects. The listener takeover below is the real fix. */
static void setup_client(SOCKET c) {
    int one = 1;
    setsockopt(c, IPPROTO_TCP, TCP_NODELAY, (char*)&one, sizeof(one));
    setsockopt(c, SOL_SOCKET, SO_KEEPALIVE, (char*)&one, sizeof(one));
}

/* LISTENER TAKEOVER -- why serve() watches the listening socket too.
 *
 * This loop used to be strictly serial: accept() one client, recv() from it
 * until the peer closed, then accept() the next. That is a permanent pointer
 * outage waiting to happen, and on 2026-08-31 it happened on the live win95
 * station.
 *
 * The daemon (warpd.rs) reconnects on ANY write error -- a routine event. It
 * closes its socket and dials again. But the guest's Winsock never learns the
 * old peer is gone: no FIN or RST is delivered across the retronet tap when the
 * host end vanishes mid-flight, so recv() on the dead socket blocks forever.
 * Meanwhile the guest's TCP stack completes the daemon's NEW connection into
 * the listen backlog, where nothing ever accepts it. Every `M x y` the daemon
 * writes is absorbed by the receive buffer and read by nobody.
 *
 * The visible symptom is pointer MOTION dying alone: buttons and keys ride the
 * QEMU PS/2 path (SH_WARPD_BUTTONS=qemu) and the QMP keyboard, so they keep
 * working perfectly and the station looks half-alive. `netstat -an` in the guest
 * shows TWO ESTABLISHED sockets on :7777 while the host has only one -- that
 * asymmetry is the fingerprint.
 *
 * The fix: select() on the listener as well as the current client. The daemon is
 * the only client and holds at most one connection at a time (it drops the old
 * TcpStream before dialling), so a NEW inbound connection is proof that the
 * current peer is dead. Hand over -- close the old socket, serve the new one.
 * Last writer wins, and a wedge heals on the next reconnect instead of lasting
 * until someone reboots the guest. */
static void serve(SOCKET ls, SOCKET c) {
    char line[1200]; int ll = 0;        /* long enough for a real 'E' command line */
    char pend[256]; int havePend = 0;   /* latest deferred move, if any */
    char rb[512];
    for (;;) {
        fd_set rfd;
        struct timeval tv;
        int sel, n;
        FD_ZERO(&rfd);
        FD_SET(c, &rfd);
        FD_SET(ls, &rfd);
        tv.tv_sec = 30; tv.tv_usec = 0;
        sel = select(0, &rfd, NULL, NULL, &tv);
        if (sel == SOCKET_ERROR) break;
        if (sel == 0) continue;              /* idle window: nothing pending */
        if (FD_ISSET(ls, &rfd)) {
            SOCKET nc = accept(ls, NULL, NULL);
            if (nc != INVALID_SOCKET) {
                /* Flush anything the dying connection had deferred, then hand
                 * the session over. Line and move state belong to the old peer
                 * and must not leak into the new one. */
                if (havePend) { handle(pend); havePend = 0; }
                closesocket(c);
                c = nc;
                setup_client(c);
                ll = 0;
                logline("client taken over");
                continue;
            }
        }
        if (!FD_ISSET(c, &rfd)) continue;
        n = recv(c, rb, sizeof(rb), 0);
        if (n <= 0) break;
        {
        int i;
        for (i = 0; i < n; i++) {
            char ch = rb[i];
            if (ch == '\n' || ch == '\r') {
                if (ll > 0) {
                    line[ll] = 0; ll = 0;
                    if (line[0]=='Q'||line[0]=='q') {
                        if (havePend) { handle(pend); havePend = 0; }
                        closesocket(c); return;
                    }
                    if (is_exec(line)) {
                        /* Flush any deferred move first so the guest is in the
                         * state the caller expects, then run + reply inline. */
                        if (havePend) { handle(pend); havePend = 0; }
                        exec_reply(c, exec_arg(line));
                        continue;
                    }
                    if (is_move(line)) {
                        lstrcpynA(pend, line, sizeof(pend)); /* overwrite: keep only newest */
                        havePend = 1;
                    } else {
                        if (havePend) { handle(pend); havePend = 0; } /* flush move first */
                        handle(line);                                 /* then the command */
                    }
                }
            } else if (ll < (int)sizeof(line) - 1) {
                line[ll++] = ch;
            } else ll = 0;
        }
        }
        /* end of this recv chunk: collapse all its queued moves to the final one */
        if (havePend) { handle(pend); havePend = 0; }
    }
    closesocket(c);
}

int WINAPI WinMain(HINSTANCE hI, HINSTANCE hP, LPSTR cmd, int show) {
    (void)hI; (void)hP; (void)cmd; (void)show;
    logline("warpnet start");
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(1,1), &wsa) != 0) { logline("WSAStartup FAIL"); return 1; }
    logline("wsastartup ok");

    for (;;) {   /* re-create the listener if it ever fails (e.g. stack not up yet) */
        SOCKET ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (ls == INVALID_SOCKET) { Sleep(1000); continue; }
        int one = 1;
        setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, (char*)&one, sizeof(one));
        struct sockaddr_in sa;
        ZeroMemory(&sa, sizeof(sa));
        sa.sin_family = AF_INET;
        sa.sin_addr.s_addr = INADDR_ANY;
        sa.sin_port = htons(WARP_PORT);
        if (bind(ls, (struct sockaddr*)&sa, sizeof(sa)) != 0) { closesocket(ls); Sleep(1000); continue; }
        if (listen(ls, 4) != 0) { closesocket(ls); Sleep(1000); continue; }
        logline("listening 7777");
        for (;;) {
            SOCKET c = accept(ls, NULL, NULL);
            if (c == INVALID_SOCKET) break;   /* recreate listener */
            setup_client(c);
            logline("client connected");
            serve(ls, c);
            logline("client gone");
        }
        closesocket(ls);
        Sleep(500);
    }
}
