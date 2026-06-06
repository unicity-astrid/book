# Capabilities, Tokens, and Delegation

Astrid has two separate authorization systems that coexist and protect different surfaces. Understanding the boundary between them is essential before reading either in depth.

**Runtime capability tokens** (`CapabilityToken`) are ed25519-signed, URI-patterned, optionally expiring, and optionally single-use. They gate individual capsule-level actions: calling an MCP tool, opening a file, invoking any operation whose resource is named with a URI. The signing key is the daemon's runtime keypair. Source: `core/crates/astrid-capabilities/src/token.rs`.

**Static capabilities** are colon-delimited identifier strings stored in `PrincipalProfile.grants`, `PrincipalProfile.revokes`, and `GroupConfig` entries. They gate the kernel's management API surface: daemon shutdown, capsule reload, agent provisioning, capability grant/revoke, invite lifecycle, audit access, and approval responses. Evaluation is a pure function over the resolved profile; no cryptography is involved at check time. Source: `core/crates/astrid-capabilities/src/policy.rs` and `core/crates/astrid-core/src/capability_grammar.rs`.

The two namespaces are mutually exclusive in what they authorize. A static `capsule:install` string has no meaning inside a `ResourcePattern`. A `mcp://filesystem:*` token has no bearing on whether a principal may call `system:shutdown`.

---

## Runtime Tokens

### The `CapabilityToken` structure

Every runtime token is a value of `CapabilityToken` (`token.rs:90`):

```rust
pub struct CapabilityToken {
    pub id: TokenId,
    pub resource: ResourcePattern,
    pub permissions: Vec<Permission>,
    pub issued_at: Timestamp,
    pub expires_at: Option<Timestamp>,
    pub scope: TokenScope,
    pub issuer: PublicKey,
    pub user_id: [u8; 8],
    pub approval_audit_id: AuditEntryId,
    pub single_use: bool,
    pub principal: PrincipalId,
    pub signature: Signature,
}
```

Fields are not independent policy suggestions. Every field except `signature` is part of the signed payload. Tampering with any field after minting causes `verify_signature` to return `CapabilityError::InvalidSignature`. The store tests at `store_tests.rs:379` confirm this: a token whose `permissions` field is modified on disk is rejected at `get()` time.

`approval_audit_id` links the token to the approval audit entry that authorized its creation. No token is minted without a corresponding approval event. This makes the audit chain the ground truth for "who approved what and when."

`user_id` is the first eight bytes of the approving user's ed25519 public key, stored as a short key fingerprint for log correlation without exposing the full key.

### Minting

Tokens are created via `CapabilityToken::create` or `CapabilityToken::create_with_options`. The runtime calls these after user approval. The `principal` parameter is mandatory and is baked into the signed payload.

```rust
let token = CapabilityToken::create(
    ResourcePattern::new("mcp://filesystem:*").unwrap(),
    vec![Permission::Invoke],
    TokenScope::Session,
    runtime_key.key_id(),
    AuditEntryId::new(),
    &runtime_key,
    Some(Duration::hours(24)),  // TTL; None means no expiry within scope
    principal.clone(),
);
```

The `create` method delegates to `create_with_options` with `single_use: false`. Use `create_with_options` when single-use replay protection is needed.

### The signing payload format (v2)

The signing data (`token.rs:228`) is a deterministic byte string. The version prefix `0x02` appears first, then each field is length-prefixed (4-byte little-endian length followed by the bytes), with fixed-width fields written without prefixes:

```text
[0x02]                                 // version
[4B len][token_id bytes]               // UUID bytes
[4B len][resource pattern UTF-8]
[4B count][for each perm: 4B len + bytes]
[8B i64 LE]                            // issued_at unix timestamp
[0x00 or 0x01][optional 8B i64 LE]    // expiration
[4B len][scope string: "session" or "persistent"]
[32B]                                  // issuer public key
[8B]                                   // user_id
[4B len][audit_id UUID bytes]
[0x00 or 0x01]                         // single_use flag
[4B len][principal string UTF-8]       // v2 addition
```

Version v1 did not include the principal suffix. A v1 token still on disk after a daemon upgrade fails signature verification against the v2 verifier because the current `signing_data()` appends the principal, producing a different byte string than what v1 signed over. There is no silent upgrade path: such a token fails as `InvalidSignature`, and operators must re-mint v1 tokens (`token.rs:691`).

### The `principal` field and cross-principal isolation

The `principal` field was added in the Layer 4 multi-tenancy work (issue #668). Its presence in the signed payload means:

- A token minted for `alice` carries `alice`'s identifier in the bytes that were signed.
- Presenting the same token as `bob` fails: `find_capability` scans only the inner map keyed by the caller's `PrincipalId`, and `validate_by_id` explicitly rejects cross-principal reuse with `CapabilityError::InvalidSignature` (`validator.rs:149`).
- Even if a token byte-for-byte matches on resource and permission, the caller's identity must equal `token.principal` or the check fails closed.

The defense-in-depth comment in `store.rs:413` covers the residual case: if a token somehow ends up in the wrong principal's inner map, `find_capability` still checks `token.principal != *principal` and skips it.

### Token scopes

`TokenScope` has two variants (`token.rs:71`):

```rust
pub enum TokenScope {
    Session,
    Persistent,
}
```

`Session` tokens live in the in-memory `HashMap` keyed by `PrincipalId`. They vanish when the daemon restarts or when `clear_session` (or `clear_session_for`) is called.

`Persistent` tokens are serialized to JSON and stored in the SurrealKV backing store under the key `caps:tokens/{principal}/{token_id}`. A secondary index at `caps:token_index/{token_id}` maps token IDs to principals for O(1) lookup by ID without a full-namespace scan.

The persistent layout was redesigned in Layer 4; the pre-Layer-4 flat `caps:tokens/{token_id}` key is no longer read. The store's `read_persistent_token_any_principal` method (`store.rs:312`) resolves a token through the secondary index only.

### Clock skew and expiration

`validate` uses a default clock skew tolerance of 30 seconds (`token.rs:32`):

```rust
const DEFAULT_CLOCK_SKEW_SECS: i64 = 30;
```

A token whose `expires_at` passed up to 30 seconds ago still passes `validate()`. `validate_with_skew(0)` applies no tolerance. This tolerates clock drift between the issuing daemon instance and the checking instance without creating an exploitable window of meaningful duration.

---

## ResourcePattern: the URI grammar and glob semantics

`ResourcePattern` (`pattern.rs:18`) wraps a pattern string and an optional compiled `GlobMatcher` from the `globset` crate.

### URI structure

Resource URIs follow two shapes:

- MCP tool resources: `mcp://{server}:{tool}` (colon separates server from tool, not a segment delimiter)
- File resources: `file://{path}`

The colon in `mcp://filesystem:read_file` is not the static-capability colon-delimiter grammar. It is a URI-style scheme separator between the server name and the tool name.

### Glob wildcards

Patterns containing `*`, `?`, or `[` are compiled with `globset`. Patterns without those characters use a bare string equality check:

```rust
let is_glob = pattern.contains('*') || pattern.contains('?') || pattern.contains('[');
```

Practical examples:

```
mcp://filesystem:read_file       // exact match only
mcp://filesystem:*               // any tool on the filesystem server
mcp://*:read_*                   // any tool starting with "read_" on any server
file:///home/user/**             // any file under /home/user (** = multi-segment)
```

The `*` wildcard in `globset` does not cross path separators by default. Use `**` for recursive directory matching.

### Path traversal rejection

Both pattern construction and resource matching reject `..` as a path segment. The check splits the path portion (after `://`) on `/` and looks for any segment equal to `..` exactly. Segments like `file..bak` pass; `/home/user/../etc` does not (`pattern.rs:149`).

This check runs in two places:
1. `ResourcePattern::new` and `ResourcePattern::exact`: reject patterns at construction time.
2. `ResourcePattern::matches`: reject resources at match time, even when the glob would otherwise match.

```rust
fn contains_path_traversal(s: &str) -> bool {
    let path = s.split_once("://").map_or(s, |(_, rest)| rest);
    path.split('/').any(|segment| segment == "..")
}
```

### Constructor helpers

`ResourcePattern` provides these typed constructors:

```rust
ResourcePattern::exact("mcp://filesystem:read_file")?   // string equality only
ResourcePattern::new("mcp://filesystem:*")?              // with glob compilation
ResourcePattern::mcp_tool("filesystem", "read_file")?   // exact: mcp://filesystem:read_file
ResourcePattern::mcp_server("filesystem")?              // glob: mcp://filesystem:*
ResourcePattern::file_dir("/home/user")?                // glob: file:///home/user/**
ResourcePattern::file_exact("/home/user/file.txt")?     // exact: file:///home/user/file.txt
```

All constructors return `CapabilityResult<Self>` and validate path traversal. Deserialization calls `ResourcePattern::new`, so malformed patterns in persisted JSON fail at load time.

---

## The CapabilityStore

`CapabilityStore` (`store.rs:81`) holds the live token set for all principals.

```rust
pub struct CapabilityStore {
    session_tokens: RwLock<HashMap<PrincipalId, HashMap<TokenId, CapabilityToken>>>,
    persistent_store: Option<Arc<dyn KvStore>>,
    revoked: RwLock<HashSet<TokenId>>,
    used_tokens: RwLock<HashSet<TokenId>>,
}
```

The session map is nested: outer key is `PrincipalId`, inner key is `TokenId`. This makes per-principal operations (lookup, clear) cheap without scanning across all principals.

Construction:

```rust
let store = CapabilityStore::in_memory();   // no KV backing
let store = CapabilityStore::with_persistence(path)?;  // SurrealKV at path
let store = CapabilityStore::with_kv_store(Arc::clone(&kv))?;  // shared KvStore
```

On construction with persistence, `load_revoked` and `load_used_tokens` replay the `caps:revoked` and `caps:used` KV namespaces into the in-memory sets so the store is immediately consistent with prior sessions.

`add` routes to session or persistent storage based on `token.scope`. It calls `token.validate()` before inserting, so an expired or signature-invalid token is rejected at store time.

`has_capability` is a boolean wrapper around `find_capability`. `find_capability` scans only the caller's principal entry and skips expired tokens and consumed single-use tokens (fail-closed on lock poisoning). For session tokens, revoked tokens are absent from the session map because `revoke()` removes them at store time; the in-loop revocation check applies only to persistent tokens. `find_capability` never considers tokens from another principal's map.

---

## Revocation

Revocation is a property of the token's identity, not the caller's identity. Revoking token T revokes it for every principal that might hold it.

`revoke(token_id)` (`store.rs:491`):
1. Writes a presence marker to `caps:revoked/{token_id}` in the persistent store. The KV write happens before the in-memory update so the revocation survives a crash-between-steps.
2. Uses the secondary index (`caps:token_index/{token_id}`) to locate and delete the primary persistent entry.
3. Drops the index row.
4. Adds the ID to the in-memory `revoked` set.
5. Removes the token from every principal's session map.

Revoked IDs are checked first in `get()`. Any lookup of a revoked token ID returns `Err(CapabilityError::TokenRevoked)` regardless of whether the token still exists on disk.

The revocation test at `store_tests.rs:239` verifies that revocation survives a simulated restart: revoke in one store instance, drop it, construct a new instance over the same KV, confirm `TokenRevoked` on lookup.

---

## Single-use replay protection

Setting `single_use: true` on a token means it can be consumed exactly once. The store uses a separate `used_tokens` set, backed by `caps:used/{token_id}` in persistent storage.

`mark_used(token_id)` (`store.rs:578`) holds the write lock across the KV write to prevent a TOCTOU race where two concurrent callers both pass the "already used?" check before either inserts. The comment in the source is explicit about this. If a second call arrives before the first completes, one of them will see `CapabilityError::TokenAlreadyUsed`.

`find_capability` uses `is_consumed_single_use`, which returns `Err(())` on lock poisoning and causes `find_capability` to return `None` (fail-closed) rather than granting the capability under an uncertain lock state.

The test at `store_tests.rs:270` confirms that consumed single-use state survives a restart in persistent storage.

---

## The CapabilityValidator

`CapabilityValidator` (`validator.rs:48`) layers issuer trust checking on top of the store.

```rust
let validator = CapabilityValidator::new(&store)
    .trust_issuer(runtime_key.export_public_key());

let result = validator.check(&principal, "mcp://filesystem:read_file", Permission::Invoke);
match result {
    AuthorizationResult::Authorized { token } => { /* proceed */ }
    AuthorizationResult::RequiresApproval { resource, permission } => { /* request approval */ }
}
```

`check` calls `store.find_capability` (which already filters by principal), then calls `validate_token` on the found token. `validate_token` checks expiry, verifies the signature, and if `trusted_issuers` is non-empty, confirms the token's `issuer` public key is in the trusted set. A token signed by an unexpected key fails even if its payload is otherwise valid.

`validate_by_id` adds principal enforcement on top: the looked-up token's `principal` field must equal the caller's principal or the call returns `CapabilityError::InvalidSignature`. The error class is the same as a cryptographic mismatch so cross-principal reuse surfaces as an authorization failure, not a routing miss.

---

## Static Capabilities: the colon-delimited grammar

Static capabilities use a different namespace, defined in `core/crates/astrid-core/src/capability_grammar.rs`.

### Grammar

```text
capability  := segment (':' segment)*
segment     := '*' | [a-zA-Z0-9_-]+
```

Validation rules enforced by `validate_capability`:
- Non-empty, at most 256 bytes.
- No `**` (double-glob is reserved and rejected).
- No empty segments (leading, trailing, or consecutive colons).
- Segments contain only ASCII alphanumerics, `-`, `_`, or a bare `*`.
- A segment may not mix `*` with other characters (e.g. `foo*` is rejected; only a standalone `*` is valid).

Shell metacharacters (space, `;`, backtick, `$`, `|`, `>`) fail the alphanumeric check. The grammar is deliberately restrictive so capability strings round-trip through TOML and audit log serialization without escaping surprises.

### Matching

`capability_matches(pattern, cap)` (`capability_grammar.rs:183`) implements segment-by-segment comparison:

- The bare string `"*"` matches any capability unconditionally.
- A trailing `*` segment (`self:*`) matches one-or-more remaining segments.
- A `*` segment in a non-trailing position matches exactly one segment.
- Otherwise segments must match literally and counts must agree.

```
capability_matches("*",               "system:shutdown")        → true
capability_matches("self:*",          "self:capsule:install")   → true
capability_matches("self:*",          "self:capsule:install:x") → true
capability_matches("self:*",          "self")                   → false  // trailing * needs one+
capability_matches("a:*:b",           "a:x:b")                  → true
capability_matches("a:*:b",           "a:x:y:b")               → false  // middle * matches one
capability_matches("system:shutdown", "self:system:shutdown")   → false  // segment count mismatch
```

The implementation walks both strings with iterators to avoid `Vec` allocation on the hot path.

### Built-in groups and capabilities

Three groups are built into every `GroupConfig` and cannot be redefined in `groups.toml`:

| Group | Capabilities |
|---|---|
| `admin` | `["*"]` (universal grant) |
| `agent` | `["self:*", "self:quota:get", "self:agent:list", "delegate:self:*"]` |
| `restricted` | `[]` (no implicit capabilities) |

The `admin` group's `*` matches every static capability via `capability_matches`, including `system:resources:unbounded` (the CPU/memory bound exemption), `net_bind`, and `uplink`.

Custom groups are defined in `$ASTRID_HOME/etc/groups.toml`:

```toml
[groups.ops]
description = "Deployment operators"
capabilities = ["capsule:install", "capsule:reload"]

[groups.auditor]
capabilities = ["audit:read_all", "agent:list"]
```

Custom groups may not use `*` without explicitly setting `unsafe_admin = true`. The check is at load time and during runtime mutations (`insert_custom_group`, `modify_custom_group`). This makes escalation to a universal grant deliberate and visible in the configuration file.

### Capability catalog

`CAPABILITY_CATALOG` in `capability_grammar.rs:308` is the single source of truth for every static capability the kernel recognizes. It is a `const` slice of `CapabilityInfo` entries. Each entry carries:

```rust
pub struct CapabilityInfo {
    pub id: &'static str,
    pub label: &'static str,
    pub description: &'static str,
    pub category: CapabilityCategory,
    pub scope: CapabilityScope,
    pub danger: CapabilityDanger,
}
```

`CapabilityScope` distinguishes `Self_` (operation targets the caller's own principal) from `Global` (operation targets any principal or system-wide state). `CapabilityDanger` ranges from `Safe` through `Normal`, `Elevated`, and `Extreme`. The HTTP gateway's `/api/sys/capabilities` route serves this catalog directly so dashboards need no client-side metadata.

A `const` assertion at compile time (`capability_grammar.rs:624`) pins `KNOWN_CAPABILITIES_COUNT` to the catalog length. Adding a capability without bumping the count fails the build:

```rust
const _: () = assert!(
    CAPABILITY_CATALOG.len() == KNOWN_CAPABILITIES_COUNT,
    "KNOWN_CAPABILITIES_COUNT is stale; bump it when adding a capability"
);
```

Selected catalog entries:

```
system:shutdown, Extreme / Global, stop the daemon
system:status, Safe    / Global, read uptime and loaded capsule list
capsule:install, Extreme / Global, install into system-wide capsule directory
self:capsule:install, Elevated / Self, install into caller's workspace
agent:create, Normal  / Global, provision a new agent principal
caps:grant, Extreme / Global, append grants; meta-permission
caps:revoke, Elevated / Global, append revokes (deny list)
self:approval:respond, Safe   / Self, approve capability requests addressed to this principal
```

### The CapabilityCheck evaluator

`CapabilityCheck` (`policy.rs:92`) is a borrowed evaluator. It is zero-allocation and pure:

```rust
let check = CapabilityCheck::new(&profile, &groups, principal.clone());

if check.has("system:shutdown") { /* ... */ }

check.require("capsule:install").map_err(|e| match e {
    PermissionError::MissingCapability { .. } => { /* not held */ }
    PermissionError::RevokedCapability { revoke_pattern, .. } => { /* held but overridden */ }
    PermissionError::PrincipalDisabled { .. } => { /* profile.enabled = false */ }
})?;
```

Evaluation precedence is strictly ordered (`policy.rs:119`):

1. **Revokes always win.** If any pattern in `profile.revokes` matches `cap`, the check returns `false` regardless of group membership or direct grants. `require` returns `PermissionError::RevokedCapability` with the matching pattern.
2. **Direct grants.** If any pattern in `profile.grants` matches `cap`, the check returns `true`.
3. **Group-inherited capabilities.** Each group in `profile.groups` is looked up in `GroupConfig`. If any group's capability list contains a pattern matching `cap`, the check returns `true`. A group name not present in `GroupConfig` is fail-closed (no inherited capabilities) and logged at `warn!` with `security_event = true`.

An unknown group does not mask other memberships. A principal in `["nonexistent", "agent"]` still inherits the `agent` group's capabilities; the unknown name is logged and skipped (`policy.rs:165`).

Revokes override everything, including direct grants:

```rust
// admin profile with system:shutdown revoked
let mut p = PrincipalProfile::default();
p.groups = vec!["admin".into()];
p.revokes = vec!["system:shutdown".into()];

// check.has("system:shutdown") → false
// check.has("system:status")   → true  (admin group `*` still applies for other caps)
```

### Reserved capability constants

`capability_grammar.rs` exports three named constants for capabilities that are checked in multiple kernel subsystems:

```rust
pub const CAP_RESOURCES_UNBOUNDED: &str = "system:resources:unbounded";
pub const CAP_NET_BIND: &str = "net_bind";
pub const CAP_UPLINK: &str = "uplink";

pub const EXEMPT_CAPABILITIES: [&str; 3] = [
    CAP_RESOURCES_UNBOUNDED,
    CAP_NET_BIND,
    CAP_UPLINK,
];
```

A principal holding any of these is exempt from per-principal CPU epoch interrupts and the linear-memory ceiling enforced by the WASM engine. The admin group's `*` matches all three. The enforcement path and the usage-report path both iterate `EXEMPT_CAPABILITIES`, so displayed-exempt and enforced-exempt cannot drift apart.

---

## The Cryptographic Layer

### KeyPair

`KeyPair` (`astrid-crypto/src/keypair.rs:19`) wraps `ed25519-dalek`'s `SigningKey` with `ZeroizeOnDrop`:

```rust
pub struct KeyPair {
    verifying_key: VerifyingKey,   // #[zeroize(skip)] - VerifyingKey does not implement Zeroize
    signing_key: SigningKey,       // zeroized on drop
}
```

Generation uses `OsRng`. The secret key bytes are zeroized when the `KeyPair` is dropped, preventing key material from lingering in freed memory.

`key_id()` returns the first 8 bytes of the public key as a `[u8; 8]`. This short fingerprint is what gets stored in `CapabilityToken::user_id` and written to logs. It is not a unique identifier for all purposes but is sufficient for audit log correlation without exposing the full 32-byte public key.

### PublicKey and Signature

`PublicKey` (`keypair.rs:128`) is a newtype over `[u8; 32]`. It serializes as base64 and verifies signatures directly:

```rust
pub fn verify(&self, message: &[u8], signature: &Signature) -> CryptoResult<()>
```

`Signature` (`signature.rs:16`) is a newtype over `[u8; 64]`. It serializes as base64. Verification reconstructs the `VerifyingKey` from the public key bytes and calls `ed25519-dalek`'s `Verifier::verify`.

### ContentHash

`ContentHash` (`hash.rs:16`) uses BLAKE3 for content hashing:

```rust
pub fn hash(data: &[u8]) -> Self {
    Self(*blake3::hash(data).as_bytes())
}
```

`CapabilityToken::content_hash()` hashes the signing payload. This produces a stable digest of the token's logical contents (excluding the signature bytes themselves) for use in audit chains and integrity checking. Two tokens with identical payloads produce identical hashes; any field change produces a different hash.

---

## Delegation and Sub-agent Capability Restriction

### Current state: config-layer sub-agent limits

The codebase has foundational support for restricting sub-agent capabilities at the configuration level. `core/crates/astrid-config/src/merge/restrict.rs` enforces that sub-agent configuration values can only decrease from the workspace baseline:

```
subagents.max_concurrent, can only decrease from workspace
subagents.max_depth, can only decrease from workspace
subagents.timeout_secs, can only decrease from workspace
```

The static capability `"delegate:self:*"` appears in the built-in `agent` group's capability set, indicating the architecture anticipates a delegation surface. The `agent` group explicitly grants `delegate:self:*`, and the grammar (`a-zA-Z0-9_-` segments, colon-delimited) accommodates `delegate:` as a capability namespace prefix.

### What is not shipped

The cryptographic delegation model described in Astrid's design principles (ephemeral agents, recursive delegation, children can only get more restricted) is not yet fully implemented in `astrid-capabilities`. There is no:

- `DelegationVoucher` type or similar structure for passing capability subsets to sub-agents.
- `CapabilityToken`-level attenuation: a token cannot be narrowed and re-signed by a non-root principal.
- Chain-of-custody proof linking a sub-agent's capabilities back to the root approval.

The current enforcement boundary is at the config layer (quota tightening) and at the static capability level (a sub-agent principal gets its own `PrincipalProfile` with explicit grants, not a subset token derived from a parent token). Runtime token minting requires the daemon's signing key; there is no user-space delegation path that produces a valid `CapabilityToken` without kernel involvement.

Future work in this area would require the kernel to sign attenuated tokens on behalf of a parent principal, encoding the attenuation chain in the payload, and the validator to walk the chain verifying each link.

---

## Security invariants in summary

These invariants are enforced in code, not convention:

1. Every `CapabilityToken` is signed by the daemon's ed25519 key. The signature covers all policy fields including the bound principal.
2. A token cannot be presented on behalf of a different principal than the one baked into its signed payload. `find_capability` and `validate_by_id` both enforce this, and `find_capability` also applies defense-in-depth inside the inner loop.
3. v1 tokens (signed without the principal suffix) fail v2 verification unconditionally. There is no silent upgrade or fallback path.
4. Revocation writes to persistent storage before updating in-memory state. A crash between the two leaves the KV as ground truth, which is replayed on restart.
5. Single-use consumption holds a write lock across the KV write and the set insert, preventing TOCTOU double-use under concurrent callers.
6. Lock poisoning in `is_consumed_single_use` is fail-closed: `find_capability` returns `None` rather than granting the capability under an unknown lock state.
7. Path traversal sequences (`..` as a path segment) are rejected in both the pattern and the resource string being matched. This applies at construction time and at match time.
8. Static capability evaluation follows a fixed precedence: revokes beat grants beat group-inherited. No grant can override a revoke. Unknown group names contribute no capabilities.
9. A custom group may not grant the universal `*` capability without `unsafe_admin = true` in its config entry. This flag must appear in the config file; it is not a runtime-only state.

## See also

- [The Five-Layer Security Gate](five-layer-gate.md)
- [Capability Gating](../host-abi/capability-gating.md)
- [Profiles, Groups, and Quotas](../identity/profiles-groups-quotas.md)
