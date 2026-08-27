#!/bin/zsh
# XADMaster フレームワークをバリアント別ディレクトリへビルドし、ハーネスを配置する。
# 使い方: build-variant.sh <name> [xcodebuild 追加設定...]
# 作業領域は $BENCH_WORK(既定 /tmp/cooviewer-bench)。ハーネスは先に
# $BENCH_WORK/bin へビルドしておくこと(README.md 参照)。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
W="${BENCH_WORK:-/tmp/cooviewer-bench}"
NAME="$1"; shift
V="$W/variants/$NAME"
rm -rf "$V"
mkdir -p "$V/Frameworks" "$V/MacOS"

env -i \
    HOME="$HOME" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}" \
    xcodebuild \
    -project "$REPO/XADMaster/XADMaster.xcodeproj" \
    -scheme XADMaster \
    -configuration Release \
    -derivedDataPath "$V/dd" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    MACOSX_DEPLOYMENT_TARGET=26.0 \
    CONFIGURATION_BUILD_DIR="$V/Frameworks" \
    "$@" \
    build > "$V/build.log" 2>&1 || { tail -30 "$V/build.log"; exit 1; }

cp "$W/bin/xadbench" "$W/bin/xadbench-swift" "$V/MacOS/"
# 中間生成物は削除(ディスク節約。成果物は Frameworks/ に出力済み)
rm -rf "$V/dd"
echo "variant $NAME built"
