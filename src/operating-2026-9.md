# Operating the 2026.9 Runtime

This page covers the hosted 2026.9.0 runtime. Astrid's standalone operating-system
direction is not a claim that this release is a bootable OS.

## Runtime state and installed software

The durable runtime authority is `astrid.volume`. While the daemon runs, it
materializes the working projection needed by runtime consumers. Clean stop
retires that projection; the stopped runtime root is exactly the volume.
Executable release binaries belong outside that mutable runtime root.

Older chapters describe host-directory stores, content-addressed `bin/`
files, and overlay implementations. Those descriptions are not instructions
to reconstruct a 2026.9 installation. In particular, the old `secrets/`
directory is a migration source, not the current secret authority.

Upgrade uses the supported runtime migration path. Preserve the legacy source
and follow the selected package's upgrade instructions; do not manually delete
legacy directories or manufacture a migration receipt. Mount visibility alone
does not prove that migration or a subsequent restart succeeded.

## Principals and composition

A capsule package and its durable registration do not grant all principals
permission to invoke it. Keep installation, principal membership, and invocation
authority distinct. A distribution defines its selected membership; an agent
host should not install every available capsule merely to discover tools.

Models are optional components. The same runtime can host services and tools
without an LLM, or compose a provider with an agent loop and tool broker.

## Lifecycle

Explicit `astrid start` requests a persistent daemon. Client-owned automatic
startup can retire when its owning connections are gone. MCP clients must hold
their connection and report their sessions; a successful server listing alone
does not demonstrate a successful tool invocation.

Multiple stdio clients may still require separate adapter processes. Do not
read shared daemon ownership as a guarantee of one process for all clients.

## Native filesystem views

macOS uses FSKit and its signed filesystem app; Linux uses FUSE. A mount is a
view into runtime storage, not a new APFS volume and not a replacement for the
host filesystem. Principal views and administrative root views have different
authority. Mount labels can be configured without changing Astrid's internals.

Use `astrid storage --help` and the installed version's mount help for the
chosen view. A meaningful round-trip check includes write, read, rename, sync,
unmount, and restart—not just Finder navigation or reported capacity.
Reported capacity is not a claim that the volume file preallocates that space.

## Source and scope

This compatibility pass is grounded in runtime commit
[`28034075`](https://github.com/astrid-runtime/astrid/tree/280340757cb67478937184e352c286bb4384a6e5),
including `crates/astrid-core/src/dirs.rs`, runtime layout admission and
retirement, and the CLI lifecycle commands. Detailed chapters retain older
source anchors where noted. Consult the release's source when changing those
implementation details; this pass is not a re-certification of every chapter.
