# Sourceful Device Drivers

This public repository is FTW's driver repository: the source of truth for its
device driver code, catalog metadata and tests. FTW installs signed,
content-addressed release assets from this repository. It never runs raw code
from `main`.

## Browse the catalog

**[Every driver, and what stands behind it →](https://srcfl.github.io/device-drivers/)**

The catalog page is generated from this repository and republished on every push
to `main`, so it cannot fall behind the source. The manifests supply versions,
tiers, protocols and tested models; each Lua source supplies its own description
and verification record. Search by manufacturer or model number, filter by device
type or protocol, or take the whole catalog as
[drivers.json](https://srcfl.github.io/device-drivers/drivers.json).

Being listed is not an install claim. The page states the same evidence the
repository does, including how few drivers have been confirmed against physical
hardware.

## Report a need or adapt a driver

Sourceful maintains the drivers and releases. External PRs are welcome,
preferably based on [issues](https://github.com/srcfl/device-drivers/issues)
with hardware needs, bugs and test evidence. Share a short Markdown proposal
or a focused fix; hardware claims need hardware results.
[FTW's product vision](https://github.com/srcfl/ftw/blob/master/VISION.md)
sets the FTW goals. The existing license still permits local adaptation.
The instructions below serve contributions and local adaptation.

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

For an issue, include the device model, protocol source and any observations
you can safely share. Implementation PRs use the template and include
sign checks and test evidence without credentials or private site data.

New drivers start with telemetry only. Control support needs a later,
separate review with a safe default mode, a bounded command lease, structured
results and supervised hardware-in-the-loop evidence.

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

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

What a driver may call is defined in [spec/host-api-profile.json](spec/host-api-profile.json)
and enforced by `make check`. A function outside the profile is not available,
whichever host it was tested against.

Drivers here are community-supported. The tier in each manifest states the test
and support evidence behind that driver; a channel signature proves artifact
integrity, never hardware coverage.

## Repository boundary

This repository contains only public source and validation code:

- `drivers/lua` — Lua driver source;
- `manifests` — public catalog metadata and tested models;
- `spec` — driver, host API, manifest and signing contracts;
- `drivers/tests` and `tests` — driver and tooling tests;
- `ftw-channel.json` — the rules for FTW's signed, read-only channel;
- `tools` — local validation and FTW release builds.

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

The catalog is not an install claim. See [SUPPORT_STATUS.md](SUPPORT_STATUS.md)
for target conformance, signed beta, HIL and legacy parity per driver and
target.

## License

This version uses AGPL-3.0-only with the Energyplan combination permission
in [LICENSE](LICENSE). See [LICENSING.md](LICENSING.md) and [NOTICE](NOTICE). Vendored Lua 5.5 source
keeps its own MIT notice; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
