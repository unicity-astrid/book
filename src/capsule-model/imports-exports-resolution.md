# Imports, Exports, and Dependency Resolution

Every capsule declares what it provides and what it needs through two manifest tables: `[exports]` and `[imports]`. The runtime reads these declarations at boot to build a dependency graph, topologically sorts it, and loads capsules in the resulting order. This page explains the declaration syntax, the semver matching rules, the Kahn's algorithm implementation, cycle detection, the uplink partition, and the `astrid-version` MSRV check. All grounding is in `core/crates/astrid-capsule`.

## Namespace and Interface Names

Every import and export is scoped by a namespace plus an interface name. The namespace is a logical owner (typically `"astrid"` for the built-in contract surface, or a custom string for third-party capsule ecosystems). Both the namespace and every interface name must match `^[a-z][a-z0-9-]*$` -- validated in `discovery.rs:18-54` before the manifest is accepted.

## The `[exports]` Table

Exports declare what a capsule provides to others. Each entry maps an interface name to an exact `semver::Version`.

```toml
[package]
name    = "astrid-capsule-session"
version = "1.2.0"

[exports.astrid]
session = "1.0.0"
```

The runtime stores the full three-part type `(namespace, interface, version)`. Two TOML surfaces are accepted and normalized to the same in-memory `ExportsMap`:

```toml
# Nested form (one table per namespace):
[exports.astrid]
session  = "1.0.0"
identity = "2.0.0"

# Flat form (cargo-like):
[exports]
"astrid:session"  = "1.0.0"
"astrid:identity" = "2.0.0"
```

The flat form requires a colon separating namespace from interface name. Both forms can appear in the same file; the deserializer merges them. The short-form string value is also valid; so is a long-form table:

```toml
[exports.astrid]
session = { version = "1.0.0" }
```

The Rust types are in `manifest/mod.rs`:

```rust
pub type ExportsMap = HashMap<String, HashMap<String, ExportDef>>;

pub struct ExportDef {
    pub version: semver::Version,   // exact version -- not a range
}
```

Exports are iterated as `(namespace, name, version)` triples via `CapsuleManifest::export_triples()` (`manifest/mod.rs:116-122`).

## The `[imports]` Table

Imports declare what a capsule needs from others. Each entry maps an interface name to a semver version requirement plus an optional flag.

```toml
[imports.astrid]
session  = "^1.0"
identity = { version = "^1.0", optional = true }
```

The short-form string is parsed as a `semver::VersionReq`, accepting any semver expression (`^1.0`, `>=1.0, <2.0`, `*`, etc.). Malformed strings are rejected at parse time with the error `"invalid semver requirement '...':"`.

```rust
pub struct ImportDef {
    pub version: semver::VersionReq,
    pub optional: bool,              // defaults to false
}
```

The same dual-form TOML surface applies. Import tuples are surfaced via `CapsuleManifest::import_tuples()` (`manifest/mod.rs:124-131`), which yields `(namespace, name, version_req, optional)` quads.

### Optional Imports

When `optional = true`, a missing provider is not an error. The capsule boots with reduced functionality. The kernel logs an `INFO`-level message (`astrid-kernel/src/lib.rs:1987-1992`) rather than an `ERROR`. A required import with no provider logs `ERROR` (`astrid-kernel/src/lib.rs:1993-1999`) but does not block the boot -- the capsule still loads, per the graceful-degradation design. The `toposort_manifests` function treats unsatisfied optional and non-optional imports identically for ordering purposes: it simply emits a `warn!` and continues (`toposort.rs:106-117`).

## Semver Matching

Dependency resolution uses the function `import_satisfied_by` in `toposort.rs:39-48`:

```rust
pub fn import_satisfied_by(
    import_ns:   &str,
    import_name: &str,
    import_req:  &semver::VersionReq,
    export_ns:   &str,
    export_name: &str,
    export_ver:  &semver::Version,
) -> bool {
    import_ns == export_ns
        && import_name == export_name
        && import_req.matches(export_ver)
}
```

All three conditions must hold. Namespace mismatch (`"astrid"` vs `"other"`) is not an error, it is simply a non-match. Version matching is delegated entirely to the `semver` crate, so all standard cargo-compatible requirement syntax works: `^`, `~`, `>=`, `<`, `=`, `*`, compound ranges.

## Multi-Provider: Any-Satisfies Semantics

When multiple loaded capsules export the same interface, any single one satisfying the importer's requirement is enough to declare the import satisfied and add the ordering edge. The `toposort_manifests` loop (`toposort.rs:89-116`) adds an ordering edge from every matching provider to the consumer, not just the first match:

```rust
for (prov_idx, exports) in all_exports.iter().enumerate() {
    if prov_idx == idx { continue; }
    if exports.iter().any(|(ns, name, ver)| {
        import_satisfied_by(imp_ns, imp_name, imp_req, ns, name, ver)
    }) {
        dependents[prov_idx].push(idx);
        in_degree[idx] += 1;
        satisfied = true;
        // Continue: all providers get an ordering edge.
    }
}
```

The comment is the intent: every provider that satisfies an import gets a "load before me" edge, so if three capsules all export `astrid/session 1.0.0`, all three are guaranteed to be present before the consumer starts. The `validate_imports_exports` function in `astrid-kernel/src/lib.rs:1963-1973` also warns when multiple capsules export the same interface, because that causes double-processing on IPC delivery -- both will fire on matching events.

## Topological Sort: Kahn's Algorithm

`toposort_manifests` in `toposort.rs:67-158` implements Kahn's algorithm over the discovered manifests.

**Inputs.** The function receives `Vec<(CapsuleManifest, PathBuf)>`. It returns `Ok(sorted_vec)` or `Err((CycleError, original_vec))`. The error path returns the original vector as the fallback buffer to avoid cloning.

**Graph construction.** For each manifest at index `idx`:

1. Collect all exports as a flat list per capsule.
2. For each import in `idx`, scan all other capsules' exports with `import_satisfied_by`.
3. On a match: push `idx` into `dependents[prov_idx]` and increment `in_degree[idx]`.

This produces an adjacency list where `dependents[i]` is the set of capsule indices that must load after capsule `i`.

**BFS.** Seed a `VecDeque` with all indices whose `in_degree` is zero (no dependencies). Process nodes in FIFO order: emit the node, decrement the in-degree of each dependent, enqueue dependents whose in-degree drops to zero.

```rust
let mut queue: VecDeque<usize> = in_degree
    .iter()
    .enumerate()
    .filter(|(_, d)| **d == 0)
    .map(|(i, _)| i)
    .collect();

while let Some(idx) = queue.pop_front() {
    order.push(idx);
    for &dependent in &dependents[idx] {
        in_degree[dependent] -= 1;
        if in_degree[dependent] == 0 {
            queue.push_back(dependent);
        }
    }
}
```

**Reorder.** The `order` vector holds indices in topological order. Manifests are extracted by index using `Option::take()` to avoid clones -- each slot is a `Some` that becomes `None` exactly once.

## Cycle Detection

If `order.len() != manifests.len()`, at least one cycle exists. The cycle members are the nodes whose `in_degree` is still above zero after the BFS completes:

```rust
let cycle: Vec<String> = in_degree
    .iter()
    .enumerate()
    .filter(|(_, d)| **d > 0)
    .map(|(i, _)| manifests[i].0.package.name.clone())
    .collect();
return Err((CycleError { cycle }, manifests));
```

The `CycleError` carries the names of the involved capsules, not a single pair. A three-capsule mutual dependency (A needs B, B needs C, C needs A) yields all three names.

The kernel's caller (`astrid-kernel/src/lib.rs:561-570`) treats a cycle as non-fatal:

```rust
let sorted = match toposort_manifests(discovered) {
    Ok(sorted) => sorted,
    Err((e, original)) => {
        tracing::error!(cycle = %e,
            "Dependency cycle in capsules, falling back to discovery order");
        original
    },
};
```

The runtime falls back to discovery order on a cycle rather than refusing to boot. This is intentional -- failing closed would brick a system that has a misconfigured capsule pair.

The diamond dependency works correctly: if D imports both B and C, and B and C both import A, then A gets the lowest in-degree and sorts first, B and C come next (in arbitrary relative order), D last. This is verified in `toposort.rs:407-426`.

## The Uplink Partition

After sorting, the kernel partitions the ordered list into uplink capsules and all others (`astrid-kernel/src/lib.rs:588-595`):

```rust
let (uplinks, others): (Vec<_>, Vec<_>) =
    sorted.into_iter().partition(|(m, _)| m.capabilities.uplink);
```

Uplinks load first. The kernel then calls `await_capsule_readiness` on the uplink names before loading any non-uplink capsule. This ensures IPC subscriptions (the event bus listener for incoming messages over the Unix socket) are active before any capsule that might generate events is started.

### Uplinks Cannot Declare Imports

An uplink capsule loads before any non-uplink capsule. Allowing it to declare `[imports]` would create a paradox: the import's provider would need to load before the uplink, but the uplink loads before all non-uplinks. The manifest loader rejects this at parse time (`discovery.rs:281-289`):

```rust
if manifest.capabilities.uplink && manifest.has_imports() {
    return Err(CapsuleError::ManifestParseError {
        path: path.to_path_buf(),
        message: "[imports] is not allowed on uplink capsules \
                  (uplinks load before non-uplinks and cannot depend on them)"
            .into(),
    });
}
```

The kernel also re-checks this as defense-in-depth after the toposort (`astrid-kernel/src/lib.rs:575-582`), emitting a warning if a manifest somehow bypassed the normal load path. Uplinks may freely declare `[exports]` -- nothing prevents other capsules from importing what an uplink provides, since uplinks are guaranteed to be present first.

## The `astrid-version` MSRV Check

`Capsule.toml` supports an `astrid-version` field in `[package]`, mirroring Cargo's `rust-version`:

```toml
[package]
name           = "my-capsule"
version        = "0.1.0"
astrid-version = ">=0.4.0"
```

The value is a semver requirement string. At manifest load time (`discovery.rs:215-236`), the loader compares it against the running runtime version, which is injected at compile time via `env!("CARGO_PKG_VERSION")`:

```rust
if let Some(ref constraint) = manifest.package.astrid_version {
    let runtime = semver::Version::parse(env!("CARGO_PKG_VERSION"))
        .expect("valid semver");
    let req = semver::VersionReq::parse(constraint).map_err(|e| {
        CapsuleError::ManifestParseError { ... }
    })?;

    if !req.matches(&runtime) {
        return Err(CapsuleError::ManifestParseError {
            path: path.to_path_buf(),
            message: format!(
                "capsule requires astrid-version {constraint}, \
                 but this runtime is {runtime}"
            ),
        });
    }
}
```

A failed check produces a hard error, not a warning. The capsule is not loaded. An absent `astrid-version` field is unconditionally accepted. The `semver::VersionReq` parser is the same crate used for imports -- all cargo-compatible expressions apply.

## Boot Validation: Checking Satisfied Imports

After sorting and before loading, the kernel calls `validate_imports_exports` (`astrid-kernel/src/lib.rs:1940-2010`). This pass:

1. Builds an index of `(namespace, interface) -> Vec<(capsule_name, version)>` from all exports.
2. Warns on any interface exported by more than one capsule.
3. Iterates every import across every capsule, checking whether any provider's version satisfies the requirement.
4. Logs `INFO` for unsatisfied optional imports, `ERROR` for unsatisfied required imports.
5. Emits a final `INFO` summary with counts.

This validation is advisory only -- capsules still load regardless of import satisfaction. The actual consequence of a missing required interface is a runtime error when the capsule attempts to call through the host function that was supposed to be provided.

## Complete Example

A three-capsule setup where `astrid-capsule-react` depends on `astrid-capsule-session` and optionally on `astrid-capsule-identity`:

```toml
# capsules/astrid-capsule-session/Capsule.toml
[package]
name    = "astrid-capsule-session"
version = "1.0.0"

[exports.astrid]
session = "1.0.0"
```

```toml
# capsules/astrid-capsule-identity/Capsule.toml
[package]
name    = "astrid-capsule-identity"
version = "1.0.0"

[exports.astrid]
identity = "1.0.0"
```

```toml
# capsules/astrid-capsule-react/Capsule.toml
[package]
name           = "astrid-capsule-react"
version        = "0.9.0"
astrid-version = ">=0.4.0"

[imports.astrid]
session  = "^1.0"
identity = { version = "^1.0", optional = true }
```

Both `session` and `identity` export `astrid/*` at `1.0.0`, which satisfies `^1.0`. The toposort places both providers before `react`. The kernel loads `session` and `identity` first (in whichever order their own `in_degree` allows), then loads `react`. If `identity` were absent, `react` still loads -- it just knows `identity` may not respond.

This exact scenario is tested in `toposort.rs:453-484`.

## Identifier Grammar

Namespace and interface names share the same validation rule (`discovery.rs:18-25`):

```
identifier := [a-z] [a-z0-9-]*
```

Uppercase, underscores, dots, and colons are rejected. The colon is reserved as the flat-form separator in `[imports]` and `[exports]` table keys. This grammar is enforced at `load_manifest` time for both `[imports]` and `[exports]` sections, after semver parsing has already been done by the custom `Deserialize` implementations.

## See also

- [The Capsule Manifest and Engines](manifest-and-engines.md)
- [Distros and the Content-Addressed Store](../distribution/distros-and-store.md)
