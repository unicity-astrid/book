# ABI Evolution

The Astrid host ABI is split into 13 independent WIT packages, each in its own file under `host/` in the canonical `unicity-astrid/wit` repository. The central guarantee of the evolution discipline is that once a file ships on `main` it is never modified. All shape changes go into a new file at a new version.

## The Frozen-File Rule

Every `host/<name>@X.Y.Z.wit` file carries this header comment:

> Frozen per the ABI evolution discipline (RFC: host_abi). Shape changes ship as a new file at a new version path; never edit this file.

The rule exists because the wasmtime Component Model linker enforces exact structural typing on every `(package, version)` pair. A capsule compiled against `astrid:ipc@1.0.0` encodes the full structural shape of that interface into its compiled WASM component binary. If the host-side definition of `astrid:ipc@1.0.0` later gains a field or a function, the linker's type check fails at instantiation time and the capsule refuses to load. There is no runtime compatibility shim. The only safe path is: leave the file alone and add a new one.

This is not a soft convention around semantic compatibility. It is a hard constraint from the Component Model's structural type system. The file names are the version identifiers. Renaming or editing them are equivalent operations from the linker's perspective.

## Per-Domain Packages and Independent Versioning

Every domain is its own package. The 13 current packages under `wit/host/`, all frozen at `@1.0.0`, are:

| File | Package |
|------|---------|
| `host/approval@1.0.0.wit` | `astrid:approval@1.0.0` |
| `host/elicit@1.0.0.wit` | `astrid:elicit@1.0.0` |
| `host/fs@1.0.0.wit` | `astrid:fs@1.0.0` |
| `host/guest@1.0.0.wit` | `astrid:guest@1.0.0` |
| `host/http@1.0.0.wit` | `astrid:http@1.0.0` |
| `host/identity@1.0.0.wit` | `astrid:identity@1.0.0` |
| `host/io@1.0.0.wit` | `astrid:io@1.0.0` |
| `host/ipc@1.0.0.wit` | `astrid:ipc@1.0.0` |
| `host/kv@1.0.0.wit` | `astrid:kv@1.0.0` |
| `host/net@1.0.0.wit` | `astrid:net@1.0.0` |
| `host/process@1.0.0.wit` | `astrid:process@1.0.0` |
| `host/sys@1.0.0.wit` | `astrid:sys@1.0.0` |
| `host/uplink@1.0.0.wit` | `astrid:uplink@1.0.0` |

A capsule world declares only the domains it actually uses:

```wit
// Interceptor-only capsule (router):
world router {
    include astrid:guest/interceptor@1.0.0;
    import astrid:ipc/host@1.0.0;
    // not importing net, http, identity, ...
}

// Run-loop capsule with install hook (cli uplink):
world cli {
    include astrid:guest/interceptor@1.0.0;
    include astrid:guest/background@1.0.0;
    include astrid:guest/installable@1.0.0;
    import astrid:ipc/host@1.0.0;
    import astrid:uplink/host@1.0.0;
    import astrid:net/host@1.0.0;
}
```

Per-domain packaging means a version bump to `astrid:ipc` does not affect a capsule that imports only `astrid:fs` and `astrid:kv`. Capsules carry no lockstep update burden for domains they never import.

## Additive Changes via New Version Files

When a domain needs a new record field, a new function, or a new variant, the procedure is:

1. Copy the latest frozen file:

```bash
cp host/ipc@1.0.0.wit host/ipc@1.1.0.wit
```

2. Bump the `package` declaration inside the new file:

```wit
package astrid:ipc@1.1.0;
```

3. Apply your shape changes to the new file only.

4. Leave the frozen file untouched.

The result is a `host/` directory with both files present:

```
host/
  ipc@1.0.0.wit      # frozen forever
  ipc@1.1.0.wit      # frozen once shipped (additive change)
  ipc@2.0.0.wit      # frozen once shipped (breaking change from 1.x)
```

For an additive change (add a function, add an optional record field), `@1.0.0` and `@1.1.0` can coexist without any capsule migration. For a breaking change (remove a function, rename a type), old capsules bound to `@1.0.0` cannot instantiate against `@2.0.0` by design. Migration is explicit.

## Dual Linker Registration

The wasmtime Component Model linker has no implicit version negotiation. A capsule that imports `astrid:ipc@1.0.0` requires the kernel to have registered exactly that package-version pair. A capsule that imports `astrid:ipc@1.1.0` requires a separate registration for that pair.

The kernel generates its host bindings using a synthetic inline world in `core/crates/astrid-capsule/src/engine/wasm/bindings.rs`:

```rust
wasmtime::component::bindgen!({
    inline: "
        package kernel:host;
        world kernel {
            import astrid:io/error@1.0.0;
            import astrid:io/poll@1.0.0;
            import astrid:io/streams@1.0.0;
            import astrid:fs/host@1.0.0;
            import astrid:ipc/host@1.0.0;
            import astrid:kv/host@1.0.0;
            import astrid:net/host@1.0.0;
            import astrid:http/host@1.0.0;
            import astrid:sys/host@1.0.0;
            import astrid:process/host@1.0.0;
            import astrid:uplink/host@1.0.0;
            import astrid:elicit/host@1.0.0;
            import astrid:approval/host@1.0.0;
            import astrid:identity/host@1.0.0;
            import astrid:guest/lifecycle@1.0.0;
        }
    ",
    path: "wit-staging",
    // ...
});
```

The comment in that file makes the multi-version requirement explicit:

> Note: every package is pinned at `@1.0.0`. When a new frozen version ships (e.g. `host/ipc@1.1.0.wit`), add it here as an additional import AND register a second `add_to_linker` call. The wasmtime Component Model linker enforces exact `(package, version)` matches, so multiple versions must be registered explicitly to allow old and new capsules to coexist.

The concrete registration call is in `core/crates/astrid-capsule/src/engine/wasm/mod.rs`:

```rust
pub fn configure_kernel_linker(
    linker: &mut wasmtime::component::Linker<HostState>,
) -> wasmtime::Result<()> {
    bindings::Kernel::add_to_linker::<HostState, wasmtime::component::HasSelf<HostState>>(
        linker,
        |state| state,
    )
}
```

`configure_kernel_linker` is the single source of truth for both the main capsule-load path and the lifecycle-hook path (`run_lifecycle`). The comment in `mod.rs` notes this explicitly: what a capsule sees at install time must match what it sees at runtime.

When `@1.1.0` ships, the pattern becomes two `bindgen!` invocations and two `add_to_linker` calls:

```rust
// @1.0.0 bindings (generated once, never regenerated)
bindings_v1_0::Kernel::add_to_linker::<HostState, _>(linker, |s| s)?;
// @1.1.0 bindings
bindings_v1_1::Kernel::add_to_linker::<HostState, _>(linker, |s| s)?;
```

Both registrations live in `configure_kernel_linker` so neither load path can diverge.

## Multi-Version Coexistence

Once both registrations are in place, old and new capsules load from the same kernel daemon without any coordination. The Component Model linker resolves each capsule to the package-version pair it was compiled against. There is no negotiation, no adapter, and no runtime shim. A capsule pinned to `astrid:ipc@1.0.0` calls the `@1.0.0` host implementation. A capsule pinned to `astrid:ipc@1.1.0` calls the `@1.1.0` host implementation. They can run concurrently in the same daemon.

The SDK side mirrors this. The `astrid-sys` crate documents the same requirement in `sdk-rust/astrid-sys/src/lib.rs`:

> Every package imported here is pinned at `@1.0.0`. When a new frozen version ships (e.g. `host/ipc@1.1.0.wit`), add it to the inline world as an additional `import`. The Component Model linker enforces exact `(package, version)` matches, so capsules pinned at the older version continue to resolve their old interface unchanged.

## Repository Layout and Build Wiring

The canonical WIT repository is `unicity-astrid/wit`. The kernel (`core/`) and the Rust SDK (`sdk-rust/`) both submodule it. The kernel submodule lands at `core/wit/`; the SDK submodule lands at `sdk-rust/contracts/`.

`build.rs` in `astrid-capsule` stages the WIT files at build time:

```rust
fn stage_wit() {
    // Copies each host/<pkg>@<ver>.wit into
    // wit-staging/deps/astrid-<pkg>/<pkg>@<ver>.wit
    // so wasmtime::component::bindgen! can find them.
}
```

The build script handles three cases: workspace builds where the submodule is checked out (clean and re-stage, CI fails on dirty `git status`), published-crate installs where the submodule is absent (use the committed `wit-staging/` that ships with the crate tarball), and developer clones without `git submodule update --init` (detect absence of `.wit` files, skip restaging rather than wiping the committed copy).

When a new version file (`host/ipc@1.1.0.wit`) is added to the submodule, `build.rs` automatically copies it into `wit-staging/deps/astrid-ipc/`. The developer must still add the corresponding `import` to the inline world and add the second `add_to_linker` call by hand.

## CI Validation

The `wit` repo runs `scripts/validate-wit.sh` in CI on every push and pull request against `main`. The script stages each `host/*.wit` file alongside its siblings so cross-package `use` clauses (for example `use astrid:io/poll@1.0.0.{pollable}` in `http@1.0.0.wit`) resolve, then parses each file with `wasm-tools component wit`.

```yaml
- name: Parse every host/*.wit file
  run: scripts/validate-wit.sh
```

The script only validates `host/`. The `interfaces/` files cross-reference each other in ways that `wasm-tools` 1.x cannot topologically resolve in a single pass. Those are validated downstream by SDK builds using `cargo-component` and `wkg`, which perform proper dependency resolution.

## Current Enforcement State

The frozen-file rule is enforced by convention and code review, not by a CI gate. The automated frozen-file check (which compared SHA256 hashes of each `host/*.wit` file against a committed manifest) was retired during pre-adoption iteration. The rationale, stated in both READMEs:

> No SDK or capsule is bound to `@1.0.0` yet, so in-place amendments don't break anyone. Once a real downstream consumer ships against a versioned file, re-enable the check (the original script lives in git history) so accidental edits surface in review.

In the current state, every `host/*.wit` file carries the marker comment "never edit this file," and the per-file version in the `package` declaration and the filename must agree by convention. The CI parse check (`validate-wit.sh`) catches malformed WIT syntax but not in-place edits to frozen files.

The practical consequence: treat the absence of the CI gate as a temporary concession to iteration speed, not a signal that the rule is optional. The rule's purpose (preventing instantiation failures in shipped capsules) applies with full force the moment any capsule is published against a versioned interface. The script to restore the gate is recoverable from git history.

## What Triggers an RFC

Per the RFC scope definition in CLAUDE.md, a host ABI change that alters the guest-visible WIT surface (adding a function, a record field, a new package, or a new version of an existing package) requires an RFC. Kernel-internal routing or dispatch changes that preserve the WIT contract do not.

The reference RFC for the host ABI design is [RFC: Host ABI (PR #22)](https://github.com/unicity-astrid/rfcs/pull/22), which established the per-domain packages, the frozen-file rule, and the multi-version kernel registration model. The motivating defect was [issue #750](https://github.com/unicity-astrid/astrid/issues/750).

## See also

- [WIT Contracts and the Three-Repo Flow](../evolution/wit-contracts.md)
- [The RFC Process](../evolution/rfc-process.md)
- [The Syscall Surface](the-syscall-surface.md)
