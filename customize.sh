#!/system/bin/sh
SKIPUNZIP=0
OLD_MODULE=/data/adb/modules/MTK_D8100_Vulkan1.4.Panvk
ui_print '- PanVK guarded launcher'
# Source-only package: reuse the installed binary without republishing it.
if [ -f "$MODPATH/vulkan.mali.so" ] && [ -f "$MODPATH/driver.sha256" ]; then
    expected=$(cat "$MODPATH/driver.sha256")
    actual=$(sha256sum "$MODPATH/vulkan.mali.so" | cut -d' ' -f1)
    [ "$actual" = "$expected" ] || abort 'Packaged driver checksum mismatch'
    sdk=$(getprop ro.build.version.sdk)
    case "$sdk" in ''|*[!0-9]*) abort 'Cannot read SDK' ;; esac
    [ "$sdk" -ge 35 ] || abort 'PanVK RC3 requires Android 15 or newer'
    ui_print '- Verified packaged PanVK RC3; 64-bit Vulkan only'
elif [ -f "$OLD_MODULE/vulkan.mali.so" ] && [ ! -L "$OLD_MODULE/vulkan.mali.so" ]; then
    cp "$OLD_MODULE/vulkan.mali.so" "$MODPATH/vulkan.mali.so" || abort 'Cannot preserve optional driver binary'
    chmod 644 "$MODPATH/vulkan.mali.so"
    ui_print '- Existing driver retained for optional manual testing'
else
    ui_print '- No driver binary found; OEM driver will be used'
fi
ui_print '- Reboot required. OpenGL and 32-bit Vulkan remain OEM.'
