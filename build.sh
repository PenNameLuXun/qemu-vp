#!/bin/bash
#
# Build helpers for the uboot-learn tree. Can be executed directly:
#
#   ./build.sh qemu          # build QEMU (our fork) into qemu/build/
#   ./build.sh virt          # U-Boot for qemu virt
#   ./build.sh raspi3b       # U-Boot for qemu raspi3b
#   ./build.sh jxl           # U-Boot for the jxl machine
#   ./build.sh jxl-dtb       # standalone Linux DTB for the jxl machine
#   ./build.sh kernel        # Linux kernel (arm64 defconfig + Image)
#   ./build.sh busybox       # BusyBox (static)
#   ./build.sh rootfs        # busybox + initramfs.cpio.gz
#   ./build.sh all           # jxl u-boot + kernel + rootfs
#
# start.sh sources this file to reuse the helpers.
#
# Env overrides: CROSS_COMPILE (default aarch64-linux-gnu-), JOBS (default nproc)
#
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UBOOT_SRC="$ROOT/src/u-boot"
LINUX_SRC="$ROOT/src/linux"
BUSYBOX_SRC="$ROOT/src/busybox"
QEMU_SRC="$ROOT/qemu"
BUILD_ROOT="$ROOT/build"
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"

JXL_FLASH_SIZE=$((16 * 1024 * 1024))
JXL_MMC_IMAGE_SIZE=$((128 * 1024 * 1024))
JXL_MMC_KERNEL_SECTOR=0x800
JXL_MMC_KERNEL_SECTORS_MAX=0x18000
JXL_MMC_DTB_SECTOR=0x18800
JXL_MMC_DTB_SECTORS_MAX=0x200
JXL_MMC_INITRD_SECTOR=0x18a00
JXL_MMC_INITRD_SECTORS_MAX=0x4000

log() { echo "[build] $*" >&2; }

build_qemu() {
  local out="$QEMU_SRC/build"
  if [[ -x "$out/qemu-system-aarch64" ]]; then return; fi
  log "qemu -> $out"
  mkdir -p "$out"
  (cd "$out" && ../configure --target-list=aarch64-softmmu --disable-docs)
  ninja -C "$out"
}

build_uboot() {
  local defconfig="$1" out="$2"
  if [[ -f "$out/u-boot.bin" ]]; then return; fi
  log "u-boot $defconfig -> $out"
  mkdir -p "$out"
  make -C "$UBOOT_SRC" O="$out" CROSS_COMPILE="$CROSS" "$defconfig" >/dev/null
  make -C "$UBOOT_SRC" O="$out" CROSS_COMPILE="$CROSS" -j"$JOBS"
}

build_kernel() {
  local out="$BUILD_ROOT/linux"
  if [[ -f "$out/arch/arm64/boot/Image" ]]; then return; fi
  log "linux -> $out"
  mkdir -p "$out"
  make -C "$LINUX_SRC" O="$out" ARCH=arm64 CROSS_COMPILE="$CROSS" defconfig
  make -C "$LINUX_SRC" O="$out" ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$JOBS" Image
}

build_busybox() {
  local out="$BUILD_ROOT/busybox"
  if [[ -x "$out/busybox" ]]; then return; fi
  log "busybox -> $out"
  mkdir -p "$out"
  make -C "$BUSYBOX_SRC" O="$out" defconfig
  # Force static link so the binary stands alone inside initramfs.
  # Drop the x86-only SHA_HWACCEL paths that ship references without
  # aarch64 assembly backing them.
  sed -i \
    -e 's|.*CONFIG_STATIC[ =].*|CONFIG_STATIC=y|' \
    -e 's|.*CONFIG_SHA1_HWACCEL.*|# CONFIG_SHA1_HWACCEL is not set|' \
    -e 's|.*CONFIG_SHA256_HWACCEL.*|# CONFIG_SHA256_HWACCEL is not set|' \
    "$out/.config"
  yes "" | make -C "$BUSYBOX_SRC" O="$out" ARCH=arm64 CROSS_COMPILE="$CROSS" oldconfig >/dev/null
  make -C "$BUSYBOX_SRC" O="$out" ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$JOBS"
}

build_rootfs() {
  build_busybox
  local stage="$BUILD_ROOT/rootfs"
  local bb="$BUILD_ROOT/busybox/busybox"
  local cpio="$BUILD_ROOT/initramfs.cpio.gz"
  if [[ -f "$cpio" && "$cpio" -nt "$bb" ]]; then return; fi
  log "rootfs -> $cpio"
  rm -rf "$stage"
  mkdir -p "$stage"/{bin,sbin,etc,proc,sys,dev,usr/bin,usr/sbin,root}
  cp "$bb" "$stage/bin/busybox"
  chmod +x "$stage/bin/busybox"
  cat > "$stage/init" <<'EOF'
#!/bin/busybox sh
/bin/busybox --install -s
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev 2>/dev/null || true
echo
echo "jxl rootfs up."
# setsid + cttyhack so /bin/sh becomes the controlling terminal's session
# leader and job control works.
exec setsid cttyhack /bin/sh
EOF
  chmod +x "$stage/init"
  (cd "$stage" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$cpio")
}

ensure_jxl_flash() {
  local image="$1"
  if [[ -f "$image" ]]; then return; fi
  log "create erased JXL flash image -> $image"
  mkdir -p "$(dirname "$image")"
  perl -e "print qq(\\xFF) x $JXL_FLASH_SIZE" >"$image"
}

build_jxl_linux_dtb() {
  local src_dir="$ROOT/dts"
  local src="$src_dir/jxl.dts"
  local common="$src_dir/jxl.dtsi"
  local out_dir="$BUILD_ROOT/jxl"
  local out="$out_dir/jxl-linux.dtb"
  if [[ -f "$out" && "$out" -nt "$src" && "$out" -nt "$common" ]]; then return; fi
  log "jxl linux dtb -> $out"
  mkdir -p "$out_dir"
  dtc -I dts -O dtb -o "$out" "$src"
}

ensure_jxl_mmc_image() {
  local image="$1"
  local kernel="$BUILD_ROOT/linux/arch/arm64/boot/Image"
  local dtb="$BUILD_ROOT/jxl/jxl-linux.dtb"
  local initrd="$BUILD_ROOT/initramfs.cpio.gz"
  local kernel_sectors dtb_sectors initrd_sectors

  kernel_sectors=$(( ($(stat -c '%s' "$kernel") + 511) / 512 ))
  dtb_sectors=$(( ($(stat -c '%s' "$dtb") + 511) / 512 ))
  initrd_sectors=$(( ($(stat -c '%s' "$initrd") + 511) / 512 ))

  if (( kernel_sectors > JXL_MMC_KERNEL_SECTORS_MAX )); then
    echo "kernel image is too large for JXL MMC layout" >&2
    return 1
  fi
  if (( dtb_sectors > JXL_MMC_DTB_SECTORS_MAX )); then
    echo "dtb is too large for JXL MMC layout" >&2
    return 1
  fi
  if (( initrd_sectors > JXL_MMC_INITRD_SECTORS_MAX )); then
    echo "initramfs is too large for JXL MMC layout" >&2
    return 1
  fi

  log "populate JXL MMC image -> $image"
  mkdir -p "$(dirname "$image")"
  truncate -s "$JXL_MMC_IMAGE_SIZE" "$image"
  dd if="$kernel" of="$image" bs=512 seek=$((JXL_MMC_KERNEL_SECTOR)) conv=notrunc status=none
  dd if="$dtb" of="$image" bs=512 seek=$((JXL_MMC_DTB_SECTOR)) conv=notrunc status=none
  dd if="$initrd" of="$image" bs=512 seek=$((JXL_MMC_INITRD_SECTOR)) conv=notrunc status=none
}

# Only dispatch if executed directly (not when sourced).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-all}" in
    qemu)    build_qemu ;;
    virt)    build_uboot qemu_arm64_defconfig "$BUILD_ROOT/virt" ;;
    raspi3b) build_uboot rpi_3_defconfig      "$BUILD_ROOT/rpi3" ;;
    jxl)     build_uboot jxl_defconfig        "$BUILD_ROOT/jxl" ;;
    jxl-dtb) build_jxl_linux_dtb ;;
    kernel)  build_kernel ;;
    busybox) build_busybox ;;
    rootfs)  build_rootfs ;;
    all)
      build_uboot jxl_defconfig "$BUILD_ROOT/jxl"
      build_jxl_linux_dtb
      build_kernel
      build_rootfs
      ;;
    *) echo "usage: $0 [qemu|virt|raspi3b|jxl|jxl-dtb|kernel|busybox|rootfs|all]" >&2; exit 1 ;;
  esac
fi
