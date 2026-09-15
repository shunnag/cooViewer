#!/usr/bin/env python3
"""監査 TSV を相対 path で比較する(開発ガイド §2.1)。"""

import argparse
import csv
import sys
from pathlib import Path


FIELDS = ("status", "names_sha256", "contents_sha256")


def load(path, engine):
    with Path(path).open(encoding="utf-8", newline="") as source:
        reader = csv.DictReader(source, delimiter="\t", quoting=csv.QUOTE_NONE)
        required = {"path", "engine", *FIELDS}
        if not required.issubset(reader.fieldnames or []):
            raise ValueError(f"{path}: 監査 TSV の必須列がありません")
        rows = {}
        for row in reader:
            if None in row or any(value is None for value in row.values()):
                raise ValueError(f"{path}:{reader.line_num}: 列数が不正です")
            if engine is not None and row["engine"] != engine:
                continue
            key = row["path"]
            if key in rows:
                raise ValueError(f"{path}: path が重複しています。--engine で絞ってください: {key}")
            rows[key] = row
        if engine is not None and not rows:
            raise ValueError(f"{path}: engine={engine} の行がありません")
        return rows


def differences(before, after):
    # TSV の可逆エスケープを保ったまま照合する。同じ実パスは同じキーになる。
    for path in sorted(before.keys() | after.keys()):
        if path not in before:
            yield path, "presence", "missing", "present"
        elif path not in after:
            yield path, "presence", "present", "missing"
        else:
            for field in FIELDS:
                if before[path][field] != after[path][field]:
                    yield path, field, before[path][field], after[path][field]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", help="比較元の監査 TSV")
    parser.add_argument("after", help="比較先の監査 TSV")
    parser.add_argument("--engine", choices=("kaitokit", "xadmaster"),
                        help="両エンジン入り TSV から比較するエンジンを指定")
    args = parser.parse_args(argv)
    try:
        before = load(args.before, args.engine)
        after = load(args.after, args.engine)
        print("path\tfield\tbefore\tafter")
        count = 0
        for row in differences(before, after):
            print("\t".join(row))
            count += 1
        print(f"audit-compare: differences={count}", file=sys.stderr)
        return 1 if count else 0
    except (OSError, UnicodeError, ValueError, csv.Error) as error:
        print(f"audit-compare: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
