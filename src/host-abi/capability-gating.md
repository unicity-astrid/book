# Capability Gating

Every resource a WASM capsule can touch -- network hosts, filesystem paths, host processes, IPC topics, identity operations -- is gated behind an explicit declaration in `Capsule.toml`. If a field is absent, the default is an empty list or `false`. The kernel treats an empty list as a deny-all allowlist, not an unconfigured default that might fall through. This is the fail-closed property, and it applies uniformly across every capability type.

This page follows the request path from a `[capabilities]` declaration through the `ManifestSecurityGate` to the host function check.

## The `[capabilities]` block

`CapabilitiesDef` (`core/crates/astrid-capsule/src/manifest/capabilities.rs`) is the Rust struct that backs the `[capabilities]` table in `Capsule.toml`. Every field defaults to an empty `Vec` or `false`:

```toml
[capabilities]
net           = ["api.github.com"]
fs_read       = ["cwd://src", "home://.config/myapp"]
fs_write      = ["cwd://out"]
host_process  = ["git"]
net_bind      = ["unix:///tmp/myapp.sock"]
net_connect   = ["db.internal:5432", "cache.internal:*"]
ipc_publish   = ["myapp.v1.*"]
ipc_subscribe = ["myapp.v1.*", "llm.v1.response"]
identity      = ["resolve"]
allow_prompt_injection = false
```

The fields and their semantics:

| Field | Type | Default | Purpose |
|---|---|---|---|
| `net` | `Vec<String>` | `[]` | Outbound HTTP hostname allowlist |
| `fs_read` | `Vec<String>` | `[]` | VFS read path allowlist (scheme-aware) |
| `fs_write` | `Vec<String>` | `[]` | VFS write path allowlist (scheme-aware) |
| `host_process` | `Vec<String>` | `[]` | Host process command allowlist |
| `net_bind` | `Vec<String>` | `[]` | Unix/TCP socket bind capability |
| `net_connect` | `Vec<String>` | `[]` | Outbound TCP `host:port` allowlist |
| `ipc_publish` | `Vec<String>` | `[]` | IPC publish topic patterns |
| `ipc_subscribe` | `Vec<String>` | `[]` | IPC subscribe topic patterns |
| `identity` | `Vec<String>` | `[]` | Identity operations (`resolve`, `link`, `admin`) |
| `allow_prompt_injection` | `bool` | `false` | Allow modifying the LLM system prompt via hooks |
| `uplink` | `bool` | `false` | Disable WASM execution timeout (daemon capsules) |
| `kv` | `Vec<String>` | `[]` | Declared for future cross-capsule KV; not enforced today |

The `kv` field is present for declaration purposes and is not enforced by a security gate at runtime. KV access is already scoped per-capsule by the store layer.

## The `ManifestSecurityGate`

The production implementation is `ManifestSecurityGate` (`core/crates/astrid-capsule/src/security/manifest_gate.rs`). It implements the `CapsuleSecurityGate` trait, which defines one async method per capability class:

```rust
#[async_trait]
pub trait CapsuleSecurityGate: Send + Sync {
    async fn check_http_request(&self, capsule_id: &str, method: &str, url: &str) -> Result<(), String>;
    async fn check_file_read(&self, capsule_id: &str, path: &str, principal_home: Option<&Path>) -> Result<(), String>;
    async fn check_file_write(&self, capsule_id: &str, path: &str, principal_home: Option<&Path>) -> Result<(), String>;
    async fn check_host_process(&self, capsule_id: &str, command: &str) -> Result<(), String>;
    async fn check_net_bind(&self, capsule_id: &str) -> Result<(), String>;
    async fn check_net_connect(&self, capsule_id: &str, host: &str, port: u16) -> Result<(), String>;
    async fn check_identity(&self, capsule_id: &str, operation: IdentityOperation) -> Result<(), String>;
    // default: permissive (backward compat, guarded separately on HostState)
    async fn check_uplink_register(&self, capsule_id: &str, uplink_name: &str, platform: &str) -> Result<(), String>;
}
```

The `check_net_bind` and `check_net_connect` trait methods have fail-closed defaults: if an implementor does not override them, they deny. `check_uplink_register` has a permissive default because the `has_uplink_capability` flag on `HostState` already gates access, and this method adds an optional operator-layer policy on top.

`ManifestSecurityGate` is constructed once at capsule load time with the parsed manifest, the workspace root, and an optional home root:

```rust
impl ManifestSecurityGate {
    pub(crate) fn new(
        manifest: CapsuleManifest,
        workspace_root: PathBuf,
        home_root: Option<PathBuf>,
    ) -> Self { ... }
}
```

The constructor calls `canonicalize()` on both roots up front so that all subsequent path checks use resolved paths. This eliminates symlink games from the comparison surface.

## Scheme prefixes for filesystem paths

Filesystem entries in `fs_read` and `fs_write` support three prefix forms, resolved during `ManifestSecurityGate::new` by `partition_schemes`:

### `cwd://` -- workspace-relative paths

`cwd://src` is resolved to the canonicalized workspace root joined with `src`. The result is stored in `resolved_static_read` or `resolved_static_write` and used directly at check time via `Path::starts_with`.

```toml
fs_read = ["cwd://src", "cwd://tests"]
```

Resolves to something like `/home/user/project/src` and `/home/user/project/tests`. A read of `/home/user/project/src/main.rs` passes; a read of `/home/user/project-evil/src/main.rs` does not, because `Path::starts_with` matches at component boundaries, not string prefixes.

### `home://` -- principal-relative paths

`home://` entries are not resolved at construction time. The suffix after `home://` is stored in `home_suffixes_read` or `home_suffixes_write`. At each check, it is joined against the effective principal's home root -- either the `principal_home` argument passed by the host function, or the construction-time `default_home_root` fallback.

```toml
fs_read = ["home://.config/myapp", "home://notes"]
```

When a different principal invokes the capsule, the interceptor machinery sets `invocation_home` on `HostState`, which is then passed as `principal_home` to `check_file_read` / `check_file_write`. This means `home://` entries are per-invocation-principal, not fixed to the capsule's load-time identity. A capsule with `home://` access can read Alice's `~/.config/myapp` when Alice invokes it, and Bob's when Bob invokes it -- but never the other's, because `principal_home` is controlled by the kernel, not the guest.

If neither a `principal_home` nor a `default_home_root` is available, `home://` entries match nothing.

### `*` -- wildcard confined to the workspace root

A bare `*` in the allowlist grants access to any path, but only under the canonical workspace root. The check is:

```rust
if p == "*" {
    path_obj.starts_with(&self.workspace_root_path)
} else {
    path_obj.starts_with(p)
}
```

A wildcard does not grant access to the entire filesystem. `/etc/passwd`, `~/.astrid/keys/user.key`, and any path outside the workspace root are denied even when `fs_read = ["*"]` is declared.

### Literal paths

Any entry that is not `*`, `cwd://...`, or `home://...` is treated as a literal prefix. `Path::starts_with` provides component-boundary matching so `/workspace/src` does not match `/workspace/src-evil`.

## Path-traversal rejection

Before any pattern matching occurs, `check_fs_permission` inspects the target path for `..` components:

```rust
if path_obj.components().any(|c| matches!(c, Component::ParentDir)) {
    return false;
}
```

This rejects inputs like `/workspace/src/../../etc/passwd` before they reach `starts_with`. Without this check, a path beginning with the allowed prefix but climbing out via `..` components would pass the component-boundary check and escape the declared scope.

The rejection fires before both static pattern matching and home-suffix matching, so it covers all entry types uniformly.

## Capability type walkthroughs

### Outbound HTTP (`net`)

The `net` field is a list of DNS hostnames. The check uses the URL's `host_str()` after `reqwest::Url::parse`:

```rust
self.manifest.capabilities.net.iter().any(|d| {
    d == "*" || host_str == d || host_str.ends_with(&format!(".{d}"))
})
```

An entry of `"api.github.com"` allows requests to `api.github.com` and any subdomain (e.g. `v3.api.github.com`), but not to `github.com` itself. The `ends_with(&format!(".{d}"))` pattern ensures the dot separator is present, so a declared host of `github.com` does not accidentally match `evil-github.com`.

After the gate passes, the HTTP host implementation builds a `reqwest::Client` with a custom `SafeDnsResolver` (`core/crates/astrid-capsule/src/engine/wasm/host/http.rs`) that blocks DNS resolution to loopback, private RFC 1918, link-local, CGNAT (100.64/10), and IPv6 ULA/link-local ranges. IPv4-mapped and IPv4-compatible IPv6 addresses are normalized before the check so they cannot be used to bypass it.

```rust
// After gate passes, SSRF airlock fires on every HTTP request:
let client = reqwest::Client::builder()
    .dns_resolver(Arc::new(SafeDnsResolver))
    .build()?;
```

There is no way to disable this airlock per-capsule. The bypass environment variables (`ASTRID_TEST_ALLOW_LOCAL_IP`, `ASTRID_ALLOW_LOCAL_IPS`) apply globally to every loaded capsule and are intended for integration test environments only. Setting either in production makes every capsule's HTTP surface reachable to internal network addresses.

**Example.** A capsule that calls the GitHub API:

```toml
[capabilities]
net = ["api.github.com"]
```

A request to `https://api.github.com/repos/...` passes. A request to `https://evil.com/hook` returns `ErrorCode::CapabilityDenied` from `check_http_security`. A request to `https://api.github.com@127.0.0.1/admin` is denied by the manifest gate itself -- `Url::parse` extracts `127.0.0.1` as the host (the `api.github.com` portion is the userinfo/username, not the host), which is not in the allowlist.

### Filesystem reads and writes (`fs_read`, `fs_write`)

The host function `gate_read` and `gate_write` helpers (`core/crates/astrid-capsule/src/engine/wasm/host/fs/mod.rs`) call `check_file_read` / `check_file_write` on the resolved physical path, then forward to the VFS:

```rust
fn gate_read(state: &HostState, physical: &Path) -> Result<(), ErrorCode> {
    if let Some(gate) = state.security.clone() {
        let check = util::bounded_block_on(&state.runtime_handle, &state.host_semaphore, async move {
            gate.check_file_read(&capsule_id, &p, home.as_deref()).await
        });
        if check.is_err() {
            return Err(ErrorCode::CapabilityDenied);
        }
    }
    Ok(())
}
```

Note: if `state.security` is `None`, the gate is absent and the call proceeds. In the production daemon path `security` is always populated; `None` arises only in unit tests using bare `HostState` construction.

**Example.** A skills capsule that needs to read skills from the user's Astrid home and write output into the workspace:

```toml
[capabilities]
fs_read  = ["home://.astrid/skills"]
fs_write = ["cwd://out"]
```

A read of `/home/alice/.astrid/home/alice/.astrid/skills/my-skill/SKILL.md` passes when Alice is the invoking principal. The same path under Bob's home is denied. A write to `/workspace/out/result.json` passes. A write to `/etc/cron.d/backdoor` is denied by both the gate and the wildcard confinement (the gate has no `*` entry and the literal `cwd://out` prefix does not match).

### Host process execution (`host_process`)

The `host_process` field is a list of command strings. The gate checks the full command (including the executable name) for an exact match or a prefix match followed by a space:

```rust
self.manifest.capabilities.host_process.iter().any(|cmd| {
    command == cmd || command.starts_with(&format!("{cmd} "))
})
```

This means an entry of `"git"` allows `git status` and `git commit -m "msg"`, but not `gitk` (no trailing space after `git`).

**Example.** A capsule that runs `git` commands:

```toml
[capabilities]
host_process = ["git"]
```

`spawn("git", ["status"])` passes. `spawn("rm", ["-rf", "/"])` returns `ErrorCode::CapabilityDenied` before any process is created. `spawn("gitk", [])` is also denied.

Note: if `state.security` is `None`, the process host function denies unconditionally -- there is no fallthrough to allow-all when the gate is absent:

```rust
} else {
    let result: Result<ProcessResult, ErrorCode> = Err(ErrorCode::CapabilityDenied);
    audit_process(self, "astrid:process/host.spawn", &cmd_for_audit, &result);
    return result;
}
```

### Unix socket binding (`net_bind`)

The `net_bind` capability is boolean in effect: the gate checks for at least one non-empty string in the `net_bind` list. An empty string is treated as malformed and does not grant capability:

```rust
let has_valid_entry = self.manifest.capabilities.net_bind
    .iter()
    .any(|entry| !entry.is_empty());
```

The gate takes no socket path argument because the kernel pre-binds the listener socket and the path is not capsule-controllable. A `net_bind` declaration grants the capsule the right to call `accept` on the pre-provisioned listener, not to bind an arbitrary path.

**Example.**

```toml
[capabilities]
net_bind = ["unix:///tmp/myapp.sock"]
```

The string value is ignored beyond the non-empty check. The capability grants `bind-unix` access; `bind-tcp` is currently stubbed and returns `CapabilityDenied` regardless of any declaration.

### Outbound TCP (`net_connect`)

The `net_connect` field is a list of `"host:port"` patterns. Each pattern can use a literal port or `*` to allow any port for a named host. Host comparison is case-insensitive (DNS names are case-insensitive per RFC 1035). DNS-style wildcards (`*.example.com`) are intentionally not supported:

```rust
fn net_connect_pattern_matches(pattern: &str, host: &str, port: u16) -> bool {
    let Some((pat_host, pat_port)) = pattern.rsplit_once(':') else { return false; };
    if !pat_host.eq_ignore_ascii_case(host) { return false; }
    match pat_port {
        "*" => true,
        p => p.parse::<u16>().is_ok_and(|n| n == port),
    }
}
```

After the gate passes, `connect-tcp` resolves the hostname with `tokio::net::lookup_host` and runs the same SSRF IP-range check that HTTP uses. A pattern like `"db.internal:5432"` will be denied at the SSRF stage if `db.internal` resolves to a private IP, regardless of the allowlist entry.

**Example.** A capsule that connects to a database and a cache:

```toml
[capabilities]
net_connect = ["db.prod.example.com:5432", "cache.prod.example.com:6379"]
```

`connect_tcp("db.prod.example.com", 5432)` passes the gate and proceeds to DNS + SSRF check. `connect_tcp("db.prod.example.com", 80)` is denied by the gate because port 80 is not in the allowlist. `connect_tcp("evil.com", 5432)` is denied because the host does not match.

### IPC publish and subscribe (`ipc_publish`, `ipc_subscribe`)

Topic patterns use dot-separated segments. A `*` in a segment matches exactly one segment. Segment counts must match: `"foo.v1.*"` allows `"foo.v1.event"` but not `"foo.v1.a.b"`. Empty segments are rejected at both declaration-validation and runtime-check time via `has_valid_segments`.

The publish check runs inside `publish_inner` before the event is handed to the bus:

```rust
if state.ipc_publish_patterns.is_empty() {
    return Err(ErrorCode::CapabilityDenied);
}
if !state.ipc_publish_patterns.iter().any(|pattern| topic_matches(&topic, pattern)) {
    return Err(ErrorCode::CapabilityDenied);
}
```

The subscribe ACL runs at subscription time, not at message delivery time. A capsule subscribes to a topic pattern string; the gate checks whether that pattern string is covered by an `ipc_subscribe` entry. Once the subscription is created, the bus delivers events without per-message ACL checks (which would be O(n) per delivery on a broadcast bus).

A new manifest format (RFC cargo-like-manifest) declares publish and subscribe entries as keys in `[publish]` and `[subscribe]` tables. When those tables are non-empty, they supersede `capabilities.ipc_publish` / `capabilities.ipc_subscribe` so operators do not double-declare. The `effective_ipc_publish_patterns()` and `effective_ipc_subscribe_patterns()` methods on `CapsuleManifest` implement this precedence.

**Example.** A capsule that participates in an LLM response stream:

```toml
[publish."myapp.v1.result"]
wit_type = "result-payload"

[subscribe."llm.v1.response"]
handler = "handle_llm_response"
```

This grants publish access to the exact topic `"myapp.v1.result"` and subscribe access to `"llm.v1.response"`. An attempt to publish to `"myapp.v1.internal"` returns `ErrorCode::CapabilityDenied`.

### Identity operations (`identity`)

The `identity` field is a list of capability level strings. The hierarchy is `admin > link > resolve`: declaring `"admin"` implies `"link"` and `"resolve"`. Declaring `"link"` implies `"resolve"`. An empty list denies all identity operations.

```rust
pub fn identity_capability_satisfies(declared: &[String], required: &str) -> bool {
    if declared.iter().any(|d| d == required) { return true; }
    match required {
        "resolve" => declared.iter().any(|d| d == "link" || d == "admin"),
        "link"    => declared.iter().any(|d| d == "admin"),
        _         => false,
    }
}
```

Operations map to levels:

| Operation | Required level |
|---|---|
| `identity-resolve` | `resolve` |
| `identity-link` | `link` |
| `identity-unlink` | `link` |
| `identity-list-links` | `link` |
| `identity-create-user` | `admin` |

**Example.** A Telegram uplink capsule that needs to resolve platform users but not create them:

```toml
[capabilities]
identity = ["resolve"]
```

`identity_resolve(...)` passes. `identity_link(...)` returns `ErrorCode::CapabilityDenied`. `identity_create_user(...)` also returns `ErrorCode::CapabilityDenied`.

### Prompt injection (`allow_prompt_injection`)

This is a boolean, defaulting to `false`. When `false`, the prompt-builder hook pipeline strips the `systemPrompt`, `prependSystemContext`, and `appendSystemContext` fields from any hook response this capsule produces. Only `prependContext` (user-visible context) passes through.

The value is read from the capsule's loaded manifest at hook dispatch time via `sys.check-capsule-capability`:

```rust
"allow_prompt_injection" => capsule.manifest().capabilities.allow_prompt_injection,
```

Unprivileged capsules cannot inject arbitrary instructions into the LLM's system prompt. Only capsules that explicitly declare `allow_prompt_injection = true` and are installed with operator approval can influence the system prompt.

## The `EnvScope::skip_deserializing` pattern

The `EnvDef.scope` field in `Capsule.toml` uses `#[serde(skip_deserializing)]`. A capsule manifest cannot set its own sharing scope. The runtime resolves scope from operator action (`astrid secret set --scope shared`) at runtime. If a malicious capsule could declare `scope = "shared"`, it could pull host-wide credential values that were set for a different capsule's namespace into its own sandbox. Operator-controlled fields that affect cross-principal exposure use `skip_deserializing` at the type level to enforce this boundary at parse time, before any runtime check fires.

## Audit logging

Every capability check emits a structured `tracing` event under the relevant target before returning:

| Target | Operations |
|---|---|
| `astrid.audit.fs` | `read-file`, `write-file`, `fs-exists`, `fs-mkdir`, `fs-readdir`, `fs-stat`, `fs-unlink` |
| `astrid.audit.http` | `http-request`, `http-stream.read-chunk` |
| `astrid.audit.ipc` | `publish`, `publish-as`, `subscribe`, `subscription.poll`, `subscription.recv` |
| `astrid.audit.net` | `connect-tcp`, `bind-unix`, `accept` |
| `astrid.audit.process` | `spawn`, `spawn-background` |

Each event carries `capsule_id`, `principal`, the operation name, path/topic/bytes as applicable, and the result or error. Denied checks are logged with the error string before the host function returns `CapabilityDenied` to the guest.

## See also

- [Capabilities, Tokens, and Delegation](../security/capabilities-and-tokens.md)
- [The Syscall Surface](the-syscall-surface.md)
- [The Capsule Manifest and Engines](../capsule-model/manifest-and-engines.md)
