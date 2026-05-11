#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: ./run.sh MODE [extra make args...]

JXL Linux GUI shortcuts:
  gui-pl111     VNC :0 / 127.0.0.1:5900 shows PL111, guest Qt uses /dev/fb1
  gui-virtio    VNC :0 / 127.0.0.1:5900 shows virtio-gpu, guest Qt uses /dev/fb0
  gui-virtio-gl EGL headless + VNC shows virtio-gpu with host OpenGL acceleration
  sdl-virtio-gl SDL/Wayland window shows virtio-gpu with virgl host OpenGL
  sdl-virtio-gl-x11
                 SDL/X11 window shows virtio-gpu with virgl host OpenGL
  gui-dual      VNC :0 shows PL111, VNC :1 / 127.0.0.1:5901 shows virtio-gpu
  sdl-pl111     SDL window shows PL111
  headless      serial only, no graphical display

Guest Qt examples:
  gui-pl111:   ./qt-gui-demo.sh pl111
  gui-virtio:  ./qt-gui-demo.sh virtio
  gui-virtio-gl:
               ./qt-gui-demo.sh eglfs
  sdl-virtio-gl:
               ./qt-gui-demo.sh eglfs
  gui-dual:    use pl111 or virtio depending on which VNC window you watch

Any extra arguments are passed to make. For example:
  ./run.sh gui-virtio JXL_NETDEV='-netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.0'
EOF
}

mode="${1:-gui-pl111}"
if [[ $# -gt 0 ]]; then
  shift
fi

# Locally-built virglrenderer 1.1.1 lives here. Ubuntu 22.04 ships 0.9.1, which
# trips on Qt 6's GL 4.1 core fence/buffer usage ("wait sync failed: illegal
# fence object ..."). The newer build keeps SONAME libvirglrenderer.so.1, so
# pointing LD_LIBRARY_PATH at the build dir is enough — no install required.
VIRGL_LOCAL_LIBDIR="$(dirname "$(readlink -f "$0")")/src/virglrenderer/build/src"
use_local_virgl() {
  if [[ -f "$VIRGL_LOCAL_LIBDIR/libvirglrenderer.so.1" ]]; then
    export LD_LIBRARY_PATH="$VIRGL_LOCAL_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    echo "[run] using local virglrenderer: $VIRGL_LOCAL_LIBDIR" >&2
  fi
  # Do NOT set MESA_LOADER_DRIVER_OVERRIDE=d3d12 here, even though it sounds
  # right. On WSLg that override forces mesa into the DRI2 path which then
  # needs kmsro to bind a KMS device, and dxgkrnl exposes no KMS device.
  # With no override mesa takes its WSL fallback chain (vgem -> kms_swrast ->
  # dxcore) and ends up on the real d3d12 driver -- which is what our patched
  # egl-headless with rendernode=dxcore relies on.
  if [[ -e /dev/dxg ]]; then
    export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-0}"
    echo "[run] WSLg detected (/dev/dxg present)" >&2
  fi
  # JXL_GL_DEBUG=1 turns on verbose host-side GL/virgl diagnostics so the
  # actual failing GL call shows up in stderr instead of just the catch-all
  # "Unknown 1282 (GL_INVALID_OPERATION)" message from vrend_check_no_error.
  if [[ "${JXL_GL_DEBUG:-0}" == "1" ]]; then
    export LIBGL_DEBUG=verbose            # which mesa DRI driver got dlopen'd
    export EGL_LOG_LEVEL=debug
    export MESA_DEBUG=context
    export VIRGL_LOG_LEVEL=debug
    export VREND_DEBUG="${VREND_DEBUG:-khr,feat,copyres,tex}"
    echo "[run] verbose GL debug enabled (JXL_GL_DEBUG=1)" >&2
  fi
}

case "$mode" in
  -h|--help|help)
    usage
    exit 0
    ;;

  gui-pl111|pl111|fb1)
    export JXL_QEMU_DISPLAY="${JXL_QEMU_DISPLAY:--display none -vnc :0 -serial mon:stdio -parallel none}"
    export JXL_GPUDEV="${JXL_GPUDEV:--device virtio-gpu-device,id=gpu0,bus=virtio-mmio-bus.1,xres=800,yres=600}"
    echo "[run] VNC :0 -> PL111 (/dev/fb1), connect to 127.0.0.1:5900" >&2
    ;;

  gui-virtio|virtio|fb0)
    export JXL_QEMU_DISPLAY="${JXL_QEMU_DISPLAY:--display none -vnc :0,display=gpu0,head=0 -serial mon:stdio -parallel none}"
    export JXL_GPUDEV="${JXL_GPUDEV:--device virtio-gpu-device,id=gpu0,bus=virtio-mmio-bus.1,xres=800,yres=600}"
    echo "[run] VNC :0 -> virtio-gpu (/dev/fb0), connect to 127.0.0.1:5900" >&2
    ;;

  gui-virtio-gl|virtio-gl|gl)
    use_local_virgl
    # On WSL2 the host has /dev/dxg (dxgkrnl) and /dev/dri/* is vgem. The
    # QEMU egl-helpers.c patch wired up by this fork routes
    # rendernode=dxcore[:N] through EGL_PLATFORM_DEVICE_EXT, which lets mesa
    # take its WSL fallback chain and load d3d12_dri.so on top of dxcore.
    # That gives a GL 4.1 *compatibility* profile -- exactly what virglrenderer
    # needs (the swrast core profile breaks vrend on legacy GL enums).
    if [[ -e /dev/dxg ]]; then
      export JXL_QEMU_DISPLAY="${JXL_QEMU_DISPLAY:--display egl-headless,rendernode=dxcore -display vnc=:0,display=gpu0,head=0 -serial mon:stdio -parallel none}"
      echo "[run] VNC :0 -> virtio-gpu virgl, host EGL via EGL_PLATFORM_DEVICE_EXT (dxcore/d3d12)" >&2
      echo "[run] connect to 127.0.0.1:5900" >&2
    else
      rendernode="$(ls /dev/dri/renderD* 2>/dev/null | head -n 1 || true)"
      if [[ -n "$rendernode" && -r "$rendernode" && -w "$rendernode" ]]; then
        export JXL_QEMU_DISPLAY="${JXL_QEMU_DISPLAY:--display egl-headless,rendernode=$rendernode -display vnc=:0,display=gpu0,head=0 -serial mon:stdio -parallel none}"
        echo "[run] VNC :0 -> virtio-gpu virgl, host EGL rendernode: $rendernode" >&2
        echo "[run] connect to 127.0.0.1:5900" >&2
      else
        if [[ -n "$rendernode" ]]; then
          echo "[run] found $rendernode but current user cannot read/write it" >&2
          echo "[run] fix with: sudo usermod -aG render,video $USER  # then restart the shell/session" >&2
        fi
        export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-x11}"
        export JXL_QEMU_DISPLAY="${JXL_QEMU_DISPLAY:--display sdl,gl=on -serial mon:stdio -parallel none}"
        echo "[run] SDL GL -> virtio-gpu virgl, no host DRM render node found" >&2
        echo "[run] forcing SDL_VIDEODRIVER=$SDL_VIDEODRIVER for WSLg/X11 GLX" >&2
      fi
    fi
    export JXL_GPUDEV="${JXL_GPUDEV:--device virtio-gpu-gl-device,id=gpu0,bus=virtio-mmio-bus.1,xres=800,yres=600}"
    ;;

  sdl-virtio-gl|virtio-gl-sdl|gl-sdl|sdl-gl)
    use_local_virgl
    export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-wayland}"
    export JXL_QEMU_DISPLAY="${JXL_QEMU_DISPLAY:--display sdl,gl=on -serial mon:stdio -parallel none}"
    export JXL_GPUDEV="${JXL_GPUDEV:--device virtio-gpu-gl-device,id=gpu0,bus=virtio-mmio-bus.1,xres=800,yres=600}"
    echo "[run] SDL/$SDL_VIDEODRIVER -> virtio-gpu virgl (/dev/dri/card0)" >&2
    echo "[run] guest Qt: ./qt-gui-demo.sh eglfs" >&2
    ;;

  sdl-virtio-gl-x11|virtio-gl-sdl-x11|gl-sdl-x11|sdl-gl-x11)
    use_local_virgl
    export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-x11}"
    export JXL_QEMU_DISPLAY="${JXL_QEMU_DISPLAY:--display sdl,gl=on -serial mon:stdio -parallel none}"
    export JXL_GPUDEV="${JXL_GPUDEV:--device virtio-gpu-gl-device,id=gpu0,bus=virtio-mmio-bus.1,xres=800,yres=600}"
    echo "[run] SDL/$SDL_VIDEODRIVER -> virtio-gpu virgl (/dev/dri/card0)" >&2
    echo "[run] guest Qt: ./qt-gui-demo.sh eglfs" >&2
    ;;

  gui-dual|dual)
    export JXL_QEMU_DISPLAY="${JXL_QEMU_DISPLAY:--display vnc=:0,id=pl111 -display vnc=:1,id=virtio,display=gpu0,head=0 -serial mon:stdio -parallel none}"
    export JXL_GPUDEV="${JXL_GPUDEV:--device virtio-gpu-device,id=gpu0,bus=virtio-mmio-bus.1,xres=800,yres=600}"
    echo "[run] VNC :0 -> PL111 (/dev/fb1), connect to 127.0.0.1:5900" >&2
    echo "[run] VNC :1 -> virtio-gpu (/dev/fb0), connect to 127.0.0.1:5901" >&2
    ;;

  sdl-pl111|sdl)
    export JXL_QEMU_DISPLAY="${JXL_QEMU_DISPLAY:--display sdl -serial mon:stdio -parallel none}"
    export JXL_GPUDEV="${JXL_GPUDEV:--device virtio-gpu-device,id=gpu0,bus=virtio-mmio-bus.1,xres=800,yres=600}"
    echo "[run] SDL -> PL111 (/dev/fb1)" >&2
    ;;

  headless|none)
    export JXL_QEMU_DISPLAY="${JXL_QEMU_DISPLAY:--nographic}"
    export JXL_GPUDEV="${JXL_GPUDEV:--device virtio-gpu-device,id=gpu0,bus=virtio-mmio-bus.1,xres=800,yres=600}"
    echo "[run] headless serial only" >&2
    ;;

  *)
    echo "unknown mode: $mode" >&2
    usage >&2
    exit 2
    ;;
esac

exec make run-jxl-linux "$@"
