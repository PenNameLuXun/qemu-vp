/*
 * egl-x11-demo: minimal "EGL + X11 backend" example.
 *
 * Demonstrates how mesa's EGL X11 platform plugs into the existing X
 * server. The flow is:
 *
 *   1. XOpenDisplay()        — Xlib opens an X11 protocol socket to Xorg
 *   2. XCreateSimpleWindow() — X server allocates a window XID for us
 *   3. eglGetDisplay(Display *)        — mesa wraps the X Display as an EGLDisplay
 *   4. eglCreateWindowSurface(Window)  — mesa uses DRI3 to negotiate a
 *                                         dma-buf with the X server for
 *                                         this window
 *   5. glClear + eglSwapBuffers        — mesa renders into the dma-buf,
 *                                         then PresentPixmap-style ships
 *                                         it to the X server
 *
 * Rendering: GPU command stream → /dev/dri/renderDN (DRM render node).
 * Scanout:   X server holds DRM master on /dev/dri/card0 and composites.
 *
 * Build: `make`   (requires libx11-dev libegl1-mesa-dev libgles2-mesa-dev)
 * Run:   `DISPLAY=:0 ./egl-x11-demo`
 *
 * Press any key in the window to quit.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <X11/Xlib.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static void die(const char *msg)
{
    fprintf(stderr, "fatal: %s (egl error 0x%x)\n", msg, eglGetError());
    exit(1);
}

int main(void)
{
    /* === X11-specific: open Display, create a Window === */
    Display *xdisplay = XOpenDisplay(NULL);
    if (!xdisplay) {
        fprintf(stderr, "XOpenDisplay failed (DISPLAY=%s)\n",
                getenv("DISPLAY") ? getenv("DISPLAY") : "(unset)");
        return 1;
    }
    Window xroot = DefaultRootWindow(xdisplay);
    Window xwindow = XCreateSimpleWindow(xdisplay, xroot,
                                         0, 0, 800, 600, 0, 0, 0x202020);
    XStoreName(xdisplay, xwindow, "egl-x11-demo");
    XSelectInput(xdisplay, xwindow, ExposureMask | KeyPressMask);
    XMapWindow(xdisplay, xwindow);

    /* === EGL: hand the X Display + Window to mesa ===
     *
     * Modern code prefers eglGetPlatformDisplay(EGL_PLATFORM_X11_KHR,
     * xdisplay, NULL); the legacy form here is identical in effect when
     * mesa is built with X11 support.
     */
    EGLDisplay egldisplay = eglGetDisplay((EGLNativeDisplayType)xdisplay);
    if (egldisplay == EGL_NO_DISPLAY)
        die("eglGetDisplay");
    if (!eglInitialize(egldisplay, NULL, NULL))
        die("eglInitialize");
    eglBindAPI(EGL_OPENGL_ES_API);

    const EGLint cfg_attribs[] = {
        EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
        EGL_RED_SIZE,        8,
        EGL_GREEN_SIZE,      8,
        EGL_BLUE_SIZE,       8,
        EGL_ALPHA_SIZE,      8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_NONE,
    };
    EGLConfig config;
    EGLint num_configs = 0;
    if (!eglChooseConfig(egldisplay, cfg_attribs, &config, 1, &num_configs)
        || num_configs == 0)
        die("eglChooseConfig");

    /* eglCreateWindowSurface: this is the magic line — mesa now knows
     * "render output goes back to this X11 Window".
     */
    EGLSurface eglsurface = eglCreateWindowSurface(
        egldisplay, config, (EGLNativeWindowType)xwindow, NULL);
    if (eglsurface == EGL_NO_SURFACE)
        die("eglCreateWindowSurface");

    const EGLint ctx_attribs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext eglcontext = eglCreateContext(egldisplay, config,
                                             EGL_NO_CONTEXT, ctx_attribs);
    if (eglcontext == EGL_NO_CONTEXT)
        die("eglCreateContext");
    if (!eglMakeCurrent(egldisplay, eglsurface, eglsurface, eglcontext))
        die("eglMakeCurrent");

    printf("egl-x11-demo: rendering. press any key in the window to quit.\n");

    /* === backend-neutral render loop === */
    int running = 1;
    float t = 0.0f;
    while (running) {
        while (XPending(xdisplay)) {
            XEvent ev;
            XNextEvent(xdisplay, &ev);
            if (ev.type == KeyPress)
                running = 0;
        }
        t += 0.02f;
        glClearColor(0.5f * (1.0f + sinf(t)),
                     0.5f,
                     0.5f * (1.0f + cosf(t)),
                     1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        eglSwapBuffers(egldisplay, eglsurface);
    }

    eglMakeCurrent(egldisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(egldisplay, eglcontext);
    eglDestroySurface(egldisplay, eglsurface);
    eglTerminate(egldisplay);
    XDestroyWindow(xdisplay, xwindow);
    XCloseDisplay(xdisplay);
    return 0;
}
