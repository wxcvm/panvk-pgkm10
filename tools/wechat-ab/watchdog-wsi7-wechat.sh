#!/system/bin/sh
# Safety watchdog: if the A/B run is left behind for more than 10 minutes,
# force the restore path so the device never stays on the experimental driver.
set -eu
session=${1:?}
bb=/data/adb/ksu/bin/busybox
sleep 600
if [ ! -f "$session/restored" ]; then
    "$bb" nohup sh /data/local/tmp/restore-wsi7-wechat.sh "$session" > "$session/watchdog-restore.log" 2>&1 < /dev/null &
fi
