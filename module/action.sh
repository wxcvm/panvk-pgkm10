#!/system/bin/sh
# Module Action button: toggle enable_global for the next boot and show the active scope.
MODDIR=${0%/*}
conf="$MODDIR/driver.conf"
[ -f "$conf" ] || { echo "Missing $conf"; exit 1; }
cur=$(sed -n 's/^enable_global=//p' "$conf" | head -1)
scope=$(sed -n 's/^scope=//p' "$conf" | head -1)
case "$cur" in
    1) next=0 ;;
    0) next=1 ;;
    *) echo "Invalid enable_global value; leaving configuration unchanged"; exit 1 ;;
esac
sed -i "s/^enable_global=.*/enable_global=$next/" "$conf" || exit 1
echo "Next boot enable_global=$next (scope=$scope). Reboot required."
if [ "$next" = 1 ] && [ "$scope" = apps ]; then
    echo "Apps get PanVK; SurfaceFlinger/system_server keep the OEM driver."
elif [ "$next" = 1 ]; then
    echo "WARNING: scope=system mounts into SurfaceFlinger; 10-bit compressed video can abort at the unlock screen."
fi
echo "Disable this module and reboot to return to OEM Vulkan immediately."
