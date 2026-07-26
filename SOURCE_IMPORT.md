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

FTW still ships its own bundled copies. `baselines/ftw` now holds all 37 of
them byte for byte, recorded in `source-map.json` with each file's hash, FTW
driver id and version. `make check` verifies those hashes, so a baseline
cannot be edited by hand and FTW's source cannot drift away unnoticed.

A baseline is a record, not a driver. Nothing under `baselines` reaches the
catalog, a package recipe or the signed channel, and every entry stays
`live_activation: blocked`.

Re-import after a change in FTW:

```bash
make ftw-baseline          # re-import from FTW master
make ftw-baseline-report   # what blocks each baseline from the catalog
```

The bundled drivers cannot simply replace their catalog namesakes:

- of the 20 that map onto a catalog driver, none is byte-identical;
- 14 compile to more than 8 KB of bytecode. That mattered when this
  repository still targeted Zap; it no longer does, and a linux-edge driver
  has no size ceiling. The figure is kept only because the Zap build track
  compiles from this source and still has a pool to fit;
- 17 have no catalog driver at all;
- six of them call host functions the contract does not cover, listed under
  `pending` in `spec/host-api-profile.json`: `easee_cloud` and
  `ferroamp_dc2_v2x` need `json_encode`, `myuplink` needs `persist_secret`,
  `tesla_vehicle` needs `set_watchdog_timeout_s`, `tibber` needs the `ws_*`
  family and `zuidwijk_p1` the `tcp_*` family. The other 31 are clean;
- `ferroamp_dc2_v2x` calls `os.time()`, which the driver sandbox forbids. The
  catalog's own `drivers/lua/ferroamp_dc2_v2x.lua` has no such call, so the fix
  already exists upstream.

Each of those is a decision per driver, not a bulk move. Take them one at a
time and record the outcome in the source map.
