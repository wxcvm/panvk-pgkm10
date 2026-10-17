#!/system/bin/sh
# Inject the experimental PanVK ICD + ColorX compatibility copy into zygote64's
# mount namespace, start WeChat, then restore core namespaces to OEM.
# Usage: start-wsi7-wechat.sh [0|1]   (1 = enable MOVECERT_ACQ_REPLAY, default 1)
set -eu
bb=/data/adb/ksu/bin/busybox
driver=/data/local/tmp/movecert-rc3-anbfix3-wsi7.so
patched=/data/local/tmp/movecert-colorx-excluded.so
gpu=/vendor/lib64/hw/mt6895/vulkan.mali.so
ext=/system_ext/lib64/libvulkanextimpl.so
replay=${1:-1}
case "$replay" in 0|1) ;; *) exit 2 ;; esac

sh /data/local/tmp/check-wsi2-baseline.sh
printf '%s  %s\n' 9c0df1a352a9100da6fb9dfde1533486a736c58d625719f6edc54ad614ef5aec "$driver" | sha256sum -c -
printf '%s  %s\n' 16c93822969608ce3662e3d01725438b1ab88d6c2c6c8b54bef9b2c0419db0b8 "$patched" | sha256sum -c -

pid=$(pidof zygote64)
case "$pid" in ''|*' '*) exit 2 ;; esac
ns=$(readlink /proc/$pid/ns/mnt)
[ "$ns" != "$(readlink /proc/1/ns/mnt)" ]
# Refuse shared vendor/system_ext mounts: a zygote-local bind must not propagate.
awk '$5 == "/vendor" || $5 == "/system_ext" {n++; for (i=7;i<=NF;i++) if ($i ~ /^shared:/) bad=1} END {exit n != 2 || bad}' /proc/$pid/mountinfo

session=$(mktemp -d /data/local/tmp/movecert-wsi7-wechat.XXXXXX)
printf '%s\n' "$session" > /data/local/tmp/movecert-wsi7-wechat-session
printf '%s\n' "$pid" > "$session/zygote.pid"
printf '%s\n' "$ns" > "$session/zygote.ns"
printf '%s\n' "$replay" > "$session/replay"
date '+%Y-%m-%d %H:%M:%S' > "$session/start-time"
for item in sync.trace acq.replay afbc.align; do getprop "debug.mesa.movecert.$item" > "$session/original-$item"; done

rollback() { sh /data/local/tmp/restore-wsi7-wechat.sh "$session"; }
completed=false
cleanup() { [ "$completed" = true ] || rollback; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

"$bb" nohup sh /data/local/tmp/watchdog-wsi7-wechat.sh "$session" > "$session/watchdog.log" 2>&1 < /dev/null &
echo "$!" > "$session/watchdog.pid"

chown 0:0 "$driver" "$patched"
chmod 644 "$driver" "$patched"
chcon u:object_r:same_process_hal_file:s0 "$driver"
chcon u:object_r:system_file:s0 "$patched"

setprop debug.mesa.movecert.sync.trace true || { rollback; exit 1; }
if [ "$replay" = 1 ]; then
    setprop debug.mesa.movecert.acq.replay true || { rollback; exit 1; }
else
    setprop debug.mesa.movecert.acq.replay false || { rollback; exit 1; }
fi
setprop debug.mesa.movecert.afbc.align true || { rollback; exit 1; }

"$bb" nsenter -t "$pid" -m -- mount -o bind "$patched" "$ext" || { rollback; exit 1; }
"$bb" nsenter -t "$pid" -m -- mount -o bind "$driver" "$gpu" || { rollback; exit 1; }

# Verify init stayed on OEM before starting the target application.
actual=$("$bb" nsenter -t 1 -m -- sha256sum "$gpu")
case "$actual" in 2ae46e5c85ff73ab3441b1acbd12e60d50247b0be56a19a825e2fae66050c5b0\ *) ;; *) rollback; exit 1 ;; esac

logcat -c
"$bb" nohup logcat -v threadtime -s MESA:V > /data/local/tmp/movecert-wsi7-logcat.log 2>&1 < /dev/null &
echo "$!" > "$session/logcat.pid"

am force-stop com.tencent.mm
am start -n com.tencent.mm/.ui.LauncherUI || { rollback; exit 1; }
app=''
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    app=$(pidof com.tencent.mm || true)
    [ -n "$app" ] && break
    sleep 1
done
case "$app" in ''|*' '*) rollback; exit 1 ;; esac
[ "$(readlink /proc/$app/ns/mnt)" != "$ns" ] || { rollback; exit 1; }

actual=$("$bb" nsenter -t "$app" -m -- sha256sum "$gpu")
case "$actual" in 9c0df1a352a9100da6fb9dfde1533486a736c58d625719f6edc54ad614ef5aec\ *) ;; *) rollback; exit 1 ;; esac
echo "$app" > "$session/app.pid"

# Restore zygote/init namespaces immediately: only the running WeChat keeps PanVK.
sh /data/local/tmp/restore-wsi7-wechat.sh "$session" zygote-only || { rollback; exit 1; }
sh /data/local/tmp/check-wsi2-baseline.sh > "$session/core-stock-baseline" || { rollback; exit 1; }
actual=$("$bb" nsenter -t "$app" -m -- sha256sum "$gpu")
case "$actual" in 9c0df1a352a9100da6fb9dfde1533486a736c58d625719f6edc54ad614ef5aec\ *) ;; *) rollback; exit 1 ;; esac

echo "WeChat PID=$app has WSI7 replay=$replay; core namespaces restored to OEM; session=$session"
completed=true
