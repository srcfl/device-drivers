# Sourceful Device Drivers

This public repository is the source of truth for Sourceful device driver
code, package metadata, compatibility contracts and tests. It is also FTW's
main driver source. FTW installs signed, content-addressed release assets from
this repository. It never runs raw code from `main`.

Device Support may later consume an exact public commit to build packages for
other products or a higher support level. It does not own a second editable
copy of the source and is not FTW's normal driver source.

## Contribute a driver

Start from **[`blueprint/BLUEPRINT.lua`](blueprint/BLUEPRINT.lua)**. It is a
complete, working driver for an imaginary inverter, written so that every rule
this repository enforces appears beside the code that follows it. It is
verified like a shipped driver: it compiles, passes the sandbox, and is run
against the harness by `tests/test_blueprint.py`.

```bash
cp blueprint/BLUEPRINT.lua drivers/lua/example.lua
make test-driver ID=example
make check
```

[docs/WRITING-A-DRIVER.md](docs/WRITING-A-DRIVER.md) explains the reasoning
behind each rule — why a failed read can take a whole site offline, why a
fabricated zero is worse than a missing field, and why arithmetic never belongs
in the host API.

Then open a pull request using the template. Include the tested device models,
the protocol source, sign checks against vendor data and a test fixture when
one can be shared without credentials or site data.

New community drivers start with telemetry only. Control support needs a later,
separate review with a safe default mode, a bounded command lease, structured
results and supervised hardware-in-the-loop evidence.

Read [CONTRIBUTING.md](CONTRIBUTING.md) and
[spec/driver-package-v1.md](spec/driver-package-v1.md) before changing a
package contract.

## Scope

The drivers here target linux-edge hosts: FTW (gopher-lua) and Blixt L1
(luajit). Both run on Linux-class hardware, so a driver is not written to a
memory budget.

37 of them came from FTW, where they have run on customer sites for months.
They were promoted byte-identical to `baselines/ftw/drivers/` so their
provenance stays checkable, and FTW continues to test them in Go. A driver
that has since been fixed here no longer matches its baseline, which is the
point — the baseline is a record of what was imported, not a mirror of what
ships. `make ftw-baseline-report` lists the current state.

**One driver per device, not one dialect per repository.** FTW and Blixt spell
some host functions differently, and both spellings are correct — each is the
real API of a shipping host, and a host that wants the other's drivers adds
aliases in a few lines. What matters is that a driver never calls a name no
host provides, which `tools/host_api_check.py` enforces. Converting drivers to
a single spelling was tried and abandoned: it changed 196 lines across 36
field-proven drivers without changing what any of them does.

Zap is built on a separate track that compiles from this source. Its
constraints do not shape the drivers here, and it is not a target in these
package recipes.

What a driver may call is defined in [spec/host-api-profile.json](spec/host-api-profile.json)
and enforced by `make check`. A function outside the profile is not available,
whichever host it was tested against.

Drivers here are community-supported. The tier in each manifest states the test
and support evidence behind that driver; a channel signature proves artifact
integrity, never hardware coverage.

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
