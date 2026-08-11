# NasFinder 작업 보존 및 배포 규칙

이 저장소에서 소스 수정, GitHub 푸시, 실기기 설치를 수행하는 모든 에이전트는 다음 규칙을 지켜야 한다.

1. 작업 시작과 종료 시 `./scripts/repository_guard.sh status`를 실행한다.
2. `refs/codex/snapshots`에 일반 로컬 브랜치가 포함하지 않는 스냅샷이 있으면 작업을 중단하고 먼저 복구한다.
3. 사용자가 받을 최종 앱을 `xcodebuild`와 `devicectl`로 직접 설치하지 않는다.
4. 최종 앱은 변경을 모두 커밋하고 GitHub upstream에 동일한 커밋을 푸시한 후에만 `make install-verified DEVICE_ID=<id>`로 설치한다.
5. 최종 설치 전에 현재 브랜치, HEAD 커밋, upstream 커밋을 사용자에게 진행 상황으로 알린다.
6. 작업 폴더가 dirty한 상태에서는 push하지 않는다. 저장소의 pre-push 훅을 우회하는 `--no-verify`를 사용하지 않는다.
7. 작업을 archive, cleanup 또는 다른 worktree로 전환하기 전에 변경이 일반 브랜치와 GitHub에 보존됐는지 확인한다.
8. 테스트·빌드·아이콘 번들 검증·설치·실행 중 하나라도 실패하면 완료라고 보고하지 않는다.

로컬 훅은 저장소를 처음 받은 뒤 `make hooks`로 활성화한다.
