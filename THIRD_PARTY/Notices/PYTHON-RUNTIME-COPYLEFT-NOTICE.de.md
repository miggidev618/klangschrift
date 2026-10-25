# Weitere Copyleft-Hinweise der Python-Laufzeit

[English](PYTHON-RUNTIME-COPYLEFT-NOTICE.md)

Der Mac-Build kopiert die Lizenzdateien aller obersten Python-Distributionen
nach `Contents/Resources/Notices/Python/`. Die Prüfung des tatsächlich
gepackten App-Bundles ergab zusätzlich folgende vollständigen Texte, die für
eine leicht auffindbare Verteilung hier separat beigelegt werden:

- `LGPL-3.0.txt`: für die in setuptools vendorte Distribution `autocommand`
  (LGPLv3). Deren unveränderte Lizenzdatei bleibt auch in der Python-Laufzeit.
- `MPL-2.0.txt`: für `certifi` (MPL-2.0), `tqdm` (MPL-2.0 AND MIT) sowie den
  in setuptools enthaltenen `validate-pyproject`-Hinweis.

Die vorhandenen GPL-3.0- und GCC-Runtime-Exception-Texte von SciPy und NumPy
werden bereits unverändert mit ihren jeweiligen Python-Lizenzdateien kopiert.
Dieser Hinweis inventarisiert die geprüfte Mac-Laufzeit; er ersetzt keine
Lizenztexte der jeweiligen Upstream-Projekte.

Die unkompilierten Python-Quellen der eingebundenen Wheels bleiben im App-Bundle
als `.py`-Dateien erhalten (beispielsweise `jinja2/runtime.py`). Der
LGPLv3-relevante `autocommand`-Quellstand liegt unverändert unter
`Runtime/Python.framework/Versions/3.14/lib/python3.14/site-packages/setuptools/_vendor/autocommand/`;
Upstream: <https://github.com/Lucretiel/autocommand>. Die jeweiligen
Upstream-Quellseiten für MPL-Komponenten sind
<https://github.com/certifi/python-certifi> und <https://github.com/tqdm/tqdm>.
