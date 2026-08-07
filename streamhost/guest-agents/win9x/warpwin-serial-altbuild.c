/* warpwin.c - in-guest absolute-cursor agent for Windows 95 / 98 SE.
 *
 * KEPT FOR REFERENCE (serial-transport variant, never deployed): live win95 runs
 * SH_POINTER=warpd via warpnet.c over a TCP hostfwd, and live win98se runs
 * SH_POINTER=abs via usb-tablet under acpi=on — neither uses this file.
 * Original rationale: the win95 tile runs QEMU with usb=off and a PS/2 *relative*
 * mouse, so the QEMU absolute tablet is unavailable. This agent runs INSIDE the guest and
 * positions the Win32 system cursor directly with SetCursorPos(x,y) -- true
 * full-screen absolute positioning, immune to the relative-mouse limitation, the
 * Win9x analogue of the Solaris warpd XTEST/XWarpPointer agent.
 *
 * Transport: reads newline-delimited ASCII commands from a serial port (COM1 by
 * default; QEMU -serial chardev socket). Serial needs zero guest TCP/IP config and
 * COM1 (16550 @ 0x3F8 IRQ4) always exists on a PC, so this is the simplest, most
 * robust legacy transport. Pass an arg "COM2" etc. to change the port.
 *
 * Protocol (guest pixels, 0..width / 0..height), identical to warpd.py:
 *   M x y        move cursor to (x,y)
 *   P n x y      move to (x,y) then PRESS button n   (1=L 2=M 3=R)
 *   R n x y      move to (x,y) then RELEASE button n
 *   B n x y      move to (x,y) then CLICK button n; n=4 wheel up, n=5 wheel down
 *   C x y        move to (x,y) then left click
 *   QUIT         exit
 *
 * Build (on the host, Debian):
 *   i686-w64-mingw32-gcc -O2 -s -mwindows -o warpwin.exe warpwin.c
 * -mwindows => GUI subsystem, so NO console/DOS box pops up in the guest.
 */

#include <windows.h>

/* mouse_event flags (present in mingw winuser.h, redefined here for clarity). */
#ifndef MOUSEEVENTF_WHEEL
#define MOUSEEVENTF_WHEEL 0x0800
#endif
#ifndef WHEEL_DELTA
#define WHEEL_DELTA 120
#endif

static void logline(const char *s) {
    /* Tiny append-only breadcrumb so we can confirm the agent launched and is
     * parsing commands, visible offline via qemu-nbd. Best-effort; ignore errors. */
    HANDLE h = CreateFileA("C:\\WARPWIN.LOG", GENERIC_WRITE, FILE_SHARE_READ, NULL,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    SetFilePointer(h, 0, NULL, FILE_END);
    DWORD w;
    WriteFile(h, s, lstrlenA(s), &w, NULL);
    WriteFile(h, "\r\n", 2, &w, NULL);
    CloseHandle(h);
}

static void press(int n)   { /* button down */
    if (n == 1)      mouse_event(MOUSEEVENTF_LEFTDOWN,   0, 0, 0, 0);
    else if (n == 2) mouse_event(MOUSEEVENTF_MIDDLEDOWN, 0, 0, 0, 0);
    else if (n == 3) mouse_event(MOUSEEVENTF_RIGHTDOWN,  0, 0, 0, 0);
}
static void release(int n) { /* button up */
    if (n == 1)      mouse_event(MOUSEEVENTF_LEFTUP,   0, 0, 0, 0);
    else if (n == 2) mouse_event(MOUSEEVENTF_MIDDLEUP, 0, 0, 0, 0);
    else if (n == 3) mouse_event(MOUSEEVENTF_RIGHTUP,  0, 0, 0, 0);
}
static void wheel(int dir) { /* dir>0 up, dir<0 down */
    mouse_event(MOUSEEVENTF_WHEEL, 0, 0, (DWORD)(dir > 0 ? WHEEL_DELTA : -WHEEL_DELTA), 0);
}
static void click(int n) {
    if (n == 4) { wheel(+1); return; }
    if (n == 5) { wheel(-1); return; }
    press(n); Sleep(15); release(n);
}

/* Parse and apply one command line immediately (minimal latency). */
static void handle(char *line) {
    char c = 0; int a = 0, b = 0, d = 0;
    /* first non-space char is the opcode */
    char *p = line;
    while (*p == ' ' || *p == '\t') p++;
    c = *p;
    if (c == 0) return;
    if (c == 'Q' || c == 'q') { logline("QUIT"); ExitProcess(0); }
    /* parse up to three integers after the opcode using wsprintf's cousin sscanf-like
     * hand parse (no CRT sscanf dependency issues on Win9x). */
    int nums[3] = {0,0,0}; int ni = 0; int sign = 1; int have = 0; long val = 0;
    for (p = p + 1; ; p++) {
        char ch = *p;
        if (ch == '-') { sign = -1; have = 1; }
        else if (ch >= '0' && ch <= '9') { val = val*10 + (ch - '0'); have = 1; }
        else {
            if (have && ni < 3) { nums[ni++] = (int)(val*sign); }
            val = 0; sign = 1; have = 0;
            if (ch == 0) break;
        }
    }
    switch (c) {
        case 'M': case 'm':
            if (ni >= 2) SetCursorPos(nums[0], nums[1]);
            break;
        case 'C': case 'c':
            if (ni >= 2) { SetCursorPos(nums[0], nums[1]); click(1); }
            break;
        case 'P': case 'p':
            if (ni >= 3) { SetCursorPos(nums[1], nums[2]); press(nums[0]); }
            break;
        case 'R': case 'r':
            if (ni >= 3) { SetCursorPos(nums[1], nums[2]); release(nums[0]); }
            break;
        case 'B': case 'b':
            if (ni >= 3) { SetCursorPos(nums[1], nums[2]); click(nums[0]); }
            break;
        default: break;
    }
}

int WINAPI WinMain(HINSTANCE hI, HINSTANCE hP, LPSTR cmd, int show) {
    (void)hI; (void)hP; (void)show;
    const char *port = "COM1";
    if (cmd && cmd[0]) {
        /* allow "COM2" as first token */
        if ((cmd[0]=='C'||cmd[0]=='c') && (cmd[1]=='O'||cmd[1]=='o')) port = cmd;
    }
    logline("warpwin start");

    HANDLE h;
    for (;;) {
        h = CreateFileA(port, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                        OPEN_EXISTING, 0, NULL);
        if (h != INVALID_HANDLE_VALUE) break;
        Sleep(500);
    }
    logline("port open");

    /* 115200 8N1. For a socket-backed QEMU chardev the baud is cosmetic (bytes flow
     * over the unix socket regardless), but set a sane line anyway. */
    DCB dcb; ZeroMemory(&dcb, sizeof(dcb)); dcb.DCBlength = sizeof(dcb);
    if (GetCommState(h, &dcb)) {
        dcb.BaudRate = CBR_115200;
        dcb.ByteSize = 8; dcb.Parity = NOPARITY; dcb.StopBits = ONESTOPBIT;
        dcb.fBinary = TRUE; dcb.fParity = FALSE;
        dcb.fOutxCtsFlow = FALSE; dcb.fOutxDsrFlow = FALSE;
        dcb.fDtrControl = DTR_CONTROL_ENABLE; dcb.fRtsControl = RTS_CONTROL_ENABLE;
        dcb.fInX = FALSE; dcb.fOutX = FALSE;
        SetCommState(h, &dcb);
    }
    /* Responsive reads: return as soon as any byte is available, so each command is
     * applied immediately with no polling delay. */
    COMMTIMEOUTS to; ZeroMemory(&to, sizeof(to));
    to.ReadIntervalTimeout = MAXDWORD;         /* return immediately with whatever is there */
    to.ReadTotalTimeoutConstant = 0;
    to.ReadTotalTimeoutMultiplier = 0;
    SetCommTimeouts(h, &to);
    SetupComm(h, 4096, 4096);
    PurgeComm(h, PURGE_RXCLEAR | PURGE_TXCLEAR);

    char line[256]; int ll = 0;
    char rb[512];
    for (;;) {
        DWORD n = 0;
        if (!ReadFile(h, rb, sizeof(rb), &n, NULL)) {
            /* port error: try to reopen */
            CloseHandle(h);
            do { h = CreateFileA(port, GENERIC_READ|GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL); Sleep(200);} while (h==INVALID_HANDLE_VALUE);
            SetCommTimeouts(h, &to);
            continue;
        }
        if (n == 0) { Sleep(1); continue; } /* nothing yet; yield briefly */
        DWORD i;
        for (i = 0; i < n; i++) {
            char ch = rb[i];
            if (ch == '\n' || ch == '\r') {
                if (ll > 0) { line[ll] = 0; handle(line); ll = 0; }
            } else if (ll < (int)sizeof(line) - 1) {
                line[ll++] = ch;
            } else {
                ll = 0; /* overflow guard */
            }
        }
    }
    /* not reached */
}
