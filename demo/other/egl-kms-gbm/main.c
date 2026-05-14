/*
 * egl-kms-gbm-demo: minimal "EGL + GBM + KMS" example (no display server).
 *
 * This is what Qt eglfs / kmscube / Weston-on-DRM do: take over the
 * physical display by holding DRM master directly, allocate framebuffers
 * with GBM, render with EGL/GLES, page-flip via KMS.
 *
 * Flow:
 *   1. open(/dev/dri/card0)              — DRM primary node (master-capable)
 *   2. drmModeGetResources / Connectors  — pick a connected output + mode
 *   3. drmModeGetEncoder                  — find which CRTC drives it
 *   4. gbm_create_device(drm_fd)         — GBM uses DRM for allocation
 *   5. gbm_surface_create(SCANOUT|RENDER)— allocates a chain of BOs that
 *                                            can both be GPU-rendered AND
 *                                            be display-scanned-out
 *   6. eglGetDisplay(gbm_device *)       — mesa's GBM platform
 *   7. eglCreateWindowSurface(gbm_surface*)
 *   8. each frame:
 *        glClear; eglSwapBuffers           (mesa rotates the BO chain)
 *        gbm_surface_lock_front_buffer     (pull the newly-rendered BO)
 *        drmModeAddFB(BO handle → FB id)   (tell KMS about this BO)
 *        first frame: drmModeSetCrtc        — actually bring up scanout
 *        later frames: drmModePageFlip      — atomic vblank flip
 *        release previous BO + RmFB
 *
 * Build: `make`  (libdrm-dev libgbm-dev libegl1-mesa-dev libgles2-mesa-dev)
 * Run:   `sudo ./egl-kms-gbm-demo`    (needs DRM master; cannot run inside
 *                                       an X11/Wayland desktop — switch to
 *                                       a free VT first: Ctrl-Alt-F3)
 *
 * Runs for ~10s (600 frames @ vblank) then exits and restores the console.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <poll.h>

#include <xf86drm.h>
#include <xf86drmMode.h>
#include <gbm.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>

static void die(const char *msg)
{
    fprintf(stderr, "fatal: %s: %s (egl 0x%x)\n", msg, strerror(errno), eglGetError());
    exit(1);
}

static int flip_done;
static void flip_handler(int fd, unsigned f, unsigned s, unsigned us, void *data)
{
    (void)fd; (void)f; (void)s; (void)us; (void)data;
    flip_done = 1;
}

int main(void)
{
    /* === step 1: open the DRM primary node === */
    int drm_fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (drm_fd < 0) die("open /dev/dri/card0");

    /* === step 2: pick the first connected connector + its preferred mode === */
    drmModeRes *res = drmModeGetResources(drm_fd);
    if (!res) die("drmModeGetResources");

    drmModeConnector *conn = NULL;
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(drm_fd, res->connectors[i]);
        if (c && c->connection == DRM_MODE_CONNECTED && c->count_modes > 0) {
            conn = c;
            break;
        }
        drmModeFreeConnector(c);
    }
    if (!conn) {
        fprintf(stderr, "no connected connector found\n");
        return 1;
    }
    drmModeModeInfo mode = conn->modes[0];
    printf("egl-kms-gbm-demo: using connector %u, mode %ux%u@%u\n",
           conn->connector_id, mode.hdisplay, mode.vdisplay, mode.vrefresh);

    /* === step 3: find a CRTC for this connector === */
    drmModeEncoder *enc = drmModeGetEncoder(drm_fd, conn->encoder_id);
    if (!enc || !enc->crtc_id) {
        fprintf(stderr, "no usable encoder/crtc\n");
        return 1;
    }
    uint32_t crtc_id = enc->crtc_id;
    drmModeCrtc *saved_crtc = drmModeGetCrtc(drm_fd, crtc_id); /* for restore */

    /* === step 4: GBM device + scanout-capable surface === */
    struct gbm_device *gbm = gbm_create_device(drm_fd);
    if (!gbm) die("gbm_create_device");
    struct gbm_surface *gbm_surf = gbm_surface_create(
        gbm, mode.hdisplay, mode.vdisplay,
        GBM_FORMAT_XRGB8888,
        GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
    if (!gbm_surf) die("gbm_surface_create");

    /* === step 5: EGL bound to the GBM device === */
    EGLDisplay egldisplay = eglGetDisplay((EGLNativeDisplayType)gbm);
    if (egldisplay == EGL_NO_DISPLAY) die("eglGetDisplay");
    if (!eglInitialize(egldisplay, NULL, NULL)) die("eglInitialize");
    eglBindAPI(EGL_OPENGL_ES_API);

    const EGLint cfg_attribs[] = {
        EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
        EGL_RED_SIZE,        8,
        EGL_GREEN_SIZE,      8,
        EGL_BLUE_SIZE,       8,
        EGL_ALPHA_SIZE,      0,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_NONE,
    };
    EGLConfig config;
    EGLint num = 0;
    if (!eglChooseConfig(egldisplay, cfg_attribs, &config, 1, &num) || num == 0)
        die("eglChooseConfig");

    EGLSurface eglsurface = eglCreateWindowSurface(
        egldisplay, config, (EGLNativeWindowType)gbm_surf, NULL);
    if (eglsurface == EGL_NO_SURFACE) die("eglCreateWindowSurface");

    const EGLint ctx_attribs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext eglcontext = eglCreateContext(egldisplay, config,
                                             EGL_NO_CONTEXT, ctx_attribs);
    if (eglcontext == EGL_NO_CONTEXT) die("eglCreateContext");
    if (!eglMakeCurrent(egldisplay, eglsurface, eglsurface, eglcontext))
        die("eglMakeCurrent");

    drmEventContext drm_ev = {
        .version = DRM_EVENT_CONTEXT_VERSION,
        .page_flip_handler = flip_handler,
    };

    printf("egl-kms-gbm-demo: rendering 600 frames...\n");

    /* === step 6: render loop with KMS page-flip === */
    struct gbm_bo *prev_bo = NULL;
    uint32_t prev_fb = 0;
    float t = 0.0f;
    for (int frame = 0; frame < 600; frame++) {
        t += 0.02f;
        glClearColor(0.5f * (1.0f + sinf(t)),
                     0.5f,
                     0.5f * (1.0f + cosf(t)),
                     1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        eglSwapBuffers(egldisplay, eglsurface);

        /* pull the freshly-rendered BO out of the surface chain */
        struct gbm_bo *bo = gbm_surface_lock_front_buffer(gbm_surf);
        if (!bo) die("gbm_surface_lock_front_buffer");
        uint32_t handle = gbm_bo_get_handle(bo).u32;
        uint32_t stride = gbm_bo_get_stride(bo);
        uint32_t fb_id  = 0;
        if (drmModeAddFB(drm_fd, mode.hdisplay, mode.vdisplay,
                         24, 32, stride, handle, &fb_id) != 0)
            die("drmModeAddFB");

        if (frame == 0) {
            /* first frame: drmModeSetCrtc actually brings up scanout */
            if (drmModeSetCrtc(drm_fd, crtc_id, fb_id, 0, 0,
                               &conn->connector_id, 1, &mode) != 0)
                die("drmModeSetCrtc");
        } else {
            /* subsequent frames: schedule a flip at next vblank */
            flip_done = 0;
            if (drmModePageFlip(drm_fd, crtc_id, fb_id,
                                DRM_MODE_PAGE_FLIP_EVENT, NULL) != 0)
                die("drmModePageFlip");
            /* wait for the flip event so we don't lap ourselves */
            struct pollfd pfd = { .fd = drm_fd, .events = POLLIN };
            while (!flip_done) {
                if (poll(&pfd, 1, -1) < 0) break;
                drmHandleEvent(drm_fd, &drm_ev);
            }
        }

        if (prev_bo) {
            drmModeRmFB(drm_fd, prev_fb);
            gbm_surface_release_buffer(gbm_surf, prev_bo);
        }
        prev_bo = bo;
        prev_fb = fb_id;
    }

    /* === cleanup: restore the previous CRTC config so tty/X comes back === */
    if (saved_crtc) {
        drmModeSetCrtc(drm_fd, saved_crtc->crtc_id, saved_crtc->buffer_id,
                       saved_crtc->x, saved_crtc->y,
                       &conn->connector_id, 1, &saved_crtc->mode);
        drmModeFreeCrtc(saved_crtc);
    }
    if (prev_bo) {
        drmModeRmFB(drm_fd, prev_fb);
        gbm_surface_release_buffer(gbm_surf, prev_bo);
    }
    eglMakeCurrent(egldisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(egldisplay, eglcontext);
    eglDestroySurface(egldisplay, eglsurface);
    eglTerminate(egldisplay);
    gbm_surface_destroy(gbm_surf);
    gbm_device_destroy(gbm);
    drmModeFreeEncoder(enc);
    drmModeFreeConnector(conn);
    drmModeFreeResources(res);
    close(drm_fd);
    return 0;
}
