# Driver signing boundary

FTW's driver channel uses Ed25519 signatures to bind release data to its
content and source commit. The public repository never contains a private key
or release credential.

## Public build

Public CI validates source and signs nothing. A pull request can produce
unsigned test output only. A host must not treat it as a release or activate
it through the normal update path.

## FTW release

`.github/workflows/ftw-drivers-release.yml` builds a read-only FTW artifact for
every catalog driver under the rules in `ftw-channel.json`. From an exact
reviewed commit, it signs an
`ftw.manifest/v1` beta and uploads each content-addressed Lua file before the
manifest. Stable promotion accepts only the exact commit already published to
beta. FTW pins the public key and keeps install and activation explicit.

The FTW key signs distribution integrity. It does not certify a device, change
the driver's tier or grant control rights.

The release workflow supplies the signing key at run time. It must not enter
source files, logs or build output.

## Canonical bytes

The channel signs the manifest payload's canonical JSON bytes, not a
stand-alone artifact hash: UTF-8, sorted object keys, compact separators, no
NaN or Infinity and no trailing newline in the signed bytes. The stored
`manifest.json` ends with one newline.
