.PHONY: guard hooks packages install-verified

guard:
	./scripts/repository_guard.sh status

hooks:
	./scripts/install_git_hooks.sh

packages:
	./scripts/xcodebuild_project.sh -resolvePackageDependencies -project NasFinder.xcodeproj

install-verified:
	@test -n "$(DEVICE_ID)" || (echo "usage: make install-verified DEVICE_ID=<device-identifier> [SKIP_TESTS=1 | TEST_ONLY=<target/test> | FULL_TESTS=1]" >&2; exit 2)
	SKIP_TESTS="$(SKIP_TESTS)" TEST_ONLY="$(TEST_ONLY)" FULL_TESTS="$(FULL_TESTS)" ./scripts/install_verified_device.sh "$(DEVICE_ID)"
