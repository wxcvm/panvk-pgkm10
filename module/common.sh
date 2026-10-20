#!/system/bin/sh
# Shared helpers for the WSI7 global-enable module. Sourced by post-fs-data.sh.

GPU_TARGET=/vendor/lib64/hw/mt6895/vulkan.mali.so
COLORX_TARGET=/system_ext/lib64/libvulkanextimpl.so

# Pinned hashes: driver payload, OEM baseline, ColorX copy and its patched result.
GPU_SHA=5eb3899da6f16a7f6b7e80aab1a693da032831d4db1c99817fbcc1f160a3d4a6
OEM_SHA=2ae46e5c85ff73ab3441b1acbd12e60d50247b0be56a19a825e2fae66050c5b0
COLORX_SHA=3835dd76a8e6536d53c638467bf9785897802ad96867ecaf9f539b1085707fe5
COLORX_PATCHED_SHA=16c93822969608ce3662e3d01725438b1ab88d6c2c6c8b54bef9b2c0419db0b8
ALIGN_PROP=debug.mesa.movecert.afbc.align

check_hash() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    sha256sum "$1" | grep -q "^$2" || return 1
}

check_platform() {
    [ "$(getprop ro.product.model)" = PGKM10 ] || return 1
    [ "$(getprop ro.build.version.sdk)" = 37 ] || return 1
    check_hash "$GPU_TARGET" "$OEM_SHA" || return 1
    check_hash "$COLORX_TARGET" "$COLORX_SHA" || return 1
}

# Build a private ColorX compatibility copy on the device; never ship or overwrite
# OEM binaries. The byte patch makes ColorxExcludedProcess return true.
prepare_colorx() {
    check_hash "$COLORX_TARGET" "$COLORX_SHA" || return 1
    local_tmp="$MODDIR/colorx.tmp"
    [ ! -L "$local_tmp" ] && [ ! -L "$MODDIR/colorx-excluded.so" ] || return 1
    cp "$COLORX_TARGET" "$local_tmp" || return 1
    printf '\137\044\003\325\040\000\200\122\300\003\137\326' |
        dd of="$local_tmp" bs=1 seek=46608 conv=notrunc 2>/dev/null || return 1
    check_hash "$local_tmp" "$COLORX_PATCHED_SHA" || return 1
    chmod 600 "$local_tmp" || return 1
    mv -f "$local_tmp" "$MODDIR/colorx-excluded.so" || return 1
    chcon u:object_r:system_file:s0 "$MODDIR/colorx-excluded.so" 2>/dev/null || true
}
