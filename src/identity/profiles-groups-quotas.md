# Profiles, Groups, and Quotas

Every principal in Astrid has a *profile* and belongs to zero or more *groups*. The profile is the per-principal policy file: it names group memberships, carries direct capability grants and revokes, sets authentication options, and declares resource quotas. Groups are the operator-managed capability sets that members inherit. The kernel resolves both at invocation time to produce the effective capability set used by the authorisation check.

---

## Profile location and security boundary

Profile files live at:

```
~/.astrid/etc/profiles/{principal}.toml
```

This is the system `etc/` directory, not inside the principal's home directory (`~/.astrid/home/{principal}/`). The distinction is load-bearing. A capsule running as `alice` and holding `fs_read = ["home://"]` can read everything under `~/.astrid/home/alice/` via the VFS. It cannot reach `~/.astrid/etc/profiles/alice.toml` because the `home://` VFS scheme is scoped to the principal's own home subtree, and the kernel's VFS layer never mounts `etc/` through `home://`. Self-elevation via file write is therefore structurally impossible, not a policy decision the kernel has to reason about at runtime.

The canonical path resolver is `AstridHome::profile_path` (`core/crates/astrid-core/src/dirs.rs:250`):

```rust
pub fn profile_path(&self, id: &PrincipalId) -> PathBuf {
    self.profiles_dir().join(format!("{id}.toml"))
}
```

Saves are atomic on Unix: the writer places a temp sibling (`{principal}.toml.tmp.{pid}.{seq}`) with mode `0o600`, calls `fsync`, then renames over the target. A failed rename removes the temp file rather than leaving a secret-adjacent remnant. The `AtomicU64` sequence counter in the IO implementation (`core/crates/astrid-core/src/profile/io_impl.rs:95`) disambiguates concurrent saves within the same process.

---

## profile.toml fields

The top-level struct is `PrincipalProfile` (`core/crates/astrid-core/src/profile/mod.rs`). All fields have `#[serde(deny_unknown_fields)]`, so a typo in the file is a hard load error, not a silent no-op.

```toml
profile_version = 1          # schema sentinel; >CURRENT is rejected
enabled = true               # master on/off switch

groups  = ["agent", "ops"]   # group membership; names validated [a-zA-Z0-9_-]
grants  = ["capsule:install"] # direct capability grants (capability grammar)
revokes = ["system:shutdown"] # highest-precedence denies (capability grammar)

[auth]
methods     = ["keypair", "passkey", "system"]
public_keys = ["ed25519:AAAA..."]

[network]
egress = ["api.example.com:443"]   # empty = no outbound (fail-closed)

[process]
allow = ["/usr/bin/env"]           # empty = no process spawn (fail-closed)

[quotas]
max_memory_bytes         = 67108864   # 64 MiB
max_timeout_secs         = 300        # per-invocation wall-clock cap
max_ipc_throughput_bytes = 10485760   # IPC bytes/sec
max_background_processes = 8
max_storage_bytes        = 1073741824 # 1 GiB
max_cpu_fuel_per_sec     = 2000000000 # wasmtime fuel units/sec
```

**Missing file.** When `etc/profiles/{principal}.toml` does not exist, `PrincipalProfile::load` returns `PrincipalProfile::default()`. The defaults are intentionally fail-closed for the sensitive parts: `network.egress` is empty (no outbound traffic), and `process.allow` is empty (no spawn). The numeric quotas use the constants defined in `profile/mod.rs` (`DEFAULT_MAX_MEMORY_BYTES`, etc.).

**Malformed file.** Any TOML syntax error, unknown field, unknown `AuthMethod` variant, or `profile_version` above `CURRENT_PROFILE_VERSION` (currently `1`) is a hard error. The kernel denies the invocation with an audit trail rather than falling back to permissive defaults. This applies to both load and save paths: `validate()` runs in both directions.

**`enabled = false`.** When the flag is `false`, the kernel refuses every invocation for that principal regardless of what capabilities it holds. There is no capability that overrides this field.

---

## groups.toml and the capability grammar

The system-wide group config lives at:

```
~/.astrid/etc/groups.toml
```

The struct is `GroupConfig` (`core/crates/astrid-core/src/groups/mod.rs`). Missing file means built-ins only. Malformed TOML or a redefined built-in name fails the kernel boot.

### Built-in groups

Three groups are baked in and cannot be redefined in `groups.toml`:

| Name | Capabilities | Purpose |
|------|-------------|---------|
| `admin` | `["*"]` | Universal grant. Matches every capability string via the glob matcher. |
| `agent` | `["self:*", "self:quota:get", "self:agent:list", "delegate:self:*"]` | Self-scoped grants for routine agent workflows. The explicit `self:quota:get` and `self:agent:list` entries are redundant (already covered by `self:*`) but are listed so operators reading the config can see the intent clearly. |
| `restricted` | `[]` | No capabilities. All grants must be explicit on the profile. |

Attempting to shadow any of these in `groups.toml` produces `GroupConfigError::RedefinedBuiltin` at load time.

### Custom groups

Operator-defined groups use the `[groups.{name}]` TOML table syntax:

```toml
[groups.ops]
description = "Deployment operators"
capabilities = ["capsule:install", "capsule:remove"]

[groups.auditor]
capabilities = ["audit:read_all", "agent:list"]

[groups.privileged]
unsafe_admin = true
capabilities = ["*"]
```

Every capability entry in a custom group is validated against the capability grammar at load time. The universal `*` pattern requires `unsafe_admin = true` as an explicit opt-in guard against typo-driven privilege escalation. Without the flag, loading a custom group that grants `*` produces `GroupConfigError::UnsafeUniversalGrant`.

### Capability grammar

Static capabilities use a colon-delimited identifier namespace. This is a distinct namespace from the runtime `CapabilityToken` URI-based resource patterns (those gate individual tool calls; static capabilities gate role membership). The grammar is:

```text
capability  := segment (':' segment)*
segment     := '*' | [a-zA-Z0-9_-]+
```

Rules enforced by `validate_capability` (`core/crates/astrid-core/src/capability_grammar.rs:135`):

- Empty string: rejected.
- Exceeds 256 bytes: rejected.
- Contains `**`: rejected (reserved).
- Empty segment (leading/trailing/consecutive colons): rejected.
- Non-ASCII or shell metacharacters: rejected. Characters like space, `;`, backtick, `$`, `(`, `)`, `|`, and `>` are all invalid.
- Mixed `*` with other characters in the same segment (`foo*`, `*bar`): rejected. A `*` must stand alone in its segment.

Valid examples: `system:shutdown`, `self:*`, `self:capsule:install`, `a:*:b`, `*`, `agent-007`.

### Matching semantics

`capability_matches(pattern, cap)` (`core/crates/astrid-core/src/capability_grammar.rs:183`) evaluates patterns against concrete capability strings:

- `*` alone matches any capability.
- A trailing `*` segment (`self:*`) matches one or more remaining segments. `self:*` matches `self:capsule`, `self:capsule:install`, and `self:capsule:install:alice`.
- A `*` segment in the middle (`a:*:b`) matches exactly one segment. `a:*:b` matches `a:x:b` but not `a:x:y:b`.
- Otherwise segments must match literally and counts must agree.

The matcher iterates segment-by-segment using `Peekable` iterators with no heap allocation on the hot path.

---

## Revoke-over-grant precedence

The effective capability set for a principal is resolved as:

1. Collect capabilities from every group in `groups`.
2. Add any direct `grants`.
3. Apply `revokes` as the highest-precedence deny layer.

A revoke pattern wins unconditionally. A principal in the `admin` group holds `*`, but if the profile also has `revokes = ["system:shutdown"]`, that principal cannot shut down the daemon. The `admin` group membership does not override the revoke. This is not a configurable policy: it is enforced structurally by `CapabilityCheck` (`core/crates/astrid-capabilities/src/policy.rs`), which evaluates revokes after building the grant set and short-circuits on any matching revoke before issuing a grant decision.

The same check logic applies to direct grants: a principal with `grants = ["system:shutdown"]` but `revokes = ["system:*"]` is denied `system:shutdown` because the revoke pattern covers it.

---

## Quota model

`Quotas` (`core/crates/astrid-core/src/profile/mod.rs:227`) carries six resource limits. Each has defaults and validation bounds. Below is the enforcement status of each as of the current codebase:

### CPU fuel (`max_cpu_fuel_per_sec`)

**Enforced.** Measures wasmtime fuel, which counts executed guest instructions independently of host-call yields. Default: 2,000,000,000 units/sec (approximately a 2 GHz-equivalent guest instruction budget).

The enforcement path lives in `cpu_rate_deny` (`core/crates/astrid-capsule/src/engine/wasm/mod.rs:501`). `invoke_interceptor` calls this function before checking out a pooled instance. If the invoking principal has exceeded its per-second window, the invocation returns `Ok(InterceptResult::Deny { reason })`. The denial is `Ok(Deny)`, never `Err`: the dispatcher halts the interceptor chain on `Ok(Deny)` but continues on `Err`. An `Err`-based denial would be a silent enforcement bypass because a broken capsule returning an error does not block the pipeline.

The cross-capsule fuel total is accumulated in `FuelLedger` (`core/crates/astrid-capsule/src/fuel_ledger.rs`), which is cloned into every `WasmEngine`. One process-wide `Arc<DashMap>` means a principal driving multiple capsules has its CPU summed into one total, not fragmented per capsule.

The run-loop CPU bound (the epoch interrupt that traps spinners) is separate from this rate limit. The epoch interrupt fires independently of how much fuel has been consumed.

### Memory (`max_memory_bytes`)

**Enforced.** Per-invocation linear-memory ceiling applied via wasmtime's `ResourceLimiter` (`StoreMemoryMeter`). Default: 64 MiB. The resolved limit is `min(profile_limit, host_ceiling)`. The peak memory consumed by each invocation is attributed to the invoking principal in `MemoryLedger` and surfaced in `astrid quota` output.

### Invocation timeout (`max_timeout_secs`)

**Enforced.** Per-invocation wall-clock timeout derived from the owner principal's `max_timeout_secs` at load time and applied as an epoch deadline to the wasmtime `Store`. Default: 300 seconds (5 minutes). Maximum enforced: 86,400 seconds (24 hours). Daemon capsules (those declaring `uplinks` or `capabilities.uplink = true`) are exempt: they hold a `u64::MAX` epoch deadline because a listener capsule must never be epoch-trapped.

### IPC throughput (`max_ipc_throughput_bytes`)

**Enforced.** Checked at every `ipc_publish` host call. The resolved value from the effective profile is passed to `IpcRateLimiter::check_quota` (`core/crates/astrid-capsule/src/engine/wasm/host/ipc.rs:179`). A publish that would push the rolling-window byte count over the ceiling returns `ErrorCode::RateLimited`. Default: 10 MiB/sec.

### Background processes (`max_background_processes`)

**Enforced.** Checked in `spawn_background` (`core/crates/astrid-capsule/src/engine/wasm/host/process/mod.rs:187`). The limit is the minimum of the profile quota and the host-global `MAX_BACKGROUND_PROCESSES` constant. Default: 8. Synchronous `spawn` calls are not capped by this quota (they block the interceptor call until the child exits and count as invocation time, not background slots).

### Storage (`max_storage_bytes`)

**Not yet enforced.** The field exists, is validated, and round-trips through TOML. No host function currently reads `max_storage_bytes` from the effective profile and denies writes. This is planned as a future enforcement layer. Operators can set the value today but should not rely on it for access control.

### Exemptions

A principal holding any capability from `EXEMPT_CAPABILITIES` (`core/crates/astrid-core/src/capability_grammar.rs:86`) is exempt from the run-loop epoch interrupt and the linear-memory ceiling:

```rust
pub const EXEMPT_CAPABILITIES: [&str; 3] = [
    CAP_RESOURCES_UNBOUNDED, // "system:resources:unbounded"
    CAP_NET_BIND,            // "net_bind"
    CAP_UPLINK,              // "uplink"
];
```

`admin` holds all three via `*`. The exemption is evaluated against the capability grammar matcher, not a group-name string comparison: a custom group with `unsafe_admin = true` and `capabilities = ["*"]` would also be exempt.

Exemption fails closed: any missing input (no profile, no group config) returns `false`. A capsule that merely declares `net_bind` in its own `Capsule.toml` manifest does not receive the exemption unless the *operator* has granted `net_bind` (or `*`) to the capsule's load principal in the profile.

There is no "unlimited" sentinel value for quota fields. Exemption is always via capability, never via a magic quota value like `0` or `u64::MAX`.

---

## Invites and device pairing

### Invites

Invite tokens let an operator delegate one-time principal provisioning without sharing credentials. The store lives in `~/.astrid/etc/invites.toml`, managed by `InviteStore` (`core/crates/astrid-kernel/src/invite.rs`).

**Token mechanics.** `generate_token()` draws 24 bytes from `OsRng` and encodes them as URL-safe base64 (32 characters, 192 bits of entropy). The kernel never stores the raw token. It stores `hex(sha256(token))` and compares against that on redemption using `ct_hash_eq`, which calls `subtle::ConstantTimeEq` to prevent timing oracle attacks on the hash bytes.

**On-disk record:**

```toml
[[invite]]
token_hash     = "..."            # hex(sha256(token)), 64 hex chars
group          = "agent"          # group new redeemers join
remaining_uses = 1                # decremented on each redemption
expires_at_epoch = 1234567890     # optional Unix epoch; omit for use-count-only expiry
issued_at_epoch  = 1234560000
metadata       = "alice's tablet" # optional operator label
```

Maximum lifetime: 30 days (`MAX_EXPIRY_SECS = 60 * 60 * 24 * 30`). Entries with `remaining_uses == 0` or past their `expires_at_epoch` are pruned lazily (on the next `prune_file` call); there is no background sweeper.

**Threat model.** A read-only leak of `invites.toml` exposes hashes, not redeemable tokens. A write-capable attacker can plant a hash of their own choosing, so the file's security depends on the same filesystem permission model as `groups.toml` and `profile.toml`: daemon-UID ownership, mode `0o600`, atomic write-then-rename.

**Redeem path.** Redemption bypasses the `invite:redeem` capability check entirely because the token itself is the authentication. Granting `invite:redeem` to any principal is a no-op (documented in the capability catalog).

### Device pairing

Pair-device tokens let an existing principal add a second device's ed25519 public key to `AuthConfig.public_keys` without creating a new principal. The store lives at `~/.astrid/etc/pair-tokens.toml`, managed by `PairTokenStore` (`core/crates/astrid-kernel/src/pair_token.rs`).

The shape mirrors the invite store: 24-byte `OsRng` token, SHA-256 hash stored, constant-time comparison on redemption. Differences from invite tokens:

- **Single-use only.** There is no `remaining_uses` field. A redeemed token is removed immediately.
- **Shorter lifetime.** `MAX_EXPIRY_SECS` is one hour. Pair-tokens are intended for immediate use ("scan this QR code with your phone now"). Longer windows are deliberately unsupported; users who need a multi-day window should redeem a separate invite to provision a distinct principal instead.
- **Principal-scoped.** The record carries the `principal` field (a `PrincipalId`) that the new key attaches to. The kernel always binds the token to the caller's own principal regardless of any wire-level hints.

The capability gating mirrors invite redemption: `auth:pair:redeem` is a no-op grant because the token is the auth. The `self:auth:pair` capability governs the ability to *mint* a pair-device token.

---

## Wiring summary

At kernel boot:

1. `GroupConfig::load` reads `~/.astrid/etc/groups.toml`, merges it with the three built-ins, and validates every custom group capability against the grammar. Failure aborts boot.
2. `PrincipalProfileCache::with_home` constructs the lazy cache. No profiles are read yet.
3. The cache is placed in an `Arc` and cloned into every `WasmEngine` via `CapsuleContext::with_profile_cache`.

On each interceptor call:

1. `invoke_interceptor` resolves the invoking principal's profile from the cache (disk read only on first use; subsequent calls return an `Arc` clone with no IO).
2. `cpu_rate_deny` checks the windowed fuel rate against `max_cpu_fuel_per_sec`; denies with `Ok(Deny)` if over budget.
3. The memory limit, invocation timeout, IPC throughput limit, and background-process cap are applied from the resolved profile at the appropriate host-function call sites.

Profile cache invalidation is wired today via the quota_set handler (`astrid.v1.admin.quota.set`), which calls `PrincipalProfileCache::invalidate` after saving the updated profile. Other write paths (group edits, direct caps changes) still require a kernel restart to pick up changes.

## See also

- [PrincipalId and Per-Invocation Isolation](principal-and-isolation.md)
- [Capabilities, Tokens, and Delegation](../security/capabilities-and-tokens.md)
