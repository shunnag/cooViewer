# 破損入力バッテリー: 各シード書庫から切詰め・ビット反転のミュータントを決定論的に生成
import random, sys, os

seeds = sys.argv[1:-1]
outdir = sys.argv[-1]
os.makedirs(outdir, exist_ok=True)
rng = random.Random(20260827)
n = 0
for seed in seeds:
    data = open(seed, "rb").read()
    base = os.path.basename(seed)
    for i in range(12):  # 切詰め
        cut = rng.randrange(1, len(data))
        open(f"{outdir}/{base}.trunc{i}", "wb").write(data[:cut])
        n += 1
    for i in range(20):  # ビット反転(1-16 箇所)
        buf = bytearray(data)
        for _ in range(rng.randrange(1, 17)):
            pos = rng.randrange(len(buf))
            buf[pos] ^= 1 << rng.randrange(8)
        open(f"{outdir}/{base}.flip{i}", "wb").write(buf)
        n += 1
print(f"{n} mutants")
