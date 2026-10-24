#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
whisper="$root/Vendor/WhisperKit"
whisper_commit=1e2a163736dfa5a198e637ae44c114e1c6d5cc2d
patch="$root/Patches/whisperkit-local-tokenizer.patch"
if [[ ! -e "$whisper" ]]; then
  git clone --filter=blob:none --no-checkout https://github.com/argmaxinc/argmax-oss-swift.git "$whisper"
  git -C "$whisper" fetch --depth 1 origin "$whisper_commit"
  git -C "$whisper" checkout --detach "$whisper_commit"
fi
[[ -d "$whisper/.git" && "$(git -C "$whisper" rev-parse HEAD)" == "$whisper_commit" ]] || { print -u2 "WhisperKit checkout does not match fixed release commit"; exit 1; }
if git -C "$whisper" diff --quiet; then
  git -C "$whisper" apply --check "$patch"
  git -C "$whisper" apply "$patch"
else
  # An already patched checkout is accepted only when its complete tracked diff
  # matches this exact offline patch. Unrelated edits are never reset.
  cmp -s <(git -C "$whisper" diff --binary) "$patch" || { print -u2 "WhisperKit has edits outside the fixed offline patch"; exit 1; }
  git -C "$whisper" apply --reverse --check "$patch"
fi

sdk="$root/Vendor/Sherpa/SherpaOnnxC.xcframework"
if [[ ! -d "$sdk" ]]; then
  stage="$(mktemp -d "${TMPDIR:-/tmp}/klangschrift-p23-sdk.XXXXXX")"
  trap 'rm -rf "$stage"' EXIT
  ios_zip="${KLANGSCHRIFT_SHERPA_IOS_ARCHIVE:-$stage/ios.zip}"
  mac_zip="${KLANGSCHRIFT_SHERPA_MACOS_ARCHIVE:-$stage/macos.zip}"
  [[ -f "$ios_zip" ]] || curl --fail --location --proto '=https' --proto-redir '=https' https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-ios-shared-onnxruntime-static.xcframework.zip -o "$ios_zip"
  [[ -f "$mac_zip" ]] || curl --fail --location --proto '=https' --proto-redir '=https' https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-macos-shared-onnxruntime-static.xcframework.zip -o "$mac_zip"
  [[ "$(shasum -a 256 "$ios_zip" | awk '{print $1}')" == e259a7d3b38ad7dec49bb078252a30bb42ede8355e2bb130cf8c1c78ed131f75 ]] || { print -u2 "Sherpa iOS archive hash mismatch"; exit 1; }
  [[ "$(shasum -a 256 "$mac_zip" | awk '{print $1}')" == 82d5cb3af38c3cb4871c3532a6c7dc86d6b7db1077bcc9d6a1047100976f199b ]] || { print -u2 "Sherpa macOS archive hash mismatch"; exit 1; }
  ditto -x -k "$ios_zip" "$stage/ios"
  ditto -x -k "$mac_zip" "$stage/macos"
  python3 "$root/Tools/verify_sherpa_sdk.py" --combine "$stage/ios/SherpaOnnxC.xcframework" "$stage/macos/sherpa-onnx.xcframework" "$stage/combined.xcframework" "$root/Vendor/Sherpa/SOURCE.json"
  mv "$stage/combined.xcframework" "$sdk"
fi
python3 "$root/Tools/verify_sherpa_sdk.py" --verify "$sdk" "$root/Vendor/Sherpa/SOURCE.json"
print "P23 SDK bootstrap verified (Whisper offline patch; Sherpa fixed archive slices)"
