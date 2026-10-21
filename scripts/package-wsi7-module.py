"""Assemble the WSI7 global-enable module ZIP from pinned sources.

The ZIP contains only our scripts, the pinned WSI7 ICD and license texts.
The ColorX compatibility copy is generated on the device from the OEM library;
no OEM binary is packaged.

v1.1.2 packaging fix: ``service.sh.orig`` is part of the module (the v1.1.1 ZIP
omitted it, so the service stage executed a missing script and the zygote
app-spawn namespaces never received the ICD).
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parent.parent
DRIVER_SHA = "5eb3899da6f16a7f6b7e80aab1a693da032831d4db1c99817fbcc1f160a3d4a6"
COLORX_PATCHED_SHA = "16c93822969608ce3662e3d01725438b1ab88d6c2c6c8b54bef9b2c0419db0b8"
DRIVER_SOURCE_COMMIT = "bcc8e691637790f4874c2bf13de4031d46ce1f24"
MODULE_FILES = (
    "module.prop",
    "driver.conf",
    "common.sh",
    "post-fs-data.sh",
    "service.sh",
    "service.sh.orig",
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
    parser.add_argument("--output", type=Path, default=ROOT / "PanVK-WSI7-PGKM10-v1.1.2.zip")
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
                    "diagnostics/026-mapper-before-legacy-format.patch",
                    "diagnostics/030-one-shot-android-acquire-replay.patch",
                    "patches/031-kbase-import-coherency.patch",
                    "patches/032-afbc-switch.patch",
                    "patches/033-afbc-linear-import.patch",
                    "patches/034-kbase-uncached-imports.patch",
                    "patches/035-yu10-external-format.patch",
                    "patches/036-panvk-yu10-image.patch",
                    "patches/038-yu10-afbc-format.patch",
                    "patches/039-strip-hotpath-logs.patch",
                    "patches/040-strip-acquire-trace.patch"],
        "default_enable_global": False,
        "colorx_copy": "generated on device from the verified OEM library",
        "colorx_patched_sha256": COLORX_PATCHED_SHA,
        "oem_binary_included": False,
        "opengl_updated": False,
        "surfaceflinger_backend": "skiagl (unchanged)",
        "service_script_included": True,
        "zygote_namespace_fix": ("scope=system binds init at post-fs-data and re-verifies/re-binds "
                                 "zygote/zygote64/webview_zygote after boot_completed; this device's "
                                 "zygote64 rebuilds its mount namespace during boot"),
        "validation": ("PGKM10/Android 17, 2026-10-21: module ZIP contains service.sh.orig; cold boot with "
                       "enable_global=1 scope=system leaves init, zygote, zygote64, system_server and WeChat "
                       "on the 5eb3899d driver (WeChat maps 4 segments); boot-ok written, fail-safe counter "
                       "reset; no new ANR/tombstone after boot. SurfaceFlinger stays skiagl (hwui_use_vulkan "
                       "module not installed). Game/10-bit compressed video remain unverified."),
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
        required = {"vulkan.mali.so", "module.prop", "service.sh", "service.sh.orig"}
        if not required.issubset(names):
            raise SystemExit("module zip missing required entries: " + ", ".join(sorted(required - names)))
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
