#!/bin/bash

set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"

git config core.hooksPath .githooks

configured_path="$(git config --get core.hooksPath)"
if [[ "$configured_path" != ".githooks" ]]; then
    echo "error: Git hook 경로를 설정하지 못했습니다." >&2
    exit 1
fi

echo "Git hooks enabled: $configured_path"
