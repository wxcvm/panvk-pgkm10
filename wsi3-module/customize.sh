#!/system/bin/sh
SKIPUNZIP=0
MODDIR="$MODPATH"
. "$MODDIR/common.sh"
ui_print '- Experimental WSI3: exact PGKM10 / Android 17 OEM build only'
check_platform || abort 'OEM build mismatch or another driver already mounted. Restore OEM and reboot before installation.'
check_hash "$MODDIR/vulkan.mali.so" "$GPU_SHA" || abort 'WSI3 checksum mismatch'
prepare_colorx || abort 'Cannot prepare verified local ColorX compatibility copy'
# Updates deliberately reset activation: installing alone cannot enable a new HAL.
printf 'enable_global=0\n' > "$MODDIR/driver.conf" || abort 'Cannot save default configuration'
touch "$MODDIR/skip_mount"
set_perm_recursive "$MODDIR" 0 0 0755 0644
set_perm "$MODDIR/post-fs-data.sh" 0 0 0755
set_perm "$MODDIR/action.sh" 0 0 0755
set_perm "$MODDIR/colorx-excluded.so" 0 0 0600
ui_print '- Installed with global replacement OFF'
ui_print '- Action toggles next-boot activation; reboot required'
ui_print '- Disable this module and reboot to restore OEM'
