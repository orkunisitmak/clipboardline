// X11 generation/focus metadata only. Clipboard payloads stay in Electron.
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/extensions/Xfixes.h>
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <unistd.h>

static int ignore_error(Display *display, XErrorEvent *error) {
    (void)display; (void)error; return 0; // Closed foreign windows are ordinary failures.
}
static unsigned long property(Display *d, Window w, const char *name, Atom wanted) {
    Atom type; int format; unsigned long count, remaining, value = 0; unsigned char *bytes = NULL;
    if (XGetWindowProperty(d, w, XInternAtom(d, name, False), 0, 1, False, wanted,
                           &type, &format, &count, &remaining, &bytes) == Success &&
        type == wanted && format == 32 && count == 1 && bytes) value = *(unsigned long *)bytes;
    if (bytes) XFree(bytes);
    return value;
}
static Window active(Display *d) { return property(d, DefaultRootWindow(d), "_NET_ACTIVE_WINDOW", XA_WINDOW); }
static unsigned long pid(Display *d, Window w) { return w ? property(d, w, "_NET_WM_PID", XA_CARDINAL) : 0; }
static void events(Display *d, int base, uint32_t *generation, int announce) {
    XSync(d, False);
    while (XPending(d)) {
        XEvent e; XNextEvent(d, &e);
        if (e.type == base + XFixesSelectionNotify) {
            if (++*generation == 0) *generation = 1;
            if (announce) printf("{\"sequence\":%" PRIu32 "}\n", *generation);
        }
    }
    fflush(stdout);
}
int main(int argc, char **argv) {
    Display *d = XOpenDisplay(NULL);
    if (!d) { fputs("X11 display is unavailable.\n", stderr); return 1; }
    XSetErrorHandler(ignore_error);
    if (argc == 2 && !strcmp(argv[1], "capture")) {
        Window w = active(d); unsigned long p = pid(d, w);
        // A window identity does not establish an editable, non-password field.
        if (w && p) printf("{\"handle\":\"%lu\",\"processId\":%lu,\"runtime\":\"\",\"editable\":false,\"secure\":false}\n", w, p);
        else puts("null");
        XCloseDisplay(d); return 0;
    }
    if (argc == 5 && !strcmp(argv[1], "restore")) {
        char *end; Window w = strtoul(argv[2], &end, 10); if (*end || !w) return 1;
        unsigned long target = strtoul(argv[3], &end, 10); if (*end || !target) return 1;
        unsigned long source = strtoul(argv[4], &end, 10); if (*end || !source) return 1;
        Window current = active(d); unsigned long foreground = pid(d, current);
        if (pid(d, w) != target || (current && foreground != source && foreground != target)) { XCloseDisplay(d); return 1; }
        XEvent event = {0}; event.xclient.type = ClientMessage; event.xclient.window = w;
        event.xclient.message_type = XInternAtom(d, "_NET_ACTIVE_WINDOW", False);
        event.xclient.format = 32; event.xclient.data.l[0] = 1; // Normal application request; WM owns activation policy.
        event.xclient.data.l[1] = CurrentTime;
        XSendEvent(d, DefaultRootWindow(d), False, SubstructureRedirectMask | SubstructureNotifyMask, &event);
        XSync(d, False); XCloseDisplay(d); return 0;
    }
    if (argc != 1) { XCloseDisplay(d); return 1; }
    int base, error;
    if (!XFixesQueryExtension(d, &base, &error)) { XCloseDisplay(d); return 1; }
    Window w = XCreateSimpleWindow(d, DefaultRootWindow(d), 0, 0, 1, 1, 0, 0, 0);
    XFixesSelectSelectionInput(d, w, XInternAtom(d, "CLIPBOARD", False),
        XFixesSetSelectionOwnerNotifyMask | XFixesSelectionWindowDestroyNotifyMask | XFixesSelectionClientCloseNotifyMask);
    XSync(d, False);
    uint32_t generation = 1; char input[128]; size_t used = 0;
    for (;;) {
        events(d, base, &generation, 1);
        fd_set readfds; FD_ZERO(&readfds); FD_SET(STDIN_FILENO, &readfds); FD_SET(ConnectionNumber(d), &readfds);
        int result = select(ConnectionNumber(d) + 1, &readfds, NULL, NULL, NULL);
        if (result < 0) { if (errno == EINTR) continue; break; }
        if (FD_ISSET(STDIN_FILENO, &readfds)) {
            char c; if (read(STDIN_FILENO, &c, 1) != 1) break;
            if (c == '\n') {
                input[used] = '\0'; unsigned int id; char extra;
                if (sscanf(input, "clipboard-sequence:%u%c", &id, &extra) != 1 || !id) break;
                // Round-trip before answering so queued ownership changes precede the reply.
                events(d, base, &generation, 1);
                printf("{\"clipboardQuery\":%u,\"sequence\":%" PRIu32 "}\n", id, generation); fflush(stdout); used = 0;
            } else if (used < sizeof(input) - 1) input[used++] = c;
            else break;
        }
    }
    XDestroyWindow(d, w); XCloseDisplay(d); return 0;
}
