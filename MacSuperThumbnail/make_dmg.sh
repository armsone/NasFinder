#!/bin/zsh
set -euo pipefail

package_root="${0:A:h}"
app_path="${1:-${package_root}/dist/NasFinder Super Thumbnail.app}"
version="${APP_VERSION:-2.1.1}"
dist_dir="${package_root}/dist"
dmg_path="${dist_dir}/NasFinder-Super-Thumbnail-${version}.dmg"
staging_dir="$(mktemp -d)"
trap 'rm -rf -- "${staging_dir}"' EXIT

if [[ ! -d "${app_path}" ]]; then
  print -u2 "앱 번들을 찾지 못했습니다: ${app_path}"
  exit 1
fi

mkdir -p "${dist_dir}"
ditto "${app_path}" "${staging_dir}/$(basename "${app_path}")"
ln -s /Applications "${staging_dir}/Applications"

rm -f -- "${dmg_path}"
hdiutil create -volname "NasFinder Super Thumbnail" \
  -srcfolder "${staging_dir}" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "${dmg_path}"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "${SIGN_IDENTITY}" "${dmg_path}"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "${dmg_path}" --keychain-profile "${NOTARY_PROFILE}" --wait
  xcrun stapler staple "${dmg_path}"
  xcrun stapler staple "${app_path}"
  xcrun stapler validate "${dmg_path}"
  xcrun stapler validate "${app_path}"
  spctl --assess --type open --context context:primary-signature --verbose=4 "${dmg_path}"
  spctl --assess --type execute --verbose=4 "${app_path}"
fi

print "완료: ${dmg_path}"
