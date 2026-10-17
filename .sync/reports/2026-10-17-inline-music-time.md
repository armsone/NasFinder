# 인라인 음악 재생 시간 표시 (2.13.2 / 202610171633)

[16:36 팀장][완료]

- 표시: 대기 `크기 · 3:28`, 재생/일시정지 `크기 · 0:42 / 3:28`. 전체 길이를 모르면 전체 시간은 표시하지 않음(0:00 안 보임). 1시간 이상은 h:mm:ss.
- 변경: `TrailerMusicAuditionPlayer`에 `elapsed`/`duration` 게시(기존 0.1초 타이머 재사용, 메인 액터). `InlineMusicPlayback`이 재생 중 측정한 길이를 목록 수명 동안 캐시(`knownDuration`). 새 `InlineMusicTimeText`를 FileBrowserView 행(`RemoteFileMetadataView`)과 ReceivedFilesView(`LocalInboxSizeLabel`)에 적용.
- 원격: 전체 다운로드 없음. 첫 재생 시 로더가 측정한 길이가 나오면 표시. 폰하드: 기존 `LocalInboxMediaDurationCache`/`LocalInboxDurationLabel`의 비동기 측정 재사용.
- 원 링 진행, 재생/일시정지 버튼, 기존 메타데이터, 접근성 레이블 유지(시간 텍스트에 접근성 레이블 추가).
- 버전 2.13.1/202610171625 -> 2.13.2/202610171633 (전체 타깃).
- Mac arm64 빌드 exit 0 (/tmp/nasfinder-music-time-mac-build.log), /Applications/NasFinder.app 교체 후 재실행(2.13.2).
- iOS generic 빌드 exit 0 (/tmp/nasfinder-music-time-ios-build.log), iPhone(00008150-001E342C3C87801C) 설치 및 실행.
- 테스트 미실행. TM이 CUA로 Mac 실제 NAS MP3를 재생하여 0:00 → 0:10 → 0:16 / 3:28 표시와 일시정지 후 0:16 유지 상태를 확인. 오디오 출력은 앞서 사용자 직접 재생 확인. iPhone 시간 표시 UI는 미확인.
- 알려진 차이: 폰하드 대기 상태의 전체 시간(브라우저 행)은 기존 라벨이라 `03:28`(mm:ss), 재생 후에는 `3:28`로 바뀜. 접근성 행 레이블에는 시간이 합쳐지지 않음.
