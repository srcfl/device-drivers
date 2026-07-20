# Sourceful driver inventory v1

`sourceful.driver-inventory/v1` reports which drivers an authenticated host is
using. It supports fleet counts, beta rollout and rollback checks. It is not a
package index and grants no install or control rights.

The host sends one bounded snapshot on start, on a driver change and at least
every 15 minutes. FTW publishes it on:

```text
gateways.{gateway_id}.inventory.drivers.json.v1
```

Nova gets gateway and organization identity from the authenticated subject.
The payload does not repeat them. Nova checks that the bridged organization
owns the gateway before it replaces the last snapshot.

Each row groups equal driver ID, version and source. It reports configured and
running counts plus health counts. Managed rows bind the Sourceful package ID,
repository, channel and artifact SHA-256. `legacy_repository` rows mark an old
FTW repository artifact by repository and artifact SHA-256 without claiming a
canonical package ID or channel. Bundled and local override rows must not claim
package provenance. They report the loaded Lua source SHA-256 so Nova can tell
two local builds apart even when their driver version is equal.

`control_class` is `read_only` or `control` only when the loaded metadata or
canonical package states that fact. Old drivers with no explicit declaration
report `unknown`; the inventory must not guess from a missing boolean.

The payload must not contain instance names, site names, config, IP or host
names, URLs, serial numbers, MAC addresses, device IDs, tokens, credentials,
logs, command inputs or vendor responses. Nova may keep the latest snapshot
and aggregate by driver, version, source, channel and health. Access to one
gateway's row stays under the normal organization and admin checks.

The first FTW rollout will therefore have two baselines:

- the existing Nova network count, which cannot identify drivers;
- exact driver use from FTW versions that emit this contract.

Coverage must be shown with every fleet report. Counts from reporting FTW
hosts must not be presented as the full Sourceful fleet until coverage reaches
the chosen release gate.
