"""Assemble the WSI7 global-enable module ZIP from pinned sources.

The ZIP contains only our scripts, the pinned WSI7 ICD and license texts.
The ColorX compatibility copy is generated on the device from the OEM library;
no OEM binary is packaged.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parent.parent
DRIVER_SHA = "e62177fb598271b12e478833d9c0d01f44c3e452e83e194903e5ac1478fc1dc0"
COLORX_PATCHED_SHA = "16c93822969608ce3662e3d01725438b1ab88d6c2c6c8b54bef9b2c0419db0b8"
DRIVER_SOURCE_COMMIT = "43001017a03c463c950381b6e461dcb72e8cc539"
MODULE_FILES = (
    "module.prop",
    "driver.conf",
    "common.sh",
    "post-fs-data.sh",
    "service.sh",
    "action.sh",
    "customize.sh",
    "uninstall.sh",
    "README.md",
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", type=Path, required=True, help="Pinned libvulkan_panfrost.so (wsi7)")
    parser.add_argument("--output", type=Path, default=ROOT / "PanVK-WSI7-PGKM10-v1.0.0.zip")
    args = parser.parse_args()

    driver_bytes = args.driver.read_bytes()
    if digest(driver_bytes) != DRIVER_SHA:
        raise SystemExit("driver SHA256 mismatch: " + digest(driver_bytes))

    module_dir = ROOT / "module"
    entries: dict[str, bytes] = {}
    for name in MODULE_FILES:
        path = module_dir / name
        if not path.is_file() or path.is_symlink():
            raise SystemExit("missing or unsafe module file: " + name)
        entries[name] = path.read_bytes().replace(b"\r\n", b"\n")
    entries["vulkan.mali.so"] = driver_bytes
    entries["driver.sha256"] = (DRIVER_SHA + "\n").encode()
    entries["skip_mount"] = b""

    licenses = ROOT / "licenses"
    for path in sorted(licenses.rglob("*")):
        if path.is_symlink():
            raise SystemExit("refusing symlink: " + str(path))
        if path.is_file():
            entries["licenses/" + path.relative_to(licenses).as_posix()] = path.read_bytes()

    for name in ("update-binary", "updater-script"):
        path = ROOT / "META-INF" / "com" / "google" / "android" / name
        if not path.is_file():
            raise SystemExit("missing installer metadata: " + name)
        entries["META-INF/com/google/android/" + name] = path.read_bytes().replace(b"\r\n", b"\n")

    validation = {
        "driver_sha256": DRIVER_SHA,
        "driver_source_commit": DRIVER_SOURCE_COMMIT,
        "patches": ["patches/019-anb-import-fd-discovery.patch",
                    "patches/020-kbase-disable-drm-sync-payload-copy.patch",
                    "patches/021-kbase-sync-file-waiter-lifetime.patch",
                    "diagnostics/022-bounded-workload-trace.patch",
                    "diagnostics/023-swapchain-allocation-diagnostic.patch",
                    "diagnostics/024-native-present-cache-diagnostic.patch",
                    "diagnostics/025-afbc-body-alignment-diagnostic.patch",
                    "diagnostics/026-mapper-before-legacy-format.patch",
                    "diagnostics/027-bounded-kbase-sync-trace.patch",
                    "diagnostics/028-bounded-queue-dependency-trace.patch",
                    "diagnostics/029-bounded-queue-caller-trace.patch",
                    "diagnostics/030-one-shot-android-acquire-replay.patch"],
        "default_enable_global": False,
        "colorx_copy": "generated on device from the verified OEM library",
        "colorx_patched_sha256": COLORX_PATCHED_SHA,
        "oem_binary_included": False,
        "opengl_updated": False,
        "surfaceflinger_backend": "skiagl (unchanged)",
        "validation": ("PGKM10/Android 17: 3 cold boots completed, WeChat Flutter/WebView pages OK, "
                       "ColorX crash not reproduced, camera/browser/settings render OK, ~13 min soak without "
                       "ANR/tombstone; microbenchmark shows 26-31% lower submit latency than OEM. "
                       "Game gameplay and 10-bit compressed YU10 composition remain unverified."),
    }
    entries["PACKAGE-VALIDATION.json"] = (json.dumps(validation, indent=2) + "\n").encode()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(args.output, "w", ZIP_DEFLATED) as archive:
        for name, data in sorted(entries.items()):
            archive.writestr(name, data)
    with ZipFile(args.output) as archive:
        bad = archive.testzip()
        if bad is not None:
            raise SystemExit("corrupt entry: " + bad)
        names = set(archive.namelist())
        if "vulkan.mali.so" not in names or "module.prop" not in names:
            raise SystemExit("module zip missing required entries")
        leaked = [n for n in names if n.endswith(".so") and n != "vulkan.mali.so"]
        if leaked:
            raise SystemExit("unexpected extra binaries: " + ", ".join(leaked))

    print(json.dumps({
        "path": str(args.output.resolve()),
        "sha256": digest(args.output.read_bytes()),
        "size": args.output.stat().st_size,
        "files": len(entries),
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
