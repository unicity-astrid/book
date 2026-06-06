# Tools as an IPC Convention

Tools are not a kernel feature. The kernel has no concept of a tool name, a tool schema, or what
it means to execute a tool. What the kernel does is route IPC events by topic and invoke registered
interceptors. Tools are a convention layered on top of those primitives: a set of agreed topic
names, a well-known payload shape, and a handful of capsules that honor the contract.

This page traces the full lifecycle of a tool call through the bus, grounding every claim in the
code that implements it.

## The Two Payload Types

Two variants of `IpcPayload` carry all tool traffic. Both live in
`core/crates/astrid-types/src/ipc.rs`:

```rust
pub enum IpcPayload {
    // ...
    ToolExecuteRequest {
        call_id: String,
        tool_name: String,
        arguments: Value,
    },
    ToolExecuteResult {
        call_id: String,
        result: crate::llm::ToolCallResult,
    },
    // ...
}
```

`call_id` is a caller-generated correlation token that threads through the entire round trip.
`tool_name` is an opaque string to the kernel. The kernel serializes `IpcPayload` to JSON via
`serde` and hands the bytes to the WASM guest; neither the tag (`"tool_execute_request"`) nor
the field values are inspected by kernel code.

`ToolCallResult` carries `call_id: String`, `content: String`, and `is_error: bool`. There is no structured error
type. The tool capsule produces a human-readable string and a boolean; the LLM provider receives
exactly that.

## The Topic Namespace

The tool convention uses three topic families:

| Direction | Topic | Description |
|-----------|-------|-------------|
| react to router | `tool.v1.request.execute` | Initiate execution |
| router to tool capsule | `tool.v1.execute.<name>` | Capsule-specific dispatch |
| tool capsule to router | `tool.v1.execute.<name>.result` | Per-capsule result |
| router to react | `tool.v1.execute.result` | Unified result back to react loop |
| react to tool capsules | `tool.v1.request.cancel` | Abort in-flight executions |
| prompt-builder to capsules | `tool.v1.request.describe` | Schema fan-out request |
| tool capsule to prompt-builder | `tool.v1.response.describe.<source_id>` | Schema response |

None of these topics are registered in the kernel. They are dot-separated strings that flow
through `EventBus::publish` as `AstridEvent::Ipc` events. The bus matches them against
interceptor patterns from `Capsule.toml`; the kernel's role ends there.

## Execution Flow: React to Tool Capsule

When the react loop decides the LLM wants to call a tool, it publishes a
`ToolExecuteRequest` on `tool.v1.request.execute`:

```rust
// capsules/astrid-capsule-react/src/lib.rs:1107
ipc::publish_json(
    "tool.v1.request.execute",
    &IpcPayload::ToolExecuteRequest {
        call_id: tc.id.clone(),
        tool_name: tc.name.clone(),
        arguments: tc.arguments.clone(),
    },
)
```

The router capsule (`capsules/astrid-capsule-router/`) has declared an interceptor for this topic
in its `Capsule.toml`:

```toml
[subscribe]
"tool.v1.request.execute" = { wit = "@unicity-astrid/wit/types/tool-call", handler = "handle_execute_request" }
"tool.v1.execute.*.result" = { wit = "@unicity-astrid/wit/types/tool-call-result", handler = "handle_execute_result" }
```

When the dispatcher finds a matching `handle_execute_request` interceptor, it invokes the router
WASM guest with the serialized payload. The router unpacks the `ToolExecuteRequest` and computes
the forward topic:

```rust
// capsules/astrid-capsule-router/src/lib.rs:48
let forward_topic = format!("tool.v1.execute.{tool_name}");
```

Before doing so it validates the tool name. Dots are specifically forbidden to prevent topic
injection: a `tool_name` of `"foo.bar"` would produce `tool.v1.execute.foo.bar`, a four-segment
topic that could match a different capsule's interceptor pattern. The validation rejects anything
that is not alphanumeric, hyphen, underscore, or colon:

```rust
// capsules/astrid-capsule-router/src/lib.rs:39-45
if tool_name.is_empty()
    || tool_name
        .chars()
        .any(|c| !c.is_alphanumeric() && c != '-' && c != '_' && c != ':')
{
    log::warn(format!("Rejected invalid tool name: {tool_name}"));
    return Self::publish_error_result(&call_id, format!("Invalid tool name: {tool_name}"));
}
```

The kernel does not enforce this constraint. The router capsule enforces it.

The router then publishes a fresh `ToolExecuteRequest` to `tool.v1.execute.<name>`. The tool
capsule that wants to handle `foo` declares:

```toml
[subscribe]
"tool.v1.execute.foo" = { wit = "...", handler = "execute_foo" }
```

The dispatcher fires the matching interceptor on that capsule. The tool capsule performs its work
and publishes a `ToolExecuteResult` on `tool.v1.execute.foo.result` (or any topic matching
`tool.v1.execute.*.result`).

The router's second interceptor catches the result and republishes it on
`tool.v1.execute.result`, the single consolidated topic the react loop polls:

```rust
// capsules/astrid-capsule-router/src/lib.rs:85-88
ipc::publish_json(
    "tool.v1.execute.result",
    &IpcPayload::ToolExecuteResult { call_id, result },
)
```

The react loop receives this on its registered interceptor for `tool.v1.execute.result` and
records the result against the pending `DispatchedToolCall` keyed by `call_id`.

## The Kernel Is Unaware of All of This

No kernel crate contains the string `"tool.v1"` in dispatching logic. `astrid-capsule/src/dispatcher.rs`
calls `find_matching_interceptors` which calls `topic_matches` from `astrid-capsule/src/topic.rs`.
`topic_matches` compares dot-separated segments; it knows nothing about tools. The entire routing
decision is: does the pattern in this capsule's `Capsule.toml` match the topic on this event?
If yes, invoke the interceptor. If no, skip. That is all.

## The Describe Protocol

Before tool execution can happen, the prompt-builder capsule must know which tools exist and what
their JSON schemas look like. The kernel has no tool registry. Discovery uses the same bus:

1. The prompt-builder subscribes to `tool.v1.response.describe.*` before publishing.
2. It publishes an empty JSON object on `tool.v1.request.describe`.
3. Each tool capsule that has an interceptor for `tool.v1.request.describe` wakes, assembles a
   `{ "tools": [...] }` envelope, and publishes it on
   `tool.v1.response.describe.<its own source_id>`.
4. The prompt-builder drains responses for a bounded window
   (`TOOL_DESCRIBE_FANOUT_TIMEOUT_MS`, currently 500 ms), deduplicates by tool name (first
   occurrence wins), and caches the result in KV under `__tool_schema_cache`.

```rust
// capsules/astrid-capsule-prompt-builder/src/lib.rs:501,513
let sub = ipc::subscribe("tool.v1.response.describe.*")?;
ipc::publish("tool.v1.request.describe", "{}")?;
```

The fan-out window is bounded and approximate. A capsule that responds after the window closes is
silently ignored. There is no ordering guarantee across capsule responses. The deduplication rule
(first wins) means two capsules that export a tool with the same name will have one schema
silently dropped.

The collected schemas are `serde_json::Value` objects. The prompt-builder treats them as opaque
JSON for inclusion in the `LlmRequest` payload. The `LlmToolDefinition` type in
`core/crates/astrid-types/src/llm.rs` captures `name`, `description`, and `input_schema`:

```rust
pub struct LlmToolDefinition {
    pub name: String,
    pub description: Option<String>,
    pub input_schema: Value,
}
```

The kernel does not validate schemas. No WIT type-checking happens at runtime on tool schemas.

## The Mutable Flag

`Capsule.toml` tool entries carry a `mutable` boolean:

```rust
// core/crates/astrid-capsule/src/manifest/mod.rs:636-647
pub struct ToolDef {
    pub name: String,
    pub description_for_llm: String,
    pub input_schema_wit: Option<String>,
    pub mutable: bool,
}
```

The SDK `#[astrid::tool]` attribute reflects this. Tools annotated `mutable` in `capsule-fs`
include `write_file`, `replace_in_file`, `create_directory`, `delete_file`, and `move_file`:

```rust
// capsules/astrid-capsule-fs/src/lib.rs:108,119
#[astrid::tool("write_file", mutable)]
pub fn write_file(&self, args: WriteFileArgs) -> Result<String, SysError> { ... }

#[astrid::tool("replace_in_file", mutable)]
pub fn replace_in_file(&self, args: ReplaceInFileArgs) -> Result<String, SysError> { ... }
```

Read-only tools like `list_directory` and `grep_search` omit the flag. The field is carried in the
tool schema response so the prompt-builder and approval layer can key on it, but the flag has no
effect on routing. The kernel does not gate on mutability. Whether an approval prompt fires for a
mutable tool is a capsule-space decision, not a kernel enforcement.

## Dispatcher Topic Matching

The interceptor matching used for tool topics follows `topic_matches` in
`core/crates/astrid-capsule/src/topic.rs`. The rule is strict: segment count must be equal, and
`*` matches exactly one segment.

```rust
// core/crates/astrid-capsule/src/topic.rs
pub(crate) fn topic_matches(topic: &str, pattern: &str) -> bool {
    if !has_valid_segments(topic) || !has_valid_segments(pattern) {
        return false;
    }
    if topic.split('.').count() != pattern.split('.').count() {
        return false;
    }
    topic
        .split('.')
        .zip(pattern.split('.'))
        .all(|(t, p)| p == "*" || t == p)
}
```

This differs from the `EventReceiver` topic filter on the bus, which supports trailing `.*` to
match one or more segments. The interceptor matcher requires equal depth. A pattern like
`tool.v1.execute.*.result` matches `tool.v1.execute.write_file.result` (four-segment wildcard at
position four) but does not match `tool.v1.execute.result` (only three segments after the prefix).
Topic injection via a crafted `tool_name` containing a dot would produce a six-segment result topic that the five-segment router pattern `tool.v1.execute.*.result` cannot match, because the segment counts differ,
which is the defense the router's name
validation backstops.

## Bus-Level Delivery Mechanics

Each `AstridEvent::Ipc` carries the topic in `IpcMessage::topic`. When `EventBus::publish` is
called, it does three things:

1. Broadcasts to the tokio `broadcast::Sender<Arc<AstridEvent>>` for all unfiltered subscribers.
2. Notifies the synchronous `SubscriberRegistry`.
3. Fans out to the per-(capsule, topic, principal) `routes` table via `dispatch_to_routes`.

The routes table is used by the per-principal IPC routing demux introduced to fix the concurrency
cliff at `N > buffer_capacity` principals. Each route entry holds its own bounded byte budget and
per-principal FIFO queues; the `RoutedEventReceiver` drains them with deficit-round-robin fairness.
For tool traffic specifically, the per-principal keying means a tool result for principal `alice`
will not head-of-line block a tool result for principal `bob` even if both are waiting on
`tool.v1.execute.result`.

The dispatcher side uses per-(capsule, principal) `mpsc` queues of depth 64. If a capsule's queue
is full, the event is dropped with a warning. There is no back-pressure to the publisher.

## The Router Is Stateless Middleware

`ToolRouter` in `capsules/astrid-capsule-router/src/lib.rs` carries no state: it derives
`Default` and holds no fields. Every call to `handle_execute_request` or `handle_execute_result`
is a pure transform of the incoming payload: validate, compute a topic, re-publish. If the
re-publish fails, the router publishes an error result on `tool.v1.execute.result` so the react
loop does not hang waiting for a result that will never arrive:

```rust
// capsules/astrid-capsule-router/src/lib.rs:94-106
fn publish_error_result(call_id: &str, error_message: String) -> Result<(), SysError> {
    ipc::publish_json(
        "tool.v1.execute.result",
        &IpcPayload::ToolExecuteResult {
            call_id: call_id.to_string(),
            result: ToolCallResult {
                call_id: call_id.to_string(),
                content: error_message,
                is_error: true,
            },
        },
    )
}
```

The router publishes on `tool.v1.execute.*` (wildcard) and `tool.v1.execute.result`, declared in
`[publish]`. The kernel's IPC publish ACL enforces that the router can only publish to these
topics. A router capsule cannot publish to `agent.v1.response` or any other topic outside its
declared publish surface.

## Cancellation

Cancellation is a separate signal rather than a cancellation of an in-flight interceptor call.
When the react loop receives a cancel request, it publishes `ToolCancelRequest` on
`tool.v1.request.cancel`:

```rust
// capsules/astrid-capsule-react/src/lib.rs:1198-1200
ipc::publish_json(
    "tool.v1.request.cancel",
    &IpcPayload::ToolCancelRequest { call_ids },
)
```

The host-level process tracker in the kernel listens on `tool.v1.request.cancel` and delivers
SIGINT (then SIGKILL) to any spawned child processes whose `call_id` matches. Tool capsules that
do not spawn host processes ignore the signal. There is no mechanism to interrupt a WASM guest
mid-execution once the interceptor call has started.

## Implementing a New Tool Capsule

A capsule that wants to handle the tool `my_tool`:

1. Declare a `[subscribe]` entry binding `tool.v1.execute.my_tool` to a handler function.
2. Declare a `[subscribe]` entry for `tool.v1.request.describe` with a handler that publishes
   the JSON schema on `tool.v1.response.describe.<source_id>`.
3. Declare `[publish]` entries for `tool.v1.execute.my_tool.result` and
   `tool.v1.response.describe.<source_id>`.
4. Mark tools that mutate state with `mutable = true` in `[[tool]]` entries so the approval
   layer can present the appropriate copy.

```toml
[subscribe]
"tool.v1.execute.my_tool" = { wit = "...", handler = "execute_my_tool" }
"tool.v1.request.describe" = { wit = "opaque", handler = "handle_describe" }

[publish]
"tool.v1.execute.my_tool.result" = { wit = "..." }
"tool.v1.response.describe.*" = { wit = "opaque" }
```

The kernel knows nothing about `my_tool`. It will deliver events to the capsule when the topic
matches, and the capsule will publish results when it is done. The only shared contract is the
`IpcPayload` enum and the topic naming convention described above.

## See also

- [Interceptors](interceptors.md)
- [Topics and Wildcards](topics-and-wildcards.md)
