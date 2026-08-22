#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
package_checkout_dir="${NASFINDER_SOURCE_PACKAGES_DIR:-$repository_root/.build/xcode-source-packages}"
package_cache_dir="${NASFINDER_PACKAGE_CACHE_DIR:-$repository_root/.build/xcode-package-cache}"
tool_cache_dir="$repository_root/.build/xcode-tool-cache"
xcodebuild_lock="$tool_cache_dir/xcodebuild.lock"

mkdir -p \
    "$package_checkout_dir" \
    "$package_cache_dir" \
    "$tool_cache_dir/clang-module-cache" \
    "$tool_cache_dir/swiftpm-module-cache" \
    "$tool_cache_dir/xdg-cache"

export CLANG_MODULE_CACHE_PATH="$tool_cache_dir/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$tool_cache_dir/swiftpm-module-cache"
export XDG_CACHE_HOME="$tool_cache_dir/xdg-cache"

package_arguments=(
    -clonedSourcePackagesDirPath "$package_checkout_dir"
    -packageCachePath "$package_cache_dir"
    -onlyUsePackageVersionsFromResolvedFile
    -skipPackageUpdates
)

# Dependency resolution is an explicit preparation step. Normal builds must
# reuse the locked, project-local package checkout without contacting GitHub.
if [[ "${1:-}" != "-resolvePackageDependencies" ]]; then
    package_arguments+=(-disableAutomaticPackageResolution)
else
    # Foundation falls back to ~/Library/Caches when the macOS sandbox blocks
    # DARWIN_USER_CACHE_DIR. Redirect that fallback only for manifest loading;
    # normal signed builds keep the real user home and provisioning profiles.
    package_resolution_home="$tool_cache_dir/package-resolution-home"
    mkdir -p "$package_resolution_home/Library/Caches"
    export CFFIXED_USER_HOME="$package_resolution_home"
fi

# Package resolution and builds share the same checkout. Serialize wrapper
# users so concurrent Codex tasks cannot deadlock SwiftPM's package graph.
if ! /usr/bin/lockf -s -t 0 -k "$xcodebuild_lock" true; then
    echo "Waiting for another NasFinder xcodebuild process to finish..." >&2
fi

exec /usr/bin/lockf -t 900 -k "$xcodebuild_lock" \
    xcodebuild "${package_arguments[@]}" "$@"
