# Topics and Wildcards

Every IPC message on the Astrid event bus carries a `topic` field. Topics are the routing key: they
determine which subscribers receive a message, whether an interceptor fires, and how the kernel
demultiplexes traffic. This page covers the naming convention, the two distinct wildcard systems,
the depth limit, the set of well-known system topics, and the two subscribe paths available to
capsule authors.

## Topic Naming Convention

Topics follow a `name.vN.kind` convention where segments are separated by `.`. By convention:

- The first segment is a namespace or subsystem (`astrid`, `agent`, `user`, `llm`, `tool`).
- The second segment is a version marker (`v1`).
- Remaining segments describe the operation or event kind, optionally with a recipient suffix.

Examples from the codebase:

```
user.v1.prompt                        # user input to the agent
agent.v1.response                     # final agent reply
agent.v1.stream.delta                 # incremental stream token
agent.v1.session_changed              # session metadata update
llm.v1.request                        # LLM provider request
llm.v1.response.chunk.anthropic       # per-provider streaming chunk
tool.v1.request.cancel                # cancel in-flight tool calls
astrid.v1.request.status              # daemon status request
astrid.v1.response.status             # daemon status reply
astrid.v1.request.shutdown            # graceful shutdown
astrid.v1.request.get_commands        # command palette query
astrid.v1.request.reload_capsules     # hot-reload signal
astrid.v1.capsules_loaded             # kernel capsule load notification
astrid.v1.audit.entry                 # audit stream (gateway SSE feed)
astrid.v1.watchdog.tick               # periodic bus-monitor heartbeat
astrid.v1.admin.<op>                  # kernel admin request (router prefix)
astrid.v1.admin.response.<op>         # kernel admin response
astrid.v1.approval                    # approval request from a capsule
astrid.v1.approval.response.<id>      # approval reply (request-correlated)
astrid.v1.elicit                      # interactive input request
astrid.v1.elicit.response.<id>        # elicit reply (request-correlated)
```

The `astrid.v1.approval.response.<id>` and `astrid.v1.elicit.response.<id>` topics embed an opaque
request UUID as the final segment, giving each round-trip a unique topic that the originating
capsule can subscribe to exactly once.

Topics must have no empty segments: no leading dot, trailing dot, or consecutive dots. The
`has_valid_segments` check in
`core/crates/astrid-capsule/src/topic.rs` enforces this at the capsule boundary.

## MAX\_TOPIC\_DEPTH

All topic matching enforces a hard cap of **20 dot-separated segments**. A topic that splits into
more than 20 segments is rejected as if it matched nothing. The constant is defined in two places:

```rust
// core/crates/astrid-events/src/route/matcher.rs:20
pub const MAX_TOPIC_DEPTH: usize = 20;

// core/crates/astrid-events/src/bus.rs (EventReceiver)
const MAX_TOPIC_DEPTH: usize = 20;
```

Both the broadcast path (`EventReceiver`) and the routed path (`TopicMatcher`) apply this check
independently. A capsule publishing a topic deeper than 20 segments will not reach any subscriber
regardless of its pattern.

## Two Distinct Wildcard Systems

Astrid has two separate topic-matching implementations with different semantics. Confusing them is a
known footgun.

### 1. EventReceiver (broadcast path)

Used by `EventBus::subscribe_topic` and `EventBus::subscribe_topic_as`. The receiver holds a
pattern and filters the broadcast channel on the receive side.

Matching is performed by `EventReceiver::matches` in
`core/crates/astrid-events/src/bus.rs`:

- **Exact match**: every segment matches and the segment count is equal.
  `"a.b.c"` matches `"a.b.c"` only.
- **Mid-segment `*`**: matches exactly one segment. `"a.*.c"` matches `"a.b.c"` and `"a.zz.c"` but
  not `"a.b.c.d"` (segment count must still be equal).
- **Trailing `*`** (namespace subscription): if the pattern ends with `.*`, the prefix must match
  segment-for-segment and the topic must have at least one additional segment after the prefix.
  `"a.b.*"` matches `"a.b.c"` and `"a.b.c.d"` but not `"a.b"`.

The trailing `.*` form is the only way to match across variable depth on this path. A pattern of
`"astrid.*"` matches any topic starting with `"astrid."` at any depth, regardless of segment count.

This path applies topic filtering **receive-side** after the event has already been broadcast to
the channel. Under a burst, a receiver with a narrow pattern still receives every event from the
shared broadcast buffer and discards non-matches in its loop, up to `YIELD_AFTER_SKIPPED = 32`
consecutive skips before yielding the async worker.

### 2. Interceptor matching (dispatcher path)

Used for `[subscribe]` handler patterns in `Capsule.toml` and for the kernel dispatcher that routes
events to WASM guests. The matching function is `topic_matches` in
`core/crates/astrid-capsule/src/topic.rs`:

```rust
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

Key differences from the broadcast path:

- **Segment count must be equal.** There is no trailing-`*` namespace match. A `*` in any position
  matches exactly one segment.
- **No trailing wildcard semantics.** `"a.b.*"` on this path matches `"a.b.x"` (three segments,
  three pattern segments) but does NOT match `"a.b.x.y"` (four segments versus three pattern
  segments).

The `TopicMatcher` compiled struct used by `subscribe_topic_routed` mirrors the broadcast-path
semantics, not the interceptor semantics. Its `matches` method in
`core/crates/astrid-events/src/route/matcher.rs` supports the trailing-`.*` namespace form.

### The footgun

A capsule author who writes an interceptor pattern of `"llm.v1.request.*"` expecting to catch all
LLM requests at any depth will receive events on `"llm.v1.request.generate"` (four segments, four
pattern segments) but will not receive `"llm.v1.response.chunk.anthropic"` even if they write
`"llm.v1.response.chunk.*"` and a message arrives on `"llm.v1.response.chunk.anthropic"` -- that
one does match. What will not match is any topic with more or fewer segments than the pattern.

The key rule: on the interceptor path, a trailing `*` is just a single-segment wildcard, not a
namespace prefix. On the broadcast and routed paths, a trailing `.*` is a namespace prefix that
matches one or more remaining segments.

Summary table:

| Context | `"a.b.*"` matches `"a.b.c"` | `"a.b.*"` matches `"a.b.c.d"` |
|---|---|---|
| `subscribe_topic` / `subscribe_topic_routed` | yes | yes (trailing-`.*` = 1+ segments) |
| `[subscribe]` handler / `topic_matches` | yes (3 == 3 segs, `*` matches `c`) | no (3 != 4 segs) |

## The Two Subscribe Paths

### Broadcast path: `subscribe_topic` / `subscribe_topic_as`

```rust
// EventBus methods, core/crates/astrid-events/src/bus.rs
pub fn subscribe_topic(&self, topic_pattern: impl Into<String>) -> EventReceiver
pub fn subscribe_topic_as(&self, topic_pattern: impl Into<String>, subscriber: &'static str) -> EventReceiver
```

Both return an `EventReceiver` that wraps a `tokio::sync::broadcast::Receiver`. Every event is
broadcast to every `EventReceiver` subscriber; the pattern is applied as a receive-side filter. The
broadcast channel has a fixed capacity (default 1024). When a receiver falls too far behind, it
receives a `Lagged(n)` error, events are dropped, and the lag counter
`astrid_bus_receiver_lagged_total{subscriber}` is incremented.

Use `subscribe_topic_as` for long-lived consumers so lag is attributed to a stable label rather
than `"untagged"`. The `subscriber` argument must be a `&'static str` to bound metric cardinality.

Non-IPC events (`RuntimeStarted`, `AgentStarted`, and so on) are always filtered out by a
topic-filtered `EventReceiver` regardless of pattern.

### Routed path: `subscribe_topic_routed`

```rust
// EventBus method, core/crates/astrid-events/src/bus.rs
pub fn subscribe_topic_routed(
    &self,
    capsule_uuid: Uuid,
    topic_pattern: impl Into<String>,
    capsule_id_label: impl Into<String>,
    subscriber: &'static str,
) -> RoutedEventReceiver
```

This path was added to address bus backpressure under high principal fan-in (issue #813). Instead
of sharing the broadcast channel, `subscribe_topic_routed` allocates a dedicated `RouteEntry` in
the bus's `routes` table. Each matching publish enqueues the event into the entry's
per-principal sub-queue using publish-side fan-out.

Key properties:

- Each `RoutedEventReceiver` receives its own copy of every matching event. Two receivers with
  different `capsule_uuid` values on the same pattern each get the full message set independently.
- Fan-out is per-principal. Traffic from `principal = "alice"` and `principal = "bob"` lands in
  separate sub-queues. Deficit-round-robin drain ensures no single principal starves another.
- The byte budget for the entire entry is `MAX_SUBSCRIPTION_BUDGET_BYTES = 1 MiB`
  (`core/crates/astrid-events/src/route/entry.rs:19`). When the budget is exhausted, the oldest
  head across all sub-queues is evicted. A message larger than the budget is rejected outright with
  an audit log entry.
- A per-bucket fallback cap of 256 messages (`PENDING_PER_PRINCIPAL_FALLBACK`) bounds the
  sub-queue length when a flood of near-zero-byte messages would otherwise fill a bucket without
  triggering the byte budget.
- Dropping the `RoutedEventReceiver` removes its `RouteEntry` from the bus automatically (via
  `Drop`).

`RoutedEventReceiver::recv` parks the calling task until a matching event arrives or an optional
timeout expires. `RoutedEventReceiver::try_drain` is a non-blocking batch drain for polling
contexts such as the gateway's saturation alarm path.

Topic patterns on the routed path use `TopicMatcher` which has the same wildcard semantics as the
broadcast path (trailing `.*` is a namespace prefix, mid-segment `*` is a single-segment
wildcard). The routed path does not carry broadcast lag because each receiver owns its queue:
pressure manifests as byte-budget eviction on the publish side, not as a shared channel overflow.

## Pattern Validity

In both systems, a topic or pattern is rejected if it contains empty segments. Specifically, the
string must be non-empty and every segment produced by splitting on `.` must be non-empty. This
rejects:

- Empty string (`""`)
- Leading dot (`".a.b"`)
- Trailing dot (`"a.b."`)
- Consecutive dots (`"a..b"`)

The interceptor path validates both the incoming topic and the pattern in `has_valid_segments`
before any segment comparison. The broadcast and routed paths check segment count (derived from
`split('.')`) but do not separately call `has_valid_segments`; topics with empty segments will
produce a segment count that does not match any valid pattern and so fall through to no match.

## Non-IPC Events and Topic Filters

Topic-filtered subscribers only match `AstridEvent::Ipc` messages. All other variants
(`AstridEvent::RuntimeStarted`, `AstridEvent::CapsuleLoaded`, and so on) are silently discarded by
any subscriber that has a topic pattern set. To receive lifecycle events, use `subscribe` or
`subscribe_as` (no pattern), then dispatch on `event_type()` in the handler.

The `event_type()` values for lifecycle events follow a `astrid.v1.lifecycle.<name>` scheme as
string constants (for example, `"astrid.v1.lifecycle.runtime_started"`). These are not IPC topics
and are not routable on the IPC bus. They exist only on the Rust side for telemetry labelling and
are not visible to WASM capsules as topic strings.

## See also

- [Interceptors](interceptors.md)
- [Tools as an IPC Convention](tools-as-ipc.md)
- [Per-Principal Routing and Backpressure](routing-and-backpressure.md)
