#!/usr/bin/env python3
"""Local-only MLX helper. Parent owns hard timeout: terminate and reap this process."""
from __future__ import annotations
import hashlib, json, math, os, re, stat, struct, sys, threading, wave
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Callable

PROTOCOL_VERSION, MAX_FRAME_BYTES, MAX_AUDIO_BYTES, MAX_DURATION_SECONDS, MAX_TEXT_CHARS = 1, 1_048_576, 256 * 1024 * 1024, 30 * 60, 100_000
REQUEST_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
LANGUAGES = {None, "auto", "de", "en", "fr", "es", "it", "pt", "nl"}
class ProtocolError(ValueError): pass
class EngineResultError(RuntimeError): pass

def _read_exact(stream: BinaryIO, length: int) -> bytes:
    result = bytearray()
    while len(result) < length:
        piece = stream.read(length - len(result))
        if not piece: raise EOFError("unexpected EOF")
        result.extend(piece)
    return bytes(result)
def read_frame(stream: BinaryIO) -> dict:
    length = struct.unpack(">I", _read_exact(stream, 4))[0]
    if not 0 < length <= MAX_FRAME_BYTES: raise ProtocolError("invalid frame")
    value = json.loads(_read_exact(stream, length).decode("utf-8"))
    if not isinstance(value, dict): raise ProtocolError("invalid frame")
    return value
def write_frame(stream: BinaryIO, value: dict) -> None:
    payload = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if len(payload) > MAX_FRAME_BYTES: raise ProtocolError("response too large")
    stream.write(struct.pack(">I", len(payload)) + payload); stream.flush()
def safe_write_frame(stream: BinaryIO, value: dict) -> None:
    try: write_frame(stream, value)
    except Exception:
        try: write_frame(stream, {"version": PROTOCOL_VERSION, "id": None, "status": "error", "code": "response_unavailable"})
        except Exception: pass
def error_code(error: Exception) -> str:
    if isinstance(error, ProtocolError): return "invalid_request"
    if isinstance(error, FileNotFoundError): return "audio_unavailable"
    return "engine_error"
def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1_048_576), b""): digest.update(block)
    return digest.hexdigest()
_model_validation_cache: dict[tuple, bool] = {}
def _secure_file(path: Path) -> os.stat_result:
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or (stat.S_IMODE(info.st_mode) & 0o022): raise ProtocolError("invalid model")
    return info
def _validated_model_file(model: Path, blob_root: Path, name: str) -> tuple[Path, os.stat_result]:
    candidate = model / name
    if candidate.is_symlink():
        target = candidate.resolve(strict=True)
        if blob_root == target or blob_root not in target.parents: raise ProtocolError("invalid model")
    else:
        target = candidate.resolve(strict=True)
        if target.parent != model: raise ProtocolError("invalid model")
    return target, _secure_file(target)
def _validate_model(path: Path) -> tuple:
    if not path.is_absolute() or path.is_symlink() or not path.is_dir() or path.name == "": raise ProtocolError("invalid model")
    path = path.resolve(strict=True)
    # HF snapshot layout: models--name/snapshots/revision with content symlinked only into models--name/blobs.
    if path.parent.name != "snapshots": raise ProtocolError("invalid model")
    blob_root = path.parent.parent / "blobs"
    if blob_root.is_symlink() or not blob_root.is_dir(): raise ProtocolError("invalid model")
    blob_root = blob_root.resolve(strict=True)
    weights_names = [name for name in ("weights.npz", "weights.safetensors") if (path / name).exists()]
    if len(weights_names) != 1: raise ProtocolError("invalid model")
    files = [_validated_model_file(path, blob_root, name) for name in ("config.json", weights_names[0])]
    expected = tuple(os.environ.get(key, "") for key in ("KLANGSCHRIFT_MODEL_CONFIG_SHA256", "KLANGSCHRIFT_MODEL_WEIGHTS_SHA256"))
    if not all(expected) or any(not re.fullmatch(r"[a-f0-9]{64}", value) for value in expected): raise ProtocolError("invalid model")
    fingerprint = (str(path.resolve()), str(blob_root.resolve()), expected) + tuple((str(target), info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns) for target, info in files)
    if fingerprint in _model_validation_cache: return fingerprint
    for (target, _), expected_hash in zip(files, expected):
        if expected_hash and _sha256(target) != expected_hash: raise ProtocolError("invalid model")
    _model_validation_cache.clear(); _model_validation_cache[fingerprint] = True
    return fingerprint
def validate_audio_root(path: Path) -> Path:
    if not path.is_absolute() or path.is_symlink(): raise ProtocolError("invalid audio root")
    resolved = path.resolve(strict=True); info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or (stat.S_IMODE(info.st_mode) & 0o077): raise ProtocolError("invalid audio root")
    return resolved
def resolve_audio(audio_root: Path, requested: str) -> Path:
    candidate = Path(requested)
    if not candidate.is_absolute() or candidate.is_symlink(): raise ProtocolError("invalid audio")
    root = audio_root.resolve(strict=True)
    resolved = candidate.resolve(strict=True)
    if root == resolved or root not in resolved.parents: raise ProtocolError("invalid audio")
    info = resolved.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or (stat.S_IMODE(info.st_mode) & 0o077): raise ProtocolError("invalid audio")
    if info.st_size > MAX_AUDIO_BYTES: raise ProtocolError("invalid audio")
    return resolved
def load_canonical_audio(wav_path: Path):
    with wave.open(str(wav_path), "rb") as reader:
        if reader.getnchannels() != 1 or reader.getsampwidth() != 2 or reader.getframerate() != 16_000 or reader.getcomptype() != "NONE": raise ProtocolError("invalid audio")
        frames, rate = reader.getnframes(), reader.getframerate()
        if frames / max(rate, 1) > MAX_DURATION_SECONDS: raise ProtocolError("invalid audio")
        raw = reader.readframes(frames)
    if len(raw) > MAX_AUDIO_BYTES: raise ProtocolError("invalid audio")
    # P3 already owns canonical 16 kHz mono PCM16 WAV creation. Passing the
    # waveform directly keeps the helper offline and independent of ffmpeg or
    # PATH lookup inside mlx_whisper.
    import numpy as np
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
def is_empty_or_all_zero_pcm(samples) -> bool:
    """Only deterministic empty/zero PCM skips the pinned Whisper path."""
    if samples.size == 0: return True
    import numpy as np
    return bool(np.all(samples == 0))

def _finite_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)

def validate_transcription_result(result: object, *, tokenizer: object | None = None, audio_duration: float | None = None) -> str:
    """Validate the complete upstream result before applying the No-Speech veto.

    A mixed result may preserve only its accepted, ordered segments.  That path
    requires the resident-model tokenizer and a bound PCM duration; otherwise it
    closes rather than making a text selection from unbound metadata.
    """
    if not isinstance(result, dict): raise EngineResultError("invalid engine result")
    text, segments = result.get("text"), result.get("segments")
    if not isinstance(text, str) or not isinstance(segments, list): raise EngineResultError("invalid engine result")
    if len(text) > MAX_TEXT_CHARS: raise EngineResultError("invalid engine result")
    if not text:
        if segments != []: raise EngineResultError("invalid engine result")
        return ""
    if not segments: raise EngineResultError("invalid engine result")
    if tokenizer is None:
        eot, decode, n_vocab = None, None, None
    else:
        eot, decode = getattr(tokenizer, "eot", None), getattr(tokenizer, "decode", None)
        if not isinstance(eot, int) or isinstance(eot, bool) or eot <= 0 or not callable(decode): raise EngineResultError("invalid engine result")
        encoding, n_vocab = getattr(tokenizer, "encoding", None), getattr(getattr(tokenizer, "encoding", None), "n_vocab", None)
        if encoding is None or not isinstance(n_vocab, int) or isinstance(n_vocab, bool) or n_vocab <= eot: raise EngineResultError("invalid engine result")
    accepted, vetoed, parts, selected, all_text_tokens = False, False, [], [], []
    previous_seek, previous_end, same_seek_scores = None, None, {}
    for segment in segments:
        if not isinstance(segment, dict): raise EngineResultError("invalid engine result")
        required = ("seek", "start", "end", "text", "tokens", "temperature", "avg_logprob", "compression_ratio", "no_speech_prob")
        if any(key not in segment for key in required): raise EngineResultError("invalid engine result")
        seek, start, end, segment_text, tokens = (segment[key] for key in ("seek", "start", "end", "text", "tokens"))
        if not isinstance(seek, int) or isinstance(seek, bool) or seek < 0 or not isinstance(segment_text, str) or not isinstance(tokens, list) or any(not isinstance(token, int) or isinstance(token, bool) or token < 0 or (n_vocab is not None and token >= n_vocab) for token in tokens): raise EngineResultError("invalid engine result")
        if not _finite_number(start) or not _finite_number(end) or start < 0 or end < start: raise EngineResultError("invalid engine result")
        temperature, logprob, compression, no_speech = (segment[key] for key in ("temperature", "avg_logprob", "compression_ratio", "no_speech_prob"))
        if not all(_finite_number(value) for value in (temperature, logprob, compression, no_speech)) or not 0 <= no_speech <= 1: raise EngineResultError("invalid engine result")
        if previous_seek is not None and (seek < previous_seek or start < previous_end): raise EngineResultError("invalid engine result")
        scores = (temperature, logprob, compression, no_speech)
        if seek in same_seek_scores and same_seek_scores[seek] != scores: raise EngineResultError("invalid engine result")
        same_seek_scores[seek] = scores; previous_seek, previous_end = seek, end
        # Upstream keeps cleared whitespace nodes in the segment stream with their
        # original bounded duration.  Only this exact empty-text/empty-token form
        # is neutral; all other text/token mismatches remain malformed below.
        cleared = segment_text == "" and tokens == []
        if not cleared and (not segment_text or not tokens): raise EngineResultError("invalid engine result")
        text_tokens = [token for token in tokens if token < eot] if eot is not None else []
        if decode is not None:
            try: decoded = decode(text_tokens)
            except Exception as error: raise EngineResultError("invalid engine result") from error
            if not isinstance(decoded, str) or decoded != segment_text: raise EngineResultError("invalid engine result")
            all_text_tokens.extend(text_tokens)
        parts.append(segment_text)
        if cleared: continue
        if no_speech > 0.6:
            vetoed = True
        else:
            accepted = True; selected.append((segment_text, tokens, start))
    if "".join(parts) != text: raise EngineResultError("invalid engine result")
    if decode is not None:
        try: decoded_text = decode(all_text_tokens)
        except Exception as error: raise EngineResultError("invalid engine result") from error
        if not isinstance(decoded_text, str) or decoded_text != text: raise EngineResultError("invalid engine result")
    if not accepted: return ""
    if not vetoed: return text
    if tokenizer is None or not _finite_number(audio_duration) or audio_duration <= 0: raise EngineResultError("invalid engine result")
    selected_parts, selected_tokens = [], []
    for segment_text, tokens, start in selected:
        if start >= audio_duration: raise EngineResultError("invalid engine result")
        text_tokens = [token for token in tokens if token < eot]
        try: decoded = decode(text_tokens)
        except Exception as error: raise EngineResultError("invalid engine result") from error
        if not isinstance(decoded, str) or decoded != segment_text: raise EngineResultError("invalid engine result")
        selected_parts.append(segment_text); selected_tokens.extend(text_tokens)
    try: selected_text = decode(selected_tokens)
    except Exception as error: raise EngineResultError("invalid engine result") from error
    if not isinstance(selected_text, str) or selected_text != "".join(selected_parts): raise EngineResultError("invalid engine result")
    return selected_text

@dataclass
class LocalEngine:
    model_path: Path
    _transcribe: Callable | None = None
    _warm_model_path: str | None = None
    _warm_model_identity: tuple | None = None
    _warm_model: object | None = None
    def configured(self) -> bool:
        try: _validate_model(self.model_path); return True
        except Exception: return False
    def import_function(self) -> None:
        _validate_model(self.model_path)
        if self._transcribe is None:
            os.environ.update({"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1"})
            from mlx_whisper import transcribe
            self._transcribe = transcribe
    @property
    def function_imported(self) -> bool: return self._transcribe is not None
    @property
    def model_warm(self) -> bool:
        try: return self._warm_model_path == str(self.model_path.resolve(strict=True)) and self._warm_model_identity == _validate_model(self.model_path)
        except Exception: return False
    def prepare(self) -> None:
        """Validate pinned local bytes, then materialize the exact fp16 model once.

        `prepared` on the wire is intentionally stronger than a successful
        function import: it is emitted only after ModelHolder accepted this
        validated local snapshot and MLX evaluated its parameters.  The helper
        never supplies a repository id, so the upstream fallback downloader is
        unreachable from this path.
        """
        identity = _validate_model(self.model_path)
        self.import_function()
        model_path = str(self.model_path.resolve(strict=True))
        if self._warm_model_path == model_path and self._warm_model_identity == identity: return
        from mlx.core import eval as mlx_eval, float16
        from mlx_whisper.transcribe import ModelHolder
        model = ModelHolder.get_model(model_path, float16)
        if model is None or getattr(ModelHolder, "model_path", None) != model_path: raise ProtocolError("invalid model")
        parameters = getattr(model, "parameters", None)
        if not callable(parameters): raise ProtocolError("invalid model")
        mlx_eval(parameters())
        if _validate_model(self.model_path) != identity: raise ProtocolError("invalid model")
        self._warm_model_path, self._warm_model_identity, self._warm_model = model_path, identity, model
    def _result_tokenizer(self, result: object):
        if not isinstance(result, dict) or not isinstance(result.get("language"), str) or self._warm_model is None: raise EngineResultError("invalid engine result")
        multilingual, num_languages = getattr(self._warm_model, "is_multilingual", None), getattr(self._warm_model, "num_languages", None)
        if not isinstance(multilingual, bool) or not isinstance(num_languages, int) or isinstance(num_languages, bool) or num_languages <= 0: raise EngineResultError("invalid engine result")
        try:
            from mlx_whisper.tokenizer import get_tokenizer
            return get_tokenizer(multilingual, num_languages=num_languages, language=result["language"], task="transcribe")
        except Exception as error: raise EngineResultError("invalid engine result") from error
    def transcribe(self, audio: Path, language: str | None) -> str:
        samples = load_canonical_audio(audio)
        if is_empty_or_all_zero_pcm(samples): return ""  # avoids importing MLX for deterministic silence
        self.prepare()
        # Keep the same canonical snapshot spelling used by prepare().  On
        # macOS `/var` and `/private/var` may name the same bytes but are
        # distinct ModelHolder cache keys.
        result = self._transcribe(samples, path_or_hf_repo=str(self.model_path.resolve(strict=True)), language=None if language == "auto" else language, verbose=None, condition_on_previous_text=False)
        text = validate_transcription_result(result, tokenizer=self._result_tokenizer(result), audio_duration=samples.size / 16_000.0)
        return text

class Service:
    def __init__(self, engine: LocalEngine, audio_root: Path): self.engine, self.audio_root, self.lock, self.shutdown_requested = engine, validate_audio_root(audio_root), threading.Lock(), False
    def handle(self, request: dict, identifier: str | None = None) -> dict:
        identifier = identifier if identifier is not None else validate_envelope(request); operation = request.get("op")
        if operation == "health": return {"version": PROTOCOL_VERSION, "id": identifier, "status": "prepared" if self.engine.model_warm else "configured" if self.engine.configured() else "misconfigured"}
        if operation == "shutdown": self.shutdown_requested = True; return {"version": PROTOCOL_VERSION, "id": identifier, "status": "shutdown"}
        if operation == "prepare": self.engine.prepare(); return {"version": PROTOCOL_VERSION, "id": identifier, "status": "prepared"}
        if operation != "transcribe": raise ProtocolError("unsupported operation")
        language = request.get("language", "auto")
        if language not in LANGUAGES: raise ProtocolError("invalid language")
        audio = resolve_audio(self.audio_root, request.get("audio_path", ""))
        with self.lock:  # Serial. Parent terminates/reaps this helper for an in-flight cancel or hard timeout.
            text = self.engine.transcribe(audio, language)
        if not text:
            return {"version": PROTOCOL_VERSION, "id": identifier, "status": "silence"}
        return {"version": PROTOCOL_VERSION, "id": identifier, "status": "ok", "text": text}
def validate_envelope(request: dict) -> str:
    identifier = request.get("id")
    if request.get("version") != PROTOCOL_VERSION or not isinstance(identifier, str) or not REQUEST_ID.fullmatch(identifier): raise ProtocolError("invalid envelope")
    return identifier
def handle_request(service: Service, request: dict) -> dict:
    identifier = None
    try:
        identifier = validate_envelope(request)
        return service.handle(request, identifier=identifier)
    except Exception as error:
        return {"version": PROTOCOL_VERSION, "id": identifier, "status": "error", "code": error_code(error)}
def main() -> int:
    model_path, audio_root = os.environ.get("KLANGSCHRIFT_MODEL_PATH", ""), os.environ.get("KLANGSCHRIFT_AUDIO_ROOT", "")
    if not model_path or not audio_root: return 2
    service = Service(LocalEngine(Path(model_path)), Path(audio_root))
    while not service.shutdown_requested:
        try: request = read_frame(sys.stdin.buffer)
        except EOFError: return 0
        except Exception as error: safe_write_frame(sys.stdout.buffer, {"version": PROTOCOL_VERSION, "id": None, "status": "error", "code": error_code(error)}); continue
        response = handle_request(service, request)
        safe_write_frame(sys.stdout.buffer, response)
    return 0
if __name__ == "__main__": raise SystemExit(main())
