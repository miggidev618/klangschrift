# Mac-App bauen

[English](BUILD-MAC.md)

Du brauchst einen Mac mit Apple Silicon und macOS 26 oder neuer, Xcode und Python 3.14.

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

Das Skript lädt die nötigen Bibliotheken, baut die App und legt sie unter `/private/tmp/Klangschrift.app` ab. Von dort in den Programme-Ordner ziehen.

Die Sprachmodelle sind nicht im Repository. Du lädst sie beim ersten Start in der App herunter.
