#!/bin/zsh
# cold cache での open 計測。detach/attach でボリュームのページキャッシュを落とす。
# 使い方: coldopen.sh <disk-image> <command> [args...]
# 書庫のパスは /Volumes/BenchCold/ 以下を計測コマンドへ渡す。
set -euo pipefail
if (( $# < 2 )); then
    echo "使い方: $0 <disk-image> <command> [args...]" >&2
    exit 2
fi
IMG="$1"; shift

# 一旦 detach → 再 attach でキャッシュを落とす
hdiutil detach /Volumes/BenchCold >/dev/null 2>&1 || true
hdiutil attach "$IMG" -mountpoint /Volumes/BenchCold -nobrowse >/dev/null 2>&1
# cold: 初回実行。出力形式は計測コマンドに委ね、経過時間を stderr に出す。
echo "cold:"
/usr/bin/time -p "$@"
# warm: 同じコマンドを別プロセスで直後に実行する。
echo "warm:"
/usr/bin/time -p "$@"
