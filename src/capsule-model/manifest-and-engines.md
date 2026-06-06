# The Capsule Manifest and Engines

Every capsule is defined by a single TOML file named `Capsule.toml`. The runtime reads this file before touching a single byte of WASM. It is the authoritative, declarative source of truth for identity, capabilities, IPC surface, environment variables, and OS integrations. This page covers the complete schema and then explains how the three execution engines, composed by `CompositeCapsule`, bring the manifest to life.

---

## `Capsule.toml` Schema

The Rust type that models the manifest is `CapsuleManifest` in `core/crates/astrid-capsule/src/manifest/mod.rs`. Every section below maps directly to a field on that struct.

### `[package]`

Identity and publication metadata. All fields except `name` and `version` are optional.

```toml
[package]
name = "astrid-capsule-http"
version = "0.1.0"
description = "HTTP fetch tool for Astrid agents"
authors = ["Joshua J. Bouw <dev@joshuajbouw.com>"]
astrid-version = ">=0.1.0"
license = "MIT OR Apache-2.0"
repository = "https://github.com/unicity-astrid/capsule-http"
keywords = ["http", "fetch"]
categories = ["networking"]
publish = true      # set false to block registry publication
```

The `astrid-version` field declares a semver requirement against the host runtime. `publish = false` prevents `astrid capsule pack` from uploading to any registry. `include` and `exclude` accept glob patterns that control what files are bundled by the packer. `metadata` accepts an arbitrary JSON table for tool-specific extensions (unused by the kernel).

A `CapsuleId` is derived at load time from `package.name`. The id must be non-empty and contain only lowercase ASCII alphanumeric characters and hyphens (`core/crates/astrid-capsule/src/capsule.rs:109-124`).

### `[[component]]`

Each `[[component]]` block names a WASM binary. A capsule may have more than one.

```toml
[[component]]
id = "http-tools"
file = "astrid_capsule_http.wasm"    # path relative to Capsule.toml
type = "executable"                  # "executable" (default) or "library"
hash = "sha256:abc123..."            # optional; checked against meta.json at load
```

When at least one `[[component]]` block exists, `CapsuleLoader` adds a `WasmEngine` to the composite (see `loader.rs:64-71`). The field is serialized as `file`. Per-component capability overrides are possible via an inline `capabilities` table on the block itself.

### `[imports]` and `[exports]`

These tables declare the WIT interface contract. Two TOML surface forms are accepted and normalized to the same nested representation at parse time.

**Flat (cargo-like) form, one colon-delimited key per interface:**

```toml
[imports]
"astrid:session" = "^1.0"
"astrid:kv"      = { version = "^1.0", optional = true }

[exports]
"astrid:context" = "1.0.0"
```

**Nested form:**

```toml
[imports.astrid]
session = "^1.0"
kv      = { version = "^1.0", optional = true }

[exports.astrid]
context = "1.0.0"
```

Both forms may be mixed within a single file. The deserializer at `manifest/mod.rs:222-257` handles them with a single `deserialize_dual_form_map` helper. Import values parse to `ImportDef { version: semver::VersionReq, optional: bool }`; export values parse to `ExportDef { version: semver::Version }`.

An `optional = true` import allows the capsule to boot even when no provider is loaded for that interface.

### `[publish]` and `[subscribe]`

These are the current, canonical way to declare a capsule's IPC surface. Each table key is an IPC topic name or wildcard pattern. Each value carries a typed WIT payload reference and optional source pinning.

**Short form:** a bare WIT reference string.

```toml
[publish]
"tool.v1.execute.*.result" = "@unicity-astrid/wit/types/tool-call-result"
```

**Long form:** an inline table.

```toml
[publish]
"tool.v1.execute.*.result"  = { wit = "@unicity-astrid/wit/types/tool-call-result" }
"llm.v1.request.generate.*" = { wit = "GenerateRequest", fanout = true }

[subscribe]
"tool.v1.execute.fetch_url" = { wit = "@unicity-astrid/wit/types/tool-call", handler = "tool_execute_fetch_url" }
```

The `wit` field accepts either:

- A bare local record name, resolved from the capsule's own `wit/` directory.
- An `@scope/repo/<iface>/<record>` reference, resolved through the registry (registry + lockfile work is behind the same RFC as the manifest format; the kernel does not enforce source pins today).
- The literal string `"opaque"`, which marks an entry whose payload is not type-checked, used by uplink or proxy capsules that forward raw bytes.

Exactly one of `version`, `tag`, `rev`, `branch`, `path` may be set on the long form. The deserializer rejects manifests that set more than one (`manifest/topics.rs:98-104`).

The `handler` field on a `[subscribe]` entry binds the topic to a `#[astrid::interceptor("...")]` WASM export, making the entry an interceptor binding. An optional `priority` (a `u32`, default `100`, lower fires first) orders it within the chain. Entries without `handler` grant ACL only; the guest still calls `ipc::subscribe()` to receive events.

The `fanout = true` flag on a `[publish]` entry is a documentation hint to tooling that the suffix segment names a recipient (for example `llm.v1.request.generate.*` per LLM provider). The kernel routes wildcard topics regardless of this flag.

**ACL semantics.** The kernel's IPC ACL for publish and subscribe is derived from these tables when they are non-empty. `CapsuleManifest::effective_ipc_publish_patterns()` returns the keys of `[publish]` if that table is present and non-empty, falling back to `capabilities.ipc_publish` otherwise. The same precedence applies to subscribe (`manifest/mod.rs:141-158`). The new format takes precedence so a capsule never double-declares.

#### Interceptor binding from subscribe

`CapsuleManifest::effective_interceptors()` (`manifest/mod.rs`) collects every `[subscribe]` entry that has a `handler` field into the runtime `Vec<InterceptorDef>`, carrying each entry's declared `priority`. A `[subscribe]` entry with no `handler` is ACL only and produces no interceptor binding.

### `[capabilities]`

Declares host resources the capsule may access. Every field defaults to fail-closed (empty or `false`). The kernel's `ManifestSecurityGate` enforces these at runtime.

```toml
[capabilities]
uplink              = false           # long-lived daemon mode (disables WASM timeout)
net                 = ["api.github.com", "*.example.com", "*"]
net_bind            = ["unix:*"]      # socket addresses the capsule may bind
net_connect         = ["db.internal:5432", "redis.internal:*"]
kv                  = []              # reserved; not currently enforced
fs_read             = ["cwd://", "home://", "/absolute/path"]
fs_write            = ["cwd://"]
host_process        = ["npx"]         # Airlock Override: escape hatch to host
ipc_publish         = ["registry.*"]  # legacy; superseded by [publish] when present
ipc_subscribe       = ["registry.*"]  # legacy; superseded by [subscribe] when present
identity            = ["resolve"]     # "resolve", "link", "admin"
allow_prompt_injection = false        # gate on system-prompt modification
```

**Path schemes in `fs_read` and `fs_write`.**

- `cwd://` resolves to the capsule's install directory at construction time.
- `home://` resolves against the invoking principal's home directory at check time. Per-principal isolation is preserved: only the active principal's subtree matches.
- `*` is a wildcard confined to the workspace root; it does not grant access to the entire filesystem.
- Literal absolute paths are matched with `Path::starts_with`, which enforces component boundaries (`/workspace` does not match `/workspace-evil`).
- Paths containing `..` components are always rejected before any match, preventing traversal attacks (`security/manifest_gate.rs:136-143`).

**`net_connect` patterns.** Each entry is `"host:port"` or `"host:*"`. The host segment is compared case-insensitively. DNS-style wildcards (`*.example.com`) are not supported. IP resolution and SSRF checks run after the manifest gate passes.

**`identity` hierarchy.** `admin` implies all operations. `link` implies `resolve` plus link/unlink/list. `resolve` is read-only lookup only. An empty list denies all identity operations.

**`allow_prompt_injection`.** When `false` (the default), hook responses from this capsule have `systemPrompt`, `prependSystemContext`, and `appendSystemContext` fields stripped by the prompt builder before they reach the LLM. Only `prependContext` (user-visible context) passes through. This is a hard security boundary: unprivileged capsules cannot inject arbitrary instructions into the system prompt.

**Operator-only fields.** `EnvDef::scope` is decorated `skip_deserializing`. A capsule manifest cannot set its own env scope. The kernel resolves scope from operator action at runtime, not from manifest declaration, preventing a malicious capsule from marking its credentials `Shared` and reading host-wide secrets (`manifest/mod.rs:444-456`).

### `[env]`

Declares environment variables the capsule requires. Values are elicited from the user during `astrid capsule install` and stored per-principal in the KV store (secrets go through `FileSecretStore` at `~/.astrid/secrets/`).

```toml
[env]
API_KEY  = { type = "secret", request = "Enter your API key", placeholder = "sk-..." }
REGION   = { type = "select", enum_values = ["us-east-1", "eu-west-1"], default = "us-east-1" }
TAGS     = { type = "array",  request = "Comma-separated tags" }
NAME     = { type = "text",   request = "Your name", default = "Agent" }
```

Accepted `type` values:

| Value | Behavior |
|-------|----------|
| `"secret"` | Masked prompt at install; stored in `FileSecretStore` (`~/.astrid/secrets/`). `enum_values` is ignored. |
| `"text"` | Plain text input; stored in env JSON. |
| `"select"` | Dropdown from `enum_values`; stored in env JSON. A single-choice enum auto-fills without prompting. |
| `"array"` | Comma-separated list; stored in env JSON. |

The `scope` field is operator-only (`skip_deserializing`). Lookup precedence is always per-agent first; `Shared` scope only changes the miss fallback.

`engine/mod.rs:147-233` shows the full resolution path: KV lookup, default fill, onboarding publication.

### `[[command]]`

Slash-command registrations.

```toml
[[command]]
name = "deploy"
description = "Deploy to production"
file = "commands/deploy.toml"    # optional; path to a declarative command TOML
```

### `[[mcp_server]]`

MCP server declarations. Only entries with `type = "stdio"` activate the `McpHostEngine`; this is the Airlock Override that breaks out of the WASM sandbox.

```toml
[[mcp_server]]
id          = "my-server"
type        = "stdio"
command     = "npx"              # must appear in capabilities.host_process
args        = ["-y", "@scope/package"]
description = "My MCP server"
```

### Other Sections

| Section | Key type | Purpose |
|---------|----------|---------|
| `[[skill]]` | array | Skills the capsule contributes to the operator's skill library. |
| `[[uplink]]` | array | Uplink declarations (platform, interaction profile). |
| `[[context_file]]` | array | Static context files injected into LLM context. |
| `[[topic]]` | array | Legacy topic API declarations (superseded by `[publish]`/`[subscribe]`). |
| `[[tool]]` | array | Tools surfaced to the LLM. `description_for_llm` is operator-reviewed at install time. |

---

## The Three Engines

The `CapsuleLoader` (`loader.rs`) reads a manifest and builds a `CompositeCapsule`. It inspects the manifest and adds zero or more `ExecutionEngine` implementations to the composite. Every capsule gets at least a `StaticEngine`; WASM and MCP engines are conditional.

### `WasmEngine`

Added when `manifest.components` is non-empty (`loader.rs:64-71`).

```
// loader.rs:64-71
if !manifest.components.is_empty() {
    composite.add_engine(Box::new(crate::engine::WasmEngine::new(
        manifest.clone(),
        capsule_dir.clone(),
        self.fuel_ledger.clone(),
        self.fuel_rate.clone(),
    )));
}
```

`WasmEngine` runs the WASM binary through the Wasmtime Component Model. It wires all `astrid:*` WIT host interfaces (fs, http, ipc, kv, net, identity, approval, elicitation, process, sys) through the `ManifestSecurityGate` before every call, so the sandbox is fail-closed: any syscall not declared in the manifest is denied without reaching the kernel event bus.

For non-run-loop capsules the engine maintains a pool of `(Store, Instance)` pairs (default size 16, or 1 for `host_process` capsules that hold live cross-invocation resources). This allows concurrent interceptor calls from different principals without serializing through a single store. Capsules with a `run()` WASM export get a single dedicated store owned by a background task.

WASM timeouts are enforced via the wasmtime epoch mechanism (tick interval 100ms, default wall-clock budget 5 minutes). Run-loop capsules whose owner principal holds an operator-granted capability (`CAP_RESOURCES_UNBOUNDED`, `CAP_NET_BIND`, or `CAP_UPLINK`) are exempted from the epoch interrupt. The manifest `capabilities.uplink` field does not grant exemption; exemption is purely capability-driven via the principal profile resolved through the permission system.

CPU fuel is charged to the invoking principal's `FuelLedger` after each call. The ledger is kernel-owned and shared across all capsules, so a principal's CPU is aggregated cross-capsule. A `FuelRateLimiter` enforces per-principal 1-second CPU rate limits.

### `McpHostEngine`

Added once per `[[mcp_server]]` entry where `type = "stdio"` (`loader.rs:74-85`). This is the Airlock Override: the only sanctioned path to run a host process from a capsule.

Security checks happen in two stages:

1. **Manifest gate.** Before spawning, the engine checks that the verbatim command string appears in `capabilities.host_process`. This check runs against the original declared string, before any path resolution, to prevent bypass via directory names that are substrings of allowed commands (`mcp.rs:61-71`).

2. **Fat-binary resolution.** If the command resolves to a directory inside the capsule directory, the engine appends the host's target triple (injected at build time by `env!("TARGET")`) to find the architecture-specific slice. Symlinks are verified not to escape the capsule boundary.

The engine connects to the spawned process through `astrid-mcp`'s `SecureMcpClient::connect_dynamic`. Interceptor hooks on MCP capsules are invoked by calling the `astrid_hook_intercept` MCP tool with the hook name and payload. MCP interceptors always return `Continue` (no wire format for short-circuit in MCP; this is documented as a future gap).

### `StaticEngine`

Always added, regardless of manifest content (`loader.rs:87-93`).

```
// loader.rs:86-93
composite.add_engine(Box::new(crate::engine::StaticEngine::new(
    manifest.clone(),
    capsule_dir.clone(),
)));
```

`StaticEngine::load` is currently a no-op stub. The design intent is to read `manifest.context_files`, `manifest.skills`, and static `manifest.commands` from disk and publish them to the OS event bus or LLM router. The `_manifest` and `_capsule_dir` fields are stored but unused at present. Static capsules that declare only context files or skills still load cleanly; their content is not yet injected automatically.

---

## `CompositeCapsule`

`CompositeCapsule` is the universal implementation of the `Capsule` trait (`capsule.rs:251-378`). It owns a `Vec<Box<dyn ExecutionEngine>>` and fans every lifecycle call across all engines.

- **`load`** iterates engines in order. If any engine fails, the capsule transitions to `CapsuleState::Failed` and returns immediately. The remaining engines are not loaded.
- **`unload`** iterates all engines on a best-effort basis. A failing engine does not prevent the rest from shutting down.
- **`wait_ready`** consumes a shared deadline across all engines. If the first engine exhausts the budget, the second engine receives zero remaining time and returns `Timeout` immediately. This is intentional: the deadline is global, not per-engine.
- **`invoke_interceptor`** tries each engine in turn. Engines that return `CapsuleError::NotSupported` are skipped; the first engine that returns `Ok` or a non-`NotSupported` error wins.
- **`check_health`** returns the first `CapsuleState::Failed` it finds across all engines, or the capsule's own `state` if all engines are healthy.

The three lifecycle states that matter to the health monitor are `Unloaded`, `Ready`, and `Failed(String)`. `Loading` and `Unloading` are transient.

---

## The Two Manifest Styles

### New: `[publish]` / `[subscribe]` (current)

Declared as top-level TOML tables where each key is an IPC topic pattern and each value carries a typed WIT payload reference. A `handler` on a `[subscribe]` entry (with an optional `priority`) declares an interceptor binding. These tables simultaneously serve as the IPC ACL when non-empty, superseding `capabilities.ipc_publish` and `capabilities.ipc_subscribe`.

This is the format all new capsules must use. `astrid-capsule-http`, `astrid-capsule-fs`, `astrid-capsule-context-engine`, and `astrid-capsule-memory` all use it.

### Legacy ACL: `capabilities.ipc_publish` / `capabilities.ipc_subscribe`

IPC ACL declared in the `[capabilities]` block as plain string arrays rather than `[publish]` / `[subscribe]` tables. `astrid-capsule-cli` is an example: it uses `capabilities.ipc_publish` and `capabilities.ipc_subscribe` directly because it is an uplink proxy that routes opaque bytes and binds no handlers.

`effective_ipc_publish_patterns()` and `effective_ipc_subscribe_patterns()` resolve the ACL: the `[publish]` / `[subscribe]` tables take precedence when present, falling back to the `capabilities.ipc_*` arrays. A capsule using the arrays can migrate to the tables one topic at a time.

---

## Complete Example

The `astrid-capsule-http` manifest is a minimal, real-world reference for a tool capsule using the current format:

```toml
# capsules/astrid-capsule-http/Capsule.toml

[package]
name = "astrid-capsule-http"
version = "0.1.0"
description = "HTTP fetch tool for Astrid agents"
authors = ["Joshua J. Bouw <dev@joshuajbouw.com>", "Unicity Labs <info@unicity-labs.com>"]
astrid-version = ">=0.1.0"

[[component]]
id = "http-tools"
file = "astrid_capsule_http.wasm"
type = "executable"

[capabilities]
net = ["*"]

[publish]
"tool.v1.execute.*.result"    = { wit = "@unicity-astrid/wit/types/tool-call-result" }
"tool.v1.response.describe.*" = { wit = "@unicity-astrid/wit/tool/describe-response" }

[subscribe]
"tool.v1.execute.fetch_url"  = { wit = "@unicity-astrid/wit/types/tool-call", handler = "tool_execute_fetch_url" }
"tool.v1.request.describe"   = { wit = "@unicity-astrid/wit/tool/describe-request", handler = "tool_describe" }
```

The loader creates a `CompositeCapsule` with a `WasmEngine` (because `[[component]]` is present) and a `StaticEngine` (always). The `WasmEngine` enforces `net = ["*"]` via `ManifestSecurityGate::check_http_request`. The `[publish]` and `[subscribe]` tables double as the IPC ACL and the interceptor handler registry.

## See also

- [Imports, Exports, and Dependency Resolution](imports-exports-resolution.md)
- [Capsule Lifecycle](lifecycle.md)
- [Capability Gating](../host-abi/capability-gating.md)
