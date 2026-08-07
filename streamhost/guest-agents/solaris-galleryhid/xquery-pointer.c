#include <stdio.h>

/* Minimal Xlib ABI declarations: the Solaris end-user media has no headers. */
typedef struct _XDisplay Display;
typedef unsigned long Window;
extern Display *XOpenDisplay(const char *);
extern int XDefaultScreen(Display *);
extern Window XRootWindow(Display *, int);
extern int XQueryPointer(Display *, Window, Window *, Window *, int *, int *,
    int *, int *, unsigned int *);
extern int XCloseDisplay(Display *);

int
main(void)
{
        Display *display;
        Window root;
        Window root_return;
        Window child_return;
        int root_x;
        int root_y;
        int win_x;
        int win_y;
        unsigned int mask;

        display = XOpenDisplay(NULL);
        if (display == NULL) {
                (void)fprintf(stderr, "cannot open DISPLAY\n");
                return (1);
        }
        root = XRootWindow(display, XDefaultScreen(display));
        if (!XQueryPointer(display, root, &root_return, &child_return,
            &root_x, &root_y, &win_x, &win_y, &mask)) {
                (void)fprintf(stderr, "XQueryPointer failed\n");
                (void)XCloseDisplay(display);
                return (2);
        }
        (void)printf("root_x=%d root_y=%d mask=0x%x\n",
            root_x, root_y, mask);
        (void)XCloseDisplay(display);
        return (0);
}
