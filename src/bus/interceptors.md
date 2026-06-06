# Interceptors

An interceptor is a WASM capsule export that the kernel dispatcher calls synchronously whenever an IPC event matches the capsule's declared topic pattern. Interceptors compose into ordered middleware chains: every capsule that matches a given event fires in priority order, each one deciding whether to pass the (possibly modified) payload to the next link or cut the chain short.

This page covers how interceptors are declared, how the dispatcher sorts and runs them, what the three return variants mean, how null-returning handlers pass through silently, why events destined for the same principal serialize within a capsule but run concurrently across principals, and how the `#[capsule]` macro generates stateful vs. stateless dispatch.

---

## Declaring an Interceptor

Interceptors are declared in `Capsule.toml` as `[subscribe]` entries that carry a `handler`:

```toml
[subscribe]
"tool.v1.request.execute" = { wit = "@unicity-astrid/wit/types/tool-call", handler = "handle_execute_request" }
"tool.v1.execute.*.result" = { wit = "@unicity-astrid/wit/types/tool-call-result", handler = "handle_execute_result", priority = 10 }
```

The `handler` value names the `#[astrid::interceptor("...")]` export in the WASM guest. An entry without a `handler` grants subscribe ACL only: the guest still calls `ipc::subscribe()` to receive those events itself. Every interceptor binding carries a typed `wit` payload reference; use `"opaque"` for an entry that forwards raw bytes.

Source: `capsules/astrid-capsule-router/Capsule.toml`

### Priority

`priority` is an optional `u32` on a `[subscribe]` entry, meaningful only when `handler` is set. Lower values fire first. The default is `100`. A pattern guard at priority `10` fires before the react loop at priority `100`, which fires before a logging capsule at priority `200`. `CapsuleManifest::effective_interceptors` (`core/crates/astrid-capsule/src/manifest/mod.rs`) collects every `[subscribe]` entry that has a `handler` and carries its declared priority through; the dispatcher sorts the matched set (`core/crates/astrid-capsule/src/dispatcher.rs`) and runs the handlers in strict ascending order.

---

## Topic Matching

Interceptor patterns support exact matches and single-segment wildcards. Matching is handled by `topic_matches` in `core/crates/astrid-capsule/src/topic.rs`:

- Both the topic and the pattern are split on `.`.
- Segment counts must be equal.
- A `*` in the pattern matches exactly one segment.
- Topics or patterns with empty segments (leading/trailing/consecutive dots) are rejected.

```
tool.execute.search.result  matches  tool.execute.*.result     // true
tool.execute.result         matches  tool.execute.*.result     // false (3 vs 4 segments)
user.prompt                 matches  user.prompt               // true
user.prompt.extra           matches  user.prompt               // false
```

This is stricter than the bus-side `EventReceiver::matches` used for async subscribers, which allows trailing `*` to consume one-or-more segments. Interceptor patterns always require exact segment count. The wildcard covers exactly one position.

---

## The Three Return Variants

The kernel type `InterceptResult` (`core/crates/astrid-capsule/src/capsule.rs:28`) governs chain flow:

```rust
pub enum InterceptResult {
    Continue(Vec<u8>),
    Final(Vec<u8>),
    Deny { reason: String },
}
```

### Continue

The handler passes. Execution moves to the next interceptor in the chain. If `Continue` carries non-empty payload bytes, the dispatcher replaces `current_payload` with those bytes before calling the next capsule. If `Continue` carries an empty payload, the previous payload is preserved unchanged.

This is the mechanism for payload mutation: a capsule can deserialize the incoming JSON, modify it, re-serialize, and return the new bytes inside `Continue`. The next capsule receives the modified version.

### Final

The handler short-circuits the chain with a successful response. No further interceptors fire. The response payload is available to the caller but, because all dispatch is fire-and-forget from the dispatcher's perspective, it is primarily used for response collection via the `hooks::trigger` kernel syscall rather than as a direct return value to IPC callers.

### Deny

The handler blocks the event entirely. No further interceptors fire. The `reason` string is emitted via a plain `warn!` carrying `capsule_id`, `action`, `topic`, and `reason` fields (`core/crates/astrid-capsule/src/dispatcher.rs:487`). Deny is the correct response when a capability check fails, a rate limit fires, or a policy rule rejects the payload.

### Error and NotSupported

If a capsule returns `CapsuleError::NotSupported`, the chain continues silently. This allows a capsule to declare a broad wildcard and selectively skip events it does not handle without poisoning the chain. Any other error is logged at `warn` level and the chain also continues, so a malfunctioning capsule cannot block the rest of the pipeline.

---

## Null-Return Passthrough Semantics

The `#[capsule]` macro (`sdk-rust/astrid-sdk-macros/src/lib.rs`) wraps every handler return value. When the Rust method returns `Ok(())` or `Ok(None)` (types that serialize to JSON `null`), the generated dispatch code detects the `"null"` string and returns:

```rust
return ::astrid_sdk::astrid_sys::CapsuleResult {
    action: "continue".into(),
    data: None,
};
```

A `CapsuleResult` with `data: None` maps to `InterceptResult::Continue` with an empty payload. The component model adapter in `capsule.rs::from_capsule_result` (`core/crates/astrid-capsule/src/capsule.rs:65`) converts `"continue"` with no data to `Continue(vec![])`. The dispatcher then preserves the incoming payload unchanged for the next capsule in the chain.

The practical effect: a handler that returns `Ok(())` is a passive observer. It receives the event, does its work (logging, side-effects, metric increments), and the event passes through as if the capsule were not there. No explicit passthrough return is required.

---

## Per-Principal Chain Serialization

The dispatcher partitions event delivery by `(CapsuleId, PrincipalKey)` where `PrincipalKey` is `Option<String>` extracted from `IpcMessage.principal`. Events for the same principal targeting the same capsule execute serially via a per-slot `tokio::Mutex`. Events for different principals on the same capsule run concurrently.

This design comes from issue resolution around the orchestration cliff (issue `#813`). The concern was that a per-class queue could collapse traffic from N distinct principals into a single serialized stream, causing head-of-line blocking. Per-principal keying eliminates that: alice's tool call and bob's tool call targeting the same capsule execute in parallel.

For multi-interceptor events, the chain task acquires a `ChainLockGuard` per `(CapsuleId, PrincipalKey)` before invoking each capsule (`core/crates/astrid-capsule/src/dispatcher.rs:456`). The guard is RAII and prunes its map entry on drop when no other task holds the lock, bounding the `ChainLocks` map under high principal churn.

For single-interceptor events (the common case), the dispatcher uses `dispatch_single` which routes through a per-principal `mpsc::Sender<InterceptorWork>` without chain overhead. These queues idle-evict after 60 seconds of inactivity.

The queue cap is `CAPSULE_EVENT_QUEUE_CAPACITY = 64` slots per `(capsule, principal)` pair. When the queue is full, the event is dropped with a warning. When the per-capsule principal count exceeds `MAX_DISPATCHER_QUEUES_PER_CAPSULE = 10_000`, new principals degrade to a shared `PrincipalKey::None` queue with an audit-logged error.

---

## Stateful vs. Stateless Dispatch

The `#[capsule]` macro generates two distinct dispatch paths depending on whether the capsule is stateful.

### Stateless dispatch

When all handler methods take `&self` and the macro attribute is not `#[capsule(state)]`, the macro emits a `OnceLock<T>` singleton:

```rust
static INSTANCE: ::std::sync::OnceLock<MyCapsule> = ::std::sync::OnceLock::new();

fn get_instance() -> &'static MyCapsule {
    INSTANCE.get_or_init(|| MyCapsule::default())
}
```

Handlers call `get_instance().my_method(args)`. No KV round-trip occurs. This is appropriate for handlers with no mutable state, including read-only tools and pure routing capsules like `astrid-capsule-router`.

### Stateful dispatch

When any method takes `&mut self`, or when the attribute is `#[capsule(state)]`, the macro generates load-call-save logic around every handler:

```rust
// Before the call:
let mut instance: MyCapsule = match kv::get_json("__state") {
    Ok(state) => state,
    Err(SysError::JsonError(_)) => Default::default(),
    Err(e) => return CapsuleResult { action: "deny".into(), data: Some(format!("...")) },
};

// The user method runs, mutating `instance`.

// After a successful call:
if let Err(e) = kv::set_json("__state", &instance) {
    return CapsuleResult { action: "deny".into(), data: Some(format!("...")) };
}
```

State is only persisted on success. A failed tool call does not commit partial mutations (`sdk-rust/astrid-sdk-macros/src/lib.rs:535`).

The `#[astrid::run]` method is an exception even in stateful capsules: it loads state once at startup but never auto-saves, because a run-loop is infinite and has no natural commit boundary.

---

## The Generated ABI

The macro generates an `impl Guest for __AstridExport` block. All interceptors and commands land in `astrid_hook_trigger`, which receives a `(action: String, payload: Vec<u8>)` pair and returns a `CapsuleResult { action: String, data: Option<String> }`:

```rust
fn astrid_hook_trigger(action: String, payload: Vec<u8>) -> CapsuleResult {
    match action.as_str() {
        "handle_execute_request" => { /* generated dispatch */ }
        "my_guard" => { /* generated dispatch */ }
        _ => CapsuleResult {
            action: "deny".into(),
            data: Some(format!("unknown hook action: {}", action)),
        },
    }
}
```

The `action` string is the name declared in `#[astrid::interceptor("...")]` and matched identically against the `action` field in `InterceptorDef`. Unknown actions return `Deny` rather than `Continue` so that a misconfigured manifest fails loudly instead of silently passing all events.

Tools get a synthetic action name `tool_execute_<tool_name>`, so `#[astrid::tool("read_file")]` appears as `"tool_execute_read_file"` in the match arm and in the dispatcher's action string. The `tool_describe` action is automatically generated when any tool is present and returns the JSON schema for all tools.

---

## Introspection: `interceptors::bindings`

The SDK exposes `astrid_sdk::interceptors::bindings()` (`sdk-rust/astrid-sdk/src/interceptors.rs:42`), which calls the host function `get-interceptor-bindings` and returns a `Vec<InterceptorBinding>`:

```rust
pub struct InterceptorBinding {
    pub handle_id: u64,   // opaque kernel registry handle, for log correlation
    pub action: String,   // the action name from the manifest
    pub topic: String,    // the topic pattern this interceptor subscribes to
}
```

The `handle_id` is opaque and cannot be converted to an `ipc::Subscription`. It is surfaced for log correlation and introspection tooling only. Capsules use this at startup to enumerate their own auto-subscribed interceptor bindings and confirm the kernel has registered them correctly.

---

## Example: the Tool Router

`astrid-capsule-router` (`capsules/astrid-capsule-router/src/lib.rs`) demonstrates a stateless, two-interceptor capsule:

```rust
#[capsule]
impl ToolRouter {
    #[astrid::interceptor("handle_execute_request")]
    pub fn handle_execute_request(&self, req: IpcPayload) -> Result<(), SysError> {
        // validate tool name, publish to tool.v1.execute.<name>
        Ok(())
    }

    #[astrid::interceptor("handle_execute_result")]
    pub fn handle_execute_result(&self, res: IpcPayload) -> Result<(), SysError> {
        // forward result to tool.v1.execute.result
        Ok(())
    }
}
```

The example above is simplified for illustration. On the happy path, both methods propagate to `Continue(vec![])` so neither modifies any payload and the events pass through. On errors (for example, when an `ipc::publish_json` call fails), the macro converts the returned `Err(SysError)` to a `Deny` result rather than `Continue`. The Capsule.toml subscribes `handle_execute_request` to `tool.v1.request.execute` and `handle_execute_result` to `tool.v1.execute.*.result`. The wildcard in the second pattern matches any tool-specific result topic (one segment) before the `.result` suffix.

The tool name validation inside `handle_execute_request` illustrates a soft-guard pattern: on an invalid name, the method calls `ipc::publish_json` to post an error result and returns `Ok(())`, which keeps the chain continuing. A hard-deny (returning an `Err` or explicitly producing `Deny`) would also work but would generate no error result visible to the caller. The choice between them is policy.

---

## Delivery Guarantees and Failure Modes

All interceptor dispatch is fire-and-forget from the `EventDispatcher::run` loop (`core/crates/astrid-capsule/src/dispatcher.rs:249`). The dispatcher does not wait for chain completion before processing the next event from the broadcast channel. This means:

- An interceptor that blocks indefinitely delays events destined for the same `(capsule, principal)` queue but does not stall unrelated capsules or different principals.
- A capsule that panics inside the WASM sandbox does not crash the kernel; the host catches the trap, logs the error, and the chain continues.
- If the per-principal mpsc queue is full (64 slots), the dispatcher drops the event with a `warn!` log and no further retry occurs. This is the designed backpressure behavior.
- Broadcast channel overflow is tracked via the `astrid_bus_receiver_lagged_total` metric, labeled by `subscriber = "capsule_dispatcher"`. A rising counter there means the event publication rate is exceeding the dispatcher's drain rate.

## See also

- [Topics and Wildcards](topics-and-wildcards.md)
- [Tools as an IPC Convention](tools-as-ipc.md)
- [The Five-Layer Security Gate](../security/five-layer-gate.md)
