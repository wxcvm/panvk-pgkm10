#!/system/bin/sh
SKIPUNZIP=0
OLD_MODULE=/data/adb/modules/MTK_D8100_Vulkan1.4.Panvk
ui_print '- PanVK launcher repair: global replacement disabled by default'
# Source-only package: reuse the installed binary without republishing it.
if [ -f "$OLD_MODULE/vulkan.mali.so" ] && [ ! -L "$OLD_MODULE/vulkan.mali.so" ]; then
    cp "$OLD_MODULE/vulkan.mali.so" "$MODPATH/vulkan.mali.so" || abort 'Cannot preserve optional driver binary'
    chmod 644 "$MODPATH/vulkan.mali.so"
    ui_print '- Existing driver retained for optional manual testing'
else
    ui_print '- No driver binary found; OEM driver will be used'
fi
ui_print '- Reboot to restore the original Vulkan HAL. Vendor partition is not modified.'
