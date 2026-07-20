# Sourceful driver package v1

`sourceful.driver-package/v1` is the canonical Sourceful release contract for a
driver. It describes one immutable version and binds executable artifacts to
runtime targets without requiring those targets to share an implementation.
The initial targets are FTW Core and Blixt L1. Zap is reserved as a future
target; Nova Core and mobile applications are consumers of package metadata
and telemetry, not executable Lua targets.

The normative schemas are:

- `schemas/sourceful.driver-package.v1.schema.json` — signed payload;
- `schemas/sourceful.driver-package-envelope.v1.schema.json` — signature envelope;
- `schemas/sourceful.driver-package-source.v1.schema.json` — reviewable build input.
- `schemas/sourceful.driver-index.v1.schema.json` — channel discovery index;
- `schemas/sourceful.driver-index-envelope.v1.schema.json` — signed index envelope.

Runtime and fleet contracts are separate from the signed package:

- `schemas/sourceful.driver-command.v1.schema.json` — host-owned command and lease;
- `schemas/sourceful.driver-command-result.v1.schema.json` — bounded control result;
- `schemas/sourceful.driver-inventory.v1.schema.json` — secret-free fleet snapshot.

See `control-runtime-v2.md` and `driver-inventory-v1.md`. Package v1 remains
valid for read-only targets. Managed control requires a v2 runtime ABI and host
API, so an old host cannot gain control by accepting new package metadata.

The source schema is not published or installed. It contains repository paths
and build transforms, never generated hashes, credentials, or runtime
configuration. The packager turns it into the immutable payload.

## Contract boundaries

The payload binds all information a host must decide before loading code:

- stable `package_id`, SemVer and `beta` or `stable` channel;
- hardware identity reporting and host-owned persistent state;
- source commit and build provenance;
- device matching, telemetry capabilities, permissions and sign convention;
- canonical commands, their runtime actions, default mode and lease expiry;
- an explicit compatibility record for each target, Lua semantics, runtime ABI,
  named host API profile and host API range;
- content-addressed artifacts with HTTPS URLs, SHA-256 and size constraints;
- rollback to a previously verified package without mutating the old release.

Compatibility is fail-closed. A host must provide a known target, product,
SemVer, runtime name/semantics/version/ABI, host API profile and host API. A
missing value, an unknown target or any out-of-range value is incompatible. A target-specific
`control_enabled` flag prevents a controllable package from acquiring control
rights merely because it can be loaded by another runtime. A controllable
source package may keep this flag false for every target while its v2 adapter
is staged. Setting it to true requires the target's approved v2 runtime ABI and
host API.

`read_only: true` requires no commands, no write permissions, no control leases
and no target with control enabled. A controllable package requires a vendor
autonomous default and a bounded lease whose heartbeat is shorter than its
expiry. Hosts still own runtime safety and must validate every command; package
metadata never authorizes direct hardware dispatch.

## Signing and immutable releases

The envelope uses the existing Sourceful Ed25519 PKCS8/SPKI key format. It does
not reuse the legacy operation of signing a hexadecimal artifact hash. Instead,
it signs the complete canonical payload, which already binds every artifact
hash and compatibility rule.

`sourceful.canonical-json/v1` is UTF-8 JSON with object keys sorted, compact
separators, no NaN/Infinity and no trailing newline in the signed bytes. The
serialized `.json` file ends with one newline; verification parses it and
reconstructs the canonical signed bytes.

The immutable trust root is the verified envelope plus the pinned public key.
A GitHub release or immutable object store may hold the envelope and artifacts.
The Device Support database and APIs may index verified releases for discovery,
but must not rewrite payloads, substitute URLs, or become the authority for an
immutable release. Channel promotion publishes a newly signed channel payload
over the exact already-reviewed version, commit and artifact hashes.

This public repository owns canonical sources, package metadata and release
versions. The private Device Support publisher owns official signed target
artifacts. Host repositories own runtime adapters, pinned trust roots and
install and activation policy. A driver changes once here; each target checks,
stages and activates the matching artifact on its own.
There is intentionally no automatic update or activation path in Phase 1.
Building, publishing, selecting, installing and activating are separate actions.

## Discovery index

`sourceful.driver-index/v1` is the single signed discovery/control-plane view.
It lists immutable package-envelope URLs, exact envelope hashes and available
executable targets. It does not duplicate driver metadata, artifact URLs or
permissions from the package and cannot authorize activation. A consumer first
verifies the index, then downloads and independently verifies each selected
package envelope and artifact.

Device Support signs and publishes this index. Nova Core and apps may use it for
catalog discovery; FTW adapts `ftw-core` packages into its Update Center; Blixt
can resolve an explicitly pinned package directly. Hugin is not on this trust
or distribution path.

## Deterministic tooling

Install tooling dependencies and validate the two pilots:

```bash
uv run --extra package tools/driver_package.py validate packages/v1/sdm630/package-source.json
uv run --extra package tools/driver_package.py validate packages/v1/sungrow/package-source.json
```

Build an unsigned FTW or Blixt candidate. The tool reads the current Git commit
and commit epoch so the same inputs produce the same bytes:

```bash
make package-driver ID=sdm630 TARGET=ftw-core
```

Official package and index signing runs only in the private publisher. Runtime
device passwords, tokens, certificates and serial or Modbus settings live in
each host's secret or config store and sit outside this package contract.

The private publisher verifies the signature and every local artifact before
publication. Hosts repeat the same checks before install:

```bash
uv run --extra package tools/driver_package.py verify \
  --envelope dist/packages/sdm630/1.1.1/manifest.envelope.json \
  --public-key /path/to/pinned-public.pem \
  --artifact-dir dist/packages/sdm630/1.1.1
```

The private publisher builds a signed beta index from signed package envelopes:

```bash
uv run --extra package tools/driver_package.py index \
  --package-envelope dist/packages/sdm630/1.1.1/manifest.envelope.json \
  --package-url https://packages.example/sdm630/1.1.1/manifest.envelope.json \
  --channel beta \
  --source-date-epoch 1700000000 \
  --public-key /path/to/pinned-public.pem \
  --key /path/to/release-private.pem \
  --key-id RELEASE_KEY_ID \
  --output dist/index/beta/manifest.envelope.json
```

The index builder first verifies every package envelope with the supplied
public key and binds the exact downloaded envelope bytes by SHA-256.

Published artifacts use the immutable version root. Beta and stable package
envelopes use separate immutable paths because the signed payload contains its
channel:

```text
/v1/packages/sdm630/1.1.1/<content-hash>.lua
/v1/packages/sdm630/1.1.1/beta/manifest.envelope.json
/v1/packages/sdm630/1.1.1/stable/manifest.envelope.json
```

Promotion verifies the beta envelope, changes only `channel`, and signs a new
stable envelope. It keeps the exact source commit, provenance, artifact URLs,
hashes, and sizes:

```bash
uv run --extra package tools/driver_package.py promote \
  --envelope dist/packages/sdm630/1.1.1/beta/manifest.envelope.json \
  --public-key /path/to/pinned-public.pem \
  --key /path/to/release-private.pem \
  --key-id RELEASE_KEY_ID \
  --output dist/packages/sdm630/1.1.1/stable/manifest.envelope.json
```

SDM630 is the first executable read-only pilot for FTW and Blixt. Its canonical
source is based on David's Blixt L1 implementation and preserves the one-read
hardware path. Sungrow is only a control-contract fixture until lease expiry,
default-mode invocation, command results and physical HIL gates are closed.
Zap remains intentionally outside the active pilot set.
