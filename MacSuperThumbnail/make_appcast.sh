#!/bin/zsh
set -euo pipefail

package_root="${0:A:h}"
dist_dir="${package_root}/dist"
appcast_path="${dist_dir}/nasfinder-super-thumbnail.xml"
key_account="${SPARKLE_KEY_ACCOUNT:-NasFinderSuperThumbnail}"
app_version="${APP_VERSION:-2.0.0}"
download_url_prefix="${DOWNLOAD_URL_PREFIX:-https://github.com/armsone/NasFinder/releases/download/mac-super-thumbnail-v${app_version}/}"
release_notes_link="${RELEASE_NOTES_LINK:-https://github.com/armsone/NasFinder/releases/tag/mac-super-thumbnail-v${app_version}}"

if [[ -z "${SPARKLE_BIN_DIR:-}" || ! -x "${SPARKLE_BIN_DIR}/generate_appcast" ]]; then
  print -u2 "SPARKLE_BIN_DIR에 Sparkle 릴리스의 generate_appcast 도구 경로가 필요합니다."
  print -u2 "https://github.com/sparkle-project/Sparkle/releases 에서 Sparkle-2.9.4.tar.xz를 내려받아 압축을 풀고 bin 디렉터리를 지정하세요."
  exit 1
fi

# generate_appcast는 EdDSA 개인키를 로그인 Keychain에서 직접 찾아 서명한다.
# 이 스크립트는 Keychain 값을 읽거나 노출하지 않는다.
work_dir=$(mktemp -d "${dist_dir}/.appcast.XXXXXX")
trap 'rm -rf "${work_dir}"' EXIT
ditto "${dist_dir}/NasFinder-Super-Thumbnail-${app_version}.dmg" "${work_dir}/NasFinder-Super-Thumbnail-${app_version}.dmg"

"${SPARKLE_BIN_DIR}/generate_appcast" \
  --account "${key_account}" \
  --download-url-prefix "${download_url_prefix}" \
  --link "${release_notes_link}" \
  --maximum-deltas 0 \
  --maximum-versions 3 \
  -o "${appcast_path}" \
  "${work_dir}"

print "완료: ${appcast_path}"
