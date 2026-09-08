# Introduction

Astrid is an operating-system project for composable software. Its current
release is a hosted runtime on macOS and Linux; a standalone operating system
is the direction, not something this release already boots.

The thesis is simple: **software should compose without inheriting each
other's authority**. Capsules run in WebAssembly sandboxes, communicate through
versioned interfaces and an event bus, and use host capabilities subject to
runtime enforcement. Principals separate identity, grants, and durable state.

That is especially useful for agents: models can choose actions without being
the authority that permits them. But Astrid is not tied to LLMs. Tools, services,
model providers, and agent loops are compositions above the kernel, not built-in
product choices. The kernel routes communication and enforces boundaries rather
than owning application behavior.

These are architectural mechanisms, not a promise that every implementation is
bug-free or that every action appears in one audit log. The detailed chapters
distinguish the mechanisms and their enforcement paths.

## What this book covers

Start with [Operating the 2026.9 Runtime](operating-2026-9.md) for the current
hosted lifecycle, volume, and platform contract. The getting-started chapters
have been aligned with that release.

The deeper chapters explain the capsule model, host ABI, event bus, storage,
identity, and security. Some retain older implementation snapshots and source
line anchors. They are useful design references, but an old directory layout
or code excerpt is not an instruction to recreate that layout in a current
installation. Where this matters, a compatibility note points back to the
current operating guide.

## How to read it

- **Run the runtime:** [Getting Started](getting-started/see-it-work.md).
- **Write a component:** [Your First Capsule](getting-started/your-first-capsule.md),
  then the Capsule Model and Host ABI chapters.
- **Understand authority:** the Security chapters, including capabilities,
  tokens, delegation, and enforcement paths.
- **Change a contract:** the Evolution chapters and RFC process.

For the longer argument behind the project, read the
[Afterword](afterword/the-labyrinth.md). It is optional; the technical chapters
stand on their own.
