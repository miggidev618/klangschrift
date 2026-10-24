import io, json, os, stat, struct, subprocess, sys, tempfile, types, unittest, wave
import numpy as np
sys.dont_write_bytecode = True
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).parent))
import klangschrift_mlx_helper as helper

class ProtocolTests(unittest.TestCase):
    def test_all_settings_languages_pass_real_request_parser(self):
        class Engine:
            def __init__(self): self.languages = []
            def transcribe(self, audio, language): self.languages.append(language); return "fixture"
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); os.chmod(root, 0o700)
            audio = self.make_audio(root); engine = Engine(); service = helper.Service(engine, root)
            languages = [None, "auto", "de", "en", "fr", "es", "it", "pt", "nl"]
            for language in languages:
                response = helper.handle_request(service, {"version": 1, "id": "language", "op": "transcribe", "audio_path": str(audio), "language": language})
                self.assertEqual(response["status"], "ok")
            self.assertEqual(engine.languages, languages)
            self.assertEqual(helper.handle_request(service, {"version": 1, "id": "bad", "op": "transcribe", "audio_path": str(audio), "language": "xx"})["status"], "error")
    def make_model(self, root):
        model_root = root / "models--local--whisper"; blobs = model_root / "blobs"; snapshot = model_root / "snapshots" / "revision"
        blobs.mkdir(parents=True); snapshot.mkdir(parents=True)
        for name, contents in (("config.json", b"{}"), ("weights.npz", b"w")):
            blob = blobs / (name + ".blob"); blob.write_bytes(contents); (snapshot / name).symlink_to(blob)
        return snapshot
    def make_audio(self, root, mode=0o600, sample=0):
        path = root / "audio.wav"
        with wave.open(str(path), "wb") as writer:
            writer.setnchannels(1); writer.setsampwidth(2); writer.setframerate(16000); writer.writeframes(struct.pack("<h", sample) * 160)
        os.chmod(path, mode); return path
    def make_safetensors_model(self, root):
        model_root = root / "models--local--whisper-st"; blobs = model_root / "blobs"; snapshot = model_root / "snapshots" / "revision"
        blobs.mkdir(parents=True); snapshot.mkdir(parents=True)
        for name, contents in (("config.json", b"{}"), ("weights.safetensors", b"w")):
            blob = blobs / (name + ".blob"); blob.write_bytes(contents); (snapshot / name).symlink_to(blob)
        return snapshot
    def pins_for(self, model, weights_name):
        return {"KLANGSCHRIFT_MODEL_CONFIG_SHA256": helper._sha256((model / "config.json").resolve()), "KLANGSCHRIFT_MODEL_WEIGHTS_SHA256": helper._sha256((model / weights_name).resolve())}
    def pins(self, model):
        return self.pins_for(model, "weights.npz")
    def fake_upstream(self, calls, *, fail_load=False, result_text=None, result_value=None, token_overrides=None):
        class FakeModel:
            is_multilingual = True
            num_languages = 99
            def parameters(self): return ("pinned",)
        class FakeHolder:
            model_path = None
            model = None
            @classmethod
            def get_model(cls, path, dtype):
                calls["get_model_calls"] = calls.get("get_model_calls", 0) + 1
                calls.setdefault("paths", []).append(path); calls.setdefault("dtypes", []).append(dtype); calls.setdefault("events", []).append("get_model")
                if cls.model is None or cls.model_path != path:
                    calls["loads"] += 1
                    if fail_load: raise RuntimeError("synthetic warm failure")
                    cls.model_path, cls.model = path, FakeModel()
                return cls.model
        core = types.ModuleType("mlx.core"); core.float16 = "fp16"
        def fake_eval(parameters): calls["evals"] += 1; calls["parameters"] = parameters; calls.setdefault("events", []).append("eval")
        core.eval = fake_eval
        mlx = types.ModuleType("mlx"); mlx.core = core
        module = types.ModuleType("mlx_whisper.transcribe"); module.ModelHolder = FakeHolder
        token_text = {}
        class FakeEncoding:
            n_vocab = 2000
        class FakeTokenizer:
            eot = 1000
            encoding = FakeEncoding()
            def decode(self, token_ids):
                key = tuple(token_ids)
                calls.setdefault("decode_calls", []).append(key)
                if token_overrides is not None and key in token_overrides: return token_overrides[key]
                if key in token_text: return token_text[key]
                return "".join(token_text.get((token,), "") for token in token_ids)
        tokenizer_module = types.ModuleType("mlx_whisper.tokenizer")
        tokenizer_module.get_tokenizer = lambda multilingual, *, num_languages, language, task: FakeTokenizer()
        def fake_transcribe(samples, *, path_or_hf_repo, language, verbose, condition_on_previous_text):
            model = FakeHolder.get_model(path_or_hf_repo, core.float16)
            calls["jobs"] = calls.get("jobs", 0) + 1; calls["samples"] = samples.copy(); calls.setdefault("model_ids", []).append(id(model)); calls.setdefault("events", []).append("transcribe"); calls.setdefault("condition_on_previous_text", []).append(condition_on_previous_text)
            text = f"fixture-job-{calls['jobs']}" if result_text is None else result_text
            result = result_value if result_value is not None else {"text": text, "language": "de", "segments": [] if not text else [{"seek": 0, "start": 0.0, "end": 0.01, "text": text, "tokens": [1], "temperature": 0.0, "avg_logprob": -0.1, "compression_ratio": 1.0, "no_speech_prob": 0.1}]}
            if isinstance(result, dict) and isinstance(result.get("segments"), list):
                combined = []
                for segment in result["segments"]:
                    if isinstance(segment, dict) and isinstance(segment.get("tokens"), list) and isinstance(segment.get("text"), str):
                        tokens = tuple(token for token in segment["tokens"] if isinstance(token, int) and not isinstance(token, bool) and token < FakeTokenizer.eot)
                        token_text[tokens] = segment["text"]; combined.extend(tokens)
                token_text[tuple(combined)] = result.get("text", "")
            return result
        package = types.ModuleType("mlx_whisper"); package.__path__ = []; package.transcribe = fake_transcribe
        return patch.dict(sys.modules, {"mlx": mlx, "mlx.core": core, "mlx_whisper": package, "mlx_whisper.transcribe": module, "mlx_whisper.tokenizer": tokenizer_module})
    def test_safetensors_weights_accepted_exactly_one(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); model = self.make_safetensors_model(root)
            with patch.dict(os.environ, self.pins_for(model, "weights.safetensors"), clear=False):
                self.assertTrue(helper.LocalEngine(model).configured())
            both = self.make_model(root / "both"); (both / "weights.safetensors").symlink_to((both / "weights.npz").resolve())
            with patch.dict(os.environ, self.pins(both), clear=False):
                self.assertFalse(helper.LocalEngine(both).configured())
            neither = self.make_model(root / "neither"); (neither / "weights.npz").unlink()
            with patch.dict(os.environ, {"KLANGSCHRIFT_MODEL_CONFIG_SHA256": helper._sha256((neither / "config.json").resolve()), "KLANGSCHRIFT_MODEL_WEIGHTS_SHA256": "0" * 64}, clear=False):
                self.assertFalse(helper.LocalEngine(neither).configured())
    def test_length_prefixed_round_trip_and_limit(self):
        data = io.BytesIO(); helper.write_frame(data, {"version": 1, "id": "x", "op": "health"}); data.seek(0)
        self.assertEqual(helper.read_frame(data)["op"], "health")
        with self.assertRaises(helper.ProtocolError): helper.read_frame(io.BytesIO(struct.pack(">I", helper.MAX_FRAME_BYTES + 1)))
    def test_audio_root_escape_symlink_and_mode_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); audio_root = root / "audio"; audio_root.mkdir(mode=0o700); path = self.make_audio(audio_root)
            self.assertEqual(helper.resolve_audio(audio_root, str(path)), path.resolve())
            os.chmod(path, 0o644)
            with self.assertRaises(helper.ProtocolError): helper.resolve_audio(audio_root, str(path))
            os.chmod(path, 0o600); link = audio_root / "link.wav"; link.symlink_to(path)
            with self.assertRaises(helper.ProtocolError): helper.resolve_audio(audio_root, str(link))
            outside = self.make_audio(root)
            with self.assertRaises(helper.ProtocolError): helper.resolve_audio(audio_root, str(outside))
    def test_silence_never_imports_mlx_and_health_states(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); audio_root = root / "audio"; audio_root.mkdir(mode=0o700); model = self.make_model(root); path = self.make_audio(audio_root)
            with patch.dict(os.environ, self.pins(model), clear=False):
                service = helper.Service(helper.LocalEngine(model), audio_root)
                self.assertEqual(service.handle({"version": 1, "id": "h", "op": "health"})["status"], "configured")
                response = service.handle({"version": 1, "id": "s", "op": "transcribe", "audio_path": str(path), "language": "auto"})
                self.assertEqual(response["status"], "silence"); self.assertNotIn("mlx_whisper", sys.modules)
    def test_quiet_nonzero_pcm_reaches_existing_transcribe_without_rescale(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); audio_root = root / "audio"; audio_root.mkdir(mode=0o700); model = self.make_model(root); path = self.make_audio(audio_root, sample=1); calls = {"loads": 0, "evals": 0}
            with patch.dict(os.environ, self.pins(model), clear=False), self.fake_upstream(calls):
                response = helper.Service(helper.LocalEngine(model), audio_root).handle({"version": 1, "id": "quiet", "op": "transcribe", "audio_path": str(path), "language": "auto"})
                self.assertEqual(response["status"], "ok"); self.assertEqual(calls["jobs"], 1); self.assertEqual(calls["loads"], 1)
                self.assertTrue(np.allclose(calls["samples"], np.full(160, 1 / 32768.0, dtype=np.float32)))
    def test_existing_no_speech_empty_text_still_maps_to_silence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); audio_root = root / "audio"; audio_root.mkdir(mode=0o700); model = self.make_model(root); path = self.make_audio(audio_root, sample=1); calls = {"loads": 0, "evals": 0}
            with patch.dict(os.environ, self.pins(model), clear=False), self.fake_upstream(calls, result_text=""):
                response = helper.Service(helper.LocalEngine(model), audio_root).handle({"version": 1, "id": "nospeech", "op": "transcribe", "audio_path": str(path), "language": "auto"})
                self.assertEqual(response["status"], "silence"); self.assertEqual(calls["jobs"], 1)
    def test_result_validator_vetoes_high_no_speech_independent_of_logprob(self):
        def result(no_speech, logprob):
            return {"text": "fixture", "language": "de", "segments": [{"seek": 0, "start": 0.0, "end": 1.0, "text": "fixture", "tokens": [1], "temperature": 0.0, "avg_logprob": logprob, "compression_ratio": 1.0, "no_speech_prob": no_speech}]}
        for no_speech in (0.0, 0.6):
            for logprob in (-1.1, -1.0, -0.9): self.assertEqual(helper.validate_transcription_result(result(no_speech, logprob)), "fixture")
        for no_speech in (0.600001, 1.0):
            for logprob in (-1.1, -1.0, -0.9): self.assertEqual(helper.validate_transcription_result(result(no_speech, logprob)), "")
    def test_result_validator_closes_invalid_and_mixed_results(self):
        valid = {"text": "a", "language": "de", "segments": [{"seek": 0, "start": 0.0, "end": 1.0, "text": "a", "tokens": [1], "temperature": 0.0, "avg_logprob": -0.1, "compression_ratio": 1.0, "no_speech_prob": 0.1}]}
        self.assertEqual(helper.validate_transcription_result({"text": "", "segments": []}), "")
        for field, value in (("no_speech_prob", float("nan")), ("no_speech_prob", True), ("avg_logprob", "bad"), ("tokens", [True]), ("end", float("inf"))):
            broken = json.loads(json.dumps(valid)); broken["segments"][0][field] = value
            with self.assertRaises(helper.EngineResultError): helper.validate_transcription_result(broken)
        mixed = json.loads(json.dumps(valid)); mixed["segments"].append({"seek": 0, "start": 1.0, "end": 2.0, "text": "b", "tokens": [2], "temperature": 0.0, "avg_logprob": -0.1, "compression_ratio": 1.0, "no_speech_prob": 0.7}); mixed["text"] = "ab"
        with self.assertRaises(helper.EngineResultError): helper.validate_transcription_result(mixed)
    def test_service_errorframe_and_veto_mapping(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); audio_root=root/'audio'; audio_root.mkdir(mode=0o700); model=self.make_model(root); audio=self.make_audio(audio_root,sample=1)
            def result(nsp, logprob=-0.1): return {"text":"fixture","language":"de","segments":[{"seek":0,"start":0.0,"end":1.0,"text":"fixture","tokens":[1],"temperature":0.0,"avg_logprob":logprob,"compression_ratio":1.0,"no_speech_prob":nsp}]}
            def request(identifier): return {"version":1,"id":identifier,"op":"transcribe","audio_path":str(audio),"language":"auto"}
            def invoke(identifier, value):
                calls={"loads":0,"evals":0}
                with patch.dict(os.environ,self.pins(model),clear=False),self.fake_upstream(calls,result_value=value):
                    return helper.handle_request(helper.Service(helper.LocalEngine(model),audio_root),request(identifier))
            for nsp, expected in ((0.59,"ok"),(0.6,"ok"),(0.6001,"silence")):
                for logprob in (-1.1,-1.0,-0.9):
                    response=invoke("veto",result(nsp,logprob))
                    self.assertEqual(response.get("id"),"veto")
                    if expected == "silence": self.assertEqual(response,{"version":1,"id":"veto","status":"silence"})
                    else: self.assertEqual(response,{"version":1,"id":"veto","status":"ok","text":"fixture"})
            mixed=result(0.1); mixed["segments"][0]["end"]=0.001; mixed["segments"].append({"seek":1,"start":0.001,"end":0.002,"text":"veto","tokens":[2],"temperature":0.0,"avg_logprob":-0.1,"compression_ratio":1.0,"no_speech_prob":0.7}); mixed["text"]="fixtureveto"
            missing=result(0.1); del missing["segments"][0]["seek"]
            boolean=result(0.1); boolean["segments"][0]["no_speech_prob"]=True
            infinite=result(0.1); infinite["segments"][0]["end"]=float("inf")
            self.assertEqual(invoke("mixed",mixed),{"version":1,"id":"mixed","status":"ok","text":"fixture"})
            for identifier, bad in (("missing",missing),("boolean",boolean),("infinite",infinite)):
                self.assertEqual(invoke(identifier,bad),{"version":1,"id":identifier,"status":"error","code":"engine_error"})
    def test_service_selects_only_bound_mixed_segments_and_keeps_context_disabled(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); audio_root=root/'audio'; audio_root.mkdir(mode=0o700); model=self.make_model(root); audio=self.make_audio(audio_root,sample=1)
            def segment(text, token, seek, start, end, nsp=0.1, logprob=-0.1): return {"seek":seek,"start":start,"end":end,"text":text,"tokens":[token],"temperature":0.0,"avg_logprob":logprob,"compression_ratio":1.0,"no_speech_prob":nsp}
            def request(identifier): return {"version":1,"id":identifier,"op":"transcribe","audio_path":str(audio),"language":"auto"}
            def invoke(identifier, value, token_overrides=None):
                calls={"loads":0,"evals":0}
                with patch.dict(os.environ,self.pins(model),clear=False),self.fake_upstream(calls,result_value=value,token_overrides=token_overrides):
                    response=helper.handle_request(helper.Service(helper.LocalEngine(model),audio_root),request(identifier))
                self.assertEqual(calls["condition_on_previous_text"],[False])
                return response
            accepted={"text":"a\u00a0b","language":"de","segments":[segment("a\u00a0",1,0,0.0,0.001),segment("b",2,0,0.001,0.002)]}
            all_veto={"text":"v","language":"de","segments":[segment("v",1,0,0.0,0.001,0.600001,-0.9)]}
            mixed_start={"text":"vab","language":"de","segments":[segment("v",1,0,0.0,0.001,0.7),segment("a",2,1,0.001,0.002),segment("b",3,2,0.002,0.003)]}
            mixed_middle={"text":"avb","language":"de","segments":[segment("a",1,0,0.0,0.001),segment("v",2,1,0.001,0.002,0.7),segment("b",3,2,0.002,0.003)]}
            mixed_end={"text":"abv","language":"de","segments":[segment("a",1,0,0.0,0.001),segment("b",2,1,0.001,0.002),segment("v",3,2,0.002,0.003,0.7)]}
            veto_padding={"text":"av","language":"de","segments":[segment("a",1,0,0.0,0.001),segment("v",2,1,0.02,0.03,0.7)]}
            self.assertEqual(invoke("accepted",accepted),{"version":1,"id":"accepted","status":"ok","text":"a\u00a0b"})
            self.assertEqual(invoke("veto",all_veto),{"version":1,"id":"veto","status":"silence"})
            for identifier, value, expected in (("start",mixed_start,"ab"),("middle",mixed_middle,"ab"),("end",mixed_end,"ab")):
                self.assertEqual(invoke(identifier,value),{"version":1,"id":identifier,"status":"ok","text":expected})
            self.assertEqual(invoke("padding",veto_padding),{"version":1,"id":"padding","status":"ok","text":"a"})
            bad_cases=[]
            token_mismatch={"text":"a","language":"de","segments":[segment("a",1,0,0.0,0.001)]}
            bad_cases.append(("token",token_mismatch,{(1,):"wrong"}))
            negative={"text":"a","language":"de","segments":[segment("a",-1,0,0.0,0.001)]}; bad_cases.append(("negative",negative,None))
            missing={"text":"a","language":"de","segments":[segment("a",1,0,0.0,0.001)]}; del missing["segments"][0]["tokens"]; bad_cases.append(("missing",missing,None))
            overlap={"text":"ab","language":"de","segments":[segment("a",1,0,0.0,0.002),segment("b",2,1,0.001,0.003)]}; bad_cases.append(("overlap",overlap,None))
            backwards={"text":"ab","language":"de","segments":[segment("a",1,2,0.0,0.001),segment("b",2,1,0.001,0.002)]}; bad_cases.append(("backwards",backwards,None))
            same_seek_conflict={"text":"ab","language":"de","segments":[segment("a",1,0,0.0,0.001),segment("b",2,0,0.001,0.002,0.7)]}; bad_cases.append(("same",same_seek_conflict,None))
            outside={"text":"av","language":"de","segments":[segment("a",1,0,0.02,0.03),segment("v",2,1,0.03,0.04,0.7)]}; bad_cases.append(("outside",outside,None))
            oversized={"text":"x"*(helper.MAX_TEXT_CHARS+1),"language":"de","segments":[segment("x"*(helper.MAX_TEXT_CHARS+1),1,0,0.0,0.001)]}; bad_cases.append(("oversized",oversized,None))
            for identifier, value, overrides in bad_cases:
                self.assertEqual(invoke(identifier,value,overrides),{"version":1,"id":identifier,"status":"error","code":"engine_error"})
    def test_service_keeps_only_exact_cleared_nodes_and_in_vocab_timestamp_tokens(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); audio_root=root/'audio'; audio_root.mkdir(mode=0o700); model=self.make_model(root); audio=self.make_audio(audio_root,sample=1)
            def segment(text, tokens, seek, start, end, nsp=0.1): return {"seek":seek,"start":start,"end":end,"text":text,"tokens":tokens,"temperature":0.0,"avg_logprob":-0.1,"compression_ratio":1.0,"no_speech_prob":nsp}
            def invoke(identifier, value):
                calls={"loads":0,"evals":0}
                request={"version":1,"id":identifier,"op":"transcribe","audio_path":str(audio),"language":"auto"}
                with patch.dict(os.environ,self.pins(model),clear=False),self.fake_upstream(calls,result_value=value):
                    response=helper.handle_request(helper.Service(helper.LocalEngine(model),audio_root),request)
                self.assertEqual(calls["condition_on_previous_text"],[False])
                return response,calls
            speech=segment("a",[1],0,0.0,0.001)
            clear_start=segment("",[],0,0.0,0.0)
            clear_end=segment("",[],0,0.001,0.001)
            clear_duration=segment("",[],0,0.001,0.002)
            for identifier, segments in (("clearstart",[clear_start,speech]),("clearend",[speech,clear_end])):
                response,calls=invoke(identifier,{"text":"a","language":"de","segments":segments})
                self.assertEqual(response,{"version":1,"id":identifier,"status":"ok","text":"a"}); self.assertIn((),calls["decode_calls"])
            response,calls=invoke("clearduration",{"text":"a","language":"de","segments":[speech,clear_duration]})
            self.assertEqual(response,{"version":1,"id":"clearduration","status":"ok","text":"a"}); self.assertIn((),calls["decode_calls"])
            mixed={"text":"av","language":"de","segments":[speech,clear_duration,segment("v",[2],1,0.002,0.003,0.7)]}
            self.assertEqual(invoke("clearmixed",mixed)[0],{"version":1,"id":"clearmixed","status":"ok","text":"a"})
            timestamp={"text":"a","language":"de","segments":[segment("a",[1,1001],0,0.0,0.001)]}
            timestamp_mixed={"text":"av","language":"de","segments":[segment("a",[1,1001],0,0.0,0.001),segment("v",[2],1,0.001,0.002,0.7)]}
            self.assertEqual(invoke("timestamp",timestamp)[0],{"version":1,"id":"timestamp","status":"ok","text":"a"})
            self.assertEqual(invoke("timestampmixed",timestamp_mixed)[0],{"version":1,"id":"timestampmixed","status":"ok","text":"a"})
            malformed_text={"text":"a","language":"de","segments":[speech,segment("",[2],1,0.001,0.001)]}
            malformed_tokens={"text":"a","language":"de","segments":[segment("a",[],0,0.0,0.001)]}
            invalid_veto={"text":"av","language":"de","segments":[speech,segment("v",[2000],1,0.001,0.002,0.7)]}
            bool_token={"text":"a","language":"de","segments":[segment("a",[True],0,0.0,0.001)]}
            for identifier, value in (("badtext",malformed_text),("badtokens",malformed_tokens),("vocab",invalid_veto),("booltoken",bool_token)):
                self.assertEqual(invoke(identifier,value)[0],{"version":1,"id":identifier,"status":"error","code":"engine_error"})
    def test_prepare_materializes_validated_local_model_before_prepared_and_reuses_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); audio_root = root / "audio"; audio_root.mkdir(mode=0o700); model = self.make_model(root); calls = {"loads": 0, "evals": 0}
            with patch.dict(os.environ, self.pins(model), clear=False), self.fake_upstream(calls):
                engine = helper.LocalEngine(model); service = helper.Service(engine, audio_root)
                engine.import_function()
                self.assertTrue(engine.function_imported); self.assertFalse(engine.model_warm)
                self.assertEqual(service.handle({"version": 1, "id": "before", "op": "health"})["status"], "configured")
                self.assertEqual(service.handle({"version": 1, "id": "warm0", "op": "prepare"})["status"], "prepared")
                for index in range(1, 5): self.assertEqual(service.handle({"version": 1, "id": f"warm{index}", "op": "prepare"})["status"], "prepared")
                self.assertTrue(engine.model_warm); self.assertEqual(calls["loads"], 1); self.assertEqual(calls["evals"], 1)
                self.assertEqual(calls["paths"], [str(model.resolve())]); self.assertEqual(calls["dtypes"], ["fp16"])
    def test_prepare_rejects_bad_pin_before_modelholder_load_and_never_reports_warm(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); audio_root = root / "audio"; audio_root.mkdir(mode=0o700); model = self.make_model(root); calls = {"loads": 0, "evals": 0}
            pins = self.pins(model); pins["KLANGSCHRIFT_MODEL_WEIGHTS_SHA256"] = "0" * 64
            with patch.dict(os.environ, pins, clear=False), self.fake_upstream(calls):
                engine = helper.LocalEngine(model); service = helper.Service(engine, audio_root)
                with self.assertRaises(helper.ProtocolError): service.handle({"version": 1, "id": "badpin", "op": "prepare"})
                self.assertFalse(engine.model_warm); self.assertEqual(calls["loads"], 0)
    def test_warm_failure_never_promotes_import_only_engine_to_prepared(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); audio_root = root / "audio"; audio_root.mkdir(mode=0o700); model = self.make_model(root); calls = {"loads": 0, "evals": 0}
            with patch.dict(os.environ, self.pins(model), clear=False), self.fake_upstream(calls, fail_load=True):
                engine = helper.LocalEngine(model); service = helper.Service(engine, audio_root)
                with self.assertRaises(RuntimeError): service.handle({"version": 1, "id": "warmfail", "op": "prepare"})
                self.assertTrue(engine.function_imported); self.assertFalse(engine.model_warm)
                self.assertEqual(service.handle({"version": 1, "id": "after", "op": "health"})["status"], "configured")
    def test_warm_identity_drift_closes_health_before_reusing_cached_model(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); audio_root = root / "audio"; audio_root.mkdir(mode=0o700); model = self.make_model(root); calls = {"loads": 0, "evals": 0}
            with patch.dict(os.environ, self.pins(model), clear=False), self.fake_upstream(calls):
                engine = helper.LocalEngine(model); service = helper.Service(engine, audio_root)
                self.assertEqual(service.handle({"version": 1, "id": "warm", "op": "prepare"})["status"], "prepared")
                (model / "weights.npz").resolve().write_bytes(b"drift")
                self.assertFalse(engine.model_warm)
                self.assertEqual(service.handle({"version": 1, "id": "drift", "op": "health"})["status"], "misconfigured")
                self.assertEqual(calls["loads"], 1)
    def test_five_non_silent_service_jobs_reuse_one_pinned_modelholder_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); audio_root = root / "audio"; audio_root.mkdir(mode=0o700); model = self.make_model(root); audio = self.make_audio(audio_root, sample=4096); calls = {"loads": 0, "evals": 0}
            with patch.dict(os.environ, self.pins(model), clear=False), self.fake_upstream(calls):
                service = helper.Service(helper.LocalEngine(model), audio_root)
                self.assertEqual(service.handle({"version": 1, "id": "warm", "op": "prepare"}), {"version": 1, "id": "warm", "status": "prepared"})
                self.assertEqual(calls["events"], ["get_model", "eval"])
                for index in range(5):
                    identifier = f"job{index}"
                    response = service.handle({"version": 1, "id": identifier, "op": "transcribe", "audio_path": str(audio), "language": "de"})
                    self.assertEqual(response, {"version": 1, "id": identifier, "status": "ok", "text": f"fixture-job-{index + 1}"})
                    self.assertEqual(service.handle({"version": 1, "id": f"health{index}", "op": "health"}), {"version": 1, "id": f"health{index}", "status": "prepared"})
                self.assertEqual(calls["loads"], 1, calls); self.assertEqual(calls["evals"], 1, calls); self.assertEqual(calls["get_model_calls"], 6, calls)
                self.assertEqual(calls["paths"], [str(model.resolve())] * 6); self.assertEqual(calls["dtypes"], ["fp16"] * 6)
                self.assertEqual(len(set(calls["model_ids"])), 1); self.assertEqual(calls["jobs"], 5)
    def test_non_silent_audio_is_passed_as_canonical_waveform_without_ffmpeg(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); audio_root = root / "audio"; audio_root.mkdir(mode=0o700); model = self.make_model(root); path = self.make_audio(audio_root, sample=4096)
            engine = helper.LocalEngine(model); observed = {}; calls = {"loads": 0, "evals": 0}
            def transcribe(samples, **options):
                observed["samples"] = samples; observed["options"] = options
                return {"text": "lokaler test", "language": "de", "segments": [{"seek": 0, "start": 0.0, "end": 0.01, "text": "lokaler test", "tokens": [1], "temperature": 0.0, "avg_logprob": -0.1, "compression_ratio": 1.0, "no_speech_prob": 0.1}]}
            engine._transcribe = transcribe
            with patch.dict(os.environ, self.pins(model), clear=False), patch.dict(os.environ, {"PATH": ""}, clear=False), self.fake_upstream(calls, token_overrides={(1,): "lokaler test"}):
                result = helper.Service(engine, audio_root).handle({"version": 1, "id": "n", "op": "transcribe", "audio_path": str(path), "language": "de"})
            self.assertEqual(result["text"], "lokaler test")
            self.assertFalse(isinstance(observed["samples"], (str, Path)))
            self.assertEqual(observed["samples"].shape, (160,)); self.assertAlmostEqual(float(observed["samples"][0]), 0.125)
            self.assertEqual(observed["options"]["language"], "de")
            self.assertEqual(calls["loads"], 1); self.assertEqual(calls["evals"], 1)
    def test_model_blob_symlink_allowed_and_escape_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); model = self.make_model(root); audio_root = root / "audio"; audio_root.mkdir(mode=0o700)
            with patch.dict(os.environ, self.pins(model), clear=False):
                self.assertTrue(helper.LocalEngine(model).configured())
                outside = root / "outside"; outside.write_bytes(b"x")
                (model / "weights.npz").unlink(); (model / "weights.npz").symlink_to(outside)
                self.assertFalse(helper.LocalEngine(model).configured())
    def test_missing_invalid_and_drifted_pins_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            model = self.make_model(Path(directory)); pins = self.pins(model)
            with patch.dict(os.environ, {"KLANGSCHRIFT_MODEL_CONFIG_SHA256": "", "KLANGSCHRIFT_MODEL_WEIGHTS_SHA256": ""}, clear=False): self.assertFalse(helper.LocalEngine(model).configured())
            with patch.dict(os.environ, {"KLANGSCHRIFT_MODEL_CONFIG_SHA256": "not-a-hash", "KLANGSCHRIFT_MODEL_WEIGHTS_SHA256": pins["KLANGSCHRIFT_MODEL_WEIGHTS_SHA256"]}, clear=False): self.assertFalse(helper.LocalEngine(model).configured())
            with patch.dict(os.environ, pins, clear=False): self.assertTrue(helper.LocalEngine(model).configured())
            (model / "weights.npz").resolve().write_bytes(b"drift")
            with patch.dict(os.environ, pins, clear=False): self.assertFalse(helper.LocalEngine(model).configured())
    def test_audio_root_and_envelope_language_shutdown(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); audio_root = root / "audio"; audio_root.mkdir(mode=0o700); model = self.make_model(root)
            with patch.dict(os.environ, self.pins(model), clear=False):
                service = helper.Service(helper.LocalEngine(model), audio_root)
                with self.assertRaises(helper.ProtocolError): service.handle({"version": 1, "id": "too long" * 20, "op": "health"})
                with self.assertRaises(helper.ProtocolError): service.handle({"version": 1, "id": "x", "op": "transcribe", "audio_path": "/x", "language": "xx"})
                self.assertEqual(service.handle({"version": 1, "id": "z", "op": "shutdown"})["status"], "shutdown"); self.assertTrue(service.shutdown_requested)
            insecure = root / "insecure"; insecure.mkdir(); os.chmod(insecure, 0o755)
            with self.assertRaises(helper.ProtocolError): helper.Service(helper.LocalEngine(self.make_model(root / "next")), insecure)
    def test_main_survives_overlong_id_max_frame_and_large_response(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); audio_root = root / "audio"; audio_root.mkdir(mode=0o700); model = self.make_model(root); env = os.environ.copy(); env.update(self.pins(model)); env.update({"KLANGSCHRIFT_MODEL_PATH": str(model), "KLANGSCHRIFT_AUDIO_ROOT": str(audio_root), "PYTHONDONTWRITEBYTECODE": "1"})
            max_request = {"version": 1, "id": "max", "op": "health", "pad": ""}; encoded = json.dumps(max_request, separators=(",", ":")).encode(); max_request["pad"] = "x" * (helper.MAX_FRAME_BYTES - len(encoded)); encoded = json.dumps(max_request, separators=(",", ":")).encode(); self.assertEqual(len(encoded), helper.MAX_FRAME_BYTES)
            frames = [json.dumps({"version": 1, "id": "x" * 65, "op": "health"}, separators=(",", ":")).encode(), encoded, json.dumps({"version": 1, "id": "ok", "op": "health"}, separators=(",", ":")).encode()]
            stream = b"".join(struct.pack(">I", len(frame)) + frame for frame in frames)
            output = subprocess.run([sys.executable, str(Path(__file__).parent / "klangschrift_mlx_helper.py")], input=stream, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, check=True).stdout
            replies = io.BytesIO(output); first, second, third = helper.read_frame(replies), helper.read_frame(replies), helper.read_frame(replies)
            self.assertIsNone(first["id"]); self.assertEqual(second["status"], "configured"); self.assertEqual(third["id"], "ok")
            fallback = io.BytesIO(); helper.safe_write_frame(fallback, {"pad": "x" * helper.MAX_FRAME_BYTES}); fallback.seek(0); self.assertEqual(helper.read_frame(fallback)["code"], "response_unavailable")

if __name__ == "__main__": unittest.main()
