# Getting Started: See It Work

The fastest way to understand Astrid is to run it. In a few minutes you go from nothing to a working agent, then look underneath to see why it is contained.

Commands follow a noun-verb shape (`astrid capsule list`, `astrid caps list`). Run `astrid <command> --help` for the exact flags your build accepts.

## Install

Astrid is three binaries that work together: `astrid` (the CLI you type into), `astrid-daemon` (the kernel), and `astrid-build` (the capsule compiler). You only ever invoke `astrid`; it starts the daemon for you.

```bash
cargo install astrid
```

Or build from source:

```bash
git clone https://github.com/unicity-astrid/astrid
cd astrid && cargo build --release   # binary at ./target/release/astrid
```

## Set up a runtime

`astrid init` walks you through it. It fetches a *distro*, a curated set of capsules for a use case, lets you pick a provider, resolves any configuration the capsules need, and installs them with their manifests.

```bash
astrid init
```

A distro is a `Distro.toml` manifest, and `init` writes a `Distro.lock` pinning every capsule by BLAKE3 hash, so the same `init` reproduces the same fleet. You can point it at your own with `astrid init --distro @yourorg/your-distro`.

## Talk to an agent

The built-in chat is the frontend. Give it a provider key and go:

```bash
ANTHROPIC_API_KEY=sk-... astrid chat
```

The first time you run it, the CLI auto-starts the daemon as a background process, connects over a Unix domain socket, and streams the agent's output. Ask it to do something real, read a file, fetch a page, write a note, and watch it call tools.

Nothing about that agent is special yet. The interesting part is what it could not do, and what it left behind.

## Look underneath

Open a second terminal. Everything the agent just used is inspectable.

**The fleet.** The agent did not call one big program. It called a set of small, single-purpose capsules, each a WebAssembly module that owns one job.

```bash
astrid capsule list
```

You will see a filesystem capsule, an HTTP capsule, a provider capsule, an orchestration capsule, and so on. None of them can do another's job. Why the system is built this way is [Designing Capsules](../capsule-model/designing-capsules.md).

**The authority.** Every capability the agent has is explicit. There is no ambient power.

```bash
astrid caps list
```

A capsule that reads files declared `fs_read` and nothing else. The agent could not open a socket, spawn a process, or touch a path that was never granted, not because it was asked not to, but because the host checks a signed grant before each operation and there was no grant to check. That is the whole thesis: authority is a capability the kernel enforces, not an instruction the model is trusted to follow.

**The record.** The daemon writes structured logs of what ran.

```bash
astrid logs
```

Beneath the logs, every sensitive action is also appended to a hash-linked, signed audit chain, each entry sealing the hash of the one before it, so the history cannot be silently rewritten. The chain is covered in [The Cryptographic Audit Chain](../storage/audit-chain.md). A dedicated `astrid audit` inspector is in progress; until it lands, `astrid logs` is the operator's window.

## What you just saw

A capable agent, running at full speed inside a boundary it cannot cross, calling tools that are each contained and capability-gated, leaving a record that cannot be quietly altered. You did not have to trust the agent in order to run it. That is Astrid in one session.

From here:

- To build your own capsule, read [The Capsule Manifest and Engines](../capsule-model/manifest-and-engines.md) and [Designing Capsules](../capsule-model/designing-capsules.md).
- To understand the boundary, read [The Five-Layer Security Gate](../security/five-layer-gate.md) and [Capabilities, Tokens, and Delegation](../security/capabilities-and-tokens.md).
- For why any of this is shaped the way it is, the [Afterword](../afterword/the-labyrinth.md).
