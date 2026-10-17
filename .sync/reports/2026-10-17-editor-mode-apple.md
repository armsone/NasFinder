# 2026-10-17 편집 화면 내 예고편/뮤직비디오 전환 (Apple, 2.13.4 / 202610171649)

## 변경
- ConnectionListView: "영상 만들기"가 선택 팝업 없이 바로 미디어 선택(LocalPhotoLibraryView)을 연다. "보관한 편집" 유지.
- LocalPhotoLibraryView: 하단 "예고편 제작"/"뮤직비디오" 두 버튼을 "영상 편집" 하나로 통합(복사·미리보기·달력 동작 유지). 명시적 진입은 initialMode 유지.
- VideoTrailerView: 편집 설정 상단에 인라인 분할 선택기("예고편"|"뮤직비디오"). mode를 @State로 바꿔 저장 초안은 현재 모드로 보관·재개.
  - 뮤직비디오: 원본 전체·순서·BGM 유지(wholeMedia 계획). 예고편: 기존 하이라이트 계획.
  - 뮤직 시작 세션에서 예고편 복귀 시 model.analyzeHighlights로 실제 오디오 분석·사진 장면 길이 측정 후 추천 길이 재계산. 이미 분석된 세션은 재분석 없음.
  - 작업 중(isBusy)에는 선택기 비활성. 전환만으로 출력/초안 저장/원본 변경 없음; 새 영상은 기존 "만들기"에서만 생성. 저장 접미사는 실제 생성 모드 기준.
- product-contract.yaml 범위 갱신, 버전 2.13.4 / 202610171649 (앱+확장 전부).

## 빌드/설치 (KST 2026-10-17 16:51)
- Mac arm64: exit 0 (BUILD SUCCEEDED), iOS generic: exit 0. 로그 /tmp/editor-mode-{mac,ios}.log
- 산출물 버전 2.13.4/202610171649 (app + 4개 appex 확인)
- iPhone 설치 exit 0, 실행 exit 0
- Mac: /Applications/NasFinder.app를 2.13.4로 교체(ditto exit 0), 그러나 기존 프로세스(77941)가 정상 종료 요청을 거부(osascript -128 사용자 취소) → 강제 종료하지 않음. 재실행 미완료.
