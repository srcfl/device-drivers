<!-- External PRs are welcome, preferably based on an issue. Short Markdown
proposals are welcome too. State what was tested and what remains unproven.
For docs/proposals, mark hardware-only fields and checks as not applicable.
See CONTRIBUTING.md. -->

## Summary

<!-- State the problem, link the issue and describe the proposed result. -->

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

## Control evidence

Complete this part when a control path changes. Use `not applicable` for a
read-only change.

- HIL evidence or `required`:
- [ ] Control changes include default-mode, lease-expiry and HIL evidence.

## Checks

- [ ] Commits include `Signed-off-by`.
- [ ] `make test-driver ID=<id>`
- [ ] `make check`
