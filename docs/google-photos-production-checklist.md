# Google Photos 정식 운영 체크리스트

기준일: 2026-08-21

이 문서는 Google OAuth의 7일 재인증을 없애고 NasFinder의 `Google 포토에서 가져오기`를 정식 운영하기 위해 필요한 준비·구현·검증·제출 항목을 한곳에 모은 실행 체크리스트다. Google Cloud 설정 변경, OAuth 검증 제출과 앱 배포는 대표님의 별도 승인 후 수행한다.

## 1. 현재 확인된 상태

- `https://nasfinder.com`, NasFinder 제품 페이지, 개인정보처리방침, Google API 고지, 데이터 삭제, 지원 페이지가 공개되어 있으며 2026-08-21 확인 시 모두 HTTP 200으로 응답했다.
- 홈페이지 소스에는 NasFinder 전용 개인정보처리방침, Google API Limited Use 고지, 데이터 삭제와 지원 경로가 준비되어 있다.
- iOS 앱에는 Google Drive용 OAuth 구성과 Authorization Code + PKCE 흐름이 있다.
- 현재 Google OAuth 구성은 Drive 권한(`openid`, `email`, `profile`, `drive`)을 요청하며, Google Photos Picker 전용 구현은 아직 없다.
- `Info.plist`에는 기존 Google Drive용 client ID와 URL scheme이 들어 있다. Google Photos를 별도 프로젝트·client로 운영하려면 별도 구성 키와 callback scheme이 필요하다.
- Google Photos 도입 설계는 `docs/google-photos-rollout.md`에 준비되어 있으나 앱 코드, 테스트, 실제 Google Cloud 프로젝트와 검증 제출은 시작 전이다.

## 2. 일주일 재인증의 직접 원인

External OAuth 앱의 Publishing status가 `Testing`이면 기본 신원 범위를 제외한 권한의 승인은 7일 뒤 만료되고, offline access로 받은 refresh token도 함께 만료된다. 따라서 계속 유지되는 연결을 만들려면 다음 상태가 필요하다.

1. 운영용 Google Cloud 프로젝트를 개발·테스트 프로젝트와 분리한다.
2. Audience를 External로 구성한다.
3. Branding과 Data Access 정보를 실제 공개 앱과 일치시킨다.
4. Publishing status를 Published/Production으로 전환한다.
5. Google Photos API가 요구하는 OAuth 검증을 완료한다.

Production 전환 뒤에도 사용자의 직접 철회, 6개월 미사용, 토큰 발급 한도, 조직 정책 등으로 refresh token이 무효화될 수 있으므로 앱은 `invalid_grant` 재로그인을 정상 상태로 처리해야 한다.

## 3. 확정할 Cloud 구조

Google 정책은 개발·테스트·운영 환경의 프로젝트 분리를 요구한다. Google Drive와 Google Photos까지 서로 다른 운영 프로젝트로 나누는 것은 정책상 필수라고 단정하지 않되, NasFinder에서는 다음 이유로 분리를 권장한다.

- Photos는 `photospicker.mediaitems.readonly` 하나만 요청해 심사 범위를 최소화할 수 있다.
- Photos 연결 해제와 토큰 철회가 기존 Drive 연결에 영향을 주지 않는다.
- Photos 기능·브랜딩·데모·정책 고지를 독립적으로 검증할 수 있다.
- 테스트 client와 운영 client가 빌드에서 섞일 위험을 줄인다.

권장 프로젝트 구성:

- `NasFinder Photos Development`: 테스트 사용자와 개발 빌드 전용
- `NasFinder Photos Production`: 공개 앱과 OAuth 검증 전용
- 기존 Google Drive 프로젝트: 현 상태를 별도로 확인하고 Photos 범위를 추가하지 않음

## 4. 대표님 계정에서 필요한 값

다음 값은 추측하지 않고 Google Cloud·App Store Connect의 실제 화면에서 확인한다.

- 운영 프로젝트 이름과 Project ID
- 사용자 지원 이메일
- 개발자 연락 이메일
- iOS Bundle ID: 현재 확인값 `com.armsone.nasfinder`
- Apple Team ID: 현재 프로젝트 확인값 `T7B4EPLHPK`
- App Store ID
- 운영용 iOS OAuth client ID
- Google Cloud가 생성한 redirect URI 또는 reversed client ID scheme
- Search Console에서 `nasfinder.com` 소유권을 확인할 프로젝트 Owner/Editor 계정
- OAuth Data Access 화면에서 표시되는 Picker scope 분류와 실제 검증 항목

## 5. Google Cloud 준비 순서

- [ ] 개발용·운영용 프로젝트를 구분한다.
- [ ] 운영 프로젝트에서 Google Photos Picker API를 활성화한다.
- [ ] Audience를 External로 설정한다.
- [ ] 앱 이름을 홈페이지·앱·제출 영상과 동일한 `NasFinder`로 맞춘다.
- [ ] NasFinder 고유 로고를 등록하고 Google 상표나 Google Photos 로고를 앱 로고에 포함하지 않는다.
- [ ] 홈페이지 URL을 `https://nasfinder.com/apps/nasfinder`로 확정한다.
- [ ] 개인정보처리방침 URL을 `https://nasfinder.com/apps/nasfinder/privacy`로 확정한다.
- [ ] 이용약관 URL을 `https://nasfinder.com/apps/nasfinder/terms`로 확정한다.
- [ ] 지원 URL을 `https://nasfinder.com/apps/nasfinder/support`로 준비한다.
- [ ] 데이터 삭제 URL을 `https://nasfinder.com/apps/nasfinder/data-deletion`로 준비한다.
- [ ] Google API 영문 고지 URL을 `https://nasfinder.com/apps/nasfinder/google-oauth`로 준비한다.
- [ ] Authorized domain에 `nasfinder.com`을 등록한다.
- [ ] 프로젝트 Owner/Editor 계정으로 Search Console Domain Property 소유권을 확인한다.
- [ ] iOS OAuth client를 실제 Bundle ID·Team ID·App Store ID로 만든다.
- [ ] Data Access에는 아래 Picker scope 하나만 추가한다.

```text
https://www.googleapis.com/auth/photospicker.mediaitems.readonly
```

- [ ] 개발 프로젝트의 client ID와 토큰이 운영 빌드에 포함되지 않는지 확인한다.
- [ ] Published/Production 전환 전에 홈페이지와 앱 고지가 실제 구현과 일치하는지 다시 검토한다.
- [ ] Branding을 검증·게시한 뒤 필요한 Data Access 검증을 제출한다.

## 6. 앱 구현 게이트

- [ ] Google Drive 연결 모델과 분리된 Photos 전용 OAuth 구성·토큰 저장소를 만든다.
- [ ] OAuth 직전에 앱 본문에서 데이터 접근·사용·로컬 저장·NAS 전송·삭제를 고지한다.
- [ ] 고지는 설정 메뉴 안에만 두지 않고 동의 요청 바로 전에 정상 흐름으로 표시한다.
- [ ] 사용자가 `계속`을 누르기 전에는 OAuth나 데이터 수집을 시작하지 않는다.
- [ ] 시스템 인증 세션과 Authorization Code + PKCE를 사용한다.
- [ ] `state` 검증, S256 challenge, offline access와 refresh 처리, 취소 처리를 구현한다.
- [ ] Picker session 생성·권장 polling interval·timeout·pagination·session 삭제를 구현한다.
- [ ] 사용자가 Picker에서 직접 고른 항목만 가져온다.
- [ ] 사진·동영상 base URL 요청에 Bearer token을 포함하고 60분 유효기간을 고려한다.
- [ ] 다운로드는 임시 파일로 스트리밍하고 안전한 파일명·MIME·저장공간·부분 실패를 처리한다.
- [ ] 완료 파일은 기존 `SharedInboxStore.importDownloadedFile(...)` 경로로 편입한다.
- [ ] NAS 전송은 Picker 동의와 분리된 사용자의 명시적 후속 행동으로 유지한다.
- [ ] 설정에 `Google 포토 연결 해제`를 제공하고 Photos token만 철회·삭제한다.
- [ ] 가져온 로컬 파일과 외부로 내보낸 파일의 삭제 위치를 정확히 안내한다.
- [ ] token, authorization code, session ID, picker URI, base URL을 로그·분석에 남기지 않는다.

## 7. 홈페이지 최종 문구 게이트

현재 홈페이지는 Photos 기능을 `예정`으로 설명한다. 구현 전에는 이 상태를 유지하고, 검증 제출 직전에 실제 동작과 다음 항목을 정확히 맞춘다.

- 접근: Picker에서 사용자가 직접 선택한 사진·동영상만 접근
- 사용: 기기의 받은 파일로 가져와 미리보기·공유·삭제·사용자 요청 NAS 전송 제공
- 저장: 기기 로컬 저장과 임시 다운로드, 토큰의 Keychain 보관
- 공유: 사용자가 명시적으로 고른 NAS·외부 저장소·공유 대상에만 전송
- 삭제: 받은 파일·캐시 삭제, Photos 연결 해제와 Google 계정에서의 접근 철회
- 금지: 광고, 추적, 데이터 판매, 얼굴 분류, 일반 갤러리 재구현, AI 모델 학습에 사용하지 않음
- Limited Use: Google API Services User Data Policy와 Photos API 정책 준수 문구 유지

## 8. 검증 제출 자료

### Scope justification 초안

> NasFinder requests `photospicker.mediaitems.readonly` only when a user chooses “Import from Google Photos.” The user selects specific photos or videos in Google Photos Picker. NasFinder downloads only those selected items to the app's local Received Files storage so the user can preview, share, delete, or explicitly transfer them to a NAS or another storage connection. NasFinder does not browse or recreate the user's complete Google Photos library and does not use Google Photos data for advertising, tracking, face recognition, data sale, or AI model training.

### 제출 영상 순서

1. 로그인 없이 공개되는 NasFinder 홈페이지 표시
2. 동일 도메인의 개인정보처리방침·Google API 고지·데이터 삭제 페이지 표시
3. 실제 제출 빌드의 앱명·아이콘 표시
4. 받은 파일에서 `Google 포토에서 가져오기` 선택
5. 앱 내부 사전 고지 전체와 사용자의 `계속` 동작 표시
6. Google OAuth 동의 화면과 정확한 scope 표시
7. Google Photos Picker에서 사진·동영상 선택
8. 앱 복귀, 다운로드 진행, 받은 파일 편입 표시
9. 미리보기와 사용자 행동에 의한 NAS 전송 표시
10. 로컬 파일 삭제와 Google 포토 연결 해제 표시

영상은 운영 client, 운영 scope와 제출 빌드를 사용하고 중요한 동의 단계를 편집으로 생략하지 않는다.

## 9. 검증 범위

- 단위: OAuth state·PKCE·token refresh, Picker 모델 decoding, pagination, URL 구성, MIME·파일명 검증, 오류·backoff, 부분 성공
- 통합: URLProtocol 기반 OAuth·Picker·다운로드, SharedInbox 원자적 편입, 취소·실패 임시 파일 정리, Photos token만 연결 해제
- 실기기: 실제 Google 계정, Picker 앱/웹 경로, 앱 복귀, 사진·동영상, 대용량 취소, 저장공간 부족, VoiceOver·Dynamic Type·iPad 방향 전환
- 최종 후보: 관련 테스트와 기기 빌드 후 영향 범위가 넓으면 전체 테스트 1회

## 10. 공식 기준 자료

- [Google OAuth 2.0 개요와 7일 테스트 토큰 만료](https://developers.google.com/identity/protocols/oauth2)
- [Google OAuth 앱 상태 비교](https://developers.google.com/identity/protocols/oauth2/production-readiness/overview)
- [Google OAuth 정책](https://developers.google.com/identity/protocols/oauth2/policies)
- [Google OAuth 검증 요건](https://support.google.com/cloud/answer/13464321)
- [Google OAuth 검증 제출 절차](https://support.google.com/cloud/answer/13461325)
- [Google Photos API 권한](https://developers.google.com/photos/overview/authorization)
- [Google Photos Picker session](https://developers.google.com/photos/picker/guides/sessions)
- [Google Photos Picker media item](https://developers.google.com/photos/picker/guides/media-items)
- [Photos API User Data and Developer Policy](https://developers.google.com/photos/support/api-policy)
