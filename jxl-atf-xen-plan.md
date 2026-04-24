# JXL ATF + Xen Integration Notes

This repository now carries the upstream sources for:

- `src/trusted-firmware-a`
- `src/xen`

The intended long-term boot chain for `jxl` is:

`BootROM (QEMU load) -> SPL -> BL31 (TF-A) -> U-Boot proper -> Xen -> Dom0 Linux`

## Current State

- `jxl-linux`:
  `QEMU -> U-Boot proper -> Linux`
- `jxl-linux-spl`:
  `SPL -> U-Boot proper -> Linux`

## Near-Term Integration Plan

1. Enable `EL3` and `EL2` in the QEMU `jxl` CPU model, but only for the
   ATF/Xen boot path so the current direct/SPL flows keep working.
2. Teach `jxl` SPL to load `BL31 + BL33` instead of only `U-Boot proper`.
3. Build a `jxl`-specific TF-A BL31 image instead of the current reference
   `PLAT=qemu` helper build.
4. Teach U-Boot proper to launch Xen with:
   - Xen image
   - Dom0 kernel
   - Dom0 DTB
   - Dom0 initramfs
5. Add a Xen-adjusted Dom0 DT flow for `jxl`.

## Build Helpers

The repository now exposes two new helper targets:

- `./build.sh tfa`
  Builds a reference `qemu` BL31 into `build/tfa/qemu/debug/bl31.bin`
- `./build.sh xen`
  Builds the Xen ARM64 hypervisor into `build/xen/xen`

These helpers are mainly to get the source and toolchain flow wired up.
They are not yet sufficient to boot ATF or Xen on the custom `jxl` machine.
