# NasFinder 수퍼 썸네일 동기화 보고

- 시작: 2026-08-25 12:50:59 KST
- 종료: 2026-08-25 13:16:49 KST
- 경과: 25분 50초
- 그룹: `nasfinder` — Apple `/Users/armsone/git/NasFinder`, Android `/Users/armsone/git/NasFinder-Android`
- 공통 릴리스 후보: 제품 버전 `2.1.1`, 표시 빌드 `202608251305`; Android 내부 코드 `340625`

## 실제 동기화 표

| 기능 | Mac 수퍼 썸네일 | iPhone/iPad | Android 휴대전화·태블릿·TV | 판정 |
|---|---|---|---|---|
| NAS 수퍼 썸네일 우선 표시 | 생성 결과를 실제 `.NasFinder-Vault`에서 최대 60개 지연 로딩 | NAS Vault → 기기 수퍼 캐시 → 휴대폰 표준 캐시 → 원격 생성 | NAS Vault 전용 메모리·디스크 키 → 휴대폰 표준 캐시 → 원격 생성 | 소스·단위 테스트 동일, 실제 NAS 다기기 추적 필요 |
| 이어하기/새로하기 | 하단에 나란히 배치. 새로하기는 선택 루트 안의 `.NasFinder-Vault`만 확인 후 삭제하고 재생성 | 기존 생성·이어하기 흐름 유지 | 저장된 결과 소비 우선순위만 변경 | Mac 실제 UI 확인 |
| 미리보기 접기/펼치기 | 휴대폰과 같은 공개형 미리보기 영역, 선택 상태 저장, 접근성 이름 제공 | 기존 수퍼 썸네일 화면 유지 | 기존 보기 종류와 소비 경로 유지 | Mac 실제 UI 확인 |
| 원본 보존 | 선택 루트 경계·심볼릭 링크 검증 후 Vault 디렉터리만 삭제 | 원본 삭제 없음 | 읽기 우선순위 변경만 수행 | 테스트 통과 |

## 검증

| 대상 | 결과 |
|---|---|
| Mac helper | SwiftPM 16 tests, 0 failures; universal 앱 빌드·Developer ID 서명·notarization·설치 성공; 실제 화면에서 미리보기 접기/펼치기, 새로하기 확인창 검증 |
| iPhone/iPad | `SuperThumbnailVaultTests` 12 tests, 0 failures; Release archive 2.1.1(202608251305) 및 App Store Connect 업로드 성공 |
| Android | 우선순위·캐시·직접 업데이트 JVM 테스트 통과; `assembleReleaseQa` 성공; 서명·package·version·SHA-256 검증 후 SM-F968N에 데이터 유지 설치·실행 성공 |

## Matchup 장부 게이트

장부 구조는 유효하지만 전체 39행 중 35행이 열려 있어 `--gate`는 실패했다. 이번 수퍼 썸네일 8단계도 소스·단위 테스트 근거는 추가됐으나, 잠긴 Android 기기와 실제 NAS fixture 부재로 화면·콜드 캐시·실패 복구 추적은 완료하지 않았다. 따라서 전체 플랫폼의 렌더링 동기화 완료로 판정하지 않는다.

## 오류와 해결

| 단계 | 오류 | 원인 | 조치 | 결과 |
|---|---|---|---|---|
| Mac 테스트 | 임시 경로 `/var`와 `/private/var` 비교 실패 | macOS 경로 정규화 차이 | canonical URL로 비교 | 통과 |
| Apple 테스트 컴파일 | CryptoKit import와 async 호출 누락 | 신규 fixture 테스트 선언 누락 | import 및 `try await` 적용 | 통과 |
| Android 테스트 컴파일 | 존재하지 않는 `removedFiles` 참조 | 캐시 결과 필드명 불일치 | `removedFileCount` 사용 | 통과 |
| Android 화면 캡처 | 검은 화면 | 실기기 키가 잠긴 상태 | 설치·실행·버전만 검증하고 캡처를 근거에서 제외 | 런타임 시각 검증 남음 |

## 남은 검증

- 실제 NAS의 같은 파일에 Mac 수퍼 썸네일과 휴대폰 표준 썸네일이 함께 있을 때 iPhone/iPad/Android에서 Vault 이미지가 선택되는 네트워크 추적
- Android 잠금 해제 상태의 휴대전화·태블릿·Google TV 대표 화면과 콜드 캐시 재실행 근거
- 이 미완료 근거 때문에 동기화 그룹의 마지막 검증 HEAD는 갱신하지 않는다.
