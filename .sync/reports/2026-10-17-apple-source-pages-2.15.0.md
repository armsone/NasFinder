# Apple 2.15.0 출처 가로 페이지 + 공유 썸네일 트레이 (소스·빌드·설치만, UI 미확인)

## 변경 파일
- .sync/product-contract.yaml (editing.unified_media_selector 먼저 갱신)
- NasFinder/Features/PhotoLibrary/LocalPhotoLibrarySourcePages.swift (신규, 461줄: 탭/페이저/네트워크 페이지/트레이/파일 페이지)
- NasFinder/Features/PhotoLibrary/LocalPhotoLibraryView.swift (+ 메뉴·push 제거, 탭+페이저+트레이, Google 큐)
- NasFinder/Features/GooglePhotos/GooglePhotosImportFlowView.swift (임베드 모드)
- NasFinder/Features/Browser/FileBrowserView.swift (임베드 루트 뒤로 버튼 숨김, 담은 뒤 브라우저 선택 해제 — 최소 3곳)
- NasFinder.xcodeproj/project.pbxproj (MARKETING_VERSION 2.14.2→2.15.0 12곳, CURRENT_PROJECT_VERSION 202610171956 12곳)

## 동작(소스 기준)
- 사진/달력/폰하드/즐겨찾기/NAS·네트워크/파일/Google 포토 탭 + 가로 스와이프. 처음 방문한 페이지만 생성하고 이후 유지(폴더 경로·웹 세션 보존). 부모 상단 바는 숨기고 슬림 헤더(뒤로)만 두어 중첩 바는 브라우저 자체 하나뿐.
- 하단 공유 트레이: 선택 순서 썸네일, 항목별 X(44pt), 탭=미리보기, 개수, 폰하드 복사, 영상 편집. 기존 선택은 출처 전환·폴더 이동·취소에 유지.
- 폰하드=기존 FileBrowserView(선택 모드), 즐겨찾기=기존 MediaFavoritePickerView(리스트 행. 썸네일 타일 스타일은 미적용), NAS=저장 연결 목록→기존 브라우저.
- 파일 페이지: 사용자가 고른 폴더를 보안 범위 북마크(UserDefaults)로 기억하고 실제 폴더/썸네일 격자 + 경로 이동/상위 폴더. 보조 버튼은 기존 fileImporter(취소 시 바구니 유지). iOS 전체 파일시스템 열거는 불가.
- Google: 기존 흐름을 임베드. 제목·dismiss 제거, 웹 피커는 최상위 WKWebView 유지, 페이지 전환으로 취소하지 않음(부모 이탈 정리 때만 cancel). 끝/취소/실패 시 새 기록을 큐로 바구니에 추가, 원본 기록은 폰하드 소유(삭제 없음). 완료 버튼은 "더 선택하기".
- 라이프사이클 결함 수정: 기존 cleanup 가드에 즐겨찾기 push가 빠져 있었음 → push 방식 제거로 해소. 페이지 전환은 임시 사본을 지우지 않음. 편집기 전달은 기존 beginTrailer가 전체 entries를 순서대로 준비.

## OS/제공자 차이
- Google 웹 피커는 iframe 불가라 안드로이드식 인라인 격자와 다르게 웹 화면 그대로 표시(공식 sessions 가이드).

## 빌드/버전/서명 (분리)
- iOS generic: scripts/xcodebuild_project.sh build, derivedData /tmp/NasFinder-inline-music-device, exit 0 + BUILD SUCCEEDED (/tmp/nasfinder-apple-pages-ios-build.log).
- Mac Catalyst(순차): BUILD SUCCEEDED, 단 wrapper exit 143(원인 미확인, 잔류 프로세스 없음; 성공으로 위장하지 않음) (/tmp/nasfinder-apple-pages-mac-build.log).
- 버전: iOS 앱+확장 4개(DocumentPicker/FileProvider/Share/Widget) 모두 2.15.0 (202610171956), Mac 2.15.0 (202610171956; Mac은 appex 미포함). 기준 이전 2.14.2.
- 서명: 기존 설정(Apple Development) 그대로, codesign --verify --deep --strict iOS/Mac 모두 0.
- 설치: BK_iPhone17pro(00008150-001E342C3C87801C)만 devicectl install(데이터 유지)+launch 성공, info apps 2.15.0/202610171956. Mac: 정상 quit→ditto /Applications→open, 실행 확인.

## 미확인
- 모든 실제 UI(스와이프, 트레이, 폴더 탐색, Google 세션 유지, 혼합 출처 복사/편집) 미실행. 가로 페이지와 내부 세로 스크롤/뒤로 스와이프 충돌 가능성, 비지연 HStack의 onDisappear 거동은 런타임 확인 필요. 테스트/린트 실행 안 함. Git 커밋/푸시 없음.

## 모델/사용량
- Claude Sonnet 5.5 (claude-sonnet-5-5). 토큰 사용량 상세 수치는 제공되지 않음.

## 보정 (2026-10-17 20:23 KST 실측)
- 소스: MediaFavoritePickerView를 FavoriteCell 썸네일 격자(탭 전용, 순서변경/제거 없음)로 교체. MediaFilesSourcePage.list를 throwing으로 바꾸고 loadError(다시 시도/폴더 선택) 표시, 바구니·경로 유지, CancellationError 비삼킴. 페이지 재진입(isActive 전환)·refreshToken 변경 시 재로딩(폴링·선택 초기화 없음). 폰하드는 기존 FileBrowserView가 inboxStore.records onChange로 이미 갱신(FileBrowserView.swift:2319). 허용되지 않은 파일시스템은 열거하지 않음.
- 변경 파일: LocalPhotoLibrarySourcePages.swift, LocalPhotoLibraryView.swift(isActive 전달 1줄), FavoriteViews.swift.
- 빌드(별도): iOS generic exit 0 + BUILD SUCCEEDED, Mac Catalyst exit 0 + BUILD SUCCEEDED (행 없음). 로그 /tmp/nasfinder-apple-pages-{ios,mac}-build2.log. 버전 2.15.0 (202610171956), 앱+확장 4개 일치, codesign 검증 0.
- 설치(별도): iPhone 00008150-001E342C3C87801C devicectl 설치+실행(데이터 유지), Mac은 PID 27233 정상 종료→ditto /Applications→open(PID 32170).
- UI 런타임 미검증. 테스트/린트/Git 없음. 모델: Claude Sonnet 5.5, 사용량 수치 미제공.

## 검색 툴바 누수 수정 (date 실측 2026-10-17 20:31 KST)
- 원인: 임베드된 PhoneHard 루트의 FileBrowserSearchModifier가 isEnabled: true로 남아, 즐겨찾기로 전환 후에도 '현재 폴더 검색' 툴바가 유지됨.
- 수정: FileBrowserView.swift 한 줄 — isEnabled: !isEmbeddedSourceRoot (기존 embeddedAsSourcePage 플래그 재사용). 일반 FileBrowser 검색과 하위 폴더 push 화면은 그대로. 다른 파일 수정 없음.
- 빌드: iOS generic, Mac Catalyst 순차 모두 exit 0 + BUILD SUCCEEDED (/tmp/nasfinder-source-search-{ios,mac}-build.log). 이번엔 Mac wrapper도 exit 0.
- 버전 2.15.0/202610171956 유지, codesign --verify --deep --strict iOS/Mac/Applications 모두 0.
- 설치: iPhone 00008150-001E342C3C87801C devicectl install(데이터 유지)+launch(--terminate-existing), Mac은 PID 33956 SIGTERM 종료→ditto /Applications→open(PID 34780).
- 미확인: 실제 UI 동작(PhoneHard→즐겨찾기 전환 시 툴바) 미확인, 런타임 확인은 TM 소유. 테스트/린트/Git 실행 안 함.
