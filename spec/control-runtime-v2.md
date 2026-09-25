# Control runtime v2

Control runtime v2 is FTW Core's structured command interface for Lua
drivers. FTW's profile is `gopher-lua-source-v2` with the host API profile
`sourceful.host/ftw-core/v2`. A driver that implements it keeps its v1
entrypoints as well; FTW never grants v2 control to a v1 driver.

## Calls and results

A v2 driver exposes:

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

The host passes a `sourceful.driver-command/v1` command to
`driver_command_v2`. The host owns the command ID, times, attempt and lease. It
rejects expired commands, unknown command IDs, undeclared inputs and values
outside the declared limits before Lua runs.

The driver returns only `status`, `code`, optional `message`, `device_state`,
applied values and evidence names. The host creates the
`sourceful.driver-command-result/v1` record, adds the command and lease IDs,
driver identity, completion time and the number of allowed host writes, and
records the result. A nil, boolean or string Lua result fails the v2 call.
`accepted` is not proof that the device applied a value. Only `applied` with
the evidence required by that driver may renew a lease.

## Write scope

Write calls work only while the host runs `driver_command_v2` under a valid
lease or `driver_default_mode_v2` during expiry and shutdown. Write calls from
init, poll or cleanup fail. A driver that needs writes in init or poll must
move them to an explicit command or default-mode call.

The host applies call deadlines, instruction and memory budgets, URL and topic
allowlists, and write-count limits. A timed-out Lua call loses its write scope.
Control Lua gets a small library allowlist; `os`, `io`, `debug`, `package`,
`load`, `loadfile`, `dofile` and native modules are absent.

## Lease and default mode

The host starts or renews a lease only after an `applied` result. It runs
default mode when the lease expires, the driver goes stale, the control loop
stops, the driver changes or the host shuts down. It blocks later control if
default mode fails. Downloading, installing or activating a driver never
starts a lease.

A v2 control path may reach a beta only after HIL proves:

1. normal command and result;
2. expiry returns the device to its stated default;
3. host restart and process kill do not leave an unsafe target;
4. network loss has a bounded safe outcome;
5. rollback restores the last verified driver;
6. init, poll and cleanup cannot write outside the allowed phase.

If the device keeps a setpoint after host loss and has no device-side timeout,
the driver does not pass this gate until it provides an equivalent safe path.
