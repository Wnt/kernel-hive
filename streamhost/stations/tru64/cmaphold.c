/*
 * cmaphold.c - retronet tru64 ICQ station: colormap chrome anchor.
 *
 * The es40 CDE desktop is an 8-bit PseudoColor display (one 256-cell hardware
 * colormap). Gaim (GTK+1.2) leaks roughly a full widget style's worth of
 * colormap cells on every wake reconnect (buddy-list destroy/recreate + SSI
 * re-sync); after ~8 cycles the shared map is exhausted and GTK can no longer
 * allocate its neutral widget-background grey, so the window chrome (menubars,
 * toolbars, tab rows) renders BLACK while the white text areas stay correct.
 *
 * Pinning the colours in ~/.gtkrc is NOT enough on its own: when the map is
 * full the allocation of the (correct) grey still fails and falls back to the
 * black pixel. This tiny client fixes that at the root of the X colour model:
 * it pre-allocates the exact colours Gaim needs -- read-only, SHARED -- and
 * then never exits, so those cells stay allocated for the whole session.
 * XAllocColor of an already-allocated shareable colour returns the existing
 * pixel WITHOUT consuming a free cell, so every later Gaim (re)allocation of
 * the same rgb succeeds even when the colormap is otherwise exhausted -- the
 * chrome can never fall back to black again.
 *
 * The grey set matches the values pinned in ~/.gtkrc (bg NORMAL/ACTIVE/
 * PRELIGHT) plus the light/dark/mid shadow shades GTK+1.2 derives from each bg
 * (LIGHTNESS_MULT 1.3 / DARKNESS_MULT 0.7; for a grey the HLS shade reduces to
 * a per-channel scale, so these values are bit-exact with what Gaim computes).
 * A handful of chat/smiley primaries are held too so they survive the same
 * exhaustion.
 *
 * Build (on the guest, native Compaq C):  cc -o cmaphold cmaphold.c -lX11
 * Run   (in the CDE session, before Gaim): DISPLAY=:0 cmaphold &
 */
#include <X11/Xlib.h>
#include <stdio.h>
#include <unistd.h>

static Display *d;
static Colormap cm;
static int held = 0, failed = 0;

static void hold16(unsigned r, unsigned g, unsigned b)
{
	XColor c;
	c.red = r; c.green = g; c.blue = b;
	c.flags = DoRed | DoGreen | DoBlue;
	if (XAllocColor(d, cm, &c))
		held++;
	else {
		failed++;
		fprintf(stderr, "cmaphold: alloc failed %04x%04x%04x\n", r, g, b);
	}
}

static unsigned litev(unsigned v) { double x = (double)v * 1.3; return x > 65535.0 ? 65535u : (unsigned)x; }
static unsigned drkv(unsigned v)  { return (unsigned)((double)v * 0.7); }

/* bg + GTK-derived light/dark/mid for one grey base (16-bit per channel) */
static void hold_grey_set(unsigned v)
{
	unsigned l = litev(v), dk = drkv(v), mid = (l + dk) / 2;
	hold16(v, v, v);
	hold16(l, l, l);
	hold16(dk, dk, dk);
	hold16(mid, mid, mid);
}

int main(void)
{
	d = XOpenDisplay(":0");
	if (!d) {
		fprintf(stderr, "cmaphold: cannot open display :0\n");
		return 1;
	}
	cm = DefaultColormap(d, DefaultScreen(d));

	/* Gaim chrome greys (pinned in ~/.gtkrc) + their shadow shades */
	hold_grey_set(0xd7d7);	/* bg NORMAL / INSENSITIVE */
	hold_grey_set(0xc3c3);	/* bg ACTIVE               */
	hold_grey_set(0xdcdc);	/* bg PRELIGHT             */

	/* fixed neutrals */
	hold16(0xffff, 0xffff, 0xffff);	/* white text-area base */
	hold16(0x0000, 0x0000, 0x0000);	/* black text / fg      */
	hold16(0x7f7f, 0x7f7f, 0x7f7f);	/* insensitive fg grey  */

	/* chat + smiley primaries so message colours survive too */
	hold16(0xffff, 0x0000, 0x0000);	/* red  (sender nick / timestamp) */
	hold16(0x0000, 0x0000, 0xffff);	/* blue (own nick)                */
	hold16(0xffff, 0xffff, 0x0000);	/* yellow (smiley)                */
	hold16(0x0000, 0x0000, 0x8b8b);	/* selection dark blue            */

	XFlush(d);
	fprintf(stderr, "cmaphold: held=%d failed=%d pid=%d\n", held, failed, (int)getpid());

	for (;;)
		pause();	/* stay connected forever so the cells stay allocated */
	return 0;
}
