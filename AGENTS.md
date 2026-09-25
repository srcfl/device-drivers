# Device driver repository guide

This public repository is FTW's driver repository and the only editable source
for its device drivers. It publishes FTW's signed driver channel from reviewed
commits.

## FTW product direction

Read [FTW's vision](https://github.com/srcfl/ftw/blob/master/VISION.md) for the household
experience these drivers support. Sourceful maintains this shared repository.
External PRs are welcome, preferably based on issues with needs and evidence.
Work is agentic first: state the problem, scope, test steps and actual results.
Short Markdown proposals are welcome; hardware changes keep the acceptance
gates below. See [CONTRIBUTING.md](CONTRIBUTING.md). Local Lua customization remains useful
and does not grant signed-channel activation or release rights.

Support mixed makes and generations with explicit model/firmware evidence.
Report identity, reliable measurements, known limits and structured command
results so Core can distinguish read support from control support. A catalog
entry or a simulated response does not establish working physical control.
Heat telemetry helps planning first; active tank or hot-water control requires
its separate safety and hardware evidence. Keep the existing host contracts
and control acceptance gates below.

## Boundaries

- Keep API, admin, database and deployment code out of this repo.
- Never add private keys, credentials, production account ids or site data.
- Keep signing keys out of source, logs and build output.
- Public pull-request builds stay unsigned. The release workflow signs the FTW
  channel only after a reviewed change reaches `main`.
- A catalog build never grants activation or control authority.
- New drivers start read-only.
- Control needs a safe default mode, bounded leases, structured results and HIL
  acceptance for every target host.

## Where a driver change has to land

A driver can exist in two places. Fixing one and leaving the other is how a
fixed bug comes back.

1. **`drivers/lua/<id>.lua`** — the catalog driver. This is what the signed
   channel publishes and what FTW bundles. Every fix starts here, and it is
   the only copy of a driver in this repository.
2. **FTW's `drivers/`** — a recovery snapshot, generated from this repository
   at the commit pinned in FTW's `drivers/BUNDLED_SOURCE.json`. Never edit a
   driver there; FTW's own CI rejects the drift. But note the reverse: merging
   here does **not** reach that snapshot. Someone has to move the pin and run
   FTW's `scripts/sync-bundled-drivers.sh`. Until then a gateway booting
   offline still runs the old driver.

Pixii's flap on register 40288 is the worked example. It was fixed in #16,
survived in a separate package-target copy, was reverted in the catalog driver
by #27, and reached customer hardware a second time. See the entries for
**pixii** 2.1.1 and **solaredge_legacy** 0.3.1 in `CHANGELOG.md`. Those copies
have since been removed.

### One id and one version

A driver's id is its file name and catalog name, and its `DRIVER` table says
exactly that id and the manifest's version. FTW compares its bundled copy with
the signed channel by that id and version, so they must be the same text. The
channel build and `tests/test_driver_truth.py` refuse anything else. Change a
version with `make bump-driver`, which moves both.

`baselines/ftw` records what was promoted from FTW in #27. Every promoted
driver has since changed, so no check treats them differently.

## Source rules

- Sign conversion occurs only in the driver.
- Meter import, battery/vehicle charge and site consumption are positive.
- PV generation, meter export and battery/vehicle discharge are negative.
- Report stable hardware identity early.
- Do not emit stale cached telemetry as fresh.
- Record the vendor documents a driver was decoded from — register map,
  parameter changelog, API reference — in the manifest's `upstream_docs`, at
  the most durable URL available. A weekly watcher opens a tracking issue when
  one changes or disappears, so a driver that has fallen behind its source is
  caught there rather than by a wrong value on a customer's site. A document
  behind a login cannot be watched; reference it in a driver comment instead.
  See `docs/WRITING-A-DRIVER.md`.

## Checks

Run the narrow driver command while editing, then the full check:

```bash
make test-driver ID=example
make check
```

Use plain English in docs. Add detail only for contracts, safety or operator
steps that code and tests cannot state.
