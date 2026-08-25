# NasFinder Super Thumbnail for Mac

Finder에 마운트된 NAS 또는 Mac 폴더를 직접 읽어 NasFinder의 `.NasFinder-Vault` 형식으로 수퍼썸네일을 만드는 macOS 전용 앱입니다.

- 사진과 영상 재귀 검색
- iPhone·iPad NasFinder와 호환되는 JPEG 이름 및 저장 구조
- 기존 썸네일 건너뛰기와 중단 후 재검사 방식의 이어하기
- 진행률, 예상시간, 원본 확인 용량, 생성 썸네일 용량 표시
- 동시 작업 충돌을 줄이는 worker/claim 기록

## 개발

```sh
swift test --package-path MacSuperThumbnail
swift build -c release --package-path MacSuperThumbnail
MacSuperThumbnail/build_app.sh
```

최소 지원 버전은 macOS 14이며 AVFoundation과 ImageIO만 사용합니다.

`build_app.sh`는 기본적으로 버전 `2.1.1`, 빌드 `202608251305`(표시 `202608251305`)의 `MacSuperThumbnail/dist/NasFinder Super Thumbnail.app`을 arm64+x86_64 유니버설 바이너리로 만들고 ad-hoc 서명합니다. Developer ID 배포본은 `SIGN_IDENTITY`, `APP_VERSION`, `BUILD_NUMBER`, `DISPLAY_BUILD_NUMBER` 환경변수를 지정한 뒤 Apple 공증을 진행합니다.

앱은 Sparkle 2.9.4로 시작 시 자동 업데이트 확인(6시간 주기)과 메뉴의 "업데이트 확인…" 수동 확인을 제공합니다. 릴리스/서명 절차는 `RELEASE.md`를 참고하세요.
