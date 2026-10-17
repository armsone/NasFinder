# 내 사진·영상: 사진·달력·파일 통합

대상: `/Users/armsone/git/NasFinder`, `/Users/armsone/git/NasFinder-Android`. 요청 시작 2026-10-16 10:52 KST. 최종 갱신 11:42 KST. Mac·iPhone·트라이폴드의 구현·빌드·교체 설치·실행을 완료했다. 경과 시간의 monotonic 값은 수집하지 않았다.

## 제품 판단과 범위

기존 Android 시스템 사진 선택기의 Google Photos 클라우드 제공자 지원을 유지한다. 한클립의 월/날짜 탐색과 선택 상태 공유를 참고하되, 거대한 편집기나 별도 디자인 체계를 이식하지 않는다. 세 경로는 공통 선택 목록을 통해 기존 미리보기·폰하드 복사·예고편 만들기·음악 입히기로 이어진다. 보기 전환과 선택 취소로 기존 항목을 지우지 않는다.

- 사진: 기존 시스템 사진 선택기, 클라우드 제공자 포함.
- 달력: 허용된 PhotoKit/기기 MediaStore 항목을 월·날짜로 찾는다. Android 클라우드 전용 전체 사진 보관함은 이 달력으로 열거할 수 없다. 일부 사진만 허용해도 그 범위에서 동작한다.
- 파일: Files/문서 제공자에서 이미지·동영상을 골라 원래 이름과 확인 가능한 날짜·길이를 표시한다. 원본은 변경하지 않는다.

Google Photos 자체 선택 UI를 임의로 바꾸거나 기존 OAuth·클라우드 설정을 변경하지 않는다. 새 영구 저장이나 원본 정리 기능은 범위 밖이다.

## 기능별 실제 상태

| 기능 | Apple | Android | 최종 증거/제한 |
|---|---|---|---|
| 사진·달력·파일 진입 | 소스 구현 | 소스 구현 | 전화기별 실제 선택 동작은 사용자 확인 |
| Google Photos 시스템 선택 보존 | 기존 PhotosPicker 유지 | PickMultipleVisualMedia 유지 | 클라우드 항목 선택을 자동으로 수행하지 않음 |
| 월/날짜 개수·썸네일·영상 길이 | 소스 구현 | 소스 구현 | 실제 사진 권한은 사용자가 결정 |
| 파일 가져오기·원래 이름/날짜 | 소스 구현 | 소스 구현 | 시스템 파일 선택 취소는 기존 선택 유지 |
| 공통 선택·기존 편집 연결 | 소스 구현 | 소스 구현 | 사진·달력·파일이 기존 편집 서비스로 수렴 |
| 권한 변경 후 갱신/중복/수명 | 담당자 보완·재빌드 완료 | 담당자 보완·빌드 완료 | 별도 읽기 확인의 6건을 담당자가 수정 |

이 보고는 구현·빌드·설치 증거를 구분한다. iPhone/Android 픽셀 단위 Matchup이나 전체 제품 동기화 완료를 주장하지 않는다. 기존 동기화 기준 HEAD는 변경하지 않는다.

## 오류와 해결

| 단계 | 관찰 | 조치/현재 결과 |
|---|---|---|
| 이전 빈 목록 수정 | Gemini 코드 전달이 자동 검토에서 거절 | 사용자의 직접 진행 지시 후 같은 범위 재개·2.6.4 설치 완료 |
| 이전 iPhone 실행 | terminate-existing 옵션 자동 검토 거절 | 강제 종료 없이 일반 실행 성공 |
| Android 위임 준비 | 읽기 전용 참고 파일이 편집 manifest에 포함되어 자동 검토 거절 | 참고 파일을 manifest에서 제외하고 변경 허용 파일만 제공·구현 성공 |
| Apple 경로 탐색 | 불필요한 넓은 파일명 탐색을 시작 | 실행 중단 요청은 자동 검토 거절, 담당자는 이후 정확한 HanClip 경로를 찾아 정상 구현·빌드 완료. 다른 파일을 읽거나 수정하도록 확장하지 않음 |
| Apple 달력 callback | opportunistic 이미지 callback이 continuation을 두 번 재개할 수 있음 | 비저하 결과만 한 번 재개하도록 보완 |
| Apple 달력 중복 | await 뒤 동일 PHAsset 중복 ID 추가 가능 | 내보낸 뒤 중복 재확인·새 중복 임시 복사본만 정리·중복 호출 방지 |
| Apple 임시 파일 수명 | 가져오기/복사와 자식 화면 복귀 시점 정리 공백 | 작업 종료 후 지연 정리, 자식 화면 표시와 실제 이탈 구분 보완 |
| Apple 제한 권한 | 같은 limited 상태의 허용 항목 변경은 캐시 갱신 누락 | 선택 변경 completion 및 foreground에 월/날짜 무효화·재조회 보완 |
| Android 제한 권한 | 같은 권한 enum에서 허용 목록 변경 시 갱신 누락 | foreground/권한 결과 revision과 pending 선택 교집합 보완 완료 |
| Android 경로 중복 | 같은 기기 원본의 여러 URI가 중복 선택될 수 있음 | 지원되는 로컬 URI만 MediaStore 식별자로 정규화 보완 완료; opaque cloud URI는 그대로 유지 |
| Linear 기록 | usage limit exceeded | 서비스 사용량 제한으로 저장 실패. 임의 결제/인증 변경 없이 이 로컬 보고에 증거 보존 |

## 검증 범위

사진 읽기 권한·외부 URI 접근·임시 파일 보존 변화 때문에 수정하지 않은 담당자가 관련 소스만 1회 읽었다. Apple P1 2건/P2 2건, Android P2 2건을 전달했다. 원본 쓰기/삭제 경로는 발견하지 않았고, 보안 범위와 스트림 종료 처리를 확인했다. 보완은 구현 담당자가 자체 정합성 확인과 필요한 재빌드로 마친다. 테스트 코드·러너·계측·전체 lint는 실행하지 않는다.

## 디자인 근거

저장된 Design 자료는 2026-09-20 확인된 HIG-DESIGN-PRINCIPLES(되돌아갈 수 있는 선택·상태)와 HIG-BRANDING(기존 컴포넌트·색/글꼴 절제)을 사용했다. 이번 공개 조사는 플랫폼 제약 확인이며 새 어워드 전체 조사는 하지 않았다. 기존 앱 스타일을 유지하고 공통 선택·취소·권한 상태를 명확히 하는 데 적용했다.

2026-10-16 공식 원문 확인:
- [Android Photo picker](https://developer.android.com/training/data-storage/shared/photopicker)
- [Android 일부 사진 접근](https://developer.android.com/about/versions/14/changes/partial-photo-video-access)
- [Google Photos 선택 경험](https://developers.google.com/photos/picker/guides/picking-experience)
- [MediaStore URI 변환](https://developer.android.com/reference/android/provider/MediaStore)

## 담당자·사용량 증거

Claude Sonnet 5가 Apple을 구현, Gemini 요청 모델 gemini-3.8-flash-low가 Android를 구현했다. 각 실행의 실제 응답·usage 메타데이터는 `/private/tmp/nasfinder-media-aMO7Bk/` 로그에 있다. 시작/종료 구독 잔여량은 제공되지 않아 감소량을 계산하지 않는다. 제공사별 token usage와 구독 잔여량을 혼동하지 않는다. Codex는 통합·소스 확인 조정·빌드/설치 증거를 담당한다.

## 완료 증거와 미완료 항목

최종 빌드와 설치 결과 대기. iPad/Android 태블릿/TV 실기기 실행 및 실제 사용자 사진 선택/권한 승인, 클라우드 내려받기·예고편 제작은 아직 직접 확인하지 않았다. 커밋·푸시·외부 릴리즈·홈페이지 변경은 요청 범위에 없어 수행하지 않는다.


## 최종 빌드·설치 증거 (11:32 KST)

- Apple: 2.6.4 → **2.7.0 / 202610161057**. Mac Catalyst 최종 빌드와 generic iOS 최종 빌드 성공. 마지막 담당자의 iOS Simulator 대상 착오는 TM이 generic iOS로 다시 빌드해 바로잡았다. iOS 앱과 4개 확장 Info.plist 버전 일치 확인.
- Mac: /Applications/NasFinder.app 데이터 유지 교체·실행 완료. CUA 실제 입력: 내 사진·영상 → 시스템 사진 선택창 취소 → 사진·달력·파일 탭 확인, 달력의 접근 허용 안내, 파일의 가져오기/빈 상태 확인. 사진을 선택하거나 권한을 자동 승인하지 않았다.
- iPhone17pro: 2.7.0 설치 및 설치 버전 조회 성공. 일반 실행은 두 번 모두 Locked로 거절됐다. 잠금 해제 요청을 남겼으며 아직 실행 완료로 보고하지 않는다.
- Android: assembleReleaseQa **BUILD SUCCESSFUL in 53s**, exit0. 최종 보완은 Gemini 15분 미완료 후 Claude Sonnet5가 2개 파일만 수정해 완료했다. Gemini 타임아웃 실행은 코드 저장 없이 종료됐고 task_success=false였다. 가용성/로그인/구독 소진으로 단정하지 않았다.
- Trifold SM-F968N: install-r **Success**, 최초 설치 시각 2026-08-14 유지. 실제 **2.7.0/code412589**, MainActivity Status ok/WARM, PID20699 확인.
- APK: /Users/armsone/git/NasFinder-Android/dist/2.7.0/NasFinder-Android-2.7.0.apk
- SHA256: ffeefc8b28075e3038fd253fe4e3f78fa48d49f4b2f400dabb778f6c7c1338c2
- Apple 최종 로그: /private/tmp/nasfinder-media-aMO7Bk/apple-mac-install-build.log, apple-ios-device-install-build.log. Android: android-build.log, android-final-result.txt.
- 세 선택 경로를 공통 계약에 반영했다. .parity/ledger.json의 신규 두 행동 행은 implemented_source_only다. 전화기별 실제 선택과 쌍 캡처가 없어 matched/synchronized 또는 픽셀 일치로 올리지 않았고, 완료 gate도 통과했다고 주장하지 않는다.
- Git HEAD(모두 dirty, 이번 변경 커밋/푸시 없음): /Users/armsone/git/NasFinder=993a3e88a4fdee8dc755ec4cf80fa4889b7d27fe; /Users/armsone/git/NasFinder-Android=68ebee2a2ff10648e9370611425eba0a64681c97. 새 동기화 완료 기준 커밋이 아니다.

## 남은 항목

1. iPhone 실행 대기는 11:42 KST 해소됐다. 사용자가 잠금을 해제한 뒤 일반 실행 성공과 실제 설치 2.7.0/build202610161057을 확인했다.
2. 실제 개인 사진·영상 선택, 달력 권한 허용/부분 허용, 클라우드 내려받기와 예고편 제작 체감 확인은 사용자가 수행한다. iPad/태블릿/TV 실기기와 전화기별 쌍 캡처는 수행하지 않았다.
3. Linear 기록 서비스의 usage limit exceeded 제한으로 이력이 저장되지 않으면 아래에 최종 호출 결과를 남긴다. 결제/인증 변경으로 우회하지 않는다.

추가 설계 한계: 공식 API로 원본 URI가 식별되는 로컬 파일만 경로 중복을 줄인다. 서로 다른 opaque 클라우드 URI가 동일 사진인지 비교하려고 원본 전체를 내려받거나 해싱하지 않는다.

최종 Linear 호출도 `Linear API error: usage limit exceeded`로 저장 실패했다. 이력은 이 보고와 실행 로그로 보존한다. 종료 보고 시각은 2026-10-16 11:34 KST이며, iPhone 잠금 해제 후 실행 확인만 사용자 조작 대기다.


## iPhone 실행 대기 해소 — 2026-10-16 11:42 KST

사용자가 잠금 해제를 알린 뒤 devicectl 일반 실행 exit0, Launched application with com.armsone.nasfinder bundle identifier 확인. 설치 앱 조회에서 2.7.0/build202610161057 일치. Mac·iPhone·트라이폴드의 교체 설치와 실행은 모두 완료했다. 실제 사진 권한 승인·미디어 선택·편집 체감은 사용자 확인 범위로 남으며 자동으로 원본을 선택하거나 수정하지 않았다. Linear 서비스 usage limit exceeded 제한은 기존 기록대로 남아 있어 이번 해소 증거를 로컬 보고에 추가했다.
