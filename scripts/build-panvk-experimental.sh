#!/bin/bash
# Build a separate, traceable Android ICD; this does not produce an installer.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/experimental-build.json"
WORK="$ROOT/.cache/panvk-experimental"
read_lock() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$LOCK" "$1"; }
PANVK_COMMIT="$(read_lock panvk_source_commit)"
MESA_COMMIT="$(read_lock mesa_commit)"
NAME="$(read_lock name)"
NDK_VERSION="$(read_lock ndk_version)"
NDK="${ANDROID_NDK_ROOT:-${ANDROID_HOME:?Android SDK required}/ndk/$NDK_VERSION}"
NDK_BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
API="$(read_lock android_api)"
test -x "$NDK_BIN/aarch64-linux-android$API-clang"
grep -q "Pkg.Revision = $NDK_VERSION" "$NDK/source.properties"
mkdir -p "$WORK"
report_failure() {
  local status=$?
  trap - ERR
  for log in "$WORK"/*.log; do
    [ -f "$log" ] || continue
    printf '\nLast output from %s\n' "$log"
    tail -n 35 "$log"
  done
  exit "$status"
}
trap report_failure ERR

fetch_exact() {
  local repo="$1" rev="$2" destination="$3"
  if [ -e "$destination" ]; then
    echo "Refusing to reuse source directory: $destination" >&2
    exit 1
  fi
  git init -q "$destination"
  git -C "$destination" remote add origin "$repo"
  git -C "$destination" fetch --depth 1 origin "$rev"
  git -C "$destination" checkout -q --detach FETCH_HEAD
  test "$(git -C "$destination" rev-parse HEAD)" = "$rev"
}

UPSTREAM="$WORK/upstream"
MESA="$WORK/mesa"
fetch_exact https://github.com/zenithblue-oss/panvk-kbase-android.git "$PANVK_COMMIT" "$UPSTREAM"
fetch_exact https://gitlab.freedesktop.org/mesa/mesa.git "$MESA_COMMIT" "$MESA"
python3 - "$UPSTREAM/sources.lock" "$MESA_COMMIT" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['mesaCommit'] == sys.argv[2]
PY
bash "$UPSTREAM/scripts/apply-patches.sh" --profile "$(read_lock upstream_profile)" --mesa "$MESA" | tee "$WORK/patches.log"
while IFS= read -r patch; do
  git -C "$MESA" apply --check "$ROOT/$patch"
  git -C "$MESA" apply "$ROOT/$patch"
done < <(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["patches"]))' "$LOCK")
# Keep Vulkan's driverInfo distinguishable from the unmodified official RC3.
python3 - "$MESA/src/panfrost/vulkan/panvk_vX_physical_device.c" "$NAME" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = '#define PANVK_KBASE_RELEASE "RC3"'
assert t.count(old) == 1
p.write_text(t.replace(old, '#define PANVK_KBASE_RELEASE "' + sys.argv[2] + '"'))
PY

# Host tools are tied to the source and patch hashes by the workflow cache key.
if [ ! -x "$WORK/host-tools/mesa_clc" ] || [ ! -x "$WORK/host-tools/vtn_bindgen2" ] || [ ! -x "$WORK/host-tools/panfrost_compile" ]; then
# Ubuntu 24.04's SPIRV-Tools predates this Mesa's >=2024.1 requirement.
SPIRV="$WORK/spirv-tools"
fetch_exact https://github.com/KhronosGroup/SPIRV-Tools.git "$(read_lock spirv_tools_commit)" "$SPIRV"
fetch_exact https://github.com/KhronosGroup/SPIRV-Headers.git "$(read_lock spirv_headers_commit)" "$SPIRV/external/spirv-headers"
cmake -S "$SPIRV" -B "$WORK/spirv-build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WORK/host-deps" \
  -DSPIRV_SKIP_TESTS=ON -DSPIRV_SKIP_EXECUTABLES=ON -DSPIRV_WERROR=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON > "$WORK/spirv.log" 2>&1
cmake --build "$WORK/spirv-build" --parallel 4 >> "$WORK/spirv.log" 2>&1
cmake --install "$WORK/spirv-build" >> "$WORK/spirv.log" 2>&1

export PKG_CONFIG_PATH="$WORK/host-deps/lib/pkgconfig"
export LLVM_CONFIG=/usr/lib/llvm-18/bin/llvm-config
meson setup "$WORK/host" "$MESA" \
  -Dbuildtype=release -Dgallium-drivers= -Dvulkan-drivers=panfrost \
  -Dplatforms= -Dglx=disabled -Degl=disabled -Dgbm=disabled \
  -Dopengl=false -Dgles1=disabled -Dgles2=disabled \
  -Dmesa-clc=enabled -Dinstall-mesa-clc=true \
  -Dprecomp-compiler=enabled -Dinstall-precomp-compiler=true \
  -Dllvm=enabled -Dzstd=disabled > "$WORK/host.log" 2>&1
ninja -j4 -C "$WORK/host" src/compiler/clc/mesa_clc \
  src/compiler/spirv/vtn_bindgen2 src/panfrost/clc/panfrost_compile >> "$WORK/host.log" 2>&1
mkdir -p "$WORK/host-tools"
for tool in src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 src/panfrost/clc/panfrost_compile; do
  cp "$WORK/host/$tool" "$WORK/host-tools/$(basename "$tool")"
done
fi

# PanVK still compiles DRM backends beside Kbase. Link their Android libdrm
# statically so the resulting ICD never requires a vendor libdrm.so.
DRM_VERSION="$(read_lock libdrm_version)"
curl --fail --location --retry 3 "https://dri.freedesktop.org/libdrm/libdrm-$DRM_VERSION.tar.xz" -o "$WORK/libdrm.tar.xz"
printf '%s  %s\n' "$(read_lock libdrm_archive_sha256)" "$WORK/libdrm.tar.xz" | sha256sum --check
tar -xJf "$WORK/libdrm.tar.xz" -C "$WORK"
export PATH="$NDK_BIN:$PATH"
export PKG_CONFIG_PATH=
export PKG_CONFIG_LIBDIR="$UPSTREAM/work/android-deps/lib/pkgconfig"
mkdir -p "$PKG_CONFIG_LIBDIR"
sed "s/aarch64-linux-android[0-9]*-clang/aarch64-linux-android$API-clang/g" "$UPSTREAM/meson/android-aarch64.ini" > "$WORK/deps-cross.ini"
meson setup "$WORK/libdrm-build" "$WORK/libdrm-$DRM_VERSION" \
  --cross-file "$WORK/deps-cross.ini" --prefix "$UPSTREAM/work/android-deps" \
  --libdir lib -Dbuildtype=release -Ddefault_library=static \
  -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled \
  -Dvmwgfx=disabled -Domap=disabled -Dexynos=disabled -Dfreedreno=disabled \
  -Dtegra=disabled -Dvc4=disabled -Detnaviv=disabled -Dudev=false \
  -Dtests=false -Dinstall-test-programs=false -Dcairo-tests=disabled \
  -Dman-pages=disabled -Dvalgrind=disabled > "$WORK/libdrm.log" 2>&1
ninja -j4 -C "$WORK/libdrm-build" install >> "$WORK/libdrm.log" 2>&1
unset PKG_CONFIG_LIBDIR

# NDK supplies Android's zlib; this .pc describes only that target library.
# Keep host dependency directories out of the target pkg-config search path.
mkdir -p "$UPSTREAM/work/android-deps/lib/pkgconfig"
cat > "$UPSTREAM/work/android-deps/lib/pkgconfig/zlib.pc" <<'PC'
Name: zlib
Description: Android NDK system zlib
Version: 1.2.13
Libs: -lz
Cflags:
PC
export PKG_CONFIG_PATH=
export MESA HOST_TOOLS="$WORK/host-tools" BDIR="$WORK/android" DDIR="$WORK/dist"
bash "$UPSTREAM/scripts/build-android.sh" \
  --profile "$(read_lock upstream_profile)" --api "$API" --ndk "$NDK" | tee "$WORK/android-summary.log"

OUT="$WORK/dist"
"$NDK_BIN/llvm-readelf" -h -n -d -Ws "$OUT/libvulkan_panfrost.so" > "$OUT/elf-report.txt"
grep -q AArch64 "$OUT/elf-report.txt"
grep -q vk_icdGetInstanceProcAddr "$OUT/elf-report.txt"
grep -q ' HMI$' "$OUT/elf-report.txt"
cp "$LOCK" "$OUT/build-inputs.json"
cp "$ROOT"/patches/*.patch "$OUT/"
cp -R "$ROOT/licenses/Mesa" "$OUT/LICENSE-Mesa"
cp "$WORK/libdrm.tar.xz" "$OUT/libdrm-$DRM_VERSION-source.tar.xz"
python3 - "$ROOT" "$WORK" "$NDK" <<'PY'
from pathlib import Path
import hashlib, json, subprocess, sys
root, work, ndk = map(Path, sys.argv[1:])
out = work / 'dist'
so = out / 'libvulkan_panfrost.so'
sha = hashlib.sha256(so.read_bytes()).hexdigest()
data = json.loads((root / 'experimental-build.json').read_text())
patch_files = [root / name for name in data['patches']]
assert len({p.name for p in patch_files}) == len(patch_files), 'Ambiguous patch names in provenance'
data.update({
    'repository_commit': subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(),
    'sha256': sha,
    'size_bytes': so.stat().st_size,
    'patch_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in patch_files},
    'ndk_properties': (ndk / 'source.properties').read_text(),
    'validation': 'Build and ELF checks only; device and game validation pending',
})
(out / 'SOURCE.json').write_text(json.dumps(data, indent=2) + '\n')
(out / 'SHA256SUMS.txt').write_text(sha + '  libvulkan_panfrost.so\n')
print('Experimental driver:', sha, so.stat().st_size)
PY
