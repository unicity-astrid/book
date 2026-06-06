# KV Storage

Astrid provides per-(principal, capsule) key-value storage through the `astrid:kv@1.0.0` WIT
package. Every capsule gets an isolated slice of a shared embedded store. Values are arbitrary
bytes up to 1 MiB. The store is ACID-compliant and supports atomic compare-and-swap.

The two layers involved are:

- `core/crates/astrid-storage`: the kernel-side storage library with the `KvStore` trait,
  `ScopedKvStore` (the pre-bound namespace view the kernel hands to a capsule), and the two
  concrete backends.
- `sdk-rust/astrid-sdk/src/kv.rs`: the capsule-side API. Capsule code calls these functions;
  it never touches a `KvStore` directly.

## Namespaces

The composite key stored on disk is `"{namespace}\0{key}"`. The null byte acts as a separator
(`\x00` is forbidden in both namespace and key strings, which is enforced by validation in
`core/crates/astrid-storage/src/kv/mod.rs:44-83`).

The kernel builds a capsule's namespace at load time:

```rust
// core/crates/astrid-kernel/src/lib.rs:396-399
let kv = astrid_storage::ScopedKvStore::new(
    Arc::clone(&self.kv) as Arc<dyn astrid_storage::KvStore>,
    format!("{principal}:capsule:{}", capsule.id()),
)?;
```

The format is `{principal}:capsule:{capsule_id}`. For the default single-user deployment,
`principal` is the string `"default"`, producing namespaces like
`default:capsule:astrid-capsule-session`. Multi-principal deployments have one namespace slice
per user per capsule; a message arriving from principal `alice` causes the dispatcher to
derive `alice:capsule:{capsule_id}` as the invocation namespace.

This is exposed as a helper on `HostState`:

```rust
// core/crates/astrid-capsule/src/engine/wasm/host_state.rs:473-476
pub fn principal_kv_namespace(&self) -> String {
    format!("{}:capsule:{}", self.principal, self.capsule_id)
}
```

Capsule code never sees namespace strings. The `ScopedKvStore` is pre-bound, and the host
function implementations resolve the effective namespace transparently.

### Per-invocation scoping

When an IPC message arrives from a principal that differs from the capsule's load-time
principal, the dispatcher (or `ipc::recv`) creates a second `ScopedKvStore` scoped to the
invoking principal and stores it in `HostState::invocation_kv`. All KV host functions read
through `effective_kv()`, which prefers `invocation_kv` when set:

```rust
// core/crates/astrid-capsule/src/engine/wasm/host_state.rs:483-487
pub fn effective_kv(&self) -> &ScopedKvStore {
    self.invocation_kv.as_ref().unwrap_or(&self.kv)
}
```

A debug assertion fires in debug builds if the invoking principal differs from the owner
principal but `invocation_kv` is `None` (guarding against accidental cross-principal leaks).
The `recv` path constructs the invocation namespace with the same format:

```rust
// core/crates/astrid-capsule/src/engine/wasm/host_state.rs:698
let ns = format!("{}:capsule:{}", p, self.capsule_id);
```

## The KvStore Trait

```rust
// core/crates/astrid-storage/src/kv/mod.rs:170-250
#[async_trait]
pub trait KvStore: Send + Sync {
    async fn get(&self, namespace: &str, key: &str) -> StorageResult<Option<Vec<u8>>>;
    async fn set(&self, namespace: &str, key: &str, value: Vec<u8>) -> StorageResult<()>;
    async fn delete(&self, namespace: &str, key: &str) -> StorageResult<bool>;
    async fn exists(&self, namespace: &str, key: &str) -> StorageResult<bool>;
    async fn list_keys(&self, namespace: &str) -> StorageResult<Vec<String>>;
    async fn list_keys_with_prefix(&self, namespace: &str, prefix: &str) -> StorageResult<Vec<String>>;
    async fn compare_and_swap(
        &self, namespace: &str, key: &str,
        expected: Option<&[u8]>, new: Vec<u8>,
    ) -> StorageResult<bool>;
    async fn clear_namespace(&self, namespace: &str) -> StorageResult<u64>;
    async fn clear_prefix(&self, namespace: &str, prefix: &str) -> StorageResult<u64>;
}
```

`compare_and_swap` returns `Ok(true)` on success, `Ok(false)` when the expected value did
not match (or a concurrent commit invalidated the comparison), and `Err(...)` only for I/O
failures. The kernel does not retry on the capsule's behalf; capsule code issues its own
retry loop.

`ScopedKvStore` pre-binds a namespace and removes the `namespace` argument from every method.
It also provides typed JSON helpers (`get_json`, `set_json`) and forwards `compare_and_swap`
to the underlying store unchanged.

## Storage Tiers

`astrid-storage` exposes two independent storage engines, each behind a Cargo feature flag.

### Tier 1: SurrealKV (`feature = "kv"`)

`SurrealKvStore` wraps `surrealkv::Tree`, an embedded, versioned, ACID-compliant LSM-tree.
This is the backend the kernel uses for capsule KV.

```rust
// core/crates/astrid-storage/src/kv/surreal.rs:54-72
pub fn open(path: impl AsRef<std::path::Path>) -> StorageResult<Self> {
    let tree = surrealkv::TreeBuilder::new()
        .with_path(path.as_ref().to_path_buf())
        .build()
        .map_err(|e| StorageError::Connection(e.to_string()))?;
    Ok(Self { tree, cas_lock: tokio::sync::Mutex::new(()) })
}
```

All operations use SurrealKV transactions internally. Read-only operations open a
`Mode::ReadOnly` transaction; writes commit through a read-write transaction.

`compare_and_swap` holds an additional `cas_lock: tokio::sync::Mutex<()>` across the
read-then-conditional-write-then-commit sequence. The reason is documented in the source:
SurrealKV's `Transaction::validate_write_conflicts` reads the memtable before the core's
write mutex is held, so two concurrent CAS calls on the same key can both pass validation
before either commits. The per-store mutex closes that TOCTOU window. CAS is a rare
operation and the lock is acceptable; transaction conflicts from background flush activity
that slip through are translated to `Ok(false)` rather than an error.

`list_keys` and `list_keys_with_prefix` use SurrealKV's range iterator with the composite
key bounds:

- Namespace range start: `b"{namespace}\0"`
- Namespace range end: `b"{namespace}\x01"` (the byte after `\x00` captures exactly the
  namespace's keys)
- Prefix range end: increments the last byte of the composite prefix, with overflow
  fallback to the namespace range end.

`clear_namespace` and `clear_prefix` collect keys via a range iterator and then delete
them all in one transaction. The iterator is dropped before the deletions begin (it holds
an immutable borrow on the transaction).

### Tier 2: SurrealDB (`feature = "db"`)

`Database` wraps a `surrealdb::Surreal` client and provides full SurrealQL access. This
backend is used for system stores (approval, audit, capabilities, identity) that need
document-graph semantics, relations, and complex queries. Capsule KV does not go through
this tier.

| Deployment | KV backend | DB backend |
|---|---|---|
| Dev / single-agent | SurrealKV (embedded) | SurrealDB (embedded, SurrealKV engine) |
| Production / multi-node | SurrealKV (embedded) | SurrealDB (over TiKV, Raft) |

The same `Database` API works in both modes; connection strings select the engine:

```rust
// core/crates/astrid-storage/src/db.rs:47-56
pub async fn connect_embedded(path: &str) -> StorageResult<Self> {
    let endpoint = format!("surrealkv://{path}");
    // ...
    db.use_ns("astrid").use_db("main").await?;
}
```

### In-Memory Store

`MemoryKvStore` is a `HashMap<String, Vec<u8>>` behind an `RwLock`. It is always available
(no feature flag required), suitable for tests and ephemeral data. `compare_and_swap` is
trivially atomic because the write lock covers the read and the conditional write as a unit.

## Key and Value Constraints

From the WIT contract (`wit/host/kv@1.0.0.wit`):

- Keys must be valid UTF-8, NFC-normalized, with no NUL bytes or control characters. Maximum
  length is 256 bytes.
- Values are arbitrary bytes. Maximum size is 1 MiB per value.
- `kv-list-keys` is capped at 1024 keys per call; result sets beyond that return
  `too-large`, directing the caller to `kv-list-keys-page`.
- Cumulative quota per (principal, capsule) namespace is enforced server-side; exhaustion
  returns the `quota` error code.

The storage layer enforces the no-NUL constraint on both namespace and key at every call site.
Key and namespace validation lives in `core/crates/astrid-storage/src/kv/mod.rs:40-83`.

## WIT Contract

The host function surface is defined in `wit/host/kv@1.0.0.wit` as `package astrid:kv@1.0.0`:

```wit
kv-get:        func(key: string) -> result<option<list<u8>>, error-code>;
kv-set:        func(key: string, value: list<u8>) -> result<_, error-code>;
kv-delete:     func(key: string) -> result<_, error-code>;
kv-list-keys:  func(prefix: string) -> result<list<string>, error-code>;
kv-list-keys-page: func(prefix: string, cursor: option<string>, limit: u32)
                       -> result<key-page, error-code>;
kv-clear-prefix: func(prefix: string) -> result<u64, error-code>;
kv-cas: func(key: string, expected: option<list<u8>>, new: list<u8>)
             -> result<_, error-code>;
```

The `error-code` variant has: `invalid-key`, `too-large`, `quota`, `cas-mismatch`,
`unknown(string)`.

The file is frozen. Shape changes are versioned as a new file at a new path, never edits to
the existing file.

## SDK API

Capsule authors import `astrid_sdk::kv`. The module wraps the WIT bindings and adds typed
convenience functions. All functions are synchronous from the capsule's perspective.

### Raw bytes

```rust
use astrid_sdk::kv;

// Write
kv::set_bytes("my-key", b"raw value")?;

// Read, returns None for missing keys
let val: Option<Vec<u8>> = kv::get_bytes_opt("my-key")?;

// Read, returns empty Vec for missing keys (pre-migration compat shape)
let val: Vec<u8> = kv::get_bytes("my-key")?;

// Delete (idempotent)
kv::delete("my-key")?;

// List
let keys: Vec<String> = kv::list_keys("prefix.")?;
```

### JSON

```rust
#[derive(serde::Serialize, serde::Deserialize)]
struct Config { model: String, temperature: f32 }

kv::set_json("config", &Config { model: "gpt-4o".into(), temperature: 0.7 })?;
let cfg: Config = kv::get_json("config")?;       // Err if missing or invalid JSON
let cfg: Option<Config> = kv::get_json_opt("config")?;  // None if missing
```

### Borsh

```rust
use borsh::{BorshSerialize, BorshDeserialize};

#[derive(BorshSerialize, BorshDeserialize)]
struct Counter { n: u64 }

kv::set_borsh("counter", &Counter { n: 0 })?;
let c: Counter = kv::get_borsh("counter")?;
```

### Atomic Compare-and-Swap

`kv::cas` returns `Ok(true)` when the swap was applied, `Ok(false)` on mismatch (the normal
lost-race path), and `Err` only for genuine host failures. The WIT host fn surfaces mismatch
as `Err(ErrorCode::CasMismatch)`, which the SDK wrapper translates back to `Ok(false)` so
capsule code can branch on a bool rather than pattern-match an error variant.

```rust
// Create-if-absent: expected = None means "must be missing"
let created = kv::cas("lock", None, b"owner-id")?;

// Replace if still matching previous read
let old_bytes: Option<Vec<u8>> = kv::get_bytes_opt("state")?;
let won = kv::cas("state", old_bytes.as_deref(), &new_bytes)?;
if !won {
    // Lost the race; re-read and retry
}
```

The capsule-registry uses this pattern to persist shared state without a dedicated lock:

```rust
// capsules/astrid-capsule-registry/src/lib.rs:78-90
let expected = kv::get_bytes_opt(STATE_KEY).ok().flatten();
match kv::cas(STATE_KEY, expected.as_deref(), &new_bytes) {
    Ok(true) => {}
    Ok(false) => { /* lost race, deferring */ }
    Err(e) => { kv::set_bytes(STATE_KEY, &new_bytes); }
}
```

The session capsule uses `cas` inside a retry loop with a bounded attempt count:

```rust
// capsules/astrid-capsule-session/src/lib.rs:39-43
const CAS_RETRY_LIMIT: u32 = 8;
```

### Prefix operations

```rust
// List all keys under a prefix (capped at 1024; use list_keys_page for more)
let keys = kv::list_keys("session.")?;

// Paginated listing
let page = kv::list_keys_page("session.", None, 100)?;
let next = kv::list_keys_page("session.", page.next_cursor.as_deref(), 100)?;

// Delete all keys under a prefix; returns count removed
let n = kv::clear_prefix("session.")?;
```

Note that `kv::list_keys` underneath calls the kv-list-keys WIT function, which the host dispatches to list_keys_with_prefix on the ScopedKvStore (a native range scan in SurrealKvStore). Passing
an empty string lists all keys in the capsule's namespace.

## Versioned Envelope Pattern

`astrid-sdk` provides a schema-versioning layer on top of JSON that capsule authors use to
safely evolve stored data structures.

### Wire format

```json
{ "__sv": 1, "data": { "field": "value" } }
```

The `__sv` field is an unsigned 32-bit integer. The `data` field holds the actual payload.
The key name `__sv` is intentionally unusual to avoid collision with capsule-defined fields.

### Writing versioned data

```rust
#[derive(serde::Serialize, serde::Deserialize)]
struct Profile { name: String, role: String }

const SCHEMA_VERSION: u32 = 2;

let p = Profile { name: "alice".into(), role: "admin".into() };
kv::set_versioned("profile", &p, SCHEMA_VERSION)?;
```

### Reading versioned data

`get_versioned` returns a `Versioned<T>` enum:

```rust
pub enum Versioned<T> {
    Current(T),
    NeedsMigration { raw: serde_json::Value, stored_version: u32 },
    Unversioned(serde_json::Value),  // data written before versioning was adopted
    NotFound,
}
```

Reading a version newer than `current_version` is a hard error (fail secure: do not silently
interpret data from a schema the caller does not understand).

### Automatic migration

`get_versioned_or_migrate` accepts a closure that receives the raw JSON and the stored
version number and must return a `T` at the current version. On success the migrated value
is written back with a plain set. If a concurrent writer mutated the key between the read and the write-back, the migration wins the last-write; capsules needing true atomic migration must implement the CAS retry pattern manually (as the session capsule does). The closure must be idempotent.

```rust
const CURRENT: u32 = 2;

let profile = kv::get_versioned_or_migrate::<Profile>(
    "profile",
    CURRENT,
    |raw, stored_version| match stored_version {
        0 | 1 => {
            // v0/v1 had no `role` field; default to "user"
            let name = raw["name"].as_str().unwrap_or("").to_string();
            Ok(Profile { name, role: "user".into() })
        }
        v => Err(SysError::ApiError(format!("unknown version {v}"))),
    },
)?;
// profile is Option<Profile>; None only when the key did not exist
```

The session capsule demonstrates this pattern inline without the SDK helper: it reads raw
bytes, deserializes, inspects `schema_version`, migrates in memory, and CAS-writes the
migrated bytes back using the original bytes as `expected`. This approach is equivalent to
`get_versioned_or_migrate` but gives the caller control over the retry loop.

## Capsule.toml

No capability declaration is required for basic KV access. Every capsule receives a
`ScopedKvStore` for its `{principal}:capsule:{id}` namespace at load time. There is no
`[capabilities]` entry to gate it.

A capsule that intentionally leaves data behind (for example, session history or user
preferences) should document the keys it uses in its `Capsule.toml` or README, because no
runtime tooling currently enumerates cross-capsule key usage.

## Concurrency

The kernel runs capsule invocations across the multi-threaded Tokio worker pool. The WIT
comment makes the implication explicit:

> Required for any concurrent coordination on shared state. The kernel runs capsule
> invocations across the multi-threaded tokio worker pool, so RMW patterns on shared keys
> race without this.

Plain `kv::set_bytes` is not atomic in the read-modify-write sense. Any pattern that reads a
key and then conditionally writes it back must use `kv::cas`. A plain set is only race-free
when the value is write-only (no reader depends on the previous value).

The `MemoryKvStore` serializes CAS under a single write lock, making the race trivially
impossible. `SurrealKvStore` closes the TOCTOU window with `cas_lock`, as described above.

## Key Design Conventions

Keys used by the standard capsules follow a dotted-segment convention:

```
session.{session_id}         capsule-session: per-session conversation history
react.turn.{turn_id}         capsule-react: in-flight turn state
react.req2sess.{request_id}  capsule-react: request-to-session mapping
registry_state               capsule-registry: provider list and active model
```

The reactor and session capsules use this prefix structure so `kv::clear_prefix` can remove
all keys for a logical entity in one call.

## Error Handling

`SysError` is the SDK's unified error type. KV-specific host errors arrive as
`SysError::HostError(String)` where the string contains the WIT `ErrorCode` variant name
(`"InvalidKey"`, `"TooLarge"`, `"Quota"`, `"CasMismatch"`, or `"Unknown(\"...\")"``).
`JsonError` and `BorshError` surface serialization failures from the typed helpers.

The kernel maps `astrid-storage`'s `StorageError` to `ErrorCode` by substring at the host
boundary (`core/crates/astrid-capsule/src/engine/wasm/host/kv.rs:15-26`). The classification
is best-effort for the `unknown` fallthrough; structured `StorageError` variants are not yet
propagated as typed WIT codes beyond `invalid-key`, `quota`, and `too-large`.

## See also

- [Packages: Filesystem, IO, and Storage](../host-abi/packages-fs-io-storage.md)
- [PrincipalId and Per-Invocation Isolation](../identity/principal-and-isolation.md)
