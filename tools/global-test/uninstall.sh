#!/system/bin/sh
# Remove the fail-safe markers so a reinstall starts from a clean state.
MODDIR=${0%/*}
rm -f "$MODDIR/attempt" "$MODDIR/boot-ok"
