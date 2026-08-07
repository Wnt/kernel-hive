/* agent.c -- Win16 in-guest pointer agent for Windows 3.11.
 * Reads the newline-ASCII M/P/R/B protocol from COM1 and drives the native
 * absolute cursor API (SetCursorPos) + mouse_event for button injection.
 *
 * Protocol (guest pixels, screen 0..W / 0..H):
 *   M x y       move cursor to (x,y)
 *   P n x y     move to (x,y) then press button n   (1=L 2=M 3=R)
 *   R n x y     move to (x,y) then release button n
 *   B n x y     move to (x,y) then click button n    (n 4/5 = wheel: ignored)
 *
 * Build (OpenWatcom 1.9, Win16; -bcl=windows implies -bt=windows):
 *   wcl -bcl=windows -mc -fe=AGENT.EXE agent.c
 */
#include <windows.h>
#include <string.h>
#include <stdlib.h>

/* mouse_event lives in USER.EXE / windows.lib but is not declared by the
 * OpenWatcom Win16 headers, so declare it here. */
void WINAPI mouse_event( UINT, UINT, UINT, UINT, DWORD );

#define MEF_MOVE       0x0001
#define MEF_LEFTDOWN   0x0002
#define MEF_LEFTUP     0x0004
#define MEF_RIGHTDOWN  0x0008
#define MEF_RIGHTUP    0x0010
#define MEF_MIDDLEDOWN 0x0020
#define MEF_MIDDLEUP   0x0040
#define MEF_ABSOLUTE   0x8000

static int   gCom = -1;          /* comm device id */
static char  gLine[256];         /* current line accumulator */
static int   gLen = 0;
static int   gScrW = 640;        /* screen size (queried at startup) */
static int   gScrH = 480;

static void down_flag( int btn, UINT *dn, UINT *up )
{
    switch( btn ) {
    case 2: *dn = MEF_MIDDLEDOWN; *up = MEF_MIDDLEUP; break;
    case 3: *dn = MEF_RIGHTDOWN;  *up = MEF_RIGHTUP;  break;
    default:*dn = MEF_LEFTDOWN;   *up = MEF_LEFTUP;   break;
    }
}

/* Inject a button event carrying an ABSOLUTE position (0..65535 mapped to the
 * screen). NOTE: under QEMU + Win 3.11 386-enhanced mode (mouse=*vmd),
 * mouse_event was observed to be a no-op, so this is kept only as a supplement
 * for foreground-window fidelity; the primary click path is post_btn() below. */
static void btn_at( UINT flag, int x, int y )
{
    UINT ax, ay;
    if( x < 0 ) x = 0; if( x >= gScrW ) x = gScrW - 1;
    if( y < 0 ) y = 0; if( y >= gScrH ) y = gScrH - 1;
    ax = (UINT)( (long)x * 65535L / (long)( gScrW - 1 ) );
    ay = (UINT)( (long)y * 65535L / (long)( gScrH - 1 ) );
    mouse_event( MEF_MOVE | MEF_ABSOLUTE | flag, ax, ay, 0, 0L );
}

/* Primary click path: SetCursorPos to move the visible cursor, then PostMessage
 * a WM_*BUTTON* directly to the window under the screen point (client coords).
 * Deterministic on this stack where mouse_event does not inject. isDown!=0 posts
 * the DOWN message, ==0 the UP, ==2 a double-click (DBLCLK + UP). */
static void post_btn( int btn, int isDown, int x, int y )
{
    POINT  pt;
    HWND   h;
    UINT   msg;
    WPARAM wp;

    SetCursorPos( x, y );
    pt.x = x; pt.y = y;
    h = WindowFromPoint( pt );
    if( h == NULL ) return;
    ScreenToClient( h, &pt );

    if( btn == 3 ) {
        msg = isDown ? WM_RBUTTONDOWN : WM_RBUTTONUP;
        wp  = isDown ? MK_RBUTTON : 0;
    } else if( btn == 2 ) {
        msg = isDown ? WM_MBUTTONDOWN : WM_MBUTTONUP;
        wp  = isDown ? MK_MBUTTON : 0;
    } else {
        wp  = isDown ? MK_LBUTTON : 0;
        if(      isDown == 2 ) msg = WM_LBUTTONDBLCLK;
        else if( isDown )      msg = WM_LBUTTONDOWN;
        else                   msg = WM_LBUTTONUP;
    }
    PostMessage( h, msg, wp, MAKELPARAM( pt.x, pt.y ) );
    /* also fire the supplemental hardware-level event (no-op on this stack) */
    if( isDown == 1 || isDown == 2 )
        btn_at( btn == 3 ? MEF_RIGHTDOWN : btn == 2 ? MEF_MIDDLEDOWN : MEF_LEFTDOWN, x, y );
    else
        btn_at( btn == 3 ? MEF_RIGHTUP : btn == 2 ? MEF_MIDDLEUP : MEF_LEFTUP, x, y );
}

static DWORD gLastClk = 0;
static int   gLastX = -99, gLastY = -99;

/* --- per-drain-batch move coalescing (mirror warpnet.c) ---------------------
 * The guest COM drain + Win3.x WM_COMMNOTIFY / message-loop overhead is the real
 * throughput ceiling (empirically ~11 KB/s on this QEMU stack; QEMU does NOT
 * throttle serial RX to the programmed 9600 divisor, so raising the baud does
 * nothing -- see BuildCommDCB note in WinMain). A burst of daemon-paced 'M'
 * lines therefore queues up faster than SetCursorPos can replay it, and the
 * cursor rubber-bands through every stale position. Fix: within one drain pass
 * PEND the newest 'M' and apply only that final position once the buffer is
 * fully drained. A non-move line (P/R/B) first flushes the pending move so
 * ordering and the click position stay correct. */
static int  gPendMove = 0;
static int  gPendX = 0, gPendY = 0;

static void flush_move( void )
{
    if( gPendMove ) { SetCursorPos( gPendX, gPendY ); gPendMove = 0; }
}

/* Apply one complete protocol line. */
static void apply( char *s )
{
    char  cmd;
    int   a[4];
    int   nf = 0;
    char *p = s;
    UINT  dn, up;

    while( *p == ' ' || *p == '\t' ) p++;
    if( *p == 0 ) return;
    cmd = *p++;
    /* parse up to 4 integers */
    while( nf < 4 ) {
        while( *p == ' ' || *p == '\t' ) p++;
        if( *p == 0 || (*p != '-' && (*p < '0' || *p > '9')) ) break;
        a[nf++] = (int)strtol( p, &p, 10 );
    }

    switch( cmd ) {
    case 'M':                                   /* M x y : coalesced (pend newest) */
        if( nf >= 2 ) { gPendX = a[0]; gPendY = a[1]; gPendMove = 1; }
        break;
    case 'P':                                   /* P n x y */
        flush_move();
        if( nf >= 3 ) post_btn( a[0], 1, a[1], a[2] );
        break;
    case 'R':                                   /* R n x y */
        flush_move();
        if( nf >= 3 ) post_btn( a[0], 0, a[1], a[2] );
        break;
    case 'B':                                   /* B n x y : click (+dblclick) */
        flush_move();
        if( nf >= 3 ) {
            DWORD now;
            int   dbl;
            if( a[0] == 4 || a[0] == 5 ) break;  /* wheel: no Win16 support */
            now = GetTickCount();
            dbl = ( a[0] == 1 ) && ( now - gLastClk < 500 )
                  && ( a[1] - gLastX < 4 ) && ( gLastX - a[1] < 4 )
                  && ( a[2] - gLastY < 4 ) && ( gLastY - a[2] < 4 );
            if( dbl ) {
                post_btn( a[0], 2, a[1], a[2] );  /* WM_LBUTTONDBLCLK */
                post_btn( a[0], 0, a[1], a[2] );
            } else {
                post_btn( a[0], 1, a[1], a[2] );
                post_btn( a[0], 0, a[1], a[2] );
            }
            gLastClk = now; gLastX = a[1]; gLastY = a[2];
        }
        break;
    default:
        break;
    }
}

/* Drain whatever bytes are waiting on COM1 and dispatch complete lines. */
static void drain( void )
{
    char buf[256];
    int  n, i;
    char c;

    if( gCom < 0 ) return;
    while( (n = ReadComm( gCom, buf, sizeof(buf) )) != 0 ) {
        if( n < 0 ) n = -n;                      /* error: |n| bytes still valid */
        for( i = 0; i < n; i++ ) {
            c = buf[i];
            if( c == '\n' || c == '\r' ) {
                if( gLen > 0 ) { gLine[gLen] = 0; apply( gLine ); gLen = 0; }
            } else if( gLen < (int)sizeof(gLine) - 1 ) {
                gLine[gLen++] = c;
            }
        }
        if( n < (int)sizeof(buf) ) break;        /* fully drained */
    }
    flush_move();       /* apply only the newest pended position for this batch */
}

long FAR PASCAL _export WndProc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    switch( msg ) {
    case WM_COMMNOTIFY:                          /* data arrived: immediate */
        drain();
        return 0;
    case WM_TIMER:                               /* fallback poll ~55ms */
        drain();
        return 0;
    case WM_DESTROY:
        PostQuitMessage( 0 );
        return 0;
    }
    return DefWindowProc( hwnd, msg, wp, lp );
}

int PASCAL WinMain( HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmdln, int show )
{
    WNDCLASS wc;
    HWND     hwnd;
    MSG      msg;
    DCB      dcb;

    if( !hPrev ) {
        wc.style         = 0;
        wc.lpfnWndProc   = WndProc;
        wc.cbClsExtra    = 0;
        wc.cbWndExtra    = 0;
        wc.hInstance     = hInst;
        wc.hIcon         = LoadIcon( NULL, IDI_APPLICATION );
        wc.hCursor       = LoadCursor( NULL, IDC_ARROW );
        wc.hbrBackground = (HBRUSH)( COLOR_WINDOW + 1 );
        wc.lpszMenuName  = NULL;
        wc.lpszClassName = "WarpdAgent";
        RegisterClass( &wc );
    }

    /* tiny, out-of-the-way window to own the message queue */
    hwnd = CreateWindow( "WarpdAgent", "warpd-agent",
                         WS_POPUP, 0, 0, 1, 1,
                         NULL, NULL, hInst, NULL );

    gScrW = GetSystemMetrics( SM_CXSCREEN );
    gScrH = GetSystemMetrics( SM_CYSCREEN );
    if( gScrW <= 0 ) gScrW = 640;
    if( gScrH <= 0 ) gScrH = 480;

    gCom = OpenComm( "COM1", 2048, 128 );
    if( gCom >= 0 ) {
        /* 9600,n,8,1. NOTE: raising this is pointless on the QEMU stack -- the
         * emulated 16550 does NOT rate-limit host->guest RX to the programmed
         * divisor (measured ~11 KB/s sustained vs the 960 B/s that 9600 would
         * imply, i.e. ~11x over). The ceiling is guest CPU (drain + SetCursorPos
         * + message loop), not baud, so the fix is move-coalescing above. */
        BuildCommDCB( "COM1:9600,n,8,1", &dcb );
        dcb.Id = (BYTE)gCom;
        SetCommState( &dcb );
        /* notify on every received byte for minimal input latency */
        EnableCommNotification( gCom, hwnd, 1, -1 );
    } else {
        MessageBeep( 0 );
    }

    SetTimer( hwnd, 1, 55, NULL );               /* fallback drain */
    drain();

    while( GetMessage( &msg, NULL, 0, 0 ) ) {
        TranslateMessage( &msg );
        DispatchMessage( &msg );
    }

    if( gCom >= 0 ) CloseComm( gCom );
    KillTimer( hwnd, 1 );
    return msg.wParam;
}
