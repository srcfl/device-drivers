# Contributing device drivers

Thank you for helping add hardware support. Keep each pull request focused on
one driver or one contract change.

## Legal sign-off

Contributions use Apache-2.0 and the Developer Certificate of Origin 1.1. Sign
every commit with your real name and email:

```bash
git commit -s -m "feat(driver): add example meter"
```

The sign-off confirms that you wrote the contribution or have the right to
submit it under this license.

## Start a driver

```bash
git checkout -b add-example-meter
make new-driver ID=example PROTOCOL=modbus KIND=meter
```

The generated package is read-only and targets FTW and Blixt through the shared
Lua 5.1 source profile. Edit the generated files rather than creating a second
manifest elsewhere.

Every driver must:

- declare `DRIVER` metadata whose id and version match its package;
- implement `driver_init`, `driver_poll`, `driver_cleanup` and a safe
  `driver_default_mode` when control is later added;
- translate vendor signs at the driver boundary;
- report make and serial as soon as stable identity is known;
- stop emitting cached data when it becomes stale;
- request only the network and device permissions it needs;
- avoid credentials, private keys and site data in code, fixtures and docs.

Power uses one convention above the driver boundary:

- meter import is positive and export is negative;
- PV generation is negative;
- battery and vehicle charge are positive and discharge is negative.

## Change an existing driver

Raise the version whenever the Lua source changes. A version names a set of
bytes that runs on hardware, so shipping two different drivers under one
version leaves a site with no way to say which one it has.

Raise it too when a manifest field the signed channel publishes changes, even
though no Lua moved. The channel signs source and metadata as one artifact, so
`ders`, `protocol` and the `manufacturer` and `model_family` of a
`tested_devices` entry all reach the published bytes. Changing one under a
version already released fails with `changed artifact needs a higher version`.

The `signed channel accepts this tree` check answers that on every pull
request, against the manifest the channel has actually published. To ask it
yourself:

```bash
gh release download drivers-beta --repo srcfl/device-drivers \
  --pattern manifest.json --dir /tmp/ftw
FTW_DRIVER_SIGNING_PUBLIC_KEY=MX+j27UBkyM099hTyJlmMLK9qlTTDUJsaK/vH12fFKc= \
  uv run --extra package python tools/ftw_repository.py check-versions \
  --previous-manifest /tmp/ftw/manifest.json --key-id ftw-drivers-2026-01
```

It signs nothing and needs no secret. It names every driver that has to move
and the command that moves it. Because it compares against the published
channel rather than against `main`, a `main` that is itself unpublishable
fails this check on unrelated pull requests too — that is the breakage
surfacing, and it clears when `main` is fixed.

```bash
make bump-driver ID=example LEVEL=patch
```

That moves the version in `manifests/example.yaml` and, when the driver
declares one, in its `DRIVER` table. It then refreshes `index.yaml`,
`devices.yaml` and the support status. Use `LEVEL=patch` for a fix that keeps
the same registers and fields, `LEVEL=minor` for new telemetry, and
`LEVEL=major` when a host or an operator has to do something differently.

Add a `CHANGELOG.md` entry under `[Unreleased]` in the same pull request.

`sha256` and `size_bytes` in a manifest are derived, never typed:

```bash
make sync-manifests
```

`make check` runs the same command and fails on any difference, so a manifest
cannot claim bytes the driver does not have.

## Go back to an older driver

`driver-history.json` records every version this repository has published:
the source SHA-256, the size, the commit that first carried it and the date.
To recover an exact past driver, look up the version and read that commit:

```bash
python3 -c "import json;print([e for e in json.load(open('driver-history.json'))['drivers']['sungrow']])"
git show <commit>:drivers/lua/sungrow.lua > sungrow-1.2.0.lua
```

The file is append-only. A recorded version describes bytes already running
somewhere, so `make check` fails if an entry is rewritten or dropped. Publish
a new version instead of changing an old one.

Maintainers record newly published versions at release:

```bash
make history
```

## Validate locally

```bash
make bootstrap
make test-driver ID=example
make package-driver ID=example TARGET=ftw-core
make check
```

The package command creates an unsigned candidate under `.artifacts/`. It does
not grant release or signing rights.

The FTW release build turns each source file into a signed, read-only Lua
artifact. The channel includes the full catalog and checks every generated
artifact against the FTW v1 lifecycle and host API. A merged source change
reaches beta only after the signed release workflow passes.

## Pull request evidence

State:

- device make, model and relevant firmware;
- protocol documentation or register source;
- values compared between the device, its vendor UI and a site meter;
- offline, reconnect and stale-data behavior;
- which parts were tested on hardware;
- known limits or missing functions.

Do not post credentials, full configuration, serial numbers, private addresses
or energy history from a real site.

New contributions use the `community` tier. That tier states the current test
and support evidence; it does not mean the public repo is unofficial or
unmaintained. A maintainer may promote a driver only after the stated review
and hardware checks. Control support always uses a separate change and cannot
rely on community-tier review alone.
