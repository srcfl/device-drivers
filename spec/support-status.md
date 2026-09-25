# Driver support status

Catalog presence means that public source and a manifest exist. It does not
mean that a driver has passed a target contract, a signed beta, HIL evidence
or a stable release.

`support-status.json` records each catalog driver against `ftw-core` and
`blixt-l1`. Its keys mean:

- `target_conformance` — no assessment, contract passed or a staged gate;
- `historical_signed_beta_version` — an older beta that keeps its original
  provenance and must not be overwritten;
- `hil` — recorded physical test state for that driver and target;
- `legacy_parity` — whether the driver matches an existing host driver.

Values other than the defaults come from `support-status-overrides.json`.
Runtime truth still comes from each host's own inventory, not this planning
file.
