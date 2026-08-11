.PHONY: guard hooks install-verified

guard:
	./scripts/repository_guard.sh status

hooks:
	./scripts/install_git_hooks.sh

install-verified:
	@test -n "$(DEVICE_ID)" || (echo "usage: make install-verified DEVICE_ID=<device-identifier>" >&2; exit 2)
	./scripts/install_verified_device.sh "$(DEVICE_ID)"
