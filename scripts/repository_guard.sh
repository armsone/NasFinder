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

if [[ "$mode" == "push" ]]; then
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

if [[ $failed -ne 0 ]]; then
    exit 1
fi

echo "repository guard: OK"
echo "branch: ${branch:-detached}"
echo "commit: $head_sha"
