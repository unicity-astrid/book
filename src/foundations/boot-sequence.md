# The Boot Sequence

This page traces the path from `astrid-daemon` receiving `run()` through the moment the readiness
sentinel file appears on disk. Every ordering constraint is real code. File anchors are given as
`crate/src/file.rs:line`.

## Entry Point

The standalone binary (`core/crates/astrid-daemon/src/main.rs`) is a one-liner that delegates to
`astrid_daemon::run()`. The shared library function lives in
`core/crates/astrid-daemon/src/lib.rs` so both the standalone binary and the bundled CLI binary
execute the same path.

```rust
// astrid-daemon/src/main.rs
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    astrid_daemon::run().await
}
```

`run()` parses CLI arguments, initializes logging, resolves the session UUID, determines the
workspace root (argument or `$PWD`), and then calls `Kernel::new`. Everything interesting happens
inside that call.

## Runtime Requirement

`Kernel::new` opens with an assertion:

```rust
assert!(
    tokio::runtime::Handle::current().runtime_flavor()
        == tokio::runtime::RuntimeFlavor::MultiThread,
    "Kernel requires a multi-threaded tokio runtime ..."
);
```

This is not defensive boilerplate. The capsule engine uses `tokio::task::block_in_place` to call
synchronous WASM host functions from async context. `block_in_place` panics on a single-threaded
runtime because it cannot park the current thread without starving the runtime. The `#[tokio::main]`
macro in `main.rs` provides the required multi-thread scheduler.

## `Kernel::new` -- Numbered Steps

The constructor is a single linear function (`core/crates/astrid-kernel/src/lib.rs:189`). The
numbered comments in the source establish the canonical ordering. Each step is constrained by the
ones before it.

### Step 1: KV Store

```rust
let kv = Arc::new(
    astrid_storage::SurrealKvStore::open(&kv_path)
        .map_err(|e| std::io::Error::other(...))?
);
```

The persistent KV store at `~/.astrid/state.db` must open before anything else. The capability
store, identity store, and all capsule-scoped KV namespaces derive from this handle. A boot failure
here is fatal: the kernel cannot gate capabilities or log audit entries without it.

### Step 2: MCP Process Manager

```rust
let mcp_config = ServersConfig::load_default().unwrap_or_default();
let mcp_manager = ServerManager::new(mcp_config)
    .with_workspace_root(workspace_root.clone())
    .with_capsule_log_dir(principal_home.log_dir());
let mcp_client = McpClient::new(mcp_manager);
```

The MCP manager is configured before it is wrapped in the security layer. `unwrap_or_default()`
means a missing or unreadable MCP config file does not abort boot.

### Step 3: Capability Store and Audit Log

```rust
let capabilities = Arc::new(
    CapabilityStore::with_kv_store(Arc::clone(&kv) as Arc<dyn KvStore>)
        .map_err(|e| ...)?
);
let audit_log = open_audit_log()?;
```

The capability store is backed by the KV store opened in step 1. `open_audit_log` loads or
generates the ed25519 runtime signing key from `~/.astrid/keys/runtime.key` (mode `0o600`) and
opens the SurrealKV-backed audit database. On every boot it calls `verify_all()` across all
historical audit chain sessions. Verification failures are logged at `error!` level but do not
block boot -- fail-open for availability, loud alert for integrity.

Key generation is idempotent: the 32-byte raw secret is written only when the file is absent. On
Unix the file is written with `std::fs::write`, then permissions are narrowed to `0o600` via a
separate `std::fs::set_permissions` call. This is a two-step sequence with a brief TOCTOU window.

### Step 4: Physical Security Boundary

```rust
let root_handle = DirHandle::new();
```

`DirHandle` is a cap-std directory handle. It establishes the physical security boundary for all
VFS access. The handle itself is not yet associated with any path -- that happens in step 5.

### Step 5: VFS and Overlay Registry

```rust
let kernel_host_vfs = HostVfs::new();
kernel_host_vfs
    .register_dir(root_handle.clone(), workspace_root.clone())
    .await?;
let overlay_registry = Arc::new(OverlayVfsRegistry::new(
    workspace_root.clone(),
    root_handle.clone(),
));
```

Two VFS handles are established. The `kernel_host_vfs` is a plain `HostVfs` used for paths that do
not yet know an invoking principal (discovery, capsule load scan). The `OverlayVfsRegistry` is the
per-principal overlay system: on first use for a given `PrincipalId`, it creates an `OverlayVfs`
whose lower layer is the shared workspace and whose upper layer is a principal-private tempdir.
Agent A's uncommitted writes are never visible to Agent B.

The kernel's own `vfs` field points at the `HostVfs`. Capsule contexts receive a reference to
`overlay_registry` and resolve their own overlay at invocation time.

### Step 6: Socket Bind and Session Token

```rust
let (listener, singleton_lock) = socket::bind_session_socket(&home)?;
let (session_token, token_path) = socket::generate_session_token()?;
```

This is the most constrained step in the boot sequence. The singleton lock must be acquired before
the socket is bound, and the session token must be written before any capsule can accept
connections.

`bind_session_socket` (`core/crates/astrid-kernel/src/socket.rs:41`) performs the following in
order:

1. Creates `~/.astrid/run/` with mode `0o700` if absent. The mode is set explicitly because the
   directory might be created here rather than by `AstridHome::ensure()`, and would otherwise
   inherit the process umask (commonly `0o755`, making the socket listable by other users).

2. Acquires an exclusive advisory `flock` on `~/.astrid/run/system.lock`. This is non-blocking
   (`try_lock`): a second daemon fails immediately rather than waiting. The lock is held for the
   process lifetime via the returned `std::fs::File`. When the process exits (cleanly or by crash),
   the OS releases the lock, so a restart is never wedged by a dead predecessor.

3. Calls `prepare_socket_path`, which:
   - Rejects paths exceeding the platform `sun_path` limit (104 bytes on macOS/FreeBSD/OpenBSD,
     108 on Linux).
   - Removes symlinks at the socket path (a tamper indicator).
   - Probes an existing socket file by attempting `UnixStream::connect`. A live connection means
     another kernel is running and boot fails. `ECONNREFUSED` means a stale socket from a crashed
     predecessor; it is removed. Other errors (EACCES, etc.) are treated as a live-kernel indicator
     and also cause boot to fail.

4. Removes any stale readiness file as defense-in-depth.

5. Binds the `UnixListener`.

`generate_session_token` generates a fresh `SessionToken`, writes it to `~/.astrid/run/system.token`
with mode `0o600`, and returns both the token and the path. There is no `/tmp` fallback for the
token: writing a secret under a world-listable directory would undermine the authentication it
provides. The path is stored in `Kernel::token_path` so shutdown uses the same path without
re-resolving `$ASTRID_HOME`.

### Identity and Groups Bootstrap

After the socket step, `Kernel::new` bootstraps the CLI root user identity (idempotent across
reboots) and loads the group configuration:

```rust
let groups_loaded = GroupConfig::load(&home)
    .map_err(|e| std::io::Error::other(...))?;
let groups = Arc::new(ArcSwap::from_pointee(groups_loaded));
```

A missing `etc/groups.toml` means built-in groups only. A malformed TOML file is a hard boot
failure (fail-closed). The `ArcSwap` wrapper allows admin topics to hot-swap the live config
atomically: in-flight checks holding the old `Arc` finish under the old config; the next check sees
the new one.

`bootstrap_cli_root_user` seeds the default principal's `profile.toml` with `groups = ["admin"]`
when the profile is absent or entirely unconfigured. If the operator has already set any `groups`,
`grants`, or `revokes`, the existing profile is left untouched. Legacy profiles under
`home/{principal}/.config/profile.toml` are migrated to `etc/profiles/{principal}.toml` on first
boot post-issue-#672 to prevent capsules with `fs_read = ["home://"]` from reading their own
policy.

### Kernel Construction

The `Arc<Kernel>` is constructed from all the handles assembled above. Notable fields:

| Field | Type | Purpose |
|---|---|---|
| `singleton_lock` | `Option<std::fs::File>` | Holds the flock for process lifetime. Annotated `#[expect(dead_code)]` -- the point is `Drop`. |
| `ephemeral` | `AtomicBool` | Set by the daemon after boot. Controls idle shutdown behavior. |
| `boot_time` | `std::time::Instant` | Captured at construction for uptime reporting. |
| `shutdown_tx` | `watch::Sender<bool>` | The daemon's main loop selects on the receiver to exit without `process::exit`. |
| `fuel_ledger` | `FuelLedger` | Shared per-principal CPU fuel counter, cloned into every `WasmEngine`. |
| `fuel_rate` | `FuelRateLimiter` | Shared per-principal rate limiter; deny side of the CPU budget. |
| `profile_cache` | `Arc<PrincipalProfileCache>` | Boot-loaded, invalidated by kernel restart. Plumbed into every capsule load for per-invocation resource caps. |

## Background Tasks Spawned Inside `Kernel::new`

Immediately after construction, before `Kernel::new` returns, five background tasks are spawned:

```rust
drop(kernel_router::spawn_kernel_router(Arc::clone(&kernel)));
drop(spawn_idle_monitor(Arc::clone(&kernel)));
drop(spawn_react_watchdog(Arc::clone(&kernel.event_bus)));
drop(spawn_capsule_health_monitor(Arc::clone(&kernel)));
drop(bus_monitor::spawn_bus_activity_monitor(&kernel.event_bus));
```

The `drop` calls are intentional: the `JoinHandle` is discarded because these tasks run for the
process lifetime and are not joined on shutdown. The `EventDispatcher` is then spawned separately
with a `tokio::spawn`.

A `debug_assert` immediately after verifies the expected internal subscriber count:

```rust
debug_assert_eq!(
    kernel.event_bus.subscriber_count(),
    INTERNAL_SUBSCRIBER_COUNT,  // = 5
    "INTERNAL_SUBSCRIBER_COUNT is stale; ..."
);
```

The five permanent internal subscribers are: `KernelRouter` (`kernel.request.*`), `AdminRouter`
(`kernel.admin.*`), `ConnectionTracker` (`client.*`), `EventDispatcher` (all events), and the bus
activity monitor (all events). Any addition of a permanent subscriber requires updating this
constant.

### Idle Monitor

`spawn_idle_monitor` implements dual-mode idle shutdown.

In ephemeral mode (`--ephemeral` flag), the daemon shuts down after the last client disconnects.
The idle timeout defaults to 30 seconds (overridable via `ASTRID_IDLE_TIMEOUT_SECS`). The 30-second
grace prevents premature shutdown during brief reconnects (tool execution, TUI restarts).

In persistent mode (`astrid start`), idle shutdown is opt-in. Without `ASTRID_IDLE_TIMEOUT_SECS`,
the monitor task exits immediately and the daemon stays up until SIGTERM.

Both modes wait through an initial 5-second grace period before checking. Non-ephemeral mode adds
a further 25-second grace so capsules can fully initialize before the idle check begins.

Idle shutdown triggers only when both `total_connection_count() == 0` AND no registered capsule
has a non-empty `uplinks` field (`!has_daemons`). The connection count alone is insufficient: a
daemon with capsules that declare uplinks will not idle-shutdown regardless of connection count.
The previous heuristic of subtracting known internal `EventBus` subscribers was replaced because
capsule run-loop crashes reduce `subscriber_count()`, producing false "zero connections" readings
that triggered premature shutdown while a client was active.

### Capsule Health Monitor

`spawn_capsule_health_monitor` runs every 10 seconds. It reads the capsule registry under a brief
read lock, collects capsules in `Ready` state, drops the lock, calls `check_health()` on each, and
publishes `astrid.v1.health.failed` IPC events for failures.

Failed capsules enter a `RestartTracker`:

| Constant | Value |
|---|---|
| `MAX_ATTEMPTS` | 5 |
| `INITIAL_BACKOFF` | 2 seconds |
| `MAX_BACKOFF` | 2 minutes |

Backoff doubles on each failed attempt (saturating at `MAX_BACKOFF`). After five attempts the
tracker is marked exhausted and the capsule remains down. Successful restart clears the tracker.

The restart path calls `Arc::get_mut` to obtain exclusive access before calling the async `unload`
method. The health monitor explicitly drops all `Arc<dyn Capsule>` clones before attempting restart,
because in-flight dispatcher tasks hold temporary clones and `Arc::get_mut` requires strong count 1.

### React Watchdog

`spawn_react_watchdog` publishes `astrid.v1.watchdog.tick` every 5 seconds. WASM guests cannot use
async timers, so this kernel-side loop drives timeout enforcement in the `ReAct` capsule by waking
its `handle_watchdog_tick` interceptor.

## `load_all_capsules` -- Topological Discovery and Load

After `Kernel::new` returns to `run()`, the daemon calls `kernel.load_all_capsules()`. This is the
lengthiest phase of boot.

### Discovery

```rust
let discovered = astrid_capsule::discovery::discover_manifests(Some(&paths));
```

`discover_manifests` (`core/crates/astrid-capsule/src/discovery.rs:72`) scans in priority order:

1. Principal capsule directory: `~/.astrid/home/{principal}/.local/capsules/`
2. Workspace capsule directory: `.astrid/capsules/` (relative to CWD)

When the same `package.name` appears in multiple sources, the first occurrence wins. Lower-priority
duplicates are logged as warnings and skipped.

`load_manifest` validates each `Capsule.toml` before it enters the sort:

- Semver validity of `[package].version`.
- `astrid-version` constraint against the running kernel's `CARGO_PKG_VERSION`.
- `ipc_publish` patterns and `[subscribe]` handler event patterns must have no empty segments.
- `[imports]` and `[exports]` namespace and interface names must match `^[a-z][a-z0-9-]*$`.
- Uplink capsules (`capabilities.uplink = true`) must not declare `[imports]`. Uplinks load before
  non-uplinks and cannot depend on them; declaring imports would violate that ordering. This is
  enforced at parse time so it can never be bypassed by a manifest that reaches `load_capsule` via
  a non-discovery path.
- `[[topic]]` declarations are validated for name format, schema path safety (no absolute paths, no
  `..` components), and uniqueness of `(name, direction)` pairs.

### Topological Sort

```rust
let sorted = match toposort_manifests(discovered) {
    Ok(sorted) => sorted,
    Err((e, original)) => { /* log cycle, fall back to discovery order */ },
};
```

`toposort_manifests` (`core/crates/astrid-capsule/src/toposort.rs:67`) implements Kahn's algorithm:

1. For each capsule, collect all `(namespace, name, version)` triples from its `[exports]`.
2. For each capsule's `[imports]`, find every provider whose exports satisfy the import via
   semver-range matching. Every satisfying provider gets an ordering edge (not just the first).
   Unsatisfied imports are logged as warnings and treated as satisfied for ordering purposes -- the
   capsule still loads.
3. BFS from zero-in-degree nodes produces the topological order.
4. If the emitted count is less than the input count, a cycle exists. The cycle members (nodes with
   remaining in-degree > 0) are named in the error and the original unsorted slice is returned as a
   fallback.

The "any-satisfies" semantics mean that if two capsules both export `astrid/session ^1.0`, a
consumer of that interface gets ordering edges to both, ensuring both load first. The
`validate_imports_exports` call after sorting warns about such duplicates (double-processing risk)
but does not abort.

### Uplink Partition

```rust
let (uplinks, others): (Vec<_>, Vec<_>) =
    sorted.into_iter().partition(|(m, _)| m.capabilities.uplink);
```

After the topological sort, the result is partitioned into uplink capsules and non-uplink capsules.
Relative order within each partition is preserved from the toposort. Uplinks load first.

### Load and Readiness Wait

```rust
for (manifest, dir) in &uplinks {
    if let Err(e) = self.load_capsule(dir.clone()).await { /* warn */ }
}
self.await_capsule_readiness(&uplink_names).await;

for (manifest, dir) in &others {
    if let Err(e) = self.load_capsule(dir.clone()).await { /* warn */ }
}
self.await_capsule_readiness(&other_names).await;
```

`await_capsule_readiness` collects `Arc<dyn Capsule>` handles under a short-lived read lock, drops
the lock, and awaits all capsules concurrently via `tokio::task::JoinSet`. Each capsule is given
500 milliseconds. Capsules without a run loop return `Ready` immediately. A timeout produces a
warning but does not abort boot. A `Crashed` status (run loop exited before signaling ready)
produces an error log.

The separation is critical: non-uplink capsules must not load until uplink capsules have their event
bus subscriptions active. If a non-uplink published an event before the uplink that handles it had
subscribed, the event would be dropped.

### Capsule Load Detail

`load_capsule` (`lib.rs:371`) skips capsules already in the registry (prevents double-load from
overlapping discovery paths), uses `CapsuleLoader` to create the capsule instance, resolves the
`.env.json` config, builds a `CapsuleContext` with references to all shared kernel handles, calls
`capsule.load(&ctx)`, and then writes the capsule into the `CapsuleRegistry` under a write lock.

The `CapsuleContext` receives:

- The shared `event_bus` for IPC.
- The `cli_socket_listener` (the `UnixListener` bound in step 6 of `Kernel::new`). Uplink capsules
  use this to accept client connections.
- A `ScopedKvStore` namespace keyed by `{principal}:capsule:{capsule_id}`.
- The `session_token` generated at boot.
- The `profile_cache`, `overlay_registry`, and a snapshot of the live group config for the
  resource-exemption capability check.

### Capsules Loaded Event

After all capsules have loaded and signaled readiness:

```rust
let msg = IpcMessage::new(
    "astrid.v1.capsules_loaded",
    IpcPayload::RawJson(serde_json::json!({"status": "ready"})),
    self.session_id.0,
);
let _ = self.event_bus.publish(AstridEvent::Ipc { ... });
```

This event allows uplink capsules (such as the registry) to proceed with post-boot discovery work
instead of polling with arbitrary timeouts.

## Readiness Sentinel

Back in `run()`, after `load_all_capsules()` returns:

```rust
let has_cli_proxy = reg.list().iter().any(|id| id.as_str() == "astrid-capsule-cli");
if !has_cli_proxy {
    anyhow::bail!("CLI proxy capsule (astrid-capsule-cli) not found ...");
}

astrid_kernel::socket::write_readiness_file()?;
```

The check for `astrid-capsule-cli` is a hard gate: without it, the kernel has no accept loop and
CLI connections will always time out. If the capsule is missing, `run()` returns an error and the
process exits before writing the readiness file.

`write_readiness_file` creates `~/.astrid/run/system.ready` with mode `0o600` using
`OpenOptions::mode()` to set permissions atomically (no TOCTOU window). The CLI polls for this file
rather than the socket file to avoid connecting before the accept loop is running. Writing the file
after `load_all_capsules()` (which includes `await_capsule_readiness` for both partitions) ensures
the CLI never observes a half-initialized daemon.

On shutdown, `Kernel::shutdown` calls `remove_readiness_file()`. `bind_session_socket` also removes
any stale readiness file at startup, covering the case of a daemon crash that bypassed graceful
shutdown.

## Ephemeral Mode

```rust
if args.ephemeral {
    kernel.set_ephemeral(true);
}
```

The ephemeral flag is set on `Kernel` after `Kernel::new` returns but before `load_all_capsules`.
The idle monitor reads the flag after its initial 5-second grace period, so setting it post-`new`
is safe. Ephemeral mode is used by the CLI to launch a per-session daemon that exits automatically
when the user disconnects.

## Optional HTTP Gateway

`run()` optionally spawns the HTTP gateway after capsules are loaded:

```rust
match load_gateway_config().await {
    Ok(Some(cfg)) if cfg.enabled => Some(spawn_gateway(cfg, &kernel)?),
    ...
}
```

`load_gateway_config` reads `~/.astrid/etc/gateway-http.toml`. A missing file or `enabled = false`
is a no-op. The gateway receives three kernel handles: the event bus (for SSE and bus-direct admin
calls), the audit log (for the `GET /api/sys/audit` route), and the session ID.

## Signal Handling and Graceful Shutdown

The daemon's main loop selects on three signals simultaneously:

```rust
tokio::select! {
    _ = tokio::signal::ctrl_c() => { /* SIGINT */ }
    _ = sigterm.recv() => { /* SIGTERM */ }
    _ = shutdown_rx.wait_for(|v| *v) => { /* API-initiated shutdown */ }
}
```

The third branch is driven by `Kernel::shutdown_tx`, a `tokio::sync::watch` channel. Admin handlers
that implement a shutdown RPC send `true` on this sender. The main loop receives it here, treating
it identically to a signal.

`Kernel::shutdown` (`lib.rs:763`) executes four steps:

1. Publishes `AstridEvent::KernelShutdown` on the event bus so capsules can react before teardown.
2. Drains the capsule registry and calls `unload()` on each capsule. MCP engine unload is critical:
   it terminates child processes. Without explicit unload, MCP child processes become orphaned.
   `Arc::get_mut` is retried up to 20 times with 50ms yields to let in-flight dispatcher tasks
   release their `Arc` clones. After 20 retries, the capsule is dropped without unload with a
   warning that MCP children may be orphaned.
3. Flushes and closes the KV store.
4. Removes the Unix socket file, the session token file, and the readiness sentinel.

## Ordering Summary

The table below captures the hard ordering constraints grounded in the code:

| Step | What happens | Why it must be here |
|---|---|---|
| KV open | `SurrealKvStore::open` | Capability store, identity store, and all capsule KV namespaces depend on it |
| Audit log open | `AuditLog::open` + `verify_all` | Must run before any capability decisions are audited |
| Capability store init | `CapabilityStore::with_kv_store` | Gates every subsequent capability check |
| Singleton lock | `acquire_singleton_lock` (inside `bind_session_socket`) | Must precede socket bind to eliminate TOCTOU between probe and bind |
| Socket bind | `UnixListener::bind` | Must precede session token write (no client can connect without a socket) |
| Session token write | `generate_session_token` | Must be present before any capsule can accept a handshake |
| Background tasks spawn | Inside `Kernel::new`, after construction | After `Arc<Kernel>` exists; before capsule load so monitors are active |
| Uplink load | First partition of `load_all_capsules` | Must subscribe before non-uplinks publish |
| Uplink readiness wait | `await_capsule_readiness(uplink_names)` | Non-uplinks must not publish until uplink accept loops are live |
| Non-uplink load | Second partition | Safe to publish; uplinks are ready |
| Non-uplink readiness wait | `await_capsule_readiness(other_names)` | `astrid.v1.capsules_loaded` must follow complete readiness |
| `astrid.v1.capsules_loaded` publish | End of `load_all_capsules` | Signals post-boot discovery to registered listeners |
| CLI proxy check | `run()`, post-`load_all_capsules` | No accept loop means no CLI; fail before advertising readiness |
| Readiness sentinel write | `write_readiness_file()` | Last step before blocking on signals; CLI polls this file |

## See also

- [The Kernel Is Dumb](kernel-is-dumb.md)
- [Capsule Lifecycle](../capsule-model/lifecycle.md)
- [Distros and the Content-Addressed Store](../distribution/distros-and-store.md)
