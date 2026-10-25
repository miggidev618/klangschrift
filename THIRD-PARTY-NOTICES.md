# Drittanbieterhinweise

Eigener Klangschrift-Code steht unter GPL-3.0-only. Diese Lizenz überträgt sich nicht auf fremde Komponenten, Modellgewichte oder deren Urheberrechtsvermerke.

Die vollständigen Texte der im Mac-Quellbaum enthaltenen SDKs liegen unter `macos/Vendor/DesktopSDKs/Attribution/`. Zusätzliche Kataloghinweise liegen in `macos/Vendor/ModelCatalog/NOTICE.md`.

Der iOS-Quellstand verwendet feste lokale SDKs. Der Export enthält diese mit ihren Lizenztexten unter `ios/Vendor/` und `ios/Licenses/`, einschliesslich MLX Swift, MLX Audio Swift, MLX Swift LM, Swift-Transitivpaketen sowie lokaler SDK-Patches. Modellgewichte gehören nicht in dieses Repository und haben eigene Bedingungen.

Genutzte Komponenten umfassen WhisperKit (MIT), FluidAudio (Apache-2.0), Moonshine Voice (MIT, Modellbedingungen separat), Sherpa-ONNX und Kaldi Native Fbank (Apache-2.0), ONNX Runtime und nlohmann JSON (MIT), UTF8CPP (Boost Software License 1.0) sowie UTF8Proc (MIT mit Datenhinweisen).

## Mac-Python-Laufzeit

Die Mac-App enthält eine fest gepinnte Python-Laufzeit. Der Build kopiert die
vorhandenen Lizenzdateien aller obersten Python-Distributionen in
`Contents/Resources/Notices/Python/`. Zusätzliche vollständige Copyleft-Texte
und die konkrete Laufzeitinventur liegen unter `THIRD_PARTY/Notices/` und
werden nach `Contents/Resources/Notices/Runtime/` mitgepackt:

- `SCIPY-RUNTIME-NOTICE.md` und `LGPL-2.1.txt` für SciPys mitgeliefertes
  `libquadmath.0.dylib`;
- `LGPL-3.0.txt` für die in setuptools vendorte LGPLv3-Komponente;
- `MPL-2.0.txt` und `PYTHON-RUNTIME-COPYLEFT-NOTICE.md` für die im geprüften
  Runtime-Inventar gefundenen MPL-2.0-Hinweise.

Die Quelldatei `SCIPY-RUNTIME-NOTICE.md` nennt die exakte SciPy-Pin-Prüfsumme,
die GCC-13.4.0-Compilerangabe des geprüften Wheels und reproduzierbare
Upstream-Quellwege. Sie behauptet ausdrücklich nicht, dass diese
Compilerangabe allein die Quellprovenienz jeder dylib beweist. Der private
Release v1.0 enthält den verifizierten GCC-13.4.0-Quellarchivdownload als
begleitendes Asset; diese Hinweise sind keine pauschale Rechtsfreigabe.
