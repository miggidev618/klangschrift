#!/usr/bin/env python3
"""Fetch the pinned public Phonon-2 release and export a local MLX safetensors model.

The app never calls this program and never downloads a model.  It is a build-time
tool: it verifies the public release archive before extracting it, then expands the
five-value encoder weights exactly to float16.  The resulting folder is intentionally
gitignored because it is a redistributable model artifact, not application source.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

import numpy as np
from safetensors.numpy import save_file

REVISION = "9c7fef3584499a88fe8d394427f45851bbb8b446"
REPOSITORY = "https://huggingface.co/fermionresearch/phonon-2/resolve/" + REVISION
ARCHIVE = "phonon-2.bps.tar.zst"
ARCHIVE_SHA256 = "98125795b6dda72f5c6eee9ba33d19815df65dcb18b50a357bf9f73c9935309e"
CONTAINER_SHA256 = "4b6bfa3a12cc3c4e0a54f2ab3ec4ca7a842b09e5c7ecfc8e7ca0ac6cc8c11468"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url: str, destination: Path) -> None:
    with urllib.request.urlopen(url) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output)


def trits(buf: bytes, out_features: int, in_features: int) -> np.ndarray:
    row_bytes = (in_features + 4) // 5
    packed = np.frombuffer(buf, dtype=np.uint8, count=out_features * row_bytes).reshape(out_features, row_bytes)
    values = np.empty((out_features, row_bytes, 5), dtype=np.uint8)
    for shift in range(5):
        values[:, :, shift] = (packed // (3 ** shift)) % 3
    return values.reshape(out_features, row_bytes * 5)[:, :in_features]


def five_value_parts(blob: bytes, shape: tuple[int, int]) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    out_features, in_features = shape
    row_bytes = (in_features + 4) // 5
    codes = trits(blob[: out_features * row_bytes], out_features, in_features)
    nonzero = codes != 1
    bit_count = int(nonzero.sum())
    bit_bytes = (bit_count + 7) // 8
    offset = out_features * row_bytes
    high = np.unpackbits(np.frombuffer(blob[offset : offset + bit_bytes], dtype=np.uint8), bitorder="little")[:bit_count]
    offset += bit_bytes
    lo = np.frombuffer(blob[offset : offset + 2 * out_features], dtype=np.float16)
    hi = np.frombuffer(blob[offset + 2 * out_features : offset + 4 * out_features], dtype=np.float16)
    if offset + 4 * out_features != len(blob):
        raise ValueError("invalid five-value record length")
    is_high = np.zeros((out_features, in_features), dtype=bool)
    is_high[nonzero] = high.astype(bool)
    magnitude = np.where(is_high, hi[:, None], lo[:, None])
    return codes.astype(np.int8) - 1, is_high, lo.copy(), hi.copy()


def five_value(blob: bytes, shape: tuple[int, int]) -> np.ndarray:
    sign, is_high, lo, hi = five_value_parts(blob, shape)
    magnitude = np.where(is_high, hi[:, None], lo[:, None])
    return (sign.astype(np.float16) * magnitude).astype(np.float16)


def pack_2bit(codes: np.ndarray) -> np.ndarray:
    """Pack 16 two-bit affine codes per uint32 in MLX's quantized_matmul layout."""
    rows, columns = codes.shape
    if columns % 16:
        raise ValueError(f"packed input width {columns} is not a multiple of 16")
    values = codes.astype(np.uint32).reshape(rows, columns // 16, 16)
    shifts = (2 * np.arange(16, dtype=np.uint32))[None, None, :]
    return (values << shifts).sum(axis=2, dtype=np.uint32)


def unpack_2bit(words: np.ndarray, columns: int) -> np.ndarray:
    shifts = (2 * np.arange(16, dtype=np.uint32))[None, None, :]
    return ((words[:, :, None] >> shifts) & 3).reshape(words.shape[0], -1)[:, :columns].astype(np.float32)


def two_plane(sign: np.ndarray, is_high: np.ndarray, lo: np.ndarray, hi: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Exact {0,+-lo,+-hi} factorization into two affine 2-bit planes.

    Plane A is sign*lo; plane B is sign*is_high*(hi-lo).  `row_delta` stays
    fp32 because the difference of two fp16 source values must not be rounded.
    """
    if np.any(is_high & (sign == 0)) or np.any(hi < lo):
        raise ValueError("invalid five-value record")
    base = pack_2bit((sign + 1).astype(np.uint8))
    residual = pack_2bit((1 + sign * is_high.astype(np.int8)).astype(np.uint8))
    return base, residual, lo.astype(np.float32), (hi.astype(np.float32) - lo.astype(np.float32))


def plane_max_delta(sign: np.ndarray, is_high: np.ndarray, lo: np.ndarray, hi: np.ndarray) -> float:
    """Independent CPU gate for an exact packed record, before it reaches MLX."""
    base, residual, row_lo, row_delta = two_plane(sign, is_high, lo, hi)
    columns = sign.shape[1]
    expanded = row_lo[:, None] * unpack_2bit(base, columns) - row_lo[:, None]
    expanded += row_delta[:, None] * unpack_2bit(residual, columns) - row_delta[:, None]
    reference = sign.astype(np.float32) * np.where(is_high, hi[:, None], lo[:, None]).astype(np.float32)
    return float(np.max(np.abs(expanded - reference)))


def int_n(blob: bytes, shape: tuple[int, ...], bits: int) -> np.ndarray:
    rows = shape[0]
    total = int(np.prod(shape))
    body, scales = blob[: -2 * rows], np.frombuffer(blob[-2 * rows :], dtype=np.float16)
    if bits == 8:
        quantized = np.frombuffer(body, dtype=np.int8).astype(np.int32)[:total]
    elif bits == 6:
        words = np.frombuffer(body, dtype=np.uint8).reshape(-1, 3).astype(np.uint32)
        packed = words[:, 0] | (words[:, 1] << 8) | (words[:, 2] << 16)
        quantized = np.stack([(packed >> shift) & 0x3F for shift in (0, 6, 12, 18)], axis=1).ravel()[:total].astype(np.int32) - 32
    else:
        raise ValueError(f"unsupported int{bits}")
    return (quantized.reshape(rows, -1).astype(np.float32) * scales.astype(np.float32)[:, None]).reshape(shape).astype(np.float16)


def read_container(path: Path) -> tuple[dict[str, np.ndarray], dict[str, tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]]]:
    with path.open("rb") as handle:
        header_length = int.from_bytes(handle.read(8), "little")
        header = json.loads(handle.read(header_length))
        if header.get("format") != "fermion-five-value-parakeet-v1":
            raise ValueError("unexpected container format")
        tensors: dict[str, np.ndarray] = {}
        packed: dict[str, tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]] = {}
        for entry in header["index"]:
            blob = handle.read(entry["b"])
            shape = tuple(entry["shape"])
            kind = entry["k"]
            name = entry["n"]
            if kind == "five_value":
                sign, is_high, lo, hi = five_value_parts(blob, shape)
                tensors[name + ".weight"] = (sign.astype(np.float16) * np.where(is_high, hi[:, None], lo[:, None])).astype(np.float16)
                packed[name + ".weight"] = two_plane(sign, is_high, lo, hi)
            elif kind.startswith("int"):
                tensors[name] = int_n(blob, shape, int(kind[3:]))
            elif kind == "fp16":
                tensors[name] = np.frombuffer(blob, dtype=np.float16).reshape(shape).copy()
            else:
                raise ValueError(f"unsupported record kind {kind}")
        if handle.read(1):
            raise ValueError("trailing data in container")
    return tensors, packed


def mlx_key(hf_key: str) -> str | None:
    """Map the documented Parakeet-TDT state dictionary into MLXAudio Swift layout."""
    if hf_key.endswith("num_batches_tracked"):
        return None
    if hf_key.startswith("encoder.subsampling.layers."):
        _, _, _, index, suffix = hf_key.split(".", 4)
        return f"encoder.pre_encode.conv.{index}.{suffix}"
    if hf_key.startswith("encoder.subsampling.linear."):
        return hf_key.replace("encoder.subsampling.linear.", "encoder.pre_encode.out.")
    if hf_key.startswith("encoder.layers."):
        parts = hf_key.split(".")
        layer, tail = parts[2], ".".join(parts[3:])
        if tail.startswith("conv.norm."):
            return f"encoder.layers.{layer}.conv.batch_norm.{tail.removeprefix('conv.norm.')}"
        attention = {"q_proj": "linear_q", "k_proj": "linear_k", "v_proj": "linear_v", "o_proj": "linear_out", "relative_k_proj": "linear_pos", "bias_u": "pos_bias_u", "bias_v": "pos_bias_v"}
        if tail.startswith("self_attn."):
            rest = tail.removeprefix("self_attn.")
            head, dot, suffix = rest.partition(".")
            if head in attention:
                return f"encoder.layers.{layer}.self_attn.{attention[head]}{dot}{suffix}"
        return hf_key
    simple = {
        "encoder_projector.": "joint.enc.",
        "decoder.decoder_projector.": "joint.pred.",
        "joint.head.": "joint.joint_net.2.",
        "decoder.embedding.weight": "decoder.prediction.embed.weight",
    }
    for old, new in simple.items():
        if hf_key.startswith(old):
            return hf_key.replace(old, new, 1)
    if hf_key.startswith("decoder.lstm."):
        suffix = hf_key.removeprefix("decoder.lstm.")
        if suffix.startswith("weight_ih_l"):
            return "decoder.prediction.dec_rnn.lstm." + suffix.removeprefix("weight_ih_l").replace("", "", 1) + ".Wx"
        if suffix.startswith("weight_hh_l"):
            return "decoder.prediction.dec_rnn.lstm." + suffix.removeprefix("weight_hh_l").replace("", "", 1) + ".Wh"
        if suffix.startswith("bias_ih_l"):
            return "decoder.prediction.dec_rnn.lstm." + suffix.removeprefix("bias_ih_l") + ".bias"
        if suffix.startswith("bias_hh_l"):
            return None
    raise ValueError(f"unmapped Phonon-2 key: {hf_key}")


def convert(tensors: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
    converted: dict[str, np.ndarray] = {}
    for key, value in tensors.items():
        target = mlx_key(key)
        if target is None:
            continue
        if key.startswith("decoder.lstm.bias_ih_l"):
            other = key.replace("bias_ih_l", "bias_hh_l")
            value = (value.astype(np.float32) + tensors[other].astype(np.float32)).astype(np.float16)
        if key.endswith("conv.pointwise_conv1.weight") or key.endswith("conv.pointwise_conv2.weight"):
            value = value[:, None, :] if value.ndim == 2 else value.transpose(0, 2, 1)
        elif key.endswith("conv.depthwise_conv.weight"):
            value = value.transpose(0, 2, 1)
        elif key.startswith("encoder.subsampling.layers.") and key.endswith(".weight"):
            value = value.transpose(0, 2, 3, 1)
        if target in converted:
            raise ValueError(f"duplicate target key: {target}")
        converted[target] = np.ascontiguousarray(value)
    return converted


def convert_packed(tensors: dict[str, np.ndarray], raw_packed: dict[str, tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]]) -> tuple[dict[str, np.ndarray], int]:
    """Keep non-five-value tensors dense, and emit exact two-plane records for the 264 encoder modules."""
    five_keys = set(raw_packed)
    dense = convert({key: value for key, value in tensors.items() if key not in five_keys})
    packed: dict[str, np.ndarray] = {}
    for source_key, (base, residual, lo, delta) in raw_packed.items():
        target = mlx_key(source_key)
        if target is None or not target.endswith(".weight"):
            raise ValueError(f"invalid packed source key {source_key}")
        stem = target.removesuffix(".weight")
        if stem + ".base_q" in packed:
            raise ValueError(f"duplicate packed target {stem}")
        packed[stem + ".base_q"] = base
        packed[stem + ".residual_q"] = residual
        packed[stem + ".row_lo"] = lo
        packed[stem + ".row_delta"] = delta
    if len(raw_packed) != 264:
        raise ValueError(f"expected 264 five-value modules, found {len(raw_packed)}")
    return dense | packed, len(raw_packed)


def extract_archive(archive: Path, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    subprocess.run(["tar", "--zstd", "-xf", str(archive), "-C", str(destination)], check=True)
    containers = list(destination.rglob("model.fermion"))
    if len(containers) != 1:
        raise RuntimeError(f"expected one model.fermion after extraction, found {len(containers)}")
    return containers[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--archive", type=Path, help="already downloaded public release archive")
    parser.add_argument("--format", choices=("dense", "packed"), default="packed",
                        help="packed is the final mobile artifact; dense is only the P1 comparison baseline")
    args = parser.parse_args()
    output = args.output.resolve()
    with tempfile.TemporaryDirectory(prefix="phonon2-export-") as temporary:
        work = Path(temporary)
        archive = args.archive.resolve() if args.archive else work / ARCHIVE
        if not args.archive:
            download(f"{REPOSITORY}/{ARCHIVE}", archive)
        actual_archive_sha = sha256(archive)
        if actual_archive_sha != ARCHIVE_SHA256:
            raise RuntimeError("public release archive SHA-256 mismatch")
        container = extract_archive(archive, work / "release")
        actual_container_sha = sha256(container)
        if actual_container_sha != CONTAINER_SHA256:
            raise RuntimeError("extracted model container SHA-256 mismatch")
        source_tensors, raw_packed = read_container(container)
        if args.format == "packed":
            tensors, five_modules = convert_packed(source_tensors, raw_packed)
            deltas = []
            # Re-read only the decoded five-value arrays for an independent gate.
            for source_key, value in source_tensors.items():
                if source_key not in raw_packed:
                    continue
                sign = np.sign(value.astype(np.float32)).astype(np.int8)
                magnitude = np.abs(value.astype(np.float32))
                _, _, lo, delta = raw_packed[source_key]
                hi = lo + delta
                is_high = np.isclose(magnitude, hi[:, None]) & (sign != 0)
                deltas.append(plane_max_delta(sign, is_high, lo.astype(np.float16), hi.astype(np.float16)))
            if len(deltas) != 264 or max(deltas, default=1.0) != 0.0:
                raise ValueError("two-plane parity gate failed")
            representation = "five-value-exact-two-plane-qmm"
        else:
            tensors = convert(source_tensors)
            five_modules = 0
            representation = "dense-fp16-exact-expansion"
        output.mkdir(parents=True, exist_ok=True)
        save_file(tensors, output / "model.safetensors", metadata={"format": "mlx", "source": "phonon-2", "source_revision": REVISION, "source_container_sha256": actual_container_sha, "representation": representation})
        shutil.copy2(container.parent / "config.json", output / "config.json")
        trained_tensors = len(convert(source_tensors))
        model_path = output / "model.safetensors"
        config_path = output / "config.json"
        receipt = {"source_revision": REVISION, "archive_sha256": actual_archive_sha, "container_sha256": actual_container_sha, "trained_tensors": trained_tensors, "stored_tensors": len(tensors), "five_value_modules": five_modules, "group_size": 128 if args.format == "packed" else None, "bits_per_plane": 2 if args.format == "packed" else None, "planes": 2 if args.format == "packed" else None, "plane_parity_modules": len(deltas) if args.format == "packed" else 0, "plane_parity_max_abs_delta": max(deltas, default=0.0) if args.format == "packed" else 0.0, "representation": representation, "safetensors_bytes": model_path.stat().st_size, "safetensors_sha256": sha256(model_path), "config_bytes": config_path.stat().st_size, "config_sha256": sha256(config_path)}
        (output / "export-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(receipt, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
