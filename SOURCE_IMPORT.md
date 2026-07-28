# Source import

The initial public tree was reviewed and imported from the private
`srcfl/srcful-device-support` repository at commit
`5b16f74fc64321aedf09044622dfe05b3155a5e4`.

The import includes driver source, public manifests, public contracts, package
recipes, tests and local validation tools. It excludes the service API,
database, admin UI, deployment, cloud release code and signing material.

The initial import also contains the reviewed path fixes and repository URL
changes listed in `source-import-delta.json`. It includes one behavior delta
for Ferroamp DC2 V2X field names. A focused host-contract test pins that change;
no Ferroamp package recipe or release is part of this cutover, and physical HIL
remains required before any signed Ferroamp artifact.

From this import onward, this public repository is the editable source. The
private service consumes a locked commit and must reject local source drift.

## FTW bundled drivers

`baselines/ftw` holds all 37 of FTW's bundled drivers byte for byte as they
stood at FTW commit `b297b378`, recorded in `source-map.json` with each file's
hash, FTW driver id and version. `make check` verifies those hashes, so a
baseline cannot be edited by hand.

A baseline is a record, not a driver. Nothing under `baselines` reaches the
catalog, a package recipe or the signed channel, and every entry stays
`live_activation: blocked`.

Re-import after a change in FTW:

```bash
make ftw-baseline          # re-import from FTW master
make ftw-baseline-report   # what blocks each baseline from the catalog
```

## What happened to the import question

This file used to weigh whether the bundled drivers could replace their catalog
namesakes, and answered one at a time. #27 settled it the other way: all 37
were promoted verbatim and the catalog's own 62 drivers stopped being the
truth. `CHANGELOG.md` records why — the serious defects were all in the
catalog, never in FTW's drivers.

Two consequences outlive that decision.

**The direction of the snapshot reversed.** FTW's `drivers/` is now generated
from this repository at the commit pinned in FTW's `drivers/BUNDLED_SOURCE.json`,
and FTW's CI rejects any drift. A fix merged here does not reach that snapshot
on its own; someone moves the pin and runs FTW's `scripts/sync-bundled-drivers.sh`.

**A promoted driver drops its exemption the moment it is edited.**
`drivers/tests/conftest.py` decides byte-identity by content, so a fixed driver
rejoins every catalog convention at once. See `AGENTS.md` for what to do when
that fails a check.

Some promoted drivers call host functions the contract does not cover, listed
under `pending` in `spec/host-api-profile.json` — the `ws_*` and `tcp_*`
families, `json_encode`, `persist_secret`, `set_watchdog_timeout_s`,
`mqtt_pub`, `serial_write`. They shipped anyway because they work on FTW.
Defining each for every linux-edge host, or rewriting the driver without it,
is still open.
