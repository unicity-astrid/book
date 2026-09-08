# Getting Started: Your First Capsule

The previous chapter started a runtime. This one extends it: scaffold a capsule,
compile it to WebAssembly, check its wiring, and install it into the running
daemon. No restart is required. Installation does not make the tool available
to every agent on the machine: discovery and invocation depend on the selected
principal's grants and tool-broker composition.

You need a Rust toolchain (`rustup`) and a working Astrid install from the previous chapter. Nothing else.

## Scaffold

```bash
astrid capsule new my-tool
cd my-tool
```

The scaffold is deliberately complete: it compiles first try, and it carries its own documentation in `AUTHORING.md`, written to be read by you or by an agent you point at the directory. The layout:

| File | What it is |
|------|------------|
| `src/lib.rs` | Tool implementations: `#[astrid::tool]` exports. |
| `Capsule.toml` | The manifest: component, capabilities, and the tool-bus ACL. |
| `AUTHORING.md` | The self-contained guide to editing all of the above. |
| `.cargo/config.toml` | Pins the build target to `wasm32-unknown-unknown`. |

If the `wasm32-unknown-unknown` target is missing, the scaffolder offers to add it (or pass `--install-target` to skip the prompt).

## Read what you got

The generated `src/lib.rs` is a whole, working capsule:

```rust
use astrid_sdk::prelude::*;
use astrid_sdk::schemars;
use serde::Deserialize;

#[derive(Debug, Default, Deserialize, schemars::JsonSchema)]
pub struct HelloArgs {
    /// Who to greet.
    pub name: String,
}

#[derive(Default)]
pub struct Capsule;

#[capsule]
impl Capsule {
    /// Greet someone by name. Replace this with your own tool.
    #[astrid::tool("hello")]
    pub fn hello(&self, args: HelloArgs) -> Result<String, SysError> {
        Ok(format!("Hello, {}!", args.name.trim()))
    }
}
```

Three things carry all the weight:

- **`#[capsule]`** turns the impl block into a WebAssembly component that exports Astrid's guest interface. You never write bindings.
- **`#[astrid::tool("hello")]`** advertises a tool. The doc comment becomes the tool's description; the argument struct's `JsonSchema` derive becomes the schema the agent sees. Documentation here is not decoration, it is the tool's contract with the model.
- **`Result<String, SysError>`** is the honest shape: tools can fail, and failures travel back through the bus as typed errors, not panics.

The manifest, `Capsule.toml`, is where intent becomes enforceable. Two tables matter:

```toml
[publish]
"tool.v1.execute.*.result" = { wit = "@unicity-astrid/wit/types/tool-call-result" }

[subscribe]
"tool.v1.execute.hello" = { wit = "@unicity-astrid/wit/types/tool-call", handler = "tool_execute_hello" }
```

`[subscribe]` binds a bus topic to an exported handler, and doubles as the subscribe ACL: the kernel will not deliver anything else to you. `[publish]` is the complete list of topics you may emit. A capsule's IPC surface is exactly these two tables, and nothing in your Rust can widen it. The commented-out `[capabilities]` block is the same idea for host powers (filesystem, network): the hello tool needs none, so it declares none.

## Build and check

```bash
astrid capsule build
astrid capsule check
```

`build` runs the whole pipeline: cargo compile, component wrap, and packing into a signed `.capsule`. `check` is the static linter you will learn to trust: it cross-checks the tools your code advertises against the routing your manifest declares, catching the classic silent failure, a tool that exists in Rust but that no `[subscribe]` entry ever routes to. Run it in CI.

## Install, live

```bash
astrid capsule install .
```

The daemon does not restart. The kernel verifies the package, registers the
manifest's ACLs, and sandboxes the component. To prove tool invocation through
chat, you also need a configured chat composition and a principal authorized to
use this capsule. With those prerequisites in place:

```bash
astrid chat
# then ask: "use the hello tool to greet Ada"
```

The agent discovers the tool through the same describe flow every other capsule uses, calls it over the bus, and your Rust runs inside the sandbox with exactly the capabilities you declared, which in this case is none.

## Make it yours

The loop from here is tight: edit `src/lib.rs`, add a tool with `#[astrid::tool("my_tool")]`, mirror it with a `[subscribe]` entry, `build`, `check`, `install .` again. If your tool needs host powers, declare them in `[capabilities]` and the kernel will hold you to the declaration; the [Capability Gating](../host-abi/capability-gating.md) chapter explains what enforcement looks like, and [Designing Capsules](../capsule-model/designing-capsules.md) covers how to shape bigger ones.

That is the whole developer story: the OS grew a skill, the skill is sandboxed and signed, and nothing you shipped can do more than its manifest admits.
