# PrincipalId and Per-Invocation Isolation

Every resource in Astrid, from a KV namespace to a home directory to a secret store, is owned by a **principal**. A principal is not a role or a group. It is a validated identity string that the kernel uses as a prefix key when partitioning storage and filesystem access across users, agents, and the runtime itself. This page covers the `PrincipalId` type, the default sentinel, and the transparent per-invocation re-scoping that lets a single shared capsule serve multiple principals without any capsule-side awareness.

## The `PrincipalId` Type

`PrincipalId` lives in `core/crates/astrid-core/src/principal.rs`. It is a newtype over `String` with an enforced alphabet:

```rust
pub struct PrincipalId(String);
```

Validation runs at construction time via `PrincipalId::new`, `FromStr`, and the `TryFrom<String>` impl (the last two are wired for serde). The three error variants map to the three rejection conditions:

```rust
pub enum PrincipalIdError {
    Empty,
    TooLong,              // > 64 characters
    InvalidChar(char),    // outside [a-zA-Z0-9_-]
}
```

The alphabet is intentionally narrow. It excludes `/`, `.`, `@`, spaces, and any unicode. Two consequences follow:

1. A `PrincipalId` used as a filesystem path component can never escape its directory. `../escape` is rejected at `'.'`.
2. A `PrincipalId` used as a KV namespace prefix can never collide with separator characters the storage layer reserves.

The tests at `principal.rs:111-192` exercise all rejection paths, including `"../escape"` and `"foo/bar"`, and verify that serde rejects invalid strings through `TryFrom`.

### The Default Sentinel

`PrincipalId::default()` returns `"default"`. This is the single-user sentinel. An `AstridUserId` created with `AstridUserId::new()` starts with the default principal. Most distro capsules run under `default`. The string `"default"` is a valid `PrincipalId` by the alphabet rules, not a special-cased magic value, so it occupies the same storage paths and KV namespaces as any other principal.

When `AstridUserId::with_display_name` is called and the principal is still `"default"`, it derives a slug from the display name: lowercase, invalid characters replaced with hyphens, consecutive hyphens collapsed, trailing hyphens trimmed, truncated to 64 characters. If derivation produces an empty string, the fallback is `"user-{first-8-chars-of-uuid}"`. An explicit `with_principal` call before `with_display_name` preserves the explicit value (`identity/types.rs:74-81`).

## Directory Layout

Each principal maps to a home directory under the Astrid home root:

```text
~/.astrid/home/{principal}/
    .local/
        capsules/    user-installed capsules
        kv/          capsule KV data
        log/         capsule logs  (daily rotation: YYYY-MM-DD.log)
        audit/       audit chain
        tokens/      capability tokens
        tmp/         VFS-mounted as /tmp
    .config/
        env/         per-capsule config overrides ({capsule_id}.env.json)
```

`AstridHome::principal_home` constructs this path by joining `home_dir()` with `id.as_str()` (`dirs.rs:363-367`). Because `as_str()` is just the validated inner string, path traversal is impossible by construction.

Principal profiles live at `etc/profiles/{principal}.toml`, deliberately outside the principal's own home tree. A capsule with `fs_read = ["home://"]` in its manifest cannot read its own policy, and `fs_write` cannot let it self-elevate (`dirs.rs:236-253`).

Home directories are created with mode `0o700` on Unix. The two top-level dot-dirs (`.local/`, `.config/`) are also `0700`. All directories are created by `PrincipalHome::ensure`, which is called by provisioning code, not by capsule load. The load path only mounts a directory that already exists.

## KV Namespacing

The KV namespace for a capsule-plus-principal pair is:

```
{principal}:capsule:{capsule_id}
```

This format is produced by `HostState::principal_kv_namespace` (`host_state.rs:474-476`) and is also constructed inline wherever `invocation_kv` is populated. The separator character `:` is deliberately outside the `PrincipalId` alphabet, so a crafted principal string can never produce a namespace that collides with a different principal's data.

At capsule load time, `HostState.kv` holds the capsule owner's `ScopedKvStore` (scoped to the load-time principal). At invocation time, when the IPC message carries a different principal, `invocation_kv` is set to a new `ScopedKvStore` built via `kv.with_namespace(&ns)` where `ns` uses the invoking principal.

Every KV host function reads through `HostState::effective_kv`:

```rust
pub fn effective_kv(&self) -> &ScopedKvStore {
    self.invocation_kv.as_ref().unwrap_or(&self.kv)
}
```

The capsule code calls `kv_get`, `kv_set`, and so on without knowing which principal it is serving. The kernel switches the effective namespace transparently.

## Per-Invocation Transparent Re-Scoping

When the dispatcher dispatches an IPC message to a capsule, it calls `WasmEngine::invoke_interceptor`. The invocation principal is derived from the IPC message's `principal` field:

```rust
// astrid-types/src/ipc.rs:41
pub principal: Option<String>,
```

This field is `Option<String>` because `astrid-types` must not depend on `astrid-core`. Validation to `PrincipalId` happens at the kernel boundary, inside `invoke_interceptor`.

The invoking principal is resolved as:

```rust
let invoking_principal = caller
    .and_then(|msg| msg.principal.as_deref())
    .and_then(|p| astrid_core::PrincipalId::new(p).ok())
    .or_else(|| self.owner_principal.clone())
    .unwrap_or_default();
```

If the message carries no `principal`, or if the string fails validation, the capsule owner's principal is used. This means unauthenticated or system events run on the owner's budget and namespace, which for distro capsules is `default`.

When the invoking principal differs from the capsule's load-time `state.principal`, the SET phase of `invoke_interceptor` populates four fields on `HostState`:

**`invocation_kv`** (`HostState.invocation_kv: Option<ScopedKvStore>`)

Built from `kv.with_namespace("{invoking_principal}:capsule:{capsule_id}")`. All KV reads and writes during this invocation see the invoking principal's data. If namespace construction fails (should not happen with a validated `PrincipalId`), a warning is logged and `invocation_kv` stays `None`, causing `effective_kv` to fall back to the owner's store.

**`invocation_home`** and **`invocation_tmp`** (`HostState.invocation_home: Option<PrincipalMount>`, `HostState.invocation_tmp: Option<PrincipalMount>`)

Built by `build_principal_vfs_bundle(invoking_principal)`, which only mounts a `HostVfs` if `~/.astrid/home/{principal}/` exists on disk. There is a registration gate: an invocation for an unknown principal returns an empty `PrincipalVfsBundle`, and the host fs layer returns an error to the guest rather than auto-creating the attacker's home tree. The `tmp` mount is only created when `home` is mounted, because both live under the same principal root.

The `PrincipalMount` struct groups three things that must be installed and cleared as a unit:

```rust
pub struct PrincipalMount {
    pub root: PathBuf,           // canonical physical root
    pub vfs: Arc<dyn Vfs>,       // HostVfs wrapping root
    pub handle: DirHandle,       // capability handle confined to root
}
```

The capability handle ensures that host fs functions cannot escape the principal's directory even through symlinks, because path resolution goes through the `DirHandle` boundary.

Host fs functions read through `HostState::effective_home` and `HostState::effective_tmp`:

```rust
pub fn effective_home(&self) -> Option<&PrincipalMount> {
    self.invocation_home.as_ref().or(self.home.as_ref())
}
```

**`invocation_secret_store`** (`HostState.invocation_secret_store: Option<Arc<dyn SecretStore>>`)

Built from the invocation KV scope. The capsule name plus the invoking principal are used as the keychain service name so secrets stay isolated per principal even when the same capsule serves multiple ones. `effective_secret_store` follows the same fallback pattern as the other accessors.

**`invocation_capsule_log`** and **`invocation_env_overlay`**

Log files are also per-principal. The log is opened at `~/.astrid/home/{principal}/.local/log/{capsule}/{YYYY-MM-DD}.log`. Like the VFS bundle, this only succeeds if the principal's home directory exists. The env overlay is read from `~/.astrid/home/{principal}/.config/env/{capsule_id}.env.json`, a flat `HashMap<String, String>`. The `get_config` host function checks this overlay before falling back to the manifest defaults loaded at capsule boot. Without the overlay, a per-principal `base_url` written through the gateway env endpoint would be silently ignored by any capsule other than `default`.

## Debug Assertion

In debug builds, `HostState::debug_assert_invocation_field_set` enforces the invariant that `invocation_kv` and `invocation_secret_store` are populated whenever `caller_context` carries a principal that differs from the capsule owner. A violation would mean `effective_kv` silently returns the owner's store for the invoking principal's reads and writes. The assertion is omitted for `invocation_home`, `invocation_tmp`, and `invocation_capsule_log` because those legitimately stay `None` when the principal has no registered home directory.

## The Run-Loop Path

Capsules with a `run()` export receive events via an auto-subscribed IPC channel inside the run loop. They do not go through `invoke_interceptor`. For these capsules, `HostState::install_recv_invocation_context` performs the same re-scoping on each received message. It sets `caller_context`, rebuilds `invocation_kv`, and opens the per-principal log file. It skips `invocation_home`, `invocation_tmp`, and `invocation_secret_store` because run-loop capsules (prompt-builder, registry, context-engine) do not currently access home paths or secrets from within their receive loops. When one does, those fields must be added to the recv path.

There is a fast path: if the new message's principal matches the already-installed `caller_context.principal`, the expensive re-open of the KV scope and log file is skipped. Only `caller_context` itself is refreshed. This matters because the recv loop calls `install_recv_invocation_context` on every tick.

There is also a guard against interceptor nesting: if `interceptor_active` is set, `install_recv_invocation_context` returns immediately. An active interceptor owns its `caller_context` for the duration of the dispatch, and a nested `ipc::recv` inside the handler must not overwrite it.

## How Principal Flows Through IPC Chains

The capsule does not manage principal propagation. When a capsule calls `ipc_publish`, the `publish_inner` function stamps the outgoing message with `effective_principal()`:

```rust
pub fn effective_principal(&self) -> astrid_core::principal::PrincipalId {
    self.caller_context
        .as_ref()
        .and_then(|m| m.principal.as_deref())
        .and_then(|p| astrid_core::principal::PrincipalId::new(p).ok())
        .unwrap_or_else(|| self.principal.clone())
}
```

This means a capsule that receives a message from principal `alice`, processes it, and publishes a downstream message automatically stamps that downstream message with `alice`. The next capsule in the chain receives the message, finds `principal = Some("alice")`, and its own invocation re-scoping fires. The principal travels down the entire interceptor chain through the IPC message field, not through any shared state or explicit capsule-to-capsule parameter passing. The capsule is a dumb handler. The kernel's principal propagation is the mechanism.

## Concurrency and Pooled Stores

Capsules that handle interceptors run from a pool of `(Store, Instance)` pairs (16 by default, 1 for capsules with the `host_process` capability). Each leased Store is exclusive for the duration of an invocation. The `PoolCheckout::drop` implementation clears every `invocation_*` field and resets `caller_context` to `None` before returning the Store to the pool. This runs on every exit path: normal return, early `?`, panic unwind, and future cancellation. The next lease of the same Store sees no trace of the previous invocation's principal.

The IPC rate limiter is shared across all pooled instances of a capsule (`Arc<IpcRateLimiter>`), so the per-capsule throughput budget is not multiplied by pool size. The same sharing model applies to the fuel ledger and fuel rate limiter used for per-principal CPU accounting.

## Security Properties

The isolation model has three hard properties:

1. **No cross-principal KV leakage.** The namespace format puts the principal first. A principal cannot observe another principal's keys by guessing key names because the `ScopedKvStore` prepends the namespace to every key before it reaches the storage layer.

2. **No home directory escape.** `PrincipalId` excludes `.` and `/`, so `principal_home(&id)` can never produce a path that escapes the `home/` directory. The `DirHandle` capability further enforces this at VFS resolution time.

3. **No auto-provisioning of unknown principals.** Both `build_principal_vfs_bundle` and `open_capsule_log` check `ph.root().exists()` before proceeding. An IPC message with an unregistered principal string gets a kernel-side invocation with no home mount and no log file, not a silently created home tree.

Profile data (quotas, groups, grants, revokes, enabled flag) lives at `etc/profiles/{principal}.toml`, outside the `home://` VFS scheme. A capsule cannot read or modify its own profile through the fs host functions.

## See also

- [Profiles, Groups, and Quotas](profiles-groups-quotas.md)
- [KV Storage](../storage/kv.md)
- [The VFS Copy-on-Write Overlay](../storage/vfs-overlay.md)
