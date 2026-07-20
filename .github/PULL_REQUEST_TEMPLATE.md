## Summary

<!-- State what hardware support or contract changes. -->

## Driver evidence

- Driver id:
- Device make/model:
- Firmware tested:
- Protocol/register source:
- Hardware test performed:
- Known limits:

## Safety

- [ ] The driver starts read-only, or this is a separately reviewed control change.
- [ ] Vendor signs are converted at the driver boundary.
- [ ] Cached telemetry becomes stale instead of being re-emitted as fresh.
- [ ] No credentials, serial numbers, private addresses or site data are included.

## Package or promotion evidence

Complete this part when a package version, target, control contract or release
candidate changes. Use `not applicable` for a driver-only read-only change.

- Public source SHA:
- Package ID and new version:
- Target matrix:
- Material and candidate artifact SHA-256:
- HIL evidence or `required`:
- Control enabled: `false` unless all control gates have passed
- [ ] Control changes include default-mode, lease-expiry and HIL evidence.

## Checks

- [ ] Commits include `Signed-off-by`.
- [ ] `make test-driver ID=<id>`
- [ ] `make package-driver ID=<id> TARGET=<target>`
- [ ] `make check`
