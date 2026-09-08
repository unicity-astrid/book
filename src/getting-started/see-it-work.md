# Getting Started: See It Work

Start with the runtime itself. A model account, agent loop, and product
distribution are not prerequisites for running Astrid.

## Install

Follow the [runtime installation instructions](https://github.com/astrid-runtime/astrid#install)
for your platform. The 2026.9.0 release targets macOS Apple Silicon and Intel,
and Linux x86_64 and ARM64 with GNU and MUSL archives. Windows publication is
not part of this release.

The CLI, daemon, capsule build tools, and native filesystem providers have
different roles. Use the packaged release when you need its native integration:
a Cargo build is not a substitute for the signed macOS filesystem app.

## Start an uncomposed runtime

```bash
astrid --version
astrid start
astrid status
astrid capsule list
astrid stop
```

A fresh uncomposed runtime has no product capsules. That is intentional:
Astrid does not choose a model provider, agent loop, or application for you.
Explicit `start` keeps the daemon running until stopped. Automatic
client-owned startup has a different lifetime; see
[Operating the 2026.9 runtime](../operating-2026-9.md).

After clean stop, the durable runtime root contains `astrid.volume`.
Starting again restores the working projection. Do not recreate the old
directory layout by writing files beside the stopped volume.

## Choose a composition

A distribution's `Distro.toml` selects capsules for a use case. Select a
source explicitly rather than relying on bare `astrid init` to pick one:

```text
astrid init --distro <source>
```

Use the distribution author's documented source and trust instructions.
The selected distribution determines its capsule membership and onboarding.
Do not assume it contains an LLM provider, filesystem tools, or a chat loop.
Installation and grants are principal-scoped, not machine-wide tool sharing.

If your chosen composition supplies the required chat capabilities and provider
configuration, use `astrid chat`. Otherwise continue directly to
[Your First Capsule](your-first-capsule.md): building a component does not
require an LLM.

## Inspect the running system

```bash
astrid start
astrid capsule list
astrid caps list
astrid logs
```

These show installed capsules, capabilities, and runtime logs. They are not
interchangeable evidence: logs are not the cryptographic audit chain, and an
installed capsule is not automatically available to every principal.

The core idea is composition with explicit authority. The kernel routes
communication and enforces runtime boundaries; tools, models, and application
behavior belong in capsules. See [Designing Capsules](../capsule-model/designing-capsules.md)
and [Capabilities, Tokens, and Delegation](../security/capabilities-and-tokens.md).
