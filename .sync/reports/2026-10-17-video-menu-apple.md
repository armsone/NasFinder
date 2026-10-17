# 영상 만들기 메뉴 통합 (Apple) — 2.13.3 / 202610171638 (KST 16:38 기준)

모델: claude-sonnet-5-5

## 변경
- ConnectionListView: 홈 "예고편 만들기"/"뮤직비디오" 두 항목 제거, 단일 "영상 만들기" 항목 추가(confirmationDialog, 제목 "영상 만들기", 선택지 "예고편"/"뮤직비디오"/취소). 선택 시 기존 LocalPhotoLibraryView(.trailer/.mediaMusic) 이동. 취소는 홈 변화 없음.
- "편집 중인 예고편" → "보관한 편집" (빈 상태 "보관한 편집이 없습니다", 접근성 힌트 갱신). 저장·재개·삭제·무제한 목록·폰하드 롱터치 유지.
- .sync/product-contract.yaml dashboard.four_area_navigation 문구 갱신, project.pbxproj 2.13.3/202610171638 전 타깃.

## 실행
- Mac Catalyst arm64 Debug build: BUILD SUCCEEDED
- generic iOS Debug build: exit 0, BUILD SUCCEEDED (순차 실행)
- Mac: 앱 종료 → rsync로 /Applications/NasFinder.app 교체(데이터 보존) → open. 설치본 2.13.3 / 202610171638.
- iPhone 74D48C61-...: devicectl install app 후 launch --terminate-existing 성공(설치 명령 종료코드는 파이프로 미기록; launch 성공 메시지 확인).

## 미해결
- 런타임 UI 동작(선택지 탭, 복귀 경로)은 직접 확인하지 않음 — TM CUA 확인 필요. 테스트 미실행.
