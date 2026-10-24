#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
install_vendor() {
  local target="$1" url="$2" commit="$3" patch="$4"
  if [[ -e "$target" ]]; then
    [[ -d "$target/.git" ]] || { print -u2 "existing vendor is not a git checkout: $target"; exit 1; }
    [[ "$(git -C "$target" status --porcelain)" == "" ]] || { print -u2 "refusing to overwrite edited vendor: $target"; exit 1; }
  else
    git clone "$url" "$target"
  fi
  git -C "$target" checkout --detach "$commit"
  if [[ -n "$patch" ]]; then git -C "$target" apply --check "$patch"; git -C "$target" apply "$patch"; fi
}
install_vendor "$root/Vendor/mlx-swift" https://github.com/ml-explore/mlx-swift.git 19601207e9a0de51e03ee6ec0c3c5f3784275075 "$root/Patches/mlx-swift-batchnorm.patch"
git -C "$root/Vendor/mlx-swift" submodule update --init --recursive
install_vendor "$root/Vendor/mlx-audio-swift" https://github.com/Blaizzy/mlx-audio-swift.git 8d86630ade569728aaea3dc1a29fc44e2efa719b "$root/Patches/mlx-audio-swift-phonon.patch"
install_vendor "$root/Vendor/FluidAudio" https://github.com/FluidInference/FluidAudio.git 0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7 "$root/Patches/fluidaudio-offline-local.patch"
install_vendor "$root/Vendor/Moonshine" https://github.com/moonshine-ai/moonshine-swift.git 45a14f9edf1f2a6913d3aff38c1fd4e72d5b7daa "$root/Patches/moonshine-local-binary.patch"
# Binary provenance is fixed by upstream v0.1.5 SHA-256. Pass a downloaded archive
# explicitly; this bootstrap never silently retrieves an unverified framework.
if [[ ! -d "$root/Vendor/Moonshine/Moonshine.xcframework" ]]; then
  archive="${KLANGSCHRIFT_MOONSHINE_ARCHIVE:-}"
  [[ -f "$archive" ]] || { print -u2 "Set KLANGSCHRIFT_MOONSHINE_ARCHIVE to the upstream v0.1.5 Moonshine.xcframework.zip"; exit 1; }
  [[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "6bc7fb4b6d3a470a2ae2d681299975f3ba9d710753786d1cd7e8beabaad066e8" ]] || { print -u2 "Moonshine archive hash mismatch"; exit 1; }
  ditto -x -k "$archive" "$root/Vendor/Moonshine"
fi

# P23 SDKs: standalone idempotent verifier/acquisition; never downloads model weights.
zsh "$root/Tools/bootstrap_p23_vendors.sh"
