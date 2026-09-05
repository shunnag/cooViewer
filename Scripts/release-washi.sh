#!/usr/bin/env bash
# Washi/ を公開リポジトリへ片方向ミラーし、SemVer タグを公開する。
# 使い方: Scripts/release-washi.sh <version> [--dry-run]
# --dry-run は検証だけを行い、変更を加えるコマンドを表示する。
set -euo pipefail

usage() {
    echo "使い方: $0 <version> [--dry-run]" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 2
fi

VERSION="$1"
DRY_RUN=false
if [[ $# -eq 2 ]]; then
    if [[ "$2" != "--dry-run" ]]; then
        usage
        exit 2
    fi
    DRY_RUN=true
fi

# `sort -V` と順序が一致する、v を付けない安定版 SemVer(X.Y.Z)に限定する。
VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if [[ ! "$VERSION" =~ $VERSION_RE ]]; then
    echo "error: version は v を付けない安定版 SemVer(X.Y.Z)で指定してください: $VERSION" >&2
    exit 2
fi

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

MIRROR_URL="https://github.com/shunnag/Washi.git"
PUBLIC_BRANCH="washi-public"

# 公開対象に未コミットの変更があれば、split が取りこぼすため停止する。
if [[ -n "$(git status --porcelain -- Washi)" ]]; then
    echo "error: Washi/ に未コミットの変更があります。先にコミットしてください。" >&2
    exit 1
fi

# リリース対象は Unreleased ではなく、日付が確定した見出しでなければならない。
CHANGELOG_PREFIX="## [$VERSION] - "
CHANGELOG_DATE="$(awk -v prefix="$CHANGELOG_PREFIX" \
    'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }' \
    Washi/CHANGELOG.md)"
if [[ ! "$CHANGELOG_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "error: Washi/CHANGELOG.md に '$CHANGELOG_PREFIX<YYYY-MM-DD>' がありません。" >&2
    exit 1
fi

# 公開側の最新タグを version sort で求め、同じ版や巻き戻しを拒否する。
LATEST_TAG="$(git ls-remote --tags https://github.com/shunnag/Washi.git \
    | awk '{print $2}' \
    | sed 's#refs/tags/##' \
    | sort -V \
    | tail -1)"
if [[ -n "$LATEST_TAG" ]]; then
    if [[ ! "$LATEST_TAG" =~ $VERSION_RE ]]; then
        echo "error: 公開側の最新タグを安定版 SemVer として比較できません: $LATEST_TAG" >&2
        exit 1
    fi
    GREATEST_TAG="$(printf '%s\n%s\n' "$LATEST_TAG" "$VERSION" | sort -V | tail -1)"
    if [[ "$VERSION" == "$LATEST_TAG" || "$GREATEST_TAG" != "$VERSION" ]]; then
        echo "error: version $VERSION は公開側の最新タグ $LATEST_TAG より大きくありません。" >&2
        exit 1
    fi
fi

if [[ "$DRY_RUN" == true ]]; then
    # split 後にも行う構成確認を、現在のコミットの Washi/ に対して先取りする。
    if ! git ls-tree --name-only HEAD:Washi | grep -Fxq 'Package.swift'; then
        echo "error: Washi/ のルートに Package.swift がありません。" >&2
        exit 1
    fi

    echo "dry-run: 公開側の最新タグ: ${LATEST_TAG:-なし}"
    printf '+ git subtree split --prefix=Washi -b %s\n' "$PUBLIC_BRANCH"
    printf '+ git ls-tree --name-only %s\n' "$PUBLIC_BRANCH"
    printf '+ git push %s %s:main\n' "$MIRROR_URL" "$PUBLIC_BRANCH"
    printf '+ git tag %s %s\n' "$VERSION" "$PUBLIC_BRANCH"
    printf '+ git push %s %s\n' "$MIRROR_URL" "$VERSION"
    exit 0
fi

git subtree split --prefix=Washi -b "$PUBLIC_BRANCH"

if ! git ls-tree --name-only "$PUBLIC_BRANCH" | grep -Fxq 'Package.swift'; then
    echo "error: $PUBLIC_BRANCH のルートに Package.swift がありません。" >&2
    exit 1
fi

if ! git push "$MIRROR_URL" "$PUBLIC_BRANCH:main"; then
    echo "error: 公開ミラーへの push が拒否されました。" >&2
    echo "スクリプトは強制 push しません。履歴を確認し、片方向ミラーの上書きが必要な場合だけ、開発ガイド §3.5 に従って次を手動実行してください。" >&2
    printf '  git push --force %s %s:main\n' "$MIRROR_URL" "$PUBLIC_BRANCH" >&2
    exit 1
fi

git tag "$VERSION" "$PUBLIC_BRANCH"
git push "$MIRROR_URL" "$VERSION"

echo "Washi $VERSION を公開しました。"
