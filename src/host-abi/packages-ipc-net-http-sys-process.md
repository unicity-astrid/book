# Host Packages: IPC, Net, HTTP, Sys, Process

Astrid's host ABI is split into per-domain WIT packages, each frozen at a semantic version. The kernel exposes zero `wasi:*` interfaces. Every host call is gated by the capability layer, attributed to a principal, and auditable. This page covers the five packages that handle inter-capsule messaging, external networking, HTTP, system primitives, and child-process spawning.

All WIT files live in the `unicity-astrid/wit` repository at `wit/host/<pkg>@1.0.0.wit`. The `astrid-sys` crate generates typed guest bindings from those files via `wit_bindgen::generate!`. The `astrid-sdk` crate wraps those bindings behind an ergonomic API that mirrors `std` conventions where applicable.

---

## astrid:ipc

**Source:** `wit/host/ipc@1.0.0.wit`
**SDK module:** `astrid_sdk::ipc`

The event bus. Capsules communicate exclusively through topic-based publish and subscribe. The kernel routes events; it never interprets payload content. No capsule holds a direct reference to another capsule.

### Topics

Topics are dot-delimited strings: segments match `[a-z0-9._-]+`, up to 8 segments, up to 256 bytes total. The host rejects anything outside that grammar with `invalid-input`. Wildcards in subscriptions are trailing-suffix only: `foo.bar.*` is valid; `foo.*.bar` is not.

### Capability gating

Publishing requires a `[publish]` table key matching the target topic; subscribing requires a `[subscribe]` key. Each entry pairs the topic with a WIT payload reference, or `"opaque"` for a capsule that forwards bytes whose schema it does not own. The CLI capsule, which bridges the Unix-domain uplink, is the canonical opaque example (partial listing):

```toml
[capabilities]
uplink = true
net_bind = ["unix:*"]

[publish]
"user.v1.prompt"         = { wit = "opaque" }
"client.v1.connect"      = { wit = "opaque" }
"cli.v1.command.execute" = { wit = "opaque" }
"astrid.v1.request.*"    = { wit = "opaque" }

[subscribe]
"agent.v1.response"      = { wit = "opaque" }
"agent.v1.stream.delta"  = { wit = "opaque" }
"astrid.v1.approval"     = { wit = "opaque" }
```

(Source: `capsules/astrid-capsule-cli/Capsule.toml`, abbreviated. Every topic the uplink relays is declared `wit = "opaque"`, because it forwards payloads it does not define.)

### Principal attribution

Every message carries a `principal-attribution` variant. This is the central trust signal for sensitive actions.

```wit
variant principal-attribution {
    verified(string),  // kernel-verified from invocation context
    claimed(string),   // uplink-asserted via publish-as, NOT kernel-verified
    system,            // kernel-originated lifecycle event
}
```

The `claimed` variant exists because uplink capsules (those with `uplink = true`) call `publish-as` on behalf of authenticated users: the kernel trusts that the uplink verified the authentication, but it does not re-verify itself. Downstream capsules processing sensitive actions MUST check `principal-attribution` per message, not once per batch. The `verified` variant is safe for capability checks; `claimed` is caller-supplied input.

The SDK mirrors this as `PrincipalAttribution` with a `verified()` accessor:

```rust
use astrid_sdk::ipc::{self, PrincipalAttribution};

let sub = ipc::subscribe("tool.v1.execute.run_shell_command")?;
let poll = sub.recv(30_000)?;
for msg in poll.messages {
    match &msg.principal {
        PrincipalAttribution::Verified(p) => { /* safe for authz */ }
        PrincipalAttribution::Claimed(p) => { /* treat as user input */ }
        PrincipalAttribution::System => { /* kernel lifecycle */ }
    }
}
```

### Subscription resource

The WIT `subscription` is a resource: creating one allocates a kernel-side handle; dropping it tears down the subscription. The SDK wraps this in `Subscription`. Capsules do not call an unsubscribe function.

Per-capsule cap: **128 subscriptions**. Attempting to exceed returns `quota`.

```wit
resource subscription {
    poll: func() -> result<ipc-envelope, error-code>;
    recv: func(timeout-ms: u64) -> result<ipc-envelope, error-code>;
    subscribe-readiness: func() -> pollable;
}
```

`poll` is non-blocking; it returns whatever is queued. `recv` blocks up to `timeout-ms` (host-capped at 60,000 ms). `subscribe-readiness` yields a `pollable` that can be composed with other pollables via `astrid:io/poll.poll` for capsules multiplexing IPC with network or process events.

The envelope carries lag and drop counters in addition to the message list:

```wit
record ipc-envelope {
    messages: list<ipc-message>,
    dropped: u64,   // messages lost to buffer overflow
    lagged: u64,    // cumulative missed messages (slow consumer)
}
```

### Publishing

`publish` attributes the message as `verified` from the calling capsule's invocation context. The call is asynchronous: subscribers receive the message on their next `recv`/`poll`, not synchronously within the publish call. A per-invocation publish-depth budget (default 8) prevents unbounded re-entry from interceptors publishing back to themselves. Fan-out caps at 256 matching subscribers; further matches are counted as dropped.

```rust
use astrid_sdk::ipc;
use serde::Serialize;

#[derive(Serialize)]
struct ToolResult { success: bool, output: String }

ipc::publish_json("tool.v1.execute.run_shell_command.result", &ToolResult {
    success: true,
    output: "hello".into(),
})?;
```

`publish_as` is restricted to capsules with `uplink = true`. Subscribers see the principal as `claimed(...)`.

### Request-response helper

`ipc::request_response` implements the correlation-ID handshake that is the conventional cross-capsule RPC pattern:

1. Generate a v4 UUID.
2. Subscribe to `{response_namespace}.{correlation_id}` before publishing (prevents a race).
3. Inject `"correlation_id"` into the JSON request object.
4. Publish the request.
5. Block up to `timeout_ms` for the reply.
6. Deserialize the response, then drop the subscription.

The request payload must serialize to a JSON object (not a primitive or array) so there is a field to inject the correlation ID into. The check runs before any host call.

```rust
#[derive(Serialize)]
struct SetModelRequest { model_id: String }

#[derive(Deserialize)]
struct SetModelResponse { ok: bool }

let resp: SetModelResponse = ipc::request_response(
    "registry.v1.set_active_model",
    "registry.v1.response.set_active_model",
    &SetModelRequest { model_id: "gpt-5.4".into() },
    5_000,
)?;
```

### Interceptors and get-interceptor-bindings

Run-loop capsules can declare `[subscribe]` handler entries in `Capsule.toml`. The host auto-subscribes the capsule to those topics. `get-interceptor-bindings` returns only the calling capsule's own bindings, not a registry of other capsules' bindings.

---

## astrid:net

**Source:** `wit/host/net@1.0.0.wit`
**SDK module:** `astrid_sdk::net`

Unix-domain sockets, inbound TCP listeners, outbound TCP, UDP, and DNS resolution.

### SSRF airlock

DNS resolution runs host-side before any connect. Addresses in private (`10.0.0.0/8`, `192.168.0.0/16`, `172.16.0.0/12`), loopback (`127.0.0.0/8`, `::1`), link-local, multicast, and unspecified ranges are rejected with `airlock-rejected`. IPv4-mapped IPv6 addresses are also checked. The WASM guest never sees the resolved IP. An empty result from `lookup-host` means all candidates were filtered.

### Capability keys

| Manifest key | Controls |
|---|---|
| `net_connect` | Outbound TCP (`connect-tcp`) and DNS resolution |
| `net_tcp_bind` | Inbound TCP listener (`bind-tcp`) |
| `net_udp` | UDP socket (`udp-bind`) and DNS for UDP peers |
| `net_bind` | Pre-provisioned Unix-domain listener (`bind-unix`) |

Values are hostname patterns or address patterns. A pattern of `"*"` permits all hosts. The HTTP capsule and OpenAI-compat capsule use `net = ["*"]` in their manifests. The system capsule does not have a net capability. Capsules that should only call specific APIs should restrict further.

Per-capsule limits: **8 concurrent TCP streams**, **4 TCP listeners**, **4 UDP sockets**.

### Unix-domain listener

The kernel pre-binds a Unix socket per capsule at load time. The capsule activates it by calling `bind-unix`. Accepted connections perform a UID-match peer credential check and a session token handshake before the handle is returned. This is how uplink capsules receive CLI connections.

```rust
use astrid_sdk::net;

let listener = net::bind_unix()?;
loop {
    let stream = listener.accept()?; // blocks until connection + handshake
    // stream is TcpStream, shared type for both Unix and TCP
    let frame = stream.recv()?;      // blocking framed read
    stream.send(b"ack")?;
}
```

`try_accept(timeout_ms)` is the polling variant. The listener also exposes `subscribe-readiness` for poll-based multiplexing.

### Inbound TCP listener

`bind-tcp` creates a `tcp-listener` for network-facing endpoints: webhooks, Prometheus scrape ports, gRPC servers. Distinct from the Unix listener, gated by `net_tcp_bind`.

```rust
let listener = net::bind_tcp("127.0.0.1", 9090)?;
println!("listening on {}", listener.local_addr()?);
loop {
    let conn = listener.accept()?;
    // handle conn as TcpStream
}
```

Port `0` requests an ephemeral port. The address `"0.0.0.0"` exposes the listener on every interface; restrict to loopback for local-only services.

### Outbound TCP

`connect` opens a TCP connection through the SSRF airlock. The SDK's `TcpStream::connect` accepts a `"host:port"` string and handles IPv6 bracket-stripping internally.

```rust
use astrid_sdk::net::TcpStream;

let mut stream = TcpStream::connect("api.example.com:443")?;
// TcpStream implements std::io::Read + std::io::Write
stream.write_all(b"GET / HTTP/1.0\r\n\r\n")?;
```

`TcpStream` is the shared type for both Unix-domain accepted connections and outbound TCP. TCP-only socket options (`set_nodelay`, `set_keepalive`, `set_hop_limit`, `set_linger`, `set_reuseaddr`) return a `HostError("NotTcp")` on Unix-domain streams.

Two I/O modes exist on the same stream. Use one per call site:

- **Length-prefixed framing** (`read`/`write`, `recv`/`send`) for the uplink-proxy protocol and structured capsule-to-capsule local transport.
- **Raw byte stream** (`read_bytes`/`write_bytes`, `peek`, `std::io::Read`/`Write`) for standard protocols (HTTP/1.1, gRPC, SSH, raw TLS).

The stream also exposes `read-stream` and `write-stream` as `input-stream`/`output-stream` pairs for `splice`-based byte forwarding that moves data host-side without crossing the WASM boundary per byte.

### UDP socket

`udp_bind` creates a datagram socket in one of two modes:

- **Unconnected** (default): use `send_to`/`recv_from` with a peer address on every call. The SSRF airlock runs per call.
- **Connected** (after `connect`): lock to a single peer. The airlock runs once at connect time. Use `send`/`recv` for the faster per-call path. `disconnect` reverts to unconnected.

```rust
use astrid_sdk::net;

let sock = net::udp_bind("127.0.0.1", 0)?;
sock.send_to(b"ping", "1.1.1.1", 53)?;
if let Some(dg) = sock.recv_from(512)? {
    // dg.data, dg.peer_host, dg.peer_port
}
```

Bind addresses other than loopback expose the socket to external peers. Restrict `net_udp` patterns to `"bind:127.0.0.1:*"` unless the capsule genuinely needs to serve inbound datagrams from the network.

### DNS

`lookup_host` resolves a hostname and returns a list of `"ip:port"` (or `"ip"`) strings. The SSRF airlock filters the result; an empty list means all resolved addresses were in a blocked range. Requires a `net_connect` or `net_udp` capability matching the hostname.

---

## astrid:http

**Source:** `wit/host/http@1.0.0.wit`
**SDK module:** `astrid_sdk::http`

Outbound HTTP with SSRF protection. Distinct from `astrid:net` because the host implements the HTTP protocol layer including TLS, redirect following, and header normalization.

The same SSRF airlock as `astrid:net` applies: DNS resolution blocks private/loopback/link-local/multicast/unspecified ranges. IPv4-mapped IPv6 addresses are also checked. Requires the `net` capability in `Capsule.toml`.

The HTTP capsule and OpenAI-compat capsule both use `net = ["*"]`:

```toml
[capabilities]
net = ["*"]
```

### Buffered requests

`http-request` sends a complete request and returns the full response in memory. Timeout: 30 seconds. Body cap: 10 MB. The audit log records URL host, method, and status; payload bytes are not logged.

```rust
use astrid_sdk::http::{self, Request};

let resp = http::send(
    &Request::post("https://api.example.com/v1/chat/completions")
        .header("Authorization", &format!("Bearer {key}"))
        .json(&body)?
)?;

if resp.is_success() {
    let parsed: ChatResponse = resp.json()?;
}
```

The `Request` builder provides `get`, `post`, `put`, `delete`, and `new` (arbitrary method). Bodies can be set as a string (`body`), raw bytes (`body_bytes`), or a serialized JSON value (`json`).

Non-standard methods (PROPFIND, PATCH, REPORT) are carried in the `http-method::other(string)` variant.

### Streaming requests

`http-stream-start` returns an `http-stream` resource immediately after receiving the response status and headers. The body is read in chunks via `read-chunk`. An empty chunk signals EOF. Per-capsule cap: **4 concurrent HTTP streams**.

```rust
use astrid_sdk::http::{self, Request};

let stream = http::stream_start(
    &Request::post("https://api.openai.com/v1/chat/completions")
        .header("Authorization", &format!("Bearer {key}"))
        .json(&body)?
)?;

println!("status: {}", stream.status());
while let Some(chunk) = stream.read_chunk()? {
    // process SSE chunk
}
// stream drops here, kernel releases the resource
```

The `http-stream` resource also exposes:

- `subscribe-readable` for pollable composition (multiplexing HTTP streaming with IPC).
- `body-stream` returning an `input-stream` for splice-based forwarding: pipe the HTTP response body into a TCP connection host-side without round-tripping bytes through WASM.

`body-stream` and `read-chunk` share the same underlying response cursor. Use one per stream instance.

Drop is automatic. Capsules do not need to call `close` explicitly on the happy path.

---

## astrid:sys

**Source:** `wit/host/sys@1.0.0.wit`
**SDK modules:** `astrid_sdk::env`, `astrid_sdk::time`, `astrid_sdk::log`, `astrid_sdk::runtime`, `astrid_sdk::capabilities`

System-level runtime primitives. Astrid exposes no `wasi:*` interfaces; capsules reach the system clock, entropy source, and logging through this package, keeping every call on the audited, principal-scoped kernel path.

### Configuration and secrets

`get-config` reads a value from the capsule's `Capsule.toml [config]` or `[env]` section. The kernel injects these at load time. The SDK surfaces this through `astrid_sdk::env`:

```rust
use astrid_sdk::env;

// var returns "" if the key is not set
let api_key = env::var("api_key")?;

// var_opt distinguishes "not set" from "empty string"
let base_url = env::var_opt("base_url")?
    .unwrap_or_else(|| "https://api.openai.com".to_string());
```

Config values are returned without JSON-encoding. The empty string is a valid value distinct from `none`.

The well-known key `ASTRID_SOCKET_PATH` (constant `env::CONFIG_SOCKET_PATH`) is injected by the kernel into every capsule that needs to locate the Unix-domain socket. `runtime::socket_path()` reads it and validates the string (rejects empty, rejects null bytes).

Reserved internal keys cannot be read by capsules; the host returns `config-key-reserved`.

### Caller context

`get-caller` returns the acting principal, the originating capsule UUID, and the ISO 8601 message timestamp for the current invocation.

```rust
use astrid_sdk::runtime;

let ctx = runtime::caller()?;
if let Some(principal) = ctx.principal {
    // route work to the correct tenant
}
```

The SDK exposes this as `types::CallerContext`. The `source_id` is the capsule UUID, not the principal. Cross-tenant capsule invocations write logs to the target principal's log directory.

### Structured logging

`log` routes structured messages to the current principal's log directory with daily rotation. All five levels (`trace`, `debug`, `info`, `warn`, `error`) are available. The call is infallible. Every log call is recorded as a structured audit entry.

```rust
use astrid_sdk::log;

log::info(format!("handling request from {}", ctx.source_id));
log::error("inference failed: model returned empty response");
```

The `install_panic_handler` function (called automatically by the `#[capsule]` macro's generated entry points) routes Rust panics through `log::error` before the WASM trap, preserving file and line information in the capsule log.

### Signal-ready

`signal-ready` tells the kernel that the capsule's run loop has initialized and is ready to receive events. Call this after setting up IPC subscriptions but before entering the polling loop. The kernel waits for this signal before loading dependent capsules. It is a no-op if no readiness channel is configured.

```rust
use astrid_sdk::{ipc, runtime};

pub fn run() {
    let sub = ipc::subscribe("tool.v1.execute.*").unwrap();
    runtime::signal_ready().unwrap(); // kernel proceeds loading dependents
    loop {
        let poll = sub.recv(60_000).unwrap();
        // handle poll.messages
    }
}
```

### Clock

Two clock variants are available:

- `time::now()` returns `std::time::SystemTime` from the host wall clock (`clock-ms`, milliseconds since UNIX epoch). Infallible. Pre-1970 clocks are a host misconfiguration.
- `time::monotonic()` returns `std::time::Duration` from the host monotonic clock (`clock-monotonic-ns`, nanoseconds). Does not jump with NTP. Absolute value is meaningless across capsule reloads; use only for elapsed-time measurement.

### Random bytes

`runtime::random_bytes(length)` fills a `Vec<u8>` with cryptographically secure random bytes from the host's OS-level CSPRNG. Per-call cap: **4096 bytes**. Loop for bulk entropy. The host call is `random-bytes(length: u64)` which returns `too-large` above the cap.

```rust
use astrid_sdk::runtime;

let key_material = runtime::random_bytes(32)?; // 256-bit key
```

This call is not audit-recorded (read-only, no side effects).

### Sleep

`time::sleep(duration)` blocks the calling guest task. The host caps any single call at 60 seconds. Callers that need longer waits loop on shorter sleeps and check for a cancellation signal between iterations. Returns `cancelled` if the capsule is unloading mid-sleep.

### Capability introspection

`capabilities::check(source_uuid, capability)` lets a capsule verify that another capsule (identified by its IPC session UUID) has a specific manifest capability. Fail-closed: returns `false` for unknown UUIDs and unknown capabilities. Returns an error variant `registry-unavailable` when the registry cannot be consulted, rather than silently returning `false`.

```rust
use astrid_sdk::capabilities;

// Only trust a capsule that declared allow_prompt_injection
if capabilities::check(&msg.source_id, "allow_prompt_injection")? {
    // process the prompt injection
}
```

---

## astrid:process

**Source:** `wit/host/process@1.0.0.wit`
**SDK module:** `astrid_sdk::process`

**Desktop-kernel only.** Spawning child processes depends on a POSIX fork/exec model. Unikernel targets (hermit-rs, etc.) do not implement this package; capsules that import it will fail to load on those kernels.

Requires the `host_process` capability. The manifest value is a list of permitted executable names:

```toml
[capabilities]
host_process = ["bash", "sh", "zsh"]
```

(Source: `capsules/astrid-capsule-shell/Capsule.toml`)

### Sandbox

Commands are wrapped in platform-specific sandbox tools: `sandbox-exec` on macOS, `bwrap` on Linux. The sandbox is scoped to the workspace directory. Absolute paths and `..` path traversals in the `cwd` field are rejected with `boundary-escape`.

The audit log records command and arguments. Environment variables and stdin bytes are not logged.

### Synchronous spawn

`spawn` (and the SDK helper with the same name) blocks until the process exits or the capsule is cancelled.

```rust
use astrid_sdk::process::{self, Command};

// simple helper
let out = process::spawn("git", &["status", "--short"])?;
println!("{}", out.stdout);

// builder for env, cwd, stdin
let out = Command::new("python3")
    .arg("script.py")
    .env("PYTHONPATH", "/workspace/lib")
    .cwd("src")
    .stdin(b"input data\n".to_vec())
    .spawn()?;

if out.exit.success() {
    // exit_code == Some(0)
}
```

`Output` carries `stdout`, `stderr`, and `ExitInfo`. `ExitInfo` distinguishes normal exit (non-None `exit_code`) from signal-killed (non-None `signal`), matching the information in `/usr/include/signal.h`.

### Background spawn

`spawn_background` returns immediately with a `Process` handle. The kernel buffers stdout and stderr in **1 MiB ring buffers** per stream. Per-capsule cap: **8 concurrent background processes**.

```rust
use astrid_sdk::process::{Command, Signal};

let proc = Command::new("node")
    .arg("server.js")
    .spawn_background()?;

// poll for output
let logs = proc.read_logs()?;
if logs.running {
    println!("stdout so far: {}", logs.stdout);
}

// interactive stdin for REPL-style children
proc.write_stdin(b"SELECT 1;\n")?;

// graceful shutdown, then forceful if needed
proc.signal(Signal::Term)?;
let exit = proc.wait(Some(std::time::Duration::from_secs(5)))?;
if !exit.success() {
    proc.kill()?; // SIGKILL + drains remaining buffers
}
```

`read_logs` drains the buffers: subsequent calls return only new output since the last drain.

`wait_with_output` combines waiting and draining atomically, closing the race between "process exits" and "output not yet drained" that affects short-lived children.

```rust
let result = proc.wait_with_output(Some(std::time::Duration::from_secs(30)))?;
// result.stdout is complete even for fast-exiting processes
```

`os_pid` returns the OS-level PID for correlation with cgroup IDs or `/proc` paths. Returns `closed` if the process has already been reaped.

Drop reaps the child automatically. Capsules do not need explicit `wait` or `kill` on the happy path.

### Signals

The `Signal` enum maps to Unix signals. `kill` (SIGKILL) is a separate method that additionally drains the output buffers and returns them in `KillResult`:

| Variant | Unix signal |
|---|---|
| `Term` | SIGTERM |
| `Hup` | SIGHUP |
| `Usr1` | SIGUSR1 |
| `Usr2` | SIGUSR2 |
| `Int` | SIGINT |

The kernel maps signals to the closest equivalent on Windows. `kill` is non-graceful; use `Signal::Term` followed by a bounded `wait` for graceful shutdown sequences.

---

## Pollable composition across packages

All five packages participate in `astrid:io/poll`. The `subscribe-readiness` (IPC), `subscribe-readable` (net, HTTP, process), and `subscribe-exit`/`subscribe-logs` (process) methods return `pollable` resources. `astrid:io/poll.poll` waits on a heterogeneous list of up to **256 pollables** in a single call, firing when at least one is ready.

This is the multiplexing primitive for bridge and fan-out capsules that need to handle IPC messages, HTTP response chunks, and child process output simultaneously, without spinning on individual blocking calls.

```rust
// Conceptual sketch: poll IPC + HTTP stream + child process together
let ipc_ready = sub.subscribe_readiness();       // astrid:ipc
let http_ready = stream.subscribe_readable();    // astrid:http  
let proc_logs  = proc.subscribe_logs();          // astrid:process

// astrid:io/poll.poll returns indices of ready pollables
let ready = astrid_sys::astrid::io::poll::poll(&[
    &ipc_ready, &http_ready, &proc_logs,
]).expect("poll cancelled on capsule unload");
```

The per-call cap of 256 is sized to accommodate a capsule at its full IPC subscription quota (128) plus its TCP, UDP, HTTP, and process pollables in a single call. Per-principal quota profiles may lower the effective cap but never raise it above 256.

Blocking within `poll` races against the calling capsule's cancellation token. If the capsule is unloading, `poll` returns `cancelled` rather than stranding host tasks on futures that may never complete.

---

## ABI freeze discipline

Every WIT file in `wit/host/` carries the annotation:

```
Frozen per the ABI evolution discipline (RFC: host_abi). Shape changes
ship as a new file at a new version path; never edit this file.
```

Adding a field, a variant, or a function to an existing package is a breaking change from the Component Model's perspective. New capabilities ship as a new version file (`ipc@1.1.0.wit`), imported alongside the old one in the `astrid-sys` synthetic world. Capsules pinned at `@1.0.0` continue to resolve unchanged. The kernel linker enforces exact `(package, version)` matches.

## See also

- [The Syscall Surface](the-syscall-surface.md)
- [Topics and Wildcards](../bus/topics-and-wildcards.md)
- [The OS Process Sandbox](../security/os-process-sandbox.md)
