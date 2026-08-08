#!/bin/zsh
# Sparkle(自動更新フレームワーク。MIT ライセンス)の公式バイナリ配布を
# Frameworks/ へ取得する。build-frameworks.sh から呼ばれる。
# バージョンと SHA-256 を固定し、改ざん・すり替えを検出する。
# 更新するときは SPARKLE_VERSION と SPARKLE_SHA256 を併せて上げること。
# EN: Fetches the pinned official Sparkle binary distribution into Frameworks/,
# EN: verifying its SHA-256. Bump SPARKLE_VERSION and SPARKLE_SHA256 together.
set -euo pipefail

SPARKLE_VERSION="2.9.5"
SPARKLE_SHA256="015336b601493e05c237964954bff6191370003d94edefe663724c88840d73cc"

cd "$(dirname "$0")/.."
FW_DIR="$PWD/Frameworks"
DIST_DIR="$FW_DIR/Sparkle-dist"

if [[ -e "$FW_DIR/Sparkle.framework/Versions/B/Sparkle" && \
      -e "$DIST_DIR/VERSION" && \
      "$(cat "$DIST_DIR/VERSION")" == "$SPARKLE_VERSION" ]]; then
    echo "Sparkle $SPARKLE_VERSION is up to date."
    exit 0
fi

echo "Fetching Sparkle $SPARKLE_VERSION..."
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE="$TMP_DIR/Sparkle-$SPARKLE_VERSION.tar.xz"
curl -fsSL -o "$ARCHIVE" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"

ACTUAL="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
if [[ "$ACTUAL" != "$SPARKLE_SHA256" ]]; then
    echo "error: Sparkle archive checksum mismatch (got $ACTUAL)" >&2
    exit 1
fi

tar -xJf "$ARCHIVE" -C "$TMP_DIR"
mkdir -p "$FW_DIR" "$DIST_DIR"
rm -rf "$FW_DIR/Sparkle.framework" "$DIST_DIR/bin"
# ditto でシンボリックリンク構造と署名を保ったままコピーする
# EN: ditto preserves the framework's symlink structure and code signature.
ditto "$TMP_DIR/Sparkle.framework" "$FW_DIR/Sparkle.framework"
ditto "$TMP_DIR/bin" "$DIST_DIR/bin"
cp "$TMP_DIR/LICENSE" "$DIST_DIR/LICENSE"
echo "$SPARKLE_VERSION" > "$DIST_DIR/VERSION"
echo "Sparkle $SPARKLE_VERSION installed into Frameworks/."
