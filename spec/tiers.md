# Driver Tiers

Drivers are classified into three tiers based on authorship, testing, and trust level.

## Core

Maintained by Sourceful Labs AB. Tested on physical hardware. Ed25519-signed.

- **Author**: Sourceful Labs AB
- **Testing**: Hardware-validated, CI-checked
- **Signing**: Ed25519 signature verified by gateway firmware
- **Shipping**: Included by default on all gateways
- **Review**: Changes require `@srcfl/core` team approval

Current core drivers: sungrow, solis, solaredge, sma, huawei, fronius, fronius_smart_meter, deye, pixii, sdm630, ferroamp, ambibox, p1_meter.

## Community

External contributions from the community. CI-validated but not hardware-tested by Sourceful.

- **Author**: Community contributor
- **Testing**: CI syntax, contract, and sandbox checks pass
- **Signing**: Not signed (or self-signed)
- **Shipping**: Available for download, not shipped by default
- **Review**: CI pass + 1 reviewer approval

Community drivers carry a "use at your own risk" label. Gateway firmware logs a warning when loading unsigned drivers.

## OEM

Manufacturer-built drivers, certified by Sourceful.

- **Author**: Device manufacturer
- **Testing**: CI + Sourceful certification process
- **Signing**: Signed by Sourceful after certification
- **Shipping**: Available via manufacturer partnership
- **Review**: Sourceful certification + CI pass

## Promotion Path

```
community → core
```

A community driver can be promoted to core when:
1. Sourceful tests it on physical hardware
2. It passes all CI checks
3. It's signed with the Sourceful Ed25519 key
4. A Sourceful engineer reviews and approves

## Tier in Manifest

The `tier` field in `manifests/*.yaml` determines the tier:

```yaml
tier: core       # Sourceful-maintained
tier: community  # Community contribution
tier: oem        # Manufacturer-built
```
