#!/system/bin/sh
# Late-start service stage.
#   scope=apps: bind the pinned ICD + device-generated ColorX copy into the app spawn
#   namespaces (zygote/usap) so every newly started app uses PanVK while SurfaceFlinger,
#   system_server and other system processes keep the OEM driver. This avoids the
#   SurfaceFlinger P010/compressed-YU10 abort seen with a system-wide mount.
#   Also marks a successful boot for the scope=system fail-safe.
MODDIR=${0%/*}
. "$MODDIR/common.sh"
exec >>"$MODDIR/log.txt" 2>&1
echo "=== $(date) service ==="

conf="$MODDIR/driver.conf"
read_conf() { sed -n "s/^$1=//p" "$conf" | head -1; }
enable_global=$(read_conf enable_global)
scope=$(read_conf scope)
bb=/data/adb/ksu/bin/busybox

wait_boot() {
    i=0
    while [ "$i" -lt 240 ]; do
        if [ "$(getprop sys.boot_completed)" = 1 ]; then
            touch "$MODDIR/boot-ok"
            echo "boot completed after ${i}s"
            return 0
        fi
        sleep 2
        i=$((i + 2))
    done
    echo "boot_completed not seen within 240s"
    return 1
}

if [ "$enable_global" != 1 ] || [ "$scope" != apps ]; then
    echo "enable_global=$enable_global scope=$scope: nothing to bind at service stage"
    wait_boot
    exit 0
fi

check_platform || { echo "STOP: unsupported platform or OEM baseline mismatch"; exit 1; }
check_hash "$MODDIR/vulkan.mali.so" "$GPU_SHA" || { echo "STOP: driver payload mismatch"; exit 1; }
prepare_colorx || { echo "STOP: ColorX compatibility copy unavailable"; exit 1; }
chown 0:0 "$MODDIR/vulkan.mali.so" "$MODDIR/colorx-excluded.so"
chmod 644 "$MODDIR/vulkan.mali.so" "$MODDIR/colorx-excluded.so"
chcon u:object_r:same_process_hal_file:s0 "$MODDIR/vulkan.mali.so" || exit 1
chcon u:object_r:system_file:s0 "$MODDIR/colorx-excluded.so" || exit 1

bind_one() {
    pid=$1
    [ -n "$pid" ] || return 1
    "$bb" nsenter -t "$pid" -m -- mount -o bind "$MODDIR/vulkan.mali.so" "$GPU_TARGET" 2>/dev/null || return 1
    "$bb" nsenter -t "$pid" -m -- mount -o bind "$MODDIR/colorx-excluded.so" "$COLORX_TARGET" 2>/dev/null || true
    return 0
}

# Wait for the app spawn processes, then bind into each of their namespaces.
mounted=0
waited=0
while [ "$waited" -lt 90 ]; do
    for name in zygote zygote64 webview_zygote webview_zygote64 usap64 usap32; do
        for pid in $(pidof "$name" 2>/dev/null); do
            if bind_one "$pid"; then
                mounted=$((mounted + 1))
                echo "bound app namespace pid=$pid name=$name"
            fi
        done
    done
    [ "$mounted" -ge 1 ] && break
    sleep 1
    waited=$((waited + 1))
done

if [ "$mounted" -eq 0 ]; then
    echo "STOP: no app spawn namespace could be bound"
    exit 1
fi

[ "$(read_conf acq_replay)" = 0 ] || setprop debug.mesa.movecert.acq.replay true
[ "$(read_conf afbc_align)" = 0 ] || setprop "$ALIGN_PROP" true

# Verify the system processes stayed on the OEM driver.
sp=$(pidof surfaceflinger)
if [ -n "$sp" ]; then
    system_hash=$("$bb" nsenter -t "$sp" -m -- sha256sum "$GPU_TARGET" 2>/dev/null)
    case "$system_hash" in
        "$OEM_SHA"\ *) echo "system namespace verified on OEM driver" ;;
        *) echo "WARN: surfaceflinger namespace is not OEM: $system_hash" ;;
    esac
fi
echo "apps-scope mount complete; namespaces bound=$mounted"
wait_boot
