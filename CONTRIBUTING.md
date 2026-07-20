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

## Validate locally

```bash
make bootstrap
make test-driver ID=example
make package-driver ID=example TARGET=ftw-core
make check
```

The package command creates an unsigned candidate under `.artifacts/`. It does
not grant release or signing rights.

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

New contributions use the `community` tier. A maintainer may promote a driver
only after the stated review and hardware checks. Control support always uses a
separate change and cannot rely on community-tier review alone.
