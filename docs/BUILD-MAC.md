# Build the Mac app

[Deutsch](BUILD-MAC.de.md)

You need a Mac with Apple Silicon and macOS 26 or newer, Xcode and Python 3.14.

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

The script downloads the required libraries, builds the app and puts it at `/private/tmp/Klangschrift.app`. Move it from there to the Applications folder.

The speech models are not in the repository. Download them in the app on first launch.
