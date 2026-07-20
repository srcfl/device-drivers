# Sourceful control runtime v2

Control packages use the same signed `sourceful.driver-package/v1` envelope as
read-only packages. A control target must use a v2 runtime ABI and host API.
Hosts must not grant control to a v1 target.

The first profiles are:

- FTW: `gopher-lua-source-v2` with `sourceful.host/ftw-core/v2`;
- Blixt L1: `mlua-0.10-luajit21-source-v2` with
  `sourceful.host/blixt-l1/v2`.

This version split keeps existing read-only artifacts valid and stops an old
host from loading a control artifact that it cannot contain.

## Calls and results

A v2 adapter exposes:

```lua
function driver_command_v2(command)
  return {
    status = "applied",
    code = "ok",
    device_state = "controlled"
  }
end

function driver_default_mode_v2(context)
  return {
    status = "defaulted",
    code = "default_restored",
    device_state = "default"
  }
end
```

The host passes `sourceful.driver-command/v1` to `driver_command_v2`. The host
owns the command ID, times, attempt and lease. It rejects expired commands,
unknown command IDs, undeclared inputs and values outside the package limits
before Lua runs.

The Lua adapter returns only `status`, `code`, optional `message`,
`device_state`, applied values and evidence names. The host creates
`sourceful.driver-command-result/v1`, adds the command and lease IDs, package
identity, completion time and the number of allowed host writes, and records
the result. A nil, boolean or string Lua result fails the v2 call. `accepted`
is not proof that the device applied a value. Only `applied` with the evidence
required by that driver may renew a lease.

## Write scope

Package permissions narrow the host capabilities. Host config may narrow them
again but may never add a permission that the signed package did not request.

For a managed v2 control package, write calls work only while the host runs
`driver_command_v2` under a valid lease or `driver_default_mode_v2` during
expiry and shutdown. Write calls from init, poll or cleanup fail. A driver that
needs writes in init or poll needs a target adapter that moves those writes to
an explicit command or default-mode call.

The host applies call deadlines, instruction and memory budgets, URL and topic
allowlists, and write-count limits. A timed-out Lua call loses its write scope.
Managed control Lua gets a small library allowlist; `os`, `io`, `debug`,
`package`, `load`, `loadfile`, `dofile` and native modules are absent.

## Lease and default mode

The host starts or renews a lease only after an `applied` result. It runs
default mode when the lease expires, the driver goes stale, the control loop
stops, the package changes or the host shuts down. It blocks later control if
default mode fails.

The package lease is an upper bound. Site policy may use a shorter lease. A
channel index, download, install or activation never starts a lease.

A controllable source package may keep every target at `control_enabled: false`
while its v2 adapter and host are still in development. A target may change the
flag to `true` only when it uses its approved v2 ABI and host API. A control
package may reach a beta channel index only after HIL proves:

1. normal command and result;
2. expiry returns the device to its stated default;
3. host restart and process kill do not leave an unsafe target;
4. network loss has a bounded safe outcome;
5. rollback restores the last verified package;
6. init, poll and cleanup cannot write outside the allowed phase.

If the device keeps a setpoint after host loss and has no device-side timeout,
the driver does not pass this gate until its adapter provides an equivalent
safe path.

## Beta activation

`control_enabled: true` says that an artifact supports control. It does not
turn control on. A host also requires an explicit beta channel, exact package
version and hash pin, a per-site opt-in and a passed HIL record for that driver
and model. Beta control packages never auto-activate.
