# Driver tiers

Tiers state support and test evidence. They do not state whether the repository
or release channel is official. Sourceful maintains this public repository and
reviews every tier. An FTW channel signature proves artifact integrity, not a
tier or hardware result.

## Core

Maintained by Sourceful Labs AB and tested on physical hardware.

- **Author**: Sourceful Labs AB
- **Testing**: Hardware-validated, CI-checked
- **Release**: Eligible for a signed host channel after target checks
- **Shipping**: May ship by default for a stated host
- **Review**: Changes require `@srcfl/core` team approval

Current core drivers: sungrow, solis, solaredge, sma, huawei, fronius, fronius_smart_meter, deye, pixii, sdm630, ferroamp, ambibox, p1_meter.

## Community

Community-origin or early-support drivers. Sourceful maintains accepted code in
this repository, but hardware coverage may be missing or narrow.

- **Author**: Community contributor
- **Testing**: CI syntax, contract, and sandbox checks pass
- **Release**: May enter a signed, read-only host channel after target checks
- **Shipping**: Not bundled by default unless the host states otherwise
- **Review**: Required repository checks and maintainer review

Hosts must show the driver's test and support state. A signature must not turn a
community driver into a hardware-tested driver in the UI.

## OEM

Manufacturer-built drivers, certified by Sourceful.

- **Author**: Device manufacturer
- **Testing**: CI + Sourceful certification process
- **Release**: Eligible for a signed host channel after certification
- **Shipping**: Available via manufacturer partnership
- **Review**: Sourceful certification + CI pass

## Promotion Path

```
community → core
```

A community driver can be promoted to core when:

1. Sourceful tests it on physical hardware.
2. It passes all required checks.
3. A Sourceful maintainer reviews the stated support scope.

## Tier in Manifest

The `tier` field in `manifests/*.yaml` determines the tier:

```yaml
tier: core       # Sourceful-maintained with stated hardware evidence
tier: community  # Accepted and maintained with limited support evidence
tier: oem        # Manufacturer-built and certified
```
