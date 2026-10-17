# 브라우저 음악 감지/다운로드 수정 2.14.1 (2026-10-17)

## 구현 (소스 기준)
- 후보마다 URL + 자기 제목(title) + 재생 중 여부를 묶은 값으로 다룸. 다운로드는 탭 시점의 후보 값을 불변 스냅샷으로 사용(Apple: musicSnapshot, Android: startDownload 인자).
- SPA 곡 변경: 페이지 JS가 audio play/loadstart/emptied/loadedmetadata/durationchange, popstate/hashchange에서 "rescan 요청"만 네이티브로 전달(디바운스). Apple은 WKScriptMessageHandler(약참조 프록시, 메인 프레임/현재 WebView/"scan"|"nav" 문자열만 허용, invalidate에서 제거), Android는 @JavascriptInterface requestScan(kind) 하나(active 플래그, onRelease에서 제거) + doUpdateVisitedHistory.
- 스캔 결과는 이전 DOM 후보를 교체(병합 안 함). 재생 중 후보를 우선. 응답 기반 후보는 DOM 후보가 없을 때만 최신 1개 fallback. 페이지 generation/스캔 sequence/URL 가드로 오래된 결과 폐기.
- 제목: 재생 중이면 navigator.mediaSession.metadata.title → 요소 title/aria-label/data-title → document.title. 비재생 audio/링크는 자기 요소 라벨/링크 텍스트만.
- 파일명: 제목(NFC, 제어/금지/방향 문자 제거, 100자 제한, URL/서명 토큰 형태 거부) + 서버 CD/URL 확장자 또는 audio MIME 확장자. 제목 없으면 서버 파일명 fallback + MIME 확장자 보정.
- 닫기(X): 현재 후보 identity(host+path)를 dismissed로 기록하고 알림/선택 대기 제거. 같은 identity는 재스캔으로 재등장하지 않음. 새 곡 재생 시작, 새 navigation(didCommit/onPageStarted, 리로드 포함)에서는 다시 표시 가능. 진행 중 다운로드는 취소하지 않음(알림은 다운로드 중 숨김 상태 유지, 기존 진행/취소/저장 선택 UI 그대로).
- 다운로드 성공 시 소비된 후보를 dismissed 처리하여 첫 곡 버튼이 남지 않음.
- 기존 URL 검증/http(s) 제한/referer/쿠키 경로, 웹 보안 설정 변경 없음.

## 버전/빌드
- Apple 2.14.1 build 202610171708 (전 타깃), Android 2.14.1 / 416668 / BUILD_NUMBER 202610171708.
- 빌드(순차, 종료코드 파일 리다이렉트): MacCatalyst arm64 exit 0, generic iOS exit 0, Android assembleDebug exit 0 (로그 /tmp/nf_*_build.log).

## 설치/실행
- Mac: 정상 종료 후 ditto /Applications/NasFinder.app, 재실행 PID 87561, 2.14.1(202610171708).
- iPhone: devicectl install/launch, 2.14.1(202610171708) 확인.
- Android SM_F968N(192.168.0.253:39513): install -r Success, versionName 2.14.1/code 416668, force-stop 후 EnamelLauncherAlias 실행 PID 16613. APK sha256 233eb86c55ed761a22ec68f891291706324b026ab01d94e27e3455aa5af83722.

## 미확인
- 테스트/린트/실제 사이트 재현 미실시. 실제 사용자 사이트에서 동작 여부 unknown. 보안 리뷰(브리지)는 TM이 별도 수행 예정.
- scoped canonical product contract 파일 위치를 특정하지 못해 갱신하지 않음.

## 재빌드 보정 (2.14.1 / 416668 유지, 새 버전 아님)
1. 후보 식별: 쿼리 전체(프래그먼트 제외)를 포함하도록 변경. `/stream?id=A`와 `?id=B`가 구분되며 원본 URL은 그대로 요청.
2. 일시정지/emptied 후 같은 곡 재개 시 닫은 알림이 되살아나지 않도록 마지막 재생 곡을 유지(닫을 때 현재 재생 후보로 시드). 다른 곡으로 바뀔 때만 해제. 전체 로드/이동에서만 초기화.
3. WKScript 신호에 네이티브 250ms 합치기 추가(Task 생성 전). kind/top-frame 검증은 기존 유지.
4. 파일명: UTF-8 220바이트 이내(문자소 단위), 서버 파일명도 안전한 stem/"음악" 대체, 오디오 확장자 교체(.bin.mp3 방지). 음악 요청에만 reloadIgnoringLocalCacheData.
5. LocalPhotoLibraryView 제목: nil="내 사진·영상", trailer="영상 만들기".
