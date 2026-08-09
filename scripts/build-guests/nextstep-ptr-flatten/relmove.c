/* relmove — precise relative pointer injection into the kiosk X server.
 * Reads "dx dy delay_us" lines on stdin; emits one XTest relative motion each,
 * flushes, and sleeps delay_us before the next. Prints the X pointer position
 * after the whole batch so the commanded total can be checked against X. */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>

int main(void) {
	Display *d = XOpenDisplay(NULL);
	if (!d) { fprintf(stderr, "no display\n"); return 1; }
	char line[128];
	int dx, dy; long us;
	while (fgets(line, sizeof line, stdin)) {
		if (sscanf(line, "%d %d %ld", &dx, &dy, &us) != 3) continue;
		XTestFakeRelativeMotionEvent(d, dx, dy, 0);
		XFlush(d);
		if (us > 0) {
			struct timespec ts = { us / 1000000L, (us % 1000000L) * 1000L };
			nanosleep(&ts, NULL);
		}
	}
	Window root, child; int rx, ry, wx, wy; unsigned int mask;
	XQueryPointer(d, DefaultRootWindow(d), &root, &child, &rx, &ry, &wx, &wy, &mask);
	printf("xptr %d %d\n", rx, ry);
	XCloseDisplay(d);
	return 0;
}
