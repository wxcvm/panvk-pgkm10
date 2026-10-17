#!/bin/sh
# Execute the real launcher with system mutations mocked, including partial-bind failures.
set -eu
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
sed '/^MODDIR=/d; /\. "\$MODDIR\/common.sh"/d' "$ROOT/wsi3-module/post-fs-data.sh" > "$WORK/launcher.sh"
for scenario in off platform driver copy property colorx_mount gpu_mount verify success; do
    MODDIR="$WORK/$scenario"
    mkdir "$MODDIR"
    EVENTS="$MODDIR/events"
    : > "$EVENTS"
    printf 'original\n' > "$MODDIR/property"
    printf 'enable_global=1\n' > "$MODDIR/driver.conf"
    [ "$scenario" != off ] || printf 'enable_global=0\n' > "$MODDIR/driver.conf"
    if (
        . "$ROOT/wsi3-module/common.sh"
        check_platform() { [ "$scenario" != platform ]; }
        check_hash() {
            [ "$scenario" != driver ] || [ "$1" != "$MODDIR/vulkan.mali.so" ] || return 1
            [ "$scenario" != copy ] || [ "$1" != "$MODDIR/colorx-excluded.so" ] || return 1
            [ "$scenario" != verify ] || [ "$1" != "$GPU_TARGET" ] || return 1
            return 0
        }
        prepare_colorx() { return 1; }
        getprop() { [ "$1" != "$ALIGN_PROP" ] || cat "$MODDIR/property"; }
        setprop() {
            printf 'property:%s\n' "$2" >> "$EVENTS"
            [ "$scenario" != property ] || [ "$2" != true ] || return 1
            printf '%s\n' "$2" > "$MODDIR/property"
        }
        getenforce() { echo Permissive; }
        chmod() { :; }
        chown() { :; }
        mount() {
            printf 'mount:%s\n' "$4" >> "$EVENTS"
            [ "$scenario" != colorx_mount ] || [ "$4" != "$COLORX_TARGET" ] || return 1
            [ "$scenario" != gpu_mount ] || [ "$4" != "$GPU_TARGET" ] || return 1
        }
        umount() { printf 'unmount:%s\n' "$1" >> "$EVENTS"; }
        . "$WORK/launcher.sh"
    ); then result=0; else result=$?; fi
    case "$scenario" in
        off|success) [ "$result" = 0 ] ;;
        *) [ "$result" != 0 ] ;;
    esac
    case "$scenario" in
        off|platform|driver|copy) [ ! -s "$EVENTS" ] ;;
        gpu_mount) grep -q '^unmount:/system_ext/' "$EVENTS" ;;
        verify) [ "$(grep -c '^unmount:' "$EVENTS")" = 2 ] ;;
        success) [ "$(grep -c '^mount:' "$EVENTS")" = 2 ]; ! grep -q '^unmount:' "$EVENTS" ;;
    esac
    if [ "$scenario" = success ]; then expected=true; else expected=original; fi
    [ "$(cat "$MODDIR/property")" = "$expected" ]
done
# The actual platform predicate must reject an unsupported device before hashing.
. "$ROOT/wsi3-module/common.sh"
getprop() { echo unsupported; }
if check_platform; then echo 'FAIL: unsupported platform accepted'; exit 1; fi
echo 'PASS: default off, unsupported build, corrupt binaries, property failure, partial binds and verified activation'
