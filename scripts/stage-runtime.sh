#!/bin/zsh

set -euo pipefail

if (( $# != 1 )); then
    echo "Использование: $0 /путь/к/App.app/Contents" >&2
    exit 2
fi

CONTENTS_PATH="$1"
HELPERS_PATH="$CONTENTS_PATH/Helpers"
FRAMEWORKS_PATH="$CONTENTS_PATH/Frameworks"
HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-/opt/homebrew}"

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Сборка runtime поддерживается только на Apple Silicon." >&2
    exit 1
fi
if [[ ! -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    echo "Не найден Homebrew для Apple Silicon: $HOMEBREW_PREFIX/bin/brew" >&2
    exit 1
fi

BREW="$HOMEBREW_PREFIX/bin/brew"
required_formulae=(zstd xz lz4 sevenzip e2fsprogs gettext)
missing_formulae=()
for formula in "${required_formulae[@]}"; do
    if ! "$BREW" list --versions "$formula" >/dev/null 2>&1; then
        missing_formulae+=("$formula")
    fi
done
if (( ${#missing_formulae} > 0 )); then
    echo "Для сборки установите: brew install ${missing_formulae[*]}" >&2
    exit 1
fi

rm -rf "$HELPERS_PATH" "$FRAMEWORKS_PATH"
mkdir -p "$HELPERS_PATH" "$FRAMEWORKS_PATH"

copy_helper() {
    local source="$1"
    local name="$2"
    [[ -x "$source" ]] || { echo "Не найден runtime-компонент: $source" >&2; exit 1; }
    cp -L "$source" "$HELPERS_PATH/$name"
    chmod 755 "$HELPERS_PATH/$name"
}

copy_library() {
    local source="$1"
    local name="${source:t}"
    [[ -f "$source" ]] || { echo "Не найдена библиотека: $source" >&2; exit 1; }
    [[ -f "$FRAMEWORKS_PATH/$name" ]] || cp -L "$source" "$FRAMEWORKS_PATH/$name"
    chmod 755 "$FRAMEWORKS_PATH/$name"
}

copy_helper "$HOMEBREW_PREFIX/bin/zstd" zstd
copy_helper "$HOMEBREW_PREFIX/bin/xz" xz
copy_helper "$HOMEBREW_PREFIX/bin/lz4" lz4
copy_helper "$HOMEBREW_PREFIX/bin/7zz" 7zz

E2FS_PREFIX="$("$BREW" --prefix e2fsprogs)"
for tool in debugfs e2fsck resize2fs tune2fs; do
    copy_helper "$E2FS_PREFIX/sbin/$tool" "$tool"
done

copy_library "$("$BREW" --prefix zstd)/lib/libzstd.1.dylib"
copy_library "$("$BREW" --prefix xz)/lib/liblzma.5.dylib"
copy_library "$("$BREW" --prefix lz4)/lib/liblz4.1.dylib"

# Follow every Homebrew dependency so the installed app never needs Homebrew.
runtime_files=("$HELPERS_PATH"/*(N) "$FRAMEWORKS_PATH"/*(N))
index=1
while (( index <= ${#runtime_files} )); do
    current="${runtime_files[$index]}"
    dependencies=("${(@f)$(/usr/bin/otool -L "$current" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')}" )
    for dependency in "${dependencies[@]}"; do
        if [[ "$dependency" == "$HOMEBREW_PREFIX"/* ]]; then
            destination="$FRAMEWORKS_PATH/${dependency:t}"
            if [[ ! -f "$destination" ]]; then
                cp -L "$dependency" "$destination"
                chmod 755 "$destination"
                runtime_files+=("$destination")
            fi
        fi
    done
    (( index += 1 ))
done

for current in "$HELPERS_PATH"/*(N) "$FRAMEWORKS_PATH"/*(N); do
    if [[ "$(/usr/bin/file -b "$current")" != *"arm64"* ]]; then
        echo "Runtime-компонент не содержит arm64: $current" >&2
        exit 1
    fi

    dependencies=("${(@f)$(/usr/bin/otool -L "$current" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')}" )
    for dependency in "${dependencies[@]}"; do
        library="$FRAMEWORKS_PATH/${dependency:t}"
        if [[ -f "$library" && ( "$dependency" == "$HOMEBREW_PREFIX"/* || "$dependency" == @rpath/* ) ]]; then
            if [[ "$current" == "$HELPERS_PATH"/* ]]; then
                replacement="@executable_path/../Frameworks/${dependency:t}"
            else
                replacement="@loader_path/${dependency:t}"
            fi
            /usr/bin/install_name_tool -change "$dependency" "$replacement" "$current"
        fi
    done

    if [[ "$current" == "$FRAMEWORKS_PATH"/*.dylib ]]; then
        /usr/bin/install_name_tool -id "@rpath/${current:t}" "$current"
    fi
done

if /usr/bin/otool -L "$HELPERS_PATH"/* "$FRAMEWORKS_PATH"/* | /usr/bin/grep -q "$HOMEBREW_PREFIX"; then
    echo "В runtime остались абсолютные ссылки на Homebrew." >&2
    exit 1
fi

/usr/bin/xattr -cr "$HELPERS_PATH" "$FRAMEWORKS_PATH"
