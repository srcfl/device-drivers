# Sourceful Device Drivers

This public repository is the source of truth for Sourceful device driver
code, package metadata, compatibility contracts and tests. It serves several
hosts, including FTW and Blixt. The private Device Support service builds and
signs reviewed commits from this repository; it does not own a second editable
copy of the source.

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
- `tools` — local validation and deterministic unsigned package builds.

The following remain private in Device Support: the API, database, admin UI,
deployment, signing keys, cloud roles and release service. A public pull
request can produce an unsigned candidate only. Maintainers publish a signed
beta from an exact reviewed commit through the private release service.

## Release flow

```text
public PR -> public CI -> reviewed commit -> private signer -> beta package
          -> supervised site test -> exact-byte stable promotion
```

FTW and other hosts consume the signed package index. Refreshing an index never
installs or activates code. Each host keeps its own safety and activation
authority.

## License

Sourceful-authored code is licensed under Apache-2.0. Vendored Lua 5.5 source
keeps its own MIT notice; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
