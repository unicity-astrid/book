# WIT Contracts and the Three-Repo Flow

The host ABI and the capsule-to-capsule event schemas are both defined in WebAssembly Interface Types (WIT). This page covers what the two WIT packages actually contain, how they travel from the canonical repo through the SDK to a compiled capsule, the frozen-file rule that keeps instantiation from breaking across kernel versions, and the IPC topic naming convention that ties the bus contracts to real payloads.

## Two Namespaces, One Repo

The canonical source of truth is `unicity-astrid/wit` (`wit/` in the monorepo working tree). It contains two independent trees.

### `host/`: the kernel-to-capsule ABI (`astrid:*`)

Files under `host/` define what the kernel provides to every WASM capsule. Each domain is its own package, versioned in the file name.

| File | Package |
|------|---------|
| `host/io@1.0.0.wit` | `astrid:io@1.0.0` |
| `host/fs@1.0.0.wit` | `astrid:fs@1.0.0` |
| `host/ipc@1.0.0.wit` | `astrid:ipc@1.0.0` |
| `host/kv@1.0.0.wit` | `astrid:kv@1.0.0` |
| `host/net@1.0.0.wit` | `astrid:net@1.0.0` |
| `host/http@1.0.0.wit` | `astrid:http@1.0.0` |
| `host/sys@1.0.0.wit` | `astrid:sys@1.0.0` |
| `host/process@1.0.0.wit` | `astrid:process@1.0.0` |
| `host/uplink@1.0.0.wit` | `astrid:uplink@1.0.0` |
| `host/elicit@1.0.0.wit` | `astrid:elicit@1.0.0` |
| `host/approval@1.0.0.wit` | `astrid:approval@1.0.0` |
| `host/identity@1.0.0.wit` | `astrid:identity@1.0.0` |
| `host/guest@1.0.0.wit` | `astrid:guest@1.0.0` |

The `astrid:io` package (`error`, `poll`, `streams`) is the foundation. Its shape mirrors `wasi:io@0.2.0` deliberately, but Astrid implements every interface itself: no `wasi:*` imports reach the kernel, every readiness operation is audited, principal-scoped, cancellable, and quota-bounded. The `host/sys@1.0.0.wit` file documents this explicitly:

> Astrid does not expose any `wasi:*` interfaces to capsules. The host ABI is fully Astrid-owned: every call is gated, principal-scoped, audited, and dispatched through the kernel's capability layer.

The `astrid:guest@1.0.0` package is structurally different from the others: instead of importing functions from the kernel, it declares the worlds the kernel calls *into*. Each entry point lives in a separate world so capsules `include` only the ones they implement.

```wit
// Interceptor-only capsule (e.g. router):
world my-capsule {
    include astrid:guest/interceptor@1.0.0;
    import astrid:ipc/host@1.0.0;
}

// Run-loop capsule with install hook:
world my-capsule {
    include astrid:guest/interceptor@1.0.0;
    include astrid:guest/background@1.0.0;
    include astrid:guest/installable@1.0.0;
    import astrid:ipc/host@1.0.0;
    import astrid:uplink/host@1.0.0;
}
```

Per-export worlds matter: the CM toolchain auto-stubs every export declared in a world the component targets. If all four entry points (`astrid-hook-trigger`, `run`, `astrid-install`, `astrid-upgrade`) lived in one mandatory world, a capsule that only implements `run` would carry stubs for the other three and the kernel would have to parse the WASM binary to distinguish them. With per-export worlds, an export is present in the binary only when the capsule actually implements it (`wit/host/guest@1.0.0.wit:5`).

### `interfaces/`: the capsule-to-capsule event schemas (`astrid-bus:*`)

Files under `interfaces/` define the record types that travel over the IPC bus between capsules. The namespace is deliberately distinct from the host ABI: `astrid-bus:*` vs `astrid:*`. The medium differs too: host-package imports are direct wasmtime Component Model linker calls, while bus-interface records are JSON-serialized payloads published via `astrid:ipc/host.publish`.

| File | Package |
|------|---------|
| `interfaces/types.wit` | `astrid-bus:types@1.0.0` |
| `interfaces/llm.wit` | `astrid-bus:llm@1.0.0` |
| `interfaces/session.wit` | `astrid-bus:session@1.0.0` |
| `interfaces/spark.wit` | `astrid-bus:spark@1.0.0` |
| `interfaces/context.wit` | `astrid-bus:context@1.0.0` |
| `interfaces/prompt.wit` | `astrid-bus:prompt@1.0.0` |
| `interfaces/tool.wit` | `astrid-bus:tool@1.0.0` |
| `interfaces/hook.wit` | `astrid-bus:hook@1.0.0` |
| `interfaces/registry.wit` | `astrid-bus:registry@1.0.0` |
| `interfaces/agent.wit` | `astrid-bus:agent@1.0.0` |
| `interfaces/users.wit` | `astrid-bus:users@1.0.0` |
| `interfaces/approval.wit` | `astrid-bus:approval@1.0.0` |
| `interfaces/elicit.wit` | `astrid-bus:elicit@1.0.0` |
| `interfaces/client.wit` | `astrid-bus:client@1.0.0` |
| `interfaces/user.wit` | `astrid-bus:user@1.0.0` |
| `interfaces/system.wit` | `astrid-bus:system@1.0.0` |
| `interfaces/onboarding.wit` | `astrid-bus:onboarding@1.0.0` |

Notably, `astrid:approval@1.0.0` (host) and `astrid-bus:approval@1.0.0` (bus) both exist. The host interface is the in-capsule syscall that blocks until a user approves or denies. The bus interface carries the same flow as IPC events so uplinks can subscribe and surface the prompt. The namespace split prevents a naming collision and keeps the two concerns visible at the type level (`wit/host/approval@1.0.0.wit:7`).

## The Frozen-File Discipline

The wasmtime Component Model linker enforces structural typing on every `(package, version)` pair. Adding a field to a record or a function to an interface in a published WIT file breaks every capsule built against the old shape: their compiled imports no longer match what the kernel advertises. The fix is never to edit a published file in place.

Once a `host/<name>@X.Y.Z.wit` file lands on `main`, it is immutable forever. Evolution ships as a new file at a new version:

```
host/
  ipc@1.0.0.wit           # frozen
  ipc@1.1.0.wit           # frozen (additive change)
  ipc@2.0.0.wit           # current (breaking change)
```

To evolve a package:

1. Copy the latest frozen file: `cp host/ipc@1.0.0.wit host/ipc@1.1.0.wit`.
2. Bump the package declaration inside the new file: `package astrid:ipc@1.1.0;`.
3. Add your changes in the new file only. Leave the frozen file untouched.
4. The kernel registers both versions in its linker so old and new capsules coexist.

The `wit/README.md` is direct about the current state of enforcement:

> The rule is currently a documented convention rather than a CI gate. The automated frozen-file check was retired during pre-adoption iteration (no SDK or capsule is bound to `@1.0.0` yet, so in-place amendments don't break anyone). Once a real downstream consumer ships against a versioned file, re-enable the check.

The `wit/.github/workflows/lint.yml` CI currently runs `scripts/validate-wit.sh`, which parses every `host/*.wit` file with `wasm-tools component wit`. The `interfaces/` files are not validated there because `wasm-tools 1.x` cannot topo-sort cross-package `use` dependencies in a single pass; those files are validated by downstream SDK builds.

## The Three-Repo Flow

The `unicity-astrid/wit` repo is a git submodule in both the kernel (`core/`) and the Rust SDK (`sdk-rust/`). Each consumer points its submodule at a specific SHA. Updating the submodule pointer is the mechanism for pulling a contract change into a consumer. CI comparing submodule SHAs across consumers would catch silent drift; that check does not yet exist but the README documents the intent.

### Repo 1: `unicity-astrid/wit` (canonical source)

WIT files live at `host/` and `interfaces/`. No build artifacts. Changes here propagate to every consumer by submodule bump.

### Repo 2: `unicity-astrid/sdk-rust` (Rust SDK)

The `sdk-rust` repo submodules `unicity-astrid/wit` at `contracts/`:

```
sdk-rust/
  contracts/            # git submodule → unicity-astrid/wit
    host/               # *.wit files (host ABI)
    interfaces/         # *.wit files (bus contracts)
  astrid-sys/
    build.rs            # stages host/ → wit-staging/
    wit-staging/        # committed, ships with crate tarball
      root.wit
      deps/
        astrid-fs/fs@1.0.0.wit
        astrid-ipc/ipc@1.0.0.wit
        ...
    src/lib.rs          # wit_bindgen::generate! consumes wit-staging/
  astrid-sdk/
    wit/astrid-contracts.wit  # bundled interfaces/ (auto-generated)
  scripts/
    sync-contracts-wit.sh
```

**Host ABI path (`astrid-sys`):** `build.rs` in `astrid-sys` reads `contracts/host/*.wit`. If the submodule is checked out, it cleans `wit-staging/` and copies each `host/<pkg>@<ver>.wit` into `wit-staging/deps/astrid-<pkg>/<pkg>@<ver>.wit`. If the submodule is absent (published crate, fresh clone without `--init`), it skips staging and uses the committed `wit-staging/` that ships with the `.crate` tarball. The `src/lib.rs` then invokes `wit_bindgen::generate!` with an inline synthetic world:

```rust
wit_bindgen::generate!({
    inline: "
        package astrid-sdk:capsule;
        world capsule {
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
            include astrid:guest/interceptor@1.0.0;
            include astrid:guest/background@1.0.0;
            include astrid:guest/installable@1.0.0;
            include astrid:guest/upgradable@1.0.0;
        }
    ",
    path: "wit-staging",
    pub_export_macro: true,
    generate_all,
});
```

This produces typed Rust host-import functions under `astrid_sys::astrid::<domain>::host`, the `Guest` trait combining all four guest export worlds, and the `export!` macro. `astrid-sdk` then re-exports these under ergonomic `std`-shaped module names (`astrid_sdk::fs`, `astrid_sdk::ipc`, etc.), wrapping each host-function call in a Rust `Result` and converting the per-domain `error-code` variants into `SysError::HostError(String)` via `Debug` formatting (`sdk-rust/astrid-sdk/src/lib.rs:138`).

One side effect of the `wasm32-unknown-unknown` target is that `getrandom` has no platform backend. `astrid-sys/src/lib.rs` registers a custom backend that routes calls to `astrid:sys/host.random-bytes`, so `HashMap`, `uuid`, and any other crate that depends on `getrandom` work inside WASM without per-capsule wiring (`sdk-rust/astrid-sys/src/lib.rs:133`).

**Bus contracts path (`astrid-sdk/wit/astrid-contracts.wit`):** The `interfaces/` files are one-package-per-file in the canonical repo. The `astrid-sdk-macros` crate's `wit_events!` macro expects a single bundled file. `scripts/sync-contracts-wit.sh` transforms the canonical set by stripping each per-file `package` declaration and rewriting cross-package `use` references into same-package cross-interface references, then concatenating everything under a single `package astrid:contracts@1.0.0;` header. CI runs `sync-contracts-wit.sh --check` to fail if the bundled file drifts from the canonical source.

The `wit_events!` macro parses this bundled WIT using `wit-parser`, emits one `pub mod <interface> { ... }` per WIT interface, and derives `serde::Serialize` and `serde::Deserialize` on every generated struct. Capsule authors get compile-time-typed structs for every IPC payload:

```rust
use astrid_sdk::contracts::session::GetMessagesRequest;
use astrid_sdk::contracts::llm::GenerateRequest;
```

### Repo 3: `unicity-astrid/astrid` (kernel)

The kernel submodules `unicity-astrid/wit` at `core/wit/`. The `astrid-capsule` crate's `build.rs` runs the same staging logic as `astrid-sys`: it copies `wit/host/*.wit` into `crates/astrid-capsule/wit-staging/deps/astrid-<pkg>/`, with the same published-crate fallback to the committed copy (`core/crates/astrid-capsule/build.rs:60`).

The `crates/astrid-capsule/src/engine/wasm/bindings.rs` then invokes `wasmtime::component::bindgen!` with an inline synthetic `kernel` world:

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
    with: {
        "astrid:io/poll@1.0.0.pollable": wasmtime_wasi::p2::DynPollable,
        "astrid:io/error@1.0.0.error": wasmtime_wasi::p2::IoError,
        "astrid:io/streams@1.0.0.input-stream": wasmtime_wasi::p2::DynInputStream,
        "astrid:io/streams@1.0.0.output-stream": wasmtime_wasi::p2::DynOutputStream,
    },
    // subscription.recv, http-request, http-stream-start declared async
    // to avoid blocking tokio workers on the orchestration hot path.
});
```

The `with:` map reuses wasmtime-wasi storage types for the `astrid:io` resources. This is storage reuse only: every `Host` trait implementation for `astrid:io/poll`, `astrid:io/streams`, and related interfaces lives in Astrid's own `engine/wasm/host/io.rs`, adding audit, cancellation-token races, and per-principal quota accounting on every operation.

The kernel registers `Kernel::add_to_linker` for every host package. When a new frozen version ships (e.g. `host/ipc@1.1.0.wit`), the kernel adds a second call:

```
bindings::ipc_v1_0::add_to_linker(&mut linker, ...)?;
bindings::ipc_v1_1::add_to_linker(&mut linker, ...)?;
```

Old capsules (compiled against `ipc@1.0.0`) and new capsules (compiled against `ipc@1.1.0`) coexist in the same running daemon.

### Submodule topology summary

```
unicity-astrid/wit   ← canonical WIT source
    ↓ submodule        ↓ submodule
core/wit/          sdk-rust/contracts/
    ↓ build.rs         ↓ build.rs
wit-staging/       wit-staging/         sdk-rust/astrid-sdk/wit/
    ↓ bindgen!         ↓ wit_bindgen!      ↓ wit_events!
kernel Host impls   astrid-sys types     contracts structs
```

All three consumers use a committed `wit-staging/` that ships with each crate or binary, so `cargo install` and published-crate builds work without the submodule being checked out.

## IPC Topic Naming Convention

The `astrid-bus:*` interface names map directly to IPC topic prefixes. The convention is:

```
<domain>.v<major>.<operation>[.<sub-operation>]
```

The `v<major>` segment lets topic consumers and producers negotiate major revisions independently of the WIT package version. A few examples from the actual interface files:

| Interface | WIT record | Topic |
|-----------|-----------|-------|
| `llm` | `describe-request` | `llm.v1.request.describe` |
| `llm` | `generate-request` | `llm.v1.request.generate.<model>` |
| `session` | `get-messages-request` | `session.v1.request.get` |
| `session` | `append-request` | `session.v1.append` |
| `session` | `session-cleared` | `session.v1.clear` |
| `tool` | `describe-request` | `tool.v1.request.describe` |
| `tool` | `describe-response` | `tool.v1.response.describe.<correlation-id>` |
| `users` | `resolve-request` | `users.v1.resolve.request` |
| `users` | `resolve-response` | `users.v1.resolve.response` |
| `users` | `context-set-request` | `users.v1.context.set.request` |
| `registry` | `selection-required` | `registry.v1.selection.required` |
| `agent` | `response` | `agent.v1.response` |
| `agent` | `session-changed` | `agent.v1.session_changed` |
| `system` | `capsules-loaded` | `astrid.v1.capsules_loaded` |
| `system` | `watchdog-tick` | `astrid.v1.watchdog.tick` |

The topic strings are documented in the WIT file comments alongside each record. The kernel enforces topic syntax: segments are `[a-z0-9._-]+`, max 8 segments, max 256 bytes total. Wildcard subscriptions use a trailing `.*` (e.g. `llm.v1.stream.*`); mid-segment wildcards are rejected by `astrid:ipc/host.subscribe` (`wit/host/ipc@1.0.0.wit:156`).

Correlation IDs follow a consistent pattern: a requester publishes on the base request topic and subscribes on `<domain>.v1.response.<noun>.<correlation-id>`. The provider replies on that topic. The `session`, `tool`, `llm`, `registry`, and `users` interfaces all follow this shape. The correlation-id is opaque to the bus; each capsule generates its own (typically a UUID v4).

## What Capsules Declare in `Capsule.toml`

The two WIT namespaces are reflected in `Capsule.toml` as two separate import tables. The kernel uses the `[imports.astrid]` table to gate which host packages a capsule can call. The `[imports.astrid-bus]` table records which bus interfaces a capsule consumes, and `[exports.astrid-bus]` records which it provides. The kernel validates at boot that every required `astrid-bus` import has a matching export from another loaded capsule.

```toml
# Host ABI, kernel-mediated syscalls.
[imports.astrid]
fs = "1.0.0"
ipc = "1.0.0"
kv = "1.0.0"

# Bus interfaces this capsule subscribes to.
[imports.astrid-bus]
llm = "^1.0"
session = { version = "^1.0", optional = true }

# Bus interfaces this capsule provides.
[exports.astrid-bus]
session = "1.0.0"
```

A capsule's WASM binary lists its imports literally: every `astrid:*` import in the binary corresponds to a capability row the kernel checks at load time. On `wasm32-unknown-unknown` there are no implicit `wasi:*` imports, so the binary's WIT import list IS the capsule's capability list, which is why that target is canonical for new capsules.

## See also

- [The RFC Process](rfc-process.md)
- [ABI Evolution](../host-abi/abi-evolution.md)
- [The Syscall Surface](../host-abi/the-syscall-surface.md)
