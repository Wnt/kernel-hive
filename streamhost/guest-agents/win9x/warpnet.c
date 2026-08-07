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
 *   QUIT       close this connection
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

#define WARP_PORT 7777

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
        default: break;
    }
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
static void serve(SOCKET c) {
    char line[256]; int ll = 0;
    char pend[256]; int havePend = 0;   /* latest deferred move, if any */
    char rb[512];
    for (;;) {
        int n = recv(c, rb, sizeof(rb), 0);
        if (n <= 0) break;
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
            int nd = 1; setsockopt(c, IPPROTO_TCP, TCP_NODELAY, (char*)&nd, sizeof(nd));
            logline("client connected");
            serve(c);
            logline("client gone");
        }
        closesocket(ls);
        Sleep(500);
    }
}
