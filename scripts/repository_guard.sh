#!/bin/bash

set -euo pipefail

mode="${1:-status}"
case "$mode" in
    status|push|install) ;;
    *)
        echo "error: usage: $0 [status|push|install]" >&2
        exit 2
        ;;
esac

repository_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "error: Git 저장소 안에서 실행해야 합니다." >&2
    exit 1
}
cd "$repository_root"

failed=0
branch="$(git symbolic-ref --quiet --short HEAD || true)"
head_sha="$(git rev-parse HEAD)"

if [[ -z "$branch" ]]; then
    echo "error: detached HEAD에서는 푸시하거나 최종 앱을 만들 수 없습니다." >&2
    failed=1
fi

if [[ "$mode" == "push" || "$mode" == "install" ]]; then
    if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
        echo "error: 커밋되지 않은 변경이 있습니다." >&2
        echo "       Git push는 작업 폴더의 변경을 포함하지 않습니다. 먼저 모두 커밋하세요." >&2
        git status --short >&2
        failed=1
    fi
fi

unanchored_snapshots=0
while IFS=' ' read -r snapshot_ref snapshot_sha; do
    [[ -n "$snapshot_ref" && -n "$snapshot_sha" ]] || continue
    containing_branch="$(
        git for-each-ref --contains "$snapshot_sha" --format='%(refname:short)' refs/heads \
            | sed -n '1p'
    )"
    if [[ -z "$containing_branch" ]]; then
        if [[ $unanchored_snapshots -eq 0 ]]; then
            echo "error: 일반 브랜치에 포함되지 않은 Codex 스냅샷이 있습니다." >&2
        fi
        echo "       $snapshot_ref -> $snapshot_sha" >&2
        unanchored_snapshots=$((unanchored_snapshots + 1))
    fi
done < <(
    git for-each-ref --format='%(refname) %(objectname)' refs/codex/snapshots
)

if [[ $unanchored_snapshots -gt 0 ]]; then
    echo "       스냅샷을 검토해 브랜치로 복구하기 전에는 진행할 수 없습니다." >&2
    failed=1
fi

if [[ "$mode" == "install" && -n "$branch" ]]; then
    upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    if [[ -z "$upstream" ]]; then
        echo "error: 현재 브랜치 '$branch'에 GitHub upstream이 없습니다." >&2
        echo "       먼저 git push --set-upstream origin $branch 를 실행하세요." >&2
        failed=1
    else
        remote="$(git config --get "branch.$branch.remote")"
        merge_ref="$(git config --get "branch.$branch.merge")"
        remote_branch="${merge_ref#refs/heads/}"
        git fetch --quiet "$remote" "$remote_branch"
        upstream_sha="$(git rev-parse '@{upstream}')"
        if [[ "$head_sha" != "$upstream_sha" ]]; then
            echo "error: 로컬 HEAD와 GitHub upstream이 다릅니다." >&2
            echo "       local:    $head_sha" >&2
            echo "       upstream: $upstream_sha" >&2
            echo "       동일한 커밋을 푸시한 뒤에만 설치할 수 있습니다." >&2
            failed=1
        fi
    fi
fi

if [[ $failed -ne 0 ]]; then
    exit 1
fi

echo "repository guard: OK"
echo "branch: ${branch:-detached}"
echo "commit: $head_sha"
if [[ "$mode" == "install" ]]; then
    echo "upstream: $(git rev-parse '@{upstream}')"
fi
