#!/system/bin/sh
# Global PanVK (wsi7) test launcher with fail-safe.
# - mounts the experimental ICD + ColorX compatibility copy system-wide
# - counts boots; after 3 non-successful boots it disables itself
# - verifies the OEM baseline before touching anything
MODDIR=${0%/*}
LOG="$MODDIR/log.txt"
exec >>"$LOG" 2>&1
echo "=== $(date) post-fs-data ==="

OEM_GPU=2ae46e5c85ff73ab3441b1acbd12e60d50247b0be56a19a825e2fae66050c5b0
OEM_EXT=3835dd76a8e6536d53c638467bf9785897802ad96867ecaf9f539b1085707fe5
DRV_SHA=9c0df1a352a9100da6fb9dfde1533486a736c58d625719f6edc54ad614ef5aec
CX_SHA=16c93822969608ce3662e3d01725438b1ab88d6c2c6c8b54bef9b2c0419db0b8
GPU=/vendor/lib64/hw/mt6895/vulkan.mali.so
EXT=/system_ext/lib64/libvulkanextimpl.so

check_hash() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    sha256sum "$1" | grep -q "^$2" || return 1
}

attempt=1
[ -f "$MODDIR/attempt" ] && attempt=$(( $(cat "$MODDIR/attempt") + 1 ))
echo "$attempt" > "$MODDIR/attempt"

if [ -f "$MODDIR/boot-ok" ]; then
    rm -f "$MODDIR/boot-ok"
    attempt=1
    echo 1 > "$MODDIR/attempt"
    echo "previous boot completed; attempt reset"
fi

if [ "$attempt" -ge 3 ]; then
    echo "FAIL-SAFE: $attempt boots without completion; disabling module"
    touch "$MODDIR/disable"
    rm -f "$MODDIR/attempt"
    exit 0
fi

check_hash "$GPU" "$OEM_GPU" || { echo "STOP: OEM gpu hash mismatch"; exit 1; }
check_hash "$EXT" "$OEM_EXT" || { echo "STOP: OEM ext hash mismatch"; exit 1; }
check_hash "$MODDIR/vulkan.mali.so" "$DRV_SHA" || { echo "STOP: driver hash mismatch"; exit 1; }
check_hash "$MODDIR/colorx-excluded.so" "$CX_SHA" || { echo "STOP: colorx copy hash mismatch"; exit 1; }

chown 0:0 "$MODDIR/vulkan.mali.so" "$MODDIR/colorx-excluded.so"
chmod 644 "$MODDIR/vulkan.mali.so" "$MODDIR/colorx-excluded.so"
chcon u:object_r:same_process_hal_file:s0 "$MODDIR/vulkan.mali.so" || exit 1
chcon u:object_r:system_file:s0 "$MODDIR/colorx-excluded.so" || exit 1

mount -o bind "$MODDIR/colorx-excluded.so" "$EXT" || { echo "STOP: ext bind failed"; exit 1; }
if ! mount -o bind "$MODDIR/vulkan.mali.so" "$GPU"; then
    echo "STOP: gpu bind failed; unmounting ext"
    umount "$EXT"
    exit 1
fi

check_hash "$GPU" "$DRV_SHA" || { echo "STOP: post-bind gpu verify failed"; umount "$GPU"; umount "$EXT"; exit 1; }
check_hash "$EXT" "$CX_SHA" || { echo "STOP: post-bind ext verify failed"; umount "$GPU"; umount "$EXT"; exit 1; }

setprop debug.mesa.movecert.acq.replay true
setprop debug.mesa.movecert.afbc.align true
setprop debug.mesa.movecert.sync.trace true
echo "mounted wsi7 globally (attempt $attempt)"
