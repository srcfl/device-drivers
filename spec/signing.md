# Driver signing boundary

Sourceful driver releases use Ed25519 envelopes to bind each package and index
to its content, compatibility rules, permissions and source commit. The public
repository never contains an official private key or a release credential.

## Public build

Public CI validates source and builds unsigned candidates. Contributors can
run the same path locally:

```bash
make package-driver ID=sdm630 TARGET=ftw-core
```

An unsigned candidate is test input. A host must not treat it as an official
release or activate it through the normal update path.

## Official release

The private Device Support publisher checks out an exact commit from this
repository. It repeats validation, builds deterministic artifacts, signs the
canonical package envelope and publishes a signed beta index. Stable promotion
keeps the exact source commit and artifact hashes from the tested beta.

The publisher supplies keys and release credentials at run time. Those inputs
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
