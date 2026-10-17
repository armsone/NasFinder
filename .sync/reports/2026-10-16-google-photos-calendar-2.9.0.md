# TM 확인 갱신 — 2026-10-16 21:29 KST

이 갱신이 아래 중간 보고보다 우선한다.

- Apple Mac/iPhone 및 Android Trifold 모두 최종 소스 2.9.0 빌드·데이터 유지 교체 설치·재실행 완료. Mac 서명 검증 정상. iPhone devicectl 실제 설치 버전 2.9.0 / 202610162040, Android 실제 설치 버전 2.9.0 / 412591 확인.
- Mac 충돌 수정 후 실제 Google 인증 단계·선택·가져오기·제작 통과. 앱 종료 및 교체 설치 후 다시 접속했을 때 로그인 재요구 없이 내부 Google 사진 목록이 열림. 최신 사진1(10월16일)+최신 동영상1(10월12일,39초) 가져오기 성공, 12장면 약12초 예고편 생성·영상 재생 확인. 별도로 Google 사진4장→4장면7초 제작·재생 확인.
- Android Google 포토 최신 사진1+최신 동영상1→2장면7초 제작·두 장면 재생 확인. 내 사진·영상→달력10월15일 사진2장→달력에서 바로 제작→약4초 예고편 생성·재생 확인.
- iPhone 내 사진·영상→달력10월14일 사진4장→달력에서 바로 제작→4장면7초 생성·재생 확인.
- iPhone Google 포토의 SFSafariViewController가 빈 화면 로딩에 머물러, Mac에서 가져오기에 성공한 persistent WKWebView 선택 화면으로 Apple 공통 전환. OAuth만 기존 ASWebAuthenticationSession 유지. 해당 공통 소스로 두 Apple 빌드/설치 완료.
- iPhone 새 내부 선택 화면은 Google 로그인 페이지까지 실제 표시됨. 최초 로그인은 사용자에게 요청한 상태이며, 이 새 방식에서 선택→가져오기→제작 및 재실행 후 로그인 유지 확인은 아직 미완료. Mac의 로그인 유지 확인을 iPhone 완료로 확대하지 않는다.
- Google 401 발생 시 저장 토큰 자동 갱신 후 딱 한 번 재시도하며, 갱신 불가면 정식 OAuth 재인증. 웹 쿠키는 기본 persistent 데이터 저장소 사용. Google 자체 보안 재확인은 앱에서 제거하거나 우회하지 않음.
- Mac 닫기 버튼 및 공통 선택창 최종 수정본까지 재설치 후 재실행 완료. 기존 데이터/계정/원본 파일은 삭제하거나 수정하지 않음. 생성한 예고편의 별도 폰하드 저장 완료는 현재 화면에서 확인하지 못했으므로 주장하지 않음.
- Linear 이력은 기존 호출에서 워크스페이스 사용량 제한으로 실패한 상태. 로컬 기록 보존. 커밋·푸시·공개 릴리즈·TestFlight·홈페이지 변경 없음.

---

# TM 확인 갱신 — 2026-10-16 21:21 KST

아래 Claude 최초 보고는 중간 이력이며, 현재 상태는 이 갱신을 우선한다.

- Apple/Android 2.9.0 빌드·교체 설치·실행 완료. 공개 릴리즈·커밋·푸시는 하지 않았다.
- Mac 실제 충돌 세 건은 GooglePhotosOAuthAuthorizer의 시스템 콜백에 MainActor가 추론되어 백그라운드 큐에서 실행되며 발생한 Swift isolation assertion. 콜백을 @Sendable로 지정하고 내부 Task에서 MainActor로 이동하도록 수정. 교체 후 동일 인증 단계 통과, 추가 충돌 기록 없음.
- Catalyst SFSafariViewController는 실제로 외부 브라우저로 전환돼 Mac 선택 페이지만 persistent WKWebView로 변경. OAuth는 ASWebAuthenticationSession 유지. 패스키는 해당 WKWebView에서 동작하지 않아 Google의 비밀번호 및 휴대전화 2FA로 사용자 인증을 진행했다. 인증·Google 선택 뒤 4개 가져오기 성공(실패 0), 4장면 7초 예고편 생성 진행 중.
- Mac 사진 권한 거절은 hardened runtime의 photos-library entitlement 누락이 실제 TCC 로그에서 확인돼 전용 Mac entitlements에 추가. 재설치 후 달력 미디어 표시 및 직접 제작 성공. 이전 서명 오류는 샌드박스 조회 한계였으며 정식 권한 조회/검증은 정상이다.
- 달력 하단 제작/복사 기능 Apple 적용. iPhone 실제 10월14일 사진4장→달력에서 직접 제작→4장면7초 생성 및 재생 확인. 사진별 길이 부동소수점 합산으로 마지막 사진이 빠지던 비교에 1e-6 여유 추가.
- Android 네이티브 Google 포토 선택→최신 사진1+최신 동영상1 가져오기→2장면7초 예고편 생성·두 장면 재생 확인. 초기 추천시간이 공통 영상 장면 길이보다 짧아 선택 항목이 누락되던 부분 수정, 수정본 재설치 후 확인.
- Android 달력10월15일 사진2개 표시·선택 확인. 최신 수정본에서 달력 제작 완료 확인은 진행 중.
- 전역 foreground 복귀 시 진행 중인 가져오기/선택/예고편 화면을 보존하도록 보강.
- Mac SuperThumbnail 취소는 명시적인 시트 바인딩 종료로 변경. 업데이트 확인은 이전 릴리즈를 메타데이터 검증 전에 제외해 오래된 피드의 product 누락 오류를 피하도록 수정. 이 두 항목은 빌드 확인, 실제 UI 재확인은 남음.
- 로그인 유지: 기존 OAuth 키체인 저장·자동 갱신을 보존. 추가로 생성 요청401이면 저장 토큰의 로컬 만료 전이라도 한 번 갱신 후 재시도, Mac WKWebView persistent 데이터 저장소 명시, 닫기 버튼 추가. 해당 추가분 Apple 양쪽 빌드 성공, 마지막 교체 설치 및 재실행 후 로그인 유지 확인은 진행 중.
- iPhone Google 선택 페이지가 다시 로딩에 머문 뒤 HTTP401이 관찰됨. 같은 시간 트라이폴드에 Google 계정 보호 안내가 표시돼 로그인 시도를 중단하고 사용자에게 인계했으며, 사용자가 재시도를 지시했다. 원본/비밀번호/보안 설정은 변경하지 않았다.
- 인증/개인정보 관련 추가분 독립 읽기 검토: 중대한 문제 없음. 테스트 러너 미실행.
- Linear 기록은 연결된 워크스페이스 이슈 사용량 제한으로 실패. 로컬 보고에 근거 유지.

---

# Google 포토 / 달력 / 버전 2.9.0 작업 보고 (Claude Sonnet 5, 20:41)

## 완료한 변경
1. **Google 포토 선택을 앱 내부 시트로 전환** (`NasFinder/Features/GooglePhotos/GooglePhotosImportFlowController.swift`)
   - `UIApplication.shared.open(pickerURI)`를 제거하고, Picker URI는 항상 인앱 `SFSafariViewController` 시트(`GooglePhotosPickerSheetPresenter`)로 표시. 외부 브라우저 앱(Whale 등) 전환이 없어져 앱이 백그라운드로 전환되지 않음.
   - 기존 `GooglePhotosPickerURLPresenter`(ASWebAuthenticationSession 기반 폴백)는 삭제. OAuth 인가는 별도 파일(`GooglePhotosOAuthAuthorizer`)의 `ASWebAuthenticationSession`만 그대로 사용(정책대로 시스템 OAuth 유지, WKWebView/UA 스푸핑 없음).
2. **전역 포그라운드 리셋이 진행 중인 Google 포토 가져오기를 끊던 문제 수정** (`ConnectionListView.swift`)
   - `resetToDashboardAfterForegroundReturn()`에서 `isImportingFromGooglePhotos = false` 제거. 이제 Google 포토 시트가 포그라운드 복귀 시 자동으로 닫히지 않으므로, 선택/가져오기 세션이 유지됨.
3. **Mac에서 Cancel이 동작하지 않던 OAuth 인증 문제 수정** (`GooglePhotosOAuthAuthorizer.swift`)
   - `ASWebAuthenticationSession`을 `withTaskCancellationHandler`로 감싸, Swift `Task` 취소 시 `session.cancel()`이 실제로 호출되도록 함. 기존에는 Task 취소가 ASWebAuthenticationSession에 전달되지 않아 "취소" 버튼이 무반응이었고, Escape 키(시스템 시트를 직접 닫음)만 동작했음. 이것이 Mac에서 "preparing" 상태가 2분 넘게 멈춰 있던 근본 원인으로 확인됨(세션이 열린 채로 응답을 기다리기만 함).
   - `GooglePhotosImportFlowController.run()`의 오류 처리에서 `Task.isCancelled`일 때 `.failed` 대신 `.cancelled`로 표시하도록 보강(취소 중 다른 오류로 올라오는 경우도 취소 UX로 통일).
4. **달력에서 바로 예고편/복사 가능하도록 bottomActionBar 노출** (`LocalPhotoLibraryView.swift`)
   - 기존에는 `.photos`/`.files` 모드에서만 하단 액션바가 보여서, 달력에서 고른 항목은 탭을 전환해야만 예고편/복사가 가능했음. 달력 모드에도 동일한 `bottomActionBar`를 `safeAreaInset(edge: .bottom)`로 추가(선택 0개일 때는 숨김, 중복 바 없음).
5. **버전 2.8.0 → 2.9.0, 새 빌드 스탬프** (`NasFinder.xcodeproj/project.pbxproj`)
   - 모든 타깃/구성에서 `MARKETING_VERSION = 2.9.0`, `CURRENT_PROJECT_VERSION = 202610162040`로 통일(12곳 모두 일치). 각 Info.plist는 `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)` 변수를 참조하므로 추가 수정 불필요.

## 변경한 파일
- NasFinder/Features/GooglePhotos/GooglePhotosImportFlowController.swift
- NasFinder/Core/Services/GooglePhotos/GooglePhotosOAuthAuthorizer.swift
- NasFinder/Features/Connections/ConnectionListView.swift
- NasFinder/Features/PhotoLibrary/LocalPhotoLibraryView.swift
- NasFinder.xcodeproj/project.pbxproj

각 파일을 `swift -frontend -parse`로 개별 구문 검사했고 오류 없음. 기존에 더티 상태였던 다른 파일(.sync/product-contract.yaml, AGENTS.md, DraftStore.swift, VideoTrailerPlan.swift, VideoTrailerView.swift, AppSettingsView.swift, Info.plist 등)은 손대지 않음 — `git status`로 확인.

## 확인하지 못한/손대지 않은 항목 (불확실성 보고)
- **Mac Catalyst "Access Allow가 OS 프롬프트 없이 즉시 denied로 바뀌는" 문제**: `LocalPhotoLibraryCalendarService.requestAccess()` 자체 로직은 정상(`PHPhotoLibrary.requestAuthorization(for: .readWrite)`). 원인은 권한 요청 로직이 아니라 서명/엔타이틀먼트/샌드박스 쪽일 가능성이 높지만, 어떤 조합인지 기기 없이 확정할 수 없었음. `com.apple.security.personal-information.photos-library` 같은 엔타이틀먼트를 추가하는 안을 검토했으나, 앱이 현재 App Sandbox(`com.apple.security.app-sandbox`)를 켜고 있지 않아 추측만으로 추가하면 효과가 없거나 프로비저닝 프로파일의 미등록 Capability로 서명이 아예 깨질 위험이 있어 보류함. 설치된 앱에서 `codesign -d --entitlements :-` 실제 출력과 Apple Developer Portal의 활성 Capability 목록을 먼저 확인한 뒤 결정하는 것을 권장.
- **`codesign -d --entitlements`가 "invalid entitlements blob"을 보고하는 문제**: 소스 엔타이틀먼트 파일(`NasFinder.entitlements`) 자체는 유효한 XML(app-groups, keychain-groups만 포함, 지시대로 최소 유지)이라 소스 변경으로 고칠 수 있는 문제가 아님. 빌드 산출물(설치된 .app)의 서명 과정(자동 서명 재생성, 캐시된 derived data, 프로파일 불일치) 쪽 문제로 추정되며, 코드/엔타이틀먼트 파일 수정만으로는 재현·검증이 불가능해 손대지 않음. 다음 빌드 후 TM이 `codesign -d --entitlements :- /Applications/NasFinder.app`으로 재확인 필요.
- **Mac SuperThumbnail 폴더 피커 Cancel 무반응, 잘못된 product 오류 매핑**: 해당 기능 코드 위치를 짧게 탐색했으나(VideoTrailerPlan/VideoTrailerView 등에서 명확한 folder-picker/product 매핑 코드를 찾지 못함) 이번 작업 범위에서 "가능하면"으로 명시된 낮은 우선순위 항목이라 시간 내 확정 진단을 하지 못해 손대지 않음.

## 재사용 가능한 빌드/서명/설치 명령 (TM 실행용, 기존에 성공했던 경로 재사용)
- iOS 시뮬레이터/기기 빌드: 기존 `.build/release-derived-ios` 등에서 쓰던 스킴·구성 그대로 재사용 가능(새 코드는 기존 타깃 구조를 변경하지 않음).
- Mac Catalyst: 기존 `.build/release-mac-2.2.4` 계열과 동일한 Archive 절차 재사용. 엔타이틀먼트 파일을 바꾸지 않았으므로 서명 커맨드도 기존과 동일.
- 설치 후 확인: `codesign -d --entitlements :- /Applications/NasFinder.app` (엔타이틀먼트 블롭 유효성 재확인용, TM이 실행).

## 보존 확인
`git status`로 이번 작업 전 더티였던 모든 파일이 그대로 수정 중 상태로 남아있고, 이번 세션에서 추가로 건드린 파일은 보고서에 명시한 5개뿐임을 확인함.
