# SciPy runtime: libquadmath and GCC runtime libraries

[Deutsch](SCIPY-RUNTIME-NOTICE.de.md)

The Mac app bundle contains the following files from the pinned SciPy wheel 1.18.1:
`scipy/.dylibs/libquadmath.0.dylib`, `libgfortran.5.dylib` und
`libgcc_s.1.1.dylib`.

According to the `LICENSE.txt` supplied with SciPy, `libquadmath` is licensed
under LGPL-2.1-or-later. The full text of LGPL 2.1 is in `LGPL-2.1.txt`. The
GPL-3.0 and GCC runtime exception notices for `libgfortran` and `libgcc_s`
remain in the unmodified SciPy license text
(`Notices/Python/scipy-1.18.1.dist-info/LICENSE.txt`).

The dependency is fixed in the source tree as `scipy==1.18.1` with SHA-256
`011413b7426b75012840e35649e00fe0a2c3bae89fed433876e3a99251572efc`. The
configuration of the checked SciPy wheel names GCC 13.4.0 as the Fortran
compiler. This compiler information is configuration evidence for the wheel;
it does not by itself establish the exact source provenance of every included
dylib.

Source and origin links:

- SciPy 1.18.1: <https://pypi.org/project/scipy/1.18.1/> and
  <https://github.com/scipy/scipy/tree/v1.18.1>
- GCC 13.4.0 including `libquadmath`:
  [accompanying release asset](https://github.com/miggidev618/klangschrift/releases/download/v1.0/gcc-13.4.0.tar.xz),
  <https://ftp.gnu.org/gnu/gcc/gcc-13.4.0/gcc-13.4.0.tar.xz>,
  [official SHA-512 manifest](https://gcc.gnu.org/pub/gcc/releases/gcc-13.4.0/sha512.sum)
  and
  <https://gcc.gnu.org/git/?p=gcc.git;a=tree;h=refs/tags/releases/gcc-13.4.0>

The unmodified archive `gcc-13.4.0.tar.xz` is provided as an accompanying
asset in the same private release v1.0. Its SHA-256 is
`9c4ce6dbb040568fdc545588ac03c5cbc95a8dbf0c7aa490170843afb59ca8f5`; the
official SHA-512 checksum is in the GCC manifest linked above. This is the
documented machine-readable source access for the included LGPL component,
without declaring a source-code commitment beyond this specific release.

`libquadmath.0.dylib` remains unmodified as a separate dynamic library in the
SciPy subdirectory. Replacing it in the signed app would invalidate the app’s
signature. It would need to be signed again locally; this information describes
packaging and is not an installation or legal commitment.
