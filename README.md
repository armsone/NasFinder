# NasFinder

NasFinder는 iPhone에서 Synology NAS와 SFTP 서버의 파일을 탐색하고, 사진·영상 썸네일과 미리보기를 제공하며, Apple 파일 앱의 위치로 연결하는 네이티브 SwiftUI 앱입니다.

## 현재 MVP

- Synology DSM File Station API 로그인, 공유 폴더/파일 목록, 파일 다운로드
- 목록·작은 썸네일·큰 썸네일 보기와 이름·종류·크기·수정일 정보
- Synology 서버 썸네일 우선 사용, SFTP/HTTP 대체 경로의 사진·영상·PDF 로컬 썸네일
- 사진·영상 전체화면 연속 미리보기와 세로/가로 회전
- 사진 핀치 확대·패닝·더블 탭 원래 배율·스와이프 닫기
- 영상 드래그 탐색, 전체 반복·임의 재생·한 항목 반복, 즉시 공유
- ImageIO 다운샘플링 사진 표시와 비미디어 Quick Look
- 원격 파일을 내려받은 뒤 iOS 공유 시트로 내보내기
- Share Extension으로 다른 앱의 사진·영상·Live Photo·일반 파일을 최대 50개까지 받기
- App Group `SharedInbox`의 받은 파일 미리보기·재공유·삭제
- 서버 연결 정보를 App Group에 저장하고 비밀번호는 Keychain에 분리 저장
- 연결별 `NSFileProviderDomain` 등록
- 파일 앱에서 Synology/SFTP 원격 폴더 열거와 파일 다운로드
- Citadel 기반 SFTP 비밀번호 인증과 SHA-256 SSH 호스트 키 고정
- 폴더 생성, 이름 변경, 삭제, 업로드, 복사·이동과 충돌 처리
- SFTP 영상 범위 읽기 기반 빠른 썸네일과 앱 내 스트리밍 재생
- Wi-Fi·충전 중 현재 폴더 또는 하위 폴더의 썸네일 미리 생성
- 저장된 네트워크 위치의 사용자 지정 순서 변경
- 7일/512MB 제한 다운로드 캐시

## 실행 준비

1. 최초 clone 또는 `Package.resolved` 변경 뒤 한 번 `make packages`를 실행합니다. Swift 패키지는 저장소의 `.build` 아래에 캐시되며 이후 명령줄 빌드는 GitHub를 다시 조회하지 않습니다. Codex에서는 Xcode가 내부 `sandbox-exec`를 사용하므로 이 준비 명령만 범위를 제한해 샌드박스 밖에서 실행합니다.
2. `NasFinder.xcodeproj`를 Xcode에서 엽니다.
3. 현재 서명 Team은 `T7B4EPLHPK`, 앱 번들 ID는 `com.armsone.nasfinder`로 설정되어 있습니다. 다른 개발자 계정에서는 앱·File Provider·Share·테스트 타깃을 해당 계정 값으로 바꿉니다.
4. Developer Portal에서 `group.com.armsone.nasfinder` App Group을 앱과 Share/File Provider 확장에 등록합니다.
5. 실기기에서 로컬 네트워크 권한을 허용합니다.

명령줄 빌드와 테스트는 `scripts/xcodebuild_project.sh`를 사용합니다. 이 래퍼는 `Package.resolved`의 버전만 허용하고 프로젝트 로컬 패키지 체크아웃을 재사용합니다. 패키지 캐시가 준비된 뒤 일반 빌드에서는 자동 패키지 해석을 비활성화합니다.

Synology 연결에는 QuickConnect ID가 아닌, 기기에서 접근 가능한 DDNS/도메인 또는 VPN 주소가 필요합니다. 외부 연결은 신뢰할 수 있는 HTTPS 인증서를 사용하세요.

## 작업 보존과 검증된 실기기 설치

저장소를 처음 받은 뒤 Git 훅을 활성화합니다.

```sh
make hooks
```

이 훅은 미커밋 변경이 있거나 일반 브랜치에 포함되지 않은 Codex 스냅샷이 남아 있으면 `git push`를 중단합니다. 현재 상태는 다음 명령으로 언제든 검사할 수 있습니다.

```sh
make guard
```

사용자에게 전달할 실기기 앱은 직접 `xcodebuild` 또는 `devicectl`로 설치하지 않습니다. 모든 변경을 커밋하고 GitHub upstream에 푸시한 뒤 다음 단일 명령을 사용합니다.

```sh
make install-verified DEVICE_ID=<device-identifier>
```

이 명령은 작업 폴더가 깨끗한지, Codex 스냅샷이 브랜치에 보존됐는지, 로컬과 GitHub가 정확히 같은 커밋인지 확인합니다. 그다음 전체 테스트, 기기용 서명 빌드, 기본·보조 앱 아이콘 번들 검증, 설치와 실행을 순서대로 수행하며 어느 단계든 실패하면 설치를 중단합니다.

## 구조

- `NasFinder/`: SwiftUI 앱, 원격 파일 모델, Synology/SFTP 서비스, 미리보기
- `NasFinderShared/`: 앱과 Share Extension이 공유하는 받은 파일 보관함과 manifest
- `NasFinderShare/`: iOS 공유 시트에서 NasFinder로 파일을 받는 확장
- `NasFinderFileProvider/`: 파일 앱용 Replicated File Provider 확장
- `NasFinderTests/`: 모델과 연결 동작 테스트

파일 앱용 File Provider는 현재 원격 파일 열람·다운로드 중심으로 동작합니다. SFTP 키 인증과 Synology OTP 로그인, File Provider 쓰기 동기화는 다음 단계입니다. 실제 NAS/SFTP 환경의 네트워크 E2E 검증도 출시 전에 필요합니다.
