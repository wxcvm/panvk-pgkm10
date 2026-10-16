#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"
umask 077
exec > "$MODDIR/driver.log" 2>&1
echo 'Experimental WSI3 launcher'
setting=$(cat "$MODDIR/driver.conf")
[ "$setting" = enable_global=1 ] || { echo 'OFF: OEM retained'; exit 0; }
check_platform || { echo 'STOP: unsupported OEM build or conflicting mount'; exit 1; }
check_hash "$MODDIR/vulkan.mali.so" "$GPU_SHA" || { echo 'STOP: WSI3 hash mismatch'; exit 1; }
check_hash "$MODDIR/colorx-excluded.so" "$COLORX_PATCHED_SHA" || {
    prepare_colorx || { echo 'STOP: ColorX compatibility copy unavailable'; exit 1; }
}
# Keep properties belonging to other modules intact; refuse a combined experiment.
for option in debug.mesa.movecert.wsi.cpu debug.mesa.movecert.wsi.flush; do
    value=$(getprop "$option")
    case "$value" in ''|false|0) ;; *) echo "STOP: conflicting option $option"; exit 1 ;; esac
done
chmod 644 "$MODDIR/vulkan.mali.so" "$MODDIR/colorx-excluded.so" || exit 1
chown 0:0 "$MODDIR/vulkan.mali.so" "$MODDIR/colorx-excluded.so" || exit 1
if [ "$(getenforce)" = Enforcing ]; then
    chcon u:object_r:same_process_hal_file:s0 "$MODDIR/vulkan.mali.so" || exit 1
    chcon u:object_r:system_file:s0 "$MODDIR/colorx-excluded.so" || exit 1
fi
original_align=$(getprop "$ALIGN_PROP")
gpu_bound=0
colorx_bound=0
success=0
rollback() {
    [ "$success" = 0 ] || return 0
    if [ "$gpu_bound" = 1 ]; then umount "$GPU_TARGET" || echo 'ERROR: GPU unmount failed; disable module and reboot'; fi
    if [ "$colorx_bound" = 1 ]; then umount "$COLORX_TARGET" || echo 'ERROR: ColorX unmount failed; disable module and reboot'; fi
    setprop "$ALIGN_PROP" "$original_align" || echo 'ERROR: property restoration failed'
    echo 'Activation failed; rollback attempted'
}
trap rollback EXIT
trap 'exit 1' HUP INT TERM
setprop "$ALIGN_PROP" true && [ "$(getprop "$ALIGN_PROP")" = true ] || exit 1
mount -o bind "$MODDIR/colorx-excluded.so" "$COLORX_TARGET" || exit 1
colorx_bound=1
mount -o bind "$MODDIR/vulkan.mali.so" "$GPU_TARGET" || exit 1
gpu_bound=1
check_hash "$COLORX_TARGET" "$COLORX_PATCHED_SHA" && check_hash "$GPU_TARGET" "$GPU_SHA" || exit 1
success=1
echo 'WSI3 and ColorX compatibility copy verified; AFBC body alignment enabled'
echo 'Original HWC composition, OpenGL/EGL and 32-bit Vulkan retained'
