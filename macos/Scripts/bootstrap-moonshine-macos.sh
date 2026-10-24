#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="$root/Vendor/DesktopSDKs/Moonshine/Moonshine.xcframework"
url="https://github.com/moonshine-ai/moonshine/releases/download/v0.1.5/moonshine-voice-macos-arm64.tar.gz"
expected="51151f98eb1b20b8fc141bab361a1574dbfdbef8300b632ee6679e373112e0f6"
expected_library="754f894267cc4f45af8cc91cae8acf483dba6ce7bd987e7f85f0dec737293ae6"
stage="$(mktemp -d "${TMPDIR:-/tmp}/klangschrift-moonshine.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

if [[ -f "$sdk/macos-arm64/libmoonshine.a" ]] && [[ "$(shasum -a 256 "$sdk/macos-arm64/libmoonshine.a" | awk '{print $1}')" == "$expected_library" ]]; then
  print "Moonshine v0.1.5 macOS SDK already installed and verified."
  exit 0
fi

curl --fail --location --proto '=https' --proto-redir '=https' "$url" -o "$stage/moonshine.tar.gz"
actual="$(shasum -a 256 "$stage/moonshine.tar.gz" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || { print -u2 "Moonshine archive hash mismatch"; exit 1; }
tar -xzf "$stage/moonshine.tar.gz" -C "$stage"
mkdir -p "$sdk/macos-arm64/Headers"
cp "$stage/moonshine-voice-macos-arm64/lib/libmoonshine.a" "$sdk/macos-arm64/libmoonshine.a"
[[ "$(shasum -a 256 "$sdk/macos-arm64/libmoonshine.a" | awk '{print $1}')" == "$expected_library" ]] || { print -u2 "Moonshine library hash mismatch"; exit 1; }
cp "$stage/moonshine-voice-macos-arm64/include/"*.h "$sdk/macos-arm64/Headers/"
cat > "$sdk/macos-arm64/Headers/module.modulemap" <<'MODULEMAP'
module Moonshine {
    umbrella header "moonshine-c-api.h"
    export *
    module * { export * }
}
MODULEMAP
cat > "$sdk/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>AvailableLibraries</key><array><dict><key>BinaryPath</key><string>libmoonshine.a</string><key>HeadersPath</key><string>Headers</string><key>LibraryIdentifier</key><string>macos-arm64</string><key>LibraryPath</key><string>libmoonshine.a</string><key>SupportedArchitectures</key><array><string>arm64</string></array><key>SupportedPlatform</key><string>macos</string></dict></array><key>CFBundlePackageType</key><string>XFWK</string><key>XCFrameworkFormatVersion</key><string>1.0</string></dict></plist>
PLIST
print "Moonshine v0.1.5 macOS SDK installed and verified."
