#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="$PROJECT_DIR/.build/app"
APP_PATH="$PROJECT_DIR/.build/Simple Imager.app"
CONTENTS_PATH="$APP_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"
HELPERS_PATH="$CONTENTS_PATH/Helpers"
FRAMEWORKS_PATH="$CONTENTS_PATH/Frameworks"
BINARY_PATH="$BUILD_DIR/SimpleImager"
SYSTEM_SWIFT_ROOT="/Library/Developer/CommandLineTools/usr"
LOCAL_TOOLCHAIN="$PROJECT_DIR/.build/toolchain/usr"

mkdir -p "$BUILD_DIR"

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Эта версия Simple Imager собирается только для Mac с процессором серии M." >&2
    exit 1
fi

if [[ -f "$SYSTEM_SWIFT_ROOT/include/swift/module.modulemap" && -f "$SYSTEM_SWIFT_ROOT/include/swift/bridging.modulemap" ]]; then
    mkdir -p "$LOCAL_TOOLCHAIN/lib" "$LOCAL_TOOLCHAIN/include/swift"
    ln -sfn "$SYSTEM_SWIFT_ROOT/lib/swift" "$LOCAL_TOOLCHAIN/lib/swift"
    ln -sfn "$SYSTEM_SWIFT_ROOT/include/swift/bridging" "$LOCAL_TOOLCHAIN/include/swift/bridging"
    ln -sfn "$SYSTEM_SWIFT_ROOT/include/swift/bridging.modulemap" "$LOCAL_TOOLCHAIN/include/swift/module.modulemap"
    RESOURCE_ARGUMENTS=(-resource-dir "$LOCAL_TOOLCHAIN/lib/swift")
else
    RESOURCE_ARGUMENTS=()
fi

swiftc \
    "${RESOURCE_ARGUMENTS[@]}" \
    -warnings-as-errors \
    -O \
    -whole-module-optimization \
    -parse-as-library \
    -target arm64-apple-macos13.0 \
    "$PROJECT_DIR"/Sources/SimpleImager/*.swift \
    -o "$BINARY_PATH" \
    -framework SwiftUI \
    -framework AppKit \
    -framework CryptoKit \
    -framework IOKit \
    -framework UniformTypeIdentifiers

if [[ -d "$APP_PATH" ]]; then
    rm -r "$APP_PATH"
fi
mkdir -p "$MACOS_PATH" "$RESOURCES_PATH"
cp "$BINARY_PATH" "$MACOS_PATH/SimpleImager"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_PATH/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES_PATH/AppIcon.icns"
cp "$PROJECT_DIR/LICENSE" "$RESOURCES_PATH/LICENSE"
cp -R "$PROJECT_DIR/Resources/ThirdPartyLicenses" "$RESOURCES_PATH/ThirdPartyLicenses"
cp -R "$PROJECT_DIR/Resources/en.lproj" "$RESOURCES_PATH/en.lproj"
cp -R "$PROJECT_DIR/Resources/ru.lproj" "$RESOURCES_PATH/ru.lproj"
chmod 755 "$MACOS_PATH/SimpleImager"

"$PROJECT_DIR/scripts/stage-runtime.sh" "$CONTENTS_PATH"

SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
SIGN_ARGUMENTS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_ARGUMENTS+=(--options runtime --timestamp)
fi

for binary in "$FRAMEWORKS_PATH"/*(N) "$HELPERS_PATH"/*(N); do
    /usr/bin/codesign "${SIGN_ARGUMENTS[@]}" "$binary"
done

MANIFEST_PATH="$RESOURCES_PATH/RuntimeManifest.plist"
/usr/bin/plutil -create xml1 "$MANIFEST_PATH"
/usr/bin/plutil -insert schemaVersion -integer 1 "$MANIFEST_PATH"
/usr/bin/plutil -insert platform -string macos "$MANIFEST_PATH"
/usr/bin/plutil -insert architecture -string arm64 "$MANIFEST_PATH"
/usr/bin/plutil -insert files -array "$MANIFEST_PATH"

manifest_index=0
for binary in "$HELPERS_PATH"/*(N) "$FRAMEWORKS_PATH"/*(N); do
    if [[ "$binary" == "$HELPERS_PATH"/* ]]; then
        relative_path="Helpers/${binary:t}"
        kind=executable
    else
        relative_path="Frameworks/${binary:t}"
        kind=library
    fi
    digest="$(/usr/bin/openssl dgst -sha256 -r "$binary" | /usr/bin/awk '{print $1}')"
    /usr/bin/plutil -insert "files.$manifest_index" -dictionary "$MANIFEST_PATH"
    /usr/bin/plutil -insert "files.$manifest_index.path" -string "$relative_path" "$MANIFEST_PATH"
    /usr/bin/plutil -insert "files.$manifest_index.sha256" -string "$digest" "$MANIFEST_PATH"
    /usr/bin/plutil -insert "files.$manifest_index.kind" -string "$kind" "$MANIFEST_PATH"
    (( manifest_index += 1 ))
done

/usr/bin/codesign "${SIGN_ARGUMENTS[@]}" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
    /usr/sbin/spctl --assess --type execute --verbose=2 "$APP_PATH"
fi

if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    ARCHIVE_PATH="$PROJECT_DIR/.build/Simple-Imager-notarization.zip"
    /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
    /usr/bin/xcrun notarytool submit "$ARCHIVE_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$APP_PATH"
    /usr/bin/xcrun stapler validate "$APP_PATH"
fi

echo "Создано приложение: $APP_PATH"
