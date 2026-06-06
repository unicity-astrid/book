# Host Packages: Filesystem, IO, and Storage

Three host packages give capsules access to persistent data and I/O primitives: `astrid:fs@1.0.0` (VFS-backed file operations), `astrid:kv@1.0.0` (principal-scoped key-value storage), and `astrid:io@1.0.0` (readiness multiplexing and byte streams). All three are frozen at their `@1.0.0` version; shape changes ship as new version paths, never as edits to these files.

The WIT definitions live in `wit/host/fs@1.0.0.wit`, `wit/host/kv@1.0.0.wit`, and `wit/host/io@1.0.0.wit`. The host implementations live in `core/crates/astrid-capsule/src/engine/wasm/host/fs/`, `…/host/kv.rs`, and `…/host/io.rs`. The capsule-facing SDK wrappers live in `sdk-rust/astrid-sdk/src/fs.rs` and `…/kv.rs`.

---

## `astrid:fs@1.0.0`: Virtual Filesystem

### VFS scheme and path validation

Every path a capsule passes to an `astrid:fs` host function must carry a VFS scheme prefix: `workspace://`, `home://`, or `tmp://`. The kernel resolves the scheme to a physical root on each call. There is no "current directory" concept and no way to pass a raw host path.

Path validation rejects:
- NUL bytes, control characters, non-UTF-8-NFC strings, or strings exceeding the maximum length.
- Absolute paths without a recognized VFS scheme.
- `..` components that resolve outside the VFS scope (returned as `boundary-escape`).

The kernel re-resolves every path on every call (`wit/host/fs@1.0.0.wit:6-8`). The result of `fs-canonicalize` is for display and equality checking only; it is not a security check that subsequent calls can rely on.

### Error type

Every fallible fs function returns `result<_, error-code>` where `error-code` is:

```
variant error-code {
    not-found,
    access,
    capability-denied,
    boundary-escape,
    invalid-path,
    would-block,
    is-directory,
    not-directory,
    not-empty,
    too-large,
    quota,
    cross-vfs,
    already-exists,
    closed,
    unknown(string),
}
```

Error strings in the `unknown` arm never contain host real-paths, IP addresses, UUIDs, or capability names (`wit/host/fs@1.0.0.wit:11-13`).

### Byte-size caps

| Operation | Cap |
|-----------|-----|
| `read-file` / `write-file` / `fs-append` | 10 MB per call (`util::MAX_GUEST_PAYLOAD_LEN` = `10 * 1024 * 1024`) |
| `file-handle.read-at` / `file-handle.write-at` | 1 MB per call (WIT contract) |
| `fs-readdir` | 4096 entries per call |

### Live path-based functions

These functions have production implementations in the host. They route through the per-principal overlay VFS (see `core/crates/astrid-vfs/`) after passing the capability security gate, then emit an audit event to `astrid.audit.fs`.

| WIT function | SDK equivalent | Notes |
|---|---|---|
| `fs-exists` | `fs::exists` | |
| `fs-mkdir` | `fs::create_dir` | Strict: fails if path already exists or parent is missing. Implemented in `host/fs/mod.rs:187`. |
| `fs-mkdir-all` | `fs::create_dir_all` | Idempotent. Implemented in `host/fs/mod.rs:227`. |
| `fs-readdir` | `fs::read_dir` | Returns entry names, not full paths. Cap: 4096 entries. |
| `fs-stat` | `fs::metadata` | Follows symlinks. Returns size, kind, mtime. Created and accessed timestamps are `None` in the current VFS layer (`host/fs/mod.rs:148-150`). |
| `fs-unlink` | `fs::remove_file` | |
| `read-file` | `fs::read` | Convenience wrapper. Two-phase size check (stat before read, cap check after read) to close the TOCTOU window (`host/fs/mod.rs:316-374`). |
| `write-file` | `fs::write` | Truncate-or-create. |

### Stubbed functions

The following functions are defined in the WIT contract but return `ErrorCode::Unknown("... port pending")` from the host. Capsules should handle them as transient failures and fall back to `read-file` / `write-file` for simple access patterns.

**`fs-open` and the entire `file-handle` resource:**
`fs-open` returns `Err(ErrorCode::Unknown("fs-open: FileHandle resource port pending"))`. All six `file-handle` methods (`read-at`, `write-at`, `sync-data`, `sync-all`, `stat`, `set-len`) return the same pattern. This is documented explicitly in `core/crates/astrid-capsule/src/engine/wasm/host/fs/file_handle.rs:1-8`:

```rust
// STUB SHELL, every method returns `Unknown("port pending")`.
```

**Other stubbed path-based functions** (`host/fs/mod.rs:403-443`):

| Function | Message |
|---|---|
| `fs-stat-symlink` | `"fs-stat-symlink: lstat port pending"` |
| `fs-append` | `"fs-append: append-mode port pending"` |
| `fs-copy` | `"fs-copy: VFS copy port pending"` |
| `fs-rename` | `"fs-rename: VFS rename port pending"` |
| `fs-remove-dir-all` | `"fs-remove-dir-all: recursive remove port pending"` |
| `fs-canonicalize` | `"fs-canonicalize: VFS-scheme canonicalization port pending"` |
| `fs-read-link` | `"fs-read-link: readlink port pending"` |
| `fs-hard-link` | `"fs-hard-link: cross-scheme guard + hard-link port pending"` |

`fs-symlink` is intentionally absent from the contract: it would let capsules encode boundary-escape paths into the workspace, so the WIT design omits it entirely (`wit/host/fs@1.0.0.wit:277-282`).

### SDK surface

The SDK (`sdk-rust/astrid-sdk/src/fs.rs`) mirrors `std::fs` naming. All functions return `Result<_, SysError>` where the WIT `error-code` variants are stringified into `SysError::HostError(String)`.

```rust
// Simple whole-file access
fs::read("workspace://data/config.json")?;
fs::write("workspace://data/out.txt", &bytes)?;

// Directory iteration
for entry in fs::read_dir("workspace://data/")? {
    println!("{}", entry.file_name());
}

// Metadata
let meta = fs::metadata("workspace://data/config.json")?;
println!("size: {}", meta.len());
```

The `File` struct wraps the `file-handle` resource, but calling `File::open` currently returns a `SysError::HostError` containing `"fs-open: FileHandle resource port pending"`. Use `fs::read` and `fs::write` for current file access.

### VFS layer internals

The host VFS is implemented in `core/crates/astrid-vfs/`. Three types are in play:

- `HostVfs` (`src/host.rs`): `cap-std`-backed implementation. Uses a `Semaphore::new(64)` to bound concurrent open file descriptors. The `read` method has its own 50 MB ceiling (`host.rs:298-313`), which is higher than the 10 MB WIT contract limit; the host-function layer enforces the tighter bound.
- `OverlayVfs` (`src/overlay.rs`): Copy-on-write layer. Reads fall through to the lower (workspace) layer; writes go to the upper (tempdir) layer. Commit copies dirty files to lower; rollback discards them. Both `commit` and `rollback` exist and are tested but have no production call site today.
- `OverlayVfsRegistry` (`src/overlay_registry.rs`): Per-principal registry. Default cap: 1024 principals (configurable via `ASTRID_OVERLAY_REGISTRY_MAX_PRINCIPALS`). LRU eviction with a 10-minute idle window. The upper-layer `TempDir` is owned by the `OverlayVfs` so eviction cannot delete it while an in-flight invocation holds an `Arc` clone.

The `IgnoreBoundary` (`src/boundary.rs`) enforces `.astridignore` rules using the `ignore` crate's gitignore matching, preventing capsules from reading or writing protected host files (e.g. `.env`).

---

## `astrid:kv@1.0.0`: Key-Value Storage

### Namespace and isolation

Every key in the KV store is scoped to a `(principal, capsule)` pair. The host creates a `ScopedKvStore` with namespace `wasm:{capsule_id}` per capsule context (`core/crates/astrid-storage/src/kv/scoped.rs:3`). Per-invocation principal scoping means two users' data never overlaps even when served by the same capsule. Capsule code never sees or manipulates the namespace string.

### Key and value constraints

- Keys: UTF-8 NFC, no NUL byte, no control characters, max 256 bytes.
- Values: arbitrary bytes, max 1 MiB per value.
- Cumulative per-`(principal, capsule)` quota is server-enforced; exhaustion returns `quota`.

### Operations

```
// WIT contract (astrid:kv@1.0.0)
kv-get: func(key: string) -> result<option<list<u8>>, error-code>;
kv-set: func(key: string, value: list<u8>) -> result<_, error-code>;
kv-delete: func(key: string) -> result<_, error-code>;
kv-list-keys: func(prefix: string) -> result<list<string>, error-code>;
kv-list-keys-page: func(prefix: string, cursor: option<string>, limit: u32)
                       -> result<key-page, error-code>;
kv-clear-prefix: func(prefix: string) -> result<u64, error-code>;
kv-cas: func(key: string, expected: option<list<u8>>, new: list<u8>)
            -> result<_, error-code>;
```

The `kv-get` audit note in the WIT: reads are not recorded per-call (high volume; sampled at kernel level). `kv-set`, `kv-delete`, `kv-clear-prefix`, and `kv-cas` are all audit-recorded.

### Pagination

`kv-list-keys` is capped at 1024 results per call and returns `TooLarge` for larger result sets. The intent is to push callers to `kv-list-keys-page`.

`kv-list-keys-page` in the current host implementation (`host/kv.rs:66-98`) emulates pagination on top of a full `list_keys_with_prefix` call: it lists all matching keys, sorts them, and slices. The `cursor` is the last key on the previous page. This is documented as a 1.0 approximation pending a native cursor API in the storage backend.

### Compare-and-swap

`kv-cas` is the required primitive for concurrent coordination. The kernel dispatches capsule invocations across a multi-threaded Tokio pool so read-modify-write patterns on shared keys race without it.

The WIT contract surfaces a mismatch as `Err(cas-mismatch)`. The SDK translates this back to `Ok(false)` so capsule code can use a boolean branch for the routine lost-race retry (`sdk-rust/astrid-sdk/src/kv.rs:111-117`):

```rust
// sdk-rust/astrid-sdk/src/kv.rs
pub fn cas(key: &str, expected: Option<&[u8]>, new: &[u8]) -> Result<bool, SysError> {
    match wit_kv::kv_cas(key, expected, new) {
        Ok(()) => Ok(true),
        Err(wit_kv::ErrorCode::CasMismatch) => Ok(false),
        Err(e) => Err(host_err(e)),
    }
}
```

`expected = None` is the create-if-absent (insert-lock) form. `MemoryKvStore` serializes the compare-and-write under a single write lock; `SurrealKvStore` serializes all compare_and_swap calls under a global `tokio::sync::Mutex` (the `cas_lock` field in `surreal.rs`) because SurrealKV's MVCC conflict detection alone is insufficient to guarantee atomicity. Commit conflicts from background flush activity are additionally treated as mismatches as a secondary defense (`surreal.rs:246-250`).

### Host storage backend

The host routes KV calls through `ScopedKvStore` -> `KvStore` trait in `core/crates/astrid-storage/`. Two backends exist:

- `MemoryKvStore` (`kv/memory.rs`): in-memory `HashMap`, used in tests and ephemeral deployments.
- `SurrealKvStore` (`kv/surreal.rs`, behind the `kv` feature): `SurrealKV` embedded LSM-tree, ACID-compliant. Production backend.

The composite key format is `"{namespace}\0{key}"` where `\0` is the separator byte and `\x01` closes the namespace range for scans (`kv/mod.rs:85-116`).

### SDK surface

The SDK adds typed convenience on top of the raw byte API:

```rust
// Raw bytes
kv::set_bytes("my-key", b"raw value")?;
let val = kv::get_bytes_opt("my-key")?; // Option<Vec<u8>>

// JSON
kv::set_json("config", &my_struct)?;
let cfg: Option<MyConfig> = kv::get_json_opt("config")?;

// Versioned (schema evolution)
kv::set_versioned("state", &data, 2)?;
match kv::get_versioned::<State>("state", 2)? {
    Versioned::Current(s) => { /* use s */ }
    Versioned::NeedsMigration { raw, stored_version } => { /* migrate */ }
    Versioned::Unversioned(raw) => { /* pre-versioning data */ }
    Versioned::NotFound => { /* first run */ }
}

// Paginated listing
let first = kv::list_keys_page("session:", None, 100)?;
let second = kv::list_keys_page("session:", first.next_cursor.as_deref(), 100)?;

// CAS
loop {
    let current = kv::get_bytes_opt("counter")?;
    let new_val = compute_new(&current);
    if kv::cas("counter", current.as_deref(), &new_val)? { break; }
}
```

The versioned API stores a `{"__sv": N, "data": ...}` envelope. Reading a version newer than `current_version` is an error (fail-secure). `get_versioned_or_migrate` reads and optionally migrates in one call, writing the updated value back automatically.

---

## `astrid:io@1.0.0`: Foundation I/O Primitives

### Why Astrid-owned instead of `wasi:io`

The WIT file explains the choice directly (`wit/host/io@1.0.0.wit:3-29`):

- `pollable.block()` and `poll.poll()` race against the calling capsule's cancellation token. On capsule unload, blocking calls return `cancelled` immediately rather than stranding host tasks on futures that may never complete.
- Every read/write/skip/splice on a stream is audited (per-principal, with bytes transferred and elapsed time).
- Stream and pollable handles are bounded by the per-principal quota profile; exceeding it returns `quota` from the allocating host function.
- Pollables from capsule A's resource table cannot be passed to capsule B (wasmtime resource-table boundary).

The shape mirrors `wasi:io@0.2.0` so capsule SDKs can reason uniformly, but all interfaces are under the `astrid:io` package name.

### Interface: `astrid:io/error`

A downcastable opaque error resource. Carried by `stream-error::last-operation-failed`. Other packages (`astrid:net`, `astrid:http`, `astrid:process`) may provide downcast functions that convert a borrowed `error` into their own typed error-code.

```
resource error {
    to-debug-string: func() -> string;
}
```

`to-debug-string` is for human-readable diagnostics only. Do not parse its content; it is not part of the contract.

### Interface: `astrid:io/poll`

Readiness multiplexing. Capsules obtain `pollable` handles from `subscribe-*` methods on other host resources (TCP streams, HTTP bodies, process stdio) and wait on heterogeneous signals in one call.

```
resource pollable {
    ready: func() -> bool;         // non-blocking; not audit-recorded
    block: func() -> result<_, error-code>;  // blocking; audit-recorded
}

poll: func(pollables: list<borrow<pollable>>) -> result<list<u32>, error-code>;
```

**Hard cap: 256 pollables per `poll` call.** The cap is sized so a capsule at its full IPC subscription quota (128) plus TCP/UDP/HTTP/process stream pollables can wait on all of them in one call (`wit/host/io@1.0.0.wit:68-73`). `too-large` is returned for lists that exceed it.

`block` and `poll` both return `cancelled` if the capsule's cancellation token fires. The host implementation (`host/io.rs:63-66`) checks the token before entering the wasmtime-wasi poll machinery:

```rust
// core/crates/astrid-capsule/src/engine/wasm/host/io.rs
let cancel = self.cancel_token.clone();
let result = if cancel.is_cancelled() {
    Err(ErrorCode::Cancelled)
} else {
    wasi_poll::Host::poll(&mut self.resource_table, pollables).map_err(map_inner_err)
};
```

`ready` is not audit-recorded (high-volume non-blocking check). Each `poll` and `block` call emits a `tracing::debug!` event under target `astrid.audit.io` with capsule ID, principal, handle count, and elapsed milliseconds.

### Interface: `astrid:io/streams`

```
resource input-stream {
    read: func(len: u64) -> result<list<u8>, stream-error>;
    blocking-read: func(len: u64) -> result<list<u8>, stream-error>;
    skip: func(len: u64) -> result<u64, stream-error>;
    blocking-skip: func(len: u64) -> result<u64, stream-error>;
    subscribe: func() -> pollable;
}

resource output-stream {
    check-write: func() -> result<u64, stream-error>;
    write: func(contents: list<u8>) -> result<_, stream-error>;
    blocking-write-and-flush: func(contents: list<u8>) -> result<_, stream-error>;
    flush: func() -> result<_, stream-error>;
    blocking-flush: func() -> result<_, stream-error>;
    subscribe: func() -> pollable;
    write-zeroes: func(len: u64) -> result<_, stream-error>;
    blocking-write-zeroes-and-flush: func(len: u64) -> result<_, stream-error>;
    splice: func(src: borrow<input-stream>, len: u64) -> result<u64, stream-error>;
    blocking-splice: func(src: borrow<input-stream>, len: u64) -> result<u64, stream-error>;
}
```

Streams are never constructed directly by capsules. They are obtained from other resources:
- `astrid:net/host.tcp-stream.{read-stream, write-stream}`: TCP byte halves
- `astrid:http/host.http-stream.body-stream`: HTTP response body
- `astrid:process/host.process-handle.{stdin, stdout, stderr}`: child process stdio

**`check-write` / `write` contract:** `write` must be called with at most the byte count returned by the last `check-write`. Calling `write` with more bytes traps. This is identical to `wasi:io/streams` semantics.

**`splice`** moves bytes from an input to an output in the host without crossing the WASM boundary per byte. It is the primary throughput primitive for proxy and forwarder capsules.

**Non-blocking semantics of all methods:** The host applies a cancel-token guard even to the nominally non-blocking calls (`read`, `write`, `check-write`, `flush`, `skip`, `write-zeroes`). When a capsule is unloading, all stream operations return `closed` immediately rather than allowing one more poll cycle (`host/io.rs:231-237`):

```rust
// core/crates/astrid-capsule/src/engine/wasm/host/io.rs
fn cancel_guard(state: &HostState) -> Result<(), RtStreamError> {
    if state.cancel_token.is_cancelled() {
        Err(RtStreamError::Closed)
    } else {
        Ok(())
    }
}
```

### Stream-error variant

```
variant stream-error {
    last-operation-failed(error),
    closed,
}
```

After a stream returns `last-operation-failed`, the stream is permanently closed. All subsequent calls return `closed`. `closed` is also used for the end-of-stream / EOF signal on input streams and for the cancelled-capsule case on all streams.

### Stub pollables and streams

`core/crates/astrid-capsule/src/engine/wasm/host/stubs.rs` defines three sentinel types used by resource methods whose dedicated pollable wiring has not landed:

- `AlwaysReadyPollable`: resolves immediately. `poll`/`block` return at once; the guest should then call the actual resource's read/recv method.
- `ClosedInputStream`: `read` returns `StreamError::Closed`. Guest observes EOF.
- `ClosedOutputStream`: all output methods return `StreamError::Closed`. Guest cannot write through these stub halves.

These are predictable typed failures, not panics. Capsule code that handles `closed` correctly (as the canonical end-of-stream signal) behaves correctly against stubs without any special casing.

---

## Capability gating summary

| Package | Required capability |
|---|---|
| `astrid:fs` reads (`fs-exists`, `fs-stat`, `read-file`, `fs-readdir`) | `fs_read` |
| `astrid:fs` writes (`fs-mkdir`, `fs-mkdir-all`, `fs-unlink`, `write-file`) | `fs_write` |
| `astrid:fs` hard link (both ends) | `fs_write` on both paths |
| `astrid:kv` all operations | implicitly granted to all capsules (scoped to their own namespace) |
| `astrid:io` all operations | implicitly granted; quota bounded by principal profile |

Manifest capabilities are declared in `Capsule.toml` under `[capabilities]`. The security gate runs before VFS dispatch on every call (`host/fs/mod.rs:94-126`); capability denial returns `ErrorCode::CapabilityDenied` before any path resolution is attempted.

## See also

- [The Syscall Surface](the-syscall-surface.md)
- [The VFS Copy-on-Write Overlay](../storage/vfs-overlay.md)
- [KV Storage](../storage/kv.md)
