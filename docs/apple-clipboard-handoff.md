# Apple 파일 클립보드(폰하드 ↔ NAS) 인수인계

작업 위치: 분리된 worktree `/Users/armsone/git/.NasFinder-Apple-clipboard-20261101` (처음에는 detached `0cffae9`, 공개 2.29.0. 현재 브랜치 `release/apple-2.30.0-candidate`, 버전 2.30.0 빌드 202611010312. 이번 차례에서 버전·빌드 번호는 바꾸지 않음).
상태: **소스 편집만 끝남. 빌드·테스트·실기기 실행은 하지 않음(이 작업에서는 금지).** 컴파일 성공도, 런타임 안전성도 검증되지 않았습니다. 최종 Mac 빌드 재실행 결과는 TM이 확인합니다.

## 바꾼 파일과 함수

### `NasFinder/Features/Browser/FileOperationCoordinator.swift`
- `import Combine` 추가.
- `FileClipboardPayload`: `token: UUID`, `sourceService: (any RemoteFileService)?`(메모리 전용) 추가. 명시적 `init`의 기본값(`token = UUID()`, `sourceService = nil`)으로 기존 형태의 호출도 그대로 됩니다.
- 새 타입 `SharedFileClipboard`(@MainActor 싱글턴, `@Published payload`, `stage` / `clear` / `retain(_:ofStaging:)`). 저장하지 않으며 앱 메모리에만 있습니다.
- `FileOperationCoordinator.init()`: 공유 클립보드를 `assign(to: &$clipboard)`로 구독합니다. 그래서 모든 브라우저(대시보드 루트, 폰하드, 즐겨찾기, NAS 대상 선택기)가 같은 클립보드를 봅니다.
- `placeOnClipboard(_:mode:using:)`: 선택 인자 `using`(기본값 nil)을 추가했습니다. 항목 연결과 같은 연결의 서비스만 원본으로 보관합니다.
- `clearClipboard()`: 공유 저장소를 비웁니다.
- 새 `canPaste(into:)`: 같은 연결이면 기존 capability 검사를 쓰고, 다른 연결이면 `crossStorageBlocker`로 확인합니다.
- `paste(into:using:onCompletion:)`: 연결이 다르면 `pasteAcrossStorage`로 넘기고, 같은 서버는 기존 엔진(`service.copy/move`, `.keepBoth`, `.automatic`)을 그대로 씁니다. 다음을 강화했습니다.
  - 루트를 완료로 치는 조건: succeeded가 하나 이상이고 failures·skipped가 비어 있으며 취소되지 않았을 때만.
  - 건너뛴 항목의 메시지도 보여 주고, 메시지 없는 미완료에도 안내 문구를 붙입니다.
  - `RemoteOperationInterruptedError`의 취소를 취소로 처리합니다.
  - 이동 후 남은 항목은 `SharedFileClipboard.retain(_:ofStaging:)`으로 정리하므로, 그 사이 새로 담은 클립보드는 지우지 않습니다.
- 새 `crossStorageBlocker(for:into:)`: 다른 저장소 붙여넣기 조건을 확인합니다. 원본 서비스 스냅샷이 필요하고(연결 ID가 같아야 함), 대상은 `.upload`(폴더가 있으면 `.createFolder`도), 이동이면 원본이 `.delete`(폴더가 있으면 `.recursiveDelete`도)를 지원해야 합니다.
- 새 `pasteAcrossStorage(_:into:using:onCompletion:)`: 루트별로 `CrossStorageTransfer`를 실행하고, 진행 제목, 취소·요약, 토큰 기반 클립보드 정리를 맡습니다.
- `start` / `operationContext`: `activeRunID`를 추가했습니다. 이전 실행이 늦게 보낸 진행률은 현재 작업의 진행률을 덮지 않습니다.
- 새 private 클래스 `CrossStorageTransfer`와 `CrossStorageTransferError`(같은 파일 안).

### `NasFinder/Features/Browser/FileBrowserView.swift`
- `placeOnClipboard` 호출 4곳(항목 패널의 복사·이동, 선택 막대의 복사·이동)에 `using: viewModel.service`를 넘깁니다.
- `canPerformPasteAction`: 클립보드가 있으면 `operationCoordinator.canPaste(into: viewModel.service)`를 씁니다. 기존 "붙여넣기" 버튼과 아이콘을 그대로 쓰며 새 버튼이나 설명 줄은 없습니다.

### 바꾸지 않은 파일
`ReceivedFilesView.swift`, `InboxUploadDestinationView.swift`, `RemoteFileService.swift`, `SharedInboxStore.swift`.
- `ReceivedFilesView`는 저장소 전체에서 생성하는 곳이 없습니다(`ReceivedFilesView\b` 검색 결과가 정의 한 줄뿐). 폰하드는 `PhoneHardBrowserView` → `FileBrowserView(LocalInboxFileService())`를 쓰므로 공유 클립보드와 기존 붙여넣기로 연결됩니다.
- `InboxUploadDestinationView`의 코디네이터도 공유 클립보드를 보게 되지만 코드는 바꾸지 않았습니다.

## 사용 흐름
1. 폰하드 또는 NAS 브라우저에서 기존 "복사" 또는 "이동"을 누릅니다.
2. 대시보드를 거쳐 다른 저장소의 폴더로 가서 더보기 패널의 "붙여넣기"를 누릅니다.

클립보드는 화면을 오가도 유지됩니다. 파일과 폴더 모두 압축 없이 하나씩 전송합니다.

## 저장소 간 전송의 검증과 삭제 불변식(코드 기준, 실행으로 확인하지 않음)
1. **원본 고정**: 원본은 클립보드에 담을 때의 서비스 스냅샷에서만 읽습니다. 대상이나 현재 활성 연결로 바뀌지 않습니다. 붙여넣기는 시작할 때의 클립보드 값을 그대로 씁니다.
2. **루프·경로 탈출 방지**: 쓰기 전에 원본 트리 전체를 먼저 나열합니다(깊이 64 제한).
   - 루트는 `connectionID`가 클립보드에 담은 원본 서비스의 `connection.id`와 같아야 합니다. 이름이 안전하고, 경로가 `RemotePath.normalize`로 해석되어야 합니다(`..`·NUL·빈 경로 거부).
   - 이름 거부 조건(`isSafeName`): 빈 이름, `.`, `..`, `/`, `\`(SMB·일부 FTP의 구분자), NUL.
   - 하위 항목은 같은 원본 연결이어야 하고, 이름이 안전해야 합니다. 경로는 현재 폴더 `item.path`의 **바로 아래 한 단계**여야 합니다(`isImmediateChild`: `RemotePath.normalize(child, within: parent)` 통과, 같은 절대·상대 형식, 구성 요소가 정확히 하나 더 많고 마지막 구성 요소도 안전한 이름). 마지막 구성 요소를 목록 이름과 비교하지는 않습니다. 폰하드는 저장 파일 이름으로 경로를 만들기 때문입니다.
   - 조건에 맞지 않는 항목이 하나라도 있으면 그 루트 전체를 전송하지 않습니다(이동이면 원본 유지). 목록에 나온 바깥 경로, 자기 자신, 상위 경로는 따라가지 않습니다. 서버 쪽 심볼릭 링크 순환은 깊이 제한으로만 끊습니다.
3. **충돌 처리**: 루트 폴더 이름이 대상에 있으면 대소문자를 무시하고 `이름 (n)`을 새로 만듭니다. 기존 폴더에 합치거나 덮어쓰지 않습니다. 파일 업로드는 항상 `.keepBoth`입니다.
4. **파일 전송(task 소유 staging + 해시)**:
   - 원본 `download(_:progress:)`가 돌려준 URL은 **읽기 전용**으로 다룹니다. 폰하드는 저장된 원본 자체를 돌려주므로 이 URL은 지우거나 옮기지 않습니다.
   - 그 URL을 `CrossStorageTransfer.stage(_:to:)`가 1 MiB 단위 `FileHandle.read(upToCount:)`로 한 번 읽습니다. 같은 바이트를 CryptoKit `SHA256`(증분)에 넣고 동시에 이 전송 전용 staging 파일에 씁니다. 결과가 `FileProof(byteCount, sha256)`입니다. 파일 전체를 메모리에 올리지 않습니다(`Data(contentsOf:)` 미사용). 작업은 `Task.detached`(`offMainActor`)에서 돌고 취소가 전달됩니다.
   - staging 위치는 `temporaryDirectory/NasFinder-CrossStorage-<UUID>/<UUID>/<원래 이름>`입니다. 파일마다 새 폴더를 만들고, 이미 파일이 있으면 실패합니다. 한 번 쓴 뒤 다시 쓰기용으로 열지 않습니다(write-once). 권한을 읽기 전용으로 바꾸지는 않았습니다. 폰하드 `upload`(`SharedInbox.importTemporaryItem`)가 `copyItem`으로 권한까지 복사하기 때문에, 바꾸면 사용자의 저장 파일이 읽기 전용이 됩니다.
   - staged 바이트 수를 `RemoteDownloadIntegrityError.validate`로 원본 목록 크기와 맞춘 뒤, **staging 사본만** 대상 `upload(.keepBoth)`에 넘깁니다. 그래서 업로드 중에 원본이 바뀌어도 보낸 내용은 바뀌지 않습니다.
   - 업로드 결과는 succeeded가 정확히 1개이고 failures·skipped·cancel이 없어야 합니다. 또 `resultingItem?.path ?? destinationPath`가 있어야 합니다(없으면 미확인).
   - staged 파일 폴더는 업로드가 끝나면(성공·실패·취소 모두) 바로 지웁니다. 비교에는 proof만 씁니다. 지우는 것은 staging 루트 바로 아래의 자기 폴더뿐입니다.
5. **결과 검증(대상 바이트 재확인)**: 폴더마다 대상을 다시 나열합니다.
   - 각 결과는 업로드나 `createFolder`가 돌려준 ID 또는 정규화한 경로와 **정확히 하나만** 맞아야 합니다. 종류도 같아야 합니다.
   - 파일은 목록 크기가 있으면 크기가 다를 때 바로 실패합니다. 크기가 없어도 그것만으로 실패하지는 않습니다.
   - 이어서 `freshProof(of:from:expectedByteCount:)`로 **대상의 실제 바이트를 다시 읽어** SHA-256과 실제 바이트 수가 staged proof와 같은지 비교합니다.
   - 찾지 못하거나, 읽지 못하거나, 다르면 그 루트는 미완료입니다. 이동이면 원본을 유지하고, 성공으로 치지 않습니다.
   - 기존 대상 경로는 덮어쓰거나 지우지 않습니다. 대상에서 무엇을 지우는 코드는 없습니다.
6. **`freshProof` 읽기 방식**:
   - `supportsRangeStreaming`인 서비스(SMB, WebDAV, SFTP, FTP, Synology)는 기존 `readRange`로 4 MiB씩 처음부터 끝까지 읽어 해시합니다. 그래서 `DownloadCache`(경로·수정 시각·크기로 키를 만드는 캐시)의 옛 바이트가 현재 내용 대신 쓰이지 않습니다. 이때 다음을 지킵니다.
     - 요청보다 긴 응답은 확인 불가로 처리합니다.
     - 빈 응답은 파일 끝으로 봅니다(짧으면 바이트 수 불일치).
     - 목록 크기가 기대값과 같지 않으면(크기 미보고) 기대 길이 뒤 1바이트를 더 읽어 파일이 늘어나지 않았는지 확인합니다. 이 추가 읽기가 오류를 내면 확인 불가로 처리합니다.
   - range를 지원하지 않는 서비스 중에서는 **`LocalInboxFileService`(폰하드)만** `download(_:)`가 돌려준 URL(저장된 원본 파일 자체)을 읽기만 하며 1 MiB 단위로 해시합니다. 폰하드는 브라우저에서 `TrafficMeasuringRemoteFileService`로 감싸지 않으므로(`FileBrowserView.swift` 317행) 타입 검사가 맞습니다.
   - 그 밖에 range를 지원하지 않는 서비스는 `download`가 캐시 사본을 돌려줄 수 있습니다. 그래서 현재 내용의 증명으로 쓰지 않고 `contentUnverifiable`을 던집니다. 이는 원본 삭제 **전에** 일어납니다. 캐시를 비우거나 신선하다고 가정하지 않습니다.
   - 현재 NAS 5종(SMB, WebDAV, SFTP, FTP, Synology)은 모두 `supportsRangeStreaming = true`라 range 경로를 탑니다.
   - range를 지원한다고 한 서비스에서 `readRange`가 실패하면 download로 대신하지 않습니다. 확인 불가로 처리합니다. 파일 끝 뒤를 읽는 무조건 EOF 확인은 추가하지 않았습니다(Synology HTTP 416). 1바이트 추가 읽기는 목록 크기가 기대값과 다를 때만 하는 기존 동작 그대로입니다.
7. **이동 삭제 조건**: 위 검증이 루트 전체에서 통과한 경우에만 다음을 진행합니다.
   - `unchangedTree`(1차): 취소 확인 → 원본 상위 폴더를 다시 나열합니다. 같은 `id`의 항목이 정확히 하나여야 하고 `id`·연결·정규화 경로·종류·크기·수정 시각·리비전이 같아야 합니다. 폴더는 하위 트리 전체를 다시 나열(2번 규칙 그대로)해 스냅샷과 완전히 같은지 확인합니다. 추가·삭제·변경 항목이 있으면 유지합니다.
   - **새로** 나열한 트리의 모든 파일을 `freshProof`로 원본에서 지금 다시 읽어, 전송 때 staged proof와 SHA-256·바이트 수가 같은지 확인합니다. 파일마다 취소를 확인합니다. proof가 없거나, 읽을 수 없거나, 하나라도 다르면 원본을 유지하고 "복사는 끝났지만 원본을 그대로 두었습니다"를 남깁니다(복사됨, 이동 안 됨).
   - `unchangedTree`(2차): 해시 읽기가 **끝난 직후** 루트와 트리 전체를 같은 기준으로 다시 나열·비교합니다. `freshProof`는 staged 바이트 수까지만 읽습니다. 그래서 해시하는 동안 뒤에 덧붙은 데이터는 해시로는 드러나지 않고 목록의 크기·수정 시각·리비전 변화로만 잡힙니다. 다르면 원본을 유지합니다.
   - 바로 이어 취소 확인 후 그 루트 하나만 `delete(recursive:)`.
   - 삭제 결과가 완전한 성공이어야 완료로 칩니다.
   - 하나라도 확인되지 않으면 그 항목은 클립보드에 남깁니다. 부분 트리를 지우거나, 늦게 도착한 다른 클립보드 토큰으로 지우는 경로는 없습니다.
8. **취소와 정리**: 매 단계 전에 `Task.checkCancellation`을 확인합니다. 취소되면 원본을 지우지 않고(삭제 도중 취소는 별도 메시지), 이미 만든 대상 부분 복사본은 남깁니다. 클립보드는 같은 토큰일 때만 정리합니다. 루트 반복이 끝나면(완료·실패·취소 모두) `pasteAcrossStorage`가 `transfer.removeStaging()`으로 이 전송의 staging 루트 폴더만 지웁니다. 진행 제목, 취소·오류 요약, 토큰 처리는 바꾸지 않았습니다. 재확인 읽기는 같은 `progress`에 `.reading` 단계로 보고됩니다.
9. **결과 보고**: 완료로 치지 않은 루트에는 반드시 메시지를 남깁니다. 요약은 기존 `presentSummary` / `presentCancellationSummary`를 씁니다.

## 남은 공백 / 확인하지 못한 한계
- 빌드, 단위 테스트, 실기기 실행을 하지 않았습니다. Swift 6 동시성 경고나 오류가 있는지(`assign(to:)`, `@Sendable` 진행 클로저 등) 통합 뒤 빌드로 확인해야 합니다.
- NAS에서 받은 임시 또는 캐시 파일(`DownloadCache`, 클라우드 드라이브 임시 파일 등)은 원본 download URL이므로 이 경로에서 지우지 않습니다. 큰 폴더를 옮기면 기기 저장 공간을 쓸 수 있습니다. staging 사본은 파일 하나 분량만 동시에 남고 업로드 직후 지워집니다. 그래도 큰 파일 하나에는 그만큼의 여유 공간이 더 필요합니다.
- 비용: 파일마다 원본 1회 다운로드, staging 1회 쓰기, 대상 1회 재읽기가 필요합니다. 이동이면 원본 재읽기 1회가 더 있습니다. 큰 동영상은 이전보다 네트워크와 시간이 약 2~3배 듭니다.
- **남은 비원자 구간(정직한 한계)**: 2차 `unchangedTree` 목록과 `delete` 사이의 짧은 간격에서 생기는 변경은 막지 못합니다(이 프로토콜에는 조건부 삭제가 없음). 또 목록이 크기·수정 시각·리비전을 보고하지 않거나 갱신이 늦는 서버에서는 해시 중 파일 끝에 덧붙은 데이터를 2차 목록이 놓칠 수 있습니다. 최종 재목록은 이 위험을 좁힐 뿐 전역 원자성을 보장하지 않습니다. `readRange`의 실제 동작(캐시, 짧은 응답, 파일 끝 뒤 요청 시 오류 여부)은 백엔드마다 실제 서버로 확인하지 않았습니다. 목록이 크기를 보고하지 않고 파일 끝 뒤 1바이트 요청에 오류를 내는 서버에서는 이동이 '복사됨, 원본 유지'로 끝날 수 있습니다.
- range를 지원하지 않는 서비스는 폰하드를 빼고 모두 내용 확인 불가로 처리합니다. 그래서 클라우드 드라이브, 기기 폴더(`DeviceFolderFileService`) 같은 비-range 서비스가 원본이나 대상이면 다음과 같이 끝납니다(코드 읽기 기준, 실행 확인 안 함).
  - 복사: 대상에 사본은 남지만 '확인하지 못함'으로 보고합니다.
  - 이동: 원본을 유지하고 클립보드에 남깁니다.
  - 백엔드 프로토콜은 바꾸지 않았습니다.
- 이름에 `\`가 들어간 항목(폰하드·APFS에서는 정상 이름일 수 있음)이 루트나 하위에 있으면 그 루트 전체를 전송하지 않습니다(보수적 처리). 백엔드가 목록 하위 경로를 `현재 경로 + 한 단계`가 아닌 형태로 돌려주면(예: 다른 루트 형식) 그 루트는 실패하고 원본은 유지됩니다. 실제 서버별로 확인하지 않았습니다.
- `.keepBoth` 업로드가 실제로 기존 파일을 덮어쓰지 않는지는 각 백엔드 `upload`의 기존 동작에 맡깁니다. 이 코드는 대상에서 아무것도 지우지 않습니다.
- 백엔드마다 경로 표기, 목록의 크기·수정 시각 보고, `createFolder`가 같은 이름을 만났을 때의 동작이 다릅니다. 이 부분은 실제 서버로 확인하지 않았습니다. 일치하지 않으면 '확인 불가'로 원본을 유지하는 쪽으로 동작하도록 작성했습니다. 다만 목록과 생성 사이의 짧은 경쟁 구간은 막지 못합니다.
- 같은 NAS를 두 연결(예: SMB와 WebDAV)로 등록했을 때 자기 하위로 복사하는 경우는 감지하지 못합니다. 사전 나열로 무한 반복은 없고, 이동은 재검증에서 원본이 유지됩니다.
- 파일 하나 단위의 원자성은 대상 `upload`의 기존 동작에 맡깁니다. 내용은 SHA-256과 실제 바이트 수로 비교하며, 목록 크기는 빠른 실패에만 씁니다.
- `Task.detached`, `withTaskCancellationHandler`, `nonisolated static` 헬퍼, `autoreleasepool`의 throw 클로저가 Swift 6 엄격 동시성에서 경고 없이 컴파일되는지는 빌드로 확인하지 않았습니다.
- 클립보드에 보관한 원본 서비스가 나중에 세션 만료 등으로 쓸 수 없게 되면 붙여넣기 단계에서 오류로 보고될 뿐 자동으로 다시 연결하지 않습니다.
- 같은 서버 붙여넣기의 성공 판정을 엄격하게 바꿨습니다(부분 성공 루트는 클립보드에 남음). 기존 단위 테스트에 클립보드나 붙여넣기 테스트는 없습니다(`NasFinderTests`에서 검색 결과 없음).
- 진행률 표시는 기존 코디네이터의 단일 `progress`를 씁니다. 실행 ID로 늦게 온 보고는 막지만, 코디네이터 인스턴스마다 하나의 작업만 표시합니다.
- 미사용 `ReceivedFilesView`의 "NAS로 보내기(파일만)"는 그대로입니다.

## 자체 무결성 확인
- 편집한 파일은 `FileOperationCoordinator.swift`, `FileBrowserView.swift` 두 개와 이 문서뿐입니다. Video·사진·.sync·프로젝트·테스트·AGENTS 파일은 건드리지 않았습니다.
- `FileOperationCoordinator.swift`의 클립보드, 붙여넣기, 진행률 부분을 편집 후 다시 읽어 확인했습니다. `FileBrowserView.swift`의 `placeOnClipboard` 4곳과 `canPerformPasteAction`은 정확한 문자열 치환으로 바꿨습니다.
- 바이트 검증 보정 작업(이번 차례)은 `FileOperationCoordinator.swift`(`import CryptoKit`, `pasteAcrossStorage`의 `removeStaging()` 호출, `CrossStorageTransfer`, `CrossStorageTransferError`의 `stagingFailed`·`contentUnverifiable`)와 이 문서만 바꿨습니다. `RemoteFileService`의 프로토콜과 서비스 구현은 바꾸지 않았습니다. 셸, 빌드, 테스트, Git, 네트워크는 쓰지 않았고, 편집 뒤 해당 구간을 다시 읽어 확인했습니다.
- 최종 원본 안전 보정 작업(이번 차례)은 `FileOperationCoordinator.swift`의 `CrossStorageTransfer`와 이 문서만 바꿨습니다. 바꾼 부분은 다음과 같습니다.
  - `transferRoot` 루트 검증, `snapshot` 하위 검증.
  - 새 `unchangedTree`, `deleteSourceIfUnchanged`의 해시 뒤 재목록.
  - `freshProof` 비-range 분기.
  - `isSafeName`의 `\`, 새 `pathComponents(of:)`·`isImmediateChild(_:of:)`, `sameMetadata`의 연결·경로 비교.

  새 기능, 버튼, 테스트는 없습니다. 셸, 빌드, 테스트, Git, 네트워크는 쓰지 않았습니다. 편집한 구간은 한 번 다시 읽어 확인했습니다. **컴파일 여부는 확인하지 않았으므로 통합 빌드에서 확인해야 합니다.**
- 자격 증명이나 토큰을 문서나 로그에 쓰지 않습니다. 원본 서비스 참조는 메모리에만 있습니다.

## 최종 후보 복구: 컴파일 오류 2건 + 프라이버시 보존 가드 (2026-11-01, 미빌드)
쓰기 범위: `VideoTrailerView.swift`, `TrailerSceneEditing.swift`, `FileOperationCoordinator.swift`, 이 문서. `PrivacyMode.swift`, `ReceivedFilesView.swift`(`LocalInboxFileService`), `NasFinderShared/SharedInbox.swift`, `MacUIScale.swift`는 참조로만 읽었습니다.

### 컴파일 오류
- `VideoTrailerView.swift` `areaContent(size:)`(1776행 부근): `MacUIScale.defaultPadding`은 `CGFloat?`(iPhone·iPad·Mac idiom에서 nil = 시스템 기본 `padding()`)입니다. `let pad: CGFloat = isPreviewFullscreen ? 0 : (MacUIScale.defaultPadding ?? 16)`으로 명시했습니다. 16은 `MacUIScale.swift` 39~41행이 말하는 시스템 기본 여백이며 강제 언래핑은 없습니다. 참고: Mac idiom의 SwiftUI 기본 `padding()` 값이 정확히 16인지는 실행으로 확인하지 않았습니다.
- `TrailerSceneEditing.swift` `deleteScenes(ids:in:)`(81행): `delete(id, in: scenes)` → `delete(id, in: &scenes)`.

### 클립보드 프라이버시 가드 (`FileOperationCoordinator.swift`)
- `SharedFileClipboard`: `private init()`에서 `PrivacyMode.shared.$epoch.dropFirst().removeDuplicates().sink { [weak self] _ in self?.clear() }`를 `AnyCancellable`로 보관합니다. `@Published`는 `PrivacyMode.setActive`(@MainActor) 안에서 동기적으로 발행하므로, 모드가 켜지거나 꺼지는 순간 공유 payload가 비워집니다. 저장하지 않으며 `PrivacyMode`·보안 설정은 바꾸지 않았습니다. 이미 실행 중인 붙여넣기는 시작 때 잡은 클립보드 값(토큰 포함)으로 계속 동작하고, 끝난 뒤 `retain(_:ofStaging:)`은 토큰이 다르거나 payload가 비었으면 아무것도 하지 않으므로 비워진 클립보드를 되살리거나 새 선택으로 쓰기 대상을 바꾸지 않습니다.
- 새 `hasHiddenOrigin(_:)`: 담긴 루트 중 하나라도 `PrivacyMode.hides(connectionID:path:)`이면 `canPaste(into:)`는 false, `paste(into:using:onCompletion:)`는 항목 이름 없이 일반 오류 문구를 띄우고 시작하지 않습니다(같은 저장소·다른 저장소 공통). 모드 변경 없이 담은 뒤 비공개로 바뀐 경우도 막습니다. 새 UI 컨트롤은 없습니다.
- 새 `CrossStorageTransfer.coversStoredTree(_:)`(원본이 폰하드 연결일 때만): `SharedInbox.records()`의 원시 manifest 메타데이터를 `offMainActor`에서 읽고, 선택 루트의 `storedFilename`과 같거나 그 아래(`루트/` 접두사)인 기록을 `LocalInboxFileService.browserItem(for:)`로 바꾼 뒤, 스냅샷 트리(루트 + 모든 하위)와 **개수·id가 정확히 같고 `sameMetadata`가 같은지** 비교합니다. 숨겨진 하위나 목록에 없는 항목, 중복, 불일치가 하나라도 있으면 false입니다. manifest를 읽지 못하면 오류 내용을 전하지 않고 false로 처리합니다(숨김 이름이 들어 있을 수 있기 때문). 파일 내용은 읽지 않습니다.
  - `transferRoot`: 스냅샷 직후, 대상 목록 읽기나 쓰기 **전에** 확인합니다. 실패하면 기존 문구 "`<루트 이름>`: 원본 목록을 읽지 못했습니다."만 남기고 그 루트를 실패로 처리합니다(복사·이동 공통, 원본 유지, 클립보드에 남음).
  - `unchangedTree`: 1차·2차 모두 `sameTree` 다음에 같은 확인을 거칩니다. 실패하면 nil → 기존 `keptMessage`로 원본을 유지하고 `delete(recursive:)`를 부르지 않습니다. 파일 루트의 비교 결과는 이전과 같습니다(`sameMetadata` + 자식 0개).
  - 프라이버시 모드에서 만든 서비스는 비공개를 포함해 전부 나열하므로 일치합니다. 일반 모드에서 공개 항목만 있는 폴더도 일치하므로 그대로 동작합니다(코드 읽기 기준).
  - 같은 저장소 copy/move 경로(`service.copy/move`)는 숨김 루트 거부 외에는 바꾸지 않았습니다. 새 서비스, 우회 권한, 프라이버시 완화는 없습니다.

### 남은 한계 (정직한 기록)
- **TOCTOU**: 2차 `unchangedTree`(+ manifest 확인)와 `SharedInbox.delete` 사이에 다른 프로세스(공유 확장, 로컬 웹하드)가 하위 항목을 추가하거나 비공개로 바꾸면 막지 못합니다. 조건부 삭제가 없기 때문입니다. 폰하드 manifest는 프로세스 잠금 아래에서 읽지만, 확인과 삭제는 같은 잠금 구간이 아닙니다.
- `hides`는 `PrivacyMode`의 메모리 스냅샷(`setPrivatePhoneHard`)을 씁니다. `SharedInboxStore`가 스냅샷을 갱신하기 전의 짧은 간격에는 막 비공개로 바꾼 항목을 놓칠 수 있습니다. 다만 다른 저장소로 보내는 전송은 manifest 확인이 따로 있습니다. 같은 저장소 붙여넣기에는 이 manifest 확인이 없습니다.
- 다른 저장소(NAS 등)가 원본이면 manifest 확인을 하지 않습니다. 비공개 연결 자체는 `hides`로 막지만, NAS 쪽 목록이 무엇을 빠뜨리는지는 백엔드 동작에 맡깁니다.
- `SharedInbox.records()`는 기존 `list`와 같이 reconcile 결과를 manifest에 다시 쓸 수 있습니다(기존 동작, 메타데이터만).
- 모드 전환 시 클립보드를 비우는 것은 이 앱 프로세스의 메모리에서만 일어납니다. 이미 시작한 작업은 끝까지 진행합니다(의도된 기존 의미).
- **빌드·테스트 미실행.** Swift 6에서 `sink` 클로저의 MainActor 상속, `guard …, try await …` 조건, `offMainActor` 제네릭 추론이 경고 없이 컴파일되는지는 TM의 최종 빌드로 확인해야 합니다.

### 이번 차례 무결성 확인
- 편집 뒤 다음 구간을 다시 읽었습니다: `SharedFileClipboard` 전체, `canPaste`, `paste` 시작부, `hasHiddenOrigin`, `transferRoot` 스냅샷 직후, `unchangedTree`, `coversStoredTree`, `items(in:)`. 다시 읽으면서 두 가지를 직접 고쳤습니다. (1) `unchangedTree`에서 처음 쓴 삼항 연산자 안 `try await`(Swift에서 허용되지 않음)를 `if/else` 대입으로 바꿨습니다. (2) `transferRoot`의 `do/catch`를 없애고 manifest 오류를 `coversStoredTree` 안에서 이름 없이 false로 처리하게 바꿨습니다.
- 도구 사용 정정: 정의 위치를 찾느라 읽기 전용 `grep`을 셸(Bash)로 한 번 실행했습니다(지시 위반). 두 번째 셸 호출은 권한 단계에서 거부되어 실행되지 않았습니다. 그 뒤로는 기본 파일 도구만 썼습니다. 빌드·테스트·Git·네트워크는 쓰지 않았습니다.
