#!/bin/bash
#
# Build helpers for the uboot-learn tree. Can be executed directly:
#
#   ./build.sh qemu          # build QEMU (our fork) into qemu/build/
#   ./build.sh virt          # U-Boot for qemu virt
#   ./build.sh raspi3b       # U-Boot for qemu raspi3b
#   ./build.sh jxl           # U-Boot for the jxl machine
#   ./build.sh jxl-dtb       # standalone Linux DTB for the jxl machine
#   ./build.sh tfa           # Trusted Firmware-A BL31 for the jxl machine
#   ./build.sh xen           # Xen hypervisor (arm64)
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
TFA_SRC="$ROOT/src/trusted-firmware-a"
XEN_SRC="$ROOT/src/xen"
LINUX_SRC="$ROOT/src/linux"
BUSYBOX_SRC="$ROOT/src/busybox"
QEMU_SRC="$ROOT/qemu"
BUILD_ROOT="$ROOT/build"
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"

JXL_FLASH_SIZE=$((16 * 1024 * 1024))
JXL_MMC_IMAGE_SIZE=$((128 * 1024 * 1024))
JXL_MMC_BOOT_START_SECTOR=2048
JXL_XEN_DOM0_KERNEL_ADDR=0x80000000
JXL_XEN_DOM0_INITRD_ADDR=0x90000000

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
  if [[ "$defconfig" == "jxl_defconfig" ]]; then
    if [[ -f "$out/u-boot.bin" && -f "$out/u-boot.img" &&
          -f "$out/spl/u-boot-spl.bin" ]]; then
      return
    fi
  elif [[ -f "$out/u-boot.bin" ]]; then
    return
  fi
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

build_tfa() {
  local out="$BUILD_ROOT/tfa"
  local artifact="$out/jxl/debug/bl31.bin"
  if [[ -f "$artifact" ]]; then
    if ! find \
      "$TFA_SRC/plat/jxl" \
      "$TFA_SRC/plat/qemu/common" \
      "$TFA_SRC/common" \
      "$TFA_SRC/lib/psci" \
      "$TFA_SRC/services/std_svc" \
      -type f -newer "$artifact" -print -quit | grep -q .; then
      return
    fi
  fi
  if [[ ! -e "$TFA_SRC/.git" ]]; then
    echo "error: TF-A source is missing at $TFA_SRC" >&2
    return 1
  fi
  log "trusted-firmware-a jxl bl31 -> $out"
  mkdir -p "$out"
  make -C "$TFA_SRC" \
    PLAT=jxl \
    ARCH=aarch64 \
    DEBUG=1 \
    CROSS_COMPILE="$CROSS" \
    BUILD_BASE="$out" \
    bl31
}

build_xen() {
  local out="$BUILD_ROOT/xen"
  local artifact="$out/xen"
  if [[ -f "$artifact" ]]; then return; fi
  if [[ ! -e "$XEN_SRC/.git" ]]; then
    echo "error: Xen source is missing at $XEN_SRC" >&2
    return 1
  fi
  log "xen arm64 hypervisor -> $out"
  mkdir -p "$out"
  make -C "$XEN_SRC" \
    XEN_TARGET_ARCH=arm64 \
    CROSS_COMPILE="$CROSS" \
    O="$out" \
    arm64_defconfig
  make -C "$XEN_SRC" \
    XEN_TARGET_ARCH=arm64 \
    CROSS_COMPILE="$CROSS" \
    O="$out" \
    build-xen \
    -j"$JOBS"
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

populate_jxl_spl_flash() {
  local image="$1"
  local payload="$2"
  local payload_size max_payload

  ensure_jxl_flash "$image"
  payload_size=$(stat -c%s "$payload")
  max_payload=$((JXL_FLASH_SIZE - 0x10000))

  if (( payload_size > max_payload )); then
    echo "error: $payload is too large for JXL flash boot area" >&2
    return 1
  fi

  log "install U-Boot proper into JXL flash image -> $image"
  dd if="$payload" of="$image" conv=notrunc status=none
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

build_jxl_xen_dtb() {
  local out_dir="$BUILD_ROOT/jxl"
  local base_dtb="$out_dir/jxl-linux.dtb"
  local out_dtb="$out_dir/jxl-xen.dtb"
  local overlay_dts="$out_dir/jxl-xen-overlay.dts"
  local overlay_dtbo="$out_dir/jxl-xen-overlay.dtbo"
  local kernel="$BUILD_ROOT/linux/arch/arm64/boot/Image"
  local initrd="$BUILD_ROOT/initramfs.cpio.gz"
  local kernel_size initrd_size

  kernel_size=$(stat -c%s "$kernel")
  initrd_size=$(stat -c%s "$initrd")

  log "jxl xen dtb -> $out_dtb"
  mkdir -p "$out_dir"
  cat >"$overlay_dts" <<EOF
/dts-v1/;
/plugin/;

/ {
	fragment@0 {
		target-path = "/chosen";

		__overlay__ {
			#address-cells = <0x2>;
			#size-cells = <0x2>;
			xen,xen-bootargs =
				"console=dtuart dtuart=serial0 dom0_mem=512M bootscrub=0 console_timestamps=boot";

			module@44000000 {
				compatible = "multiboot,kernel", "multiboot,module";
				reg = <0x0 $JXL_XEN_DOM0_KERNEL_ADDR 0x0 0x$(printf '%x' "$kernel_size")>;
				bootargs = "console=hvc0 earlycon=xen rdinit=/init";
			};

			module@46000000 {
				compatible = "multiboot,ramdisk", "multiboot,module";
				reg = <0x0 $JXL_XEN_DOM0_INITRD_ADDR 0x0 0x$(printf '%x' "$initrd_size")>;
			};
		};
	};
};
EOF

  dtc -@ -I dts -O dtb -o "$overlay_dtbo" "$overlay_dts"
  fdtoverlay -i "$base_dtb" -o "$out_dtb" "$overlay_dtbo"
}

ensure_jxl_mmc_image() {
  local image="$1"
  local kernel="$BUILD_ROOT/linux/arch/arm64/boot/Image"
  local dtb="$BUILD_ROOT/jxl/jxl-linux.dtb"
  local initrd="$BUILD_ROOT/initramfs.cpio.gz"
  local out_dir stage bootfs boot_bytes total_sectors start_sector boot_sectors

  out_dir="$(dirname "$image")"
  stage="$out_dir/jxl-mmc-boot"
  bootfs="$out_dir/jxl-mmc-boot.ext4"
  total_sectors=$(( JXL_MMC_IMAGE_SIZE / 512 ))
  start_sector=$JXL_MMC_BOOT_START_SECTOR
  boot_sectors=$(( total_sectors - start_sector ))
  boot_bytes=$(( boot_sectors * 512 ))

  log "populate JXL MMC image -> $image"
  mkdir -p "$out_dir"
  rm -rf "$stage"
  rm -f "$bootfs"
  mkdir -p "$stage"
  cp "$kernel" "$stage/Image"
  cp "$dtb" "$stage/jxl-linux.dtb"
  cp "$initrd" "$stage/initramfs.cpio.gz"

  truncate -s "$boot_bytes" "$bootfs"
  mkfs.ext4 -q -F -O ^metadata_csum,^64bit -d "$stage" -L JXLBOOT "$bootfs"

  truncate -s "$JXL_MMC_IMAGE_SIZE" "$image"
  sfdisk --wipe always --wipe-partitions always "$image" >/dev/null <<EOF
label: dos
unit: sectors

${start_sector},${boot_sectors},L,*
EOF
  dd if="$bootfs" of="$image" bs=512 seek=$start_sector conv=notrunc status=none
}

ensure_jxl_xen_mmc_image() {
  local image="$1"
  local kernel="$BUILD_ROOT/linux/arch/arm64/boot/Image"
  local dtb="$BUILD_ROOT/jxl/jxl-xen.dtb"
  local initrd="$BUILD_ROOT/initramfs.cpio.gz"
  local xen="$BUILD_ROOT/xen/xen"
  local out_dir stage bootfs boot_bytes total_sectors start_sector boot_sectors

  out_dir="$(dirname "$image")"
  stage="$out_dir/jxl-xen-mmc-boot"
  bootfs="$out_dir/jxl-xen-mmc-boot.ext4"
  total_sectors=$(( JXL_MMC_IMAGE_SIZE / 512 ))
  start_sector=$JXL_MMC_BOOT_START_SECTOR
  boot_sectors=$(( total_sectors - start_sector ))
  boot_bytes=$(( boot_sectors * 512 ))

  log "populate JXL Xen MMC image -> $image"
  mkdir -p "$out_dir"
  rm -rf "$stage"
  rm -f "$bootfs"
  mkdir -p "$stage"
  cp "$kernel" "$stage/Image"
  cp "$dtb" "$stage/jxl-xen.dtb"
  cp "$initrd" "$stage/initramfs.cpio.gz"
  cp "$xen" "$stage/xen"

  truncate -s "$boot_bytes" "$bootfs"
  mkfs.ext4 -q -F -O ^metadata_csum,^64bit -d "$stage" -L JXLBOOT "$bootfs"

  truncate -s "$JXL_MMC_IMAGE_SIZE" "$image"
  sfdisk --wipe always --wipe-partitions always "$image" >/dev/null <<EOF
label: dos
unit: sectors

${start_sector},${boot_sectors},L,*
EOF
  dd if="$bootfs" of="$image" bs=512 seek=$start_sector conv=notrunc status=none
}

build_jxl_atf_fit() {
  local out="$1"
  local bl31="$BUILD_ROOT/tfa/jxl/debug/bl31.bin"
  local uboot="$out/u-boot-nodtb.bin"
  local uboot_dtb="$out/arch/arm/dts/jxl.dtb"
  local its="$out/jxl-atf.its"
  local itb="$out/jxl-atf.itb"
  local bl31_load=0xbff90000

  if [[ -f "$itb" && "$itb" -nt "$bl31" && "$itb" -nt "$uboot" &&
        "$itb" -nt "$uboot_dtb" ]]; then
    return
  fi

  log "jxl atf fit -> $itb"
  cat >"$its" <<EOF
/dts-v1/;

/ {
	description = "JXL SPL -> BL31 -> U-Boot FIT";
	#address-cells = <1>;

	images {
		uboot {
			description = "U-Boot proper";
			data = /incbin/("u-boot-nodtb.bin");
			type = "standalone";
			os = "u-boot";
			arch = "arm64";
			compression = "none";
			load = <0x40080000>;
			entry = <0x40080000>;
			hash {
				algo = "sha256";
			};
		};

		atf {
			description = "ARM Trusted Firmware BL31";
			data = /incbin/("$bl31");
			type = "firmware";
			os = "arm-trusted-firmware";
			arch = "arm64";
			compression = "none";
			load = <$bl31_load>;
			entry = <$bl31_load>;
			hash {
				algo = "sha256";
			};
		};

		fdt-0 {
			description = "JXL U-Boot DTB";
			data = /incbin/("arch/arm/dts/jxl.dtb");
			type = "flat_dt";
			arch = "arm64";
			compression = "none";
			hash {
				algo = "sha256";
			};
		};
	};

	configurations {
		default = "conf";

		conf {
			description = "BL31 then U-Boot";
			firmware = "atf";
			loadables = "uboot";
			fdt = "fdt-0";
		};
	};
};
EOF

  (
    cd "$out"
    ./tools/mkimage -f "$(basename "$its")" "$(basename "$itb")" >/dev/null
  )
}

# Only dispatch if executed directly (not when sourced).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-all}" in
    qemu)    build_qemu ;;
    virt)    build_uboot qemu_arm64_defconfig "$BUILD_ROOT/virt" ;;
    raspi3b) build_uboot rpi_3_defconfig      "$BUILD_ROOT/rpi3" ;;
    jxl)     build_uboot jxl_defconfig        "$BUILD_ROOT/jxl" ;;
    jxl-dtb) build_jxl_linux_dtb ;;
    tfa)     build_tfa ;;
    xen)     build_xen ;;
    kernel)  build_kernel ;;
    busybox) build_busybox ;;
    rootfs)  build_rootfs ;;
    all)
      build_uboot jxl_defconfig "$BUILD_ROOT/jxl"
      build_jxl_linux_dtb
      build_kernel
      build_rootfs
      ;;
    *) echo "usage: $0 [qemu|virt|raspi3b|jxl|jxl-dtb|tfa|xen|kernel|busybox|rootfs|all]" >&2; exit 1 ;;
  esac
fi
