#!/bin/zsh
# KaitoKit の兄弟チェックアウトが組み立てるユニバーサルフレームワークを
# cooViewer の Frameworks/ へ配置する。SwiftPM 参照にせず、設計書 §1.4 の
# 動的フレームワーク構成に合わせて書庫エンジン差し替えを検証するため。
#
# KAITOKIT_SOURCE_DIR には KaitoKit の Package.swift があるディレクトリを指定する。
# 未指定時は、このリポジトリを基準に ../KaitoKit を使う。
set -euo pipefail

SCRIPT_PATH="${0:A}"
REPOSITORY_DIR="${SCRIPT_PATH:h:h}"
SOURCE_DIR="${KAITOKIT_SOURCE_DIR:-$REPOSITORY_DIR/../KaitoKit}"
if [[ "$SOURCE_DIR" != /* ]]; then
    SOURCE_DIR="$REPOSITORY_DIR/$SOURCE_DIR"
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "error: KaitoKit source directory is missing ($SOURCE_DIR)" >&2
    exit 1
fi
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd -P)"

if [[ ! -f "$SOURCE_DIR/Package.swift" ]]; then
    echo "error: KaitoKit package is missing ($SOURCE_DIR/Package.swift)" >&2
    exit 1
fi

SOURCE_BUILD_SCRIPT="$SOURCE_DIR/Scripts/build-framework.sh"
if [[ ! -x "$SOURCE_BUILD_SCRIPT" ]]; then
    echo "error: KaitoKit framework builder is missing or not executable ($SOURCE_BUILD_SCRIPT)" >&2
    exit 1
fi

SOURCE_FRAMEWORK="$SOURCE_DIR/Frameworks/KaitoKit.framework"
DESTINATION_FRAMEWORK="$REPOSITORY_DIR/Frameworks/KaitoKit.framework"
DESTINATION_EXECUTABLE="$DESTINATION_FRAMEWORK/Versions/A/KaitoKit"
DESTINATION_MODULES="$DESTINATION_FRAMEWORK/Versions/A/Modules"
STAMP_FILE="$REPOSITORY_DIR/Frameworks/.KaitoKit-framework-stamp"
CALLER_HOME="${HOME:-/var/empty}"
CALLER_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"

# ネストした SwiftPM ビルドと同じ最小環境でバージョンを調べ、Xcode から
# 継承したビルド設定を誤ってツールチェーン判定へ混ぜない。
SWIFT_VERSION="$(env -i \
    HOME="$CALLER_HOME" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    DEVELOPER_DIR="$CALLER_DEVELOPER_DIR" \
    swift --version 2>/dev/null | sed -n '1p')"
if [[ -z "$SWIFT_VERSION" ]]; then
    echo "error: Swift compiler version could not be determined" >&2
    exit 1
fi
STAMP_VALUE="${SWIFT_VERSION}"$'\n'"${SOURCE_DIR}"

# 配置済みバイナリがソースとラッパーより新しく、同じコンパイラで作られて
# いれば何もしない。設計書 §1.4 の反復ビルド最適化を維持するため。
if [[ -f "$DESTINATION_EXECUTABLE" && \
      -d "$DESTINATION_MODULES/KaitoKit.swiftmodule" && \
      -d "$DESTINATION_MODULES/KaitoKitCompat.swiftmodule" && \
      -f "$STAMP_FILE" ]] && [[ "$(<"$STAMP_FILE")" == "$STAMP_VALUE" ]]; then
    if [[ -z "$(find "$SOURCE_DIR/Sources" "$SOURCE_DIR/Package.swift" \
            "$SOURCE_BUILD_SCRIPT" "$SCRIPT_PATH" \
            -type f -newer "$STAMP_FILE" -print -quit)" ]]; then
        echo "KaitoKit.framework is up to date."
        exit 0
    fi
fi

# KaitoKit 側をフレームワーク構成の唯一の正とし、同梱スクリプトへ組み立てを
# 委譲する。cooViewer 側ではバイナリとモジュールを改変せず、埋め込み用に複製する。
"$SOURCE_BUILD_SCRIPT"

if [[ ! -f "$SOURCE_FRAMEWORK/Versions/A/KaitoKit" || \
      ! -d "$SOURCE_FRAMEWORK/Versions/A/Modules/KaitoKit.swiftmodule" || \
      ! -d "$SOURCE_FRAMEWORK/Versions/A/Modules/KaitoKitCompat.swiftmodule" ]]; then
    echo "error: KaitoKit.framework is incomplete ($SOURCE_FRAMEWORK)" >&2
    exit 1
fi

mkdir -p "${DESTINATION_FRAMEWORK:h}"
rm -f "$STAMP_FILE"
rm -rf "$DESTINATION_FRAMEWORK"
/usr/bin/ditto "$SOURCE_FRAMEWORK" "$DESTINATION_FRAMEWORK"
printf '%s\n' "$STAMP_VALUE" > "$STAMP_FILE"
echo "Installed $DESTINATION_FRAMEWORK ($SWIFT_VERSION)"
