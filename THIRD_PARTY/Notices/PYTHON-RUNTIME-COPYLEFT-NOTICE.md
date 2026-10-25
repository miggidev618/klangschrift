# Further Python runtime copyleft notices

[Deutsch](PYTHON-RUNTIME-COPYLEFT-NOTICE.de.md)

The Mac build copies the license files of all top-level Python distributions
to `Contents/Resources/Notices/Python/`. Inspection of the app bundle that was
actually packaged also found the following complete texts, which are included
here separately for easy-to-find distribution:

- `LGPL-3.0.txt`: for the `autocommand` distribution vendored in setuptools
  (LGPLv3). Its unmodified license file also remains in the Python runtime.
- `MPL-2.0.txt`: for `certifi` (MPL-2.0), `tqdm` (MPL-2.0 AND MIT), and the
  `validate-pyproject` notice included in setuptools.

The existing GPL-3.0 and GCC runtime exception texts of SciPy and NumPy are
already copied unmodified with their respective Python license files. This
notice inventories the checked Mac runtime; it does not replace the license
texts of the respective upstream projects.

The uncompiled Python sources of the included wheels remain in the app bundle
as `.py` files (for example, `jinja2/runtime.py`). The LGPLv3-relevant
`autocommand` source remains unmodified under
`Runtime/Python.framework/Versions/3.14/lib/python3.14/site-packages/setuptools/_vendor/autocommand/`;
upstream: <https://github.com/Lucretiel/autocommand>. The respective upstream
source pages for MPL components are
<https://github.com/certifi/python-certifi> and <https://github.com/tqdm/tqdm>.
