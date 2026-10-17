"""Package the pinned, independently verified WSI3 artifact; never include OEM code."""
from pathlib import Path, PurePosixPath
from zipfile import ZipFile, ZIP_DEFLATED
import argparse
import hashlib
import json
from elf_utils import inspect_elf

ROOT = Path(__file__).resolve().parent.parent
SHA = 'c24c37772f9494e8531fc8cbda9640a091859055fb63e563d44661b2308d69f1'
COMMIT = '9d9c0dc991d91c06e24a9ee811674d365a7d7fcc'
ARCHIVE_SHA = '5458f5a9c62fb1d513045a03ff575e0bfcf106e697777429806f9030c524320d'

def package(artifact, output):
    if hashlib.sha256(artifact.read_bytes()).hexdigest() != ARCHIVE_SHA:
        raise ValueError('Artifact differs from pinned Actions archive')
    entries = {}
    with ZipFile(artifact) as archive:
        source = json.loads(archive.read('SOURCE.json'))
        binary = archive.read('libvulkan_panfrost.so')
        if source['repository_commit'] != COMMIT or source['sha256'] != SHA or hashlib.sha256(binary).hexdigest() != SHA:
            raise ValueError('WSI3 source or binary mismatch')
        for name, digest in source['patch_sha256'].items():
            if hashlib.sha256(archive.read(name)).hexdigest() != digest:
                raise ValueError('Applied patch provenance mismatch: '+name)
        elf = inspect_elf(binary)
        required = {'HMI', 'vk_icdGetInstanceProcAddr', 'vk_icdGetPhysicalDeviceProcAddr', 'vk_icdNegotiateLoaderICDInterfaceVersion'}
        if elf['minimum_sdk'] != 35 or not required.issubset(elf['exports']):
            raise ValueError('Unexpected driver ABI')
        if not set(elf['needed']).issubset({'liblog.so','libnativewindow.so','libsync.so','libm.so','libz.so','libdl.so','libc.so'}):
            raise ValueError('Unexpected target dependency')
        entries['vulkan.mali.so'] = binary
        for info in archive.infolist():
            path = PurePosixPath(info.filename)
            if path.is_absolute() or '..' in path.parts or '\\' in info.filename:
                raise ValueError('Unsafe archive name')
            if info.is_dir() or info.filename == 'libvulkan_panfrost.so':
                continue
            if info.filename.endswith('.so'):
                raise ValueError('Unexpected extra binary')
            entries['upstream/'+info.filename] = archive.read(info)
    for name in ('module.prop','driver.conf','common.sh','customize.sh','post-fs-data.sh','action.sh','uninstall.sh','README.md'):
        path = ROOT/'wsi3-module'/name
        if path.is_symlink(): raise ValueError('Unsafe runtime file')
        entries[name] = path.read_bytes().replace(b'\r\n', b'\n')
    if entries['driver.conf'] != b'enable_global=0\n': raise ValueError('Package must default to OFF')
    if SHA.encode() not in entries['common.sh']: raise ValueError('Launcher checksum mismatch')
    entries['skip_mount'] = b''
    for path in (ROOT/'META-INF').rglob('*'):
        if path.is_file(): entries[path.relative_to(ROOT).as_posix()] = path.read_bytes().replace(b'\r\n',b'\n')
    entries['PACKAGE-VALIDATION.json'] = (json.dumps({
        'driver_sha256': SHA, 'driver_source_commit': COMMIT,
        'artifact_sha256': ARCHIVE_SHA, 'default_enable_global': False,
        'oem_binary_included': False, 'opengl_updated': False,
        'validation': 'Independent AFBC offset and native/AHB sync regressions passed; boot activation, browser and extended stability pending',
    }, indent=2)+'\n').encode()
    with ZipFile(output,'w',ZIP_DEFLATED) as archive:
        for name, data in sorted(entries.items()): archive.writestr(name,data)
    with ZipFile(output) as archive:
        if archive.testzip() is not None: raise ValueError('Corrupt module ZIP')
        assert not any('colorx' in name.lower() or name.startswith(('diagnostics/','tests/')) for name in archive.namelist())
    print(json.dumps({'path':str(output.resolve()),'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'size':output.stat().st_size,'files':len(entries)},indent=2))

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact',type=Path,required=True)
    parser.add_argument('--output',type=Path,default=ROOT/'PanVK-WSI3-PGKM10-experimental.zip')
    args=parser.parse_args()
    package(args.artifact,args.output)
