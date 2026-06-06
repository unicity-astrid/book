# Per-Principal Routing and Backpressure

The event bus provides two subscription models. The first is a `tokio::sync::broadcast` channel that every `EventReceiver` shares. The second is a publish-side demux that fans events into per-principal FIFO queues before any broadcast back-pressure can occur. This page covers the second model in full, including the fairness scheduler, the byte-budget eviction policy, and the dispatcher's own queue layer that sits downstream.

The structural motivation is issue #813: before the routed path existed, a cross-principal burst of N distinct agents collapsed into the single 1024-slot broadcast ring. When N exceeded the available head room, the ring shed events and per-receiver post-filtering made the truncation unpredictable across principals. The publish-side demux fixes the root cause rather than widening the ring.

## Subscription Topology

```text
EventBus::publish()
  |
  +--> broadcast::Sender (shared ring, cap = DEFAULT_CHANNEL_CAPACITY = 1024)
  |      all EventReceiver handles share this ring
  |
  +--> routes: RwLock<HashMap<RouteKey, Mutex<RouteEntry>>>
         one RouteEntry per subscribe_topic_routed() call
         RouteEntry { matcher, fanout: HashMap<PrincipalKey, PrincipalQueue>, ... }
                                             per-principal FIFO sub-queues
```

`EventBus` is clone-safe. All clones share the same `broadcast::Sender`, `routes` table, `SubscriberRegistry`, and IPC sequence counter through `Arc` handles, so a routed subscription created via one clone is visible to every publisher that holds any clone of the bus.

Sources: `core/crates/astrid-events/src/bus.rs:57-76`, `bus.rs:342-357`.

## The Broadcast Path and EventReceiver

`EventBus::subscribe()` and `EventBus::subscribe_topic()` both return an `EventReceiver`. Internally `EventReceiver` holds a `broadcast::Receiver` and, optionally, a topic pattern. Receiving is poll-based: `recv()` loops on `broadcast::recv().await` and applies the pattern filter client-side.

The broadcast channel has a fixed capacity of `DEFAULT_CHANNEL_CAPACITY = 1024` events (`bus.rs:17`). When a slow receiver falls behind the sender, Tokio's broadcast channel skips the receiver ahead to the oldest available entry and returns `RecvError::Lagged(count)`. `EventReceiver` handles this case at `bus.rs:479-497`:

```rust
Err(broadcast::error::RecvError::Lagged(count)) => {
    tracing::error!(
        target: "astrid.bus", security_event = true,
        skipped = count, subscriber = self.subscriber,
        "Event receiver lagged, events dropped"
    );
    self.lagged_count = self.lagged_count.saturating_add(count);
    metrics::counter!(METRIC_BUS_RECEIVER_LAGGED_TOTAL, "subscriber" => self.subscriber)
        .increment(count);
    tokio::task::yield_now().await;
    skipped = 0;
}
```

The yield before catching up prevents the catch-up loop from monopolizing a Tokio worker at the worst possible moment, when the channel is already under storm conditions.

**Worker monopolization guard.** A topic-filtered receiver draining a backlogged broadcast ring calls `broadcast::recv` synchronously on buffered items. Without a yield point this can hold a worker for as long as the backlog lasts. The implementation bounds this with `YIELD_AFTER_SKIPPED = 32` (`bus.rs:27`): after every 32 consecutive non-matching events the receiver calls `tokio::task::yield_now()`. The constant is kept small to cap monopolization but not set to 1, which would slow backlog drain enough to cause self-induced lag.

**Subscriber labels.** Each receiver is tagged with a `&'static str` label supplied at subscription time. The lag counter uses this label so the `astrid_bus_receiver_lagged_total` metric's `subscriber` dimension stays at bounded cardinality. Code-assigned labels include `"capsule_dispatcher"` for the dispatcher's own receiver. Receivers created without an explicit tag collapse to `"untagged"`. Passing capsule-supplied strings as labels is prohibited for this reason (`bus.rs:43-44`).

**Metrics.**
- `astrid_bus_events_published_total` - counter, labelled by `event_kind` (the `&'static str` from `AstridEvent::event_type()`). IPC traffic collapses to `"ipc"`.
- `astrid_bus_receiver_lagged_total` - counter, labelled by `subscriber`. A non-zero rate on any subscriber is the signature of a feedback storm.

## Routed Subscriptions and RoutedEventReceiver

`EventBus::subscribe_topic_routed()` is the per-principal isolation API. It allocates a `RouteEntry` in the `routes` table and returns a `RoutedEventReceiver` that drains it.

```rust
pub fn subscribe_topic_routed(
    &self,
    capsule_uuid: uuid::Uuid,
    topic_pattern: impl Into<String>,
    capsule_id_label: impl Into<String>,
    subscriber: &'static str,
) -> RoutedEventReceiver
```

The `RouteKey` identifying the entry is `(capsule_uuid, topic_pattern, subscription_rep)` where `subscription_rep` is a monotonically incrementing `u64` unique per bus instance (`route/entry.rs:49-58`, `entry.rs:360-370`). Two subscriptions with the same `capsule_uuid` and `topic_pattern` get distinct keys and therefore distinct `RouteEntry` instances. Each receives its own copy of every matching event, unlike the broadcast channel where all handles share one ring.

On drop, `RoutedEventReceiver` removes its key from the `routes` table (`route/receiver.rs:110-115`). This is the only deallocation path; entries do not time out independently.

## Publish-Side Fan-Out: dispatch_to_routes

Every `EventBus::publish()` call ends with `dispatch_to_routes(&event)` after the broadcast send (`bus.rs:146`). The ordering is deliberate: broadcast goes first so a slow per-route enqueue can never delay untargeted consumers such as `kernel_router`, `admin_router`, and `bus_monitor`.

`dispatch_to_routes` holds the `routes` read-lock only long enough to collect the `Arc<Mutex<RouteEntry>>` handles for matching routes, then releases it before doing any per-route work (`bus.rs:156-206`):

```rust
fn dispatch_to_routes(&self, event: &Arc<AstridEvent>) {
    let matched: Vec<(RouteKey, Arc<parking_lot::Mutex<RouteEntry>>)> = {
        let routes = self.routes.read();
        // collect matching Arcs, release lock
        routes.iter()
            .filter_map(|(k, e)| {
                let entry = e.lock();
                if entry.matcher.matches(event) { drop(entry); Some((k.clone(), Arc::clone(e))) }
                else { None }
            })
            .collect()
    }; // read lock released here

    for (_key, entry_arc) in matched {
        let mut entry = entry_arc.lock();
        entry.push_with_eviction(Arc::clone(event), principal, MAX_SUBSCRIPTION_BUDGET_BYTES);
        let notify = Arc::clone(&entry.notify);
        drop(entry); // release before notify so wake does not race the lock
        notify.notify_one();
    }
}
```

The `parking_lot::RwLock` is used instead of `tokio::sync::RwLock` because `publish()` is synchronous. A `tokio` lock would require the entire `SubscriberRegistry::notify` reentrant path to become async.

`PrincipalKey` is extracted from the IPC message's `principal` field (`bus.rs:188-191`). Non-IPC events use `PrincipalKey = None` (the system principal bucket).

## Topic Matching

Both `EventReceiver` (broadcast path) and `TopicMatcher` (routed path) implement the same pattern grammar so the two paths agree on what each subscription covers:

- **Exact match**: `a.b.c` matches only `a.b.c`. Segment counts must be equal.
- **Trailing wildcard**: `a.b.*` matches any topic that begins with `a.b.` and has at least one additional segment. This is a namespace subscription.
- **Mid-segment wildcard**: `a.*.c` matches exactly one segment in the middle position. Segment count must still be equal.
- **Depth limit**: topics with more than 20 dot-separated segments are rejected by both matchers. This is a DoS guard against unbounded split allocations.

Sources: `bus.rs:403-447` (broadcast path), `route/matcher.rs:34-72` (routed path).

`ipc_size_of` computes the byte cost charged against budgets (`route/matcher.rs:82-91`). It sums the serialized JSON length of `IpcPayload` and the topic string length. Non-IPC events fall back to a flat 64-byte constant. Charging payload bytes rather than `Arc<AstridEvent>` size means a flood of 1-byte payloads does not masquerade as a zero-byte stream.

## RouteEntry: Per-Principal Fan-Out

Each `RouteEntry` holds a `HashMap<PrincipalKey, PrincipalQueue>` (`fanout`) and a `VecDeque<PrincipalKey>` (`principal_order`) for DRR rotation (`route/entry.rs:91-106`):

```rust
pub(crate) struct RouteEntry {
    pub(crate) matcher: TopicMatcher,
    pub(crate) fanout: HashMap<PrincipalKey, PrincipalQueue>,
    pub(crate) principal_order: VecDeque<PrincipalKey>,
    pub(crate) total_bytes: usize,
    pub(crate) capsule_id_label: String,
    pub(crate) notify: Arc<Notify>,
}
```

`PrincipalQueue` tracks the FIFO queue, the byte sum for that bucket, the enqueue timestamp of the current head (used for eviction ordering), and the DRR deficit (`entry.rs:65-86`).

Principal sub-queues are demand-allocated: `fanout.entry(principal).or_insert_with(PrincipalQueue::new)` only on the first event for that principal. An idle principal has zero entries. The test `routed_5000_principals_demand_allocate` verifies 5000 distinct principals each produce exactly one entry, then drain completely in one `drr_drain` call (`bus_tests.rs:736-751`).

## Byte-Budget Eviction

`push_with_eviction` is the admission control gate for every event entering a route. The total budget across all sub-queues is `MAX_SUBSCRIPTION_BUDGET_BYTES = 1024 * 1024` (1 MiB). This matches the per-call IPC payload ceiling so any single message always fits within one budget (`entry.rs:19`).

The algorithm in `entry.rs:124-213`:

1. If `msg_size > budget_bytes` the message exceeds the budget outright. It is rejected rather than evicting everything else. The capsule label and principal are logged as a security event and `METRIC_ROUTE_BYTE_EVICTIONS_TOTAL` is incremented.

2. Otherwise, while `total_bytes + msg_size > budget_bytes`, call `evict_oldest_head()`.

3. Enqueue the message into the principal's bucket. If the bucket is new, append `principal` to `principal_order`.

4. After enqueueing, apply the per-principal fallback cap: if `bucket.queue.len() > PENDING_PER_PRINCIPAL_FALLBACK` (256), pop the front and update accounting. This cap exists as defence-in-depth against a flood of zero-or-near-zero-byte payloads that slip past the byte budget (`entry.rs:29-30`).

`evict_oldest_head` finds the bucket whose `head_enqueued_at` is minimum via a linear scan of `fanout` and pops its front element (`entry.rs:217-262`). The eviction preserves streaming response terminators by construction: a terminator is always the tail of its principal's queue, so head-eviction trims the prefix, not the tail.

The linear scan is O(N) in the number of active principals. The code comment at `entry.rs:265-267` notes that a `BTreeMap<Instant, PrincipalKey>` head-age index is the follow-up if benchmarks show the scan is a hot spot.

Both eviction paths (budget overflow and per-principal cap) emit to `astrid_capsule_route_byte_evictions_total` labelled by `capsule` and `principal_class`. `principal_class_label` maps `None` to `"system"`, strings starting with `"agent."` or `"agent:"` to `"agent"`, and everything else to `"user"` (`route/matcher.rs:97-103`).

## Deficit Round-Robin Drain

`drr_drain` services `principal_order` in rotation, giving each bucket a quantum of bytes per round (`entry.rs:280-352`):

```rust
let quantum = std::cmp::max(
    DRR_QUANTUM_MIN_BYTES,
    budget.checked_div(total).unwrap_or(0),
);
```

`DRR_QUANTUM_MIN_BYTES = 4096` bytes (`entry.rs:25`). The floor ensures every principal makes progress even at extreme fanout. At 5000 active principals the floor gives a theoretical 20 MiB of per-round throughput, which is well above the 1 MiB total budget, so a single round always drains at least one message per principal when payloads are small enough to fit under the quantum.

Each visit adds `quantum` to `bucket.deficit`. The bucket may then emit as many consecutive messages as fit under the accumulated deficit and the remaining round budget. After each message, `bucket.deficit` decreases by that message's size. If the queue head is larger than the deficit after the quantum add, the bucket is starved for this round: `METRIC_ROUTE_QUANTUM_STARVED_TOTAL` is incremented and the bucket is pushed to the back of `principal_order` for next round (`entry.rs:330-337`). An empty bucket is removed from both `fanout` and `principal_order`.

The outer loop exits when no bucket made progress in a full visit (`!progress`) or the round budget is consumed (`served >= budget`).

`RoutedEventReceiver::recv` drains via a fast/slow path split (`route/receiver.rs:44-71`):

```rust
pub async fn recv(&mut self, timeout: Option<std::time::Duration>) -> Option<Arc<AstridEvent>> {
    loop {
        {
            let mut out = Vec::with_capacity(1);
            let mut entry = self.route_entry.lock();
            let _ = entry.drr_drain(&mut out, MAX_SUBSCRIPTION_BUDGET_BYTES);
            if let Some(first) = out.into_iter().next() {
                return Some(first);
            }
        }
        // park on Notify or timeout
        match timeout {
            Some(dur) => { if tokio::time::timeout(dur, self.notify.notified()).await.is_err() { return None; } },
            None => { self.notify.notified().await; },
        }
    }
}
```

`try_drain` is the non-blocking variant. It takes a byte budget parameter rather than always using `MAX_SUBSCRIPTION_BUDGET_BYTES`, which is useful for a gateway poll path that wants to bound its per-call work (`route/receiver.rs:75-80`).

**Route-level metrics.**
- `astrid_capsule_route_active_principals` - gauge, labelled by `capsule`. Active sub-queue count.
- `astrid_capsule_route_budget_bytes_in_use` - gauge, labelled by `capsule`. Current `total_bytes`.
- `astrid_capsule_route_byte_evictions_total` - counter, labelled by `capsule` and `principal_class`.
- `astrid_capsule_route_quantum_starved_total` - counter, labelled by `capsule` and `principal_class`. Diagnostic: indicates sustained back-pressure where a principal's queue head is too large to fit in one DRR quantum.

## IPC Rate Limiter

`IpcRateLimiter` operates upstream of the bus, on the publish path, before events enter either the broadcast ring or the routed demux. It lives in `core/crates/astrid-events/src/rate_limiter.rs`.

Buckets are keyed by `(capsule_uuid, PrincipalId)` (`rate_limiter.rs:16`). The two-part key isolates principals from one another on the same capsule: Alice filling her bucket does not consume Bob's budget even when both are active on capsule X. Equally, the same principal on two different capsules has independent buckets.

```rust
pub fn check_quota(
    &self,
    capsule_uuid: Uuid,
    principal: &PrincipalId,
    size_bytes: usize,
    max_throughput_bytes_per_sec: usize,
) -> Result<(), String>
```

Each bucket holds `(window_start: Instant, bytes_sent: usize)`. When the window is older than 1 second, it resets. `check_quota` rejects the call if `bytes_sent + size_bytes > max_throughput_bytes_per_sec`.

Before any window check, `check_quota` applies a hard payload ceiling: `MAX_IPC_PAYLOAD_BYTES = 5 * 1024 * 1024` (5 MiB). This is a DoS guard, not a per-principal dial. It is hardcoded so a malformed or privileged profile cannot raise it (`rate_limiter.rs:23-24`).

Stale entries are pruned lazily: when `state.len() > 1000` and more than 60 seconds have elapsed since the last prune, all entries with a window older than 1 second are removed. The prune acquires `last_prune` via `try_lock` to avoid blocking concurrent `check_quota` calls under contention (`rate_limiter.rs:72-79`).

The `max_throughput_bytes_per_sec` ceiling is caller-supplied from `PrincipalProfile::quotas::max_ipc_throughput_bytes`. The rate limiter does not enforce a default; the caller decides the ceiling per principal.

## Dispatcher Queue Layer

The `EventDispatcher` in `core/crates/astrid-capsule/src/dispatcher.rs` subscribes to the broadcast channel as `"capsule_dispatcher"` and routes matching events to WASM capsule interceptors. It adds a third layer of per-principal queuing downstream of the bus.

The dispatcher maintains `CapsuleQueues`: a `parking_lot::Mutex<HashMap<(CapsuleId, PrincipalKey), mpsc::Sender<InterceptorWork>>>`. Each entry is backed by a `tokio::sync::mpsc` channel of capacity `CAPSULE_EVENT_QUEUE_CAPACITY = 64` (`dispatcher.rs:50`). Consumer tasks are spawned on demand and idle-evict themselves after `DEFAULT_IDLE_CONSUMER_GRACE_MS = 60_000` ms of inactivity.

**Per-capsule principal cap.** The dispatcher enforces `MAX_DISPATCHER_QUEUES_PER_CAPSULE = 10_000` sender slots per capsule (`dispatcher.rs:57`). When a new principal would push the count over this limit, the dispatcher degrades to the shared `(capsule, PrincipalKey::None)` slot and logs a security event on `astrid.audit.ipc`. This bounds the dispatcher's queue map under pathological N-principal storms: `10_000 principals × 16 capsules × 64 slots` stays under the half-gigabyte ceiling noted in the design's risk register.

**Drop policy.** When the per-(capsule, principal) mpsc queue is full, `dispatch_single` calls `try_send` and logs a warning on failure (`dispatcher.rs:722-728`). Events are dropped rather than blocking the dispatcher loop. The 64-slot capacity is sized for per-principal traffic where the working set is much smaller than the former per-class queue.

**Idle eviction.** A consumer task times out after the grace window and attempts to evict itself. The eviction is safe only when `rx.try_recv()` is empty AND `rx.sender_strong_count() == 1`: the map holds exactly one sender, so a count of 1 proves no in-flight dispatch task holds a clone. Any clone bumps the count to 2 or more and the consumer keeps running, delaying eviction by at most one grace window rather than losing an event (`dispatcher.rs:679-694`).

**Chain locks.** For multi-interceptor chains the dispatcher uses a `ChainLocks` map keyed by `(CapsuleId, PrincipalKey)`. A `tokio::sync::Mutex` per key serializes chain dispatches for the same principal on the same capsule (FIFO), while distinct principals run concurrently. `ChainLockGuard` prunes its map entry on drop when `Arc::strong_count == 2` (map plus the guard's own clone), so the lock map stays bounded under high principal churn (`dispatcher.rs:107-169`).

## Putting the Layers Together

A single IPC publish traverses four distinct admission and fairness gates:

| Layer | Location | Mechanism | Drop behavior |
|-------|----------|-----------|---------------|
| IPC rate limiter | `astrid-events/src/rate_limiter.rs` | Token bucket per `(capsule, principal)`, 1-second window | `Err` returned to caller; event never reaches bus |
| Broadcast ring | `astrid-events/src/bus.rs` | `tokio::sync::broadcast`, cap 1024 | Receiver skips ahead; `Lagged(N)` error |
| Routed demux | `astrid-events/src/route/entry.rs` | Per-principal FIFO, DRR drain, byte-budget eviction | Oldest head evicted; metric incremented |
| Dispatcher mpsc | `astrid-capsule/src/dispatcher.rs` | Per-`(capsule, principal)` mpsc, cap 64 | `try_send` fails silently with a warning |

The routed demux is the primary mechanism for cross-principal fairness and back-pressure isolation. The broadcast ring is retained for untargeted consumers (kernel-internal routers and monitors) that do not need principal isolation. The dispatcher mpsc provides ordered delivery into WASM invocations without blocking the dispatcher loop. The IPC rate limiter is the upstream DoS guard that prevents any single principal from saturating any downstream layer.

## See also

- [Topics and Wildcards](topics-and-wildcards.md)
- [PrincipalId and Per-Invocation Isolation](../identity/principal-and-isolation.md)
