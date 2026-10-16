#!/system/bin/sh
MODDIR=${0%/*}
umask 077
[ ! -L "$MODDIR/driver.conf" ] && [ ! -L "$MODDIR/driver.conf.tmp" ] || exit 1
case "$(cat "$MODDIR/driver.conf")" in
    enable_global=1) next=0 ;;
    enable_global=0) next=1 ;;
    *) echo 'Invalid configuration; activation unchanged'; exit 1 ;;
esac
printf 'enable_global=%s\n' "$next" > "$MODDIR/driver.conf.tmp" &&
    mv -f "$MODDIR/driver.conf.tmp" "$MODDIR/driver.conf" || exit 1
echo "Next boot enable_global=$next. Reboot required; current mounts are unchanged."
echo 'Disable this module and reboot for OEM fallback.'
