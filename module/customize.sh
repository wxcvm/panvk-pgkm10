#!/system/bin/sh
# Install-time permissions. Mounting happens at post-fs-data, not at install.
MODDIR=${0%/*}
chmod 755 "$MODDIR"/*.sh 2>/dev/null || true
chmod 644 "$MODDIR"/module.prop "$MODDIR"/driver.conf "$MODDIR"/README.md 2>/dev/null || true
chmod 644 "$MODDIR"/vulkan.mali.so 2>/dev/null || true
exit 0
