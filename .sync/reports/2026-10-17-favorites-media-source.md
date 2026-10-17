# 영상 만들기 + 메뉴 즐겨찾기 (Apple, 2.14.2 / 202610171727)

- 담당: Claude Sonnet 5.5. 계약(.sync/product-contract.yaml, editing.unified_media_selector)을 먼저 갱신했고 `ruby -ryaml`로 유효성 확인.
- 수정 파일: Features/PhotoLibrary/LocalPhotoLibraryView.swift(폰하드와 NAS·네트워크 사이 "즐겨찾기" 항목, 기존 pickedFromBrowser 반환 경로 재사용), Features/Favorites/FavoriteViews.swift(MediaFavoritePickerView 추가), project.pbxproj(2.14.2/빌드번호).
- 동작: 기존 FavoriteStore 항목 표시. 폴더는 기존 미디어 선택 브라우저(FileBrowserView onPickMedia)를 해당 경로에서 열고, 사진·영상 파일은 같은 onPickMedia로 그 항목만 추가. 비미디어는 비활성+안내, 연결 없음은 비활성/오류 알림, 이동·삭제된 파일은 기존 가져오기 실패 알림(성공 표시 없음), 즐겨찾기가 없으면 안내 문구. 웹 북마크는 대상 아님.
- 보존: 원본·즐겨찾기 저장소 변경 없음. 바스켓·순서는 취소/전환 시 유지, 중복은 기존 연결+경로 식별 재사용(교차 제공자 해시 없음).
- 빌드/설치: Mac Catalyst arm64 및 generic iOS 모두 로그 "BUILD SUCCEEDED", 단 래퍼 종료코드는 둘 다 143(lockf 래퍼 신호로 추정, 원인 미확정). Mac /Applications 교체(구 PID 92225 정상 종료 → 신 PID 97033), iPhone 17 Pro 설치·실행 성공. 앱 버전 2.14.2 확인(Mac plist).
- 미확인: 실제 + 메뉴 화면(TM CUA), 실제 즐겨찾기 파일/폴더 추가 동작, 이동·삭제 항목 실기기 동작.
