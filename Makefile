ID ?=
PROTOCOL ?= modbus
KIND ?= meter
TARGET ?= ftw-core
ARTIFACT_DIR ?= .artifacts/$(ID)

.PHONY: bootstrap new-driver test-driver package-driver check boundary

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

check: boundary
	bash tools/build_luac.sh --with-interpreter ./luac55
	uv run --frozen --extra package --extra dev python tools/validate_manifest.py
	uv run --frozen --extra package --extra dev python tools/generate_index.py
	git diff --exit-code -- index.yaml
	uv run --frozen --extra package --extra dev python tools/generate_devices.py
	git diff --exit-code -- devices.yaml
	uv run --frozen --extra package --extra dev python tools/generate_support_status.py
	git diff --exit-code -- support-status.json SUPPORT_STATUS.md
	bash tools/check_sandbox.sh
	uv run --frozen --extra package --extra dev pytest -q drivers/tests tests
