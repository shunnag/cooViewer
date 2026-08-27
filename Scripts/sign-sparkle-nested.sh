#!/bin/zsh
# Sparkle.framework 内のネスト実行体(Updater.app / Autoupdate / XPC)を
# Developer ID+secure timestamp+hardened runtime で再署名する。
# Xcode の CodeSignOnCopy はフレームワーク本体しか再署名しないため、
# これを実行しないと公証が Invalid になる(Release 前に一度実行。
# Frameworks/ を作り直したら再実行)。エンタイトルメントは保持する。
# EN: Re-signs Sparkle's nested executables with Developer ID + timestamp +
# EN: hardened runtime; required for notarization. Run before a Release build
# EN: (and again whenever Frameworks/ is recreated).
set -euo pipefail

# 署名 ID は名前をハードコードしない: team ID (FQTM2788K5) から証明書ハッシュを
# 解決する。第 1 引数でセレクタ(ハッシュ等)を明示指定して上書きも可。
IDENTITY="${1:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Developer ID Application.*FQTM2788K5/{print $2; exit}')}"
if [[ -z "$IDENTITY" ]]; then
    echo "error: no Developer ID Application identity for team FQTM2788K5 found." >&2
    echo "       (pass a signing identity as \$1 to override)" >&2
    exit 1
fi

cd "$(dirname "$0")/.."
FW="Frameworks/Sparkle.framework"
if [[ ! -d "$FW" ]]; then
    echo "error: $FW not found. Build once (or run Scripts/fetch-sparkle.sh)." >&2
    exit 1
fi

sign() {
    codesign -f --timestamp -o runtime --preserve-metadata=entitlements \
        -s "$IDENTITY" "$1"
}

sign "$FW/Versions/B/XPCServices/Downloader.xpc"
sign "$FW/Versions/B/XPCServices/Installer.xpc"
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
# 最後にフレームワーク本体(埋め込み時に CodeSignOnCopy が再署名するが、
# Frameworks/ 内でも検証が通るよう整えておく)
# EN: Re-seal the framework itself so the vendored copy verifies too.
sign "$FW"

codesign --verify --strict --deep "$FW"
echo "Sparkle nested executables signed (identity: $IDENTITY)"
