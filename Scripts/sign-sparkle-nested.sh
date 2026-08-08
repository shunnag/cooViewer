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

IDENTITY="${1:-Developer ID Application: shunnag (FQTM2788K5)}"

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
echo "Sparkle nested executables signed with: $IDENTITY"
