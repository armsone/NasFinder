# Android 2.30–2.34.2 (`95e575d`) → Apple (`2.29.0`) 포팅 격차 분석 및 구현 인계서

- **작성 기준일**: 2026-11-01 (KST)
- **Apple 현재 버전**: `2.29.0` (`CURRENT_PROJECT_VERSION = 202610301246`, `/Users/armsone/git/NasFinder`)
- **Android 기준 후보**: `2.34.2` (`95e575d`, `2.30`–`2.34.2` 누적 변경분)
- **작업 단계**: Android 최종 빌드 진행 중 **사전 계약(Contract) 갱신 및 정밀 소스 좌표·구현 계획 수립** (이번 단계에서는 Apple 앱 소스 미수정, 명령/빌드/테스트 미실행)
- **정본 계약 반영 위치**: `.sync/product-contract.yaml` (`files.shared_clipboard_cross_storage`, `editing.photo_fill_camera_plan`, `editing.storyboard_grid_and_captions`, `editing.simple_two_area_flow_and_draft_save`, `editing.preview_resize_and_output_naming`, `editing.responsive_fixed_scroll_workspace`)

---

## 0. 작업 트리 보존 및 비목표(Non-Goals) 경계

1. **보존 필수 기존 변경 파일 (절대 수정·스테이징·커밋·원복 금지)**:
   - `AGENTS.md`
   - `NasFinder/Features/Browser/FileBrowserFolderItemCount.swift`
   - `NasFinder/Features/Browser/FileBrowserPanelPopover.swift`
   - `NasFinder/Features/Browser/FileBrowserView.swift` (이번 준비 단계에서는 읽기 전용 조사만 수행; 실제 포팅 단계에서도 기존 수정분을 침범하지 않고 필요한 훅만 최소 연결)
   - 미추적(untracked) `.parity/`, `.sync/`, 디자인 리포트 파일 일체
2. **비목표 및 금지 사항**:
   - 대표님이 제거한 **확장 PhoneServer 신규 네트워크 기능**은 Apple에 절대 추가하지 않는다.
   - 이미 검증된 안전한 파일 전송/저장 엔진(`FileOperationCoordinator`, `RemoteDownloadCoordinator`, `SharedInboxStore`, `TrailerProjectStore`)을 새로 재작성하지 않고 그대로 조합·확장한다.
   - 외부 서드파티 의존성을 새로 추가하지 않는다(얼굴·피사체 검출은 기존 Apple `Vision` 프레임워크 사용).
   - 자막·편집 컨트롤에 요청되지 않은 부가 기능·설명 문구·중복 버튼을 늘리지 않는다.

---

## 1. 공통 파일 클립보드: 폰하드/로컬 ↔ 기존 네트워크 NAS 복사·이동 (무압축, 원본 보존)

### 1.1 Apple(`2.29.0`) 현재 구현 vs 부족한 점(Gap)

- **이미 구현되어 재사용할 안전 엔진**:
  - **클립보드 모델 및 동일 연결 내 복사·이동**: `NasFinder/Features/Browser/FileOperationCoordinator.swift:15-66` (`FileClipboardPayload`, `copyItems`, `stageMoveItems`) 및 `lines 205-282` (`paste(into:using:conflictPolicy:)`). 이동 실패·건너뜀 항목이 있으면 원본을 지우지 않고 미완료 항목만 클립보드에 남기는 보호 로직(`lines 258-267`)이 이미 구현되어 있다.
  - **NAS → 폰하드 무압축(No-ZIP) 파일·폴더 재귀 다운로드**: `NasFinder/Features/Browser/FileBrowserView.swift:694-699` 및 `lines 2985-3015` (`RemoteDownloadCoordinator`, `RemoteDownloadDestinationFlow`)에서 ZIP 압축 없이 하위 폴더 트리를 그대로 폰하드(`SharedInboxStore`)의 선택한 대상 폴더에 내려받는다.
  - **폰하드/로컬 → 기존 NAS 업로드(대상 연결·폴더 선택)**: `NasFinder/Features/Inbox/InboxUploadDestinationView.swift:1-300` 및 `FileOperationCoordinator.upload`(`lines 68-203`)에서 원하는 NAS와 대상 폴더를 골라 `.keepBoth` 충돌 정책으로 업로드한다.
  - **폰하드 내부 폴더 간 복사·이동**: `NasFinder/Features/Inbox/ReceivedFilesView.swift:140-145` (`InboxDestinationPickerView`).
- **실제 부족한 점 (Exact Gaps)**:
  1. **브라우저별 독립 인스턴스로 인한 클립보드 유실**: `FileBrowserView.swift:307`에서 `@StateObject private var operationCoordinator: FileOperationCoordinator`를 루트 진입마다 새로 생성한다. 따라서 폰하드에서 복사/이동을 누른 뒤 대시보드로 나와 NAS로 들어가거나(또는 그 반대로 이동하면) 클립보드가 비어 있다.
  2. **연결 간(Cross-Connection) 붙여넣기 명시적 차단**: `FileOperationCoordinator.swift:211-214`에서 `guard clipboard.connectionID == service.connection.id else { errorMessage = "다른 서버 간 복사·이동은 안전한 검증 전송 단계에서 지원할 예정입니다."; return }`로 막혀 있다.
  3. **로컬 폴더 → NAS 재귀 업로드 및 이동 시 항목별 원본 삭제 연동 부재**: `FileOperationCoordinator.upload`는 단일 레벨 `[URL]` 파일 업로드 위주이며, 폰하드 폴더를 통째로 NAS에 복사·이동할 때 하위 디렉터리 생성(`service.createFolder`) 후 파일 업로드가 모두 검증된 뒤에만 로컬 원본을 삭제하는 교차 저장소 이동(move) 파이프라인이 연결되어 있지 않다.

### 1.2 최소 수정 대상 파일·함수 좌표 및 구현 계획

| 파일 경로 | 대상 타입 / 함수 (줄 번호) | 최소 수정 내용 |
|---|---|---|
| `NasFinder/Features/Browser/FileOperationCoordinator.swift` | `FileClipboardPayload` (`15-26`), `FileOperationCoordinator` (`29-66`, `205-282`) | 1) `FileOperationCoordinator.shared`(또는 앱 전역 공유 클립보드 저장소)를 도입해 PhoneHard(`LocalInboxFileService.connectionID`)와 각 NAS 브라우저가 동일한 `clipboard`를 참조하도록 변경.<br>2) `FileClipboardPayload`에 원본 서비스/로컬 URL 해석 정보를 유지.<br>3) `paste(into:using:conflictPolicy:)`의 `clipboard.connectionID == service.connection.id` 차단을 해제하고, 원본·대상이 `(LocalInbox <-> Remote NAS)` 또는 `(Remote NAS A <-> Remote NAS B)`일 때 교차 전송 헬퍼로 분기. |
| `NasFinder/Features/Browser/FileOperationCoordinator.swift` | 신규 내부 헬퍼 `pasteAcrossEndpoints(...)` (`280` 부근) | - **PhoneHard/Local → NAS**: 선택 항목이 파일이면 `service.upload`, 폴더이면 로컬 하위 트리를 순회하며 `service.createFolder` + `service.upload` 수행(ZIP 없음). 충돌 시 `.keepBoth`(또는 원본 보존) 적용. `mode == .move`일 때는 해당 파일/하위 트리 전체의 원격 커밋이 확인된 항목만 `LocalInboxFileService` / `SharedInboxStore`에서 원본 삭제. 실패·충돌·취소 항목은 원본 보존 및 클립보드 잔류.<br>- **NAS → PhoneHard/Local**: 기존 무압축 다운로드 로직과 동일하게 원격 파일 `service.download` 및 원격 폴더 `service.list` 재귀 순회 → `SharedInboxStore` 대상 폴더에 저장. `mode == .move`일 때는 로컬 파일 크기·쓰기 검증이 끝난 항목만 원격 `service.deleteItems` 호출. |
| `NasFinder/Features/Inbox/InboxUploadDestinationView.swift` & `ReceivedFilesView.swift` | `InboxUploadDestinationView` (`1-220`), `ReceivedFilesView` (`130-165`) | 폰하드에서 복사·이동 선택 시 폰하드 내부 폴더뿐만 아니라 기존 등록된 NAS 연결·폴더를 골라 바로 붙여넣거나, 클립보드에 담아 NAS 브라우저에서 붙여넣을 수 있도록 전역 `FileOperationCoordinator`와 연동. |
| `NasFinder/Features/Browser/FileBrowserView.swift` | `init` (`295-315`) | *(사용자 수정분 보존 후 적용)* 기본 `operationCoordinator`를 공유 인스턴스(또는 공유 클립보드 바인딩)로 연결. |

---

## 2. 사진 자동 연출(FILL) 카메라 플랜 및 Apple 2.29 Vision 버그 수정

### 2.1 Apple(`2.29.0`) 현재 구현 vs 부족한 점(Gap)

- **원인 1 — Apple 2.29 Vision 검출 치명적 버그 (`VideoTrailerImageClip.swift:142-204`)**:
  - `analyzeSubjects(at:)`(`lines 145-158`)에서 `try handler.perform([faceRequest, saliencyRequest])`로 두 요청을 한 번에 실행하고, `guard let faces = faceRequest.results as? [VNFaceObservation], let saliencyObs = saliencyRequest.results as? [VNSaliencyImageObservation], !saliencyObs.isEmpty else { return .failure }`로 검사한다. 즉 **얼굴 검출이 성공해도 현저성(saliency) 결과가 비어 있거나 한쪽 요청만 오류를 던지면 무조건 `.failure`를 반환해 얼굴 데이터를 버린다.**
  - 또한 `lines 175-204`에서 검출된 박스 중 **단 하나라도** `isValidNormalizedBox`를 통과하지 못하면 즉시 `return .failure`로 전체 검출 결과를 폐기한다.
- **원인 2 — 가장자리 얼굴·피사체 또는 검출 실패 시 자동 FIT 전환 버그 (`VideoTrailerImageClip.swift:257-260, 295-389`)**:
  - 검출이 `.failure`이면 `fallbackToFit: true`를 반환해 `motionPlan = .fitted`(`line 295`)로 빠져 검은 레터박스/필러박스가 생긴다.
  - 가로/세로 크롭 범위 계산(`lines 305-306, 318-320, 374-375, 387-389`)에서 피사체 합집합이 뷰포트보다 넓거나 가장자리에 걸쳐 `uMin > uMax` 또는 `vMin > vMax`가 되면 즉시 `motionPlan = .fitted`로 자동 전환한다.
- **원인 3 — 초점 우선순위 및 모션 규칙 차이 (`VideoTrailerImageClip.swift:175-215, 290-416`)**:
  - 현재 Apple은 모든 얼굴과 모든 현저성 객체를 하나의 박스로 무조건 합집합(`union`) 처리하며, `duration <= 1.0`만 고정 크롭이고 `> 1.0`은 줌 없이 1축 직선 슬라이드만 수행한다.
  - 또한 실시간 미리보기(`TrailerWorkspacePreview`, `VideoTrailerView.swift:849-950`)는 렌더 전 정지 커버만 보여 주고 실제 사진 카메라 모션을 재생하지 않는다.

### 2.2 Android `2.34.2` (`95e575d`) 기준 목표 동작 및 수정 좌표

| 파일 경로 | 대상 타입 / 함수 (줄 번호) | 최소 수정 내용 |
|---|---|---|
| `NasFinder/Features/Preview/VideoTrailerImageClip.swift` | `SubjectAnalysisResult` (`53-57`), `analyzeSubjects(at:)` (`142-218`), `subjectBounds(for:)` (`247-272`) | 1) **부분 성공 보존**: `VNDetectFaceRectanglesRequest`와 `VNGenerateObjectnessBasedSaliencyImageRequest`를 독립 `do/try`로 실행하고, 개별 박스는 `.filter { isValidNormalizedBox($0) }`로 걸러 유효한 얼굴이나 피사체 중 하나라도 있으면 유지.<br>2) **초점 우선순위 3단계**:<br>   - **1순위 (얼굴/머리 주 군집)**: 유효한 얼굴 박스가 있으면 머리(정수리·턱 여유분)까지 확장한 뒤 주요 얼굴 군집(primary cluster)을 계산하고 현저성 박스는 섞지 않음.<br>   - **2순위 (현저성/주요 피사체)**: 얼굴이 없을 때만 `salientObjects` 중 대표 객체/군집 사용.<br>   - **3순위 (결정적 랜덤 합법 초점)**: 둘 다 없거나 분석이 실패해도 절대 `.fitted`로 빠지지 않고, 사진 안정 식별자(seed) 기반의 합법 크롭 영역 내 결정적 랜덤 초점을 반환. |
| `NasFinder/Features/Preview/VideoTrailerImageClip.swift` | `MotionPlan` (`22-36`), `makeMotionPlan(...)` (`290-416`), `drawRect(...)` (`418-451`) | 1) **항상 FILL 보장 (No Auto-FIT)**: `framing?.fitsFrame == true`인 명시적 전체 보기(FIT)일 때만 `.fitted`를 사용하고, 자동 모드에서는 `uMin > uMax` / `vMin > vMax`여도 군집 중심을 합법 `[0, 1]` FILL 크롭 범위로 클램프해 확대·패닝 전 구간에서 출력 화면을 100% 덮음. 수동 `framing`(`offsetX`, `offsetY`) 오버라이드는 그대로 보존.<br>2) **짧은 장면 (`duration <= 3.0s`)**: 독립 패닝 없이 고정 초점(fixed focus) 유지, 장면 길이에 비례한 약한 줌인(zoom-in) 또는 줌아웃(zoom-out)을 사진 고유 시드로 결정적 랜덤 선택(미리보기·내보내기·재열기 모두 동일).<br>3) **긴 장면 (`duration > 3.0s`)**: 시간·속도 상한이 적용된 카메라형 패닝 + 줌(급격한 단거리 패닝 금지, 부드러운 이징 적용). |
| `NasFinder/Features/Preview/VideoTrailerView.swift` | `TrailerWorkspacePreview` (`849-950`), `VideoTrailerModel.renderSceneGroup` (`2900-2940`) | `VideoTrailerImageClip`의 카메라 플랜 계산 함수를 `public`/`internal` 순수 함수로 노출하여, 내보내기(`AVAssetWriter`)뿐만 아니라 편집 화면 실시간 미리보기(`TrailerWorkspacePreview`)에서도 동일한 사진 카메라 모션(초점·줌·패닝)을 그대로 재현. |

---

## 3. 스토리보드 격자(4열/2열), 다중 선택·임의 1기준 위치 이동(`420 -> 3`), 자막 보존

### 3.1 Apple(`2.29.0`) 현재 구현 vs 부족한 점(Gap)

- **현재 구현**:
  - `NasFinder/Features/Video/TrailerSceneEditing.swift:423-474` (`TrailerSceneStrip`) 및 `VideoTrailerView.swift:1592-1600` (`sourceOrderSection`) 모두 **1줄 가로 스크롤(`ScrollView(.horizontal) { LazyHStack }`)** 구조다.
  - `TrailerSceneEditing.swift:689-726` (`TrailerSceneInspector.arrangement`)은 단일 장면만 선택해 `앞으로(-1)`, `뒤로(+1)`, `복제`, `포함/제외`, `삭제`만 가능하다.
  - `TrailerCustomScene`(`TrailerSceneEditing.swift:114-184`) 및 `TrailerProjectRecord`(`TrailerProjectStore.swift:26-98`)에 장면별/일괄 자막(Caption) 모델 및 편집 UI가 아직 연결되어 있지 않다.
- **부족한 점 (Exact Gaps)**:
  1. **1열 가로 줄 → 반응형 스토리보드 격자 교체**: 태블릿/넓은 패인은 **4열 격자**, 폰/좁은 화면은 **2열 보드 → 장면 탭 시 상세 진입 → 뒤로가기 시 보드 스크롤 위치 유지**.
  2. **다중 선택 및 임의 1-based 번호 이동(`420 -> 3`)**: 여러 장면을 체크/선택해 원하는 1기준 번호(예: `420`번 장면을 `3`번 위치로)로 한 번에 이동하는 기능과 레이블이 붙은 `복제`·`삭제` 액션 바.
  3. **기존 지원 자막(장면/일괄 스타일·문구·위치·색상) 및 Undo/Redo·초안 영속화**: 기능 과잉 없이 Android `2.34.2`와 동일한 범위의 장면별 자막·일괄 스타일(문구, 위치, 색상, 크기/스타일)을 편집·렌더·저장·실행취소 스택에 반영.

### 3.2 최소 수정 대상 파일·함수 좌표 및 구현 계획

| 파일 경로 | 대상 타입 / 함수 (줄 번호) | 최소 수정 내용 |
|---|---|---|
| `NasFinder/Features/Video/TrailerSceneEditing.swift` | `TrailerCustomScene` (`114-184`), `TrailerSceneStrip` (`423-474`) → `TrailerStoryboardGrid`로 교체, `TrailerSceneInspector` (`476-727`) | 1) `TrailerCustomScene`에 자막 속성(`captionText`, `captionStyle`/`position`/`color` 등 기존 지원 필드) 추가(Codable 하위 호환 유지).<br>2) 1열 `TrailerSceneStrip`을 `LazyVGrid` 기반 스토리보드 격자(태블릿/넓은 영역 4열, 폰 보드 2열)로 교체하고 `ScrollViewReader` / `.scrollPosition(id:)`로 폰 상세 왕복 및 회전 시 스크롤 위치 보존.<br>3) 다중 선택(`selectedSceneIDs: Set<UUID>`) 및 **1-based 목표 위치 이동(`moveScenes(ids:toOneBasedPosition:)`)** 함수 구현(예: 420번을 3번으로 이동 시 상대 순서 보존하여 인덱스 2에 삽입).<br>4) 레이블이 명시된 다중/단일 `위치 이동`, `복제`, `삭제` 버튼과 자막 편집 탭(장면 문구 + 일괄 스타일/위치/색상, 적용/취소 상태 포함) 구성. |
| `NasFinder/Features/Preview/VideoTrailerView.swift` | `EditorSnapshot` (`306-315`), `pushUndo`/`undo`/`redo` (`638-658`), `sourceOrderSection` (`1574-1645`), 자막 오버레이 렌더링 (`2900-3100`) | 1) `EditorSnapshot`에 다중 선택·자막·일괄 자막 스타일을 포함시켜 기존 Undo/Redo 및 `TrailerProjectStore` 초안 영속화 그대로 유지.<br>2) 미리보기 및 `AVAssetWriter` 프레임 합성 시 설정된 자막을 동일하게 렌더링. |
| `NasFinder/Features/Video/TrailerProjectStore.swift` | `TrailerProjectRecord` (`26-98`) | 자막 및 일괄 자막 스타일 필드를 `decodeIfPresent`로 안전하게 직렬화/역직렬화해 기존 저장된 편집본과의 호환성 보장. |

---

## 4. 단순 2영역 흐름(EDIT + VIDEO MAKE), 명시적 편집본 저장, 렌더 스냅샷 정지장면, 미적용 자막 가드

### 4.1 Apple(`2.29.0`) 현재 구현 vs 부족한 점(Gap)

- **현재 구현**:
  - `VideoTrailerView.swift:1406-1450` (`editorLayout`)에서 편집 옵션, 미리보기, 영상 만들기가 한 화면에 섞여 있고, 편집할 때마다 1.2초 디바운스 자동저장(`scheduleSave`, `lines 660-669`)만 돌며 상단 `projectBar`(`lines 1554-1572`)에 작은 상태 문구만 찍힌다.
  - `TrailerProjectStore.swift:215-318, 511-549`에는 이미 원자적 저장(`.bak` 백업 복구)과 실패 시 `.failed(message)`를 남기는 내구성 저장 엔진이 완비되어 있다.
  - 렌더링 중에는 이전 출력이나 일반 진행 표시만 보이며, 편집을 바꿔도 기존 `model.outputURL`과 `model.isSaved`가 그대로 남아 있을 수 있다.
- **부족한 점 (Exact Gaps)**:
  1. **`편집(EDIT)` + `영상 만들기(VIDEO MAKE)` 2영역 분리**:
     - **EDIT 영역**: 렌더링과 무관하게 언제든 편집본을 저장할 수 있는 **명시적 편집본 저장 버튼**을 두고, `TrailerProjectStore`의 내구성 저장/실패 보호를 연결해 **그 기존 버튼 자체에 실제 상태(`저장` / `저장 중…` / `저장됨` / `저장 실패`)를 표시**한다(부가 설명 문구나 여분 버튼 추가 금지).
     - **VIDEO MAKE 영역**: 오직 **현재 편집 상태의 출력만** 다룬다. `영상 만들기` 실행 → **렌더 시작 스냅샷에서 만든 무음 정지장면(silent still scene)**과 함께 진행률/취소 표시 → 완료 및 검증 후 **전체 플레이어(자동재생 금지)** → **폰하드에 실제 저장(`폰하드에 저장`)을 주 행동**으로, `공유`·`컬렉션에 추가`를 보조 행동으로 배치.
  2. **편집 시 이전 출력 즉시 무효화**: 장면 순서, 길이, 음악, 프레이밍, 자막 등 어떤 편집이든 발생하면 즉시 이전 렌더 결과(`outputURL = nil`, `isSaved = false`)를 무효화해 옛 영상이 자동 재생되거나 현재 완성본/저장본처럼 보이는 거짓 상태를 차단.
  3. **미적용 자막(Unapplied Caption) 가드**: 자막 입력창에 아직 적용하지 않은 변경이 있을 때 단계 전환(EDIT → VIDEO MAKE, 다른 장면 이동, 닫기)이나 저장을 누르면 **절대 임의로 자동 적용하거나 버리지 않고**, `적용` 또는 `취소(변경 취소)`를 선택하는 확인 가드를 띄운다.

### 4.2 최소 수정 대상 파일·함수 좌표 및 구현 계획

| 파일 경로 | 대상 타입 / 함수 (줄 번호) | 최소 수정 내용 |
|---|---|---|
| `NasFinder/Features/Preview/VideoTrailerView.swift` | `VideoTrailerSettings` (`265-845`, `1380-1770`), `VideoTrailerModel` (`2420-2620`) | 1) 상단/작업 영역을 `편집(EDIT)`과 `영상 만들기(VIDEO MAKE)` 두 영역으로 분리.<br>2) 기존 저장 버튼을 명시적 편집본 저장 액션(`saveProjectNow()`)에 연결하고 `projectStore.saveState(for: projectID)`에 따라 버튼 타이틀/상태를 직접 갱신.<br>3) 편집 변경(`recordSnapshot` / 장면·자막·옵션 변경) 시 `model.invalidateCurrentOutput()`을 호출해 `outputURL = nil`, `isSaved = false`로 즉시 초기화.<br>4) `VideoTrailerModel.generate` 시작 시 첫 유효 장면 스냅샷을 무음 정지 이미지(`renderSnapshotStill: UIImage?`)로 캡처해 렌더 진행 중 표시하고, 완료 후 자동재생 없이 플레이어만 노출.<br>5) 미적용 자막 초안(`hasUnappliedCaptionChanges`)이 있을 때 단계 이동·저장·닫기 시 확인 알림(`자막 변경을 적용할까요?` — `적용` / `입력 취소` / `계속 편집`)을 띄워 보호. |
| `NasFinder/Features/Video/TrailerProjectStore.swift` | `saveState(for:)` (`215-245`), `enqueueSave` (`250-318`) | 기존 `.bak` 원자적 저장 및 `.failed` 상태 가드를 그대로 유지하며 명시적 즉시 저장 호출(`saveNow`) 진입점 제공. |

---

## 5. 미리보기 하단 드래그 그립 리사이즈, 전체화면 정확 프레임 일시정지, 저장 파일명·기본 제목 규격, 편집본 소형 썸네일

### 5.1 Apple(`2.29.0`) 현재 구현 vs 부족한 점(Gap)

1. **미리보기 리사이즈**:
   - 현재 `VideoTrailerView.swift:1417-1418`은 `.frame(maxHeight: ui(isWide ? 380 : 260))` 고정이며 조절 수단이 없다.
   - **수정**: 미리보기 바로 아래에 **얇은 하단 드래그 그립(thin bottom drag grip) 하나만** 추가한다(슬라이더, 기본값 복원 버튼, 텍스트 라벨, `%` 표시 일체 금지). 드래그 높이는 현재 가용 뷰포트 및 키보드 높이에 맞춰 동적으로 상·하한을 클램프한다.
2. **전체화면 전환 시 정확한 프레임 인라인 일시정지 (자동 재개·이중 오디오 금지)**:
   - 현재 `VideoTrailerView.swift:849-950` (`TrailerWorkspacePreview`) 및 `RemotePreviewView.swift`는 전체화면 토글 시 재생 상태와 오디오 트랙이 겹치거나 자동 재생될 위험이 있다.
   - **수정**: 전체화면 진입·복귀 시 현재 재생 시각(`CMTime`)을 정확히 유지한 채 **즉시 일시정지(pause)**하고, 인라인 플레이어와 전체화면 플레이어가 동시에 소리를 내거나 자동으로 재생을 재개하지 않도록 단일 플레이어/정지 상태를 강제한다.
3. **저장 파일명 및 새 편집본 기본 제목 (`yyMMdd-HHmmss-예고편.mp4` / `-뮤비.mp4`)**:
   - 현재 `VideoTrailerView.swift:471-472, 794-806, 4008-4011`은 `<첫파일명 또는 모음-N개영상>-예고편.mp4` 또는 `-음악.mp4`로 저장하며, 새 편집본 기본 제목(`lines 369-372`)도 `<첫파일명> 외 N개`로 만든다.
   - **수정**:
     - 저장 파일명: 로컬 시각 기준 `yyMMdd-HHmmss-예고편.mp4` (`mode == .trailer`) 또는 `yyMMdd-HHmmss-뮤비.mp4` (`mode == .mediaMusic`).
     - 새로 저장되는 편집본의 기본 제목도 동일하게 확장자를 뺀 `yyMMdd-HHmmss-예고편` 또는 `yyMMdd-HHmmss-뮤비`로 파생한다.
4. **편집본 목록 작은 썸네일 (Draft List Small Thumbnails)**:
   - 현재 `VideoTrailerView.swift:1805` (`TrailerDraftRow`)는 `width: 76, height: 54` 크기의 썸네일을 사용한다.
   - **수정**: 편집본 목록(`TrailerDraftManagerView` / `TrailerDraftRow`)의 행 썸네일을 한눈에 많은 항목이 보이도록 소형 썸네일(예: `48x36pt` 또는 `44x44pt` 컴팩트 규격)로 축소한다.

### 5.2 최소 수정 대상 파일·함수 좌표

| 파일 경로 | 대상 타입 / 함수 (줄 번호) | 최소 수정 내용 |
|---|---|---|
| `NasFinder/Features/Preview/VideoTrailerView.swift` | `TrailerWorkspacePreview` (`849-950`), `editorLayout` (`1406-1478`) | 1) 미리보기 하단에 얇은 캡슐 핸들(`DragGesture`)만 배치해 `previewHeight`를 동적 뷰포트/키보드 범위 내에서 조절.<br>2) `isPreviewFullscreen` 전환 시 플레이어 `pause()` 및 정확한 `CMTime` 동기화, 자동 재생 차단. |
| `NasFinder/Features/Preview/VideoTrailerView.swift` | `defaultProjectTitle` (`369-372`), `save` 호출부 (`471-472`, `794-806`), `VideoTrailerModel.save` (`4004-4035`) | `DateFormatter` (`yyMMdd-HHmmss`, `Locale(identifier: "en_US_POSIX")`, 현재 타임존) 헬퍼를 통해 `.trailer`는 `yyMMdd-HHmmss-예고편.mp4`, `.mediaMusic`은 `yyMMdd-HHmmss-뮤비.mp4`로 파일명을 생성하고, 새 편집본 기본 제목도 `yyMMdd-HHmmss-예고편` / `yyMMdd-HHmmss-뮤비`로 통일. |
| `NasFinder/Features/Preview/VideoTrailerView.swift` | `TrailerDraftRow` (`1795-1835`) | 편집본 목록 행의 썸네일 크기를 `76x54`에서 소형(`48x36` 또는 `44x34`)으로 축소하고 여백을 정리. |

---

## 6. 반응형 FIXED vs SCROLL 레이아웃, 회전 상태 보존, 안전영역·키보드, Mac 2.5x 예외 및 아이콘·터치 규격

### 6.1 Apple(`2.29.0`) 현재 구현 vs 부족한 점(Gap)

- **현재 구현**:
  - `VideoTrailerView.swift:481`에 `.statusBarHidden(true)`가 걸려 있어 iPhone/iPad에서 상단 상태바를 숨기거나 노치/카메라홀 안전영역과 충돌할 수 있다.
  - `VideoTrailerView.swift:1406-1450`은 `< 640pt`에서 전체 화면 하나를 통째로 `ScrollView`에 넣어 미리보기까지 스크롤되어 사라지며, 태블릿 세로/가로별 1:1 분할 및 독립 스크롤 구조가 없다.
  - `TrailerWorkspace.swift:138-159`는 데스크톱형 4단 레일(`.wide`, `.medium`, `.compact`, `.phone`) 구조로 되어 있다.
- **Android `2.34.2` (`95e575d`) 기준 목표 반응형 구조**:
  1. **태블릿 세로 (Tablet Portrait)**:
     - **상단(FIXED)**: 적당한 크기의 미리보기 고정 + 하단 얇은 드래그 그립.
     - **하단 1:1 좌우 분할**:
       - **좌측(SCROLL)**: 4열 스토리보드 격자 독립 스크롤.
       - **우측(FIXED 탭 + SCROLL 필드)**: 상단 인스펙터/편집 탭 바 고정 + 하단 편집 필드 독립 스크롤.
  2. **태블릿 가로 (Tablet Landscape)**:
     - **좌우 1:1 분할**:
       - **좌측(SCROLL)**: 4열 스토리보드 격자 독립 스크롤.
       - **우측**: 상단 작은 고정 미리보기(하단 얇은 그립 포함) + 중간 고정 탭 바 + 하단 편집 필드 독립 스크롤.
  3. **폰 (Phone / Narrow)**:
     - 기본 화면은 **2열 스토리보드 보드(SCROLL)** (+ 상단 고정 요약/미리보기 또는 영역 전환).
     - 장면을 탭하면 **상세 편집 화면(상단 고정 미리보기 + 고정 탭 바 + 하단 독립 스크롤 필드)**으로 이동하고, 뒤로가기 시 2열 보드의 이전 스크롤 위치를 그대로 복원.
  4. **회전 보존·안전영역·키보드**:
     - 세로 ↔ 가로 회전 시 선택된 장면(`selectedSceneIDs`), 작성 중인 자막 초안, 미리보기 리사이즈 높이, 보드·인스펙터 스크롤 위치를 모두 보존.
     - `.statusBarHidden(true)`를 제거해 상태바와 안전영역(노치/다이나믹 아일랜드/카메라홀)을 침범하지 않도록 유지.
     - 키보드가 올라올 때 고정 미리보기가 자동으로 줄어들거나 스크롤 영역이 패딩을 확보해 자막·위치 번호 입력 폼이 가려지지 않게 보장.
  5. **Mac 네이티브 창 및 액션 아이콘 규격**:
     - Mac은 기존 앱 사이드바(`usesShellSidebar`), 키보드/마우스 단축키, 프로젝트 규칙의 **`MacUIScale` 2.5배 기본 배율 예외**를 그대로 유지하되, 고정 캔버스를 단순 확대하지 않고 실제 Mac 창 크기에 맞춰 위 1:1 반응형 패인을 재배치한다.
     - 액션 아이콘은 시각 크기 **24pt**(툴바 **28pt**)를 기준으로 하고, 터치/클릭 히트 영역은 Apple 접근성 최소 **44pt 이상**(앱 자체 패리티 컨트롤은 **48pt**)을 확보한다. 기존 테마(`PorcelainMetrics` / `SkyBreezeTheme`)와 아이콘 스타일은 그대로 유지한다.

### 6.2 최소 수정 대상 파일·함수 좌표

| 파일 경로 | 대상 타입 / 함수 (줄 번호) | 최소 수정 내용 |
|---|---|---|
| `NasFinder/Features/Video/TrailerWorkspace.swift` | `TrailerWorkspace` (`21-136`), `TrailerWorkspaceTier` (`138-159`) | iPad/Mac/iPhone 크기와 가로·세로 비율(`size.width`, `size.height`, `usesShellSidebar`)에 따라 `tabletPortrait`, `tabletLandscape`, `phoneBoardAndDetail`, `macResponsive` 레이아웃 모드를 판별하고, 회전 시에도 동일한 `@State`가 유지되도록 상위 상태 보유. |
| `NasFinder/Features/Preview/VideoTrailerView.swift` | `body` (`475-490`), `editorLayout` (`1406-1478`) | 1) `line 481`의 `.statusBarHidden(true)` 제거 및 안전영역 준수.<br>2) `editorLayout`을 모드별 FIXED vs SCROLL 구조(태블릿 세로 상단 고정 프리뷰 + 하단 1:1 좌 4열 보드/우 고정탭+스크롤필드, 태블릿 가로 1:1 좌 4열 보드/우 상단 프리뷰+고정탭+스크롤필드, 폰 2열 보드 ↔ 상세)로 재구성.<br>3) 액션 버튼들의 아이콘 시각 크기(`ui(24)` / 툴바 `ui(28)`) 및 최소 히트 타겟(`minWidth: ui(44), minHeight: ui(44)` 또는 `ui(48)`) 일괄 정렬. |

---

## 7. 결정적 테스트 픽스처(Fixtures) 및 재사용 가능한 기존 테스트

Apple 포팅 구현 후 최종 단계에서 재사용·확장할 기존 단위 테스트(`NasFinderTests` 타겟)는 다음과 같다:

1. **파일 복사·이동·충돌 보존 테스트**:
   - `NasFinderTests/FileOperationSafetyTests.swift` (교차 연결 `PhoneHard <-> NAS` 복사·이동 시 실패/충돌 항목의 원본 보존 및 클립보드 잔류 검증 케이스 추가)
2. **사진 카메라 플랜·Vision 부분 성공·항상 FILL 테스트**:
   - `NasFinderTests/VideoTrailerImageClipTests.swift` (또는 `VideoTrailerPlanTests.swift` / 관련 미디어 테스트 파일):
     - 얼굴만 검출되고 현저성이 빈 배열일 때 얼굴 군집 초점이 유지되는지 검증.
     - 얼굴·피사체가 이미지 가장자리(`uMin > uMax`)에 있을 때 `.fitted`로 빠지지 않고 FILL 스케일(`>= fillScale`)을 유지하는지 검증.
     - `duration <= 3.0s`일 때 고정 초점(`startCenter == endCenter`) + 결정적 약한 줌인/줌아웃이 적용되고 같은 사진 식별자에서 항상 동일한 플랜이 나오는지 검증.
     - `duration > 3.0s`일 때 속도 상한이 적용된 카메라 패닝+줌이 생성되는지 검증.
3. **스토리보드 다중 선택·1-based 위치 이동·파일명 포맷 테스트**:
   - 장면 배열 `[1...500]`에서 `420`번(1-based) 장면을 `3`번 위치로 이동했을 때 정확히 3번째(0-based index `2`)에 배치되고 나머지 순서가 보존되는지 검증.
   - `yyMMdd-HHmmss-예고편.mp4` 및 `yyMMdd-HHmmss-뮤비.mp4` 파일명·기본 제목 생성기를 고정 시각(`Date(timeIntervalSince1970:)`) 픽스처로 결정적 검증.

---

## 8. 빌드·설치·릴리즈 진입점 (파일 도구로 확인된 프로젝트 규격)

> **주의**: 이번 준비 작업에서는 아래 명령을 실행하지 않았으며, 추후 구현 단계 및 최종 실기기 설치 단계에서 프로젝트 규칙(`GEMINI.md` 및 `/Users/armsone/git/AGENTS.md`)에 따라 사용한다.

1. **작업 전·후 저장소 스냅샷 가드 (`Makefile:4-5`, `GEMINI.md` 규칙 1–2)**:
   - Git 보존·복구, 실기기 설치, worktree 전환, 배포 직전/직후에만 실행:
     ```bash
     ./scripts/repository_guard.sh status
     ```
2. **SwiftPM 로컬 패키지 캐시 고정 래퍼 (`scripts/xcodebuild_project.sh:1-49`, `GEMINI.md` 규칙 17–19)**:
   - 모든 `xcodebuild` 호출은 `.build/xcode-source-packages` 및 `.build/xcode-package-cache`를 잠금(`lockf`)으로 직렬화해 재사용하는 래퍼를 통과한다:
     ```bash
     ./scripts/xcodebuild_project.sh -project NasFinder.xcodeproj -scheme NasFinder ...
     ```
   - `Package.resolved`가 바뀌었거나 `.build` 로컬 캐시가 없을 때만 `make packages`를 단독 실행한다.
3. **검증된 실기기 설치 진입점 (`Makefile:12-13`, `scripts/install_verified_device.sh:1-166`, `GEMINI.md` 규칙 3–4, 10–14)**:
   - `xcodebuild`와 `devicectl`로 직접 설치하지 않고, 반드시 변경 범위에 맞는 관련 테스트(`TEST_ONLY`) 또는 전체 테스트(`FULL_TESTS=1`)를 통과한 동일 커밋 산출물을 설치·실행하고 아이콘 번들(`AppIcon` 및 보조 아이콘 5종)까지 자동 검증하는 아래 진입점을 사용한다:
     ```bash
     make install-verified DEVICE_ID=<실기기-UDID> TEST_ONLY=NasFinderTests/<관련테스트클래스>
     ```
   - 전체 실기기 테스트가 필요한 정식 릴리즈 후보 단계에서만:
     ```bash
     make install-verified DEVICE_ID=<실기기-UDID> FULL_TESTS=1
     ```
4. **버전 및 타겟 구성 (`NasFinder.xcodeproj/project.pbxproj:716, 897, 945`)**:
   - 현재 Apple `MARKETING_VERSION = 2.29.0`, `CURRENT_PROJECT_VERSION = 202610301246`.
   - 메인 앱(`NasFinder`) 및 확장 타겟(`NasFinderFileProvider`, `NasFinderShare`, `NasFinderWidget`, `NasFinderDocumentPicker`), 테스트 타겟(`NasFinderTests`, `NasFinderUITests`)이 동일한 `MARKETING_VERSION`과 `CURRENT_PROJECT_VERSION`을 공유하므로, 사용자에게 보이는 앱 결과가 바뀌는 최종 설치/릴리즈 전에 모든 타겟의 버전을 일괄 갱신한다.

---

## 9. 다음 구현 단계(Next Step) 실행 순서

Android `2.34.2` (`95e575d`) 최종 빌드가 준비되고 Apple 소스 구현 승인이 시작되면 다음 순서로 한 번에 구현 후 최종 단계에서 묶음 검증한다:

1. **Step 1 (Item 2)**: `VideoTrailerImageClip.swift`의 Vision 부분 성공 보존, 얼굴/머리 군집 → 현저성 → 결정적 랜덤 초점, 자동 FIT 제거(항상 FILL), `<=3s` 고정초점 약한 줌 / `>3s` 속도제한 패닝+줌 구현 및 `TrailerWorkspacePreview` 실시간 카메라 모션 연동.
2. **Step 2 (Item 3 & 4 & 5)**: `TrailerSceneEditing.swift`, `VideoTrailerView.swift`, `TrailerProjectStore.swift`에서 4열/2열 스토리보드 격자, 다중 선택 및 1-based 위치 이동(`420 -> 3`), 자막 편집/렌더, `편집(EDIT)` + `영상 만들기(VIDEO MAKE)` 2영역 분리, 기존 저장 버튼 내구성 상태 직결, 렌더 스냅샷 무음 정지장면, 미적용 자막 가드, 하단 얇은 드래그 그립 리사이즈, 전체화면 정지 동기화, `yyMMdd-HHmmss-예고편.mp4`/`-뮤비.mp4` 파일명·기본 제목, 편집본 목록 소형 썸네일 반영.
3. **Step 3 (Item 6)**: `TrailerWorkspace.swift` 및 `VideoTrailerView.swift`에 태블릿 세로/가로 1:1 FIXED vs SCROLL 분할, 폰 2열 보드→상세 스크롤 보존, 회전 상태 보존, `.statusBarHidden(true)` 제거 및 키보드 폼 대응, Mac 2.5x 반응형 창 및 `24/28pt` 아이콘 + `44/48pt` 히트 타겟 마감.
4. **Step 4 (Item 1)**: `FileOperationCoordinator.swift`, `InboxUploadDestinationView.swift`, `ReceivedFilesView.swift`(및 보존된 `FileBrowserView.swift` 최소 연결)에서 전역 공유 클립보드 및 `PhoneHard/local <-> 기존 NAS` 무압축 복사·이동·원본 보존 연결.
5. **Step 5 (최종 검증 및 설치)**: 관련 단위 테스트를 묶어 `./scripts/xcodebuild_project.sh` 또는 `make install-verified`로 한 번에 검증·설치.

---

## 10. 구현 진행 현황 (2026-11-01 연속 작업, 메인 편집 흐름 연결)

> **검증 상태**: 이번 단계도 빌드·테스트·실행을 하지 않았다(지시상 금지). 아래 "완료"는 소스 수정 완료를 뜻하며 컴파일·런타임 검증은 아직 없다. Git 커밋·스테이징 없음. 사용자 수정 파일(`AGENTS.md`, Browser 3개 파일)은 건드리지 않았다.

### 10.1 이전 실행(run 0e7d3850)에서 이미 반영되어 보존한 것
- 자막 모델·렌더: `TrailerCaption`(`TrailerProjectStore.swift`), `VideoTrailerScene.caption`, `TrailerPreparedPlan.manual`의 빈 문구 제외, 내보내기 `captionAnimationTool`, 미리보기 `CaptionOverlayView`(`referenceHeight` 360 공통 기준).
- `TrailerStoryboardGrid`(4열/2열, 다중 선택, `TrailerSceneEditor.moveScenes(ids:toOneBasedPosition:)` 420→3, `duplicateScenes`, `deleteScenes`).
- 사진 FILL 카메라 플랜(`VideoTrailerImageClip`) 및 미리보기 공유, `TrailerNaming`(yyMMdd-HHmmss-예고편/뮤비). 이번 단계에서 다시 쓰지 않았다.

### 10.2 이번 단계에서 완료한 함수·구조 (정확한 위치)
- **두 영역 편집기 (`VideoTrailerView.swift`)**
  - `VideoTrailerView`: `@State area: TrailerEditorArea`(편집 / 영상 만들기)를 실제 머리글 세그먼트에 연결. 영역 전환은 `runGuarded`를 거친다.
  - `VideoTrailerSettings.projectBar`: 고정 머리글 = 프로젝트 이름 + 되돌리기/다시 실행(아이콘 24, 히트 44) + **편집본 저장 버튼 하나**(`저장` / `저장 중…` / `저장됨` / `저장 실패`, 실패 시 같은 버튼이 다시 저장) + 영역 세그먼트. 예전 상태 문구·"다시 저장" 별도 버튼은 제거.
  - `VideoTrailerView.saveDraftNow()`: 자동 저장 대기를 취소하고 `TrailerProjectStore.saveNow`를 끝까지 기다림(렌더와 무관). 성공 시 `savedChangeKey` 기록 → 지금 상태와 같을 때만 "저장됨". 자동 저장(`scheduleSave`, 1.2초)과 나갈 때 즉시 저장, `.bak` 복구는 그대로 유지.
  - `VideoTrailerView.closeAfterSaving(thenOpen:)`: 닫기·레일 나가기는 저장 성공을 확인한 뒤에만 `requestExit()`. 실패하면 "편집본을 저장하지 못했습니다" 알림(다시 저장 / 저장하지 않고 닫기 / 계속 편집).
  - `.statusBarHidden(true)` 제거.
- **미적용 자막 가드**
  - `TrailerCaptionDraft`(`TrailerSceneEditing.swift`, `@MainActor ObservableObject`): 자막 입력 초안을 편집기(부모)가 소유 → 회전·영역 전환·폰 상세 왕복에도 유지. `load`, `caption`, `apply(to:)`, `discard(scenes:)`.
  - `TrailerEditorChrome.guarded` + `VideoTrailerView.runGuarded` + "자막 변경을 적용할까요?" 알림(적용 / 입력 취소 / 계속 편집). 적용 대상: 장면 선택(`guardedSelection`), 인스펙터 탭 전환, 편집·영상 만들기 전환, 편집본 저장, 영상 만들기·다시 시도, 폰하드 저장, 닫기·나가기, 폰 상세 뒤로, 장면 삭제. 조용히 적용하거나 버리는 경로 없음(예전의 선택 되돌리기 스냅백 제거).
  - `TrailerSceneInspector`: 자막 탭이 `captionDraft`를 사용, 색상 칩 히트 44pt.
- **메인 레이아웃 (`VideoTrailerSettings.editorLayout` / `areaContent` / `makeArea`)**
  - 머리글 고정, 본문은 `GeometryReader`의 실제 크기(안전 영역·키보드 반영 높이)로 배치. 예전 전체 `ScrollView`, 360pt 중첩 보드, 380/260 고정 미리보기, 인라인 인스펙터 제거.
  - 태블릿 세로: 위 고정 미리보기 + 아래 1:1(왼쪽 4열 보드 독립 스크롤 | 오른쪽 인스펙터 고정 탭 + 스크롤 본문).
  - 태블릿 가로·Mac: 1:1(왼쪽 4열 보드 | 오른쪽 미리보기 + 고정 탭 + 스크롤 본문). 판별은 `TrailerWorkspaceMode.mode(size:isPhoneDetail:usesShellSidebar:)`.
  - 폰(<640pt): 2열 보드 → 장면 탭 시 상세(뒤로 "장면 목록" + 고정 미리보기 + 고정 탭 + 스크롤 본문). 보드는 상세 중에도 트리에 남겨 스크롤 위치 유지.
  - `previewBounds`/`resizablePreview`/`previewGrip`: 기본 높이 `min(180pt, 본문 30%)`(Mac 2.5배 UI 배율과 무관한 pt 값), 얇은 하단 그립(36×4 캡슐, 글자·%·기본값 버튼 없음) 드래그로만 조절, 지금 본문의 `[72pt, 60%]` 안으로 클램프.
  - `TrailerSceneInspector.body`: 머리글·탭 고정 + 탭 본문만 `ScrollView`. 보드 도구줄과 겹치던 앞으로/뒤로/위치 이동/복제/삭제와 중복 되돌리기 버튼을 인스펙터에서 제거(포함/제외만 유지). 보드 선택 도구줄 버튼 히트 높이 44.
  - `TrailerWorkspace.swift`: 별도 상세 패널(오른쪽 320pt / 아래 260pt / compact 겹침)과 `detail` 제네릭 제거 → 인스펙터는 편집기 안에 한 곳만.
- **영상 만들기 영역**
  - `makeArea`: 미리보기(좁든 넓든 같은 얇은 그립 포함, 10.4 참고) + 전체 설정(`optionsSection`) 독립 스크롤 + 고정 아래 줄 `createBar`.
  - `createBar`: 지금 결과가 없거나 지난 결과면 "만들기" 하나만. 지금 결과면 **폰하드에 저장(주)** + 컬렉션에 추가(보조, 툴바에서 옮김). 공유는 플레이어 안의 기존 공유. 저장 후 실제 기록 이름을 한 줄로 표시. 툴바의 중복 저장·컬렉션 버튼과 플레이어 안 저장 버튼 제거.
  - `previewSection(showsOutput:)` + `renderStillContext`: 렌더 중에는 이전 영상을 숨기고, 렌더 시작 때 고정된 `renderPlan`의 장면을 `joinProgress.completed` 순서대로 **소리 없는 정지 장면**으로 표시(영상 장면은 그 장면 시작 시각 프레임). 진행 표시는 아래쪽 작은 패널로 옮겨 정지 장면이 보이게 함.
  - `TrailerWorkspacePreview`: `RemotePreviewView(initiallyPaused: true, pauseRequest:)` → 완성 플레이어는 **처음에 멈춤**. `setFullscreen(_:)`은 같은 플레이어 자리를 키우고 들어갈 때·나올 때 `pauseRequest`로 그 자리에서 멈춤(재생기 하나라 소리 겹침 없음, 자동 재개 없음).
  - `RemotePreviewView.swift`(공유 뷰어, 기본값 동작 불변의 추가 매개변수만): `initiallyPaused`, `pauseRequest`.
- **렌더 정합성 (`VideoTrailerModel`)**
  - `TrailerOutputRevision`(드래프트 서명 + 모드). `VideoTrailerView.apply`가 렌더 시작 시점의 재조정 드래프트로 값을 찍어 `start(..., revision:)`에 전달. 장면·옵션·자막은 기존대로 값 복사(`manualScenes`, `draftSources`).
  - 모델: `outputRevision`, `renderingRevision`, `renderPlan`, `runID`. 완성 게시 직전 `runID` 불일치면 결과 파일만 지우고 게시하지 않음. 게시 시 `outputRevision = 시작 때 revision`.
  - 화면: `isOutputCurrent = outputURL != nil && outputRevision == currentRevision`일 때만 플레이어·저장·공유·컬렉션 노출. 렌더 중 편집하면 늦게 끝난 결과는 "지난 결과"로 남고 만들기 버튼이 다시 나온다. 기존 취소·진행률·다시 시도·이전 정상 파일 보존 로직은 그대로.
  - `projectSnapshot(..., outputIsCurrent:)`: 지난 결과는 편집본에 저장하지 않음. 복원 시 `markRestoredOutput(currentRevision)`.
  - `save(to:revision:isPrivate:)`: 지금 revision의 결과만 저장, 이름은 `outputName`(완성 시각 기준 `TrailerNaming.outputFilename`), `importDownloadedFile`이 돌려준 기록(`byteCount > 0`)을 받은 뒤에만 `isSaved`/`savedFilename`. 렌더 완료 ≠ 저장됨.
  - `TrailerOutputFileService.name`: 플레이어·공유에 보이는 항목 이름도 같은 `outputName`.

### 10.3 남은 격차 (다음 담당자 작업)
1. **빌드·테스트 미실행**: 컴파일 오류 가능성 포함 전부 미검증. 우선 `./scripts/xcodebuild_project.sh`로 빌드 후 7장의 테스트(420→3, 파일명, Vision) 작성·실행 필요.
2. **편집본 목록 소형 썸네일 — 기존 구현됨, 런타임 확인 대기**: 실제 쓰이는 목록은 `NasFinder/Features/Connections/ConnectionListView.swift:1422`의 `PorcelainDraftCard`(실제 분기 `isPorcelain == true`, 1610 부근)이며 이미 112×63 소형 썸네일과 전체 항목을 보여 준다. 예전에 적은 `TrailerDraftRow`(1675)는 쓰이지 않는 대체 경로라 수정·범위 승인·48×36 축소가 필요 없다(이전 "범위 밖 미변경" 기재는 잘못).
3. **공유 이름 — 소스 경로 확인됨(TM), 런타임 확인 대기**: `TrailerWorkspacePreview`가 `TrailerOutputFileService(url: outputURL, name: outputName)`을 만들고, `RemotePreviewView.shareCurrentItem`(~745)이 `currentItem.name`을 `PreviewShareCoordinator.prepare`에 넘기며, stage(~2435)가 `safeFilename(originalFilename)` 이름으로 전용 임시 폴더에 하드링크/복사한다. 따라서 실제 공유 파일명은 `outputName`이다. 임시 출력 파일 이름은 바꾸지 않는다.
4. **회전**: 레이아웃 컨테이너가 바뀌어 미리보기 플레이어와 보드 스크롤 위치는 회전 시 새로 만들어진다(자막 초안·선택·미리보기 높이·폰 상세 여부·영역은 부모 상태라 유지).
5. **Mac 좁은 창 — 소스 수정됨(10.4), 빌드·런타임 미확인**.
6. **영상 만들기 넓은 화면 그립 — 소스 수정됨(10.4), 빌드·런타임 미확인**.
7. **키보드**: 본문 높이 축소에 의존한 클램프는 실기기 미확인.
8. **폰 상세**: 위치 이동·복제·삭제는 보드 도구줄에만 있어 상세에서 뒤로 가야 한다(중복 금지 결정).
9. **1장 공통 클립보드(교차 저장소 복사·이동) — 소스 동작 중, 런타임 확인 대기**: 별도 소유자(외부 owner) 방식이 core와 기존 Browser의 4개 호출에 이미 구현되어 있다. `PhoneHardBrowserView`가 `FileBrowserView(LocalInboxFileService)`를 감싸 같은 경로를 쓰며, `ReceivedFilesView`는 쓰이지 않는다(이전 "미착수" 기재는 잘못).
10. 사용되지 않는 옛 선언(`TrailerSceneStrip`, `VideoTrailerView.draftBinding`, `presentedSettings` 경로)은 정리하지 않았다.
11. **사진 `.sync` 테스트 참조**: `editing.photo_fill_camera_plan`의 iOS 구현은 이미 `tests: []`이며 `.sync/product-contract.yaml` 어디에도 `NasFinderTests/VideoTrailerImageClipTests.swift` 참조가 없음을 확인했다(이번에 바꿀 것 없음). 7장의 해당 파일은 아직 만들지 않은 계획 항목이다.

### 10.4 이번 보정(2026-11-01, 소스만 수정, 빌드·테스트·Git 없음)
- `VideoTrailerView.swift` `VideoTrailerSettings.makeArea(size:)`만 수정: 넓은 화면(`width >= 640 && width > height`)에서도 기존 `previewHeight` 상태와 기존 `previewGrip`을 쓴다. 넓을 때 범위는 기본 = 반쪽 폭 16:9(`half * 9 / 16 + 1`), 최소 72pt, 최대 = 지금 본문 높이 − 28pt(그립 자리), 좁을 때는 기존 `previewBounds(bodyHeight:preferredFraction: 0.45)` 그대로. 그립은 전체 화면이 아닐 때 항상 표시(새 슬라이더·라벨·되돌리기·버튼 없음). 같은 `previewHeight`를 편집 영역과 공유하고, 전체 화면은 기존대로 본문 전체 높이를 쓴 뒤 나오면 저장된 높이로 돌아온다.
- `TrailerWorkspace.swift` `TrailerWorkspaceMode.mode(size:isPhoneDetail:usesShellSidebar:)`만 수정: `size.width < 640` 판별을 Mac Catalyst / `usesShellSidebar` / `isiOSAppOnMac` 판별보다 먼저 해 좁은 Mac 창도 기존 `.phoneBoard`/`.phoneDetail`(2열 보드 → 상세) 경로를 쓴다. 넓은 Mac은 `.macResponsive` 1:1, 태블릿 세로·가로 판별은 그대로. 전역 Mac UI 배율은 건드리지 않았다.
- `.sync/product-contract.yaml`: 거짓 테스트 참조가 이미 없어 수정하지 않았다.
- 사용자 수정 파일(`AGENTS.md`, Browser 3개 파일)과 그 밖의 소스는 건드리지 않았다.

### 10.5 Mac 2.30 런타임 확인 결과 보정(2026-11-01, 부모 소스만 수정, 재빌드 대기)
런타임에서 확인된 UX 회귀 4건을 부모 작업 트리(`/Users/armsone/git/NasFinder`)에서만 고쳤다. 빌드·테스트·Git·후보 트리 변경은 하지 않았다. 버전 2.30.0 / 빌드 202611010312 그대로. TM이 현재 iOS 실행이 끝난 뒤 영향 파일 2개(`VideoTrailerView.swift`, `TrailerSceneEditing.swift`)만 후보에 넣고 다시 빌드·설치해 확인해야 한다. `TrailerWorkspace.swift`는 필요 없어 건드리지 않았다.
1. **준비가 끝나면 바로 장면 보드**: `VideoTrailerView.seedScenesIfNeeded()`가 기존 `TrailerSettingsDraft.beginSceneEditing(mode:)`(= `TrailerPreparedPlan.seedEdits`)로 자동 계획을 장면 목록으로 한 번 옮긴다. 조건: 시작됨·`model.isStaged`·`!model.isBusy`·새 `model.photoTimingReady`(예고편+사진이면 사진 길이 측정 완료)·소스 사라짐 알림 아님·`scenes == nil`. 장면 목록이 이미 있으면 아무것도 바꾸지 않는다. 호출 지점: `openSettings()`, `model.isBusy`가 false가 될 때, `continueResume()`의 완성 영상 있는 재개 분기, 자동 추천으로 되돌리기로 `scenes`가 nil이 될 때. 옮긴 목록의 계획(`TrailerPreparedPlan.scenes(... manual:)`)이 자동 계획과 장면마다 같을 때만 새 `VideoTrailerModel.carryOutputRevision(from:to:)`가 직전에 지금 결과였던 영상의 revision을 새 서명으로 옮긴다(렌더 중이거나 이미 지난 결과면 그대로). 처음 옮긴 것은 되돌리기 단계가 아니다(되돌리기 기록이 비었을 때 `history.reset`). 중복 "장면 직접 편집 시작" 버튼 2개와 안내 문구를 지웠고(`boardPane`의 자동 분기, `TrailerSceneInspector`의 `scenes == nil` 분기·`beginEditing` 인자, 자식 `beginSceneEditing()`), 준비 중에는 기존 진행 표시만 보인다.
2. **다시 열 때 선택 장면 유지**: 닫기는 `TrailerSuspendedSession`으로 이어지는데 여기에 선택이 없어 새 편집기의 `selectedSceneID`가 nil이었다. 메모리 세션에 `selectedSceneID`를 담고 `init`에서 되살린다(저장 형식 변경 없음, 디스크 경로는 기존 `record.selectedSceneID`). 두 경로 모두 `keepValidSceneSelection()`이 없거나 사라진 선택이면 첫 장면을 고른다. 회전·폰 상세 뒤로는 기존대로 부모 상태라 유지.
3. **기본 제목 고정**: `projectSnapshot(... createdAt:)` 인자를 더해 새 편집본의 `createdAt`이 머리글 기본 이름과 같은 `sessionStartedAt`이 된다. 기존 기록의 `createdAt`·사용자 이름·MP4 파일명 규칙은 그대로.
4. **머리글 문구**: 장면 격자 머리글 "스토리보드 (n)" → "장면 (n)". 내부 타입 이름은 그대로.
- 남은 한계: 사진 측정 전 저장된 옛 예고편 편집본(`photosAnalyzed == false`, 사진 포함)은 측정이 끝날 때(예: 영상 만들기 후)까지 자동 보드로 옮겨지지 않는다(→ 10.6-1에서 고침). 장면이 옮겨진 뒤에는 예고편/뮤직비디오 전환이 직접 편집 장면을 다시 계획하지 않는다(기존 직접 편집 규칙). 컴파일·런타임 미확인.

### 10.6 Mac 런타임 확인 2차 보정(2026-11-01, 부모 소스만 수정, 재빌드·런타임 확인 대기)
부모 작업 트리에서 `VideoTrailerView.swift`, `RemotePreviewView.swift` 2개만 고쳤다(`TrailerSceneEditing.swift`·`TrailerWorkspace.swift`는 필요 없어 그대로). 빌드·테스트·Git·후보 트리 변경 없음. 버전 2.30.0 / 빌드 202611010312 그대로. TM이 두 파일을 후보에 넣고 다시 빌드·설치·런타임 확인해야 한다.
1. **옛 자동 편집본도 바로 장면 보드**: `seedScenesIfNeeded()`의 `model.photoTimingReady` 조건과 그 속성을 지웠다. 새 준비는 `start`가 예고편 사진 길이 측정까지 `isBusy` 동안 끝낸 뒤 `isStaged`를 켜므로 그대로 막히고, 되살린 옛 편집본(`photosAnalyzed == false`)은 지금 저장된 길이의 자동 계획을 그대로 옮긴다(영상 만들기 강제·가짜 측정 상태 없음). `scenes != nil`이면 아무것도 바꾸지 않고, 같은 계획일 때만 revision을 옮기는 `samePlan` 검사는 그대로.
2. **편집기 안 작은 완성 영상 플레이어**: `RemotePreviewView(editorCompact:)`(기본 false, 다른 뷰어 불변). `TrailerWorkspacePreview`가 전체 화면이 아닐 때만 true로 넘긴다. 작은 컨트롤은 닫기·제목을 빼고 위에 전체 화면(기존 accessory)·공유, 아래에 기존 재생/일시 정지 + 위치 슬라이더와 "현재 / 길이" 한 줄(높이 150pt 미만이면 한 줄로 모음). 버튼은 기존 44pt 원형. 전체 화면은 기존 전체 컨트롤.
   - 0:00 / 0:00 원인(소스 판독): 전체 화면 ↔ 작은 칸 전환 때 하단 컨트롤 분기가 바뀌어 `SharedVideoProgressBar`가 새로 생기고, 멈춘 재생기에서는 주기 관찰이 불리지 않아 0으로 남는다. 또 `onDisappear`의 `tearDown` 뒤 다시 나타나면 `.task`가 재생기를 새로 만들어 0초로 돌아간다. 보정: 새 `EditorCompactVideoProgress`가 붙을 때 지금 위치·길이를 바로 읽고, 편집기(`accessoryControls != nil`)에서는 이미 재생기가 있으면 다시 불러오지 않으며, `pauseRequest`·다시 나타날 때 멈춘 재생기를 지금 위치로 다시 찾아간다(`refreshPausedPosition`, 재생 안 함). 재생기는 하나라 소리 겹침 없음.
3. **내보낸 자막 잘림**: `captionAnimationTool`의 `CATextLayer`를 자막마다 한 번 `UIGraphicsImageRenderer`(scale 1, 투명)로 그린 이미지 `CALayer.contents`로 바꿨다. 측정(`boundingRect`)과 그리기(`NSString.draw`)가 같은 UIKit 배치·가운데 정렬·단어 줄바꿈을 쓴다. 상자는 미리보기와 같은 기준(높이 360 기준 비율, 좌우 16, 글자 여백 10×4, 위 16/아래 20)이고 높이는 화면 안으로 제한(넘치면 마지막 줄 말줄임). 그림자·장면별 불투명도 애니메이션·`renderSize`·사진 채우기/움직임은 그대로.
4. **직접 편집 장면 요약**: `scenes != nil`이면 "n장면"만 보이고 "선택한 …초에 가장 가까운 길이로 맞췄어요"는 자동 계획일 때만 보인다.
- 런타임 확인 필요: 9:16 작은 칸(~122pt)에서 컨트롤이 칸 안에 들어오는지, 전체 화면 0:05 멈춤 → 나온 뒤 같은 프레임·0:05 표시인지, 인코딩된 9:16 영상의 "NF APPLE CHECK" 전체·위아래 방향(부모 층 `isGeometryFlipped`에서 이미지 내용이 바로 서는지) 확인, 옛 자동 편집본이 열자마자 장면 보드인지, 직접 편집 3장면 요약 문구. 122pt보다 좁은 칸에서는 버튼 2개 줄이 넘칠 수 있다. 컴파일 미확인.

### 10.7 길이 조절 정정(2026-11-01, 라벨만 수정, 빌드·테스트·Git·후보 트리 변경 없음)
- 정정: 직접 편집 중에는 길이 조절이 쓰이지 않는다던 예전 TM 가정은 틀렸다. "전체 길이"는 이미 `setManualTotal` → `TrailerSceneEditor.redistributeManualTotal`로 포함된 장면 길이를 다시 나누고, 클립 길이는 `setExplicitClipLength` → `applyExplicitClipLength`로 포함된 모든 장면 길이를 덮어쓴다.
- `VideoTrailerSettings.durationControls`의 두 번째 조절 제목만 바꿨다: `scenes != nil`이면 "클립 길이 일괄 적용", 자동 계획(`scenes == nil`)이면 기존 "영상 클립 길이". 값·범위·추천 칩·설명·동작은 그대로. 버전 그대로. 컴파일·런타임 미확인.

### 10.8 Mac 런타임 확인 3차 보정(2026-11-01, 부모 소스만 수정, 최종 빌드·재실행 확인 대기)
TM이 실제 Mac 빌드에서 확인한 것(새 편집본 3장면 선택 복원, 1080×1920 자막 "NF APPLE CHECK 2" 전체·바로 섬, 전체 화면 진입 시 일시 정지·나온 뒤 0:05/0:13과 같은 프레임 유지)은 그대로 두고, 남은 실제 화면 문제 2개만 고쳤다. 수정 파일은 `RemotePreviewView.swift`, `SharedFullscreenMediaPlayer.swift`와 이 문서뿐. 빌드·테스트·Git·후보 트리 변경 없음. 버전 2.30.0 / 빌드 202611010312 그대로.
1. **좁은 작은 칸 컨트롤**(`editorCompactChrome`): 폭 220pt 미만이면 아래쪽을 세로로 쌓아 재생/일시 정지 위에, 위치 줄("현재 / 길이" + 슬라이더)을 그 아래 전체 폭으로 둔다(122pt 칸에서 시간 글자 잘림 해소). 한 줄 모음은 높이 150pt 미만이면서 폭 280pt 이상일 때만(위치 줄 포함). 폭 106pt 미만이면 위 줄은 전체 화면(accessory)만 두고 공유는 숨긴다(전체 화면의 기존 컨트롤에 공유가 있다). 세로로 쌓은 칸이 높이 160pt 미만이면 위치 줄을 숨기고(전체 화면에 탐색이 있다), 높이 104pt 미만이면 재생 + 전체 화면만 한 줄로 둔다(폭 156pt 이상이면 공유 포함). 버튼·아이콘은 기존 44pt 그대로, 새 메뉴·버튼·도움말 없음. `editorCompactActions`는 `showsShare` 인자를 받는 함수로 바뀌었다.
2. **전체 화면 0:00 / 0:00**(`SharedVideoProgressBar`): 붙을 때(`onAppear`) 주기 관찰 전에 `player.currentTime()`과 `currentItem.duration`을 같은 유한값 검사로 바로 읽고, `.task`에서 `asset.load(.duration)`으로 길이를 채운다. 재생·0초 이동 없음, 재생 엔진·시간 형식·관찰 해제 그대로. `SharedVideoMiniProgressLine`도 `onAppear`에서 같은 초기값만 읽는다.
- 런타임 확인 필요: 122pt 9:16 칸의 세로 배치와 "0:00 / 0:13" 전체 표시, 칸을 106pt 미만으로 줄였을 때 버튼 넘침 없음, 멈춘 0:05에서 전체 화면 진입 시 시간·슬라이더가 0:05 / 0:13인지. 컴파일·런타임 미확인.

### 10.9 작은 칸 원인 정정(2026-11-01, `VideoTrailerView.swift`와 이 문서만 수정, 빌드·테스트·Git·후보 트리 변경 없음)
- 원인 정정: 10.8의 폭 분기만으로는 풀 수 없다. `makeArea`의 미리보기 최소 높이 72pt에 9:16 출력이면, `TrailerWorkspacePreview` 출력 분기의 `Color.clear.aspectRatio(…, .fit)`가 `RemotePreviewView` 자체를 폭 40.5pt로 줄여서 44pt 버튼이 들어갈 수 없었다.
- 보정: 출력 분기만 `Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).overlay { RemotePreviewView … }`로 바꿔 이미 높이가 정해진 미리보기 칸 전체를 쓴다. 영상은 기존 `SharedVideoPlayerSurface`의 `.resizeAspect`로 칸 안에서 제 비율 그대로(실제 영상 크기 동일), 남는 좌우 여백은 화면 쪽 레터박스일 뿐이고 컨트롤은 칸 폭 전체를 쓴다. 내보내기 캔버스·채우기는 그대로.
- 호출부 확인(소스 판독): 출력을 보이는 `previewSection(showsOutput: true)`는 `makeArea` 한 곳뿐이고 항상 `.frame(height: previewFrameHeight)`(전체 화면은 `size.height`)가 붙는다. `resizablePreview`의 `showsOutput: false`도 높이가 정해져 있다. 옛 주석의 ScrollView 얇은 띠 문제를 일으킬 높이 미정 호출부는 없다.
- 그대로: 출력 전 원본 이미지/사진 플랜의 비율 배치, 10.6~10.8의 작은 칸 진행률·초기값 코드, 단일 재생기·전체 화면 일시 정지. 새 버튼·도움말·의존성·버전 변경 없음. 컴파일·런타임 미확인.


## 11. 최종 Mac 확인 및 남은 기기 확인 (2026-11-01)

- Mac 2.30.0 / 202611010312 Universal 빌드·Developer ID 서명·공증·DMG 확인 후 기존 데이터를 유지해 교체 설치했다.
- 설치한 최종본에서 저장한 장면 3 선택·길이·자막 복원, 전체 폭 재생 버튼, 최소 높이 72pt에서 버튼 잘림 없음, 전체화면 진입 시 정지 및 0:09/0:13 표시·같은 위치 복귀를 직접 확인했다.
- 별도 확인용 편집본에서 사진·영상 혼합 12.5초 제작 → 자막 수정 → 편집본 저장 → 다시 제작 → 폰하드 저장을 수행했다. 인코딩된 세로 영상의 자막 전체가 올바르게 표시된다.
- 인물 사진으로 짧은 2.4초·긴 8.0초 장면을 제작했다. 확인한 프레임에서 짧은 장면은 고정 초점 약한 줌아웃, 긴 장면은 주된 인물 쪽 이동이며 출력 빈 여백과 주된 머리 잘림은 없었다. 모든 인물을 모든 프레임에 보존한다는 뜻은 아니다.
- 폰하드→등록된 Synology NAS 복사, NAS→폰하드 이동, 하위 파일을 포함한 폴더 복사를 실제 수행했다. 되돌아온 확인용 텍스트는 원본과 SHA-256이 일치하며, 이동한 NAS 원본이 정리된 것을 재방문해 확인했다.
- 기존 관련 검사 94개 통과·실패 0개·1개 건너뜀(iPad 시뮬레이터). 건너뛴 항목은 명시적 활성화가 필요한 기존 VideoLAN AVI/ASF 샘플 검사다. 실제 iPhone 검사로 대신 계산하지 않는다.
- iPhone은 실제 앱 실행이 잠금으로 거절되어 2.30.0 교체 설치와 실기기 확인을 하지 못했다. iPad 세로·가로 화면 확인은 연결된 실기기가 없어 기존 시뮬레이터에서 진행 중이다.
- 기존 사용자 수정과 원본 파일·기존 편집본은 보존했다. 비교용으로 만든 편집본·출력과 입력 사본은 별도로 보존한다.
