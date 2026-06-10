# Designing Capsules

The kernel is dumb on purpose, and the capsule model inherits the consequence: a capsule should do one thing. The runtime is built to compose many small capsules over the bus, not to host a few large ones. This is not a style preference. It is the shape the security model, the IPC contract, and the lifecycle all reward.

The lineage is old. Doug McIlroy's rule for Unix was to write programs that do one thing and do it well, and write programs to work together. A microkernel makes the same bet at the operating-system layer: keep the privileged core minimal and push function into small, replaceable services. Astrid is that bet applied to agents. A capsule is a process, the bus is the pipe, the manifest is the contract. The discipline that kept Unix pipelines and microkernel services durable is the discipline that keeps a capsule fleet durable.

## Why small wins here

In Astrid the argument is not aesthetic. Four properties of the runtime pay out directly when a capsule stays small.

**Least privilege is a function of scope.** A capsule declares the host resources it needs in its `[capabilities]` block, and the kernel grants nothing more. A capsule that only reads files needs only `fs_read`. Fold filesystem writes, network fetches, and process spawning into the same capsule and its manifest now reads `fs_read`, `fs_write`, `net`, `host_process`: a standing attack surface. A prompt injection that reaches a single-purpose file reader can, at worst, read files it was already allowed to read. The same injection inside a do-everything capsule can exfiltrate over the network and execute on the host. Blast radius is bounded by the smallest capability set you can get away with, and the smallest set comes from the smallest job.

**Composition is the default, not an integration step.** Capsules do not call each other. They publish and subscribe to typed events on the bus, and the kernel routes them blind. A capsule that needs a capability it does not own does not grow to absorb it; it publishes to the capsule that does. Adding behaviour to the system means adding a capsule and a manifest, never forking a monolith. The seams are the bus topics, and they are already there.

**Reuse follows focus.** A filesystem capsule that does only files is used by every workflow that touches files. A capsule that bundles files with one team's bespoke logic is used by exactly that workflow and no other. The distribution model composes a running system from a set of capsules, and the more focused each one is, the more compositions it can join.

**Independent lifecycle.** Capsules load, unload, and hot-reload independently. Install a small capsule and its tools appear on the live tool surface without restarting the others. Replace its implementation and nothing else moves. A crash takes down its slice and not the system, and an audit record names the one capsule that acted rather than a tangle of concerns sharing a process.

## The fleet is the proof

Watch a single tool call cross the running system. The react capsule runs the agent loop and decides the model wants to write a file. It publishes a tool request on the bus. The router capsule, which owns no tools of its own and is pure stateless middleware, forwards the request to the capsule that owns the tool. The filesystem capsule performs the write and publishes the result. The router relays it back. The react capsule records it and continues the loop.

Four capsules, one tool call, and not one of them holds the whole picture. The react loop knows nothing about how a file is written. The filesystem capsule knows nothing about why. The router knows neither, only how to move a message from a name to an owner. Each is a black box to the others, coordinating entirely through typed events. That is the system working in unison precisely because no single part tries to be the whole.

The shipped fleet is built this way throughout: a filesystem capsule for files, an HTTP capsule for fetches, a shell capsule for host commands, a prompt-builder for assembling prompts and tool schemas, a session capsule for conversation state, a memory capsule for recall, a registry for providers and models. Each owns one domain. None reaches into another's.

## The monolith, and why it costs more

The tempting shortcut is one capsule that reads files, fetches URLs, runs shell commands, and remembers things, so a workflow can call a single tool surface. It works, and then it does not:

- Its manifest must request every capability its broadest tool needs, so its least-privilege floor is the union of all of them. The blast radius is permanent and maximal.
- It cannot be reused in part. A workflow that wants only file access drags in the network and process capabilities it never uses.
- A bug or a compromise anywhere in it implicates everywhere in it. The audit trail conflates a file read, a network call, and a process spawn under one principal and one source.
- It evolves as a unit. A change to its HTTP handling risks its filesystem handling, and a reload swaps all of it at once.

Every one of these is the small-capsule advantages run in reverse.

## Rules of thumb

- **One responsibility per capsule.** If you can name two unrelated things the capsule does, it is two capsules.
- **Read the manifest as a job description.** If the `[capabilities]` block spans unrelated domains (files and network and process), that is the smell, not the feature.
- **Compose, do not embed.** Need another capability? Publish to the capsule that owns it. Reach for a new `[capabilities]` entry only when the capability genuinely belongs to this capsule's one job.
- **Keep a capsule's tools cohesive.** The tools a capsule exports should share a domain. A capsule whose tools have nothing in common is a bundle, not a capsule.
- **Push state to the capsule that owns it.** Routing and transformation capsules should be stateless, like the router; durable state belongs in the session, memory, and KV layers that exist for it.
- **Declare the narrowest capabilities that work.** The manifest is the contract the kernel enforces and the first thing a reviewer reads. Make it say as little as the job allows.

A capsule done right is small enough to hold in your head, declares a manifest you can read at a glance, and disappears into a fleet that does something large because each part does something small.

## See also

- [The Kernel Is Dumb](../foundations/kernel-is-dumb.md)
- [Tools as an IPC Convention](../bus/tools-as-ipc.md)
- [Capability Gating](../host-abi/capability-gating.md)
