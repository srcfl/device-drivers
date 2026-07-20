# Device driver repository guide

This public repository is the only editable source for shared Sourceful device
drivers. The private Device Support service may vendor a locked copy, build it
and sign releases, but source changes start here.

## Boundaries

- Keep API, admin, database, deployment and signing code out of this repo.
- Never add private keys, credentials, production account ids or site data.
- Driver packages are unsigned in public CI.
- A catalog or package build never grants activation or control authority.
- New drivers start read-only.
- Control needs a safe default mode, bounded leases, structured results and HIL
  acceptance for every target host.

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
