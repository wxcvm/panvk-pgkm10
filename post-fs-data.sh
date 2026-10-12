#!/system/bin/sh
MODDIR=${0%/*}
LOG="$MODDIR/driver.log"
printf 'PanVK guarded launcher: starting\n' > "$LOG"
chmod 600 "$LOG"
setting=$(sed -n 's/^enable_global=//p' "$MODDIR/driver.conf" | head -n1 | tr -d '\r')
[ "$setting" = 1 ] || { printf 'Global replacement OFF; OEM Vulkan retained\n' >> "$LOG"; exit 0; }
driver="$MODDIR/vulkan.mali.so"
target=/vendor/lib64/hw/mt6895/vulkan.mali.so
fail() { printf 'ERROR: %s; OEM driver preserved\n' "$1" >> "$LOG"; exit 1; }
# This exact platform failed the RC3 global-HAL runtime comparison. ColorX's
# constructFragmentShadingRatesInfo calls a missing entrypoint; do not imply
# that static ELF verification makes this a supported global replacement.
sdk=$(getprop ro.build.version.sdk)
model=$(getprop ro.product.model)
if [ "$sdk" = 37 ] && [ "$model" = PGKM10 ]; then
    fail 'RC3 global HAL incompatible with PGKM10 Android 17 ColorX; use OEM Vulkan'
fi
[ -f "$driver" ] && [ ! -L "$driver" ] && [ -f "$target" ] || fail 'Missing binary or OEM target'
if [ -f "$MODDIR/driver.sha256" ]; then
    expected=$(cat "$MODDIR/driver.sha256")
    actual=$(sha256sum "$driver" | cut -d' ' -f1)
    [ "$actual" = "$expected" ] || fail 'Packaged driver checksum mismatch'
    case "$sdk" in ''|*[!0-9]*) fail 'Cannot determine SDK' ;; esac
    [ "$sdk" -ge 35 ] || fail 'PanVK RC3 needs Android 15+'
fi
# ELF magic, class=64, little endian, ET_DYN, e_machine=AArch64 (183).
header=$(od -An -tx1 -N20 "$driver" | tr -d ' \n')
case "$header" in 7f454c460201*0300b700) ;; *) fail 'Driver must be an AArch64 shared library' ;; esac
oem_header=$(od -An -tx1 -N20 "$target" | tr -d ' \n')
case "$oem_header" in 7f454c460201*0300b700) ;; *) fail 'OEM target ABI does not match' ;; esac
chown 0:0 "$driver" && chmod 644 "$driver" || fail 'Cannot set driver permissions'
if [ "$(getenforce)" = Enforcing ]; then
    context=$(ls -Z "$target" | awk '{print $1}')
    case "$context" in u:object_r:*:s0*) ;; *) fail 'Cannot read OEM SELinux label' ;; esac
    chcon "$context" "$driver" || fail 'Cannot label optional driver'
fi
# Never bind an arm64 ELF onto /vendor/lib: 32-bit applications keep OEM HAL.
mount -o bind "$driver" "$target" || fail 'Optional bind mount failed'
if ! cmp -s "$driver" "$target"; then
    umount "$target"
    fail 'Optional bind verification failed'
fi
printf 'Optional arm64 global replacement verified; app compatibility is untested\n' >> "$LOG"
