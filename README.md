# Simple Imager

[Русская версия](README.ru.md)

A compact native macOS application for creating, shrinking, compressing, flashing, and verifying raw images of external drives.

## Features

- lists only whole external physical drives;
- identifies a selected drive using its current IORegistry entry, registry path, serial number when available, model, and capacity;
- creates IMG, RAW, and DD images;
- flashes an image from a local file, a direct HTTP/HTTPS URL, or another external drive;
- clones one external drive directly to another;
- supports ZSTD, GZIP, XZ, BZIP2, LZ4, ZIP, and 7Z;
- detects compression from file signatures instead of relying only on the extension;
- can physically shrink the last primary ext2/3/4 partition in an MBR image without Docker;
- can install a one-shot systemd service that expands rootfs on first boot;
- creates no JSON or other sidecar file;
- verifies the entire target drive after flashing and allows an ongoing verification to be skipped;
- can automatically eject a drive after image creation or flashing;
- warns before quitting while an operation is running and waits for safe cancellation;
- includes English and Russian UI, with English selected by default.

## Image workflow

When creating an image, Simple Imager first copies the complete source drive to a temporary RAW file. It can then shrink a supported ext partition and compress the result. The source drive is opened read-only and is no longer accessed after the initial copy.

When flashing a file, the image is extracted exactly once into a private temporary RAW file while SHA-256 is calculated. That same RAW file is written to the target, and the target is read back and compared with the saved hash. A URL is fully downloaded and its format is checked before the destructive target confirmation appears.

Cancelling while data is being written requires an additional confirmation. If cancellation happens before the write completes, Simple Imager invalidates the beginning of the partial target so macOS does not mount an incomplete filesystem.

## ext shrinking

Shrink image uses bundled `e2fsprogs` to check and shrink the last primary ext2/3/4 partition, process its free blocks, update the MBR, and truncate the image. The resulting image can be flashed to a smaller drive if that drive fits the new logical size.

Expand ext on first boot adds a one-shot systemd service to a compatible Linux image. It expands the final partition and ext filesystem, then removes itself. This is intended primarily for Raspberry Pi OS and Ubuntu. GPT, extended/logical partitions, LVM, encryption, and non-ext filesystems are not currently shrinkable.

## Compatibility

The current build supports Apple silicon Macs running macOS 13 or later. Intel Macs are not supported. The application and bundled runtime are arm64-only.

The first-launch screen checks architecture, required macOS tools, the application signature, and SHA-256 hashes of bundled utilities and libraries. `zstd`, `xz`, `lz4`, `7zz`, and required `e2fsprogs` components are included in the app. End users do not need Homebrew, Docker, PiShrink, or separate codecs.

Direct `/dev/rdiskN` access requires the standard macOS administrator authorization prompt. If macOS returns Operation not permitted, enable Full Disk Access for Simple Imager and restart it.

## Build and run

Building from source requires macOS 13+, Swift 6, Apple silicon, and these Homebrew packages used to assemble the self-contained runtime:

```bash
brew install zstd xz lz4 sevenzip e2fsprogs gettext
zsh scripts/build-app.sh
open ".build/Simple Imager.app"
```

The script creates an optimized arm64 `.app`, relocates Homebrew libraries into `Contents/Frameworks`, creates `RuntimeManifest.plist`, and signs every Mach-O file. The default build uses an ad-hoc signature.

For a distributable build, provide a Developer ID certificate:

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" zsh scripts/build-app.sh
```

To notarize during the build, configure a `notarytool` Keychain profile:

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
NOTARYTOOL_PROFILE="simple-imager-notary" \
zsh scripts/build-app.sh
```

## Image formats

Base extensions are `.img`, `.raw`, and `.dd`. Compression adds another extension, for example `.img.zst`, `.raw.gz`, `.dd.xz`, `.img.bz2`, `.img.lz4`, `.img.zip`, or `.img.7z`.

IMG, RAW, and DD contain the same sector-by-sector drive image and differ only for interoperability. ZIP and 7Z archives must contain exactly one image file. ISO, DMG, BIN, and virtual-machine formats are not supported.

## Application icon

The editable source is `Resources/AppIcon.svg`; the generated macOS icon is `Resources/AppIcon.icns`.

```bash
zsh scripts/build-icon.sh "/path/to/new-icon.svg"
zsh scripts/build-app.sh
ditto ".build/Simple Imager.app" "/Applications/Simple Imager.app"
```

## Licenses

Simple Imager source is currently all rights reserved; see `LICENSE`. Third-party notices and license texts are stored in `Resources/ThirdPartyLicenses` and copied into every app bundle.
