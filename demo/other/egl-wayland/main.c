/*
 * egl-wayland-demo: minimal "EGL + Wayland backend" example.
 *
 * Unlike X11 (where the X server draws or accepts pixmaps), Wayland
 * clients always render themselves and hand the compositor a dma-buf.
 * EGL on Wayland uses GBM under the hood for buffer allocation; the
 * `wl_egl_window` opaque type is mesa's bridge object that connects a
 * wl_surface to an EGLSurface.
 *
 * Flow:
 *   1. wl_display_connect()                — Wayland socket to compositor
 *   2. wl_registry / wl_compositor / xdg_wm_base  — bind protocol globals
 *   3. wl_compositor_create_surface()       — empty surface (no content yet)
 *   4. xdg_wm_base_get_xdg_surface()        — give it role/title/decorations
 *   5. wl_egl_window_create(wl_surface)     — mesa's "EGL native window"
 *                                              for this wl_surface
 *   6. eglGetDisplay(wl_display *)          — mesa wraps the wl_display
 *   7. eglCreateWindowSurface(wl_egl_window)— mesa allocs dma-buf, posts
 *                                              to compositor via wl_drm
 *                                              or linux-dmabuf
 *
 * Build needs `wayland-scanner` to generate xdg-shell client glue from
 * wayland-protocols' xdg-shell.xml; the Makefile does this automatically.
 *
 * Build: `make`   (libwayland-dev wayland-protocols libegl1-mesa-dev libgles2-mesa-dev)
 * Run:   `WAYLAND_DISPLAY=wayland-0 ./egl-wayland-demo`
 *
 * Close the window via the compositor's close button (or Ctrl-C).
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <wayland-client.h>
#include <wayland-egl.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include "xdg-shell-client-protocol.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static struct wl_compositor *g_compositor;
static struct xdg_wm_base   *g_wm_base;
static int g_running = 1;

/* --- xdg_wm_base ping/pong (keep-alive) --- */
static void wm_base_ping(void *data, struct xdg_wm_base *base, uint32_t serial)
{
    (void)data;
    xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_base_listener = {
    .ping = wm_base_ping,
};

/* --- wl_registry: bind compositor + xdg_wm_base globals --- */
static void registry_global(void *data, struct wl_registry *registry,
                            uint32_t name, const char *interface, uint32_t version)
{
    (void)data; (void)version;
    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        g_compositor = wl_registry_bind(registry, name,
                                        &wl_compositor_interface, 4);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        g_wm_base = wl_registry_bind(registry, name,
                                     &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(g_wm_base, &wm_base_listener, NULL);
    }
}
static void registry_global_remove(void *data, struct wl_registry *r, uint32_t name)
{ (void)data; (void)r; (void)name; }
static const struct wl_registry_listener registry_listener = {
    .global        = registry_global,
    .global_remove = registry_global_remove,
};

/* --- xdg_surface: must ack each configure --- */
static void xdg_surf_configure(void *data, struct xdg_surface *s, uint32_t serial)
{
    (void)data;
    xdg_surface_ack_configure(s, serial);
}
static const struct xdg_surface_listener xdg_surf_listener = {
    .configure = xdg_surf_configure,
};

/* --- xdg_toplevel: close = compositor asking us to quit --- */
static void toplevel_configure(void *data, struct xdg_toplevel *t,
                               int32_t w, int32_t h, struct wl_array *states)
{ (void)data; (void)t; (void)w; (void)h; (void)states; }
static void toplevel_close(void *data, struct xdg_toplevel *t)
{ (void)data; (void)t; g_running = 0; }
static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure,
    .close     = toplevel_close,
};

static void die(const char *msg)
{
    fprintf(stderr, "fatal: %s (egl error 0x%x)\n", msg, eglGetError());
    exit(1);
}

int main(void)
{
    /* === Wayland: connect + bind protocol globals === */
    struct wl_display *wldisplay = wl_display_connect(NULL);
    if (!wldisplay) {
        fprintf(stderr, "wl_display_connect failed (WAYLAND_DISPLAY=%s)\n",
                getenv("WAYLAND_DISPLAY") ? getenv("WAYLAND_DISPLAY") : "(unset)");
        return 1;
    }
    struct wl_registry *registry = wl_display_get_registry(wldisplay);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(wldisplay);

    if (!g_compositor || !g_wm_base) {
        fprintf(stderr, "compositor missing wl_compositor or xdg_wm_base\n");
        return 1;
    }

    /* === Surface + xdg roles (= "this is a top-level window") === */
    struct wl_surface  *wlsurface = wl_compositor_create_surface(g_compositor);
    struct xdg_surface *xdgsurf   = xdg_wm_base_get_xdg_surface(g_wm_base, wlsurface);
    xdg_surface_add_listener(xdgsurf, &xdg_surf_listener, NULL);
    struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xdgsurf);
    xdg_toplevel_add_listener(toplevel, &toplevel_listener, NULL);
    xdg_toplevel_set_title(toplevel, "egl-wayland-demo");
    xdg_toplevel_set_app_id(toplevel, "egl-wayland-demo");
    wl_surface_commit(wlsurface);
    wl_display_roundtrip(wldisplay);

    /* === wl_egl_window: mesa's "native window" type for Wayland ===
     *
     * Wayland's wl_surface has no inherent size/buffer; wl_egl_window
     * is a mesa-side object that pairs a wl_surface with a current
     * size so EGL can allocate buffers of the right dimensions.
     */
    struct wl_egl_window *eglwin = wl_egl_window_create(wlsurface, 800, 600);
    if (!eglwin)
        die("wl_egl_window_create");

    /* === EGL: bind to the wl_display === */
    EGLDisplay egldisplay = eglGetDisplay((EGLNativeDisplayType)wldisplay);
    if (egldisplay == EGL_NO_DISPLAY) die("eglGetDisplay");
    if (!eglInitialize(egldisplay, NULL, NULL)) die("eglInitialize");
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

    EGLSurface eglsurface = eglCreateWindowSurface(
        egldisplay, config, (EGLNativeWindowType)eglwin, NULL);
    if (eglsurface == EGL_NO_SURFACE) die("eglCreateWindowSurface");

    const EGLint ctx_attribs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext eglcontext = eglCreateContext(egldisplay, config,
                                             EGL_NO_CONTEXT, ctx_attribs);
    if (eglcontext == EGL_NO_CONTEXT) die("eglCreateContext");
    if (!eglMakeCurrent(egldisplay, eglsurface, eglsurface, eglcontext))
        die("eglMakeCurrent");

    printf("egl-wayland-demo: rendering. close the window or Ctrl-C to quit.\n");

    /* === backend-neutral render loop === */
    float t = 0.0f;
    while (g_running) {
        if (wl_display_dispatch_pending(wldisplay) == -1) break;
        t += 0.02f;
        glClearColor(0.5f * (1.0f + sinf(t)),
                     0.5f,
                     0.5f * (1.0f + cosf(t)),
                     1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        eglSwapBuffers(egldisplay, eglsurface);
        wl_display_flush(wldisplay);
    }

    eglMakeCurrent(egldisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(egldisplay, eglcontext);
    eglDestroySurface(egldisplay, eglsurface);
    eglTerminate(egldisplay);
    wl_egl_window_destroy(eglwin);
    xdg_toplevel_destroy(toplevel);
    xdg_surface_destroy(xdgsurf);
    wl_surface_destroy(wlsurface);
    xdg_wm_base_destroy(g_wm_base);
    wl_compositor_destroy(g_compositor);
    wl_registry_destroy(registry);
    wl_display_disconnect(wldisplay);
    return 0;
}
