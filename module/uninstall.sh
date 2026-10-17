#!/system/bin/sh
# Clear fail-safe state; the module's system mounts disappear with the next reboot.
MODDIR=${0%/*}
rm -f "$MODDIR/attempt" "$MODDIR/boot-ok" "$MODDIR/colorx-excluded.so" "$MODDIR/colorx.tmp" "$MODDIR/log.txt"
