#!/bin/zsh
# 公開済み GitHub リリースの本文を HTML に変換し、署名する feed の <item> に埋め込む。
# 使い方: Scripts/make-appcast.sh <zip> <マーケティング版> <ビルド番号> [ノート.md]
#   例:   Scripts/make-appcast.sh build/Release/cooViewer-2.0b3.zip 2.0b3 2003
# HTML のみ出力: Scripts/make-appcast.sh --notes-html <マーケティング版> [ノート.md]
# ノート.md を指定すると GitHub の本文取得を省略する。HTML 変換には GitHub API を使う。
# 前提: GitHub リリースを先に公開し、公証・ステープル済みの zip を渡すこと。
# 秘密鍵はログインキーチェーン(generate_keys が作成)。
set -euo pipefail

usage() {
    echo "usage: $0 <zip> <marketing-version> <build-number> [notes.md]" >&2
    echo "       $0 --notes-html <marketing-version> [notes.md]" >&2
}

if [[ "${1:-}" == "--notes-html" ]]; then
    if [[ $# -lt 2 || $# -gt 3 ]]; then
        usage
        exit 1
    fi
elif [[ $# -lt 3 || $# -gt 4 ]]; then
    usage
    exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cooviewer-appcast.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

notes_html() {
    local version="$1" notes_file="${2:-}"
    if [[ -n "$notes_file" ]]; then
        if [[ ! -f "$notes_file" || ! -r "$notes_file" ]]; then
            echo "error: cannot read release notes file: $notes_file" >&2
            return 1
        fi
        cat "$notes_file" > "$WORK_DIR/notes.md"
    else
        if ! gh release view "v$version" -R shunnag/cooViewer --json body -q .body > "$WORK_DIR/notes.md"; then
            echo "error: cannot fetch release v$version. Publish the GitHub release before running make-appcast.sh and check network access." >&2
            return 1
        fi
        local is_draft
        if ! is_draft="$(gh release view "v$version" -R shunnag/cooViewer --json isDraft -q .isDraft)"; then
            echo "error: cannot check publication of release v$version." >&2
            return 1
        fi
        if [[ "$is_draft" != "false" ]]; then
            echo "error: release v$version is not published. Publish it before running make-appcast.sh." >&2
            return 1
        fi
    fi
    if ! python3 - "$WORK_DIR/notes.md" <<'EOF'
import sys
from pathlib import Path
if not Path(sys.argv[1]).read_text().strip():
    sys.exit("error: release notes body is empty. Publish a release with non-empty notes first.")
EOF
    then
        return 1
    fi

    # -F は @- の標準入力を読み込む。-f では本文が文字列 @- になってしまう。
    if ! gh api markdown -H 'Accept: text/html' -F text=@- -f mode=gfm -f context=shunnag/cooViewer \
        < "$WORK_DIR/notes.md" > "$WORK_DIR/rendered.html"; then
        echo "error: cannot render release notes with the GitHub Markdown API." >&2
        return 1
    fi
    python3 - "$version" "$WORK_DIR/rendered.html" <<'EOF'
import html
import re
import sys
from pathlib import Path

body = Path(sys.argv[2]).read_text()
if not body.strip():
    sys.exit("error: GitHub Markdown API returned empty HTML.")
body = re.sub(r'</?markdown-accessiblity-table\b[^>]*>', '', body, flags=re.IGNORECASE)
# 単独出力でも CDATA の終端を作らず、表示は HTML の実体参照で保つ。
body = body.replace(']]>', ']]&gt;')
url = html.escape(f'https://github.com/shunnag/cooViewer/releases/tag/v{sys.argv[1]}', quote=True)
print('''<style>
:root { color-scheme: light dark; }
body { font: 14px -apple-system, sans-serif; line-height: 1.6; color: #24292f; background: #fff; }
a { color: #0969da; }
table { border-collapse: collapse; margin: 1em 0; width: 100%; }
th, td { border: 1px solid #d0d7de; padding: 6px 10px; text-align: left; }
th { background: #f6f8fa; }
code, pre { font-family: ui-monospace, monospace; font-size: 0.9em; background: #f6f8fa; }
code { padding: 0.15em 0.3em; border-radius: 3px; overflow-wrap: anywhere; }
pre { padding: 12px; border-radius: 6px; overflow-x: auto; }
pre code { padding: 0; overflow-wrap: normal; }
@media (prefers-color-scheme: dark) {
  body { color: #e6edf3; background: #0d1117; }
  a { color: #79c0ff; }
  th, td { border-color: #484f58; }
  th, code, pre { background: #161b22; }
}
</style>''')
print(body.rstrip())
print(f'<p><a href="{url}">GitHub のリリースページ</a></p>')
EOF
}

if [[ "$1" == "--notes-html" ]]; then
    notes_html "$2" "${3:-}"
    exit 0
fi

ZIP="${1:A}"
VERSION="$2"
BUILD="$3"
NOTES_FILE="${4:-}"
if [[ -n "$NOTES_FILE" ]]; then
    NOTES_FILE="${NOTES_FILE:A}"
fi

cd "$(dirname "$0")/.."

# 署名や feed の更新より前に、配布 URL・引数・実物の版の取り違えを止める。
if [[ "$(basename "$ZIP")" != "cooViewer-$VERSION.zip" ]]; then
    echo "error: zip basename must be cooViewer-$VERSION.zip ($ZIP)" >&2
    exit 1
fi
if ! ZIP_VERSION="$(unzip -p "$ZIP" cooViewer.app/Contents/Info.plist \
    | plutil -extract CFBundleShortVersionString raw -)"; then
    echo "error: cannot read CFBundleShortVersionString from cooViewer.app/Contents/Info.plist in $ZIP" >&2
    exit 1
fi
if ! ZIP_BUILD="$(unzip -p "$ZIP" cooViewer.app/Contents/Info.plist \
    | plutil -extract CFBundleVersion raw -)"; then
    echo "error: cannot read CFBundleVersion from cooViewer.app/Contents/Info.plist in $ZIP" >&2
    exit 1
fi
if [[ "$ZIP_VERSION" != "$VERSION" || "$ZIP_BUILD" != "$BUILD" ]]; then
    echo "error: zip app version/build is $ZIP_VERSION/$ZIP_BUILD; expected $VERSION/$BUILD" >&2
    exit 1
fi

SIGN_UPDATE="Frameworks/Sparkle-dist/bin/sign_update"
if [[ ! -x "$SIGN_UPDATE" ]]; then
    echo "error: $SIGN_UPDATE not found. Build once (or run Scripts/fetch-sparkle.sh)." >&2
    exit 1
fi

# 本文の取得・変換が失敗したら、署名や feed の変更には進まない。
notes_html "$VERSION" "$NOTES_FILE" > "$WORK_DIR/notes.html"

# sign_update の出力例: sparkle:edSignature="..." length="..."
SIGNATURE_ATTRS="$($SIGN_UPDATE "$ZIP")"
PUBDATE="$(LC_ALL=en_US date -u '+%a, %d %b %Y %H:%M:%S +0000')"
URL="https://github.com/shunnag/cooViewer/releases/download/v$VERSION/$(basename "$ZIP")"

MARKER="<!-- make-appcast.sh inserts new items below -->"
if ! grep -qF "$MARKER" appcast.xml; then
    echo "error: marker comment not found in appcast.xml" >&2
    exit 1
fi

python3 - "$VERSION" "$BUILD" "$PUBDATE" "$URL" "$SIGNATURE_ATTRS" "$WORK_DIR" <<'EOF'
import sys
from pathlib import Path
version, build, pubdate, url, signature_attrs, work_dir = sys.argv[1:]
notes = (Path(work_dir) / "notes.html").read_text().replace(']]>', ']]]]><![CDATA[>')
item = f'''        <item>
            <title>cooViewer {version}</title>
            <pubDate>{pubdate}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <link>https://github.com/shunnag/cooViewer/releases/tag/v{version}</link>
            <sparkle:fullReleaseNotesLink>https://github.com/shunnag/cooViewer/releases/tag/v{version}</sparkle:fullReleaseNotesLink>
            <description><![CDATA[{notes}]]></description>
            <enclosure url="{url}" {signature_attrs} type="application/octet-stream"/>
        </item>'''
item_file = Path(work_dir) / "item.xml"
item_file.write_text(item)
marker = b"<!-- make-appcast.sh inserts new items below -->"
appcast = Path("appcast.xml")
appcast.write_bytes(appcast.read_bytes().replace(marker, marker + b"\n" + item_file.read_bytes(), 1))
EOF

# 不正な XML を署名しないよう、挿入後の feed 全体を先に検査する。
if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout appcast.xml
else
    python3 - <<'EOF'
import xml.etree.ElementTree as ET
ET.parse("appcast.xml")
EOF
fi

# item の挿入後に署名し、その署名を検証する順序を崩さない。
"$SIGN_UPDATE" appcast.xml
"$SIGN_UPDATE" --verify appcast.xml

echo "appcast.xml updated for $VERSION (build $BUILD)."
echo "Commit & push appcast.xml to master so the feed URL serves it."
echo "appcast.xml を手で編集したら、必ず sign_update appcast.xml で再署名してください。"
