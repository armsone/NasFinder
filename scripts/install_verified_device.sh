#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
    echo "error: usage: $0 <device-identifier>" >&2
    exit 2
fi

device_identifier="$1"
test_only="${TEST_ONLY:-}"
full_tests="${FULL_TESTS:-0}"
repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"

"$repository_root/scripts/repository_guard.sh" install

verified_sha="$(git rev-parse HEAD)"
short_sha="$(git rev-parse --short=12 HEAD)"
source_state_file="$(mktemp)"
trap 'rm -f "$source_state_file"' EXIT
git status --porcelain=v1 --untracked-files=all > "$source_state_file"
derived_data="/tmp/NasFinder-verified-$short_sha"
project="NasFinder.xcodeproj"
scheme="NasFinder"
bundle_identifier="com.armsone.nasfinder"

skip_tests="${SKIP_TESTS:-0}"
if [[ "$skip_tests" != "0" && "$skip_tests" != "1" ]]; then
    echo "error: SKIP_TESTS는 0 또는 1이어야 합니다." >&2
    exit 2
fi
if [[ "$skip_tests" == "1" && ( -n "$test_only" || "$full_tests" == "1" ) ]]; then
    echo "error: SKIP_TESTS=1은 TEST_ONLY 또는 FULL_TESTS=1과 함께 사용할 수 없습니다." >&2
    exit 2
fi

if [[ "$device_identifier" == "mac" ]]; then
    if [[ "$skip_tests" != "1" ]]; then
        echo "error: Mac 설치는 SKIP_TESTS=1을 명시해야 합니다(테스트 모드는 지원하지 않습니다)." >&2
        exit 2
    fi
    mac_derived_data="${NASFINDER_MAC_DERIVED_DATA:-$repository_root/.build/verified-mac}"
    mac_target="/Applications/NasFinder.app"
    mac_app="$mac_derived_data/Build/Products/Debug-maccatalyst/NasFinder.app"
    mac_work=""
    trap 'rm -f "$source_state_file"; if [[ -n "$mac_work" && "$mac_work" == /* && -d "$mac_work" ]]; then rm -rf "$mac_work"; fi' EXIT

    mac_source_guard() {
        [[ "$(git rev-parse HEAD)" == "$verified_sha" ]] || {
            echo "error: HEAD가 변경됐습니다($1)." >&2
            return 1
        }
        cmp -s "$source_state_file" <(git status --porcelain=v1 --untracked-files=all) || {
            echo "error: 소스 상태가 변경됐습니다($1)." >&2
            return 1
        }
    }
    mac_plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
    mac_verify_bundle() {
        local bundle="$1" label="$2" id version build appex
        [[ -d "$bundle" && -f "$bundle/Contents/Info.plist" && -d "$bundle/Contents/Resources" \
            && -f "$bundle/Contents/Resources/Assets.car" ]] || {
            echo "error: $label 앱 번들 구성이 올바르지 않습니다: $bundle" >&2
            return 1
        }
        /usr/bin/codesign --verify --deep --strict "$bundle" || {
            echo "error: $label 코드 서명 검증 실패" >&2
            return 1
        }
        id="$(mac_plist "$bundle" CFBundleIdentifier)"
        version="$(mac_plist "$bundle" CFBundleShortVersionString)"
        build="$(mac_plist "$bundle" CFBundleVersion)"
        [[ "$id" == "$bundle_identifier" ]] || {
            echo "error: $label 잘못된 bundle identifier: $id" >&2
            return 1
        }
        if [[ -n "${NASFINDER_EXPECTED_VERSION:-}" && "$version" != "$NASFINDER_EXPECTED_VERSION" ]]; then
            echo "error: $label 버전 불일치: $version != $NASFINDER_EXPECTED_VERSION" >&2
            return 1
        fi
        if [[ -n "${NASFINDER_EXPECTED_BUILD:-}" && "$build" != "$NASFINDER_EXPECTED_BUILD" ]]; then
            echo "error: $label 빌드 불일치: $build != $NASFINDER_EXPECTED_BUILD" >&2
            return 1
        fi
        for appex in "$bundle"/Contents/PlugIns/*.appex; do
            [[ -d "$appex" ]] || continue
            [[ "$(mac_plist "$appex" CFBundleShortVersionString)" == "$version" \
                && "$(mac_plist "$appex" CFBundleVersion)" == "$build" ]] || {
                echo "error: $label 확장 버전이 앱과 다릅니다: $appex" >&2
                return 1
            }
        done
        mac_verified_version="$version"
        mac_verified_build="$build"
    }

    echo "[1/5] Tests skipped by user (SKIP_TESTS=1); building the Mac Catalyst app"
    "$repository_root/scripts/xcodebuild_project.sh" \
        -project "$project" \
        -scheme "$scheme" \
        -destination "platform=macOS,variant=Mac Catalyst,arch=arm64" \
        -derivedDataPath "$mac_derived_data" \
        build

    echo "[2/5] Verifying the built app before touching the installed one"
    mac_source_guard "빌드 후"
    mac_verify_bundle "$mac_app" "빌드된"
    built_version="$mac_verified_version"
    built_build="$mac_verified_build"

    mac_work="$(mktemp -d "${TMPDIR:-/tmp}/nasfinder-mac-install.XXXXXX")"
    [[ "$mac_work" == /* ]] || { echo "error: 작업 경로가 절대 경로가 아닙니다." >&2; exit 1; }
    mac_stage="$mac_work/stage-NasFinder"
    mac_backup="$mac_work/backup-NasFinder"
    /usr/bin/ditto "$mac_app" "$mac_stage"
    mac_verify_bundle "$mac_stage" "스테이징된"

    echo "[3/5] Checking that NasFinder is not running"
    if pgrep -x NasFinder > /dev/null; then
        echo "error: NasFinder가 실행 중입니다. 종료한 뒤 다시 실행하세요(프로세스를 강제 종료하지 않습니다)." >&2
        exit 1
    fi

    echo "[4/5] Replacing $mac_target (backup: $mac_backup)"
    mac_source_guard "설치 직전"
    had_previous=0
    if [[ -e "$mac_target" ]]; then
        had_previous=1
        mv "$mac_target" "$mac_backup"
    fi
    mac_rollback() {
        echo "error: 설치 실패, 이전 앱으로 되돌립니다." >&2
        rm -rf "$mac_target"
        if [[ "$had_previous" == "1" && -e "$mac_backup" ]]; then
            mv "$mac_backup" "$mac_target"
        fi
    }
    /usr/bin/ditto "$mac_stage" "$mac_target" || { mac_rollback; exit 1; }
    mac_verify_bundle "$mac_target" "설치된" || { mac_rollback; exit 1; }
    [[ "$mac_verified_version" == "$built_version" && "$mac_verified_build" == "$built_build" ]] || {
        mac_rollback
        echo "error: 설치된 버전이 빌드와 다릅니다." >&2
        exit 1
    }
    mac_source_guard "설치 직후" || { mac_rollback; exit 1; }

    echo "[5/5] Launching the installed app"
    open "$mac_target" || { mac_rollback; exit 1; }

    echo "Verified install complete"
    echo "commit: $verified_sha"
    echo "device: mac"
    echo "version: $built_version ($built_build)"
    echo "backup: $mac_backup"
    # 백업은 롤백 근거로 남기고 스테이징 사본만 지운다.
    rm -rf "$mac_stage"
    mac_work=""
    exit 0
fi

if [[ "$skip_tests" == "1" ]]; then
    echo "[1/5] Tests skipped by user (SKIP_TESTS=1)"
else
    test_arguments=()
    if [[ "$full_tests" == "1" ]]; then
        echo "[1/5] Running the complete test suite on device $device_identifier at $verified_sha"
    elif [[ -n "$test_only" ]]; then
        IFS=',' read -r -a test_selectors <<< "$test_only"
        for selector in "${test_selectors[@]}"; do
            [[ -n "$selector" ]] || continue
            test_arguments+=("-only-testing:$selector")
        done
        [[ ${#test_arguments[@]} -gt 0 ]] || {
            echo "error: TEST_ONLY에 하나 이상의 테스트 선택자를 지정해 주세요." >&2
            exit 2
        }
        echo "[1/5] Running related device tests: $test_only"
    else
        echo "error: 관련 테스트는 TEST_ONLY=<target/test>로, 전체 테스트는 FULL_TESTS=1로 지정해 주세요." >&2
        exit 2
    fi

    test_command=(
        "$repository_root/scripts/xcodebuild_project.sh"
        -project "$project"
        -scheme "$scheme"
        -destination "id=$device_identifier"
        -derivedDataPath "$derived_data-device-tests"
        -allowProvisioningUpdates
        test
    )
    if [[ ${#test_arguments[@]} -gt 0 ]]; then
        test_command+=("${test_arguments[@]}")
    fi
    "${test_command[@]}"

    # Device test products include the full VLCKit framework and can consume
    # several gigabytes. They are no longer needed once the selected tests pass;
    # release them before producing the separately signed install build.
    rm -rf "$derived_data-device-tests"
fi

[[ "$(git rev-parse HEAD)" == "$verified_sha" ]] || {
    echo "error: 테스트 중 HEAD가 변경됐습니다." >&2
    exit 1
}
cmp -s "$source_state_file" <(git status --porcelain=v1 --untracked-files=all) || {
    echo "error: 테스트 중 소스 상태가 변경됐습니다." >&2
    exit 1
}

echo "[2/5] Building the signed device app"
"$repository_root/scripts/xcodebuild_project.sh" \
    -project "$project" \
    -scheme "$scheme" \
    -destination "id=$device_identifier" \
    -derivedDataPath "$derived_data-device" \
    -allowProvisioningUpdates \
    build

app_path="$derived_data-device/Build/Products/Debug-iphoneos/NasFinder.app"
info_plist="$app_path/Info.plist"
assets_car="$app_path/Assets.car"

[[ -d "$app_path" && -f "$info_plist" && -f "$assets_car" ]] || {
    echo "error: 완성된 앱 번들을 찾을 수 없습니다: $app_path" >&2
    exit 1
}

echo "[3/5] Verifying bundle identity and app icons"
actual_bundle_identifier="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist"
)"
primary_icon="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' \
        "$info_plist"
)"
alternate_icon="$(
    /usr/libexec/PlistBuddy -c \
        'Print :CFBundleIcons:CFBundleAlternateIcons:AppIconAlternate:CFBundleIconName' \
        "$info_plist"
)"
vibe_coder_icon="$(
    /usr/libexec/PlistBuddy -c \
        'Print :CFBundleIcons:CFBundleAlternateIcons:AppIconVibeCoder:CFBundleIconName' \
        "$info_plist"
)"
cyber_vault_icon="$(
    /usr/libexec/PlistBuddy -c \
        'Print :CFBundleIcons:CFBundleAlternateIcons:AppIconCyberVault:CFBundleIconName' \
        "$info_plist"
)"
network_nas_icon="$(
    /usr/libexec/PlistBuddy -c \
        'Print :CFBundleIcons:CFBundleAlternateIcons:AppIconNetworkNAS:CFBundleIconName' \
        "$info_plist"
)"
enamel_icon="$(
    /usr/libexec/PlistBuddy -c \
        'Print :CFBundleIcons:CFBundleAlternateIcons:AppIconEnamel:CFBundleIconName' \
        "$info_plist"
)"

[[ "$actual_bundle_identifier" == "$bundle_identifier" ]] || {
    echo "error: 잘못된 bundle identifier: $actual_bundle_identifier" >&2
    exit 1
}
[[ "$primary_icon" == "AppIcon" \
    && "$alternate_icon" == "AppIconAlternate" \
    && "$vibe_coder_icon" == "AppIconVibeCoder" \
    && "$cyber_vault_icon" == "AppIconCyberVault" \
    && "$network_nas_icon" == "AppIconNetworkNAS" \
    && "$enamel_icon" == "AppIconEnamel" ]] || {
    echo "error: 기본 또는 보조 앱 아이콘 등록이 빠졌습니다." >&2
    exit 1
}
asset_info="$(xcrun assetutil --info "$assets_car")"
grep -q '"Name" : "AppIcon"' <<< "$asset_info"
grep -q '"Name" : "AppIconAlternate"' <<< "$asset_info"
grep -q '"Name" : "AppIconVibeCoder"' <<< "$asset_info"
grep -q '"Name" : "AppIconCyberVault"' <<< "$asset_info"
grep -q '"Name" : "AppIconNetworkNAS"' <<< "$asset_info"
grep -q '"Name" : "AppIconEnamel"' <<< "$asset_info"

[[ "$(git rev-parse HEAD)" == "$verified_sha" ]] || {
    echo "error: 빌드 중 HEAD가 변경됐습니다." >&2
    exit 1
}

echo "[4/5] Installing verified commit $verified_sha"
xcrun devicectl device install app \
    --device "$device_identifier" \
    "$app_path"

echo "[5/5] Launching the installed app"
xcrun devicectl device process launch \
    --terminate-existing \
    --device "$device_identifier" \
    "$bundle_identifier"

echo "Verified install complete"
echo "commit: $verified_sha"
echo "device: $device_identifier"
