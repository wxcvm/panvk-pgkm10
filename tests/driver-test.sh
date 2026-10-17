#!/bin/sh
# Execute the actual launcher in isolated directories, with every mount mocked.
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
sed '/^MODDIR=/d' "$ROOT/post-fs-data.sh" > "$WORK/launcher.sh"
mount() { echo unexpected-mount >&2; return 99; }
getprop() { case "$1" in ro.build.version.sdk) echo 37 ;; ro.product.model) echo PGKM10 ;; esac; }
mkdir "$WORK/off" "$WORK/on" "$WORK/incompatible"
cp "$ROOT/driver.conf" "$WORK/off/driver.conf"
( MODDIR="$WORK/off"; . "$WORK/launcher.sh" ) || exit 1
printf 'enable_global=1\n' > "$WORK/on/driver.conf"
if ( MODDIR="$WORK/on"; . "$WORK/launcher.sh" ); then
    echo 'FAIL: missing binary accepted' >&2; exit 1
fi
grep -q 'OEM driver preserved' "$WORK/on/driver.log" || exit 1
printf 'enable_global=1\n' > "$WORK/incompatible/driver.conf"
if ( MODDIR="$WORK/incompatible"; . "$WORK/launcher.sh" ); then
    echo 'FAIL: incompatible global HAL accepted' >&2; exit 1
fi
grep -q 'incompatible with PGKM10 Android 17 ColorX' "$WORK/incompatible/driver.log" || exit 1
# Other platforms still run the normal binary checks rather than this guard.
getprop() { case "$1" in ro.build.version.sdk) echo 36 ;; ro.product.model) echo OtherDevice ;; esac; }
if ( MODDIR="$WORK/on"; . "$WORK/launcher.sh" ); then exit 1; fi
grep -q 'Missing binary' "$WORK/on/driver.log" || exit 1
sh "$ROOT/uninstall.sh" || exit 1
printf 'PASS: OEM default; known ColorX incompatibility blocked; missing binary fails; uninstall inert\n'
