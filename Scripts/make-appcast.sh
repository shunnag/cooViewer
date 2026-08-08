#!/bin/zsh
# リリース zip を Sparkle の EdDSA 鍵で署名し、appcast.xml に <item> を挿入する。
# 使い方: Scripts/make-appcast.sh <zip> <マーケティング版> <ビルド番号>
#   例:   Scripts/make-appcast.sh build/Release/cooViewer-2.0b3.zip 2.0b3 2003
# 前提: リリース手順(CLAUDE.md)で公証・ステープル済みの zip を渡すこと。
# 秘密鍵はログインキーチェーン(generate_keys が作成)。
# EN: Signs a release zip with the Sparkle EdDSA key and inserts an <item>
# EN: into appcast.xml. Pass the notarized & stapled zip.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <zip> <marketing-version> <build-number>" >&2
    exit 1
fi

ZIP="$1"
VERSION="$2"
BUILD="$3"

cd "$(dirname "$0")/.."
SIGN_UPDATE="Frameworks/Sparkle-dist/bin/sign_update"
if [[ ! -x "$SIGN_UPDATE" ]]; then
    echo "error: $SIGN_UPDATE not found. Build once (or run Scripts/fetch-sparkle.sh)." >&2
    exit 1
fi

# sign_update の出力例: sparkle:edSignature="..." length="..."
SIGNATURE_ATTRS="$($SIGN_UPDATE "$ZIP")"
PUBDATE="$(LC_ALL=en_US date -u '+%a, %d %b %Y %H:%M:%S +0000')"
URL="https://github.com/shunnag/cooViewer/releases/download/v$VERSION/$(basename "$ZIP")"

ITEM="        <item>
            <title>cooViewer $VERSION</title>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <link>https://github.com/shunnag/cooViewer/releases/tag/v$VERSION</link>
            <sparkle:releaseNotesLink>https://github.com/shunnag/cooViewer/releases/tag/v$VERSION</sparkle:releaseNotesLink>
            <enclosure url=\"$URL\" $SIGNATURE_ATTRS type=\"application/octet-stream\"/>
        </item>"

MARKER="<!-- make-appcast.sh inserts new items below -->"
if ! grep -qF "$MARKER" appcast.xml; then
    echo "error: marker comment not found in appcast.xml" >&2
    exit 1
fi

python3 - "$ITEM" <<'EOF'
import sys
item = sys.argv[1]
marker = "<!-- make-appcast.sh inserts new items below -->"
text = open("appcast.xml").read()
text = text.replace(marker, marker + "\n" + item, 1)
open("appcast.xml", "w").write(text)
EOF

echo "appcast.xml updated for $VERSION (build $BUILD)."
echo "Commit & push appcast.xml to master so the feed URL serves it."
