# NasFinder Super Thumbnail Mac 릴리스 절차

## Sparkle EdDSA 키

Sparkle 업데이트 서명에는 EdDSA 키 쌍이 필요합니다.

1. Sparkle 2.9.4 릴리스(`https://github.com/sparkle-project/Sparkle/releases`)의 `Sparkle-2.9.4.tar.xz`를 내려받아 `bin/generate_keys`를 실행합니다.
2. `generate_keys`는 개인키를 실행 계정의 로그인 Keychain에 저장하고, 공개키를 표준 출력으로 보여줍니다.
3. 공개키를 `MacSuperThumbnail/Sparkle/sparkle_ed_public_key.txt`에 붙여넣고 커밋합니다. **공개키는 비밀이 아니므로 저장소에 커밋해도 안전합니다.**
4. 개인키는 절대 저장소나 CI 로그에 넣지 마세요. `generate_appcast`와 `sign_update`는 실행 시점에 로컬 Keychain에서 개인키를 직접 찾습니다.

공개키 파일을 저장소에 두면 어떤 빌드 머신에서든 `build_app.sh`가 추가 비밀 없이 `SUPublicEDKey`를 자동으로 채울 수 있다는 뜻입니다. 다만 appcast 서명(`make_appcast.sh`)은 개인키가 있는 Keychain을 가진 신뢰된 머신에서만 실행할 수 있어야 합니다. 여러 대의 빌드 머신을 쓴다면 개인키를 안전한 비밀 관리 도구로 옮기고, 필요할 때만 임시로 Keychain에 넣는 방식을 권장합니다.

## 빌드 순서

```sh
# 1. 유니버설 앱 빌드, Sparkle 프레임워크 임베드, Info.plist 업데이터 키 삽입, 서명
SIGN_IDENTITY="Developer ID Application: ..." \
APP_VERSION=1.0.0 \
BUILD_NUMBER="$(date '+%Y%m%d%H%M')" \
MacSuperThumbnail/build_app.sh

# 2. drag-to-Applications DMG 생성 (+ 서명 + 공증)
SIGN_IDENTITY="Developer ID Application: ..." \
NOTARY_PROFILE="notary-profile-name" \
APP_VERSION=1.0.0 \
MacSuperThumbnail/make_dmg.sh

# 3. 서명된 appcast 갱신
SPARKLE_BIN_DIR=/path/to/Sparkle-2.9.4/bin \
MacSuperThumbnail/make_appcast.sh
```

- `SIGN_IDENTITY`가 없으면 ad-hoc 서명(`codesign --sign -`)으로 로컬 실행만 가능한 빌드가 만들어지며, 이 경우 `SUPublicEDKey`가 없어도 빌드는 계속 진행되지만 경고만 출력합니다.
- `SIGN_IDENTITY`가 있는데 공개키가 없으면 `build_app.sh`는 공개 배포용 실수를 막기 위해 즉시 실패합니다.
- 공개 배포 아티팩트는 `NasFinder-Super-Thumbnail-<version>.dmg` 하나뿐이며, ZIP은 만들지 않습니다.
- `NOTARY_PROFILE`은 `xcrun notarytool store-credentials`로 미리 등록한 프로필 이름입니다.

## 앱의 업데이트 동작

- 시작 시 Sparkle이 `SUScheduledCheckInterval`(21600초 = 6시간) 주기로 자동 확인/설치를 시도합니다.
- 메뉴의 "업데이트 확인…" 항목으로 언제든 수동 확인이 가능합니다.
- 다운로드, 서명 검증, 앱 종료, 교체, 재실행은 모두 Sparkle의 표준 업데이트 흐름을 사용하며 커스텀 다운로더/설치기는 없습니다.
