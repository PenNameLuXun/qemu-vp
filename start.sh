#!/bin/bash
#
# Launch one of the supported machines in QEMU.
#
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=build.sh
source "$ROOT/build.sh"

QEMU_LOCAL="$ROOT/qemu/build/qemu-system-aarch64"
QEMU="${QEMU:-$([ -x "$QEMU_LOCAL" ] && echo "$QEMU_LOCAL" || echo qemu-system-aarch64)}"

MACHINE="${1:-virt}"

case "$MACHINE" in
  virt)
    OUT="$BUILD_ROOT/virt"
    build_uboot qemu_arm64_defconfig "$OUT"
    exec "$QEMU" \
      -machine virt \
      -cpu cortex-a57 \
      -nographic \
      -bios "$OUT/u-boot.bin"
    ;;
  raspi3b)
    OUT="$BUILD_ROOT/rpi3"
    build_uboot rpi_3_defconfig "$OUT"
    # DTS stdout-path points at serial1 (mini-UART); feed it stdio.
    exec "$QEMU" \
      -machine raspi3b \
      -cpu cortex-a53 \
      -display none \
      -serial null -serial stdio \
      -kernel "$OUT/u-boot.bin" \
      -dtb "$OUT/arch/arm/dts/bcm2837-rpi-3-b.dtb"
    ;;
  jxl)
    OUT="$BUILD_ROOT/jxl"
    FLASH_IMG="$OUT/jxl-flash.img"
    build_uboot jxl_defconfig "$OUT"
    ensure_jxl_flash "$FLASH_IMG"
    exec "$QEMU" \
      -machine jxl \
      -cpu cortex-a53 \
      -m 128M \
      -nographic \
      -drive if=pflash,format=raw,file="$FLASH_IMG" \
      -kernel "$OUT/u-boot.bin"
    ;;
  linux-jxl)
    # Boot Linux directly on the jxl machine (bypassing U-Boot) so the
    # kernel + initramfs chain can be validated independently of boot firmware.
    build_kernel
    build_rootfs
    exec "$QEMU" \
      -machine jxl \
      -cpu cortex-a53 \
      -m 128M \
      -nographic \
      -kernel "$BUILD_ROOT/linux/arch/arm64/boot/Image" \
      -initrd "$BUILD_ROOT/initramfs.cpio.gz" \
      -append "console=ttyAMA0 earlycon=pl011,0x9000000"
    ;;
  *)
    echo "usage: $0 [virt|raspi3b|jxl|linux-jxl]" >&2
    exit 1
    ;;
esac
