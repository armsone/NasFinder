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
    "$repository_root/scripts/xcodebuild_project.sh" -quiet
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

[[ "$(git rev-parse HEAD)" == "$verified_sha" ]] || {
    echo "error: 테스트 중 HEAD가 변경됐습니다." >&2
    exit 1
}
cmp -s "$source_state_file" <(git status --porcelain=v1 --untracked-files=all) || {
    echo "error: 테스트 중 소스 상태가 변경됐습니다." >&2
    exit 1
}

echo "[2/5] Building the signed device app"
"$repository_root/scripts/xcodebuild_project.sh" -quiet \
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

[[ "$actual_bundle_identifier" == "$bundle_identifier" ]] || {
    echo "error: 잘못된 bundle identifier: $actual_bundle_identifier" >&2
    exit 1
}
[[ "$primary_icon" == "AppIcon" \
    && "$alternate_icon" == "AppIconAlternate" \
    && "$vibe_coder_icon" == "AppIconVibeCoder" \
    && "$cyber_vault_icon" == "AppIconCyberVault" \
    && "$network_nas_icon" == "AppIconNetworkNAS" ]] || {
    echo "error: 기본 또는 보조 앱 아이콘 등록이 빠졌습니다." >&2
    exit 1
}
asset_info="$(xcrun assetutil --info "$assets_car")"
grep -q '"Name" : "AppIcon"' <<< "$asset_info"
grep -q '"Name" : "AppIconAlternate"' <<< "$asset_info"
grep -q '"Name" : "AppIconVibeCoder"' <<< "$asset_info"
grep -q '"Name" : "AppIconCyberVault"' <<< "$asset_info"
grep -q '"Name" : "AppIconNetworkNAS"' <<< "$asset_info"

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
