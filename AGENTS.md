# Device driver repository guide

This public repository is the only editable source for shared Sourceful device
drivers and the main driver source for FTW. It publishes FTW's signed driver
channel from reviewed commits. Device Support may later consume a locked commit
for other products or support levels, but it does not own a second source tree.

## Boundaries

- Keep API, admin, database and deployment code out of this repo.
- Never add private keys, credentials, production account ids or site data.
- Keep signing keys out of source, logs and build output.
- Public pull-request builds stay unsigned. The release workflow signs the FTW
  channel only after a reviewed change reaches `main`.
- A catalog or package build never grants activation or control authority.
- New drivers start read-only.
- Control needs a safe default mode, bounded leases, structured results and HIL
  acceptance for every target host.

## Where a driver change has to land

A driver can exist in three places. Fixing one and leaving the others is how a
fixed bug comes back.

1. **`drivers/lua/<id>.lua`** — the catalog driver. This is what the signed
   channel publishes and what FTW bundles. Every fix starts here.
2. **`packages/v1/<id>/targets/*.lua`** — a separate file, not generated from
   the catalog driver. Only some drivers have one. A package target carries its
   own version line and can drift from the catalog copy without any check
   noticing. If the driver you are fixing has one, fix both.
3. **FTW's `drivers/`** — a recovery snapshot, generated from this repository
   at the commit pinned in FTW's `drivers/BUNDLED_SOURCE.json`. Never edit a
   driver there; FTW's own CI rejects the drift. But note the reverse: merging
   here does **not** reach that snapshot. Someone has to move the pin and run
   FTW's `scripts/sync-bundled-drivers.sh`. Until then a gateway booting
   offline still runs the old driver.

Pixii's flap on register 40288 is the worked example. It was fixed in #16,
survived in the package target, was reverted in the catalog driver by #27, and
reached customer hardware a second time. See the entries for **pixii** 2.1.1
and **solaredge_legacy** 0.3.1 in `CHANGELOG.md`.

### Editing a driver that came from FTW

The 37 drivers promoted in #27 are exempt from this suite's catalog
conventions for as long as they stay byte-identical to `baselines/ftw/drivers`
— `drivers/tests/conftest.py` decides that by content, not by a list. The
moment you edit one, every check in the suite starts applying to it, and
`make check` may fail on rules that driver never had to meet. That is working
as intended. Read the failure before assuming your change caused it: the
rule may be right and the driver wrong, or the check itself may be wrong.

## Source rules

- Sign conversion occurs only in the driver.
- Meter import, battery/vehicle charge and site consumption are positive.
- PV generation, meter export and battery/vehicle discharge are negative.
- Report stable hardware identity early.
- Do not emit stale cached telemetry as fresh.
- Keep Lua compatible with every runtime declared in the package recipe.
- Package id, version, read-only state and target metadata must match the Lua
  `DRIVER` block.

## Checks

Run the narrow driver command while editing, then the full check:

```bash
make test-driver ID=example
make package-driver ID=example TARGET=ftw-core
make check
```

Use plain English in docs. Add detail only for contracts, safety or operator
steps that code and tests cannot state.
