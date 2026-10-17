"""Select runtime module files explicitly; exclude source and diagnostic tools."""
from pathlib import Path

RUNTIME_FILES = (
    "module.prop",
    "driver.conf",
    "customize.sh",
    "post-fs-data.sh",
    "uninstall.sh",
    "README.md",
    "upstream.json",
)


def module_files(source: Path):
    for name in RUNTIME_FILES:
        path = source / name
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"Missing or unsafe module runtime file: {path}")
        yield path, name
    for path in sorted((source / "licenses").rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Refusing symlink: {path}")
        if path.is_file():
            yield path, path.relative_to(source).as_posix()
