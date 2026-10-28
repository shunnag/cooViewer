#!/bin/zsh
# pl7x 計測: ノイズの幅(A 対 A)と ABAB。1 試行 = 1 process。結果は JSONL。
setopt nullglob
H=${0:A:h}; OUT=$H/results.jsonl; : > $OUT
A=$H/pkg-v0.15.0/.build/release/pl7x; B=$H/pkg-v0.17.0/.build/release/pl7x
RA=$(git -C $H/kk-v0.15.0 describe --tags); RB=$(git -C $H/kk-v0.17.0 describe --tags)
V=/Volumes/Test_10G/pl7x; N=0
trial() { # <phase> <A|B> <archive> <cold|warm> <i>
  local bin rev target; [[ $2 == A ]] && { bin=$A; rev=$RA } || { bin=$B; rev=$RB }
  if [[ $4 == cold ]]; then
    N=$((N+1)); local c=cold-$N-$3
    ssh -o BatchMode=yes Mac-mini-M4.local "cp -c ~/Test_10G/pl7x/$3 ~/Test_10G/pl7x/$c"
    target=$V/$c
  else
    target=$V/$3
  fi
  local line; line=$(timeout 600 $bin $target $rev $4 2>&1 | tail -1)
  echo "{\"phase\":\"$1\",\"slot\":\"$2\",\"i\":$5,\"r\":$line}" >> $OUT
  [[ $4 == cold ]] && ssh -o BatchMode=yes Mac-mini-M4.local "rm -f ~/Test_10G/pl7x/$c"
  echo "$1 $2 $3 $4 $5 done"
}
warmup() { cat $V/$1 > /dev/null; }
ARCH=(big-jpeg.7z big-tiff.7z mid-mt1.7z)
for a in $ARCH; do warmup $a; for i in 1 2 3 4; do trial noise A $a warm $i; done; done
for a in $ARCH; do for i in 1 2 3 4; do trial noise A $a cold $i; done; done
for a in $ARCH; do
  warmup $a
  for i in 1 2 3 4; do trial main A $a warm $i; trial main B $a warm $i; done
  for i in 1 2 3 4; do trial main A $a cold $i; trial main B $a cold $i; done
done
echo DONE
