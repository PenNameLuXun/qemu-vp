#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: ./run.sh MODE [extra make args...]

JXL Linux GUI shortcuts:
  gui-pl111     VNC :0 / 127.0.0.1:5900 shows PL111, guest Qt uses /dev/fb1
  gui-virtio    VNC :0 / 127.0.0.1:5900 shows virtio-gpu, guest Qt uses /dev/fb0
  gui-dual      VNC :0 shows PL111, VNC :1 / 127.0.0.1:5901 shows virtio-gpu
  sdl-pl111     SDL window shows PL111
  headless      serial only, no graphical display

Guest Qt examples:
  gui-pl111:   ./qt-gui-demo.sh pl111
  gui-virtio:  ./qt-gui-demo.sh virtio
  gui-dual:    use pl111 or virtio depending on which VNC window you watch

Any extra arguments are passed to make. For example:
  ./run.sh gui-virtio JXL_NETDEV='-netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.0'
EOF
}

mode="${1:-gui-pl111}"
if [[ $# -gt 0 ]]; then
  shift
fi

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
