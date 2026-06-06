# The Host ABI: The Syscall Surface

The host ABI is the only legal path from a capsule to the host OS. Every file
read, network connection, log line, and random byte flows through it. The
entire surface is typed in WIT, versioned, capability-gated, and
principal-scoped. There are zero `wasi:*` imports anywhere in the capsule
toolchain.

## WIT as the Contract Language

Every interface the kernel exposes to capsules is declared in a WIT file under
`sdk-rust/contracts/host/` (the `unicity-astrid/wit` submodule). The files are
organized as one package per domain:

| WIT package | Domain |
|---|---|
| `astrid:io@1.0.0` | Foundation I/O: `error`, `poll`, `streams` |
| `astrid:fs@1.0.0` | Filesystem (VFS-scheme paths) |
| `astrid:ipc@1.0.0` | Event bus pub/sub |
| `astrid:kv@1.0.0` | Persistent key-value store |
| `astrid:net@1.0.0` | Unix sockets, TCP, UDP, DNS |
| `astrid:http@1.0.0` | Outbound HTTP with SSRF protection |
| `astrid:sys@1.0.0` | Logging, config, clocks, entropy, capabilities |
| `astrid:process@1.0.0` | Host process spawning (desktop only) |
| `astrid:uplink@1.0.0` | Platform bridge registration |
| `astrid:elicit@1.0.0` | Interactive install/upgrade prompts |
| `astrid:approval@1.0.0` | Human-in-the-loop approval |
| `astrid:identity@1.0.0` | External platform identity resolution |
| `astrid:guest@1.0.0` | Guest export worlds (kernel calls into capsule) |

Every file carries the annotation `"Frozen per the ABI evolution discipline
(RFC: host_abi). Shape changes ship as a new file at a new version path; never
edit this file."` That is the ABI stability rule: a landed interface is
immutable. New behavior means a new file at a new version, and the wasmtime
linker enforces exact `(package, version)` matches at load time, so old and new
capsules coexist without a flag day.

## The Byte Boundary

Below the WIT types lies the WebAssembly Component Model binary encoding.
wasmtime's `bindgen!` macro (kernel side) and `wit_bindgen::generate!` (guest
side) each emit a Rust module from the same WIT files. At link time the
Component Model linker matches every `import` the guest declares against a
registered host implementation. The type system enforces the match: a mistyped
argument is a compile-time error, not a runtime panic.

Resource types cross the boundary as integer handles. The host maintains a
resource table per store; the guest holds typed `Resource<T>` wrappers. When
the guest drops a resource handle, the component-model runtime invokes the
host's destructor, releasing the underlying OS object (file descriptor, TCP
connection, process handle). Capsule code never calls `close` or `unsubscribe`
explicitly.

The `with:` block in `core/crates/astrid-capsule/src/engine/wasm/bindings.rs`
maps the four foundation resource types to their wasmtime-wasi storage types:

```rust
// core/crates/astrid-capsule/src/engine/wasm/bindings.rs
with: {
    "astrid:io/poll@1.0.0.pollable":      wasmtime_wasi::p2::DynPollable,
    "astrid:io/error@1.0.0.error":        wasmtime_wasi::p2::IoError,
    "astrid:io/streams@1.0.0.input-stream":  wasmtime_wasi::p2::DynInputStream,
    "astrid:io/streams@1.0.0.output-stream": wasmtime_wasi::p2::DynOutputStream,
},
```

This reuses wasmtime-wasi's existing storage types (which are `Future`-based
wrappers) without importing any wasi `Host` trait implementations. Every
`poll`, `block`, `read`, `write`, and `splice` is implemented by Astrid code
in `engine/wasm/host/io.rs` with audit recording, principal scoping, and
cancellation token wiring. The storage type is borrowed; the behavior is
entirely Astrid's.

## Zero WASI Imports

Astrid capsules target `wasm32-unknown-unknown`. That target has no WASI
runtime and no WASI-specific imports. The canonical capsule build configuration
is one line in `.cargo/config.toml`:

```toml
# capsules/astrid-capsule-cli/.cargo/config.toml
[build]
target = "wasm32-unknown-unknown"

[target.wasm32-unknown-unknown]
rustflags = ["--cfg=getrandom_backend=\"custom\""]
```

The kernel's linker is registered with only `astrid:*` interfaces. A capsule
that somehow carries a `wasi:*` import fails instantiation at load time with
"interface not found." That is the intended posture. The comment in
`configure_kernel_linker` states it plainly:

```rust
// core/crates/astrid-capsule/src/engine/wasm/mod.rs
/// Zero `wasi:*` registration. The Astrid-canonical guest target is
/// `wasm32-unknown-unknown`, capsules produce wasm with zero `wasi:*`
/// imports, every host call going through audited `astrid:*` interfaces.
/// A capsule that somehow ships with a `wasi:*` import ... fails to
/// instantiate at load time with a clear "interface not found" error, 
/// that is the intended posture, not a bug to paper over.
pub fn configure_kernel_linker(
    linker: &mut wasmtime::component::Linker<HostState>,
) -> wasmtime::Result<()> {
    bindings::Kernel::add_to_linker::<HostState, wasmtime::component::HasSelf<HostState>>(
        linker,
        |state| state,
    )
}
```

The consequence for the audit trail is direct: because the WIT imports list IS
the complete set of host calls a capsule can make, `astrid.audit.*` records
every kernel interaction without instrumentation gaps. There is no WASI carve-
out for "low-level I/O" to exempt from policy.

`wasm32-unknown-unknown` is the only capsule build target.

## Per-Export Guest Worlds

The `astrid:guest@1.0.0` package defines four worlds, one per lifecycle export:

```wit
// core/crates/astrid-capsule/wit-staging/deps/astrid-guest/guest@1.0.0.wit

world interceptor {
    use lifecycle.{capsule-result};
    export astrid-hook-trigger: func(action: string, payload: list<u8>) -> capsule-result;
}

world background {
    export run: func();
}

world installable {
    export astrid-install: func();
}

world upgradable {
    export astrid-upgrade: func();
}
```

The split is deliberate. In the Component Model, every export declared in a
world must appear in the compiled binary. Merging all four into one world would
force every capsule to stub every export it does not implement, and the kernel
would have to parse the wasm binary to distinguish real implementations from
toolchain stubs. Per-export worlds put the declaration where the implementation
is: a capsule that only handles interceptor traffic includes only
`astrid:guest/interceptor@1.0.0` and the binary is clean.

The kernel detects the presence of a `run` export by scanning the wasm binary
at load time (`wasm_exports_contain_run` in `engine/wasm/mod.rs`) before
instantiation. Run-loop capsules get one dedicated `Store`; interceptor-only
capsules get a pool of stores for concurrent invocations.

A typical interceptor capsule world looks like:

```wit
world my-capsule {
    include astrid:guest/interceptor@1.0.0;
    import astrid:ipc/host@1.0.0;
    import astrid:sys/host@1.0.0;
}
```

A capsule that also runs a background loop and accepts installation adds the
remaining includes:

```wit
world my-capsule {
    include astrid:guest/interceptor@1.0.0;
    include astrid:guest/background@1.0.0;
    include astrid:guest/installable@1.0.0;
    import astrid:ipc/host@1.0.0;
    import astrid:uplink/host@1.0.0;
}
```

## The Synthetic SDK Capsule World

`astrid-sys` is the low-level guest binding crate. It imports every host
package in a single synthetic world called `capsule`:

```rust
// sdk-rust/astrid-sys/src/lib.rs
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
    generate_unused_types: true,
    generate_all,
});
```

This is not the world a final capsule targets. It is a generation-time union
that produces typed Rust bindings for every possible host call and guest export
in one `pub use generated::*;` statement. Capsule authors use `astrid-sdk` (the
ergonomic wrapper built on top of `astrid-sys`) rather than this crate
directly. The `#[capsule]` proc-macro from `astrid-sdk-macros` generates the
`impl Guest` and `export!()` call automatically.

The `build.rs` for `astrid-sys` handles the WIT staging. When the
`unicity-astrid/wit` submodule is present, it cleans and restages
`wit-staging/deps/astrid-<pkg>/` from `contracts/host/`. When the submodule is
absent (published crate, fresh clone before `git submodule update --init`), it
skips staging and the committed `wit-staging/` ships with the crate. Either
path produces the same layout that `wit_bindgen::generate!` reads.

The reason `additional_derives` is absent from the `generate!` call is also
documented in the source. Pre-v1 the crate blanket-derived `serde::Serialize /
Deserialize` on every generated type. With resource types, that is unsound:
resource handles own kernel-side state via `Drop` and cannot be serialized.
The `astrid-sdk` wrappers convert records to serde-friendly shapes at the
boundary; raw WIT types stay non-serializable.

## The Astrid IO Foundation

`astrid:io@1.0.0` is not a re-export of `wasi:io`. It is an Astrid-owned
reimplementation with the same shape (error / poll / streams) and a different
contract:

- `pollable.block()` and `poll.poll(...)` race against the calling capsule's
  cancellation token. On capsule unload, blocking calls return `cancelled`
  immediately rather than stranding host tasks.
- Every read, write, skip, and splice on a stream is audited per-principal,
  with bytes transferred and elapsed time.
- Pollable and stream handles are bounded by the per-principal quota profile.
  Exceeding the quota returns a typed error from the host function that
  allocates the handle, not a runtime trap.
- Pollables created in one capsule's store cannot be passed to another capsule.
  The wasmtime resource-table boundary enforces isolation.

The per-call cap on `poll` is 256 pollables. That number is sized so a capsule
at its full IPC subscription quota (128 subscriptions) plus all its TCP, UDP,
HTTP, and process stream pollables can wait on them all in a single call.

The `streams` interface provides the `splice` function as the primary
throughput primitive for proxy and forwarder capsules. `splice` moves bytes
between an `input-stream` and an `output-stream` host-side without crossing
the WASM boundary per byte. A capsule that forwards an HTTP response body into
a TCP connection calls `output_stream.splice(http_stream.body_stream(), len)`
and the kernel handles the read-then-write loop.

## The getrandom Custom Backend

`wasm32-unknown-unknown` has no platform RNG. The `getrandom` crate, pulled in
transitively through `uuid` and `astrid-types`, has no backend for that target
by default. Without a shim, `HashMap` construction panics on the first hash
seed request.

`astrid-sys` provides the shim as a single `#[unsafe(no_mangle)]` function
that getrandom 0.4's custom-backend protocol expects:

```rust
// sdk-rust/astrid-sys/src/lib.rs

#[cfg(all(target_arch = "wasm32", getrandom_backend = "custom"))]
#[unsafe(no_mangle)]
unsafe extern "Rust" fn __getrandom_v03_custom(
    dest: *mut u8,
    len: usize,
) -> Result<(), getrandom::Error> {
    const CHUNK: usize = 4096;
    let mut written = 0usize;
    while written < len {
        let want = core::cmp::min(CHUNK, len - written);
        let chunk = generated::astrid::sys::host::random_bytes(want as u64)
            .map_err(|_| getrandom::Error::new_custom(1))?;
        if chunk.is_empty() {
            return Err(getrandom::Error::new_custom(2));
        }
        let take = core::cmp::min(chunk.len(), want);
        unsafe {
            core::ptr::copy_nonoverlapping(chunk.as_ptr(), dest.add(written), take);
        }
        written += take;
    }
    Ok(())
}
```

The backend is activated by the `--cfg=getrandom_backend="custom"` rustflag
that every capsule's `.cargo/config.toml` sets for the `wasm32-unknown-unknown`
target. On non-wasm32 builds (host tooling, proc-macros, tests on the developer
machine) the `#[cfg]` guard omits the symbol entirely, and the platform's
default RNG is used.

The underlying host function is `astrid:sys/host.random-bytes`. The WIT
contract caps each call at 4096 bytes; the shim loops in `CHUNK`-sized
increments to satisfy arbitrarily large requests. `random-bytes` is one of the
few host functions that is intentionally not audited. It is read-only with no
side effects, called at high frequency from standard library code, and
recording every call would produce noise rather than useful signal.

```wit
// core/crates/astrid-capsule/wit-staging/deps/astrid-sys/sys@1.0.0.wit

/// Fill the caller's requested length with cryptographically secure
/// random bytes from the host's OS-level CSPRNG.
///
/// `length` is capped at 4096 bytes per call. Larger requests return
/// `too-large`.
/// Audit: not recorded (read-only, no side effects).
random-bytes: func(length: u64) -> result<list<u8>, error-code>;
```

Defining the shim in `astrid-sys` rather than in each capsule keeps the
routing centralized. Every capsule that depends on `astrid-sdk` gets a working
RNG with zero per-capsule wiring.

## Async Host Functions

Most host functions are synchronous at the WIT level and execute quickly on the
host side. Two domains are exceptions: `astrid:ipc/host`'s
`subscription.recv` blocks until a message arrives, and three `astrid:http/host`
functions (`http-request`, `http-stream-start`, `[method]http-stream.read-chunk`)
wait on network I/O.

The kernel's `bindings.rs` marks exactly these functions `async`:

```rust
// core/crates/astrid-capsule/src/engine/wasm/bindings.rs
imports: {
    "astrid:io/streams": trappable,
    "astrid:ipc/host.[method]subscription.recv": async,
    "astrid:http/host.http-request": async,
    "astrid:http/host.http-stream-start": async,
    "astrid:http/host.[method]http-stream.read-chunk": async,
},
```

With the Component Model's async support enabled, a guest call to one of these
functions `.await`s the result on the host side instead of pinning a tokio
worker for the duration of the call via `block_in_place`. The remaining host
functions (publish, subscribe, kv, sys) are off the orchestration hot path and
remain synchronous.

## The `astrid:sys` Interface

`astrid:sys@1.0.0` covers the runtime utilities that do not belong to a
specific I/O domain:

- `get-config` reads a value from the capsule's `[config]` manifest section.
  Secret-typed keys route through the SecretStore instead of the manifest.
- `get-caller` returns the acting principal, originating capsule UUID, and
  message timestamp for the current invocation.
- `log` emits a structured log attributed to the calling capsule, written to
  the principal's daily-rotated log directory.
- `signal-ready` notifies the kernel that a run-loop capsule has set up its
  subscriptions and is ready to receive messages.
- `clock-ms` and `clock-monotonic-ns` return wall-clock and monotonic time.
- `sleep-ns` blocks for a duration up to 60 seconds per call, returning
  `cancelled` if the capsule is unloading during the sleep.
- `random-bytes` fills a buffer from the host CSPRNG (see above).
- `check-capsule-capability` queries the capability registry for a named
  capability on a given capsule UUID. Fail-closed: returns `allowed: false`
  for unknown UUIDs and returns the typed error `registry-unavailable` when
  the registry itself cannot be consulted.

The `error-code` variant on `sys` is worth reading carefully:

```wit
variant error-code {
    capability-denied,
    config-key-reserved,
    too-large,
    registry-unavailable,  // fail-closed sentinel
    cancelled,
    unknown(string),
}
```

`registry-unavailable` is a distinct variant, not collapsed into `unknown`,
because downstream callers must be able to distinguish "the capability does not
exist" from "the registry could not be reached." A capsule that implements
conditional behavior based on another capsule's capabilities must treat
`registry-unavailable` as a denial, not as approval.

## Capability Gating Per Call

Every host function that touches a resource outside the capsule's own memory
is gated against the manifest-declared capabilities in `Capsule.toml
[capabilities]`. The error variant `capability-denied` is present on every
domain's `error-code` type. The kernel checks capabilities on each call
rather than at load time, so a capability revoked mid-session is effective on
the next call.

The IPC interface distinguishes between `publish` (principal attributed as
`verified` from the invocation context) and `publish-as` (principal claimed by
an uplink, attributed as `claimed`). Capsules receiving messages MUST check the
`principal-attribution` variant on sensitive actions. A `claimed` principal is
uplink-asserted and kernel-unverified:

```wit
// astrid:ipc@1.0.0
variant principal-attribution {
    verified(string),   // kernel-checked, safe for capability decisions
    claimed(string),    // uplink-asserted, treat as caller input
    system,
}
```

This distinction appears on every `ipc-message` in a received envelope. It is
not a session-level property; multi-message batches from `subscription.recv`
may contain both `verified` and `claimed` messages, and each must be
inspected independently.

## Error Type Design

Each domain defines its own typed `error-code` variant. Common patterns across
all of them:

- `capability-denied` is always a distinct arm, never a string in `unknown`.
  A capsule catching errors can branch on it without string matching.
- `unknown(string)` carries host detail for cases the WIT contract did not
  anticipate. The content is explicitly best-effort and not part of the
  contract. Error strings from `astrid:fs` never contain host real-paths,
  IP addresses, UUIDs, or capability names (documented in the WIT comment).
- Resource-specific errors like `boundary-escape` (fs), `airlock-rejected`
  (net/http), and `cas-mismatch` (kv) are first-class arms so callers can
  handle them without parsing.

The `astrid:io/streams` error type follows the WASI shape exactly so SDK
authors can reason uniformly:

```wit
variant stream-error {
    last-operation-failed(error),  // downcastable to domain-specific code
    closed,
}
```

The `error` resource in `last-operation-failed` is downcastable via domain-
specific functions. For example, a TCP read failure surfaced as a stream error
can be downcast to `astrid:net/host.error-code` if the capsule needs to
distinguish `connection-reset` from `timeout`.

## ABI Stability and Multi-Version Coexistence

Every WIT file is pinned at `@1.0.0`. When a new version ships it is a new
file at a new path. Both versions are registered independently in the kernel
linker:

```rust
// from bindings.rs comment
// When a new frozen version ships (e.g. `host/ipc@1.1.0.wit`), add it
// here as an additional import AND register a second `add_to_linker`
// call, the wasmtime Component Model linker enforces exact
// `(package, version)` matches, so multiple versions must be registered
// explicitly to allow old and new capsules to coexist.
```

On the guest side, the same rule applies: `astrid-sys/src/lib.rs` adds the
new version as an additional `import` in the inline world. Capsules pinned at
the older version resolve their old interface unchanged; capsules built against
the newer version resolve the new one. No capsule needs to be rebuilt when a
new version of an interface ships.

This means the version in a capsule's compiled binary is the ABI it was built
against, not the version the currently running kernel prefers. The kernel must
register every version it wants to support. A capsule importing a version the
kernel has not registered fails to load with a clear linker error.

## See also

- [Capability Gating](capability-gating.md)
- [ABI Evolution](abi-evolution.md)
- [The Capsule Manifest and Engines](../capsule-model/manifest-and-engines.md)
