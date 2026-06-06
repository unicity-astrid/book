# Capsule Lifecycle

A capsule moves through a defined sequence of states from discovery on disk to active execution and eventual shutdown. This page follows that sequence in code, covering manifest discovery, install and upgrade hooks, the load path through `CapsuleLoader`, the `CapsuleState` machine, env elicitation, the `ReadyStatus` protocol for background tasks, and the hot-reload watcher that exists in the codebase but is not yet wired to the kernel.

---

## States

The `CapsuleState` enum (`core/crates/astrid-capsule/src/capsule.rs:159`) tracks every capsule through its lifetime:

```rust
pub enum CapsuleState {
    Unloaded,
    Loading,
    Ready,
    Failed(String),
    Unloading,
}
```

`CompositeCapsule::load` sets `Loading` before touching any engine, transitions to `Ready` once every engine succeeds, and records `Failed(reason)` on the first engine error (`capsule.rs:297-307`). `unload` always sets `Unloading` first and then `Unloaded`, even if an engine's teardown returns an error, so shutdown is unconditional.

---

## Discovery

The kernel scans for capsules through `discover_manifests` (`core/crates/astrid-capsule/src/discovery.rs:72`). The scan order is:

1. Extra paths supplied by the kernel (system directory `~/.astrid/capsules/`, then the invoking principal's `~/.astrid/home/{id}/.local/capsules/`).
2. The workspace-level `.astrid/capsules/` directory relative to the daemon's working directory.

Within each directory the function looks for subdirectories that contain a `Capsule.toml` file. The first occurrence of any `package.name` wins; duplicates at lower-priority paths are logged and skipped (`discovery.rs:85-91`).

The manifest file name is the constant `MANIFEST_FILE_NAME = "Capsule.toml"` (`discovery.rs:15`).

### Manifest validation

`load_manifest` (`discovery.rs:186`) parses TOML, merges per-component capability declarations into the root `capabilities` block, enforces the `astrid-version` constraint against the running daemon version, validates semver in `[package].version`, checks IPC publish and interceptor event patterns for empty segments, validates `[imports]`/`[exports]` namespace and interface name identifiers, rejects uplink capsules that declare `[imports]`, and validates every `[[topic]]` declaration for structural correctness.

---

## The Lifecycle Hooks: Install and Upgrade

Capsules may export `astrid-install` and `astrid-upgrade` WASM functions. The SDK macro `#[astrid::install]` and `#[astrid::upgrade]` generate these exports from annotated methods on the capsule's `impl` block (`sdk-rust/astrid-sdk-macros/src/lib.rs:212-258`).

These hooks run before the capsule enters the normal runtime. The kernel calls `run_lifecycle` (`core/crates/astrid-capsule/src/engine/wasm/mod.rs:2139`) to dispatch them. The function:

1. Pre-scans the WASM binary for the relevant export name (`"astrid-install"` or `"astrid-upgrade"`). If the export is absent the function returns `Ok(())` silently; lifecycle hooks are optional.
2. Builds a short-lived, separate `wasmtime::Store` with its own `HostState`. The store is not the capsule's normal interceptor pool.
3. Sets `HostState.lifecycle_phase = Some(phase)` (`mod.rs:2225`), which gates the `elicit` host function.
4. Applies a 10-minute epoch safety-net deadline (`LIFECYCLE_TIMEOUT_SECS = 600`) and seeds fuel to `u64::MAX`. Lifecycle hooks may block on interactive elicitation and are bounded by the wall-clock epoch, not a CPU rate (`mod.rs:2248-2260`).
5. Calls the export via `func.call_async` and returns any guest error to the caller.

The `run_lifecycle` call site lives outside the capsule's normal `load` path. The daemon invokes it during `astrid capsule install` and `astrid capsule upgrade`, before the capsule is registered and before `CapsuleLoader` creates the long-lived `CompositeCapsule`.

### Env elicitation during install

The `elicit` host function (`core/crates/astrid-capsule/src/engine/wasm/host/elicit.rs:61`) is the mechanism for interactive secret and text collection during a lifecycle hook. Its gate is strict: calling `elicit` outside a lifecycle phase returns `ErrorCode::NotInLifecycle` (`elicit.rs:63-65`).

When called inside a lifecycle phase the function:

1. Maps the typed `ElicitRequest` to the IPC `OnboardingField` schema.
2. Subscribes to a UUID-keyed response topic _before_ publishing the request, preventing a race between publication and subscription setup.
3. Publishes `IpcPayload::ElicitRequest` on `"astrid.v1.elicit"`, which the TUI or CLI renders as a prompt.
4. Blocks until a response arrives on the per-request response topic, or a 120-second timeout (`MAX_ELICIT_TIMEOUT_MS`) elapses, or the capsule's cancellation token fires.
5. For `ElicitType::Secret`, stores the value via the capsule's `SecretStore` and returns `ElicitResponse::SecretStored`. The raw secret value is never returned to the guest.

The four elicit types map to distinct response variants:

| `ElicitType` | Response variant | Persisted by host |
|---|---|---|
| `Text` | `Value(String)` | No. Returned to guest; guest is responsible for persistence. |
| `Secret` | `SecretStored` | Yes, via SecretStore (`~/.astrid/secrets/`). Raw value is not returned to guest. |
| `Select` | `Value(String)` | No. Returned to guest; guest is responsible for persistence. |
| `Array` | `Values(Vec<String>)` | No. Returned to guest; guest is responsible for persistence. |

---

## CapsuleLoader: Translating a Manifest into Engines

`CapsuleLoader::create_capsule` (`core/crates/astrid-capsule/src/loader.rs:57`) is the manifest-first router. It creates a `CompositeCapsule` and adds engines based on what the manifest declares:

1. **WasmEngine** (`engine/wasm/mod.rs`): added when `manifest.components` is non-empty. Each capsule supplies at most one component today.
2. **McpHostEngine** (`engine/mcp.rs`): added for each `[[mcp_server]]` entry with `type = "stdio"`. This is an explicit host-process breakout; it spawns a child process and bridges MCP over stdio. The comment in loader.rs calls it the "airlock override" (`loader.rs:73`).
3. **StaticEngine** (`engine/static_engine.rs`): always added. It handles `context_files`, static commands, and skills declared in the manifest.

The loader also receives the kernel-owned `FuelLedger` and `FuelRateLimiter` handles. It passes the same handles to every `WasmEngine` it creates, so per-principal CPU is aggregated across all capsules into one cross-capsule total (`loader.rs:14-23`).

---

## WasmEngine Load Path

`WasmEngine::load` (`mod.rs:908`) is the most complex lifecycle entry point. In order:

1. **WASM binary read and BLAKE3 integrity check.** The binary is read from the path in `manifest.components[0]`, or resolved from the content-addressed `~/.astrid/lib/{hash}.wasm` path via `meta.json`. The BLAKE3 hash in `meta.json` must match the binary; a mismatch or missing hash causes a hard load failure. Capsules not installed via `astrid capsule install` (which records the hash) cannot load.

2. **Env resolution.** `resolve_env` (`engine/mod.rs:147`) checks each `[env]` key in `manifest.env` against the capsule's `ScopedKvStore`. Keys with stored values are resolved. Keys that are multi-choice enums always go to onboarding. Keys with defaults use the default. Unresolved keys emit `IpcPayload::OnboardingRequired` on the event bus and fall back to empty strings so uplink capsules (which load before any client connects) do not block on boot.

3. **VFS setup.** An overlay VFS is built from a lower `HostVfs` rooted at the workspace and an upper `HostVfs` rooted at a temporary directory. The upper layer is a `TempDir` kept alive in `HostState` for the capsule's lifetime. Writes go to the upper layer; commits and rollbacks (`Vfs::commit`, `Vfs::rollback`) are not yet called from any production path. The capsule's owner-principal home (`~/.astrid/home/{principal}/`) is separately mounted as a direct `HostVfs` with no CoW layer.

4. **Run-loop budget resolution.** `resolve_run_loop_budget` (`mod.rs:534`) is a pure function that determines whether the capsule's `run()` export will be CPU-and-memory-bounded or exempt. Exemption is purely capability-driven: the owner principal must hold `CAP_RESOURCES_UNBOUNDED`, `CAP_NET_BIND`, or `CAP_UPLINK` (admin holds all via `*`). The capsule's own manifest (`is_daemon`, `net_bind`, `uplink` fields) plays no part. Missing input fails closed to bounded.

5. **Pool instantiation.** A wasmtime `Engine` is built with `wasm_component_model(true)`, `epoch_interruption(true)`, `consume_fuel(true)`, and `async_support(true)`. A `Linker<HostState>` is configured via `configure_kernel_linker`, which registers every Astrid host interface and no `wasi:*` interfaces. The WASM binary is compiled to a `Component` and pre-instantiated with `linker.instantiate_pre`. Then `pool_size` stores are built from that single `InstancePre`:

   - `pool_size = 1` for run-loop capsules (they have a dedicated store owned by the run task) and for capsules with `host_process` capability (they hold live resource handles across invocations).
   - `pool_size = INSTANCE_POOL_SIZE` (16) for all other capsules.

6. **Run-loop store setup (if `has_run_export`).** The single pooled instance is popped and configured as the dedicated run-loop store. Its fuel is set to `u64::MAX` (run loops are CPU-bounded by the epoch mechanism, not fuel). For bound run-loops `epoch_deadline_callback` is installed with the `epoch_decision` logic: a store that calls `recv` in each window is re-armed (`Yield`); a store that burns a window without a `recv` call accrues `no_yield_windows` and is interrupt-trapped after `MAX_NO_YIELD_WINDOWS = 3` consecutive no-recv windows.

7. **Readiness channel.** For run-loop capsules a `tokio::sync::watch` channel is created. The sender is placed in `HostState.ready_tx`; the guest calls the `sys::set-ready` host function to send `true` when its initialization is complete. The receiver is stored in `WasmEngine.ready_rx` behind a `Mutex` so `wait_ready` can be called concurrently from different tasks.

8. **Interceptor auto-subscription.** For run-loop capsules the effective interceptor list (`manifest.effective_interceptors()`, the `[subscribe].handler` entries) is recorded in `HostState.interceptor_handles`. The dispatcher routes matching IPC events directly to the run task via the auto-subscribed IPC channel; no external `invoke_interceptor` calls are made for run-loop capsules.

9. **Run task spawn.** `tokio::task::spawn` starts an async task that locks the run-loop store, looks up the `run` typed function, and calls `run().call_async(&mut store, ()).await`. If `run` exits or fails, the task logs an error and terminates. The run handle is stored in `WasmEngine.run_handle`.

10. **State caching.** `profile_cache`, `overlay_registry`, `owner_principal`, and `group_config` are cached from `CapsuleContext` into `WasmEngine` fields. The `invoke_interceptor` hot path reads these cached values without touching `HostState` under a lock.

---

## The StaticEngine Stub

`StaticEngine::load` (`engine/static_engine.rs:32`) is unconditionally `Ok(())`. The `TODO` comment records that it should eventually read `manifest.context_files` and `skills` from the capsule directory and publish them to the OS event bus or LLM router. As of the current codebase, loading a static engine is a no-op beyond noting the manifest and capsule directory.

---

## Registry and UUID Mapping

After all engines have successfully loaded, `CapsuleRegistry::register` (`core/crates/astrid-capsule/src/registry.rs:49`) is called with the `Box<dyn Capsule>`. Registration:

- Rejects duplicate `CapsuleId` values with `CapsuleError::UnsupportedEntryPoint`.
- Registers each `[uplink]` declaration from the manifest as a `UplinkDescriptor`.

A separate UUID mapping is populated during WASM engine load (step 9 above). Each load generates a fresh `uuid::Uuid::new_v4()` that is recorded in `CapsuleRegistry::uuid_map` so that host functions can resolve an IPC `source_id` back to a `CapsuleId` for capability checks. The ordering is deliberate: the UUID is registered before the capsule itself, so during the brief gap `find_by_uuid` returns `Some(id)` while `get(id)` returns `None`. Capability checks in that window fail closed.

`registry.unregister` removes the capsule, its uplinks, and its UUID mapping atomically. `registry.drain` (used during kernel shutdown) clears everything in a single pass.

---

## ReadyStatus: Waiting for Background Task Startup

The `ReadyStatus` enum (`capsule.rs:141`) and the `Capsule::wait_ready` method let the kernel observe when a capsule's background run loop has finished its initialization:

```rust
pub enum ReadyStatus {
    Ready,
    Timeout,
    Crashed,
}
```

`CompositeCapsule::wait_ready` iterates its engines, sharing a single `tokio::time::Instant` deadline across all of them. If the first engine exhausts the budget, remaining engines receive zero time and immediately return `Timeout` (`capsule.rs:320-333`).

`WasmEngine::wait_ready` (`mod.rs:1685`) returns `Ready` immediately for non-run-loop capsules (they have no `ready_rx`). For run-loop capsules it awaits `rx.wait_for(|&v| v)` with the remaining timeout:

- `Ok(Ok(_))` maps to `Ready`.
- `Ok(Err(_))` maps to `Crashed` (the `watch` sender was dropped before the guest called `sys::set-ready`).
- `Err(_)` (timeout) maps to `Timeout`.

The guest signals readiness by calling the `sys::set-ready` host function. Capsules that do not export `run` never signal and do not need to; `wait_ready` returns `Ready` immediately for them.

---

## Watchdog and Health

`Capsule::check_health` is distinct from `Capsule::state`. While `state()` returns the last value written during the load or unload path, `check_health()` probes engine liveness at call time. `CompositeCapsule::check_health` delegates to each engine; the first engine that returns a `Failed` state short-circuits and surfaces that state to the caller (`capsule.rs:365-373`).

`WasmEngine::check_health` detects when the background run-loop task has silently exited by checking whether `run_handle.is_finished()`. If the handle finished the engine reports `Failed("WASM run loop exited unexpectedly")`. The kernel's health-monitor task calls `check_health` periodically and can restart a capsule using `source_dir()`, which returns the original capsule directory stored during `CompositeCapsule::set_source_dir`.

---

## Hot-Reload Watcher (Dead Code, Issue #296)

The `CapsuleWatcher` type in `core/crates/astrid-capsule/src/watcher.rs` is fully implemented but is not wired into the kernel or any production caller. The file carries `#![allow(dead_code)]` and its module-level doc comment notes it is tracked by issue #296.

The watcher is designed to:

1. Recursively watch one or more capsule root directories using the `notify` crate.
2. Filter events to `Create`, `Modify`, and `Remove` kinds, ignoring `node_modules`, `target`, `dist`, and `.git` directories.
3. Debounce events per capsule directory with a 500 ms window (`DEFAULT_DEBOUNCE`).
4. Compute a BLAKE3 hash of all source files (sorted by relative path for determinism, excluding `.wasm` files and `astrid_bridge.mjs` to avoid feedback loops).
5. Emit `WatchEvent::CapsuleChanged { capsule_dir, source_hash }` only when the hash has changed since the last emission.

The watcher identifies a capsule directory by walking up from the changed file path until it finds a directory containing `Capsule.toml`, stopping at any configured watch root.

Until issue #296 lands, this watcher produces no observable behavior. Capsule hot-reload does not occur.

---

## Unload

`WasmEngine::unload` (`mod.rs:1661`):

1. Fires the `CancellationToken` to cooperatively unblock any in-flight `ipc_recv`, `elicit`, or net calls that poll on that token.
2. Calls `run_handle.abort()` to stop the background run task.
3. Drops the `EpochTickerGuard` (RAII, joins the epoch ticker thread).
4. Sets `self.pool = None`, which drops all pooled `Store<HostState>` values and with them all wasmtime linear memory.
5. Sets `self.ready_rx = None` to prevent stale channel reads after unload.

`CompositeCapsule::unload` calls `engine.unload()` for every engine on a best-effort basis: errors are discarded with `let _ = ...` so one failing engine does not prevent others from shutting down (`capsule.rs:310-318`).

---

## Capsule-Owned State Persistence

The runtime does not own or manage capsule state between invocations. The `#[astrid::capsule]` macro (`sdk-rust/astrid-sdk-macros/src/lib.rs`) generates state persistence inline at every dispatch site:

- Stateless capsules (`&self` methods with no `#[capsule(state)]` attribute) use a `std::sync::OnceLock<T>` singleton initialized to `T::default()`. No KV interaction occurs.
- Stateful capsules (`&mut self` or explicit `#[capsule(state)]`) call `kv::get_json("__state")` before each handler invocation, deserializing to `T::default()` on a JSON decode error. After a successful handler call the updated struct is persisted with `kv::set_json("__state", &instance)`. Persistence is skipped on error to avoid writing partial state.
- The `#[astrid::run]` export for stateful capsules loads state from KV once at run-loop startup but never auto-saves it. Run loops are long-lived and manage their own persistence via explicit KV calls.
- The `#[astrid::install]` export for stateful capsules always starts from `T::default()` and persists the result. Upgrade starts from the saved state, falling back to `T::default()` if deserialization fails.

The KV key `"__state"` is the conventional key written and read by the macro. Capsules may use additional KV keys for sub-resources.

## See also

- [The Capsule Manifest and Engines](manifest-and-engines.md)
- [Packages: Approval, Identity, Uplink](../host-abi/packages-approval-identity-uplink.md)
