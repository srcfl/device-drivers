# Driver support status

Catalog presence means that public source and a manifest exist. It does not
mean that a driver has a conforming target package, a signed beta, HIL evidence
or a stable release.

`support-status.json` records each catalog driver against `ftw-core` and
`blixt-l1`. Its keys mean:

- `target_conformance` — no assessment, contract passed or a staged gate;
- `candidate_package_version` — the next source recipe, not a signed release;
- `historical_signed_beta_version` — an older beta that keeps its original
  provenance and must not be overwritten;
- `hil` — recorded physical test state for that driver and target;
- `stable_package_version` — a package-v1 stable channel release;
- `legacy_parity` — whether the package target matches an existing host driver;
- `control_enabled` — the target flag in the candidate recipe.

Package-v1 stable promotion does not rebuild artifacts. It keeps the source
commit, materials, artifact bytes, hashes and URLs from beta. Because v1 signs
`channel` inside the payload, stable has a new envelope and signature whose
only payload change is `channel`. Moving one byte-identical envelope between
channels would require a versioned package-v2 contract.

Nova and fleet reports must use the same `driver_id`, `package_id`, version and
target values. Runtime truth still comes from each host's verified inventory,
not this planning file.
