#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="$PROJECT_DIR/.build/app"
APP_PATH="$PROJECT_DIR/.build/SD Архиватор.app"
CONTENTS_PATH="$APP_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
BINARY_PATH="$BUILD_DIR/SDCardCopy"
SYSTEM_SWIFT_ROOT="/Library/Developer/CommandLineTools/usr"
LOCAL_TOOLCHAIN="$PROJECT_DIR/.build/toolchain/usr"

mkdir -p "$BUILD_DIR"

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
    -parse-as-library \
    "$PROJECT_DIR"/Sources/SDCardCopy/*.swift \
    -o "$BINARY_PATH" \
    -framework SwiftUI \
    -framework AppKit \
    -framework CryptoKit \
    -framework UniformTypeIdentifiers

if [[ -d "$APP_PATH" ]]; then
    rm -r "$APP_PATH"
fi
mkdir -p "$MACOS_PATH"
cp "$BINARY_PATH" "$MACOS_PATH/SDCardCopy"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_PATH/Info.plist"
chmod 755 "$MACOS_PATH/SDCardCopy"
/usr/bin/codesign --force --deep --sign - "$APP_PATH"

echo "Создано приложение: $APP_PATH"
