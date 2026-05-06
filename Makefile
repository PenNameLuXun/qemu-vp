# Self-contained Makefile for the uboot-learn tree.
#
# This file does NOT call build.sh or start.sh; all build and boot logic
# lives directly in the recipes below. The shell scripts are kept as
# alternative entry points but the Makefile is the source of truth.
#
# Quick reference:
#   make help              list all targets
#   make build-jxl         build U-Boot for the jxl machine
#   make run-jxl-optee     boot SPL → BL31 → OP-TEE → U-Boot → Linux
#   make clean             wipe firmware / U-Boot / jxl artifacts
#   make distclean         wipe entire build/

# ---------------------------------------------------------------------
#  Top-level configuration
# ---------------------------------------------------------------------

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD_ROOT := $(ROOT)/build

UBOOT_SRC   := $(ROOT)/src/u-boot
TFA_SRC     := $(ROOT)/src/trusted-firmware-a
XEN_SRC     := $(ROOT)/src/xen
LINUX_SRC   := $(ROOT)/src/linux
BUSYBOX_SRC := $(ROOT)/src/busybox
OPTEE_SRC   := $(ROOT)/src/optee_os
QEMU_SRC    := $(ROOT)/qemu
DTS_DIR     := $(ROOT)/dts

CROSS_COMPILE ?= aarch64-linux-gnu-
JOBS          ?= $(shell nproc)

# Each recipe runs in a single shell so heredocs and multi-line bash work.
# We use bash with errexit only - no pipefail (yes "" | make oldconfig
# legitimately gets SIGPIPE'd) and no nounset (some sub-makes touch
# unset env).
.ONESHELL:
SHELL       := /bin/bash
.SHELLFLAGS := -e -c

# Drop GNU Make's built-in implicit rules. Otherwise Make tries to
# `cc tools/mkimage.o u-boot.bin -o tools/mkimage` for files it
# doesn't have a recipe for but which match `%`, `%.o → %`, etc.
MAKEFLAGS += --no-builtin-rules
.SUFFIXES:

# ---------------------------------------------------------------------
#  Per-target output directories and headline artifacts
# ---------------------------------------------------------------------

VIRT_OUT       := $(BUILD_ROOT)/virt
RPI3_OUT       := $(BUILD_ROOT)/rpi3
JXL_OUT        := $(BUILD_ROOT)/jxl
LINUX_OUT      := $(BUILD_ROOT)/linux
BUSYBOX_OUT    := $(BUILD_ROOT)/busybox
TFA_NOSPD_OUT  := $(BUILD_ROOT)/tfa
TFA_OPTEED_OUT := $(BUILD_ROOT)/tfa-opteed
XEN_OUT        := $(BUILD_ROOT)/xen
OPTEE_OUT      := $(BUILD_ROOT)/optee
ROOTFS_STAGE   := $(BUILD_ROOT)/rootfs
INITRAMFS      := $(BUILD_ROOT)/initramfs.cpio.gz

QEMU_LOCAL    := $(QEMU_SRC)/build/qemu-system-aarch64
QEMU_FALLBACK := qemu-system-aarch64
# Recursive (=) so the value is recomputed each recipe expansion: a freshly
# built $(QEMU_LOCAL) is picked up without needing to reload the makefile.
QEMU = $(if $(wildcard $(QEMU_LOCAL)),$(QEMU_LOCAL),$(QEMU_FALLBACK))

LINUX_IMAGE := $(LINUX_OUT)/arch/arm64/boot/Image
BUSYBOX_BIN := $(BUSYBOX_OUT)/busybox

VIRT_UBOOT  := $(VIRT_OUT)/u-boot.bin
RPI3_UBOOT  := $(RPI3_OUT)/u-boot.bin
RPI3_DTB    := $(RPI3_OUT)/arch/arm/dts/bcm2837-rpi-3-b.dtb
JXL_UBOOT   := $(JXL_OUT)/u-boot.bin
JXL_UBOOT_IMG := $(JXL_OUT)/u-boot.img
JXL_UBOOT_NODTB := $(JXL_OUT)/u-boot-nodtb.bin
JXL_SPL     := $(JXL_OUT)/spl/u-boot-spl.bin
JXL_UBOOT_DTB := $(JXL_OUT)/arch/arm/dts/jxl.dtb
JXL_MKIMAGE   := $(JXL_OUT)/tools/mkimage
JXL_MKENVIMG  := $(JXL_OUT)/tools/mkenvimage

TFA_NOSPD_BL31  := $(TFA_NOSPD_OUT)/jxl/debug/bl31.bin
TFA_OPTEED_BL31 := $(TFA_OPTEED_OUT)/jxl/debug/bl31.bin
XEN_BIN         := $(XEN_OUT)/xen
OPTEE_TEE_RAW   := $(OPTEE_OUT)/core/tee-raw.bin

JXL_LINUX_DTB         := $(JXL_OUT)/jxl-linux.dtb
JXL_XEN_DTB           := $(JXL_OUT)/jxl-xen.dtb
JXL_OPTEE_DTB         := $(JXL_OUT)/jxl-optee.dtb
JXL_XEN_OPTEE_DTB     := $(JXL_OUT)/jxl-xen-optee.dtb
JXL_OPTEE_OVERLAY     := $(JXL_OUT)/jxl-optee-overlay.dtbo
JXL_XEN_OVERLAY_DTS   := $(JXL_OUT)/jxl-xen-overlay.dts
JXL_XEN_OVERLAY_DTBO  := $(JXL_OUT)/jxl-xen-overlay.dtbo

JXL_ENV_TXT  := $(JXL_OUT)/jxl-env.txt
JXL_ENV_BIN  := $(JXL_OUT)/jxl-env.bin

JXL_LINUX_SCR := $(JXL_OUT)/jxl-linux.scr
JXL_XEN_SCR   := $(JXL_OUT)/jxl-xen.scr

JXL_ATF_ITB        := $(JXL_OUT)/jxl-atf.itb
JXL_ATF_OPTEE_ITB  := $(JXL_OUT)/jxl-atf-optee.itb

JXL_FLASH_BLANK         := $(JXL_OUT)/jxl-flash.img
JXL_LINUX_FLASH         := $(JXL_OUT)/jxl-linux-flash.img
JXL_XEN_FLASH           := $(JXL_OUT)/jxl-xen-flash.img
JXL_LINUX_SPL_FLASH     := $(JXL_OUT)/jxl-linux-spl-flash.img
JXL_XEN_ATF_FLASH       := $(JXL_OUT)/jxl-xen-atf-flash.img
JXL_OPTEE_FLASH         := $(JXL_OUT)/jxl-optee-flash.img
JXL_XEN_OPTEE_FLASH     := $(JXL_OUT)/jxl-xen-optee-flash.img

JXL_LINUX_MMC      := $(JXL_OUT)/jxl-linux.img
JXL_XEN_MMC        := $(JXL_OUT)/jxl-xen.img
JXL_OPTEE_MMC      := $(JXL_OUT)/jxl-optee.img
JXL_XEN_OPTEE_MMC  := $(JXL_OUT)/jxl-xen-optee.img

# ---------------------------------------------------------------------
#  Memory layout and sizes
# ---------------------------------------------------------------------

JXL_FLASH_SIZE            := $(shell echo $$((16 * 1024 * 1024)))
JXL_ENV_OFFSET            := $(shell echo $$((0x7F0000)))
JXL_ENV_SIZE              := 0x10000
JXL_ENV_SIZE_DEC          := $(shell echo $$((0x10000)))
JXL_MMC_IMAGE_SIZE        := $(shell echo $$((128 * 1024 * 1024)))
JXL_MMC_BOOT_START_SECTOR := 2048

JXL_RAM_SIZE             := 2G
JXL_SCRIPT_ADDR          := 0x41f00000
JXL_KERNEL_ADDR          := 0x42000000
JXL_DTB_ADDR             := 0x44f00000
JXL_INITRD_ADDR          := 0x45000000
JXL_XEN_ADDR             := 0x92000000
JXL_XEN_DOM0_KERNEL_ADDR := 0x80000000
JXL_XEN_DOM0_INITRD_ADDR := 0x90000000
# Same physical address as DOM0 initrd; the bootscript uses both names.
JXL_XEN_INITRD_ADDR      := $(JXL_XEN_DOM0_INITRD_ADDR)
JXL_XEN_DTB_ADDR         := 0x91000000

BL31_LOAD := 0xbff90000
BL32_LOAD := 0xbf001000

# ---------------------------------------------------------------------
#  QEMU (local fork)
# ---------------------------------------------------------------------

$(QEMU_LOCAL):
	mkdir -p $(QEMU_SRC)/build
	cd $(QEMU_SRC)/build && ../configure --target-list=aarch64-softmmu --disable-docs
	ninja -C $(QEMU_SRC)/build

# ---------------------------------------------------------------------
#  U-Boot variants
# ---------------------------------------------------------------------

# Each U-Boot defconfig produces multiple files; a single recipe builds
# them together and we declare the secondary outputs as dependencies of
# the canonical artifact so make tracks them via timestamp.

$(VIRT_UBOOT):
	mkdir -p $(VIRT_OUT)
	$(MAKE) -C $(UBOOT_SRC) O=$(VIRT_OUT) CROSS_COMPILE=$(CROSS_COMPILE) qemu_arm64_defconfig
	$(MAKE) -C $(UBOOT_SRC) O=$(VIRT_OUT) CROSS_COMPILE=$(CROSS_COMPILE) -j$(JOBS)

$(RPI3_UBOOT) $(RPI3_DTB) &:
	mkdir -p $(RPI3_OUT)
	$(MAKE) -C $(UBOOT_SRC) O=$(RPI3_OUT) CROSS_COMPILE=$(CROSS_COMPILE) rpi_3_defconfig
	$(MAKE) -C $(UBOOT_SRC) O=$(RPI3_OUT) CROSS_COMPILE=$(CROSS_COMPILE) -j$(JOBS)

# Grouped target (Make 4.3+): a single U-Boot build produces all of these
# at once; declare them with `&:` so Make doesn't try to (re)build any one
# of them independently.
$(JXL_UBOOT) $(JXL_UBOOT_IMG) $(JXL_UBOOT_NODTB) $(JXL_SPL) \
$(JXL_UBOOT_DTB) $(JXL_MKIMAGE) $(JXL_MKENVIMG) &:
	mkdir -p $(JXL_OUT)
	$(MAKE) -C $(UBOOT_SRC) O=$(JXL_OUT) CROSS_COMPILE=$(CROSS_COMPILE) jxl_defconfig
	$(MAKE) -C $(UBOOT_SRC) O=$(JXL_OUT) CROSS_COMPILE=$(CROSS_COMPILE) -j$(JOBS)

# ---------------------------------------------------------------------
#  Linux kernel
# ---------------------------------------------------------------------

$(LINUX_IMAGE):
	mkdir -p $(LINUX_OUT)
	$(MAKE) -C $(LINUX_SRC) O=$(LINUX_OUT) ARCH=arm64 CROSS_COMPILE=$(CROSS_COMPILE) defconfig
	$(MAKE) -C $(LINUX_SRC) O=$(LINUX_OUT) ARCH=arm64 CROSS_COMPILE=$(CROSS_COMPILE) -j$(JOBS) Image

# ---------------------------------------------------------------------
#  BusyBox + initramfs
# ---------------------------------------------------------------------

$(BUSYBOX_BIN):
	mkdir -p $(BUSYBOX_OUT)
	$(MAKE) -C $(BUSYBOX_SRC) O=$(BUSYBOX_OUT) defconfig
	# Force static linking + drop x86-only SHA hwaccel that doesn't link on aarch64.
	sed -i \
		-e 's|.*CONFIG_STATIC[ =].*|CONFIG_STATIC=y|' \
		-e 's|.*CONFIG_SHA1_HWACCEL.*|# CONFIG_SHA1_HWACCEL is not set|' \
		-e 's|.*CONFIG_SHA256_HWACCEL.*|# CONFIG_SHA256_HWACCEL is not set|' \
		$(BUSYBOX_OUT)/.config
	yes "" | $(MAKE) -C $(BUSYBOX_SRC) O=$(BUSYBOX_OUT) ARCH=arm64 CROSS_COMPILE=$(CROSS_COMPILE) oldconfig >/dev/null
	$(MAKE) -C $(BUSYBOX_SRC) O=$(BUSYBOX_OUT) ARCH=arm64 CROSS_COMPILE=$(CROSS_COMPILE) -j$(JOBS)

define ROOTFS_INIT_BODY
#!/bin/busybox sh
/bin/busybox --install -s
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev 2>/dev/null || true
echo
echo "jxl rootfs up."
exec setsid cttyhack /bin/sh
endef

$(INITRAMFS): $(BUSYBOX_BIN)
	rm -rf $(ROOTFS_STAGE)
	mkdir -p $(ROOTFS_STAGE)/{bin,sbin,etc,proc,sys,dev,usr/bin,usr/sbin,root}
	cp $(BUSYBOX_BIN) $(ROOTFS_STAGE)/bin/busybox
	chmod +x $(ROOTFS_STAGE)/bin/busybox
	cat > $(ROOTFS_STAGE)/init <<-'EOF'
	$(value ROOTFS_INIT_BODY)
	EOF
	chmod +x $(ROOTFS_STAGE)/init
	cd $(ROOTFS_STAGE) && find . | cpio -o -H newc 2>/dev/null | gzip -9 > $@

# ---------------------------------------------------------------------
#  TF-A (BL31), with and without OP-TEE dispatcher
# ---------------------------------------------------------------------

# TF-A always rebuilds when its sources change; we don't try to track every
# .c file in a Make rule — just rebuild on demand and let TF-A's own
# Makefile do the incremental work.

$(TFA_NOSPD_BL31): FORCE
	@if [[ ! -e $(TFA_SRC)/.git ]]; then \
		echo "error: TF-A source is missing at $(TFA_SRC)" >&2; exit 1; fi
	mkdir -p $(TFA_NOSPD_OUT)
	$(MAKE) -C $(TFA_SRC) PLAT=jxl ARCH=aarch64 DEBUG=1 \
		CROSS_COMPILE=$(CROSS_COMPILE) BUILD_BASE=$(TFA_NOSPD_OUT) bl31

$(TFA_OPTEED_BL31): FORCE
	@if [[ ! -e $(TFA_SRC)/.git ]]; then \
		echo "error: TF-A source is missing at $(TFA_SRC)" >&2; exit 1; fi
	mkdir -p $(TFA_OPTEED_OUT)
	$(MAKE) -C $(TFA_SRC) PLAT=jxl ARCH=aarch64 DEBUG=1 SPD=opteed \
		CROSS_COMPILE=$(CROSS_COMPILE) BUILD_BASE=$(TFA_OPTEED_OUT) bl31

.PHONY: FORCE
FORCE:

# ---------------------------------------------------------------------
#  Xen
# ---------------------------------------------------------------------

$(XEN_BIN):
	@if [[ ! -e $(XEN_SRC)/.git ]]; then \
		echo "error: Xen source is missing at $(XEN_SRC)" >&2; exit 1; fi
	mkdir -p $(XEN_OUT)
	$(MAKE) -C $(XEN_SRC) XEN_TARGET_ARCH=arm64 CROSS_COMPILE=$(CROSS_COMPILE) \
		O=$(XEN_OUT) arm64_defconfig
	$(MAKE) -C $(XEN_SRC) XEN_TARGET_ARCH=arm64 CROSS_COMPILE=$(CROSS_COMPILE) \
		O=$(XEN_OUT) build-xen -j$(JOBS)

# ---------------------------------------------------------------------
#  OP-TEE
# ---------------------------------------------------------------------

$(OPTEE_TEE_RAW):
	@if [[ ! -e $(OPTEE_SRC)/.git ]]; then \
		echo "error: OP-TEE source is missing at $(OPTEE_SRC)" >&2; exit 1; fi
	mkdir -p $(OPTEE_OUT)
	$(MAKE) -C $(OPTEE_SRC) PLATFORM=vexpress PLATFORM_FLAVOR=jxl \
		CFG_ARM64_core=y CROSS_COMPILE=$(CROSS_COMPILE) O=$(OPTEE_OUT) -j$(JOBS)

# ---------------------------------------------------------------------
#  JXL Linux DTB and overlays
# ---------------------------------------------------------------------

$(JXL_LINUX_DTB): $(DTS_DIR)/jxl.dts $(DTS_DIR)/jxl.dtsi
	mkdir -p $(JXL_OUT)
	dtc -I dts -O dtb -o $@ $<

# Xen overlay carries the runtime kernel/initrd sizes, so the .dts is
# regenerated whenever those payloads change.
$(JXL_XEN_OVERLAY_DTS): $(LINUX_IMAGE) $(INITRAMFS)
	mkdir -p $(JXL_OUT)
	kernel_size=$$(stat -c%s $(LINUX_IMAGE))
	initrd_size=$$(stat -c%s $(INITRAMFS))
	cat > $@ <<-EOF
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
					reg = <0x0 $(JXL_XEN_DOM0_KERNEL_ADDR) 0x0 0x$$(printf '%x' "$$kernel_size")>;
					bootargs = "console=hvc0 earlycon=xen rdinit=/init";
				};

				module@46000000 {
					compatible = "multiboot,ramdisk", "multiboot,module";
					reg = <0x0 $(JXL_XEN_DOM0_INITRD_ADDR) 0x0 0x$$(printf '%x' "$$initrd_size")>;
				};
			};
		};
	};
	EOF

$(JXL_XEN_OVERLAY_DTBO): $(JXL_XEN_OVERLAY_DTS)
	dtc -@ -I dts -O dtb -o $@ $<

$(JXL_XEN_DTB): $(JXL_LINUX_DTB) $(JXL_XEN_OVERLAY_DTBO)
	fdtoverlay -i $(JXL_LINUX_DTB) -o $@ $(JXL_XEN_OVERLAY_DTBO)

$(JXL_OPTEE_OVERLAY): $(DTS_DIR)/jxl-optee-overlay.dts
	mkdir -p $(JXL_OUT)
	dtc -@ -I dts -O dtb -o $@ $<

$(JXL_OPTEE_DTB): $(JXL_LINUX_DTB) $(JXL_OPTEE_OVERLAY)
	fdtoverlay -i $(JXL_LINUX_DTB) -o $@ $(JXL_OPTEE_OVERLAY)

$(JXL_XEN_OPTEE_DTB): $(JXL_XEN_DTB) $(JXL_OPTEE_OVERLAY)
	fdtoverlay -i $(JXL_XEN_DTB) -o $@ $(JXL_OPTEE_OVERLAY)

# ---------------------------------------------------------------------
#  JXL U-Boot environment blob (CRC-correct, pinned to flash env area)
# ---------------------------------------------------------------------

define JXL_ENV_TXT_BODY
bootcmd=source 0x41f00000
bootdelay=3
bootargs=console=ttyAMA0 earlycon root=/dev/mmcblk0p1 rootfstype=ext4 rw init=/init
endef

$(JXL_ENV_TXT): $(JXL_MKENVIMG)
	mkdir -p $(JXL_OUT)
	$(file >$@,$(JXL_ENV_TXT_BODY))

$(JXL_ENV_BIN): $(JXL_ENV_TXT) $(JXL_MKENVIMG)
	$(JXL_MKENVIMG) -s $(JXL_ENV_SIZE) -p 0xff -o $@ $(JXL_ENV_TXT)

# ---------------------------------------------------------------------
#  JXL flash images (blank with env, or SPL-populated)
# ---------------------------------------------------------------------

# The blank flash recipe is shared via a canned recipe; each flash file
# target uses it.
define jxl_blank_flash
	mkdir -p $$(dirname $@)
	perl -e "print qq(\\xFF) x $(JXL_FLASH_SIZE)" > $@
	dd if=$(JXL_ENV_BIN) of=$@ bs=$(JXL_ENV_SIZE_DEC) \
	   seek=$$(( $(JXL_ENV_OFFSET) / $(JXL_ENV_SIZE_DEC) )) count=1 \
	   conv=notrunc status=none
endef

$(JXL_FLASH_BLANK) $(JXL_LINUX_FLASH) $(JXL_XEN_FLASH): $(JXL_ENV_BIN)
	$(jxl_blank_flash)

# SPL boot flash: blank flash + payload at offset 0.
define jxl_spl_flash
	payload_size=$$(stat -c%s $(1))
	max_payload=$$(( $(JXL_FLASH_SIZE) - 0x10000 ))
	if (( payload_size > max_payload )); then
		echo "error: $(1) is too large for JXL flash boot area" >&2
		exit 1
	fi
	mkdir -p $$(dirname $@)
	perl -e "print qq(\\xFF) x $(JXL_FLASH_SIZE)" > $@
	dd if=$(JXL_ENV_BIN) of=$@ bs=$(JXL_ENV_SIZE_DEC) \
	   seek=$$(( $(JXL_ENV_OFFSET) / $(JXL_ENV_SIZE_DEC) )) count=1 \
	   conv=notrunc status=none
	dd if=$(1) of=$@ conv=notrunc status=none
endef

$(JXL_LINUX_SPL_FLASH): $(JXL_UBOOT_IMG) $(JXL_ENV_BIN)
	$(call jxl_spl_flash,$(JXL_UBOOT_IMG))

$(JXL_XEN_ATF_FLASH): $(JXL_ATF_ITB) $(JXL_ENV_BIN)
	$(call jxl_spl_flash,$(JXL_ATF_ITB))

$(JXL_OPTEE_FLASH) $(JXL_XEN_OPTEE_FLASH): $(JXL_ATF_OPTEE_ITB) $(JXL_ENV_BIN)
	$(call jxl_spl_flash,$(JXL_ATF_OPTEE_ITB))

# ---------------------------------------------------------------------
#  JXL MMC images (ext4 partition with kernel + dtb + initramfs [+ xen])
# ---------------------------------------------------------------------

# $(1) = output image, $(2) = staging dir, $(3) = label,
# $(4) = list of "src:name" pairs to drop into the partition root,
# $(5) = optional rootfs staging directory whose contents are copied in.
define jxl_mmc_image
	out_dir=$$(dirname $(1))
	stage=$(2)
	bootfs=$$out_dir/$$(basename $(2)).ext4
	total_sectors=$$(( $(JXL_MMC_IMAGE_SIZE) / 512 ))
	start_sector=$(JXL_MMC_BOOT_START_SECTOR)
	boot_sectors=$$(( total_sectors - start_sector ))
	boot_bytes=$$(( boot_sectors * 512 ))
	mkdir -p "$$out_dir"
	rm -rf "$$stage"
	rm -f "$$bootfs"
	mkdir -p "$$stage"
	$(foreach pair,$(4),cp "$(firstword $(subst :, ,$(pair)))" "$$stage/$(lastword $(subst :, ,$(pair)))"
	)
	$(if $(5),cp -a $(5)/. "$$stage/")
	truncate -s "$$boot_bytes" "$$bootfs"
	mkfs.ext4 -q -F -O ^metadata_csum,^64bit -d "$$stage" -L $(3) "$$bootfs"
	truncate -s $(JXL_MMC_IMAGE_SIZE) $(1)
	sfdisk --wipe always --wipe-partitions always $(1) >/dev/null <<-EOF
	label: dos
	unit: sectors

	$$start_sector,$$boot_sectors,L,*
	EOF
	dd if="$$bootfs" of=$(1) bs=512 seek=$$start_sector conv=notrunc status=none
endef

$(JXL_LINUX_MMC): $(LINUX_IMAGE) $(JXL_LINUX_DTB) $(INITRAMFS)
	$(call jxl_mmc_image,$@,$(JXL_OUT)/jxl-mmc-boot,JXLBOOT,\
	  $(LINUX_IMAGE):Image \
	  $(JXL_LINUX_DTB):jxl-linux.dtb,\
	  $(ROOTFS_STAGE))

$(JXL_XEN_MMC): $(LINUX_IMAGE) $(JXL_XEN_DTB) $(INITRAMFS) $(XEN_BIN)
	$(call jxl_mmc_image,$@,$(JXL_OUT)/jxl-xen-mmc-boot,JXLBOOT,\
	  $(LINUX_IMAGE):Image \
	  $(JXL_XEN_DTB):jxl-xen.dtb \
	  $(XEN_BIN):xen,\
	  $(ROOTFS_STAGE))

# OP-TEE variants reuse the same on-disk filenames as the non-OP-TEE
# variants (jxl-linux.dtb / jxl-xen.dtb), just with the overlay-augmented
# DTB content; this lets the existing boot scripts work unchanged.
$(JXL_OPTEE_MMC): $(LINUX_IMAGE) $(JXL_OPTEE_DTB) $(INITRAMFS)
	$(call jxl_mmc_image,$@,$(JXL_OUT)/jxl-optee-mmc-boot,JXLBOOT,\
	  $(LINUX_IMAGE):Image \
	  $(JXL_OPTEE_DTB):jxl-linux.dtb,\
	  $(ROOTFS_STAGE))

$(JXL_XEN_OPTEE_MMC): $(LINUX_IMAGE) $(JXL_XEN_OPTEE_DTB) $(INITRAMFS) $(XEN_BIN)
	$(call jxl_mmc_image,$@,$(JXL_OUT)/jxl-xen-optee-mmc-boot,JXLBOOT,\
	  $(LINUX_IMAGE):Image \
	  $(JXL_XEN_OPTEE_DTB):jxl-xen.dtb \
	  $(XEN_BIN):xen,\
	  $(ROOTFS_STAGE))

# ---------------------------------------------------------------------
#  U-Boot bootscripts (.scr from a heredoc + mkimage wrap)
# ---------------------------------------------------------------------

define JXL_LINUX_CMD_BODY
echo "JXL: booting Linux from ext4 MMC rootfs"
setenv kernel_addr_r $(JXL_KERNEL_ADDR)
setenv fdt_addr_r $(JXL_DTB_ADDR)
mmc dev 0
ext4load mmc 0:1 $${kernel_addr_r} /Image
ext4load mmc 0:1 $${fdt_addr_r} /jxl-linux.dtb
echo "  kernel : $${kernel_addr_r}"
echo "  fdt    : $${fdt_addr_r}"
booti $${kernel_addr_r} - $${fdt_addr_r}
endef

$(JXL_LINUX_SCR): $(JXL_MKIMAGE)
	mkdir -p $(JXL_OUT)
	$(file >$(JXL_OUT)/jxl-linux.cmd,$(JXL_LINUX_CMD_BODY))
	$(JXL_MKIMAGE) -A arm64 -T script -C none -n "jxl linux boot" \
		-d $(JXL_OUT)/jxl-linux.cmd $@ >/dev/null

define JXL_XEN_CMD_BODY
echo JXL: booting Xen + Dom0 from ext4 MMC rootfs
setenv xen_addr_r $(JXL_XEN_ADDR)
setenv loadaddr $(JXL_XEN_ADDR)
setenv dom0_kernel_addr_r $(JXL_XEN_DOM0_KERNEL_ADDR)
setenv kernel_addr_r $(JXL_XEN_DOM0_KERNEL_ADDR)
setenv fdt_addr_r $(JXL_XEN_DTB_ADDR)
setenv bootargs
mmc dev 0
ext4load mmc 0:1 $${xen_addr_r} /xen
ext4load mmc 0:1 $${dom0_kernel_addr_r} /Image
ext4load mmc 0:1 $${fdt_addr_r} /jxl-xen.dtb
echo xen: $${xen_addr_r}
echo dom0: $${dom0_kernel_addr_r}
echo fdt: $${fdt_addr_r}
booti $${xen_addr_r} - $${fdt_addr_r}
endef

$(JXL_XEN_SCR): $(JXL_MKIMAGE)
	mkdir -p $(JXL_OUT)
	$(file >$(JXL_OUT)/jxl-xen.cmd,$(JXL_XEN_CMD_BODY))
	$(JXL_MKIMAGE) -A arm64 -T script -C none -n "jxl xen boot" \
		-d $(JXL_OUT)/jxl-xen.cmd $@ >/dev/null

# ---------------------------------------------------------------------
#  FIT images for SPL → BL31 [→ OP-TEE] → U-Boot chains
# ---------------------------------------------------------------------

define JXL_ATF_ITS_BODY
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
			data = /incbin/("$(TFA_NOSPD_BL31)");
			type = "firmware";
			os = "arm-trusted-firmware";
			arch = "arm64";
			compression = "none";
			load = <$(BL31_LOAD)>;
			entry = <$(BL31_LOAD)>;
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
endef

$(JXL_ATF_ITB): $(TFA_NOSPD_BL31) $(JXL_UBOOT_NODTB) $(JXL_UBOOT_DTB) $(JXL_MKIMAGE)
	mkdir -p $(JXL_OUT)
	$(file >$(JXL_OUT)/jxl-atf.its,$(JXL_ATF_ITS_BODY))
	cd $(JXL_OUT) && ./tools/mkimage -f jxl-atf.its $(notdir $@) >/dev/null

define JXL_ATF_OPTEE_ITS_BODY
/dts-v1/;

/ {
	description = "JXL SPL -> BL31 -> OP-TEE -> U-Boot FIT";
	#address-cells = <1>;

	images {
		uboot {
			description = "U-Boot proper (BL33)";
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
			data = /incbin/("$(TFA_OPTEED_BL31)");
			type = "firmware";
			os = "arm-trusted-firmware";
			arch = "arm64";
			compression = "none";
			load = <$(BL31_LOAD)>;
			entry = <$(BL31_LOAD)>;
			hash {
				algo = "sha256";
			};
		};

		tee {
			description = "OP-TEE (BL32)";
			data = /incbin/("$(OPTEE_TEE_RAW)");
			type = "firmware";
			os = "tee";
			arch = "arm64";
			compression = "none";
			load = <$(BL32_LOAD)>;
			entry = <$(BL32_LOAD)>;
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
			description = "BL31 -> OP-TEE -> U-Boot";
			firmware = "atf";
			loadables = "uboot", "tee";
			fdt = "fdt-0";
		};
	};
};
endef

$(JXL_ATF_OPTEE_ITB): $(TFA_OPTEED_BL31) $(OPTEE_TEE_RAW) $(JXL_UBOOT_NODTB) $(JXL_UBOOT_DTB) $(JXL_MKIMAGE)
	mkdir -p $(JXL_OUT)
	$(file >$(JXL_OUT)/jxl-atf-optee.its,$(JXL_ATF_OPTEE_ITS_BODY))
	cd $(JXL_OUT) && ./tools/mkimage -f jxl-atf-optee.its $(notdir $@) >/dev/null

# ---------------------------------------------------------------------
#  Build aliases (file-target wrappers matching ./build.sh subcommands)
# ---------------------------------------------------------------------

.PHONY: build-qemu build-virt build-raspi3b build-jxl build-jxl-dtb \
        build-tfa build-tfa-opteed build-xen build-optee build-kernel \
        build-busybox build-rootfs build-all

build-qemu:        $(QEMU_LOCAL)
build-virt:        $(VIRT_UBOOT)
build-raspi3b:     $(RPI3_UBOOT) $(RPI3_DTB)
build-jxl:         $(JXL_UBOOT) $(JXL_UBOOT_IMG) $(JXL_SPL)
build-jxl-dtb:     $(JXL_LINUX_DTB)
build-tfa:         $(TFA_NOSPD_BL31)
build-tfa-opteed:  $(TFA_OPTEED_BL31)
build-xen:         $(XEN_BIN)
build-optee:       $(OPTEE_TEE_RAW)
build-kernel:      $(LINUX_IMAGE)
build-busybox:     $(BUSYBOX_BIN)
build-rootfs:      $(INITRAMFS)
build-all:         build-jxl build-jxl-dtb build-kernel build-rootfs

# ---------------------------------------------------------------------
#  Run aliases (boot a chain in QEMU)
# ---------------------------------------------------------------------

.PHONY: run-virt run-raspi3b run-jxl run-jxl-linux run-jxl-linux-spl \
        run-jxl-xen run-jxl-xen-atf run-jxl-optee run-jxl-xen-optee run-linux

run-virt: $(VIRT_UBOOT)
	exec $(QEMU) \
		-machine virt -cpu cortex-a57 -nographic \
		-bios $(VIRT_UBOOT)

run-raspi3b: $(RPI3_UBOOT) $(RPI3_DTB)
	exec $(QEMU) \
		-machine raspi3b -cpu cortex-a53 -display none \
		-serial null -serial stdio \
		-kernel $(RPI3_UBOOT) -dtb $(RPI3_DTB)

run-jxl: $(JXL_UBOOT) $(JXL_FLASH_BLANK)
	exec $(QEMU) \
		-machine jxl -cpu cortex-a53 -m $(JXL_RAM_SIZE) -nographic \
		-drive if=pflash,format=raw,file=$(JXL_FLASH_BLANK) \
		-kernel $(JXL_UBOOT)

run-jxl-linux: $(JXL_UBOOT) $(JXL_LINUX_FLASH) $(JXL_LINUX_MMC) $(JXL_LINUX_SCR)
	exec $(QEMU) \
		-machine jxl -cpu cortex-a53 -m $(JXL_RAM_SIZE) -nographic \
		-drive if=pflash,format=raw,file=$(JXL_LINUX_FLASH) \
		-drive if=sd,format=raw,cache=writethrough,file=$(JXL_LINUX_MMC) \
		-device loader,file=$(JXL_LINUX_SCR),addr=$(JXL_SCRIPT_ADDR),force-raw=on \
		-kernel $(JXL_UBOOT)

run-jxl-linux-spl: $(JXL_SPL) $(JXL_LINUX_SPL_FLASH) $(JXL_LINUX_MMC) $(JXL_LINUX_SCR)
	exec $(QEMU) \
		-machine jxl -cpu cortex-a53 -m $(JXL_RAM_SIZE) -nographic \
		-drive if=pflash,format=raw,file=$(JXL_LINUX_SPL_FLASH) \
		-drive if=sd,format=raw,cache=writethrough,file=$(JXL_LINUX_MMC) \
		-device loader,file=$(JXL_LINUX_SCR),addr=$(JXL_SCRIPT_ADDR),force-raw=on \
		-bios $(JXL_SPL)

run-jxl-xen: $(JXL_UBOOT) $(JXL_XEN_FLASH) $(JXL_XEN_MMC) $(JXL_XEN_SCR)
	exec $(QEMU) \
		-machine jxl -cpu cortex-a53 -m $(JXL_RAM_SIZE) -nographic \
		-drive if=pflash,format=raw,file=$(JXL_XEN_FLASH) \
		-drive if=sd,format=raw,cache=writethrough,file=$(JXL_XEN_MMC) \
		-device loader,file=$(JXL_XEN_SCR),addr=$(JXL_SCRIPT_ADDR),force-raw=on \
		-kernel $(JXL_UBOOT)

run-jxl-xen-atf: $(JXL_SPL) $(JXL_XEN_ATF_FLASH) $(JXL_XEN_MMC) $(JXL_XEN_SCR)
	exec $(QEMU) \
		-machine jxl,secure=on -cpu cortex-a53 -m $(JXL_RAM_SIZE) -nographic \
		-drive if=pflash,format=raw,file=$(JXL_XEN_ATF_FLASH) \
		-drive if=sd,format=raw,cache=writethrough,file=$(JXL_XEN_MMC) \
		-device loader,file=$(JXL_XEN_SCR),addr=$(JXL_SCRIPT_ADDR),force-raw=on \
		-bios $(JXL_SPL)

run-jxl-optee: $(JXL_SPL) $(JXL_OPTEE_FLASH) $(JXL_OPTEE_MMC) $(JXL_LINUX_SCR)
	exec $(QEMU) \
		-machine jxl,secure=on -cpu cortex-a53 -m $(JXL_RAM_SIZE) -nographic \
		-drive if=pflash,format=raw,file=$(JXL_OPTEE_FLASH) \
		-drive if=sd,format=raw,cache=writethrough,file=$(JXL_OPTEE_MMC) \
		-device loader,file=$(JXL_LINUX_SCR),addr=$(JXL_SCRIPT_ADDR),force-raw=on \
		-bios $(JXL_SPL)

run-jxl-xen-optee: $(JXL_SPL) $(JXL_XEN_OPTEE_FLASH) $(JXL_XEN_OPTEE_MMC) $(JXL_XEN_SCR)
	exec $(QEMU) \
		-machine jxl,secure=on -cpu cortex-a53 -m $(JXL_RAM_SIZE) -nographic \
		-drive if=pflash,format=raw,file=$(JXL_XEN_OPTEE_FLASH) \
		-drive if=sd,format=raw,cache=writethrough,file=$(JXL_XEN_OPTEE_MMC) \
		-device loader,file=$(JXL_XEN_SCR),addr=$(JXL_SCRIPT_ADDR),force-raw=on \
		-bios $(JXL_SPL)

run-linux: $(LINUX_IMAGE) $(INITRAMFS)
	exec $(QEMU) \
		-machine virt -cpu cortex-a57 -m 512M -nographic \
		-kernel $(LINUX_IMAGE) -initrd $(INITRAMFS) \
		-append "console=ttyAMA0 earlycon"

# ---------------------------------------------------------------------
#  Cleaning
# ---------------------------------------------------------------------

# Match start.sh's --clean: firmware / U-Boot / jxl artifacts only,
# leaving linux / busybox / initramfs cached for fast iteration.
.PHONY: clean distclean
clean:
	rm -rf $(JXL_OUT) $(VIRT_OUT) $(RPI3_OUT) \
	       $(TFA_NOSPD_OUT) $(TFA_OPTEED_OUT) \
	       $(OPTEE_OUT) $(XEN_OUT)

distclean:
	rm -rf $(BUILD_ROOT)

# ---------------------------------------------------------------------
#  Help
# ---------------------------------------------------------------------

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Build artifacts:"
	@echo "  make build-qemu              local QEMU fork (qemu-system-aarch64)"
	@echo "  make build-virt              U-Boot for qemu virt"
	@echo "  make build-raspi3b           U-Boot for qemu raspi3b"
	@echo "  make build-jxl               U-Boot for the jxl machine"
	@echo "  make build-jxl-dtb           standalone Linux DTB for jxl"
	@echo "  make build-tfa               TF-A BL31 (no SPD)"
	@echo "  make build-tfa-opteed        TF-A BL31 with SPD=opteed"
	@echo "  make build-xen               Xen arm64 hypervisor"
	@echo "  make build-optee             OP-TEE (vexpress-jxl) BL32"
	@echo "  make build-kernel            Linux kernel arm64 defconfig"
	@echo "  make build-busybox           BusyBox (static)"
	@echo "  make build-rootfs            initramfs.cpio.gz"
	@echo "  make build-all               jxl uboot + dtb + kernel + rootfs"
	@echo
	@echo "Run a chain in QEMU:"
	@echo "  make run-virt"
	@echo "  make run-raspi3b"
	@echo "  make run-jxl"
	@echo "  make run-jxl-linux"
	@echo "  make run-jxl-linux-spl"
	@echo "  make run-jxl-xen"
	@echo "  make run-jxl-xen-atf"
	@echo "  make run-jxl-optee"
	@echo "  make run-jxl-xen-optee"
	@echo "  make run-linux"
	@echo
	@echo "Clean:"
	@echo "  make clean       firmware / U-Boot / jxl artifacts (keeps linux/rootfs cache)"
	@echo "  make distclean   wipe entire build/"
