#!/bin/zsh
# Build a local, ad-hoc-signed app bundle. It neither installs nor launches it.
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
output=''
python=''
site_packages=''

usage() {
  print -u2 'Usage: Scripts/build.sh --output /absolute/path/Klangschrift.app --python /path/to/python3.14 --site-packages /path/to/site-packages'
  exit 64
}

while (( $# )); do
  case "$1" in
    --output) output=${2-}; shift 2 ;;
    --python) python=${2-}; shift 2 ;;
    --site-packages) site_packages=${2-}; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$output" == /* && "$output" == *.app && ! -e "$output" ]] || usage
[[ -x "$python" && "$site_packages" == /* && -d "$site_packages" ]] || usage
python=${python:A}
[[ $("$python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")') == 3.14 ]] || { print -u2 'Python 3.14 is required.'; exit 65; }
"$python" - "$site_packages" Helper/mlx-helper/requirements.lock <<'PYTHON_LOCK_CHECK'
from pathlib import Path
import re
import sys

site_packages, lock = map(Path, sys.argv[1:])
normalize = lambda value: re.sub(r"[-_.]+", "-", value).lower()
expected = {}
for line in lock.read_text(encoding="utf-8").splitlines():
    if match := re.match(r"^([A-Za-z0-9_.-]+)==([^\s]+)", line):
        name = normalize(match.group(1))
        if name in expected:
            print(f"duplicate normalized lock name: {name}", file=sys.stderr)
            raise SystemExit(68)
        expected[name] = match.group(2)
actual = {}
for dist_info in site_packages.glob("*.dist-info"):
    metadata = dist_info / "METADATA"
    if not metadata.is_file():
        continue
    for line in metadata.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("Name: "):
            name = normalize(line.removeprefix("Name: "))
            if name in actual:
                print(f"duplicate normalized installed name: {name}", file=sys.stderr)
                raise SystemExit(68)
            version = next((item.removeprefix("Version: ") for item in metadata.read_text(encoding="utf-8", errors="replace").splitlines() if item.startswith("Version: ")), None)
            if version is None:
                print(f"missing installed version: {name}", file=sys.stderr)
                raise SystemExit(68)
            actual[name] = version
            break
if actual != expected:
    print("site-packages does not exactly match requirements.lock", file=sys.stderr)
    print("missing: " + ", ".join(sorted(expected.keys() - actual.keys())), file=sys.stderr)
    print("extra: " + ", ".join(sorted(actual.keys() - expected.keys())), file=sys.stderr)
    print("version mismatch: " + ", ".join(f"{name}={actual[name]} (lock {expected[name]})" for name in sorted(actual.keys() & expected.keys()) if actual[name] != expected[name]), file=sys.stderr)
    raise SystemExit(68)
PYTHON_LOCK_CHECK

version_root=${python:h:h}
[[ ${version_root:t} == 3.14 && -d "$version_root" ]] || { print -u2 'Expected Python.framework/Versions/3.14/bin/python3.14.'; exit 65; }

cd "$repo_root"
./Scripts/bootstrap-moonshine-macos.sh
swift build -c release -j 2 --product KlangschriftApp
swift build -c release -j 2 --product KlangschriftDesktopNativeWorker
swift build -c release -j 2 --product KlangschriftDesktopModelInstaller

products="$repo_root/.build/release"
for executable in KlangschriftApp KlangschriftDesktopNativeWorker KlangschriftDesktopModelInstaller; do
  [[ -x "$products/$executable" ]] || { print -u2 "Missing product: $executable"; exit 66; }
done
for bundle in Klangschrift_KlangschriftPresentation.bundle Klangschrift_KlangschriftUI.bundle KlangschriftDesktopFluidAudio_FluidAudio.bundle; do
  [[ -d "$products/$bundle" ]] || { print -u2 "Missing SwiftPM resource bundle: $bundle"; exit 66; }
done

stage=$(mktemp -d /private/tmp/klangschrift-public-app.XXXXXX)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
app="$stage/Klangschrift.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Helper" "$app/Contents/Resources/Runtime/Python.framework/Versions" "$app/Contents/Resources/Brand" "$app/Contents/Resources/Notices"
cp Resources/Info.plist.template "$app/Contents/Info.plist"
cp "$products/KlangschriftApp" "$app/Contents/MacOS/Klangschrift"
cp "$products/KlangschriftDesktopNativeWorker" "$app/Contents/MacOS/"
cp "$products/KlangschriftDesktopModelInstaller" "$app/Contents/MacOS/"
for executable in Klangschrift KlangschriftDesktopNativeWorker KlangschriftDesktopModelInstaller; do
  xcrun strip -S "$app/Contents/MacOS/$executable"
done
cp Helper/mlx-helper/klangschrift_mlx_helper.py "$app/Contents/Resources/Helper/"
cp Vendor/ModelCatalog/AP04-REFERENCE-MANIFESTS.json "$app/Contents/Resources/"
cp Resources/Brand/KlangschriftLogoOchre.png "$app/Contents/Resources/Brand/"
cp "$repo_root/../LICENSE" "$app/Contents/Resources/Notices/GPL-3.0-only.txt"
for bundle in Klangschrift_KlangschriftPresentation.bundle Klangschrift_KlangschriftUI.bundle KlangschriftDesktopFluidAudio_FluidAudio.bundle; do
  ditto --norsrc --noextattr --noacl "$products/$bundle" "$app/Contents/Resources/$bundle"
done
mkdir -p "$app/Contents/Resources/Notices/SDKs"
for notice in \
  Vendor/ModelCatalog/NOTICE.md \
  Vendor/DesktopSDKs/FluidAudio/LICENSE \
  Vendor/DesktopSDKs/Attribution/WhisperKit-LICENSE \
  Vendor/DesktopSDKs/Attribution/WhisperKit-NOTICES \
  Vendor/DesktopSDKs/Attribution/iOS-NOTICE.md; do
  cp "$notice" "$app/Contents/Resources/Notices/SDKs/${notice:t}"
done
ditto --norsrc --noextattr --noacl "$version_root" "$app/Contents/Resources/Runtime/Python.framework/Versions/3.14"
rm -rf "$app/Contents/Resources/Runtime/Python.framework/Versions/3.14/lib/python3.14/test"
runtime_site="$app/Contents/Resources/Runtime/Python.framework/Versions/3.14/lib/python3.14/site-packages"
rm -rf "$runtime_site"
mkdir -p "${runtime_site:h}"
rsync -aL --delete "$site_packages/" "$runtime_site/"
if find -L "$runtime_site" -type l -print -quit | grep -q .; then
  print -u2 "Unresolved symlink in copied site-packages"
  exit 67
fi
"$python" - "$site_packages" "$app/Contents/Resources/Notices/Python" <<'PYTHON_NOTICES'
from pathlib import Path
import shutil
import sys

site_packages, notices = map(Path, sys.argv[1:])
notices.mkdir(parents=True, exist_ok=True)
inventory = []
for dist_info in sorted(site_packages.glob("*.dist-info"), key=lambda path: path.name.lower()):
    distribution = dist_info.name
    metadata = dist_info / "METADATA"
    if metadata.is_file():
        for line in metadata.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("Name: "):
                distribution = line.removeprefix("Name: ")
                break
    inventory.append(f"{distribution}\t{dist_info.name}")
    candidates = [dist_info / name for name in ("LICENSE", "LICENSE.txt", "COPYING", "NOTICE")]
    licenses_dir = dist_info / "licenses"
    if licenses_dir.is_dir():
        candidates.extend(path for path in sorted(licenses_dir.rglob("*")) if path.is_file())
    for source in candidates:
        if not source.is_file():
            continue
        relative = source.relative_to(dist_info)
        destination = notices / dist_info.name / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
(notices / "INVENTORY.txt").write_text("\n".join(inventory) + "\n", encoding="utf-8")
PYTHON_NOTICES
ln -s 3.14 "$app/Contents/Resources/Runtime/Python.framework/Versions/Current"
ln -s Versions/Current/Python "$app/Contents/Resources/Runtime/Python.framework/Python"
ln -s Versions/Current/Resources "$app/Contents/Resources/Runtime/Python.framework/Resources"

iconset="$stage/Klangschrift.iconset"
mkdir "$iconset"
for spec in '16 icon_16x16.png' '32 icon_16x16@2x.png' '32 icon_32x32.png' '64 icon_32x32@2x.png' '128 icon_128x128.png' '256 icon_128x128@2x.png' '256 icon_256x256.png' '512 icon_256x256@2x.png' '512 icon_512x512.png' '1024 icon_512x512@2x.png'; do
  size=${spec%% *}; name=${spec#* }; sips -s format png -z "$size" "$size" Resources/Brand/KlangschriftLogoOchre.png --out "$iconset/$name" >/dev/null
done
iconutil --convert icns --output "$app/Contents/Resources/Klangschrift.icns" "$iconset"

find "$app" -type f -exec chmod 644 {} +
chmod 755 "$app/Contents/MacOS/"* "$app/Contents/Resources/Runtime/Python.framework/Versions/3.14/bin/python3.14"
codesign --force --deep --sign - --options runtime --timestamp=none "$app/Contents/Resources/Runtime/Python.framework"
codesign --verify --deep --strict "$app/Contents/Resources/Runtime/Python.framework"
codesign --force --sign - --options runtime --timestamp=none "$app/Contents/MacOS/KlangschriftDesktopNativeWorker"
codesign --force --sign - --options runtime --timestamp=none "$app/Contents/MacOS/KlangschriftDesktopModelInstaller"
codesign --force --sign - --options runtime --timestamp=none --entitlements Resources/Klangschrift.entitlements "$app/Contents/MacOS/Klangschrift"
codesign --verify --deep --strict "$app"
mkdir -p "${output:h}"
mv "$app" "$output"
trap - EXIT HUP INT TERM
print -r -- "$output"
