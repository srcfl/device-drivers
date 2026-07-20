# Driver package v1 migration map

This bridges the current representations to `sourceful.driver-package/v1`. It
is a per-driver migration plan, not an instruction to mass-convert catalogs.

| Concern | FTW | Blixt L1 | Public source action |
|---|---|---|---|
| Identity | `DRIVER.id` and signed repository ID | `DRIVER_MANIFEST.name` and registry name | Allocate the stable reverse-DNS `package_id`; retain target IDs as aliases. |
| Version/channel | Driver version plus signed beta/stable history | Lua manifest version; registry response is not a release channel | Own one SemVer and signed channel. Never mutate a published version. |
| Runtime | GopherLua 1.1.2, Lua 5.1 semantics | LuaJIT 2.1 through mlua 0.10 | Bind separate runtime names, ABI values and host profiles. Do not claim runtime identity. |
| Hardware identity | `DRIVER`, `set_make`/`set_sn`; host owns state | `DRIVER_MANIFEST.provides` and host setters | Declare reporting promises and stable host fallbacks; state remains host-owned. |
| Device match | manufacturer, tested models and verification status | runner configuration and local selection | Curate reviewed families/variants/regions; catalog presence is not HIL proof. |
| Permissions | protocol/capability-scoped host functions | broad host functions around an arbitrated device path | Sign minimum operations and enforce them at every host call. |
| Telemetry | lowercase Sourceful fields; import-positive convention | typed adapter currently consumes mixed-case meter fields | Bind telemetry v2 and sign convention. Adapters normalize target field names. |
| Lifecycle | init, poll, command, default mode and cleanup | same core entrypoints plus manifest probing | Require target lifecycle conformance during build and runtime tests. |
| Scheduling | host/Core owns stale data and safety | queued work, preemption, coalescing and device arbitration | Preserve Blixt's hardware-near scheduling; it is not package-registry logic. |
| Control safety | Core-owned leases, stale cutoff and default mode | command path exists; lease expiry/default result is incomplete | Metadata never enables control. Close lifecycle, lease and HIL gates before a control pilot. |
| Artifacts | signed content-addressed Lua source | source selected by embedded/local/remote registry | Produce one immutable artifact record per target. Shared bytes are allowed, not required. |
| Trust | Ed25519 signed repository artifacts | remote source fetch has no complete package trust chain | Sign canonical envelope; host verifies signature, compatibility, length and SHA-256 before staging. |
| Provenance | repository and commit in update center | embedded/local source or mutable registry response | Bind source commit, input hashes, builder and source epoch. Toolchain is provenance, not compatibility. |
| Update/rollback | verified history and atomic activation | driver registry resolution and runtime load | The private publisher signs once; targets stage and activate on their own and retain a prior verified package. |
| Consumers | Core executes drivers and publishes telemetry | L1 executes drivers and publishes telemetry | Nova Core and apps discover metadata/telemetry; they are not Lua targets. |

## Pilot interpretation

SDM630 is the read-only pilot: telemetry only, one bundled Modbus read, no
commands, no lease and FTW/Blixt artifacts with control disabled. Its canonical
source is based on David's Blixt implementation. The common source emits both
canonical lowercase fields and temporary Blixt mixed-case aliases.

Sungrow is only the later control-contract pilot. It declares Modbus write
permission, default mode and a 30-second lease with a 10-second heartbeat, but
must not progress to activation until command results, failure/expiry default
mode and physical HIL gates are closed.

## Explicitly deferred

- no mass migration of either Lua catalog;
- no automatic publication, update, install or activation in the first pilot;
- no active Zap artifact yet; the schema only reserves the future target;
- no Hugin runtime or registry work; Hugin may later become a workbench;
- no claim of production control before physical HIL validation.
