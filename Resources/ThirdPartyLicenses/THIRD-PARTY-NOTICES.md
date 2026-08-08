# Third-party notices

The Simple Imager application license is stored one directory above as
`LICENSE`.

Simple Imager bundles the following unmodified command-line tools and dynamic
libraries in its macOS application bundle. They remain separate programs and
are covered by their respective licenses.

## Zstandard 1.5.7

- Project: https://github.com/facebook/zstd
- License: BSD-3-Clause, BSD-2-Clause and MIT components
- Included files: `zstd`, `libzstd`
- License texts: `zstd-LICENSE`, `zstd-COPYING`

## XZ Utils 5.8.3

- Project: https://tukaani.org/xz/
- License: 0BSD and GPL-2.0-or-later components
- Included files: `xz`, `liblzma`
- License texts: files prefixed with `xz-`

## LZ4 1.10.0

- Project: https://github.com/lz4/lz4
- License: BSD-2-Clause
- Included files: `lz4`, `liblz4`
- License text: `lz4-LICENSE`

## 7-Zip 26.02

- Project: https://7-zip.org/
- Source: https://github.com/ip7z/7zip
- License: LGPL-2.1-or-later and BSD-3-Clause components
- Included file: `7zz`
- License text: `sevenzip-License.txt`

## e2fsprogs 1.47.4

- Project: https://e2fsprogs.sourceforge.net/
- Source: https://github.com/tytso/e2fsprogs/tree/v1.47.4
- License: GPL-2.0-or-later, LGPL-2.0 variants, BSD-3-Clause and MIT components
- Included files: `debugfs`, `e2fsck`, `resize2fs`, `tune2fs` and their libraries
- License and source availability details: files prefixed with `e2fsprogs-`

## GNU gettext / libintl 1.0

- Project: https://www.gnu.org/software/gettext/
- License: GPL-3.0-or-later and LGPL-2.1-or-later components
- Included file: `libintl`
- License texts: `gettext-COPYING`, `gettext-COPYING.LIB`

The exact bundled files and their SHA-256 hashes are recorded in
`RuntimeManifest.plist` inside the application. Corresponding source code is
available from the project links above. No third-party component is covered by
the Simple Imager application license.
