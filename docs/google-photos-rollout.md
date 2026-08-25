# Google Photos 정식 도입 준비서

기준일: 2026-08-15

이 문서는 `nasfinder.com` 공개와 Google 도메인 확인이 끝난 뒤 NasFinder에 Google Photos Picker를 안전하게 도입하기 위한 실행 기준이다. 현재 단계에서는 앱 구현, Google Cloud 설정, OAuth 검증 제출을 시작하지 않는다.

## 1. 확정된 제품 범위

- 기능명: `Google 포토에서 가져오기`
- 사용자는 Google Photos 화면에서 사진·동영상을 직접 선택한다.
- NasFinder는 사용자가 고른 항목만 기기로 다운로드한다.
- 다운로드가 끝난 항목은 기존 `받은 파일`에 보관한다.
- 사용자가 다시 명시적으로 선택한 경우에만 기존 `NAS로 보내기` 흐름으로 전송한다.
- Google Photos 전체 보관함, 앨범 목록 또는 검색 결과를 NasFinder가 자체 탐색 화면으로 재구현하지 않는다.
- Google Photos에서 업로드, 편집, 삭제 또는 앨범 관리는 이번 범위에 포함하지 않는다.
- 광고, 사용자 프로파일링, 얼굴 분류, AI 학습에 Google Photos 데이터를 사용하지 않는다.

Google 정책상 제한된 항목을 사용자가 직접 고르는 기능은 Picker API를 사용해야 한다. 일반 사진 갤러리나 Google Photos 대체 서비스로 구현해서는 안 된다.

## 2. 현재 코드와의 통합 결정

### UI 위치

`ConnectionKind`나 `AddConnectionView`에 Google Photos를 추가하지 않는다. Picker는 지속적으로 탐색하는 원격 파일 시스템이 아니기 때문이다.

권장 진입점은 다음 두 곳이다.

1. `ReceivedFilesView` 빈 화면의 `Google 포토에서 가져오기` 버튼
2. 파일이 있을 때 `ReceivedFilesView` 상단 메뉴의 같은 작업

대시보드에는 별도 대형 카드보다 `받은 파일` 경로 안에서 발견할 수 있는 조용한 보조 행동을 우선한다.

### 기존 코드 재사용

- 다운로드 완료 파일 편입: `SharedInboxStore.importDownloadedFile(...)`
- 내구 저장소: `SharedInbox`
- 미리보기·공유·삭제: `ReceivedFilesView`와 `LocalInboxFileService`
- NAS 전송: `InboxUploadDestinationView`와 `FileOperationCoordinator`
- OAuth 토큰 저장 방식: `KeychainCredentialStore`의 ThisDeviceOnly 정책을 유지하되 Google Photos 전용 항목으로 분리

### 분리해야 할 코드

- `GooglePhotosOAuthConfiguration`
- `GooglePhotosAuthorizationService`
- `GooglePhotosPickerClient`
- `GooglePhotosImportCoordinator`
- Picker 세션·미디어 응답용 `Decodable` 모델
- 사용자에게 보이는 연결 상태와 가져오기 진행 상태

기존 `CloudDriveFileService`와 Google Drive 연결 모델에는 Picker 책임을 넣지 않는다.

## 3. Google Cloud 구성

Google Drive와 Google Photos는 별도 Google Cloud 프로젝트로 운영한다.

이유:

- Photos는 최소 Picker 권한만 요청할 수 있다.
- Photos 연결 해제 시 OAuth revoke가 기존 Drive 권한까지 함께 취소되는 것을 피한다.
- Google 심사 범위와 데모를 Photos 기능으로 한정할 수 있다.
- Drive의 광범위한 권한과 Photos 정책 변경을 서로 격리한다.

프로덕션 프로젝트 체크리스트:

- 프로젝트 표시명과 연락처 확정
- Google Photos Picker API 활성화
- iOS OAuth client 생성
  - Bundle ID: `com.armsone.nasfinder`
  - App Store ID와 Apple Team ID는 실제 값 확인 후 입력
  - 가능하면 iOS App Check 적용 여부 검토
- OAuth client ID를 앱 설정에 추가
- reversed client ID URL scheme 추가
- OAuth 동의 화면의 홈페이지·개인정보처리방침·지원 이메일 입력
- Authorized domain에 `nasfinder.com` 등록
- Google Search Console의 Domain Property 방식으로 DNS TXT 소유권 확인
- Scope는 아래 하나만 요청

```text
https://www.googleapis.com/auth/photospicker.mediaitems.readonly
```

개발·심사용 테스트 프로젝트와 프로덕션 프로젝트는 분리한다. 테스트 프로젝트의 client ID나 토큰을 프로덕션 빌드에 포함하지 않는다.

## 4. OAuth 설계

- iOS installed-app OAuth 2.0 Authorization Code + PKCE를 사용한다.
- 시스템 인증 화면을 사용하고 embedded web view에서 Google 로그인 페이지를 열지 않는다.
- `state`를 매 요청마다 무작위 생성하고 callback과 일치하는지 확인한다.
- code verifier는 매 요청 새로 생성하고 S256 challenge를 사용한다.
- iOS OAuth client에는 client secret을 포함하지 않는다.
- `access_type=offline`으로 refresh token을 요청한다.
- 불필요한 `openid`, `email`, `profile` scope는 Photos 기능에 필요하지 않으면 요청하지 않는다.
- access token과 refresh token은 Keychain의 `AfterFirstUnlockThisDeviceOnly` 수준으로 저장한다.
- 로그, 오류 메시지, 분석 이벤트에 token, authorization code, picker URI, session ID, base URL을 남기지 않는다.
- refresh token은 만료·철회·6개월 미사용 등으로 무효화될 수 있으므로 `invalid_grant`에서만 재로그인을 요구한다.

### 연결 해제

설정 화면에 `Google 포토 연결 해제`를 제공한다.

1. 진행 중 Picker 세션 삭제 시도
2. Google OAuth revoke endpoint 호출
3. 성공 여부와 관계없이 기기의 Photos 전용 토큰과 세션 상태 제거
4. 이미 `받은 파일`로 가져온 로컬 파일은 자동 삭제하지 않음
5. 로컬 파일은 받은 파일 화면에서 사용자가 직접 삭제할 수 있음을 안내

별도 Cloud 프로젝트를 쓰면 revoke가 기존 Google Drive 연결을 해치지 않는다.

## 5. Picker 세션 흐름

API endpoint:

```text
https://photospicker.googleapis.com
```

정상 흐름:

1. 앱 내부에서 Google 데이터 접근·이용·보관·삭제 안내를 표시한다.
2. 사용자가 `계속`을 눌러 명시적으로 동의한 뒤에만 OAuth를 시작한다.
3. `POST /v1/sessions`로 세션을 만들고 `maxItemCount`를 50으로 설정한다.
4. 반환된 `id`, `pickerUri`, `expireTime`, `pollingConfig`를 보관한다.
5. `pickerUri`를 시스템에서 열어 Google Photos 선택 화면으로 이동한다.
6. 앱이 활성 상태일 때만 `pollInterval`을 존중해 `GET /v1/sessions/{id}`를 호출한다.
7. `mediaItemsSet=true`이면 모든 페이지의 `GET /v1/mediaItems?sessionId=...`를 읽는다.
8. 파일을 하나씩 작업 전용 임시 위치에 다운로드한다.
9. 각 파일이 완전히 내려받아진 뒤 `SharedInboxStore.importDownloadedFile`로 편입한다.
10. 성공·실패·건너뜀 수를 사용자에게 보여준다.
11. 미디어 바이트 확보 후 `DELETE /v1/sessions/{id}`로 세션을 정리한다.

세션은 앱 재활성화 후 이어갈 수 있도록 `id`, `expireTime`, 다음 폴링 시각만 로컬에 임시 보관한다. `pickerUri`와 base URL은 장기 보관하지 않는다. 만료되거나 취소된 세션은 제거한다.

## 6. 다운로드 규칙

- `PickedMediaItem.mediaFile.filename`은 표시용 후보일 뿐이며 기존 `SharedInbox`의 파일명 정제 절차를 반드시 통과한다.
- MIME type과 Picker의 `type`을 함께 검증한다.
- 사진 다운로드 URL: `baseUrl=d`
- 동영상 다운로드 URL: `baseUrl=dv`
- 모든 base URL 요청에 유효한 OAuth Bearer token을 넣는다.
- base URL은 보통 60분 동안만 유효하므로 선택 목록을 얻은 직후 다운로드한다.
- 동영상은 `processingStatus=READY`일 때 다운로드한다. 준비 중이면 제한적으로 다시 확인하거나 사용자에게 나중에 다시 선택하도록 안내한다.
- Google 문서상 `=d` 사진은 위치 메타데이터를 제외한 나머지 EXIF가 유지될 수 있음을 정책 문구와 UI에 과장 없이 반영한다.
- Picker 응답에 파일 크기가 없으므로 다운로드 전 전체 필요 공간을 정확히 예측할 수 있다고 표시하지 않는다.
- 응답의 `Content-Length`가 있으면 다운로드 전·중 여유 공간을 확인한다.
- 동영상과 대용량 파일은 메모리에 올리지 않고 임시 파일로 스트리밍 다운로드한다.
- 다운로드는 기본 직렬 처리하고 필요성이 확인된 경우에만 낮은 동시성으로 확대한다.
- 취소 시 현재 네트워크 작업과 아직 편입하지 않은 임시 파일만 제거한다.
- 일부 성공 뒤 실패하면 성공 파일은 받은 파일에 유지하고 실패 항목만 명확히 알린다.
- 동일 Picker media ID를 영구 사용자 식별자로 사용하지 않는다. 중복 가져오기는 기본적으로 허용하되 파일 충돌은 기존 UUID 저장명으로 안전하게 처리한다.

## 7. 앱 내 고지 초안

OAuth 직전 화면에 개인정보처리방침만 링크하는 것으로 끝내지 않고 다음 내용을 별도 안내한다.

> NasFinder는 Google 포토에서 사용자가 직접 선택한 사진과 동영상만 가져옵니다. 선택한 파일은 이 iPhone의 받은 파일에 저장되며, 사용자가 선택한 경우에만 NAS나 연결된 저장공간으로 전송됩니다. 광고, 사용자 추적, 얼굴 분류 또는 AI 학습에 사용하지 않습니다. 가져온 파일은 받은 파일 화면에서 삭제할 수 있고 Google 포토 연결은 설정에서 해제할 수 있습니다.

행동:

- 기본 버튼: `계속`
- 보조 버튼: `취소`
- 링크: `개인정보처리방침 보기`

Google Photos에서 NAS로 보내는 것은 외부 전송이므로 Picker 동의와 별개로 기존 `NAS로 보내기` 사용자 행동을 반드시 유지한다.

## 8. 홈페이지 공개 완료 게이트

다음 항목을 직접 확인하기 전에는 프로덕션 OAuth 검증을 제출하지 않는다.

- `https://nasfinder.com`이 HTTPS로 공개 접근 가능
- NasFinder 제품 페이지가 로그인 없이 열림
- 개인정보처리방침이 같은 도메인에서 열림
- 홈페이지에서 개인정보처리방침 링크를 쉽게 찾을 수 있음
- OAuth 동의 화면과 같은 앱명·로고를 사용
- Google Photos 데이터의 접근·사용·로컬 저장·NAS 전송·삭제·연결 해제 설명 포함
- Google Limited Use 준수 문구 포함
- 책임자 `한병기`와 실제 사용 가능한 지원 연락처 표시
- 데이터 삭제 안내 페이지가 실제 앱 동작과 일치
- Search Console에서 프로젝트 Owner/Editor 계정으로 Domain Property 소유권 확인

## 9. OAuth 검증 제출 자료

### Scope justification 초안

> NasFinder requests `photospicker.mediaitems.readonly` only when a user chooses “Import from Google Photos.” The user selects specific photos or videos in the Google Photos Picker. NasFinder downloads only those selected items to the app's local Received Files storage so the user can preview, share, delete, or explicitly transfer them to a NAS or another storage connection. NasFinder does not browse the user's full Google Photos library and does not use Photos data for advertising, tracking, face recognition, or AI model training.

### 데모 영상 순서

1. 공개 홈페이지와 개인정보처리방침 URL 표시
2. 실제 제출 빌드의 NasFinder 앱명·아이콘 표시
3. `받은 파일` → `Google 포토에서 가져오기`
4. 앱 내부 사전 고지 전체 표시
5. OAuth 동의 화면 언어를 English로 설정
6. 전체 동의 화면과 정확한 scope 표시
7. Google Photos Picker에서 사진과 동영상 선택
8. NasFinder 복귀와 다운로드 진행 표시
9. 받은 파일에서 미리보기
10. 사용자 행동으로 NAS 전송 화면 진입
11. 로컬 파일 삭제
12. 설정에서 Google 포토 연결 해제

영상에는 실제 client, 실제 앱 branding, 제출 scope와 동일한 화면만 사용한다. 편집으로 중요한 동의 단계를 생략하지 않는다.

## 10. 오류·경계 조건

구현과 테스트에서 최소한 다음을 다룬다.

- OAuth 사용자 취소
- callback state 불일치
- scope 미부여 또는 변경
- access token 만료와 refresh 성공
- refresh `invalid_grant` 후 재로그인
- Picker API 401, 403, 404, 429, 5xx
- session 만료·취소·앱 재실행 후 재개
- 사용자가 Google Photos에서 아무것도 선택하지 않고 돌아옴
- 권장 poll interval과 timeout 준수
- 여러 페이지의 미디어 목록
- 안전하지 않은 파일명·중복 파일명·지원하지 않는 MIME type
- 50개 혼합 사진·동영상
- 동영상 PROCESSING·FAILED 상태
- base URL 만료
- 네트워크 단절·백그라운드 전환·사용자 취소
- 저장공간 부족
- 일부 다운로드 성공 후 실패
- 받은 파일 편입 실패 시 임시 파일 정리
- 세션 삭제 실패는 기록하되 사용자 파일 성공을 되돌리지 않음
- 연결 해제가 기존 Google Drive 토큰에 영향을 주지 않음
- 앱 삭제·재설치 뒤 ThisDeviceOnly token이 복원되지 않음

## 11. 검증 범위

### 단위 테스트

- Picker JSON decoding
- Google duration과 RFC 3339 parsing
- pagination
- photo/video download URL 생성
- filename과 MIME validation
- token refresh 및 `invalid_grant`
- HTTP 오류 매핑과 429 backoff
- 세션 상태 전이와 취소
- 부분 성공 결과 집계

### 통합 테스트

- URLProtocol 기반 OAuth·Picker·다운로드 응답
- 임시 파일에서 SharedInbox 원자적 편입
- 실패 시 임시 파일과 manifest 불일치 방지
- 연결 해제 시 Photos token만 제거

### 실기기 검증

- 실제 Google 계정 OAuth와 Picker 진입
- Google Photos 앱 설치/미설치 경로
- 앱 복귀와 세션 재개
- 사진·동영상 다운로드·미리보기·삭제
- NAS 한 곳으로 명시적 전송
- 대용량 동영상 취소와 저장공간 오류
- VoiceOver, Dynamic Type, 가로/세로 전환

인증·네트워크·대용량 파일 변경이므로 관련 회귀 테스트와 실기기 빌드가 필요하다. 전체 테스트는 최종 배포 후보에서 영향 범위가 넓다고 판단될 때 한 번 실행한다.

## 12. 구현 순서

1. 홈페이지 공개 게이트 확인
2. 테스트용 Google Cloud 프로젝트와 iOS client 준비
3. 앱 내부 사전 고지와 설정 화면 설계
4. Photos 전용 OAuth와 Keychain 저장 구현
5. Picker client와 세션 상태 머신 구현
6. 다운로드·SharedInbox 편입 구현
7. 연결 해제·revoke 구현
8. 단위·통합 테스트
9. 테스트 계정 실기기 E2E
10. 프로덕션 Cloud 프로젝트 구성
11. 홈페이지 문구와 실제 동작 최종 대조
12. OAuth 검증 영상 촬영·제출
13. 승인 후 최종 배포 후보 검증

## 13. 시작 시 필요한 값

홈페이지 공개 후 아래 값만 확인하면 구현을 바로 시작할 수 있다.

- NasFinder 제품 페이지 URL
- 개인정보처리방침 URL
- 데이터 삭제 안내 URL
- 실제 지원 이메일
- Google Cloud 테스트 프로젝트 ID
- 테스트용 iOS OAuth client ID
- 프로덕션 프로젝트 Owner/Editor 계정과 연락 이메일
- NasFinder App Store ID(있을 경우)

client secret, refresh token, DNS 계정 비밀번호 같은 비밀정보는 문서·Git·대화 메시지에 넣지 않는다.

## 14. 공식 참고 자료

- [Google Photos Picker REST API](https://developers.google.com/photos/picker/reference/rest)
- [Picker session 관리](https://developers.google.com/photos/picker/guides/sessions)
- [Picker media item 다운로드](https://developers.google.com/photos/picker/guides/media-items)
- [Photos API 사용자 데이터 정책](https://developers.google.com/photos/support/api-policy)
- [Photos API 권한](https://developers.google.com/photos/overview/authorization)
- [Photos API quota](https://developers.google.com/photos/overview/api-limits-quotas)
- [iOS·Desktop OAuth 2.0](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Google OAuth 검증 요구사항](https://support.google.com/cloud/answer/13464321)
- [Google OAuth 검증 제출](https://support.google.com/cloud/answer/13461325)
