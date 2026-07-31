# EV charger bench: commissioning, reset and local connectivity

Operator notes for the chargers on the Sourceful test bench. Covers how to get
into each unit, how to point it at a local OCPP server, and how to factory reset
it when an installer login blocks you.

These are steps the code cannot state. Driver behaviour lives in the driver and
its tests.

## Bench inventory

| Device | Rating | Identity | Local path | Existing driver |
|---|---|---|---|---|
| Charge Amps Dawn | 22 kW 3P 32A | P/N 130297 R3, S/N 020109885973D | OCPP 1.6J | none |
| Charge Amps Luna | 22 kW 3P 32A | P/N 131462 R1, S/N 020100006021L | OCPP 1.6J | none |
| Charge Amps (silver, RFID) | — | label not captured | OCPP 1.6J | none |
| Zaptec (Go / Go 2 / Pro) | — | label not captured | OCPP 1.6J, cloud-gated | `zaptec` (HTTP, read-only) |
| Easee Charge Up | up to 22 kW | label not captured | native OCPP 1.6J, beta | `easee` (Modbus), `easee_cloud` (HTTP) |
| Ambibox V2G / InterControl ambiCHARGE 11 kW | AC in 400 V 3×16 A, DC out 120–500 V 30 A | S/N 20251200055 00115, 2025w45 | MQTT | `ambibox_v2x` (MQTT, control) |

The ambiCHARGE is DC-coupled and bidirectional. It is the only bench unit that
already has a working driver path, and it does not use OCPP.

## Charge Amps (Dawn, Luna, Halo, Aura)

Charge Amps migrated from its proprietary CAPI protocol to OCPP 1.6J, so every
current model can be pointed at a third-party central system.

### Getting in

Access depends on the generation.

**Halo and Aura** expose a WiFi access point:

1. Power the unit.
2. Join the WiFi network named `HALO_<serial>` or `AURA_<serial>`.
3. Browse to `192.168.250.1`.
4. Enter the password from the letter shipped with the charger.
5. Settings are behind the arrow in the top-right corner.

**Dawn and Luna** use the Charge Amps Installer app over Bluetooth:

- [Charge Amps Installer — Google Play](https://play.google.com/store/apps/details?id=com.chargeamps.installer)
- [Charge Amps Installer — App Store](https://apps.apple.com/gb/app/charge-amps-installer/id6446256364)

The app authenticates with a PIN and is intended for authorised electricians.

> **Bluetooth is only discoverable for the first 10 minutes after power-up.**
> If the unit has been energised longer than that, cut the fuse, wait, power it
> back on, and start the search immediately. This is the single most common
> reason a bench unit "will not connect".

### Pointing at a local OCPP server

Set the backend URL to the FTW host. The scheme must be `ws://` or `wss://`:

```
ws://<ftw-host>:9000/<charge-point-id>
```

- Halo / Aura: Settings → OCPP menu.
- Dawn / Luna: CPMS settings → *Connect to other CPMS*. The charge point ID is
  editable during installation.

Restart the charger after applying.

Two things to do **before** switching:

1. Activate RFID locks in <https://my.charge.space> remote control settings.
   Doing this after the OCPP switch does not work.
2. Accept that cloud and local are mutually exclusive. A unit talking to a local
   central system is no longer on the Charge Amps cloud, and the Charge Amps app
   loses it.

Firmware floors observed in the field: Halo ≥ 158, Dawn ≥ 1.3.5.

### Factory reset

Halo and Aura reset from the local interface: **System → Factory Reset**.

There is no documented hardware reset button, which means the reset itself is
behind the password. If the letter is missing on a second-hand or demo unit,
Charge Amps support (<support@charge-amps.com>) has to clear it — plan for that
lead time rather than hunting for a button.

If a unit hangs during start-up, break the fuse for a minute and re-energise.
That is a power-cycle, not a reset, and it keeps the configuration.

### Known rough edges

Reported by other OCPP integrations, worth designing the driver around:

- Remote stop is unreliable; some units bounce straight back to *on*. The
  working control path is current-based — 0 A to stop, target amps to start.
- Three-phase voltage and current reporting is inconsistent per phase.
- Dual-socket Aura has connector-ID tracking problems.
- Halo occasionally drops the OCPP connection and needs a restart.

The current-based control workaround matters: a driver that models stop as
"SetChargingProfile to 0 A" rather than `RemoteStopTransaction` will behave.

## Zaptec (Go, Go 2, Pro)

Box-level OCPP 1.6J exists, but **it is gated behind the Zaptec cloud portal**.

Firmware floors: Go EU 2.4.2.4, Go UK 2.5.1.0, Go 2 3.2.1.0, Pro 7.5.4.0
(serial ZPR080000 and up).

Enabling it requires all of:

- the `Allow OCPP 1.6J` user-group permission,
- partner access granted by the installation owner via lookup key,
- the OCPP URL set in the Zaptec Portal — there is no installer-app or
  on-device path.

URL rules: `ws://` or `wss://`, and **do not append the serial** — Zaptec adds it
in uppercase automatically. So for an endpoint of `ws://host:9000/ocpp/ZAP123456`
you enter `ws://host:9000/ocpp`.

To revert: Settings → Authentication → Type, change away from OCPP 1.6J, then
Circuits → Charger → Settings and disable stand-alone mode. No factory reset is
documented.

> This is the one bench unit whose local path cannot be unlocked from the bench.
> Without a Zaptec partner account with OCPP permission, it stays on the existing
> read-only `zaptec` HTTP driver.

## Easee Charge Up

Easee offers two OCPP modes:

- **Cloud-emulated** — charger talks to Easee Cloud, which proxies to your
  back-office. Fully supported, but keeps the cloud dependency.
- **Native** — charger talks straight to a 1.6J server with no Easee proxy.

Native is what removes the cloud dependency at runtime, and it answers the
question in `charger-photos/easee.txt`: yes, local is possible.

The catch is provisioning. Native OCPP is switched on through Easee's **cloud
API**, not from the app or the device:

1. `POST /v1/connection-details/{serialNumber}` — store the OCPP config, with the
   backend URL in `websocketConnectionArgs`.
2. `POST /v1/connections/chargers/{serialNumber}` — apply it.
3. `GET /v1/connection-details/{serialNumber}` — verify.

Requirements and limits:

- Easee account, and the site must have Easee selected as operator.
- Firmware ≥ 328.
- **Beta** — Easee recommends test environments only.
- Documented for `wss://` with CA certificates; plain `ws://` to a LAN host is
  not explicitly supported, so expect to terminate TLS.
- Revert by pairing with another operator or setting `connectivityMode` to
  `OcppOff`.

So the cloud dependency moves from runtime to a one-time commissioning step. That
is a real improvement over `easee_cloud`, but it is not a cloud-free flow.

## Ambibox V2G / InterControl ambiCHARGE

Already covered by `ambibox_v2x` (MQTT, control enabled, `v2x_charger`). The
driver defaults to `sid-os.local:1883`. Nothing to build unless bench testing
shows the ambiCHARGE topic set differs from the Ambibox unit the driver was
written against.

Manufacturer is InterControl (Turku, Finland); Ambibox is the brand.

## What this means for FTW

A local OCPP central system unlocks Charge Amps (three bench units, no driver
today) and Easee natively, and would unlock Zaptec if partner access appears.

FTW had exactly this and removed it. `go/internal/ocpp/` held a 1.6J central
system — `config.go`, `handlers.go`, `server.go` plus tests, on
`github.com/lorenzodonini/ocpp-go` — retired as unused in srcfl/ftw#578. The
starting point is that commit, not a blank page.

## Sources

- [Charge Amps OCPP configuration (eCarUp wiki)](https://sites.google.com/smart-me.com/wiki-english/ocpp/charge-amps)
- [Charge Amps: migration to OCPP](https://www.chargeamps.com/article/migration-to-ocpp/)
- [Charge Amps OCPP 1.6J field reports](https://github.com/lbbrhzn/ocpp/discussions/816)
- [Zaptec OCPP 1.6J configuration guide](https://docs.zaptec.com/docs/zaptec-go-ocpp16j-configuration-guide)
- [Easee native OCPP introduction](https://developer.easee.com/docs/native-ocpp-introduction)
- [Easee OCPP commissioning for users](https://developer.easee.com/docs/ocpp-commissioning-easee-users)
