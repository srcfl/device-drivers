# Sourceful Device Drivers

This public repository is the source of truth for Sourceful device driver
code, package metadata, compatibility contracts and tests. It is also FTW's
main driver source. FTW installs signed, content-addressed release assets from
this repository. It never runs raw code from `main`.

Device Support may later consume an exact public commit to build packages for
other products or a higher support level. It does not own a second editable
copy of the source and is not FTW's normal driver source.

## Contribute a driver

Fork this repository, create a branch and start a read-only driver:

```bash
make new-driver ID=example PROTOCOL=modbus KIND=meter
make test-driver ID=example
make package-driver ID=example TARGET=ftw-core
```

Then open a pull request using the template. Include the tested device models,
the protocol source, sign checks against vendor data and a test fixture when
one can be shared without credentials or site data.

New community drivers start with telemetry only. Control support needs a later,
separate review with a safe default mode, a bounded command lease, structured
results and supervised hardware-in-the-loop evidence.

Read [CONTRIBUTING.md](CONTRIBUTING.md) and
[spec/driver-package-v1.md](spec/driver-package-v1.md) before changing a
package contract.

## Repository boundary

This repository contains only public source and validation code:

- `drivers/lua` — shared Lua driver source;
- `manifests` — public catalog metadata and tested models;
- `packages/v1` — signed-package build recipes and host adapters;
- `spec` — package, inventory and command contracts;
- `drivers/tests` and `tests` — driver and package tests;
- `ftw-channel.json` — the rules for FTW's signed, read-only channel;
- `tools` — local validation, FTW release builds and unsigned package builds.

Private keys, credentials, cloud roles and service code stay outside this
repository. A pull request can produce unsigned test output only. GitHub
Actions signs the FTW channel after review and merge. The signature proves the
source commit and artifact bytes; it does not claim hardware test coverage.

## Release flow

```text
public PR -> public CI -> reviewed commit -> signed FTW beta
          -> site test -> stable promotion of the exact beta commit
```

The FTW channel contains every catalog driver. The release build turns each
source into a separate, read-only Lua asset and checks its FTW v1 contract.
The beta workflow runs on protected `main`; stable promotion requires the exact
signed commit found in beta. Refreshing the signed catalog never installs or
activates code. FTW keeps its own safety, activation, rollback and bundled
recovery paths.

Each asset name contains the driver ID, semantic version and source hash. FTW
downloads only the selected driver. The release workflow never replaces a
content-addressed driver asset, so GitHub keeps its download count across later
manifest updates. To view counts by driver, version and channel, run:

```bash
uv run python tools/ftw_download_stats.py
```

GitHub counts asset downloads, not unique users or active installs.

The separate package-v1 work remains available for Blixt and later Device
Support use. It can consume the same public commit without changing FTW's
default source.

The catalog is not an install claim. See [SUPPORT_STATUS.md](SUPPORT_STATUS.md)
for source, target conformance, signed beta, HIL, stable and legacy parity per
driver and target. Nova and fleet inventory use the same driver, package and
target identities from [support-status.json](support-status.json).

## License

Sourceful-authored code is licensed under Apache-2.0. Vendored Lua 5.5 source
keeps its own MIT notice; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
