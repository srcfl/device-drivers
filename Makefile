ID ?=
PROTOCOL ?= modbus
KIND ?= meter
TARGET ?= ftw-core
ARTIFACT_DIR ?= .artifacts/$(ID)

LEVEL ?= patch

.PHONY: bootstrap new-driver test-driver package-driver check boundary \
	sync-manifests bump-driver history ftw-baseline ftw-baseline-report \
	host-api

# Does any driver call a host function no host provides?
host-api:
	uv run --frozen --extra package --extra dev python tools/host_api_check.py


# Re-import FTW's bundled drivers into baselines/ftw. Needs the GitHub API.
ftw-baseline:
	uv run --frozen --extra package --extra dev python tools/import_ftw_baseline.py

# Show what stands between each FTW baseline and a catalog driver.
ftw-baseline-report:
	uv run --frozen --extra package --extra dev python tools/import_ftw_baseline.py --report

# Which registers a driver reads forever while still reporting telemetry.
# Every one takes the driver offline on hardware that omits that register.
absent-register-report:
	test -n "$(ID)"
	./lua55 drivers/tests/lua_harness/absent_register_probe.lua . "drivers/lua/$(ID).lua"

bootstrap:
	uv sync --frozen --extra package --extra dev

new-driver:
	uv run --frozen --extra package --extra dev python tools/new_driver.py --id "$(ID)" --protocol "$(PROTOCOL)" --kind "$(KIND)"

test-driver:
	test -n "$(ID)"
	bash tools/build_luac.sh --with-interpreter ./luac55
	./luac55 -p "drivers/lua/$(ID).lua"
	bash tools/check_sandbox.sh "drivers/lua/$(ID).lua"
	uv run --frozen --extra package --extra dev python tools/validate_manifest.py "manifests/$(ID).yaml"
	uv run --frozen --extra package --extra dev pytest -q drivers/tests -k "$(ID)"

package-driver:
	test -n "$(ID)"
	uv run --frozen --extra package --extra dev python tools/build_candidate.py --id "$(ID)" --target "$(TARGET)" --output-dir "$(ARTIFACT_DIR)"

boundary:
	uv run --frozen --extra package --extra dev python tools/check_public_boundary.py

# Rewrite sha256 and size_bytes in every manifest from the Lua source.
sync-manifests:
	uv run --frozen --extra package --extra dev python tools/sync_manifests.py

# Raise a driver version in the manifest and the DRIVER table together.
# Example: make bump-driver ID=sungrow LEVEL=patch
bump-driver:
	test -n "$(ID)"
	uv run --frozen --extra package --extra dev python tools/bump_driver.py --id "$(ID)" --level "$(LEVEL)"
	uv run --frozen --extra package --extra dev python tools/sync_manifests.py --id "$(ID)"
	uv run --frozen --extra package --extra dev python tools/generate_index.py
	uv run --frozen --extra package --extra dev python tools/generate_devices.py
	uv run --frozen --extra package --extra dev python tools/generate_support_status.py

# Record newly published driver versions in driver-history.json.
history:
	uv run --frozen --extra package --extra dev python tools/generate_history.py

check: boundary
	bash tools/build_luac.sh --with-interpreter ./luac55
	uv run --frozen --extra package --extra dev python tools/sync_manifests.py
	git diff --exit-code -- manifests
	uv run --frozen --extra package --extra dev python tools/validate_manifest.py
	uv run --frozen --extra package --extra dev python tools/generate_index.py
	git diff --exit-code -- index.yaml
	uv run --frozen --extra package --extra dev python tools/generate_devices.py
	git diff --exit-code -- devices.yaml
	uv run --frozen --extra package --extra dev python tools/generate_support_status.py
	git diff --exit-code -- support-status.json SUPPORT_STATUS.md
	uv run --frozen --extra package --extra dev python tools/generate_history.py --check
	uv run --frozen --extra package --extra dev python tools/import_ftw_baseline.py --check
	uv run --frozen --extra package --extra dev python tools/host_api_check.py --check
	bash tools/check_sandbox.sh
	uv run --frozen --extra package --extra dev pytest -q drivers/tests tests
