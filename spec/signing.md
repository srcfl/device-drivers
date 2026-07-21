# Driver signing boundary

Sourceful driver releases use Ed25519 envelopes to bind release data to its
content, permissions and source commit. The public repository never contains a
private key or release credential.

## Public build

Public CI validates source and builds unsigned candidates. Contributors can
run the same path locally:

```bash
make package-driver ID=sdm630 TARGET=ftw-core
```

An unsigned candidate is test input. A host must not treat it as a release or
activate it through the normal update path.

## FTW release

`.github/workflows/ftw-drivers-release.yml` builds a read-only FTW artifact for
every catalog driver under the rules in `ftw-channel.json`. From an exact
reviewed commit, it signs an
`ftw.manifest/v1` beta and uploads each content-addressed Lua file before the
manifest. Stable promotion accepts only the exact commit already published to
beta. FTW pins the public key and keeps install and activation explicit.

The FTW key signs distribution integrity. It does not certify a device, change
the driver's tier or grant control rights.

## Device Support packages

Device Support may later check out an exact commit, repeat validation and sign
package-v1 data for other products or a higher support level. Those packages
remain separate from FTW's default channel. Both paths use this repository as
their only editable source.

Each publisher supplies keys and release credentials at run time. Those inputs
must not enter source files, package recipes, logs or build output.

## Host checks

Before staging a package, a host must:

1. verify the index and package envelopes against a pinned public key;
2. require a known target and compatible host, runtime, ABI and host API;
3. verify the artifact URL, byte length and SHA-256;
4. keep install separate from activation;
5. retain a prior verified package for rollback.

Package metadata never grants direct hardware control. The host still owns
leases, stale-data stops, command bounds and the driver default mode.

## Canonical bytes

Package v1 signs canonical JSON payload bytes, not a stand-alone artifact hash.
`sourceful.canonical-json/v1` uses UTF-8 JSON, sorted object keys, compact
separators, no NaN or Infinity and no trailing newline in the signed bytes. The
stored JSON file ends with one newline.

See [driver-package-v1.md](driver-package-v1.md) for the full package and
promotion contract.
