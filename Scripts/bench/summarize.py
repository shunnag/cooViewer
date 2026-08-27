# results/all.tsv を集計: バリアント×(mode,archive) の中央値と baseline 比を表示。
# 初回 rep はウォームアップとして除外(rep>=2 の中央値)。sha256 の食い違いも検査。
import json, sys, statistics, collections

path = sys.argv[1] if len(sys.argv) > 1 else "results/all.tsv"
rows = []
for line in open(path):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 3:
        continue
    variant, ts, js = parts[0], parts[1], parts[2]
    d = json.loads(js)
    key = (d["mode"], d["archive"])
    reps = d["rep_ms"][1:] if len(d["rep_ms"]) > 1 else d["rep_ms"]
    rows.append((variant, key, statistics.median(reps), d.get("sha256")))

# 同一バリアント複数回実行は全 rep(初回除外済み)まとめて中央値
agg = collections.defaultdict(list)
sha = {}
for variant, key, med, s in rows:
    agg[(variant, key)].append(med)
    if s:
        prev = sha.setdefault(key, {})
        prev.setdefault(variant, s)

base = {}
for (variant, key), meds in agg.items():
    if variant == "baseline":
        base[key] = statistics.median(meds)

keys = sorted(set(k for (_, k) in agg), key=lambda k: (k[0], k[1]))
variants = []
for v, _ in agg:
    if v not in variants:
        variants.append(v)

print(f"{'mode/archive':38s} " + " ".join(f"{v:>12s}" for v in variants))
for key in keys:
    cells = []
    for v in variants:
        meds = agg.get((v, key))
        if not meds:
            cells.append(f"{'-':>12s}")
            continue
        m = statistics.median(meds)
        b = base.get(key)
        rel = f"({m/b*100:.0f}%)" if b else ""
        cells.append(f"{m:7.1f}{rel:>6s}"[:12].rjust(12))
    print(f"{key[0]+'/'+key[1]:38s} " + " ".join(cells))

# 正しさ: baseline と異なるダイジェストを警告
bad = False
for key, per in sha.items():
    b = per.get("baseline")
    for v, s in per.items():
        if b and s != b:
            print(f"!! SHA MISMATCH {key} {v}: {s[:16]} != baseline {b[:16]}")
            bad = True
if not bad:
    print("sha256: all variants match baseline")
