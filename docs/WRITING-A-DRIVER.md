# Writing a driver

Start here: **[`blueprint/BLUEPRINT.lua`](../blueprint/BLUEPRINT.lua)**.

It is a complete, working driver for an imaginary inverter. Every rule in this
document appears there next to the code that follows it. Copy it, rename it,
replace the register map, and you are most of the way done.

This page explains the reasoning. The blueprint is the specification.

---

## What a driver is

A driver turns one device's registers into telemetry the host understands.
That is all. It does not decide policy, schedule work across polls, or talk to
anything but its own device.

The valuable part is not the code. It is the knowledge: which register holds
what, what scale it uses, which firmware lies, what the vendor documented
wrongly. **Write that down in comments as you find it.** Nobody can re-derive
it from the numbers later, and it is the reason this repository exists.

**Write down where you got it, too.** The register map, the parameter
changelog, the API reference you decoded the device from — record those in the
manifest so the driver can be checked against them again later. See
[Record what you decoded it from](#record-what-you-decoded-it-from).

## The five entry points

| Function | When |
|---|---|
| `driver_init(config)` | once, before the first poll |
| `driver_poll()` | repeatedly; returns milliseconds until the next call |
| `driver_command(action, power_w, cmd)` | when the host wants the device to act |
| `driver_default_mode()` | hand the device back to itself |
| `driver_cleanup()` | once, when the driver stops |

Only `driver_poll` is required. A read-only driver defines the first two and
stops there — and most drivers should. A driver that cannot write cannot break
a customer's site.

## The rule that matters most

**The host fails the whole poll if any single read fails.** A device that goes
offline reports nothing at all, which is worse than reporting less.

Two consequences, and they are the difference between a driver that works and
one that takes a site down:

1. **Never read a register you have no reason to believe exists.** Ask the
   device what it is first. A customer's SG12RT lost all telemetry for weeks
   because a driver read a battery block on an inverter with no battery.

2. **Never keep retrying one that has proved it does not exist.** Bound every
   probe. A register retried on every poll forever costs a failed read on every
   poll forever — the same outage, arriving more slowly.

`optional_read` in the blueprint does the second. `detect_model` does the
first, and bounds itself too.

### What this looks like in a shipped driver

Most Modbus drivers here route every read through one helper. Copy it, change
the manufacturer name, and use it everywhere the driver reads a register:

```lua
local GIVE_UP_AFTER = 3
local read_failures = {}

local function probe_read(addr, count, kind)
    if (read_failures[addr] or 0) >= GIVE_UP_AFTER then return nil end
    local ok, regs = pcall(host.modbus_read, addr, count, kind)
    if ok and regs and regs[1] ~= nil then
        read_failures[addr] = nil
        return regs
    end
    local failures = (read_failures[addr] or 0) + 1
    read_failures[addr] = failures
    if failures == GIVE_UP_AFTER then
        host.log("info", string.format(
            "Example: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end
```

Three attempts rather than one: a single failure is not proof a register is
missing, and the link may just have been slow. Bounded is the property that
matters, not the number. A restart re-probes, so firmware that gains the
register is picked up without anyone editing the driver.

Wrap the driver's own typed helpers — `read_i16`, `read_u32_be` and the like —
around `probe_read` rather than giving each its own `pcall`. That fixes every
call site at once and leaves one place to reason about.

### Check your driver before you open the pull request

```bash
make absent-register-report ID=example
```

It takes every register your driver reads, makes that one stop answering, and
watches ten polls. A line ending `SETTLED 0` with `EMITTED` above zero is the
outage: the driver decided it can live without the register and then went on
paying for it.

`drivers/tests/test_absent_register_settles.py` holds every driver to this.
A new driver must be clean. The drivers that already carried this debt when it
was first measured are listed in `absent-register-baseline.json`, and that file
may only shrink.

## The same rule for writes

A device can refuse a write as easily as it can fail a read, and one path
writes without anyone asking: `driver_default_mode()`. The host calls it on
lease expiry, on the telemetry watchdog, on shutdown. Nothing there can say no,
so a driver that writes whatever the device answers goes on writing for the
life of the session, one log line per tick.

Count refusals the way you count missed reads, and stop:

```lua
local WRITE_ATTEMPTS = 3
local write_failures = 0

local function block_worth_writing()
    return write_failures < WRITE_ATTEMPTS
end

local function note_write(err)
    if err == nil or err == "" then
        write_failures = 0   -- one success proves the register is there
    else
        write_failures = write_failures + 1
    end
end
```

Three rather than one, for the same reason as reads: a busy bus is not proof.
The count lives in the process, so a restart always tries once — which is what
the startup reset is for. A single success clears it, so firmware that gains
the register is picked up without waiting for a restart.

Do not gate this on the model instead. The device can be holding a state your
driver did not set — a container that died mid-command, an older driver
version, another EMS on the same bus — and a model label tells you nothing
about that. Whether the device took the write does.

Once it has given up, report the default as held rather than failed. A
permanent `false` has the watchdog escalate against a device that was never
under control.

```bash
make refused-write-report ID=example
```

`drivers/tests/test_refused_write_settles.py` holds every driver to this, with
`refused-write-baseline.json` recording what already shipped. `sungrow` is the
worked example, and the only one clean when this was first measured.

## Sign convention

**Positive watts flow into the site.** Every driver, every device, no
exceptions.

| Stream | Positive means |
|---|---|
| `meter` | importing from the grid |
| `pv` | never — generation is always negative |
| `battery` | charging |
| `ev` | charging the car |

Devices disagree with this constantly. Negate at the boundary, in one place,
with a comment recording what the device's own convention was.

## Never fabricate

A zero means *the device told me zero*. It must never mean *I could not read
it*. A fabricated zero flows into a site's energy totals and cannot be told
apart from a real one afterwards.

- A field that did not answer is left out.
- A stream whose defining reading did not answer is not emitted.

## A hybrid inverter may have no battery

The rule above bounds the *reads*. This is what to do with the answer.

*Never fabricate* covers a read that failed. This is the case where nothing
failed: the device is healthy, every register you asked for came back, and the
battery still is not there.

Nearly every hybrid inverter is sold in two configurations — with storage and
without it. Same model number, same firmware, same register map; one site has a
pack on the DC bus and the next has bare terminals. The SG12RT further up is
this same fact arriving as an outage instead of as a wrong number. A PV-only
commissioning is not a fault and not an edge case. It is half the product line.

How the absence reaches you is vendor-specific, and you cannot pick one and
assume the rest:

- the ESS registers stop answering at all (Sigenergy)
- they answer, with a plain zero
- they answer with a not-present sentinel — `0xFFFF`, `0x7FFFFFFF`, NaN.
  `sma` and `solis` already carry helpers for exactly this
- the read comes back a Modbus exception

**The rule.** Fill each battery field only from a register that answered, and
emit the `battery` DER only when at least one of them did.

```lua
local battery = {}
if bat_regs then battery.w   = decode(bat_regs) end
if soc_regs then battery.soc = decode(soc_regs) end

if bat_regs or soc_regs then
    host.emit("battery", battery)
end
```

Three things this is not:

- **Not a model-number check.** The same model code covers both
  configurations, and a hybrid shipped under a device-type code you have not
  been taught still has to work. The device knows. Read it.
- **Not a config flag.** `skip_battery` and friends are a reasonable
  *override* for a dev rig, but they are the wrong primary mechanism: they
  only work when somebody already knew to set them, and the site nobody told
  the driver about is exactly the one that reports wrong. Detect first, and
  let config override.
- **Not a `ders` change.** `ders` says what the driver can produce, not what
  one site has. Leave `battery` in it — it also reaches the signed artifact,
  so removing it costs a version for nothing.

**Why a zero is worse than silence here.** `soc = 0` does not read as "no
battery". It reads as an empty pack that can absorb charge — so the planner can
dispatch against storage that is not installed, and every resulting write lands
on a register the plant does not implement. It is also indistinguishable from a
real pack that has just run flat, so nothing downstream can separate the two
afterwards.

A screen of the catalog when this was written: 24 drivers emit both `pv` and
`battery`, and 20 of them emit the battery DER with no guard on whether any
battery register answered. Two of those 20 (`ferroamp`, `zap`) gate it on
configuration or on API discovery instead — better than nothing, still not
detection. The rest default their fields to zero and emit regardless; that was
spot-checked by hand on `goodwe`, `growatt`, `kostal`, `huawei` and `foxess`.
`sigenergy` 1.1.3 is the worked example of the fix.

## Numbers

Two bugs have shipped here that both look like nothing:

**Splitting 32-bit values.** Combine two registers into one 32-bit word and the
sign flips on a build where Lua integers are 32 bits — `0x80000000` is itself
negative there. Twelve drivers had this. Work on the 16-bit halves; the
blueprint shows how.

**Scaling back into infinity.** A decoder can correctly refuse infinity and
then hand you float32's largest value, which becomes infinity the moment you
multiply by 1000. Guard every scaled reading. The blueprint's `finite` does it.

## Host API

The full list is in [`spec/host-api-profile.json`](../spec/host-api-profile.json),
enforced by `tools/host_api_check.py`.

FTW and Blixt L1 spell some functions differently — `modbus_write` against
`write`, `millis` against `now_ms`. **Both are correct.** Each is the real API
of a shipping host, and a host that wants the other's drivers adds aliases;
FTW did exactly that in about thirty lines. Use whichever your target speaks.
What no host can rescue is a call to a name that exists nowhere, which is the
one thing the check enforces.

**Arithmetic is not a host service.** A float decoder or a scale factor lives
in your driver, because it is maths, not I/O. Thirty-five drivers once called
decode helpers that existed only in the test mock — they passed every test here
and would have failed on hardware.

**The sandbox removes** `require`, `dofile`, `load`, `os`, `io` and `debug`. A
driver is one self-contained file. Helpers get copied between drivers rather
than shared, and that is the accepted cost of the guarantee.

## Adding your driver

```bash
cp blueprint/BLUEPRINT.lua drivers/lua/mydevice.lua
```

Then write `manifests/mydevice.yaml`. The manifest and the driver's own
`DRIVER` table must agree on the version; `make bump-driver ID=mydevice` moves
both.

### Record what you decoded it from

A driver is only ever as current as the vendor document it was written from,
and that document does not hold still. A register renumbered, a parameter
added, a scale corrected in a new revision — none of it announces itself. The
driver goes on decoding the old map and reporting a plausible wrong number,
and it is a human noticing on a real site months later that ends it.

So record the documents you worked from, at the most durable URL you can find:

```yaml
upstream_docs:
  - url: "https://www.nibe.eu/webdav/files/myuplink_changelog/nibe-n.pdf"
    title: "NIBE S-series myUplink register/parameter changelog"
    kind: changelog
    url_stability: stable
```

Only `url` is required. `kind` is one of `changelog`, `register_map`,
`manual`, `api_docs`, `firmware_notes`, `other`. `url_stability` says how much
a broken link means — `committed` (the vendor promises the URL is permanent),
`stable` (stable in practice), `volatile` (dated or versioned links that
rotate), `unknown`. `spec/manifest-v2.md` has the full field reference.

`.github/workflows/watch-upstream-docs.yml` fetches each URL weekly and opens
a tracking issue when a document changes or disappears, so the driver gets
re-read against the new material rather than quietly falling behind. It is
descriptive metadata only: it never reaches `index.yaml` and changes nothing
about how the driver installs or runs. `make watch-upstream-docs` runs the
check locally without touching the baseline.

Two things it cannot do. A document behind a login or a vendor portal is not
fetchable — put that reference in a comment in the driver instead, where it
still tells the next reader where to look. And detection is a hash of the
bytes, so a rebuilt PDF can flag a change that isn't one; a flagged document
is a prompt to look, not proof the registers moved.

Only drivers that declare the field are watched. A driver with no entry is one
nobody will be warned about.

```bash
make test-driver ID=mydevice
make check
```

`make check` regenerates `index.yaml`, `devices.yaml`, `support-status.json`
and the manifest hashes. Commit what it produces — it fails if those are stale.

## Testing

The harness is at `drivers/tests/lua_harness/`. `host_mock.lua` lets you set
registers, fail specific addresses, and inspect what was emitted:

```lua
host._modbus_registers.input[5016] = {3000, 0}     -- LE: low word first
host._modbus_read_fail_addresses[13020] = "Illegal Data Address"
```

`tests/test_blueprint.py` is a worked example, including the test that matters
most: poll a device repeatedly and assert that failed reads per poll settle to
zero. If they do not, the site goes offline.

**Keep the mock honest.** Every time it has drifted from the real host it has
hidden a real bug — it once implemented decode helpers no host provided, which
is how thirty-five broken drivers passed CI for months. If the host does not
have it, the mock must not either.

## Drivers promoted from FTW

37 drivers here came from FTW, where they have run on customer sites for
months. They are kept **byte-identical** to `baselines/ftw/drivers/`, which is
what makes their provenance checkable.

Two consequences:

- The test suite skips catalog conventions for them, because FTW tests them in
  Go. Identity is by content: **edit one and every check applies to it again.**
- Their `DRIVER` table states FTW's id and version; the file name and manifest
  state this repository's. Two lineages, deliberately, because making them
  agree would mean editing a file we keep unmodified on purpose.

If you need to change one, just change it. The tooling will notice and start
holding it to this repository's rules, which is the correct outcome.
