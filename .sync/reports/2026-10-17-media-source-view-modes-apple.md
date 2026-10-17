# 영상 만들기 선택 브라우저 보기 모드 (Apple 2.15.2 / 202610172050)

## 변경 파일
- NasFinder/Features/Browser/FileBrowserView.swift (선택 모드 `onPickMedia != nil` 에서만 동작)
- NasFinder.xcodeproj/project.pbxproj (전 앱·확장 2.15.2 / 202610172050)
- .sync/product-contract.yaml (editing.unified_media_selector)

## 원인과 수정
- 선택 모드에서는 우상단 툴바가 비어 있어 보기 모드를 바꿀 수 없었음 → 보기 메뉴(자세히/썸네일/포스터) 추가. 기존 레이아웃 enum(list/smallThumbnails/largeThumbnails)을 재사용, 오버플로우 제외. 기본 썸네일.
- 선택 전용 저장 키 `mediaSelectionBrowserLayoutStyle` 사용 → 폴더 이동·재진입에서 유지, 일반 브라우저 `fileBrowserLayoutStyle` 는 선택 모드에서 쓰기 없음(자동 오버플로우 전환·onAppear 보정도 선택 모드에서 건너뜀).
- 폰하드/NAS/즐겨찾기 폴더는 모두 같은 FileBrowserView 와 하위 폴더 전파(onPickMedia)를 쓰므로 라우팅 파일 수정 없음.
- 뒤로가기 추정 원인: 선택 브라우저의 뒤로가기 길게 누름/접근성 동작이 대시보드 복귀(goHome)에 연결되어 있었음. 선택 모드에서는 goHome 을 비활성화해 탭은 현재 폴더만 pop. 실기기 재현 원인은 TM 확인 필요(소스 추정).

## 빌드/설치
- iOS generic Debug: exit 0, BUILD SUCCEEDED (/tmp/nasfinder-media-modes-ios-build.log)
- Mac Catalyst: 첫 시도는 내 대기 루프 종료로 INTERRUPTED, 재실행 exit 0 BUILD SUCCEEDED (/tmp/nasfinder-media-modes-mac-build.log)
- codesign strict 통과(iOS/Mac), 앱 및 확장 4종 2.15.2/202610172050
- iPhone 00008150-001E342C3C87801C devicectl install+launch(데이터 유지), Mac PID 34780 SIGTERM → ditto /Applications → open
- 실제 UI 미확인(TM 확인 예정). 테스트·린트·Git 미실행.

## 보정 패스 (같은 2.15.2 / 202610172050)
- 실제 원인: 짧은 뒤로 탭은 `dismiss()`였고, 영상 만들기 출처 페이지의 중첩 NavigationStack 안에서 SwiftUI `dismiss()`가 한 단계가 아니라 상위 영상 만들기 흐름까지 닫아 대시보드로 나갔음(앞선 길게 누름 차단은 원인이 아니었음). 소스 분석 기반이며 실기기 재확인은 TM 몫.
- 수정(FileBrowserView.swift): 선택 브라우저(onPickMedia)에서는 뒤로 버튼(탭·접근성 동작)이 실제로 올라 있는 UINavigationController 에서 `popViewController`로 한 단계만 되돌림(`FileBrowserBackAnchor`). 스택이 루트뿐이면 기존 `dismiss()`. 일반 브라우저 동작은 그대로.
- 임베드된 PhoneHard/NAS 루트는 내비게이션 바가 없어 모드 버튼이 없었음 → 루트 상단에 기존 `selectionLayoutMenu`(자세히/썸네일/포스터)를 인라인 배치. 하위 폴더는 기존 헤더 메뉴 유지.
- 빌드: iOS generic exit 0 BUILD SUCCEEDED(/tmp/nasfinder-media-modes-corrective-ios-build.log), Mac Catalyst exit 0 BUILD SUCCEEDED(…corrective-mac-build.log), codesign strict 통과, iOS 앱·확장 4종 2.15.2/202610172050(Mac 산출물에는 appex 없음).
- 설치: iPhone 00008150-001E342C3C87801C devicectl install(데이터 유지, 2.15.2/202610172050 확인), Mac PID 42602 SIGTERM → ditto → open(새 PID 44849). 완료 21:09:54 KST. 실제 UI 미확인, 테스트·린트·Git 미실행.

## 2차 보정 패스: 내비게이션 소유권 (같은 2.15.2 / 202610172050)
- 1차 보정의 "원인"은 틀렸음(21:11 실기기에서 짧은 뒤로가 여전히 대시보드로 감). `FileBrowserBackAnchor`(UIKit popViewController)는 제거함.
- 구조적 원인(소스 기준): `LocalPhotoLibraryView`는 대시보드 NavigationStack에 `navigationDestination(isPresented:)`로 push된 화면이고, 출처 페이지의 `NavigationStack`은 그 안에 중첩됨. 선택 브라우저의 폴더 열기(`navigationDestination(item:)`), 경로 막대 `NavigationLink`, NAS 연결·즐겨찾기 폴더 `NavigationLink`가 모두 이 중첩 스택을 거쳐 실제로는 바깥 대시보드 스택에 쌓였음(그래서 Music이 탭·바구니 없이 전체 화면으로 열림). 뒤로는 그 바깥 스택을 pop/dismiss해서 영상 만들기 화면까지 빠져 대시보드로 감. 경로 막대 링크는 `onPickMedia`도 넘기지 않아 일반 브라우저가 열렸음.
- 수정: 선택 브라우저의 폴더 이동은 더 이상 NavigationStack push/dismiss를 쓰지 않음.
  - `MediaSelectionNavigation`(open/goBack 클로저)과 `MediaSelectionBrowser`(FileBrowserContainerView.swift): 출처 페이지가 `@State` 폴더 경로 배열을 직접 가짐. 폴더 열기 → 배열 추가, 뒤로 → 마지막 하나 제거, 경로 막대 → 해당 위치까지 잘라냄.
  - FileBrowserView: `embeddedAsSourcePage(_:)` 로 받은 경우 인라인 헤더(뒤로 · 제목 · 기존 `selectionLayoutMenu` 자세히/썸네일/포스터)를 루트와 모든 하위 폴더에 표시, 툴바 항목은 숨김, 폴더·경로 막대 이동을 클로저로 보냄. 일반 브라우저 경로(툴바 뒤로, 길게 눌러 대시보드, NavigationLink)는 원래 코드로 되돌림.
  - 폰하드(LocalPhotoLibraryView.swift): 루트 뒤로 없음. NAS(LocalPhotoLibrarySourcePages.swift): 연결 선택을 `@State`로 가지고 루트 뒤로 → 연결 목록. 즐겨찾기(FavoriteViews.swift): 연 폴더 즐겨찾기를 `@State`로 가지고 루트 뒤로 → 즐겨찾기 목록.
  - 바구니는 부모 `LocalPhotoLibraryView`의 `entries`에 있어 폴더 이동과 무관하게 유지됨. 보기 모드 저장 키 `mediaSelectionBrowserLayoutStyle` 그대로.
- 빌드: iOS generic exit 0 BUILD SUCCEEDED(/tmp/nasfinder-media-modes-nav-ios-build.log), Mac Catalyst exit 0 BUILD SUCCEEDED(/tmp/nasfinder-media-modes-nav-mac-build.log). 편집 파일 관련 경고 없음. codesign --deep --strict 통과(iOS, Mac, 교체 후 /Applications). iOS 앱·appex 4종 2.15.2/202610172050, Mac 산출물에는 PlugIns(appex) 없음.
- 설치: iPhone 00008150-001E342C3C87801C devicectl install(데이터 유지) + launch, 기기 앱 목록 2.15.2/202610172050 확인. Mac PID 44849 SIGTERM → ditto 교체 → open(새 PID 47780). 완료 21:20:24 KST.
- 실제 짧은 뒤로 동작은 미확인(TM 실기기 확인 필요). 테스트·린트·Git 미실행.
