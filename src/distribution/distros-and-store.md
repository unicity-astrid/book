# Distros and the Content-Addressed Store

A **distro** is a curated, versioned bundle of capsules that defines a complete Astrid deployment. Two files govern every distro: `Distro.toml`, which declares the bundle, and `Distro.lock`, which pins exact resolved versions and BLAKE3 hashes for reproducible installs. Below those files sits the content-addressed store, a pair of append-only directories (`bin/` and `wit/`) shared across all capsules on a host, where every WASM binary and WIT interface file is named by its BLAKE3 hash.

This page covers the full lifecycle: writing `Distro.toml`, running `astrid init`, managing individual capsules with `install`, `update`, `remove`, and `tree`, and how the store, `meta.json`, and export-conflict detection interact.

---

## Distro.toml

`Distro.toml` is the manifest for a distro. It is consumed by `astrid init` and parsed by `astrid-cli/src/commands/distro/manifest.rs`. The schema version is enforced at parse time; the only currently supported value is `1`.

```toml
schema-version = 1

[distro]
id          = "astralis"
name        = "Astralis"
pretty-name = "Astralis 0.2.0 (Equinox)"
version     = "0.2.0"
codename    = "equinox"
release-date = "2026-06-01"
description = "The complete Astrid AI assistant experience"
authors     = ["Astrid Core Team"]
homepage    = "https://github.com/unicity-astrid/astralis"
license     = "MIT OR Apache-2.0"
astrid-version = ">=0.5.0"

[distro.requires.astrid]
llm     = "^1.0"
session = "^1.0"

[variables]
api_key  = { secret = true, description = "Provider API key" }
base_url = { description = "API base URL", default = "https://api.openai.com" }

[[capsule]]
name   = "astrid-capsule-cli"
source = "@unicity-astrid/capsule-cli"
version = "0.7.0"
role   = "uplink"

[[capsule]]
name    = "astrid-capsule-openai-compat"
source  = "@unicity-astrid/capsule-openai-compat"
version = "0.3.1"
group   = "llm"

[capsule.env]
api_key  = "{{ api_key }}"
base_url = "{{ base_url }}"
```

### Fields

**`[distro]`** carries os-release-style metadata. The required fields are `id`, `name`, and `version`. The `id` must match `^[a-z][a-z0-9-]*$`. The `version` must be valid semver. `astrid-version` (if set) must be a valid semver requirement string.

**`[distro.requires]`** declares namespace/interface pairs the distro expects to be satisfied. These are informational at the manifest level; the kernel gates actual invocations through the capability system at runtime.

**`[variables]`** defines shared values that can be referenced across capsule `[env]` blocks. Variable definitions carry three optional fields: `secret` (masked during input, defaults to `false`), `description` (shown as the prompt label), and `default` (used when the operator presses Enter without input). Variable references in capsule `env` use `{{ var_name }}` syntax. The parser rejects undefined references at load time.

**`[[capsule]]`** is a TOML array of tables, one entry per capsule. Required fields are `name`, `source`, and `version`. The `source` field accepts:
- `@org/repo` (GitHub namespace alias)
- `github.com/org/repo` or `https://github.com/org/repo`
- A local path (`.` or `/` prefix)

The optional `role = "uplink"` field marks capsules that own the Unix socket listener. Every distro must have at least one uplink capsule; the validator rejects manifests without one. The optional `group` field places a capsule in a multi-select group during `astrid init` so the operator can choose between, for example, competing LLM providers.

**`[invites]`** (optional) configures multi-tenant invite redemption. When `issuers` is non-empty, `default-group` must also be set. The `default-expires` field accepts duration strings of the form `30s`, `5m`, `24h`, or `7d`. The `max-principals` field accepts `"unlimited"` or a non-negative integer string.

**`[branding]`** (optional) provides dashboard hints: `primary-color` and `accent-color` accept `#RGB` or `#RRGGBB` strings; `icon` accepts a data URL or a relative path capped at 64 KiB.

### Validation

The validator (`astrid-cli/src/commands/distro/validate.rs`) enforces rules that serde alone cannot:

- `schema-version` must equal the supported constant (currently `1`).
- `distro.id` must match `^[a-z][a-z0-9-]*$`.
- `distro.version` must be valid semver.
- `distro.astrid-version`, if set, must be a valid semver requirement.
- Every `distro.requires` version string must be a valid semver requirement.
- At least one `[[capsule]]` entry must exist.
- Capsule names must be unique within the manifest.
- At least one capsule must have `role = "uplink"`.
- Every `{{ var }}` reference in a capsule `env` block must name a variable defined in `[variables]`.
- The `[invites]` block, if present, must be internally coherent (non-empty `issuers` requires `default-group`; `default-expires` must parse as a valid duration; `max-principals` must be `"unlimited"` or an integer).
- The `[branding]` icon must be at most 64 KiB; color fields must pass the `#RGB`/`#RRGGBB` pattern check.

---

## Distro.lock

`Distro.lock` pins exact resolved versions and BLAKE3 hashes, written after every successful `astrid init` run and regenerated after `astrid capsule update`. It lives at `~/.astrid/home/{principal}/.config/distro.lock`.

```toml
schema-version = 1

[distro]
id          = "astralis"
version     = "0.2.0"
resolved-at = "2026-06-01T14:00:00Z"

[[capsule]]
name    = "astrid-capsule-cli"
version = "0.7.0"
source  = "@unicity-astrid/capsule-cli"
hash    = "blake3:3a7f..."

[[capsule]]
name    = "astrid-capsule-openai-compat"
version = "0.3.1"
source  = "@unicity-astrid/capsule-openai-compat"
hash    = "blake3:c91e..."
```

The `hash` field stores the BLAKE3 hex digest of the installed WASM binary prefixed with `blake3:`. Capsules without a WASM component (MCP, script-only) store an empty hash string. Writes are atomic: the lock is staged to a `NamedTempFile` and renamed into place, so a crash mid-write never leaves a truncated file on disk (`astrid-cli/src/commands/distro/lock.rs:write_lock`).

`is_lock_fresh` compares `distro.id` and `distro.version` between the lock and the manifest. When the lock is fresh, `astrid init` prints a message and exits early without reinstalling anything.

---

## astrid init

`astrid init [distro-source]` is the entry point for first-run distro installation. Local file paths are detected first by `fetch_and_parse_manifest` (`astrid-cli/src/commands/init.rs`), which checks `path.exists() && path.is_file()` before calling `resolve_distro_url`. For non-local sources, `resolve_distro_url` (`astrid-cli/src/commands/init.rs:resolve_distro_url`) applies these rules:

- A bare name like `astralis` becomes `https://raw.githubusercontent.com/unicity-astrid/astralis/main/Distro.toml`.
- An `@org/repo` prefix becomes `https://raw.githubusercontent.com/org/repo/main/Distro.toml`.
- An `https://` URL is used as-is.

The manifest body is streamed with a 1 MiB limit to prevent abuse from untrusted URLs.

The init flow:

1. Resolve `AstridHome` and call `home.ensure()` to create the directory skeleton.
2. Initialize the workspace by writing `<cwd>/.astrid/config.toml` if it does not exist.
3. Fetch and parse the distro manifest.
4. Check `Distro.lock` freshness. Exit early if the lock is already current.
5. Display the distro `pretty-name` and `description`.
6. Call `select_capsules`: capsules without a `group` are always included; capsules in a group are presented interactively for multi-select. An empty selection defaults to the first capsule in the group.
7. Call `collect_variables`: prompt for only the variables referenced by selected capsules, using `description` as the prompt label and `default` as the fallback when the operator provides no input.
8. Call `write_env_files`: resolve `{{ var }}` templates in each capsule's `env` block and write per-capsule `.env.json` files before installing. Files that already exist are left alone to preserve user customization. On Unix, env files are created with mode `0600`.
9. Call `install_capsules` with a progress bar, using `install_capsule_batch` for each capsule (batch mode suppresses per-capsule import warnings and env prompting, since the distro handles those centrally).
10. Read `meta.json` for each installed capsule to retrieve the WASM hash.
11. Write `Distro.lock`.

```bash
# Install the default Astralis distro
astrid init

# Install a named distro from the unicity-astrid org
astrid init astralis

# Install from a custom GitHub repo
astrid init @my-org/my-distro

# Install from a local Distro.toml
astrid init ./path/to/Distro.toml
```

---

## capsule install

`astrid capsule install <source>` resolves a source string to a directory on disk containing a `Capsule.toml`, then delegates to the shared install library (`astrid-capsule-install`). Source resolution happens entirely in the CLI (`astrid-cli/src/commands/capsule/install.rs`).

Source routing order:

1. Starts with `.` or `/`: local path, no source tracking.
2. Starts with `@`: GitHub namespace alias (`@org/repo`).
3. Starts with `github.com/` or `https://github.com/`: raw GitHub URL.
4. Fallback: treated as a local path.

For GitHub sources, the install flow first attempts to download a `.capsule` archive from the latest GitHub release (streamed with a 50 MiB limit). If no `.capsule` asset is found, it falls back to `git clone --depth 1` followed by `astrid-build`.

For local Cargo source directories (a directory containing `Cargo.toml` but no pre-built `.wasm`), `astrid-build` is invoked automatically to produce a `.capsule` archive, which is then unpacked and installed.

Adding `--workspace` installs into `<cwd>/.astrid/capsules/<id>/` instead of the principal's home.

---

## The Install Library: astrid-capsule-install

The post-resolution install machinery is in the `astrid-capsule-install` crate so the CLI and the kernel-side admin handler share a single implementation of what an install actually does. The library never reads stdin, never writes to stderr, and returns structured diagnostics for the caller to render.

### Install phases (in order)

The install sequence in `install_from_local_path` (`astrid-capsule-install/src/local.rs`) is carefully ordered so that all reads happen before any mutation of the target directory:

**Pre-flight (read-only):**

1. Parse `Capsule.toml` from the source directory.
2. Run `check_export_conflicts` (advisory, never blocks).
3. Hash the WASM binary from the source into `bin/<hash>.wasm` via `content_address_wasm`.
4. Hash all `.wit` files under `source/wit/` into `wit/<hash>.wit` via `content_address_wit`.
5. Bake topic schemas by resolving `schema` paths or `wit_type` references from the manifest.

If any pre-flight step fails, the existing install (if any) is untouched.

**Mutation (with rollback):**

6. Rename the existing `target_dir` to `target_dir.bak` if it exists (the backup).
7. Copy the non-WASM source tree to `target_dir` via `copy_capsule_dir` (excludes `*.wasm`, top-level `wit/`, `.git`, `target`, top-level `dist/`).
8. Restore `.env.json` from the backup directory if present (preserves user configuration across upgrades).
9. Run the lifecycle hook (`install` or `upgrade` export in a one-shot wasmtime instance).
10. Write `meta.json` atomically.
11. Delete the backup.

Any failure from step 6 onward triggers rollback: `target_dir` is removed and the backup is renamed back.

```rust
// InstallOutput, what the CLI renders
pub struct InstallOutput {
    pub target_dir: PathBuf,
    pub phase: InstallPhase,        // Install or Upgrade
    pub installed_version: String,
    pub previous_version: Option<String>,
    pub wasm_hash: Option<String>,
    pub env_path: PathBuf,
    pub env_needs_prompt: bool,
    pub missing_imports: Vec<MissingImport>,
    pub export_conflicts: Vec<ExportConflict>,
}
```

### Archive unpacking

`.capsule` files are gzipped tar archives. `unpack_and_install` (`astrid-capsule-install/src/archive.rs`) extracts them into a `tempdir` before calling `install_from_local_path`. Every entry is vetted for path traversal (`..` components, absolute paths). Symlinks and hard links are refused outright. A `tempfile::tempdir()` is used as the staging area so cleanup is automatic on drop.

---

## The Content-Addressed Stores

### bin/ (WASM binaries)

`~/.astrid/bin/<blake3-hex>.wasm` holds every distinct WASM binary seen across all capsule installs. The path layout is defined in `AstridHome::bin_dir` (`astrid-core/src/dirs.rs:332`).

On install, `content_address_wasm` (`astrid-capsule-install/src/wasm.rs`):

1. Reads the WASM bytes from `source_dir/<component.path>`.
2. Computes `blake3::hash(&bytes)` and formats the hex string.
3. Writes `bin/<hash>.wasm` using an atomic temp-and-rename pattern. The temp file name uses a UUIDv4 suffix, not `process::id()`, because sibling tokio tasks within the daemon share a PID and would otherwise race on the same temp name.
4. If a concurrent installer writes identical bytes at the same time, the rename races harmlessly: whichever process loses the rename finds `store_path.exists()` true and removes its temp file.

The runtime loads capsules from this store via `resolve_content_addressed_wasm`. The per-capsule directory never contains a `.wasm` file: it is a manifest-and-configuration package, not an executable container.

### wit/ (WIT interface definitions)

`~/.astrid/wit/<blake3-hex>.wit` holds content-addressed WIT files. The path layout is defined in `AstridHome::wit_dir` (`astrid-core/src/dirs.rs:342`).

On install, `content_address_wit` (`astrid-capsule-install/src/wit.rs`) walks `source_dir/wit/` recursively. For each `.wit` file:

1. Enforces a 1 MiB size cap (a hostile or accidental gigabyte file would otherwise fill the store).
2. Computes the BLAKE3 hash and stores the bytes at `wit/<hash>.wit` using the same atomic UUID-suffixed temp-and-rename pattern as the WASM store.
3. Records the mapping of relative path (e.g., `"my-analytics.wit"`) to BLAKE3 hex in the returned `HashMap<String, String>`.

This map is persisted in `meta.json` under `wit_files` so the GC can determine which store blobs are still referenced.

### Append-only by default

Both stores are **append-only from the installer's perspective**. `astrid capsule remove` never deletes blobs. The rationale: BLAKE3 hashes in audit log entries must always resolve to real binaries so that historic capsule states can be reconstructed. Operator-initiated cleanup is handled by `astrid gc`.

---

## meta.json: the runtime capsule database

`meta.json` lives alongside `Capsule.toml` in every capsule's install directory. It is the single source of truth the runtime consults to locate the WASM binary, understand the capsule's interface contracts, and serve the topic API to subscribers.

```jsonc
{
  "version": "0.3.1",
  "installed_at": "2026-06-01T14:00:00Z",
  "updated_at": "2026-06-01T14:00:00Z",
  "source": "@unicity-astrid/capsule-openai-compat",
  "imports": {
    "astrid": { "session": "^1.0" }
  },
  "exports": {
    "astrid": { "llm": "1.0.0" }
  },
  "topics": [
    {
      "name": "llm.v1.response.chunk",
      "direction": "publish",
      "description": "Streaming response token",
      "schema": { "type": "object", "properties": { ... } }
    }
  ],
  "wasm_hash": "3a7f1b...",
  "wit_files": {
    "provider.wit": "c91e2a..."
  }
}
```

The `CapsuleMeta` struct (`astrid-capsule-install/src/meta.rs:23`) is serialized with `serde_json::to_string_pretty` and persisted atomically. Empty collections (`imports`, `exports`, `topics`, `wit_files`) are omitted from the JSON via `skip_serializing_if`. The `source` field is likewise omitted when absent.

**Reads are non-fatal.** A missing or corrupt `meta.json` is logged at `warn` level and treated as "no metadata." This means an installer can still upgrade over a partially-broken capsule. The full `CapsuleMeta` type is:

```rust
pub struct CapsuleMeta {
    pub version: String,
    pub installed_at: String,
    pub updated_at: String,
    pub source: Option<String>,
    pub imports: HashMap<String, HashMap<String, String>>,  // ns -> iface -> version
    pub exports: HashMap<String, HashMap<String, String>>,
    pub topics: Vec<BakedTopic>,
    pub wasm_hash: Option<String>,
    pub wit_files: HashMap<String, String>,  // relative path -> blake3 hex
}
```

### Topic baking

`bake_topics` (`astrid-capsule-install/src/topics.rs`) resolves each `[[topic]]` entry from `Capsule.toml` into a `BakedTopic` with an inline `schema` field. The resolution order:

1. **`wit_type`**: names a WIT record in the capsule's `wit/` directory. `WitSchemas::from_dir` parses the WIT and converts record types to JSON Schema, with `///` doc comments becoming `"description"` fields. Parsing is lazy: the WIT files are loaded only when at least one topic references `wit_type`.
2. **`schema`**: a path to a JSON Schema file, resolved relative to the capsule source directory. The canonicalized path must stay inside the source root (path-traversal defense). Files larger than 1 MiB are rejected.
3. **Neither**: the topic is baked without a schema.

Schemas are stored inline in `meta.json` so the kernel and any subscriber can read the type contract without re-parsing WIT or re-reading schema files at runtime.

---

## Capsule locations

Capsules can be installed in two locations:

| Location | Path | Scope |
|----------|------|-------|
| User | `~/.astrid/home/{principal}/.local/capsules/{id}/` | Active for the principal across all workspaces |
| Workspace | `<cwd>/.astrid/capsules/{id}/` | Active only in the current workspace |

`scan_installed_capsules` (`astrid-capsule-install/src/meta.rs:144`) scans both the principal's capsules directory and `<cwd>/.astrid/capsules/`, returning an alphabetically sorted `Vec<InstalledCapsule>` annotated with `CapsuleLocation::User` or `CapsuleLocation::Workspace`.

Environment configuration for each capsule lives separately at `~/.astrid/home/{principal}/.config/env/{capsule-name}.env.json`, mode `0600`. This file is preserved across upgrades (step 8 of the install sequence) and deleted only on explicit `--purge`.

---

## capsule update

`astrid capsule update [name]` re-installs a capsule from its recorded `source` in `meta.json`.

**Named update**: reads `meta.json` to retrieve the original source string, then calls `install_capsule` directly. No version comparison is performed; the re-install always fetches the latest from the source.

**Bulk update** (no name): for each installed capsule with a recorded source, `check_remote_version` (`astrid-cli/src/commands/capsule/install_update.rs`) calls the GitHub releases API to find the latest tag, strips common `v`/`V` prefixes, parses as semver, and compares against the installed version. Only capsules where the remote version is strictly greater are re-installed. Local paths are reported as skipped.

After a successful bulk update, `regenerate_distro_lock` re-writes `Distro.lock` from the current on-disk state to keep the lock in sync.

```bash
# Update a single capsule
astrid capsule update astrid-capsule-session

# Check all capsules for updates and install newer versions
astrid capsule update
```

---

## capsule remove

`astrid capsule remove <name> [--force] [--purge]`

Before removing a capsule, `check_removal_safety` checks whether the target is the sole provider of any interface required by another installed capsule. The check uses the `exports` and `imports` maps from every capsule's `meta.json`. If the target exports an interface that another capsule imports, and no other installed capsule also exports that interface, the removal is blocked and the user sees:

```
Cannot remove 'astrid-capsule-llm': it is the sole provider of 'astrid/llm'
which is required by 'astrid-capsule-react'. Use --force to override.
```

`--force` bypasses the safety check. Content-addressed WASM blobs in `bin/` and WIT blobs in `wit/` are never deleted by `remove`. The capsule directory itself is removed with `fs::remove_dir_all`. `--purge` additionally deletes the capsule's `.env.json` from `~/.astrid/home/{principal}/.config/env/`.

---

## capsule tree

`astrid capsule tree` builds a dependency graph from all installed capsules' `meta.json` and renders it as a tree. For each capsule it shows:

- Declared exports (namespace/interface and version)
- Declared imports, each annotated with the capsule(s) that satisfy it

Imports satisfied by no installed capsule are highlighted in red and collected in an "Unsatisfied Imports" section at the bottom. Multiple providers for the same interface are listed as a normal case (two LLM provider capsules coexisting is valid; the kernel's runtime dispatcher routes invocations).

```bash
astrid-capsule-react
  exports: astrid/ui 1.0.0
  imports: astrid/llm ^1.0
    exported by: astrid-capsule-openai-compat (1.0.0)

astrid-capsule-openai-compat
  exports: astrid/llm 1.0.0
  imports: (none)
```

The graph construction (`astrid-cli/src/commands/capsule/deps.rs:build_dep_graph`) does name-and-location equality checking so a workspace capsule and a user capsule with the same name are treated as distinct nodes.

---

## Export-conflict detection

`check_export_conflicts` (`astrid-capsule-install/src/manifest_check.rs:77`) runs during every install as a pre-flight check. It scans all installed capsules and identifies those that already export the same `(namespace, interface)` pairs as the capsule being installed.

This is **informational only**, not a blocker. The kernel's runtime dispatcher handles multiple providers of the same interface (for example, two LLM capsules). The installer logs each conflict at `info` level via `tracing`:

```
Shared export, both capsules will be active  interface=astrid/llm  existing=astrid-capsule-openai
```

Similarly, `validate_imports` checks whether required (non-optional) imports from the manifest are satisfied by the exports of other installed capsules. Unsatisfied non-optional imports are surfaced as `MissingImport` structs in `InstallOutput.missing_imports`. The CLI prints a note to stderr:

```
Note: astrid-capsule-react needs astrid/llm ^1.0.
Install the missing capsule(s) or run `astrid init` to set up a complete environment.
```

Batch-mode installs (called from distro init, where all capsules are installed together) suppress this check by setting `skip_import_check: true` in `InstallOptions`.

---

## astrid gc

`astrid gc [--force]` garbage-collects unreferenced WIT blobs from `~/.astrid/wit/`. The WASM `bin/` store is not yet swept by `gc` (the comment in `astrid-cli/src/commands/gc.rs` notes this as a planned extension).

The mark set is built by walking every principal's capsules directory and the workspace capsules directory, reading each `meta.json`, and collecting all BLAKE3 hashes from the `wit_files` map. Any `.wit` file in the store whose stem is not in the mark set is an orphan.

Without `--force`, the command reports orphan count and reclaimable bytes in dry-run mode. With `--force`, it deletes the unreferenced blobs. Temp files left by concurrent installs (matching the pattern `<hash>.tmp.<uuid>`) are skipped during the scan.

```bash
# Dry run: see what would be removed
astrid gc

# Actually delete unreferenced blobs
astrid gc --force
```

---

## Directory layout reference

```
~/.astrid/
├── bin/                      # Shared WASM store
│   └── <blake3-hex>.wasm
├── wit/                      # Shared WIT store
│   └── <blake3-hex>.wit
└── home/
    └── <principal-id>/
        ├── .local/
        │   ├── capsules/
        │   │   └── <capsule-id>/
        │   │       ├── Capsule.toml
        │   │       └── meta.json
        │   ├── kv/
        │   ├── log/
        │   ├── audit/
        │   └── tokens/
        └── .config/
            ├── distro.lock
            └── env/
                └── <capsule-id>.env.json

<cwd>/
└── .astrid/
    ├── config.toml
    └── capsules/
        └── <capsule-id>/     # Workspace-scoped capsule install
            ├── Capsule.toml
            └── meta.json
```

The `bin/` and `wit/` stores sit at the `~/.astrid/` root, not under any principal subdirectory, because they are shared across all principals on the host. Per-capsule directories contain only the manifest, runtime metadata, and any non-WASM resources (MCP command scripts and `node_modules/` for Node-based MCP capsules). The WASM binary is always read from `bin/<hash>.wasm` by hash, never from the capsule directory.

## See also

- [The Build Pipeline and WASM Targets](build-pipeline.md)
- [The Capsule Manifest and Engines](../capsule-model/manifest-and-engines.md)
