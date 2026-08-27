#!/bin/zsh
# cold cache での open 計測。detach/attach でボリュームのページキャッシュを落とす。
# 使い方: coldopen.sh <variant> <archive-basename>
set -euo pipefail
S="$(cd "$(dirname "$0")/.." && pwd)"
V="$1"; ARC="$2"
IMG="$S/cold.sparseimage"
BIN="$S/variants/$V/MacOS/xadbench"

# 一旦 detach → 再 attach でキャッシュを落とす
hdiutil detach /Volumes/BenchCold >/dev/null 2>&1 || true
hdiutil attach "$IMG" >/dev/null 2>&1
# cold: 初回 open(reps=1)
COLD=$("$BIN" open "/Volumes/BenchCold/$ARC" 1)
# warm: 直後の open(同一プロセスではないので別実行、キャッシュは載っている)
WARM=$("$BIN" open "/Volumes/BenchCold/$ARC" 1)
echo "$V $ARC"
echo "  cold: $COLD"
echo "  warm: $WARM"
