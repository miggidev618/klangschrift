#!/usr/bin/env python3
"""Combine only fixed official SDK slices and verify their frozen file inventory."""
import hashlib
import json
import pathlib
import plistlib
import shutil
import sys
import subprocess

def verify(root, receipt):
    expected = json.loads(receipt.read_text())["combined_files"]
    actual = {str(p.relative_to(root)) for p in root.rglob("*") if p.is_file()}
    if actual != set(expected):
        raise ValueError("Sherpa SDK file list differs from frozen release")
    for relative, item in expected.items():
        path = root / relative
        digest = hashlib.sha256()
        with path.open("rb") as source:
            while chunk := source.read(1 << 20):
                digest.update(chunk)
        if path.stat().st_size != item["bytes"] or digest.hexdigest() != item["sha256"]:
            raise ValueError("Sherpa SDK fixed file hash mismatch: " + relative)

if sys.argv[1] == "--verify" and len(sys.argv) == 4:
    verify(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
elif sys.argv[1] == "--combine" and len(sys.argv) == 6:
    ios, mac, destination, receipt = map(pathlib.Path, sys.argv[2:])
    if destination.exists():
        raise ValueError("Refusing to replace an SDK directory")
    shutil.copytree(ios, destination)
    # XCFrameworks must use one library type on every platform. Wrap the
    # official macOS dylib as a framework; native code and exported API stay intact.
    mac_source = mac / "macos-arm64_x86_64"
    framework = destination / "macos-arm64_x86_64" / "SherpaOnnxC.framework"
    framework.mkdir(parents=True)
    shutil.copytree(mac_source / "Headers", framework / "Headers")
    (framework / "Headers" / "module.modulemap").unlink()
    (framework / "Modules").mkdir()
    (framework / "Modules" / "module.modulemap").write_text('framework module SherpaOnnxC {\n  header "sherpa-onnx/c-api/c-api.h"\n  export *\n}\n')
    binary = framework / "SherpaOnnxC"
    shutil.copyfile(mac_source / "libsherpa-onnx-c-api.dylib", binary)
    info = {"CFBundleExecutable": "SherpaOnnxC", "CFBundleIdentifier": "org.k2-fsa.SherpaOnnxC", "CFBundlePackageType": "FMWK", "CFBundleVersion": "1.13.8", "CFBundleShortVersionString": "1.13.8", "CFBundleSupportedPlatforms": ["MacOSX"]}
    (framework / "Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["install_name_tool", "-id", "@rpath/SherpaOnnxC.framework/SherpaOnnxC", str(binary)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", "--identifier", "org.k2-fsa.SherpaOnnxC", str(framework)], check=True)
    info = plistlib.loads((ios / "Info.plist").read_bytes())
    info["AvailableLibraries"].append({"LibraryIdentifier": "macos-arm64_x86_64", "LibraryPath": "SherpaOnnxC.framework", "BinaryPath": "SherpaOnnxC.framework/SherpaOnnxC", "SupportedArchitectures": ["arm64", "x86_64"], "SupportedPlatform": "macos"})
    (destination / "Info.plist").write_bytes(plistlib.dumps(info))
    verify(destination, receipt)
else:
    raise ValueError("Expected --verify or --combine with explicit local paths")
