# The Kernel Is Dumb

This is the foundational design principle of Astrid OS. The kernel contains no business logic, no cognitive loops, no protocol parsers, and no domain knowledge. Its entire job is to instantiate an `EventBus`, load WASM capsules into the sandbox, and route typed IPC bytes between them under a capability ACL. All intelligence lives in capsules.

Understanding this principle is prerequisite to understanding every other part of the system.

## What the Kernel Owns

The `Kernel` struct is defined in `core/crates/astrid-kernel/src/lib.rs` starting at line 44. Its fields are the complete enumeration of what the kernel is allowed to own. Reading them is the fastest way to internalize the boundary.

```rust
pub struct Kernel {
    pub session_id: SessionId,
    pub event_bus: Arc<EventBus>,
    pub capsules: Arc<RwLock<CapsuleRegistry>>,
    pub mcp: SecureMcpClient,
    pub capabilities: Arc<CapabilityStore>,
    pub vfs: Arc<dyn Vfs>,
    pub overlay_registry: Arc<OverlayVfsRegistry>,
    pub vfs_root_handle: DirHandle,
    pub workspace_root: PathBuf,
    pub home_root: Option<PathBuf>,
    pub kv: Arc<astrid_storage::SurrealKvStore>,
    pub audit_log: Arc<AuditLog>,
    pub allowance_store: Arc<astrid_approval::AllowanceStore>,
    // ... connection tracking, fuel ledger, rate limiter, shutdown signal
}
```

Group these into four categories:

**Message transport.** `event_bus` is the single shared `Arc<EventBus>`. Every capsule, every uplink, and every internal kernel task communicates exclusively through this bus. There is no other inter-component channel.

**Registries and stores.** `capsules` is the live table of loaded WASM capsules. `capabilities` is the persistent capability token store. `kv` is the shared SurrealKV database that capsule-scoped stores layer on top of with `ScopedKvStore`. `allowance_store` holds in-memory session-scoped approval decisions. None of these stores implement any policy. They are read/write surfaces; the policy enforcement happens in the router.

**Security infrastructure.** `audit_log` is a chain-linked, ed25519-signed append-only log. It gets written on every authorized and denied request. `capabilities` holds ed25519-signed capability tokens. `session_token` is the per-boot HMAC token that the CLI must present on the Unix socket. None of these are smart. They verify cryptographic material and record outcomes.

**VFS.** `vfs` is a plain `HostVfs` over the workspace used for kernel-internal paths (capsule discovery, load scans). `overlay_registry` allocates per-principal `OverlayVfs` instances on first use, so agent A's uncommitted writes are never visible to agent B. The VFS enforces path isolation. It does not understand files.

What is absent from `Kernel` is as significant as what is present. There are no LLM client handles. No conversation history. No prompt templates. No tool registries in the domain sense. No session state beyond the connection counter. No knowledge of what any capsule does.

## The Dumb-Router Boundary

The kernel's routing logic lives in two tasks spawned at boot:

**`kernel_router`** subscribes on `astrid.v1.request.*` (`core/crates/astrid-kernel/src/kernel_router/mod.rs`, line 50). It handles the management API: `ListCapsules`, `ReloadCapsules`, `GetStatus`, `InstallCapsule`, `Shutdown`. Every incoming `KernelRequest` goes through a capability preamble at line 199 that calls `authorize_request`, checks the caller's `PrincipalId` against their profile and group config, and either records an audited allow or an audited deny. If denied, the router publishes an error response and returns. If allowed, it executes the mechanical action (read the registry, reload capsules, signal the watch channel) and publishes the response.

Note what these handlers do not do. `ListCapsules` reads `reg.list()` and converts capsule IDs to strings. `GetStatus` reads `kernel.total_connection_count()` and `kernel.boot_time.elapsed()`. `ReloadCapsules` calls `kernel.load_all_capsules()`. There is no handler that interprets capsule behavior, routes tool calls, or makes a decision based on what a capsule said.

**`EventDispatcher`** (`core/crates/astrid-capsule/src/dispatcher.rs`, line 197) subscribes to all events on the bus and routes them to capsule interceptors. It does topic matching, picks the capsules whose manifest declares an interceptor for the event pattern, serializes the event payload to bytes, and calls `invoke_interceptor`. It has no opinion about which capsule is correct to invoke. It reads the manifest and dispatches. The capsule's own WASM code implements the response.

The uplink capsule (capsule-cli) owns the Unix socket listener and the bus-bridge. It is loaded as a capsule, not a kernel component. It publishes `client.v1.connect` and `client.v1.disconnect` onto the bus. The connection tracker in `kernel_router/mod.rs` (line 145) reads these events and adjusts `Kernel::active_connections`. The kernel tracks counts. The uplink owns the protocol.

## The Mental Model: Typed Bus Plus Capability ACL

The simplest accurate description of the kernel: a typed broadcast message bus with a capability access control layer in front of the management API.

The `EventBus` (`core/crates/astrid-events/src/bus.rs`) is a `tokio::sync::broadcast::Sender<Arc<AstridEvent>>` with three additional surfaces:

- `subscribe_topic_as(pattern, label)` for the kernel's own consumers, which filter topic patterns on the receive side
- `subscribe_topic_routed(capsule_uuid, pattern, ...)` for capsule guests, which use a publish-side per-`(capsule_uuid, topic_pattern, subscription_rep)` routing table with per-principal FIFO sub-queues and deficit round-robin fairness
- `publish(event)` which stamps a monotonic sequence number, broadcasts to async receivers, notifies synchronous subscribers, and fans out to the routed table

`AstridEvent` (`core/crates/astrid-events/src/event.rs`, line 74) is the sealed enum of all observable occurrences. Lifecycle variants (`AgentStarted`, `LlmRequestCompleted`, `ToolCallFailed`, and so on) carry typed metadata. The `Ipc` variant carries an `IpcMessage` with a string topic, an optional string principal (`Option<String>`), a monotonic sequence number, and a `IpcPayload`. The `Ipc` variant is the workhorse. Capsule-to-capsule communication is almost entirely `Ipc` messages with structured JSON or typed payloads.

The capability ACL is enforced in `authorize_request` (line 549 of `kernel_router/mod.rs`). It resolves the caller's `PrincipalId` from the `IpcMessage`, loads the caller's profile from the `PrincipalProfileCache`, checks that the principal is enabled, loads the live `GroupConfig` via `groups.load_full()` (a lock-free `Arc` clone from `ArcSwap`), and calls `CapabilityCheck::new(profile, groups, caller).require(required_cap)`. The required capability for each `KernelRequest` variant is determined by `required_capability` (line 488), a pure function with no default-allow branch. Profile resolution failures are treated as deny, fail-closed.

This ACL guards the management API surface. The IPC bus itself is not ACL-gated. An `Ipc` event published to a topic is broadcast to every subscriber. Capsules impose their own authorization on the events they handle. The kernel's role is to ensure that callers who use the management API (`astrid.v1.request.*`) hold the correct capabilities, and to audit the outcome of every such check.

## Why No Business Logic in the Kernel

The kernel is a singleton. One daemon, one process, shared across every uplink, every capsule, and every principal. Introducing business logic at this level has three structural consequences.

First, it creates a coupling point that every capsule must respect. Capsules communicate via IPC events whose schema is governed by RFCs. If the kernel interprets those events, it must be updated whenever a schema changes. Capsule authors cannot evolve their own interfaces without coordinating a kernel release.

Second, it violates the WASM security boundary. The kernel runs natively. Capsules run in a Wasmtime sandbox with a capability-gated, WIT-typed host ABI. Any intelligence that lives in the kernel escapes the sandbox. It cannot be updated without a daemon restart. It cannot be capability-constrained. It cannot be audited through the same mechanism as capsule invocations.

Third, it breaks operational isolation. A bug in a capsule's business logic panics the capsule or returns an error. A bug in kernel business logic can corrupt shared state across all principals, all uplinks, and all capsules in the session.

The practical rule for contributors: if a field on `Kernel` knows anything about what a capsule is supposed to do with data, that field is wrong. The kernel stores `Arc<dyn Capsule>` in the registry. It does not store what those capsules think.

## Enforcement at the Code Level

The crate-level doc comment in `lib.rs` line 7 states this explicitly:

```
//! The Kernel is a pure, decentralized WASM runner. It contains no business
//! logic, no cognitive loops, and no network servers. Its sole responsibility
//! is to instantiate `astrid_events::EventBus`, load `.capsule` files into
//! the Wasmtime sandbox, and route IPC bytes between them.
```

The `#![deny(unsafe_code)]` and `#![deny(missing_docs)]` attributes at lines 1 and 2 enforce memory safety and documentation completeness across the entire crate. The kernel does not use `unsafe` because it does not need to do anything low-level that the capsule sandbox and host ABI do not already encapsulate.

The `INTERNAL_SUBSCRIBER_COUNT` constant at line 1147 enumerates every permanent bus subscriber the kernel itself creates: `KernelRouter`, `AdminRouter`, `ConnectionTracker`, `EventDispatcher`, and the bus activity monitor. Five. Every other subscription belongs to a capsule. The `debug_assert_eq` at line 357 enforces this count at kernel boot. If a future change adds a kernel-internal subscriber without updating the constant, the assertion fires in debug builds before any capsule loads.

## Boot Sequence in Brief

`Kernel::new` (`lib.rs`, line 189) is a sequential setup function. In order: open the SurrealKV store, initialize the MCP process manager, bootstrap the capability store and audit log, bind the Unix socket and generate the session token, build the VFS and overlay registry, load group config, bootstrap the default principal, and then construct the `Kernel` arc.

After construction, five background tasks are spawned (lines 339-346): the kernel router, the idle monitor, the react watchdog, the capsule health monitor, and the bus activity monitor. Then the event dispatcher is spawned (line 355). Finally, `load_all_capsules` is called externally by the daemon. The kernel itself does not decide when to load capsules. The daemon does.

The `shutdown` method (line 763) reverses this in order: publish `KernelShutdown` on the bus, clear session allowances, drain the capsule registry and call `unload()` on each capsule (which terminates MCP child processes), flush the KV store, and remove the socket and token files.

Nothing in boot or shutdown interprets capsule behavior. It is process management plus plumbing.

## Summary

| Component | Location | Role |
|-----------|----------|------|
| `EventBus` | `astrid-events/src/bus.rs` | Broadcast channel plus publish-side per-principal routing table |
| `AstridEvent` | `astrid-events/src/event.rs` | Sealed enum of all typed occurrences; `Ipc` is the capsule communication variant |
| `KernelRequest` / `KernelResponse` | `astrid-core/src/kernel_api.rs` | Typed management API surface; every variant maps to a capability string |
| `Kernel` | `astrid-kernel/src/lib.rs` | Holds bus, registries, stores, VFS, audit, and security infrastructure |
| `KernelRouter` | `astrid-kernel/src/kernel_router/mod.rs` | Consumes `astrid.v1.request.*`, enforces capability ACL, executes mechanical actions |
| `EventDispatcher` | `astrid-capsule/src/dispatcher.rs` | Consumes all events, matches interceptor manifests, invokes capsule WASM |
| Capsules | `~/.astrid/capsules/*/` | Where all business logic, intelligence, and protocol implementation lives |

The kernel is a typed message bus with a capability access control list. Every decision about what to do with a message happens in a capsule.

## See also

- [The Boot Sequence](boot-sequence.md)
- [Topics and Wildcards](../bus/topics-and-wildcards.md)
- [The Syscall Surface](../host-abi/the-syscall-surface.md)
