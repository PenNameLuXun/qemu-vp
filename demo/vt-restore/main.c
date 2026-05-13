/*
 * vt-restore: restore a Linux VT to KD_TEXT + K_UNICODE.
 *
 * Qt eglfs (and other DRM/KMS apps that grab a VT) put the active VT into
 * KD_GRAPHICS mode and switch the kbd handler to K_OFF so that the kernel
 * stops drawing fbcon characters and stops routing keystrokes to the tty
 * line discipline (the app reads them via /dev/input/event* instead). If
 * the app is killed (SIGTERM, SIGKILL, OOM, ...) before its cleanup runs,
 * the VT stays graphical and silent — any shell still reading from
 * /dev/tty1 hangs and VNC keyboard input vanishes.
 *
 * busybox doesn't ship an applet for KDSETMODE / KDSKBMODE, so this tiny
 * helper does the two ioctls needed to recover the VT. qt-gui-demo.sh
 * traps signals and invokes it on exit; users can also run it manually
 * from the serial shell after a SIGKILL.
 *
 * Usage: vt-restore [/dev/ttyN]   (defaults to /dev/tty1)
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/kd.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    const char *path = (argc > 1) ? argv[1] : "/dev/tty1";
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "vt-restore: open %s: %s\n", path, strerror(errno));
        return 1;
    }
    int rc = 0;
    if (ioctl(fd, KDSETMODE, KD_TEXT) < 0) {
        fprintf(stderr, "vt-restore: KDSETMODE KD_TEXT: %s\n", strerror(errno));
        rc = 1;
    }
    if (ioctl(fd, KDSKBMODE, K_UNICODE) < 0) {
        fprintf(stderr, "vt-restore: KDSKBMODE K_UNICODE: %s\n", strerror(errno));
        rc = 1;
    }
    close(fd);
    return rc;
}
