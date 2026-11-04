#!/usr/bin/env python3
"""Make a copied Python.framework/Versions/3.14 self-contained.

A Homebrew Python links its executables and extension modules against
absolute /opt/homebrew (or /usr/local) paths. Those paths do not exist on
other Macs, so the bundled runtime fails to start there. This script:

1. rewrites every reference to the framework's own `Python` library to a
   path relative to the referencing file,
2. copies every other external non-system dylib into `Versions/3.14/lib`
   (recursively, including their own dependencies) and rewrites the
   references to `@loader_path`-relative paths,
3. fails if any absolute non-system reference remains.

Signing is done afterwards by build.sh.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

SYSTEM_PREFIXES = ("/usr/lib/", "/System/")


def is_macho(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as handle:
        magic = handle.read(4)
    return magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf", b"\xbe\xba\xfe\xca")


def dependencies(path: Path) -> list[str]:
    output = subprocess.run(["otool", "-L", str(path)], check=True, capture_output=True, text=True).stdout
    lines = output.splitlines()[1:]
    return [line.strip().split(" (compatibility")[0] for line in lines if line.strip()]


def own_id(path: Path) -> str | None:
    output = subprocess.run(["otool", "-D", str(path)], check=True, capture_output=True, text=True).stdout.splitlines()
    return output[1].strip() if len(output) > 1 else None


def external(reference: str) -> bool:
    return reference.startswith("/") and not reference.startswith(SYSTEM_PREFIXES)


def relative(from_file: Path, target: Path) -> str:
    return "@loader_path/" + os.path.relpath(target, from_file.parent)


def change(path: Path, old: str, new: str) -> None:
    subprocess.run(["install_name_tool", "-change", old, new, str(path)], check=True, capture_output=True)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: relocate-python-runtime.py /path/to/Python.framework/Versions/3.14", file=sys.stderr)
        return 64
    root = Path(sys.argv[1]).resolve()
    python_lib = root / "Python"
    lib_dir = root / "lib"
    if not python_lib.is_file() or not lib_dir.is_dir():
        print(f"not a Python framework version directory: {root}", file=sys.stderr)
        return 65

    os.chmod(python_lib, 0o755)
    subprocess.run(["install_name_tool", "-id", "@rpath/Python.framework/Versions/3.14/Python", str(python_lib)], check=True, capture_output=True)

    copied: dict[str, Path] = {}
    queue = [path for path in root.rglob("*") if is_macho(path)]
    while queue:
        binary = queue.pop()
        os.chmod(binary, os.stat(binary).st_mode | 0o200)
        for reference in dependencies(binary):
            if reference == own_id(binary) or not external(reference):
                continue
            if reference.endswith("/Python.framework/Versions/3.14/Python"):
                change(binary, reference, relative(binary, python_lib))
                continue
            source = Path(reference)
            if not source.exists():
                print(f"missing dependency {reference} (needed by {binary})", file=sys.stderr)
                return 66
            if reference not in copied:
                destination = lib_dir / source.name
                if not destination.exists():
                    shutil.copy2(source.resolve(), destination)
                    os.chmod(destination, 0o755)
                    subprocess.run(["install_name_tool", "-id", f"@rpath/{source.name}", str(destination)], check=True, capture_output=True)
                    queue.append(destination)
                copied[reference] = destination
            change(binary, reference, relative(binary, copied[reference]))

    leftovers = []
    for binary in (path for path in root.rglob("*") if is_macho(path)):
        for reference in dependencies(binary):
            if reference != own_id(binary) and external(reference):
                leftovers.append(f"{binary}: {reference}")
    if leftovers:
        print("absolute non-system references remain:\n" + "\n".join(leftovers), file=sys.stderr)
        return 67
    for name in sorted({path.name for path in copied.values()}):
        print(f"bundled {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
