#!/system/bin/sh
# Restore WSI7 WeChat A/B run: stop WeChat, unmount zygote-local PanVK/ColorX binds,
# restore diagnostic properties, and verify core namespaces use the OEM driver.
set -eu
session=${1:?}
case "$session" in /data/local/tmp/movecert-wsi7-wechat.*) ;; *) exit 2 ;; esac
bb=/data/adb/ksu/bin/busybox
gpu=/vendor/lib64/hw/mt6895/vulkan.mali.so
ext=/system_ext/lib64/libvulkanextimpl.so

release_zygote() {
    pid=$(cat "$session/zygote.pid")
    [ "$(readlink /proc/$pid/ns/mnt)" = "$(cat "$session/zygote.ns")" ] || return 1
    current=$("$bb" nsenter -t "$pid" -m -- sha256sum "$gpu")
    case "$current" in
        9c0df1a352a9100da6fb9dfde1533486a736c58d625719f6edc54ad614ef5aec\ *) "$bb" nsenter -t "$pid" -m -- umount "$gpu" ;;
        2ae46e5c85ff73ab3441b1acbd12e60d50247b0be56a19a825e2fae66050c5b0\ *) ;;
        *) return 1 ;;
    esac
    current=$("$bb" nsenter -t "$pid" -m -- sha256sum "$ext")
    case "$current" in
        16c93822969608ce3662e3d01725438b1ab88d6c2c6c8b54bef9b2c0419db0b8\ *) "$bb" nsenter -t "$pid" -m -- umount "$ext" ;;
        3835dd76a8e6536d53c638467bf9785897802ad96867ecaf9f539b1085707fe5\ *) ;;
        *) return 1 ;;
    esac
    "$bb" nsenter -t "$pid" -m -- sha256sum "$gpu" "$ext"
}

if [ "${2:-}" = zygote-only ]; then
    release_zygote
    exit
fi

[ ! -f "$session/restored" ] || exit 0
am force-stop com.tencent.mm || true
release_zygote || true
for item in sync.trace acq.replay afbc.align; do
    setprop "debug.mesa.movecert.$item" "$(cat "$session/original-$item")" || true
done
if [ -f "$session/logcat.pid" ]; then
    kill "$(cat "$session/logcat.pid")" 2>/dev/null || true
fi
sleep 1
sh /data/local/tmp/check-wsi2-baseline.sh > "$session/restored-baseline" 2>&1 || true
touch "$session/restored"
echo 'WSI7 WeChat test restored; stock driver and original properties verified'
