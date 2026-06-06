# The VFS Copy-on-Write Overlay

The `astrid-vfs` crate (`core/crates/astrid-vfs`) implements a layered virtual filesystem that runs entirely inside the kernel daemon. It gives each capsule invocation a sandboxed view of the workspace: reads go through to a shared, read-only lower layer, and writes land in an ephemeral per-principal upper layer that is invisible to every other principal. The design intentionally mirrors Linux overlayfs at a semantic level, but is implemented in safe Rust on top of the `cap-std` crate rather than through kernel mounts.

## The `Vfs` Trait

Every VFS implementation in this crate satisfies the same async interface:

```rust
// core/crates/astrid-vfs/src/lib.rs:62
#[async_trait]
pub trait Vfs: Send + Sync {
    async fn exists(&self, handle: &DirHandle, path: &str) -> VfsResult<bool>;
    async fn readdir(&self, handle: &DirHandle, path: &str) -> VfsResult<Vec<VfsDirEntry>>;
    async fn stat(&self, handle: &DirHandle, path: &str) -> VfsResult<VfsMetadata>;
    async fn mkdir(&self, handle: &DirHandle, path: &str) -> VfsResult<()>;
    async fn unlink(&self, handle: &DirHandle, path: &str) -> VfsResult<()>;
    async fn open(
        &self,
        handle: &DirHandle,
        path: &str,
        write: bool,
        truncate: bool,
    ) -> VfsResult<FileHandle>;
    async fn open_dir(
        &self,
        handle: &DirHandle,
        path: &str,
        new_handle: DirHandle,
    ) -> VfsResult<()>;
    async fn close_dir(&self, handle: &DirHandle) -> VfsResult<()>;
    async fn read(&self, handle: &FileHandle) -> VfsResult<Vec<u8>>;
    async fn write(&self, handle: &FileHandle, content: &[u8]) -> VfsResult<()>;
    async fn close(&self, handle: &FileHandle) -> VfsResult<()>;
}
```

Every method takes either a `DirHandle` (for directory-scoped operations) or a `FileHandle` (for byte-level operations). Path strings are always relative within the handle's scope. There are no raw host paths anywhere in the interface: the handle is the authority, not the string.

## Capability Handles: Not Paths

`DirHandle` and `FileHandle` are UUID-valued newtype structs defined in `astrid-capabilities`:

```rust
// core/crates/astrid-capabilities/src/handle.rs:6
pub struct DirHandle(pub String);  // wraps a UUIDv4

pub struct FileHandle(pub String); // wraps a UUIDv4
```

A WASM guest never holds a host path. It holds a handle minted by the host. `HostVfs` maintains two internal maps: `open_dirs: RwLock<HashMap<DirHandle, Arc<Dir>>>` and `open_files: RwLock<HashMap<FileHandle, OpenFileEntry>>`. An unknown handle fails immediately with `VfsError::InvalidHandle`. A guest that tries to construct a `DirHandle` with a guessed UUID gets nothing useful because no physical directory is registered under that UUID.

`open_dir` narrows an existing handle into a sub-directory handle: the caller supplies the parent `DirHandle` and a pre-allocated new `DirHandle`. The implementation opens a child `cap_std::fs::Dir` relative to the parent and stores it under the new handle. After this call the child handle is scoped to that subdirectory and cannot reach anything above it. Closing the parent does not close the child.

## `HostVfs`: The Physical Lower Layer

`HostVfs` (`src/host.rs`) is the only implementation that touches real disk. It relies on `cap-std` throughout: every directory operation operates on a `cap_std::fs::Dir`, which is an ambient-authority-free POSIX file descriptor. The kernel opens the physical root directory once and stores it as a `Dir`; all subsequent paths are resolved relative to that `Dir` by the OS, making `../` traversal impossible at the syscall level regardless of the string passed in.

Before passing any path to `cap-std`, `HostVfs` strips leading slashes and prefix components with `make_relative`:

```rust
// src/host.rs:18
fn make_relative(requested: &str) -> &Path {
    let path = Path::new(requested);
    let mut components = path.components();
    while let Some(c) = components.clone().next() {
        if matches!(c, Component::RootDir | Component::Prefix(_)) {
            components.next();
        } else {
            break;
        }
    }
    components.as_path()
}
```

File descriptor count is bounded at two points: a `Semaphore` with 64 permits that must be acquired before calling `open` on the OS, and a hard check that the `open_files` map has fewer than 64 entries before inserting. A read or write that would exceed 50 MB is rejected with `VfsError::PermissionDenied`. The 50 MB limit is consistent across both `HostVfs::read` and `OverlayVfs::commit`.

## `OverlayVfs`: The Copy-on-Write Layer

`OverlayVfs` (`src/overlay.rs`) holds two `Box<dyn Vfs>` values: `lower` (read-only workspace) and `upper` (ephemeral scratch space, normally backed by a `tempfile::TempDir`).

```rust
// src/overlay.rs:40
pub struct OverlayVfs {
    lower: Box<dyn Vfs>,
    upper: Box<dyn Vfs>,
    copy_locks: DashMap<String, Arc<Mutex<()>>>,
    dirty_entries: DashMap<String, DirtyKind>,
    _upper_tempdir: Option<Arc<tempfile::TempDir>>,
}
```

The central invariant: all reads prefer the upper layer and fall through to the lower layer only on miss. All writes go exclusively to the upper layer. The lower layer is never written during normal operation; it changes only on an explicit `commit` call.

### Read Path

For `exists`, the overlay checks upper first; if absent, checks lower. For `stat`, it tries `upper.stat` and falls back to `lower.stat` on any error. `readdir` merges both layers into a `HashMap` keyed by entry name, with upper entries overwriting lower entries on collision. The merged result is returned as a `Vec`. For `read` on an open `FileHandle`, the overlay tries `upper.read` and, on `InvalidHandle`, tries `lower.read`. This works because the handle was created by whichever layer successfully opened the file.

### Write Path and Copy-Up

When `open` is called with `write: true`, the overlay must decide whether the target file already exists in the upper layer. If the file exists in lower but not yet in upper, a copy-up is needed. The copy-up sequence is:

1. Acquire a per-path `Mutex` from `copy_locks` (a `DashMap<String, Arc<Mutex<()>>>`). This serializes concurrent copy-ups for the same path.
2. Re-check after acquiring the lock to handle the race where another task already completed the copy-up.
3. If `truncate` is true, skip reading from lower and create an empty file in upper directly. The old lower content is irrelevant when the caller is overwriting.
4. Otherwise, stat the lower file and reject it if it exceeds 50 MB (`MAX_OVERLAY_FILE_SIZE`). Read the entire file from lower, open a new file in upper (with `create` and `truncate`), and write the content. If the write fails, the partial upper file is removed immediately to leave no truncated copy behind.
5. Release the `Mutex` (the `LockGuard` wrapper calls `DashMap::remove` on drop, so exhausted lock entries do not accumulate).

After copy-up, `open` delegates to `upper.open` for the actual `FileHandle`. The returned handle is from `HostVfs::open` inside the upper layer. Subsequent `read` or `write` calls on that handle route to the upper layer's file table.

The parent directories of the target path may not exist in the upper layer yet. Before attempting copy-up, `open` calls `ensure_upper_dirs`, which recursively routes `mkdir` through `self` (the `OverlayVfs` impl) so that created directories are tracked in `dirty_entries`.

### The `dirty_entries` Map

`dirty_entries: DashMap<String, DirtyKind>` records every path that has been mutated in the upper layer since the last commit or rollback. Paths are stored as normalized relative strings (no leading slash). `DirtyKind` distinguishes files from directories so that `commit` and `rollback` can handle them appropriately.

```rust
// src/overlay.rs:18
enum DirtyKind {
    File,
    Dir,
}
```

`mkdir` inserts the normalized path as `DirtyKind::Dir`. `open(write=true)` inserts as `DirtyKind::File`. `unlink` removes the entry from the dirty set after removing the file from upper. The `open_dir` method creates directories in upper for handle symmetry but deliberately does not insert into `dirty_entries`, since opening a directory for navigation is not a mutation:

```rust
// src/overlay.rs:479
// Eagerly create the directory in upper to ensure symmetric handle mapping
self.upper.mkdir(handle, path).await.unwrap_or(());
self.upper.open_dir(handle, path, new_handle.clone()).await?;
// Note: NOT inserted into dirty_entries.
```

### Path Traversal Rejection

`OverlayVfs::normalize_path` runs before any mutation:

```rust
// src/overlay.rs:274
fn normalize_path(path: &str) -> VfsResult<String> {
    let resolved = crate::path::resolve_path(std::path::Path::new("/"), path)?;
    let s = resolved.to_string_lossy();
    Ok(s.strip_prefix('/').unwrap_or(&s).to_string())
}
```

`resolve_path` (`src/path.rs`) is a purely lexical, no-filesystem resolver. It first rejects absolute paths via `req.is_absolute()` before any component iteration. Then, inside the component loop, it rejects `Component::Prefix` and `Component::RootDir` with `VfsError::SandboxViolation`. For `..` components, it checks whether popping the current resolved path would go below the base root, and rejects if so. The `cap-std` OS-level containment is the second line of defense; this check is the first.

### Unlink Restriction

Deleting a file that exists in the lower layer returns `VfsError::NotSupported` with the message "Cannot delete read-only workspace file (whiteout support not implemented)". Overlayfs whiteout entries (tombstones that hide lower-layer files from the merged view) are not implemented. Only upper-layer files can be unlinked through the overlay.

### Commit

`commit` propagates the upper layer's dirty set to the lower layer, effectively making the changes permanent in the workspace. For each dirty path:

- `DirtyKind::Dir`: calls `ensure_lower_dirs` recursively to create the directory in lower.
- `DirtyKind::File`: stats the upper file and refuses if it exceeds 50 MB. Reads the full content from upper, opens the lower path with `write=true, truncate=true`, writes the content, and then removes the upper copy via `unlink`. Successfully committed paths are removed from `dirty_entries`; a partial failure on one path leaves remaining paths in the dirty set so the caller can inspect or retry.

```rust
// src/overlay.rs:126
pub async fn commit(&self, handle: &DirHandle) -> VfsResult<Vec<String>>
```

The docstring notes an important assumption: WASM capsules are single-threaded, so callers can safely assume no concurrent writes during commit when they call it between tool invocations.

**There is no production caller for `commit` today.** The doc comment in `overlay_registry.rs` is explicit:

> `OverlayVfs::commit` and `OverlayVfs::rollback` are not called from any production path today; the registry simply stands up the data-structure isolation required by invariant #7 from issue #653.

The infrastructure is built and tested, but the capsule-level plumbing that would call commit at the end of a tool invocation does not exist yet.

### Rollback

`rollback` discards every dirty upper-layer path without touching lower. Files are removed via `upper.unlink`; directories are left (the `TempDir::drop` cleans up on capsule unload). All entries are removed from `dirty_entries`. After rollback, reads serve exclusively from lower as if no writes had occurred, verified by the `rollback_then_read_serves_lower` test.

```rust
// src/overlay.rs:192
pub async fn rollback(&self, handle: &DirHandle) -> VfsResult<Vec<String>>
```

Like commit, rollback has no production caller.

## Per-Principal Registry

`OverlayVfsRegistry` (`src/overlay_registry.rs`) is the top-level entry point. It maintains a bounded, lazy cache of one `Arc<OverlayVfs>` per `PrincipalId`. Every principal gets its own upper-layer `TempDir`, so two principals writing the same relative path never see each other's bytes.

```rust
// src/overlay_registry.rs:79
pub struct OverlayVfsRegistry {
    workspace_root: PathBuf,
    root_handle: DirHandle,
    max_principals: usize,
    idle_eviction: Duration,
    anchor: Instant,
    overlays: RwLock<HashMap<PrincipalId, Entry>>,
}
```

### Cache Lifetime and the Tempdir Guard

The tempdir lifetime is deliberately owned by the `OverlayVfs`, not the registry entry. When the registry evicts an entry under cap pressure, it removes the `Entry` from the `HashMap`, which drops the `Arc<OverlayVfs>` clone stored there. If a task still holds its own `Arc<OverlayVfs>` clone from an earlier `resolve` call, the tempdir stays alive until that last clone drops. This is implemented via `_upper_tempdir: Option<Arc<tempfile::TempDir>>` inside `OverlayVfs` itself, populated by `new_with_upper_guard`:

```rust
// src/overlay.rs:87
pub fn new_with_upper_guard(
    lower: Box<dyn Vfs>,
    upper: Box<dyn Vfs>,
    upper_tempdir: Arc<tempfile::TempDir>,
) -> Self
```

The registry's `build_for` wraps the raw `TempDir` in an `Arc` before handing it to `new_with_upper_guard`:

```rust
// src/overlay_registry.rs:255
Ok(Arc::new(OverlayVfs::new_with_upper_guard(
    Box::new(lower),
    Box::new(upper),
    Arc::new(upper_dir),
)))
```

### Resolve Hot Path

`resolve` acquires a read lock for the cache hit and does not need a write lock at all, because the only mutation on the hit path is a `last_used_ms` atomic store:

```rust
// src/overlay_registry.rs:171
if let Some(entry) = guard.get(principal) {
    entry.last_used_ms.store(self.now_ms(), Ordering::Relaxed);
    return Ok(Arc::clone(&entry.overlay));
}
```

The slow path (cache miss) builds the overlay outside the write lock so concurrent first-access for different principals can run in parallel. A double-build race for the same principal is handled at insertion by a first-writer-wins check: if an entry was inserted by another task while we were building, we return the cached one and discard ours.

### Eviction Policy

The cap defaults to 1024 principals, tunable via `ASTRID_OVERLAY_REGISTRY_MAX_PRINCIPALS`. When the registry is at or above cap on a new admission, `evict_idle_locked` runs a single pass over all entries and picks the one with the smallest `last_used_ms` that is beyond the 10-minute idle window. If no entry is idle, it falls back to evicting the globally oldest entry. This is a soft LRU admission control, not a sliding window.

```rust
// src/overlay_registry.rs:276
let victim = guard
    .iter()
    .map(|(p, e)| (p, e.last_used_ms.load(Ordering::Relaxed)))
    .min_by_key(|&(_, ts)| (ts > cutoff_ms, ts))
    .map(|(p, _)| p.clone());
```

The tuple `(ts > cutoff_ms, ts)` sorts idle entries (where the flag is `false`) before non-idle entries, and within each group picks the smallest timestamp.

### Quotas

The current implementation enforces:

- **50 MB per-file cap** on copy-up (`overlay.rs:403`) and on commit (`overlay.rs:152`). Files exceeding this limit return `VfsError::PermissionDenied`.
- **50 MB per-read cap** in `HostVfs::read` (`host.rs:298`). Reads are bounded by both `file.metadata().len()` and a `take` sentinel.
- **64 open file descriptors** per `HostVfs` instance, enforced by a `Semaphore` and a map-length check in `open` (`host.rs:210`, `host.rs:232`).
- **64 open directories** per `HostVfs` instance, enforced by a map-length check in `open_dir` (`host.rs:267`).
- **1024 principals** in the overlay registry by default, with LRU eviction above the cap.

There is no per-principal total-bytes quota today. A single principal could write many files each under 50 MB and fill the upper-layer tempdir until the OS rejects writes. This is a known gap, not a design oversight.

## The `WorktreeVfs` and `IgnoreBoundary`

`WorktreeVfs` (`src/worktree.rs`) wraps a `HostVfs` and applies `.astridignore` rules via the `ignore` crate's `Gitignore` matcher. It is `pub(crate)` and currently dead code (the `#[allow(dead_code)]` on the `worktree` module in `lib.rs` confirms this). Its design follows the same handle-not-path discipline as the rest of the crate: boundary checks happen before delegating to the inner `HostVfs`.

## Error Variants

```rust
// src/error.rs:5
pub enum VfsError {
    SandboxViolation(String), // path traversal or absolute path rejected
    InvalidHandle,            // unrecognized DirHandle or FileHandle
    Io(#[from] std::io::Error),
    NotFound(String),
    PermissionDenied(String), // boundary, too many FDs, file too large
    NotSupported(String),     // whiteout not implemented
}
```

`SandboxViolation` is reserved for violations caught by the lexical path resolver before any OS call. `PermissionDenied` is used for quota refusals and `.astridignore` blocks. `NotSupported` is returned when attempting to unlink a lower-layer file through the overlay.

## What Is Tested

The test suite in `src/overlay.rs` covers: writes landing in upper not lower, commit propagating to lower, rollback discarding upper, dirty-path tracking, `open_dir` not polluting the dirty set, explicit `mkdir` being tracked, read fall-through to lower, commit creating parent directories, copy-up followed by commit, rollback restoring the lower view, and attempting to unlink a lower-layer file returning `NotSupported`.

The test suite in `src/overlay_registry_tests.rs` covers: first call builds and second call caches (same `Arc`), two principals isolating their writes at the byte level, cap-of-one evicting on admission, an evicted overlay remaining usable if still held by an `Arc`, explicit invalidation, and concurrent first-use leaving exactly one entry.

Path resolution is tested in `src/path.rs`: valid relative paths, `../` traversal blocked, and absolute paths blocked.

## Limitations to Know

- `commit` and `rollback` are not called from any production code path. The overlay provides write isolation per-principal, but changes are never durable unless a caller explicitly commits them. No such caller exists today.
- Lower-layer files cannot be deleted through the overlay. Whiteout support is absent.
- `WorktreeVfs` and `IgnoreBoundary` are dead code.
- There is no per-principal disk-space quota. The 50 MB per-file ceiling is not a per-invocation or per-principal total.
- `readdir` merges both layers but does not handle files deleted from upper (no whiteout), so a file that exists only in lower and has been "deleted" through the overlay will still appear in directory listings after rollback strips the upper copy.

## See also

- [Packages: Filesystem, IO, and Storage](../host-abi/packages-fs-io-storage.md)
- [PrincipalId and Per-Invocation Isolation](../identity/principal-and-isolation.md)
- [The OS Process Sandbox](../security/os-process-sandbox.md)
