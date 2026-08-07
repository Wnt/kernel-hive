/*
 * Full-screen X11 pointer probe for graphical bridge kiosks.
 *
 * The guest cursor is deliberately hidden.  Instead, this client paints a
 * bright green 3x3 marker centred on the X pointer plus a magenta crosshair.
 * A host-side screendump can therefore recover the landing coordinate from the
 * framebuffer itself, without trusting X logs or xdotool output.
 *
 * Build in the bridge overlay:
 *   cc -O2 -Wall -Wextra -o /usr/local/bin/graphical-bridge-pointer-probe \
 *      graphical-bridge-pointer-probe.c -lX11
 */
#include <X11/Xlib.h>

#include <stdio.h>
#include <stdlib.h>

static Display *display;
static Window window;
static GC green_gc;
static GC magenta_gc;
static int pointer_x;
static int pointer_y;

static void draw_marker(void)
{
    XClearWindow(display, window);
    XDrawLine(display, window, magenta_gc, pointer_x - 12, pointer_y,
              pointer_x + 12, pointer_y);
    XDrawLine(display, window, magenta_gc, pointer_x, pointer_y - 12,
              pointer_x, pointer_y + 12);
    XFillRectangle(display, window, green_gc, pointer_x - 1, pointer_y - 1, 3,
                   3);
    XFlush(display);
}

static Cursor invisible_cursor(void)
{
    static const char empty[] = {0};
    XColor black = {0};
    Pixmap bitmap = XCreateBitmapFromData(display, window, empty, 1, 1);
    Cursor cursor = XCreatePixmapCursor(display, bitmap, bitmap, &black, &black,
                                        0, 0);

    XFreePixmap(display, bitmap);
    return cursor;
}

int main(void)
{
    XEvent event;
    Window root;
    Window child;
    int root_x;
    int root_y;
    int win_x;
    int win_y;
    unsigned int mask;
    int screen;
    int width;
    int height;
    XSetWindowAttributes attrs;
    XGCValues gc_values;
    Cursor cursor;

    display = XOpenDisplay(NULL);
    if (display == NULL) {
        fputs("graphical-bridge-pointer-probe: cannot open DISPLAY\n", stderr);
        return EXIT_FAILURE;
    }

    screen = DefaultScreen(display);
    root = RootWindow(display, screen);
    width = DisplayWidth(display, screen);
    height = DisplayHeight(display, screen);
    attrs.override_redirect = True;
    attrs.background_pixel = BlackPixel(display, screen);
    attrs.event_mask = ExposureMask | PointerMotionMask | StructureNotifyMask;
    window = XCreateWindow(display, root, 0, 0, (unsigned int)width,
                           (unsigned int)height, 0, CopyFromParent, InputOutput,
                           CopyFromParent,
                           CWOverrideRedirect | CWBackPixel | CWEventMask,
                           &attrs);
    XStoreName(display, window, "graphical-bridge-pointer-probe");

    cursor = invisible_cursor();
    XDefineCursor(display, window, cursor);

    gc_values.foreground = 0x00ff00;
    green_gc = XCreateGC(display, window, GCForeground, &gc_values);
    gc_values.foreground = 0xff00ff;
    magenta_gc = XCreateGC(display, window, GCForeground, &gc_values);

    pointer_x = width / 2;
    pointer_y = height / 2;
    if (XQueryPointer(display, root, &root, &child, &root_x, &root_y, &win_x,
                      &win_y, &mask)) {
        pointer_x = root_x;
        pointer_y = root_y;
    }

    XMapRaised(display, window);
    XSetInputFocus(display, window, RevertToPointerRoot, CurrentTime);
    draw_marker();

    for (;;) {
        XNextEvent(display, &event);
        switch (event.type) {
        case MotionNotify:
            pointer_x = event.xmotion.x;
            pointer_y = event.xmotion.y;
            while (XCheckTypedWindowEvent(display, window, MotionNotify,
                                          &event)) {
                pointer_x = event.xmotion.x;
                pointer_y = event.xmotion.y;
            }
            draw_marker();
            break;
        case Expose:
            if (event.xexpose.count == 0)
                draw_marker();
            break;
        default:
            break;
        }
    }
}
