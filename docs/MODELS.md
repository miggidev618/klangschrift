# Modelle

Modellgewichte und Tokenizer sind nicht Teil dieses Repositorys. Sie werden aus den dokumentierten Quellen bezogen und unterliegen eigenen Lizenzen. Der Mac-Downloadkatalog mit Modell-ID, Revision, URL und SHA-256 liegt unverändert in `macos/Vendor/ModelCatalog/AP04-REFERENCE-MANIFESTS.json`; der iPhone-Katalog mit Revision, Größe und Manifest-Prüfsumme liegt in `ios/Core/DictationModel.swift`.

- Whisper-Modelle: MIT.
- Phonon-2 sowie Parakeet: CC-BY-4.0.
- Moonshine Streaming: MIT für die aufgeführten Streaming-Modelle; andere Modellfamilien können abweichende Bedingungen haben.
- Sherpa Zipformer EN 20M INT8: Apache-2.0.

Beim ersten iPhone-Start wird das empfohlene Whisper-Base-Modell nicht mitgeliefert: Es muss in der App ausdrücklich geladen werden. Die App prüft dabei Revision, Manifest und Datei-Hashes, bevor ein Modell als installiert gilt. Auf dem Mac lädt der Modellinstaller die im Katalog gepinnten Dateien und prüft deren SHA-256.

Vor dem Bezug Modellkarte, Lizenz, Quelle, Revision und Prüfsumme prüfen. Tokenizer nicht verändern, weil dies die Erkennung ändern kann. Modellgewichte, Tokenizer und deren Lizenzen gehören nicht zur GPL-Lizenz dieses Repositorys.
