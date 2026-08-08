#!/bin/zsh
# XADMaster / UniversalDetector を Frameworks/ へビルドする。
# CooViewer.xcodeproj の Run Script phase から呼ばれる(outputs 宣言済みのため、
# Frameworks/ に成果物がある間は phase 自体がスキップされる)。
# サブモジュール更新後に再ビルドしたいときは `rm -rf Frameworks` してからビルドする。
set -euo pipefail

cd "$(dirname "$0")/.."
FW_DIR="$PWD/Frameworks"

# Sparkle(自動更新)は公式バイナリ配布を取得する(バージョン・チェックサム固定)
# EN: Sparkle is fetched as the pinned official binary distribution.
"$PWD/Scripts/fetch-sparkle.sh"

if [[ ! -d XADMaster/XADMaster.xcodeproj ]]; then
    echo "error: XADMaster submodule is missing. Run: git submodule update --init --recursive" >&2
    exit 1
fi

if [[ -e "$FW_DIR/XADMaster.framework/Versions/A/XADMaster" && \
      -e "$FW_DIR/UniversalDetector.framework/Versions/A/UniversalDetector" ]]; then
    if [[ -z "$(find XADMaster UniversalDetector -type f \
            \( -name '*.m' -o -name '*.h' -o -name '*.c' -o -name '*.cpp' -o -name '*.pbxproj' \) \
            -newer "$FW_DIR/XADMaster.framework/Versions/A/XADMaster" -print -quit)" ]]; then
        echo "Frameworks are up to date."
        exit 0
    fi
fi

# Xcode の script phase から起動された場合、継承したビルド環境変数が
# ネストした xcodebuild を壊すため、環境を最小構成にして実行する。
env -i \
    HOME="$HOME" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}" \
    xcodebuild \
    -project XADMaster/XADMaster.xcodeproj \
    -scheme XADMaster \
    -configuration Release \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CONFIGURATION_BUILD_DIR="$FW_DIR" \
    build
