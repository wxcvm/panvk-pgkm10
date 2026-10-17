#!/system/bin/sh
# post-fs-data stage.
#   scope=system: bind into the init namespace here (all processes). Kept for experiments
#   and guarded by a fail-safe; it is NOT the recommended mode because SurfaceFlinger can
#   abort on 10-bit compressed video layers (P010/compressed YU10) at the unlock screen.
#   scope=apps: do nothing here; the ICD is bound into the app spawn namespaces in service.sh.
MODDIR=${0%/*}
. "$MODDIR/common.sh"
exec >>"$MODDIR/log.txt" 2>&1
echo "=== $(date) post-fs-data ==="

conf="$MODDIR/driver.conf"
read_conf() { sed -n "s/^$1=//p" "$conf" | head -1; }
enable_global=$(read_conf enable_global)
scope=$(read_conf scope)
if [ "$enable_global" != 1 ]; then
    echo "enable_global=$enable_global: OEM Vulkan retained"
    exit 0
fi
if [ "$scope" != system ]; then
    echo "scope=$scope: system-wide mount skipped; apps-scope bind deferred to service.sh"
    exit 0
fi

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
    echo "FAIL-SAFE: $attempt boots without completion; setting enable_global=0"
    sed -i 's/^enable_global=.*/enable_global=0/' "$conf" 2>/dev/null || true
    rm -f "$MODDIR/attempt"
    exit 0
fi

check_platform || { echo "STOP: unsupported platform or OEM baseline mismatch"; exit 1; }
check_hash "$MODDIR/vulkan.mali.so" "$GPU_SHA" || { echo "STOP: driver payload mismatch"; exit 1; }
prepare_colorx || { echo "STOP: ColorX compatibility copy unavailable"; exit 1; }

chown 0:0 "$MODDIR/vulkan.mali.so" "$MODDIR/colorx-excluded.so"
chmod 644 "$MODDIR/vulkan.mali.so" "$MODDIR/colorx-excluded.so"
chcon u:object_r:same_process_hal_file:s0 "$MODDIR/vulkan.mali.so" || exit 1
chcon u:object_r:system_file:s0 "$MODDIR/colorx-excluded.so" || exit 1

mount -o bind "$MODDIR/colorx-excluded.so" "$COLORX_TARGET" || { echo "STOP: ext bind failed"; exit 1; }
if ! mount -o bind "$MODDIR/vulkan.mali.so" "$GPU_TARGET"; then
    echo "STOP: gpu bind failed; unmounting ext"
    umount "$COLORX_TARGET"
    exit 1
fi
check_hash "$GPU_TARGET" "$GPU_SHA" || { echo "STOP: post-bind gpu verify failed"; umount "$GPU_TARGET"; umount "$COLORX_TARGET"; exit 1; }
check_hash "$COLORX_TARGET" "$COLORX_PATCHED_SHA" || { echo "STOP: post-bind ext verify failed"; umount "$GPU_TARGET"; umount "$COLORX_TARGET"; exit 1; }

[ "$(read_conf acq_replay)" = 0 ] || setprop debug.mesa.movecert.acq.replay true
[ "$(read_conf afbc_align)" = 0 ] || setprop "$ALIGN_PROP" true
echo "mounted wsi7 system-wide (attempt $attempt)"
