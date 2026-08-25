#!/bin/zsh
# Washi(EPUB 3 ツールキット、Washi/ の SwiftPM パッケージ)を Washi.framework
# として Frameworks/ へ組み立てる。CooViewer.xcodeproj の Run Script phase から
# 呼ばれる(outputs 宣言済みのため、成果物がある間は phase 自体がスキップされる)。
# Washi/ のソース更新後に再ビルドしたいときは `rm -rf Frameworks/Washi.framework`。
#
# SwiftPM のローカルパッケージ参照を使わないのは、Xcode が legacy build location
# (このプロジェクトの build/ 直下方式)とパッケージ参照を併用できないため。
# XADMaster と同じ「スクリプトで Frameworks/ に生成して埋め込む」方式をとる。
#
# ツールチェーン互換: バイナリ .swiftmodule はコンパイラのバージョンに固定される
# ため、library evolution を有効にしてテキストの .swiftinterface も同梱する
# (別バージョンの Xcode/CLI は swiftmodule が読めないとき interface へ
# フォールバックする)。さらにビルド時の Swift バージョンをスタンプし、
# ツールチェーンが変わったら成果物が新しくても作り直す。
set -euo pipefail

cd "$(dirname "$0")/.."
FW_DIR="$PWD/Frameworks"
FW="$FW_DIR/Washi.framework"
BIN="$PWD/Washi/.build/release"

if [[ ! -e Washi/Package.swift ]]; then
    echo "error: Washi package is missing (Washi/Package.swift)" >&2
    exit 1
fi

# Xcode の script phase から起動された場合、継承したビルド環境変数が
# ネストしたビルドを壊すため、環境を最小構成にして実行する
run_swift() {
    env -i \
        HOME="$HOME" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}" \
        swift "$@"
}

SWIFT_VERSION="$(run_swift --version 2>/dev/null | head -1)"
STAMP_FILE="$FW/Versions/A/Resources/.swift-version"

# 成果物がソースより新しく、かつ同じツールチェーンで作られていればスキップ
if [[ -e "$FW/Versions/A/Washi" && \
      "$(cat "$STAMP_FILE" 2>/dev/null)" == "$SWIFT_VERSION" ]]; then
    if [[ -z "$(find Washi/Sources Washi/Package.swift Scripts/build-washi-framework.sh \
            -type f -newer "$FW/Versions/A/Washi" -print -quit)" ]]; then
        echo "Washi.framework is up to date."
        exit 0
    fi
fi

# library evolution + module interface 付きでビルドする(unsafeFlags を
# Package.swift に書くと依存パッケージとして使えなくなるため、フラグは
# ここで -Xswiftc として渡す)
run_swift build --package-path Washi -c release --product WashiDynamic \
    -Xswiftc -enable-library-evolution \
    -Xswiftc -emit-module-interface

# dylib + swiftmodule + swiftinterface からフレームワークバンドルを手組みする
rm -rf "$FW"
MODULES_DIR="$FW/Versions/A/Modules"
mkdir -p "$MODULES_DIR" "$FW/Versions/A/Resources"
cp "$BIN/libWashiDynamic.dylib" "$FW/Versions/A/Washi"

# 1 つのモジュール(swiftmodule + swiftdoc + interface)を Modules/ へ据える。
# Washi(表示層)は WashiCore(解析層)を @_exported 再輸出するので、
# `import Washi` の解決には **両方**の swiftmodule が同じ Modules/ に必要。
install_module() {
    local name="$1"
    local dest="$MODULES_DIR/$name.swiftmodule"
    mkdir -p "$dest"
    # swiftmodule の出力レイアウトは SwiftPM のバージョンで異なる:
    # - 新(Swift 6.4+): $BIN/<name>.swiftmodule/ がトリプル別ファイルのディレクトリ
    # - 旧(〜6.3): $BIN/Modules/ に <name>.swiftmodule 等が平置き
    if [[ -d "$BIN/$name.swiftmodule" ]]; then
        cp -R "$BIN/$name.swiftmodule/." "$dest/"
    elif [[ -f "$BIN/Modules/$name.swiftmodule" ]]; then
        for triple in arm64-apple-macos arm64-apple-macosx; do
            cp "$BIN/Modules/$name.swiftmodule" "$dest/$triple.swiftmodule"
            cp "$BIN/Modules/$name.swiftdoc" "$dest/$triple.swiftdoc"
            if [[ -e "$BIN/Modules/$name.abi.json" ]]; then
                cp "$BIN/Modules/$name.abi.json" "$dest/$triple.abi.json"
            fi
        done
    else
        echo "error: $name.swiftmodule not found under $BIN" >&2
        exit 1
    fi

    # .swiftinterface(ツールチェーン非依存の互換層)が無ければビルド出力から
    # 足す。これが無いと別バージョンの Xcode/CLI がバイナリ swiftmodule を
    # 読めず import に失敗する。出力位置はビルドシステムで異なるため
    # .build 全体から **最新の** ものを拾う(旧ツールチェーンの残骸を掴まない)
    local existing_interfaces=("$dest"/*.swiftinterface(N))
    if (( ${#existing_interfaces[@]} == 0 )); then
        local interface
        interface="$(find "$PWD/Washi/.build" -name "$name.swiftinterface" \
            -not -path '*ModuleCache*' -print0 2>/dev/null \
            | xargs -0 ls -t 2>/dev/null | head -1)"
        if [[ -z "$interface" ]]; then
            echo "error: $name.swiftinterface not emitted (compat layer missing)" >&2
            exit 1
        fi
        for triple in arm64-apple-macos arm64-apple-macosx; do
            cp "$interface" "$dest/$triple.swiftinterface"
        done
    fi

    # コンパイラの探索名(macos)と SwiftPM の出力トリプル(macosx)の相互補完
    for f in "$dest"/arm64-apple-macos.*(N); do
        local alt="${f/arm64-apple-macos./arm64-apple-macosx.}"
        [[ -e "$alt" ]] || cp "$f" "$alt"
    done
    for f in "$dest"/arm64-apple-macosx.*(N); do
        local alt="${f/arm64-apple-macosx./arm64-apple-macos.}"
        [[ -e "$alt" ]] || cp "$f" "$alt"
    done
}

install_module Washi
install_module WashiCore

cat > "$FW/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>ja</string>
	<key>CFBundleExecutable</key>
	<string>Washi</string>
	<key>CFBundleIdentifier</key>
	<string>jp.coo.Washi</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Washi</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
</dict>
</plist>
PLIST
echo "$SWIFT_VERSION" > "$STAMP_FILE"

ln -s A "$FW/Versions/Current"
ln -s Versions/Current/Washi "$FW/Washi"
ln -s Versions/Current/Modules "$FW/Modules"
ln -s Versions/Current/Resources "$FW/Resources"

install_name_tool -id "@rpath/Washi.framework/Versions/A/Washi" \
    "$FW/Versions/A/Washi"
# Debug はアドホック署名。Release は Embed 時の CodeSignOnCopy が
# Developer ID で再署名する(ネスト実行体を持たないので Sparkle のような
# 追加処置は不要)
codesign --force --sign - "$FW"
echo "Built $FW ($SWIFT_VERSION)"
