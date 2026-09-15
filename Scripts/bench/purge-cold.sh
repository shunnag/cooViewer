#!/bin/zsh
# sudo purge で cold にして任意の書庫計測コマンドを実行する(内蔵 SSD)。
# 使い方: purge-cold.sh <command> [args...]。先に別途 sudo の認証を済ませる。
set -euo pipefail
if (( $# < 1 )); then
    echo "使い方: $0 <command> [args...]" >&2
    exit 2
fi
sudo -n purge
# 計測対象は呼び出しユーザーで実行する。出力形式に依存しない。
exec /usr/bin/time -p "$@"
