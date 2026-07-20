# Blixt L1 as the Lua runtime reference

This repository owns Sourceful driver source, package metadata and versions.
The private Device Support publisher owns official signed artifacts. Those
roles do not replace the runtime architecture David built in Blixt L1. Blixt
is the main reference for hardware-near Lua execution.

## Preserve from Blixt

- LuaJIT through `mlua`, with a target-specific ABI rather than pretending it
  is the same runtime as FTW's GopherLua;
- one driver manager per hardware path and explicit device arbitration;
- queued work with control preemption, poll coalescing and bounded ordering;
- batched Modbus reads and typed emission adapters;
- `DRIVER_MANIFEST`, lifecycle probing and static/live provides validation;
- separate telemetry and control modes.

These are target runtime duties and remain in Blixt. Device Support does not
become a generic remote Lua executor.

## Add around the runtime

Blixt must resolve only a `blixt-l1` artifact whose compatibility record names:

- product `blixt-gateway` and a bounded host SemVer range;
- runtime `luajit`, semantics `lua-5.1`, version `2.1`;
- ABI `mlua-0.10-luajit21-source-v1`;
- host profile `sourceful.host/blixt-l1/v1` and a bounded API version.

Before load, the host verifies the Ed25519 package envelope, compatibility,
artifact URL binding, byte length and SHA-256. Verified bytes are staged in a
content-addressed cache and activated atomically; rollback selects an earlier
verified package. Package provenance records the exact source commit and input
hash. Runtime/compiler build materials belong to provenance, not compatibility.

The runtime still needs explicit instruction/time/memory budgets, permission
enforcement for every host call, and structured command results. Controllable
drivers also need host-owned leases whose expiry, driver failure and shutdown
all invoke `driver_default_mode` before control can be considered safe. None of
those requirements is granted merely by loading package metadata.

## Portable source and target adapters

A single reviewed Lua source may produce artifacts for more than one target
when its target contract tests prove that it uses the common Lua 5.1 subset and
only shared host calls. SDM630 is that minimal case. The package still contains
separate FTW and Blixt artifact records so either target can diverge later.

When runtime helpers, concurrency assumptions, memory limits or lifecycle
semantics differ, this repository keeps one canonical driver definition with
target-specific source adapters or generated artifacts. Byte-identical Lua is
never a goal. Zap follows the same rule when it becomes an active target.
