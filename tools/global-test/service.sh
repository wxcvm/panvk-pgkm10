#!/system/bin/sh
# Mark the boot as successful once the framework reports boot_completed.
# If the framework never reports it, the fail-safe counter in post-fs-data.sh
# disables the module after repeated attempts.
MODDIR=${0%/*}
LOG="$MODDIR/log.txt"
exec >>"$LOG" 2>&1
echo "=== $(date) service ==="

i=0
while [ "$i" -lt 240 ]; do
    if [ "$(getprop sys.boot_completed)" = 1 ]; then
        touch "$MODDIR/boot-ok"
        echo "boot completed after ${i}s; marking success"
        exit 0
    fi
    sleep 2
    i=$((i + 2))
done
echo "boot_completed not seen within 240s"
