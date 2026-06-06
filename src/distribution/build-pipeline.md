# The Build Pipeline and WASM Targets

`astrid build` is the canonical tool for turning a Rust capsule source tree into a `.capsule` archive ready to install into the runtime. The implementation lives in `core/crates/astrid-build`. This page covers the Rust path in depth: the target selection rules, the getrandom custom backend, the component wrapping step, and the archive format.

## Invoking the builder

```bash
# From a capsule source directory, auto-detects the project type
astrid build

# With explicit output directory
astrid build --output dist/

# Explicit project type override
astrid build --type rust
```

The library entry point is `astrid_build::run()` (`src/lib.rs:54`). Dispatch lives in `src/build.rs`. Project type detection checks for `Cargo.toml` first, then `gemini-extension.json`, `package.json`, `mcp.json`, and finally `Capsule.toml` as a bare static capsule (`src/build.rs:66-98`).

For Rust capsules, `build::run_build` delegates to `rust::build` (`src/rust.rs:40`). The high-level steps are:

1. Verify `cargo` is on `PATH`.
2. Resolve `cargo metadata` to find the package name, version, and WASM artifact name.
3. Compile in release mode, injecting any required `RUSTFLAGS`.
4. Locate the compiled `.wasm` binary.
5. Wrap it into a Component Model component if needed.
6. Merge `Capsule.toml` with any extracted description.
7. Stage the `wit/` directory.
8. Pack the `.capsule` tar.gz archive.

## WASM target selection

### The canonical target: `wasm32-unknown-unknown`

Every Astrid capsule must target `wasm32-unknown-unknown`. This is a hard architectural constraint, not a convention.

`wasm32-unknown-unknown` produces a core WASM module with zero `wasi:*` imports. Every host call a capsule makes reaches the kernel through the `astrid:*` WIT interface surface, all of it capability-gated and audited. The WIT imports list is literally the capsule's capability list. Nothing can slip through an unaudited WASI back door.

```toml
# capsules/astrid-capsule-skills/.cargo/config.toml
[build]
target = "wasm32-unknown-unknown"

[target.wasm32-unknown-unknown]
rustflags = ["--cfg=getrandom_backend=\"custom\""]
```

Every shipped capsule in the tree carries this config. The `[build] target` line makes `cargo build` (invoked directly, without going through `astrid build`) also target the right architecture.

### The capsule build target

`wasm32-unknown-unknown` is the only capsule build target.

### How `astrid build` determines the target

The builder does not pass `--target` to Cargo. It lets the capsule's own `.cargo/config.toml` decide. The function `compile_wasm` (`src/rust.rs:139`) reads the config via `cargo_config_target_and_rustflags` and also respects the `CARGO_BUILD_TARGET` environment variable (which overrides the config file, mirroring Cargo's own precedence). Cargo then compiles with whichever target is in effect.

After compilation, `locate_wasm_binary` (`src/rust.rs:329`) probes for the output artifact:

```rust
const TARGETS: &[&str] = &["wasm32-unknown-unknown"];
```

It checks both the local `target/` directory and the workspace `target/` root so that workspace builds (where Cargo may redirect the artifact) are covered.

## The getrandom custom backend

`wasm32-unknown-unknown` has no platform random source. The `getrandom` crate, pulled in transitively through `uuid` v4 and `HashMap` seeding, refuses to link on that target without an explicit backend configured. The fix is a two-layer mechanism.

### The cfg flag

Every `wasm32-unknown-unknown` capsule needs the following in its `.cargo/config.toml`:

```toml
[target.wasm32-unknown-unknown]
rustflags = ["--cfg=getrandom_backend=\"custom\""]
```

This activates `getrandom`'s custom backend protocol, which expects a `#[no_mangle]` symbol named `__getrandom_v03_custom` to be present in the binary.

### The implementation in `astrid-sys`

`astrid-sys/src/lib.rs` (line 133) provides that symbol, conditionally compiled only when both `target_arch = "wasm32"` and `getrandom_backend = "custom"` hold:

```rust
#[cfg(all(target_arch = "wasm32", getrandom_backend = "custom"))]
#[unsafe(no_mangle)]
unsafe extern "Rust" fn __getrandom_v03_custom(
    dest: *mut u8,
    len: usize,
) -> Result<(), getrandom::Error> {
    const CHUNK: usize = 4096;
    let mut written = 0usize;
    while written < len {
        let want = core::cmp::min(CHUNK, len - written);
        let chunk = generated::astrid::sys::host::random_bytes(want as u64)
            .map_err(|_| getrandom::Error::new_custom(1))?;
        // ...
        written += take;
    }
    Ok(())
}
```

The implementation calls `astrid:sys/host.random-bytes`, which is served from the kernel's OS CSPRNG. Per the `astrid:sys` WIT contract this call is intentionally ungated and not audited (read-only, no side effects). Every capsule that depends on `astrid-sdk` gets a working CSPRNG with no per-capsule wiring because `astrid-sys` is always in the dependency graph.

On host-tooling builds (build scripts, proc-macros, `cargo test` on the developer machine), the cfg is absent and the symbol is omitted entirely. Those builds use the host platform's default RNG. `astrid-sys/build.rs` declares the cfg known to suppress the `unexpected_cfgs` lint:

```rust
println!("cargo::rustc-check-cfg=cfg(getrandom_backend, values(\"custom\"))");
```

### The safety net in `astrid build`

A capsule's `.cargo/config.toml` carries the flag so that `cargo build` (invoked without `astrid build`) works. But if a capsule is missing the config entry, `astrid build` injects it automatically. The function `encoded_rustflags_with_getrandom` (`src/rust.rs:255`) does this:

- It only activates for `wasm32-unknown-unknown`. Any other target returns `None` and the environment is left untouched.
- It reads any `CARGO_ENCODED_RUSTFLAGS` or `RUSTFLAGS` already set in the caller's environment and folds them in, so developer-set flags survive.
- It reads any `rustflags` declared in the capsule's `.cargo/config.toml` (both array and space-separated string forms) and appends them.
- Finally it appends `--cfg=getrandom_backend="custom"` unless already present.
- The result is written as `CARGO_ENCODED_RUSTFLAGS` (using ASCII unit separator `\u{1f}` between flags) and `RUSTFLAGS` is removed, so flags containing spaces survive and the two sources cannot both apply.

Cargo is then invoked without `--target`, picking up the environment flag for the WASM artifacts only. Because this is a cross-compile (host is not `wasm32`), the flag reaches only the guest artifacts, not build scripts or proc-macros.

The deduplication is intentional but narrow: only the getrandom cfg itself is deduplicated. Token-level deduplication would corrupt multi-token flags like `-C opt-level=3 -C debuginfo=2` (the second `-C` would be dropped). Duplicate whole flags are harmless to `rustc`.

## Component wrapping

`wasm32-unknown-unknown` builds produce a core WASM module, not a Component Model component. `wit-bindgen`'s `generate!` macro embeds a `component-type` custom section in the module that describes the component's imports and exports. The Component Model linker reads that section to perform component adaptation.

`ensure_component` (`src/rust.rs:291`) distinguishes the two cases by reading the WASM magic bytes:

- Core module: magic `\0asm`, version field `0x00 0x00 0x00 0x01` (bytes 4-7).
- Component: magic `\0asm`, version field `0x00 0x00 0x01 0x00` (the layer byte at offset 6 is `0x01`).

When the input is a core module, `wit_component::ComponentEncoder` wraps it:

```rust
let component = wit_component::ComponentEncoder::default()
    .validate(true)
    .module(&bytes)?
    .encode()?;
```

Validation is enabled. If `wit-bindgen`'s `generate!` macro was not used or produced the wrong custom section, `ComponentEncoder` rejects the module with a clear error rather than silently producing a broken component. The result is written back to the same path as the input artifact, so the `Capsule.toml` reference to `<crate_name>.wasm` continues to resolve without any manifest changes.

## The `Capsule.toml` manifest

The capsule manifest is the installer's contract. If a `Capsule.toml` already exists in the capsule source directory, `astrid build` reads and parses it with `toml_edit`. It fills in the `[package] description` field from the manifest's existing content and (previously) from an `astrid_export_schemas` WASM export. That export path is now a no-op stub (`extract_capsule_description` at `src/rust.rs:535`): with the Component Model migration, description comes entirely from the source `Capsule.toml`.

If no `Capsule.toml` exists, a minimal one is synthesized:

```toml
[package]
name = "astrid-capsule-example"
version = "0.1.0"
description = ""

[[component]]
id = "astrid-capsule-example"
file = "astrid_capsule_example.wasm"
type = "executable"
```

A real capsule's `Capsule.toml` also declares IPC subscriptions and publications. The `[subscribe]` and `[publish]` tables use topic glob patterns wired to WIT types:

```toml
[subscribe]
"tool.v1.execute.list_skills" = { wit = "@unicity-astrid/wit/types/tool-call", handler = "tool_execute_list_skills" }

[publish]
"tool.v1.execute.*.result" = { wit = "@unicity-astrid/wit/types/tool-call-result" }
```

The manifest is written into the archive from memory (never from a temporary file), so the in-archive `Capsule.toml` is always the build-time merge result.

## WIT staging

`astrid build` stages the capsule's WIT files for inclusion in the archive so the installer has schema information without needing the SDK source tree on the target machine.

`stage_wit_directory` (`src/rust.rs:420`) produces a staging directory at `<workspace_target>/.astrid-wit-staging/` with this layout:

```
.astrid-wit-staging/
  [capsule's own .wit files, or a stub package]
  deps/
    astrid-contracts/
      astrid-contracts.wit   ← shared SDK contracts from astrid-sdk source
```

The stub package (`STUB_WIT_PACKAGE`) exists so that `wit-parser`'s `push_dir` has a root package anchor even when the capsule has no local WIT. The shared SDK contracts are located by searching `cargo metadata` for the `astrid-sdk` package and reading `wit/astrid-contracts.wit` from its crate root. If the SDK source is unavailable (published builds, missing registry source), a warning is emitted and the shared contracts are omitted from the archive.

## The `.capsule` archive format

A `.capsule` file is a gzip-compressed tar archive. `pack_capsule_archive` (`src/archiver.rs:12`) writes entries in this order:

1. `Capsule.toml`, written directly from the in-memory string, not from disk.
2. The WASM binary, if present (for Rust capsules this is the component-wrapped artifact).
3. Any additional contextual files (skills, commands, README) at their relative paths under `base_dir`.
4. The staged `wit/` directory, recursively, at the archive path `wit/`.

The archiver explicitly enables symlink dereferencing (`tar.follow_symlinks(true)`), stated explicitly rather than relying on the library default. Symlinks are resolved to their real content before archiving; the installer's extraction path rejects symlinks as a security measure. The cycle detection in `append_dir_recursive` (`src/archiver.rs:117`) tracks visited directories by canonical path. When a symlink resolves to an already-visited directory, it is skipped with a warning rather than causing infinite recursion and OOM.

Archive entries are validated to contain no absolute paths and no path traversal components (`../`) at extraction time (see the test helper `unpack_capsule` in `src/build.rs:139`).

A size warning fires for archives over 50 MB (`LARGE_ARCHIVE_BYTES` at `src/archiver.rs:9`), pointing at node_modules bloat as the typical cause for Node-based MCP capsules.

The output file is named `<crate_name>.capsule` and placed in `./dist/` by default, or in the directory specified by `--output`.

## Installing the Rustup target components

Before running `astrid build` on a Rust capsule, install the required `rustup` target:

```bash
rustup target add wasm32-unknown-unknown
```


## Minimal capsule `.cargo/config.toml`

A canonical capsule carries this config in its source tree:

```toml
[build]
target = "wasm32-unknown-unknown"

[target.wasm32-unknown-unknown]
# Routes uuid v4 / HashMap RNG seeding through astrid:sys/host.random-bytes.
# Required because wasm32-unknown-unknown has no platform entropy source.
# astrid build injects this as a fallback, but keeping it here makes
# plain `cargo build` and `cargo test` (run without astrid build) work too.
rustflags = ["--cfg=getrandom_backend=\"custom\""]
```

Without `[build] target`, `cargo build` (outside of `astrid build`) targets the host platform, producing a native binary instead of a WASM module. Without the `rustflags` entry, `cargo build` fails to link `uuid` v4 or any crate that seeds `HashMap` at initialization. `astrid build` catches the missing flag, but the config entry is necessary for the development workflow where developers run `cargo check` and `cargo test` directly.

## See also

- [Distros and the Content-Addressed Store](distros-and-store.md)
- [The Syscall Surface](../host-abi/the-syscall-surface.md)
