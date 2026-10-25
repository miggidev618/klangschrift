# SciPy-Laufzeit: libquadmath und GCC-Laufzeitbibliotheken

Das Mac-App-Bundle enthält aus dem fest gepinnten SciPy-Wheel 1.18.1 die Dateien
`scipy/.dylibs/libquadmath.0.dylib`, `libgfortran.5.dylib` und
`libgcc_s.1.1.dylib`.

`libquadmath` ist laut dem mit SciPy gelieferten `LICENSE.txt` unter
LGPL-2.1-or-later lizenziert. Der vollständige Text der LGPL 2.1 liegt in
`LGPL-2.1.txt`. Die GPL-3.0- und GCC-Runtime-Exception-Hinweise für
`libgfortran` und `libgcc_s` bleiben im unveränderten SciPy-Lizenztext
(`Notices/Python/scipy-1.18.1.dist-info/LICENSE.txt`) enthalten.

Die Abhängigkeit ist im Quellbaum als `scipy==1.18.1` mit dem SHA-256
`011413b7426b75012840e35649e00fe0a2c3bae89fed433876e3a99251572efc`
festgelegt. Die Konfiguration des tatsächlich geprüften SciPy-Wheels nennt für
den Fortran-Compiler GCC 13.4.0. Diese Compilerangabe ist ein
Konfigurationsbeleg des Wheels; sie belegt nicht für sich allein die exakte
Quellprovenienz jeder einzelnen mitgelieferten dylib.

Reproduzierbare Quell- und Herkunftswege:

- SciPy 1.18.1: <https://pypi.org/project/scipy/1.18.1/> und
  <https://github.com/scipy/scipy/tree/v1.18.1>
- GCC 13.4.0 einschließlich `libquadmath`:
  [begleitendes Release-Asset](https://github.com/miggidev618/klangschrift/releases/download/v1.0/gcc-13.4.0.tar.xz),
  <https://ftp.gnu.org/gnu/gcc/gcc-13.4.0/gcc-13.4.0.tar.xz>,
  [offizielles SHA-512-Manifest](https://gcc.gnu.org/pub/gcc/releases/gcc-13.4.0/sha512.sum)
  und
  <https://gcc.gnu.org/git/?p=gcc.git;a=tree;h=refs/tags/releases/gcc-13.4.0>

Das unveränderte Archiv `gcc-13.4.0.tar.xz` wird als begleitendes Asset im
selben privaten Release v1.0 bereitgestellt. Sein SHA-256 ist
`9c4ce6dbb040568fdc545588ac03c5cbc95a8dbf0c7aa490170843afb59ca8f5`; die
offizielle SHA-512-Prüfsumme steht im oben verlinkten GCC-Manifest. Das ist der
dokumentierte maschinenlesbare Quellzugang für die mitgelieferte
LGPL-Komponente, ohne eine über diesen konkreten Release hinausgehende
Quellcode-Zusage zu erklären.

`libquadmath.0.dylib` liegt als eigene dynamische Bibliothek unverändert im
SciPy-Unterordner. Ein Austausch in einem ad-hoc-signierten App-Bundle würde
dessen Code-Signatur ungültig machen und erfordert technisch eine erneute
lokale Signierung; diese Information beschreibt die Paketierung und ist keine
Installations- oder Rechtszusage.
