# Google 포토 네트워크 관리 및 Dropbox 계정 표시

## 후속 수정 — 2026-10-16 22:15 KST

- 사용자 지시로 Google 포토를 모든 플랫폼에서 Browser 바로 위로 통일했다. Android는 이미 해당 순서였고 Apple의 네트워크 연결 목록 뒤로 행을 이동했다.
- Google 포토 행 아래 설명글을 Apple/Android 모두 제거했다. 아이콘·이름·점 세 개 메뉴 유지, Dropbox 등 다른 연결의 계정 부제는 유지.
- 최종 Apple **2.9.5/202610162213**, Android **2.9.2/code412593/202610162213**. iOS/Mac Catalyst/assembleReleaseQa 빌드 성공, 세 기기 데이터 유지 교체 설치·재실행 및 실제 설치 버전 확인. Mac 서명 검증 성공.
- Mac AX 및 Trifold 실제 화면에서 순서와 설명글 제거 확인. iPhone은 설치·재실행 확인 후 사용자 연결 추가 화면이 열려 있어 조작하지 않았다. Apple 공통 뷰 소스 반영 확인과 iPhone 화면의 직접 확인을 구분한다.
- 사용자 요청으로 트라이폴드 미러링 창을 맥에 열어 두었다. 테스트·커밋·푸시 없음. Linear 기록은 앞선 두 번의 실제 호출에서 확인한 workspace free issue limit으로 로컬 보존.

2026-10-16 21:56–22:07 KST, Codex TM. 범위: NasFinder Apple / NasFinder-Android의 이번 네트워크 메뉴 변경. 기존 dirty 작업 보존, 커밋·푸시·공개 릴리즈 없음.

## 실제 반영과 근거

| 기능 | Apple | Android | 확인 범위 |
| --- | --- | --- | --- |
| Google 포토 네트워크 행 | 기존 테마·아이콘·제목/부제·점 세 개 | 기존 ConnectionRow 재사용 | iPhone/Mac/Trifold 실제 표시와 메뉴 열림 확인 |
| 관리 위치 통합 | 표시 이름 수정·명시적 재연결·연결 삭제; 네트워크 추가에서 재추가 | 표시 이름 수정·시스템 선택창 계정 확인·위치 삭제; 네트워크 추가에서 복원 | iPhone/Android 수정창과 취소 확인; 실제 연결 삭제/재인증은 수행하지 않음 |
| 설정 중복 제거 | GooglePhotosSettingsSection 호출 제거 | Settings 별도 Google 블록 제거 | 담당자 소스 무결성 확인 |
| Dropbox 계정 | 기존 토큰으로 get_current_account 이메일/이름 조회 | 같은 API를 기존 토큰 경로로 조회 | iPhone에서 실제 계정 이메일 표시 확인. Mac/Android는 현재 Dropbox 저장 연결이 없어 계정 조회 실동작 미확인 |
| 중복명 제거 | 제목과 같은 서비스 배지 숨김, host 대신 계정 표시 | 같은 처리 | iPhone Dropbox 반복명 제거 확인 |
| 인증 경합 보존 | 조회용 refresh 비영구, 결과에 연결/credential snapshot 검사; 일반 refresh 비교/저장 | 조회용 refresh 비영구, token/manual/connection snapshot; 공용 lock의 조건부 토큰 저장 | 독립 읽기 검토에서 발견 후 해당 보호 구간 확인 |

Apple Google 포토 삭제는 기존 Photos 전용 인증 해제를 사용하며 폰하드·Drive Keychain·웹 쿠키는 직접 변경하지 않는다. Android는 시스템 Google 계정을 앱이 해제하는 것처럼 표시하지 않고 앱의 위치 항목만 숨긴다. 기존 미디어 선택·제작 경로 유지.

## 빌드·설치

- Apple: 2.9.2 → **2.9.3 / 202610162205**, iOS 및 Mac Catalyst 최종 BUILD SUCCEEDED. iPhone 17 Pro와 `/Applications/NasFinder.app` 교체 설치·재실행, 설치 제품 버전 확인. Mac codesign deep/strict 검증 exit0.
- Android: 2.9.0 → **2.9.1 / 412592 / 202610162205**, 최종 assembleReleaseQa BUILD SUCCESSFUL. 기존 무선 연결의 SM-F968N에 install -r Success, MainActivity 재실행과 dumpsys 설치 버전 확인.
- 테스트 러너 미실행. 빌드가 포함하는 기본 lintVital 단계는 별도 정적 분석 호출 없이 실행됨.
- 빌드 로그: `/private/tmp/nasfinder-media-fix-20261016/apple-ios-cloud-menu-final-build.log`, `apple-mac-cloud-menu-build.log`, `android-cloud-menu-final-build.log`.

## 오류와 처리

| 단계 | 관찰 | 처리/결과 |
| --- | --- | --- |
| Android 연결 진단 | 샌드박스에서 adb listener 접근 거절 | 정식 elevated 경로에서 기존 무선 연결 확인, 새 페어링/주소 요청 없이 설치 성공 |
| 독립 안전 검토 | 계정 조회 중 삭제·재연결 시 늦은 refresh 결과가 이전 인증을 복원/덮을 가능성 | 양쪽 조건부 저장 및 조회 snapshot 보완, 최종 재빌드 성공 |
| Linear 이력 | 실제 팀 조회 성공, 기록 2회 모두 free issue limit HTTP400 | 결제/계정 설정 변경하지 않고 이 로컬 보고에 보존 |

## 미확인 범위

기존 실사용 계정의 실제 삭제·재인증과 재추가는 계정 보호를 위해 실행하지 않았다. 해당 동작은 소스 구현/읽기 검토 범위이며 사용자 실사용 확인이 남는다. Mac/Android Dropbox 계정 조회는 저장된 대상 연결이 없어 실기기 미확인. 전체 픽셀 매치업/모든 기기 레이아웃 일치·전체 제품 동기화는 이번 완료 주장에 포함하지 않는다.

로컬 구현 담당 두 명과 안전 검토 한 명이 참여했고 모델별 사용량 수치는 제공되지 않아 산정하지 않았다. TM은 빌드·설치·기기 메뉴 및 iPhone 실제 계정 표시를 확인했다.
