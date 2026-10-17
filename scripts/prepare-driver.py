"""Prepare the verified, unchanged upstream PanVK RC3 in an ignored build directory."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil
from urllib.request import Request, urlopen
from zipfile import ZipFile
from elf_utils import inspect_elf
from driver_package import module_files

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--archive', type=Path, help='Previously downloaded upstream adpkg ZIP')
args = parser.parse_args()
upstream = json.loads((ROOT / 'upstream.json').read_text())
if args.archive:
    archive_data = args.archive.read_bytes()
else:
    with urlopen(Request(upstream['package_url'], headers={'User-Agent': 'MoveCertificate-build'}), timeout=60) as response:
        archive_data = response.read(20 * 1024 * 1024)
if hashlib.sha256(archive_data).hexdigest() != upstream['package_sha256']:
    raise SystemExit('Upstream archive checksum mismatch')
with ZipFile(io.BytesIO(archive_data)) as archive:
    binary = archive.read('libvulkan_panfrost.so')
    manifests = {name: archive.read(name) for name in ('SOURCE.json', 'MANIFEST.json', 'VALIDATION.json', 'meta.json')}
if hashlib.sha256(binary).hexdigest() != upstream['sha256']:
    raise SystemExit('Upstream driver checksum mismatch')
elf = inspect_elf(binary)
required = {'HMI', 'vk_icdGetInstanceProcAddr', 'vk_icdGetPhysicalDeviceProcAddr', 'vk_icdNegotiateLoaderICDInterfaceVersion'}
if not required.issubset(elf['exports']) or elf.get('build_id') != upstream['build_id'] or elf.get('minimum_sdk') != upstream['minimum_sdk']:
    raise SystemExit('Unexpected HAL exports, BuildID or minimum SDK')
allowed = {'liblog.so', 'libnativewindow.so', 'libsync.so', 'libm.so', 'libz.so', 'libdl.so', 'libc.so'}
if not set(elf['needed']).issubset(allowed):
    raise SystemExit('Unreviewed dynamic dependencies')
output = ROOT / 'driver-dist'
# Fixed path inside the repository only; discard previous generated build output.
if output.is_symlink() or output.resolve().parent != ROOT:
    raise SystemExit('Build output must resolve directly inside the repository')
if output.exists():
    shutil.rmtree(output)
output.mkdir()
for path, relative in module_files(ROOT):
    destination = output / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, destination)
(output / 'vulkan.mali.so').write_bytes(binary)
(output / 'driver.sha256').write_text(upstream['sha256'] + '\n')
(output / 'driver.conf').write_text('enable_global=0\n')
(output / 'module.prop').write_text(
    'id=MTK_D8100_Vulkan1.4.Panvk\nname=Dimensity 8100 PanVK RC3 (Vulkan only)\n'
    'version=0.1.0-rc3-wrapper2\nversionCode=4\nauthor=wxcvm; upstream zenithblue-oss\n'
    'description=RC3 retained for custom loaders; global replacement OFF. PGKM10 Android 17 ColorX crashes with global RC3; OEM Vulkan required.\n')
(output / 'upstream').mkdir()
for name, data in manifests.items():
    (output / 'upstream' / name).write_bytes(data)
validation = {'static_validation': 'passed', 'sha256': upstream['sha256'], **elf,
              'device_runtime_validation': {
                  'device': 'OnePlus PGKM10 / OP5565 / Mali-G610 MC6',
                  'sdk': 37, 'tested_on': '2026-10-12',
                  'global_hal_result': 'failed',
                  'star_rail': 'repeated SIGSEGV at PC 0 in ColorX constructFragmentShadingRatesInfo; RC3 BuildID confirmed in maps',
                  'oem_comparison': 'user confirmed game opens after RC3 bind removal',
                  'colorx_bypass_tests': {
                      'whole_extension_library_mask': 'failed; libvulkan.so+0x35d48 dereferences a null swapchain',
                      'precise_colorx_exclusion': 'failed after a briefly normal display; same null swapchain, OEM extension library still mapped',
                      'swapchain_creation_failure_cause': 'independent native-buffer probe reproduced gralloc_extra FD 0 import failure; actual game CreateSwapchainKHR return not separately captured',
                      'temporary_mounts': 'removed; not included in boot configuration or package',
                  },
                  'quetta': 'user reports intermittent partial corruption; cause not isolated',
                  'custom_icd_loading': 'independent root diagnostic process passed instance/device creation; app/game custom-loader behavior untested',
                  'independent_probe': {
                      'oem_api_version': '1.1.177', 'rc3_api_version': '1.4.363',
                      'vendor_api_and_vndk': 31, 'mapper': 'MediaTek HIDL gralloc4; metadata decoded successfully',
                      'native_buffer_rgba_unorm_and_srgb': 'VK_ERROR_INVALID_EXTERNAL_HANDLE; FD 0 is gralloc_extra',
                      'ahb_image_import_and_bind': 'VK_SUCCESS on same test buffer',
                      'source_patch_helper_tests': 'real import/bind passed; metadata-only handle rejected; DMA-BUF moved to index 2 passed',
                      'scope': 'root process, small verified-linear buffer; no full driver rebuild, GPU rendering or app conformance result',
                  },
              },
              'enable_global_default': False,
              'upstream_manifests': 'Preserved unchanged under upstream/; not PGKM10 runtime results.',
              'open_gl_modified': False, 'vendor_partition_written': False}
(output / 'VALIDATION.json').write_text(json.dumps(validation, indent=2) + '\n')
print('Verified RC3: arm64 Android HAL + ICD, BuildID, minimum SDK, checksums and dependencies')
