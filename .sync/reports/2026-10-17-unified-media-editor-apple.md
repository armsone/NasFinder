# 통합 영상만들기 선택기 (Apple) — 2.14.0 / 빌드 202610171659 (KST 2026-10-17 16:59)
모델: Claude Sonnet 5.5

## 구현 (소스)
- 홈 영상만들기 → 단일 "영상만들기" 선택기(LocalPhotoLibraryView). 우상단 + 메뉴: 사진·영상(시스템 선택기) / 파일 / 폰하드 / NAS·네트워크(저장 연결 전체 서브메뉴) / Google 포토.
- NAS·네트워크·폰하드: FileBrowserView/FileBrowserContainerView에 선택적 `onPickMedia` 콜백(기본 nil → 기존 동작 불변). 지정 시 폴더는 열리고 사진·영상만 선택, "영상만들기에 담기"로 선택 항목만 반환. 바스켓이 선택 항목만 다운로드해 앱 소유 임시 사본 저장(폰하드는 복사 없이 읽기 참조, 삭제 대상 아님: `ownsURL`).
- Google 포토: GooglePhotosImportFlowView에 선택적 `onImportedMedia`. 이번 세션에 가져온 레코드만 완료/취소(부분) 화면의 "영상만들기에 담기"로 반환. 콜백 없는 기존 홈 동작은 유지(버튼 문구만 "영상편집").
- 기존 progress/취소/부분 실패 경로 재사용, 취소·실패 시 기존 선택·순서 유지, 신원은 제공자+연결+경로(폰하드는 파일 경로), 교차 제공자 해시 중복 제거 없음.
- 중복 "내 사진·영상" 대시보드 링크 제거(영상만들기와 동일 목적지). 화면 제목 영상만들기.
- 편집기: 상단 "제작 방식"(예고편/뮤직비디오), 제목·접근성 "영상편집", 만들기 버튼 isBusy 비활성, analyzeHighlights는 성공 시에만 mode=.trailer(실패 시 이전 모드 유지, 실패에 done 미호출).
- 계약: .sync/product-contract.yaml `editing.unified_media_selector` 추가 (android: pending_other_worker).

## 빌드/설치
- Mac Catalyst arm64 빌드 exit 0, iOS generic exit 0 (/tmp/nasfinder-unified-{mac,ios}-build.log), 동일 scripts/xcodebuild_project.sh + /tmp/NasFinder-inline-music-device.
- /Applications/NasFinder.app 2.14.0 (202610171659) 정상 종료 후 교체·재실행(PID 85489). iPhone 00008150-001E342C3C87801C 설치·실행 exit 0, 2.14.0 (202610171659). 데이터 보존 설치.

## 한계
- 소스 빌드/설치만 확인. 각 출처(NAS·Google 포토 실제 인증 경로)의 실기기 UI 조작 검증은 TM CUA 확인 대기.
- 브라우저 선택은 폴더 단위로 담기(폴더 간 선택 누적은 담을 때마다 바스켓에 누적).
- 원본 편집·삭제·테스트 코드·커밋 없음.

## 2026-10-17 17:23 KST 최종 통합 수정 (2.14.1 / 202610171708)
- 실제 UI 원인: 홈 영상만들기가 ConnectionListView.swift `VideoCreateEntryLink.navigationDestination`에서 `LocalPhotoLibraryView()`(nil 모드)를 열어 제목이 내사진영상으로 매핑됨.
- 수정(1줄): 해당 destination만 `LocalPhotoLibraryView(initialMode: .trailer)`. myFilesSection 내사진영상 호출(454행)은 nil 유지. 그 외 소스 변경 없음.
- Mac Catalyst arm64 → iOS generic 순차 빌드 모두 BUILD SUCCEEDED. Mac 정상 quit 후 /Applications 교체·재실행(PID 92225), iPhone 설치·실행 exit 0. 데이터 보존.

## 보정: 공통 바구니 초기 순서 유지 (2026-10-17 KST)
- 원인: VideoTrailerModel.start가 sourceOrder 없을 때 항상 chronological 정렬 → 바구니(사진 IMG_7858 → NAS IMG_8543.mov)가 NAS→사진으로 뒤집힘.
- 수정: VideoTrailerSelection.keepsSelectionOrder(기본 false) → VideoTrailerView init → model.start(keepsInputOrder)에서 id(입력 인덱스) 순 유지. LocalPhotoLibraryView.beginTrailer만 true. 편집기의 시간순/랜덤/이름 정렬 버튼과 다른 호출부 기본 동작은 불변.
- 검색 툴바 누수('현재 폴더 검색'): FileBrowserCoverFlowView.swift FileBrowserSearchModifier(허용 범위 밖)에서 나옴. 확장하지 않고 보고만 함.
- 빌드(소스/빌드/설치 별도): iOS generic·Mac Catalyst 모두 BUILD SUCCEEDED (/tmp/nasfinder-basket-order-{ios,mac}-build.log), 2.15.0/202610171956 앱+확장 4개 일치, codesign 0. iPhone 00008150-001E342C3C87801C devicectl 설치(데이터 유지)+실행, Mac PID 32170 종료 후 /Applications 교체·재실행. 런타임 UI 검증은 주장하지 않음(TM 담당).
