#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
    echo "error: usage: $0 <device-identifier>" >&2
    exit 2
fi

device_identifier="$1"
repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"

"$repository_root/scripts/repository_guard.sh" install

verified_sha="$(git rev-parse HEAD)"
short_sha="$(git rev-parse --short=12 HEAD)"
derived_data="/tmp/NasFinder-verified-$short_sha"
simulator_name="${NASFINDER_SIMULATOR_NAME:-iPhone 17 Pro}"
project="NasFinder.xcodeproj"
scheme="NasFinder"
bundle_identifier="com.armsone.nasfinder"

echo "[1/5] Running the complete test suite at $verified_sha"
xcodebuild -quiet \
    -project "$project" \
    -scheme "$scheme" \
    -destination "platform=iOS Simulator,name=$simulator_name" \
    -derivedDataPath "$derived_data-simulator" \
    test

[[ "$(git rev-parse HEAD)" == "$verified_sha" ]] || {
    echo "error: 테스트 중 HEAD가 변경됐습니다." >&2
    exit 1
}
[[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] || {
    echo "error: 테스트 중 작업 폴더가 변경됐습니다." >&2
    exit 1
}

echo "[2/5] Building the signed device app"
xcodebuild -quiet \
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

[[ "$actual_bundle_identifier" == "$bundle_identifier" ]] || {
    echo "error: 잘못된 bundle identifier: $actual_bundle_identifier" >&2
    exit 1
}
[[ "$primary_icon" == "AppIcon" && "$alternate_icon" == "AppIconAlternate" ]] || {
    echo "error: 기본 또는 보조 앱 아이콘 등록이 빠졌습니다." >&2
    exit 1
}
asset_info="$(xcrun assetutil --info "$assets_car")"
grep -q '"Name" : "AppIcon"' <<< "$asset_info"
grep -q '"Name" : "AppIconAlternate"' <<< "$asset_info"

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
