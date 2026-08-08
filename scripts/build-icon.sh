#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
MASTER_ICON="$PROJECT_DIR/Resources/AppIcon.svg"
SOURCE_ICON="${1:-$MASTER_ICON}"

if [[ ! -f "$SOURCE_ICON" ]]; then
    echo "SVG-файл не найден: $SOURCE_ICON" >&2
    exit 1
fi

if [[ "${SOURCE_ICON:A}" != "${MASTER_ICON:A}" ]]; then
    cp "$SOURCE_ICON" "$MASTER_ICON"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sd-card-copy-icon.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

RASTER_ICON="$WORK_DIR/AppIcon.png"
/usr/bin/sips -s format png "$MASTER_ICON" --out "$RASTER_ICON" >/dev/null
ICONSET="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"

typeset -A ICON_SIZES=(
    icon_16x16.png 16
    icon_16x16@2x.png 32
    icon_32x32.png 32
    icon_32x32@2x.png 64
    icon_128x128.png 128
    icon_128x128@2x.png 256
    icon_256x256.png 256
    icon_256x256@2x.png 512
    icon_512x512.png 512
    icon_512x512@2x.png 1024
)

for filename size in ${(kv)ICON_SIZES}; do
    /usr/bin/sips -z "$size" "$size" "$RASTER_ICON" \
        --out "$ICONSET/$filename" >/dev/null
done

/usr/bin/iconutil -c icns "$ICONSET" -o "$PROJECT_DIR/Resources/AppIcon.icns"
echo "Создана иконка: $PROJECT_DIR/Resources/AppIcon.icns"
