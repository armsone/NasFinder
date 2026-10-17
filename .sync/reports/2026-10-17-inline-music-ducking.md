# 인라인 음악 버튼 + 자동 덕킹 (2.13.0 / 202610171417)

- 소스: TrailerMusic.swift, TrailerMusicRemoteBrowser.swift, FileBrowserView.swift, ReceivedFilesView.swift, VideoTrailerView.swift
- 내용: 인라인 음악 버튼(일시정지/진행률), 원본 RMS 기반 BGM -55..-25dBFS 연속 덕킹(attack/release), 원본 게인 불변, 자동 토글 기본 on/음악별 보존, off 시 일정 음량.
- iOS: BUILD SUCCEEDED, iPhone17Pro 설치/실행. Android 2.13.0/416665 설치/실행 확인.
- Mac: Mac Catalyst arm64 단일 아키텍처 빌드 exit 0 (/tmp/inline-music-mac-arm64-build.log), /Applications/NasFinder.app 데이터 보존 교체(ditto), 재실행 확인, 버전 2.13.0/202610171417, arm64. 내장 extension 없음.
- 미검증: 실제 청취 확인은 사용자 몫.
