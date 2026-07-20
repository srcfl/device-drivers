# Sungrow FTW observe-only pilot

Do not install Sungrow 1.3.1 on a live site. It contains write code even
though package control is off.

Version 1.3.2 is read-only. It has no approved model and firmware profile yet,
so `driver_init` stops before the first device read. Add a profile only after
review of the exact register map.

The telemetry code comes from FTW `drivers/sungrow.lua` at commit
`699873db3e7abe81f76e8110d1cefa4a38ba6efb`, SHA-256
`466a5f8637e6756fc2e1af4197d4edc1845474231413c0016f0e5900acb7b7ac`.
The import keeps the old ID `sungrow-shx` and version 1.1.0 in the source map.
The package uses the canonical alias `sungrow`.

## Site facts required before profile review

- Exact inverter family and model. The known families are SG-CX, SG-RT, SH-RS,
  SH-RT and SH-T. This target lists only FTW's tested SH-RT models. Any other
  family needs its own reviewed protocol profile.
- Exact firmware version.
- Connection type and port. Modbus TCP defaults to port 502.
- Modbus device or unit ID. The target defaults to 1.
- Register-map title, revision and a public link or document ID.

Keep the inverter address, serial number, credentials, site ID and raw config
out of issues and inventory.

## Telemetry comparison

Compare FTW with the inverter screen or vendor app at the same time:

- PV power, lifetime energy, rated power and inverter temperature.
- Battery power and direction, voltage, current, state of charge, charged
  energy and discharged energy.
- Grid power and direction, phase power, phase voltage, phase current,
  frequency, imported energy and exported energy.

Record units, sign, scale, sample time and any value that the inverter or app
does not expose. Stop if the model, firmware or register map differs from the
approved profile.

## Release evidence

Before signed activation, record the exact public commit and tree, private
source lock, built artifact hash and signed beta index entry. In FTW, verify
install, observe-only activation, rollback to the prior driver and the Nova
inventory identity.

All write and control work stays blocked until FTW process and heap isolation,
leases, default mode, command results and physical HIL have passed review.
