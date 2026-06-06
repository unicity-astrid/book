# The RFC Process

Astrid draws a hard boundary between the kernel and user space. The kernel routes events, enforces capabilities, and runs the WASM sandbox. Capsules hold all intelligence. The contract between those two sides, the host ABI, the IPC protocol, the capability model, the manifest schema, the VFS semantics, and the SDK public API, must be stable enough for third-party capsule authors to build against without reading kernel source.

RFCs are the mechanism that keeps that contract explicit. They live in a separate repository ([`unicity-astrid/rfcs`](https://github.com/unicity-astrid/rfcs)) so specifications are decoupled from any one implementation and readable without navigating the kernel codebase. The authoritative source is `astrid-rfcs/README.md` and `astrid-rfcs/text/0001-rfc-process.md`.

## When an RFC Is Required

An RFC is required for any substantial change to the contract surface between the kernel and user space. That surface has seven areas:

| Area | Examples |
|------|----------|
| **Host ABI** | Adding, removing, or changing an `astrid_*` host function in `astrid-sys` |
| **IPC protocol** | New topic naming conventions, payload schema changes, new message types |
| **Capability model** | New capability scopes, changes to token format or validation semantics |
| **Manifest schema** | New fields in `Capsule.toml`, changes to dependency resolution or capability declarations |
| **VFS semantics** | Path resolution rules, overlay behavior, new filesystem operations |
| **Capsule interface standards** | Standard tool schemas, standard IPC contracts between capsules |
| **SDK public API** | Breaking changes to `astrid-sdk` module layout or typed wrappers |

A practical test: if the change would break a conforming capsule that was built against the existing spec, or require a capsule author to change code without touching kernel internals, an RFC is required.

## What Does Not Require an RFC

The RFC process governs the contract surface only. Kernel internals and capsule internals can move fast without coordination. The following changes do not require an RFC:

- Bug fixes to existing implementations
- Internal refactoring that preserves the external contract
- Documentation improvements
- Performance optimizations that preserve existing behavior
- Adding a new capsule that implements an existing interface standard
- Kernel-internal routing, dispatch, or storage changes that do not cross the ABI boundary

The memory file captures this sharply: "RFCs are for WIT contract changes only. Kernel-internal routing/dispatch/storage changes that preserve guest-visible WIT do not need RFC."

## Repository Layout

```
unicity-astrid/rfcs
├── 0000-template.md      # Blank RFC template, copy this
├── README.md             # Index and lifecycle summary
├── book.toml             # mdBook config for rendered docs
├── text/
│   └── 0001-rfc-process.md   # Only merged RFC as of 2026-06-05
└── generate-book.py
```

Draft RFCs live on branches (`rfc/cargo-like-manifest`, `rfc/host-abi-initial-set`, `rfc/net-connect-tcp`, `feat/users-capsule-rfc`, and others) until a maintainer merges them and assigns a number. As of 2026-06-05, only RFC-0001 (the RFC process itself) is in `text/` with **Active** status.

## Lifecycle States

An RFC moves through five states:

| State | Meaning |
|-------|---------|
| **Draft** | Pull request open, under discussion. The file lives on a branch named with the descriptive slug, not yet a number. |
| **Active** | Merged into `text/NNNN-*.md`. The contract is being implemented in `astrid-sdk` and the relevant kernel or capsule crates. |
| **Final** | Implemented and stable. Breaking changes require a new RFC; amendments for non-breaking clarifications can be submitted as follow-up PRs. |
| **Withdrawn** | Pull request closed without merge. The number is never assigned. |
| **Superseded** | A newer RFC replaces this one. The header notes the replacement. The number is retained. |

Numbers are never reused. Withdrawn or superseded RFCs retain their number to preserve link stability.

## Submitting an RFC

```bash
# 1. Fork unicity-astrid/rfcs and clone it
git clone git@github.com:YOUR_FORK/rfcs.git
cd rfcs

# 2. Copy the template, do not assign a number yet
cp 0000-template.md text/0000-my-feature.md

# 3. Fill in the RFC, commit, push, open a pull request
git checkout -b rfc/my-feature
# ... edit text/0000-my-feature.md ...
git commit -m "rfc: my-feature proposal"
git push origin rfc/my-feature
# open PR against unicity-astrid/rfcs:main
```

Discussion happens on the pull request. Revise as needed. When consensus is reached a maintainer runs the merge checklist below.

## The Template

`0000-template.md` (`astrid-rfcs/0000-template.md`) requires the following header fields:

| Field | Description |
|-------|-------------|
| `Feature Name` | A unique `snake_case` identifier. |
| `Start Date` | Date first submitted, `YYYY-MM-DD`. |
| `RFC PR` | Link to the pull request where the RFC is discussed. |
| `Tracking Issue` | Link to the implementation tracking issue in `unicity-astrid/astrid`, if applicable. |

Every RFC must include all nine sections: **Summary, Motivation, Guide-level explanation, Reference-level explanation, Drawbacks, Rationale and alternatives, Prior art, Unresolved questions, and Future possibilities**.

For RFCs that define interfaces (tools, IPC messages, host functions), the Reference-level explanation must be self-sufficient. Specifically it must cover:

- Function signatures or tool schemas with exact semantics
- Input types: JSON schemas with field types, required/optional, constraints
- Output types: success and error shapes
- Host function requirements, if any
- IPC event types and topic patterns, if any
- Ordering and concurrency guarantees
- Error handling contract

The spec must be precise enough that an independent developer can implement a conforming component from that section alone.

## Maintainer Merge Flow

When an RFC reaches consensus, the maintainer:

1. Assigns the next sequential RFC number (not the PR number).
2. Renames the file from `text/0000-*.md` to `text/NNNN-*.md`.
3. Updates the `RFC PR` and `Tracking Issue` header fields.
4. Adds an entry to the index table in `README.md`.
5. Commits and merges.

RFC numbers are assigned at merge time, not when the PR is opened. This prevents opened-but-abandoned PRs from burning numbers and keeps the sequence dense. The pattern is taken from Python PEPs, which use editor-assigned numbers for the same reason.

## SDK Feature-Flag Mapping

RFC-0001 and the README both describe an intended mapping between accepted RFCs and `astrid-sdk` Cargo feature flags:

```toml
# Enable types introduced by a specific RFC
astrid-sdk = { version = "0.2", features = ["rfc-1"] }

# Enable types from every accepted RFC
astrid-sdk = { version = "0.2", features = ["all-rfcs"] }
```

**This is aspirational.** As of 2026-06-05, `astrid-sdk/Cargo.toml` defines only two features:

```toml
[features]
default = ["derive"]
derive = ["dep:astrid-sdk-macros"]
```

No `rfc-N` or `all-rfcs` feature exists in the SDK today (`sdk-rust/astrid-sdk/Cargo.toml`). RFC-0001 itself notes "not all RFCs produce SDK types (this one does not, for example)". The feature-flag system is the intended mechanism for gating new contract types behind individual RFCs once the SDK stabilizes toward 1.0. A capsule author depending on `astrid-sdk` today gets the full current surface unconditionally.

## Rationale for the Separate Repository

Three design choices are worth calling out explicitly, because they mirror decisions made in larger ecosystems.

**Separate repository, not GitHub issues.** Issues lack the structured format needed for interface specifications. An RFC as a versioned Markdown file provides diffs, line-level review, and a permanent record that issues do not.

**Number assigned at merge, not PR open.** Prevents spam PRs from burning numbers. Python PEPs use editor-assigned numbers for the same reason.

**Scope limited to the contract surface.** Kernel internals and capsule internals can iterate fast without coordination. The contract surface is where stability matters because it affects every capsule author on both sides of the boundary. POSIX is the analogue: it standardizes the syscall interface between kernel and user space; Astrid's host ABI is the same kind of boundary.

## Current RFC Index

| RFC | Title | Status |
|-----|-------|--------|
| [0001](https://github.com/unicity-astrid/rfcs/blob/main/text/0001-rfc-process.md) | RFC Process | Active |

Draft RFCs on open branches include the host ABI initial syscall set, a Cargo-like manifest schema, the `astrid:net` TCP surface expansion, a users capsule interface, and others. None carry a number until merged.

## See also

- [WIT Contracts and the Three-Repo Flow](wit-contracts.md)
- [ABI Evolution](../host-abi/abi-evolution.md)
