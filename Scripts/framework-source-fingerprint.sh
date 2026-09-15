#!/bin/zsh
# ファイル名と内容をまとめて署名する。mtime に頼らず削除・追加・復元も検出する。
set -euo pipefail
if (( $# == 0 )); then
    echo "error: framework fingerprint needs input paths" >&2
    exit 1
fi

# NUL 区切りで空白等を含むパスを保つ。走査順には依存しない。
find "$@" -type f -print0 \
    | /usr/bin/xargs -0 /usr/bin/shasum -a 256 \
    | LC_ALL=C /usr/bin/sort \
    | /usr/bin/shasum -a 256 \
    | /usr/bin/awk '{print $1}'
