#!/bin/zsh
set -euo pipefail

package_root="${0:A:h}"
repository_root="${package_root:h}"
build_root="${package_root}/.build-release"
output_app="${1:-${package_root}/dist/NasFinder Super Thumbnail.app}"
executable="${build_root}/arm64-apple-macosx/release/NasFinderSuperThumbnailMac"
icon_source="${repository_root}/NasFinder/Resources/Assets.xcassets/AppIconCyberVault.appiconset/AppIconCyberVault-1024.png"

CLANG_MODULE_CACHE_PATH="${build_root}/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="${build_root}/module-cache" \
swift build \
  -c release \
  --package-path "${package_root}" \
  --scratch-path "${build_root}" \
  --cache-path "${build_root}/cache" \
  --config-path "${build_root}/config" \
  --security-path "${build_root}/security" \
  --disable-sandbox

if [[ "${output_app}" != *.app || "${output_app}" == "/" ]]; then
  print -u2 "안전하지 않은 앱 출력 경로입니다: ${output_app}"
  exit 2
fi

rm -rf -- "${output_app}"
mkdir -p "${output_app}/Contents/MacOS" "${output_app}/Contents/Resources"
ditto "${executable}" "${output_app}/Contents/MacOS/NasFinderSuperThumbnailMac"
ditto "${icon_source}" "${output_app}/Contents/Resources/AppIcon.png"

info_plist="${output_app}/Contents/Info.plist"
plutil -create xml1 "${info_plist}"
plutil -insert CFBundleDevelopmentRegion -string ko "${info_plist}"
plutil -insert CFBundleDisplayName -string "NasFinder Super Thumbnail" "${info_plist}"
plutil -insert CFBundleExecutable -string NasFinderSuperThumbnailMac "${info_plist}"
plutil -insert CFBundleIconFile -string AppIcon.png "${info_plist}"
plutil -insert CFBundleIdentifier -string com.armsone.nasfinder.superthumbnail.mac "${info_plist}"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "${info_plist}"
plutil -insert CFBundleName -string "NasFinder Super Thumbnail" "${info_plist}"
plutil -insert CFBundlePackageType -string APPL "${info_plist}"
plutil -insert CFBundleShortVersionString -string "${APP_VERSION:-1.0.0}" "${info_plist}"
plutil -insert CFBundleVersion -string "${BUILD_NUMBER:-1}" "${info_plist}"
plutil -insert LSMinimumSystemVersion -string 14.0 "${info_plist}"
plutil -insert NSHighResolutionCapable -bool true "${info_plist}"
plutil -insert NSPrincipalClass -string NSApplication "${info_plist}"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${output_app}"
else
  codesign --force --deep --sign - "${output_app}"
fi

codesign --verify --deep --strict --verbose=2 "${output_app}"
print "완료: ${output_app}"
