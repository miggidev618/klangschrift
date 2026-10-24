# Klangschrift für macOS bauen

## Voraussetzungen

- Apple-Silicon-Mac mit macOS 26 oder neuer: Das aktuelle offizielle Moonshine-SDK wurde für macOS 26 gebaut; frühere Versionen sind nicht geprüft.
- Geprüfter Bauweg: macOS 27.0.1, Xcode 27.1 und Apple Swift 6.4.
- Python 3.14. Der getestete Weg verwendet ein lokales venv mit den unten gepinnten Helper-Abhängigkeiten.

## Quellcode bauen

```sh
cd macos
python3.14 -m venv --without-pip .build/python
python3.14 -m pip --python .build/python install --require-hashes \
  -r Helper/mlx-helper/requirements.lock

base_python="$(.build/python/bin/python -c 'import sys; print(sys._base_executable)')"
site_packages="$(.build/python/bin/python -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
./Scripts/build.sh \
  --output /private/tmp/Klangschrift.app \
  --python "$base_python" \
  --site-packages "$site_packages"
```

`requirements.lock` enthält die vollständigen direkten und transitiven Pins mit SHA-256. Der Builder lehnt ein `site-packages` mit fehlenden oder zusätzlichen Distributionen ab.

Der Builder lädt das gepinnte Moonshine-SDK mit Prüfsumme, baut App, Worker und Installer mit zwei Jobs, bündelt Ressourcen, den Python-Helfer, das übergebene Python-3.14-Laufzeitsystem und die Modellmanifestdaten. Er signiert die lokale `.app` ad hoc und installiert oder startet sie nicht. Die Ausgabe ist ein getesteter Quellbau auf dem genannten Host, keine notarisiert verteilte oder allgemein portable Standalone-App.

Der Quellbau und die Signaturprüfung sind erfolgt. Ein nativer Start, Modellbezug, Aufnahme, Transkription, Einfügen bzw. Kopieren, Verlauf und Neustart wurden damit nicht abgenommen. Modelle werden nicht mit dem Repository geliefert; siehe [MODELS.md](MODELS.md).
