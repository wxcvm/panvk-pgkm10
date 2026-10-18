#!/system/bin/sh
# Permanent skiavkthreaded configuration guard.
# Monitors SurfaceFlinger restarts; if it crashes repeatedly within a short
# window, revert the render configuration to skiagl, disable the HWUI preset
# module and reboot, so the device cannot get stuck in a SurfaceFlinger crash
# loop (this happened during bring-up with an incompatible driver/mount).
MODDIR=${0%/*}
(
  sleep 40
  LOG="$MODDIR/log.txt"
  CNT="$MODDIR/sf-restarts.log"
  : > "$CNT"
  last=$(pidof surfaceflinger)
  while true; do
    sleep 20
    cur=$(pidof surfaceflinger)
    if [ -n "$cur" ] && [ -n "$last" ] && [ "$cur" != "$last" ]; then
      echo "$(date +%s) sf=$cur" >> "$CNT"
      last=$cur
      recent=$(/data/adb/ksu/bin/busybox awk -v now="$(date +%s)" 'now - $1 < 600 { c++ } END { print c+0 }' "$CNT" 2>/dev/null)
      if [ "${recent:-0}" -ge 3 ]; then
        echo "$(date) WATCHDOG: $recent SF restarts in 10 min; reverting to skiagl" >> "$LOG"
        sed -i 's/^debug.renderengine.backend=.*/debug.renderengine.backend=skiagl/' /data/adb/modules/hwui_use_vulkan/system.prop
        sed -i 's/^debug.renderengine.vulkan=.*/debug.renderengine.vulkan=false/' /data/adb/modules/hwui_use_vulkan/system.prop
        touch /data/adb/modules/hwui_use_vulkan/disable
        touch "$MODDIR/sf-unstable"
        sync
        /system/bin/reboot -f
      fi
    fi
  done
) &
exec /system/bin/sh "$MODDIR/service.sh.orig"
