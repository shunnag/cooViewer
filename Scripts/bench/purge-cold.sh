#!/bin/zsh
# sudo purge で cold にして open の物理 read を測る(内蔵 SSD)。
# 各書庫について purge→lha版open、purge→cdmem版open を交互に。
set -euo pipefail
S="$(cd "$(dirname "$0")/.." && pwd)"
A="$S/corpus/archives"
for a in sjis2000.zip ascii2000.zip book-deflate.cbz; do
    for v in lha cdmem; do
        sudo purge
        line=$("$S/variants/$v/MacOS/xadbench" open "$A/$a" 1)
        pr=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%.1f ms  physread=%d KB' % (d['rep_ms'][0], d['diskread']//1024))")
        printf "%-6s %-16s cold: %s\n" "$v" "$a" "$pr"
    done
done
