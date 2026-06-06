# The OS Process Sandbox

A capsule runs as WebAssembly, so the WASM sandbox contains it completely: no syscalls, no file descriptors, no host memory, every external effect gated through the host ABI. But a capsule can ask the host to spawn a real native subprocess (the `host_process` capability, used by MCP server capsules and by any tool that shells out to `git`, `npm`, `node`, a compiler). That subprocess is an ordinary OS process. The WASM sandbox does not contain it, because it is not WASM. So Astrid wraps it in a second, OS-level sandbox.

This chapter is about that second sandbox: `bubblewrap` on Linux, Seatbelt (`sandbox-exec`) on macOS. The crate is `astrid-workspace`.

## Two sandboxes, two jobs

| Sandbox | Contains | Mechanism |
|---|---|---|
| WASM sandbox | the capsule's own code | Wasmtime, host ABI only, no ambient authority |
| OS process sandbox | native subprocesses the capsule spawns | bubblewrap (Linux) or Seatbelt (macOS) |

The two are independent. A capsule with no `host_process` capability never spawns a subprocess and only ever touches the WASM sandbox. A capsule that does spawn one is trusting the OS process sandbox to keep that subprocess inside the same boundary the capsule itself lives in.

## Where a capsule actually is: two layers

This is the part that surprises people, so it goes first. There are two different notions of "the filesystem" in play, and they treat your home directory oppositely.

**The VFS layer (the capsule's own file access, through the host ABI).** The capsule sees two schemes:

- `cwd://` resolves to the workspace, which is the real project directory you launched Astrid in. Same folder. Writes land in the copy-on-write overlay until a human commits them.
- `home://` resolves to the per-principal Astrid home, `~/.astrid/home/{principal}/`, not your real `~`. It is resolved per invoking principal, so two principals sharing one `cwd://` get two different `home://`.

So at this layer your intuition holds exactly: the capsule touches the same project folder you did, but its "home" is Astrid's home, not yours.

**The native subprocess layer (a process the capsule shells out to).** Here `HOME` is not remapped. `prepare_sandboxed_command`
(`core/crates/astrid-capsule/src/engine/wasm/host/process/managed.rs`) strips `ASTRID_HOME`, `ASTRID_SOCKET_PATH`, and `ASTRID_SESSION_TOKEN` from the environment (so the subprocess cannot find the kernel socket, present the session token, or locate the Astrid home), then hands the command to the OS sandbox. It leaves `HOME` alone, so the subprocess inherits the daemon's `HOME`, which is your real home. What the sandbox changes is not the value of `HOME` but the subprocess's *reach*: the workspace is the only place it can write, and on macOS your home is not even readable.

The one-line model: the workspace is the same real folder at both layers; "home" means Astrid's per-principal home to the capsule, and your real home to a subprocess that is write-locked out of it.

## Linux: bubblewrap

The Linux sandbox prepends `bwrap` with mount rules (`core/crates/astrid-workspace/src/sandbox/bwrap.rs`, `build_bwrap_prefix`):

- `--ro-bind / /` mounts the entire host filesystem read-only at its real paths, so binaries and libraries resolve normally.
- `--dev /dev`, `--proc /proc`, and `--tmpfs /tmp` give standard device, proc, and a disposable tmp.
- `--bind <workspace> <workspace>` mounts the workspace read-write at its same absolute path.
- Each hidden path is overlaid with `--tmpfs` to blank it out. Hidden tmpfs mounts are emitted before the writable bind so a writable directory nested inside a hidden one (for example a capsule dir under a hidden `~/.astrid`) can punch back through.
- `--unshare-all` drops every namespace, then `--share-net` restores networking so `npm` and `cargo` can fetch. `--die-with-parent` prevents orphans.

Read posture on Linux: because of `--ro-bind / /`, a subprocess can *read* your whole home read-only, including `~/.ssh`, unless that path is explicitly hidden. It can only *write* to the workspace and `/tmp`.

Availability is probed at runtime, not assumed. `bwrap_available()` runs `bwrap --unshare-user --ro-bind / / -- /bin/true` once and caches the result. On Ubuntu 24.04 and later, `kernel.apparmor_restrict_unprivileged_userns=1` blocks unprivileged user namespaces and the probe fails; the remediation is `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` or installing `bubblewrap`.

## macOS: Seatbelt

The macOS sandbox prepends `sandbox-exec -p <profile>` with an inline SBPL profile, built by `build_seatbelt_prefix`
(`core/crates/astrid-workspace/src/sandbox/seatbelt.rs`). The profile is delivered inline via `-p` rather than a temp file, which avoids a temp-file leak and the TOCTOU window a file would open. Its shape:

```scheme
(version 1)
(deny default)
(allow process-exec*)
(allow process-fork)
(allow network*)          ; omitted when network is disabled
(allow sysctl-read)
(allow ipc-posix-shm)
(allow mach*)
(allow file-read*
    (subpath "/usr") (subpath "/bin") (subpath "/sbin")
    (subpath "/System") (subpath "/Library") (subpath "/opt") (subpath "/dev")
    (subpath "<workspace>")
    (subpath "/private/tmp") (subpath "/var/folders")
    (literal "/"))
(allow file-write*
    (subpath "<workspace>")
    (subpath "/private/tmp") (subpath "/var/folders")
    (literal "/dev/null"))
; per hidden path, unless it is an ancestor of the workspace:
(deny file-read*  (subpath "<hidden>"))
(deny file-write* (subpath "<hidden>"))
```

Two rules are load-bearing and easy to miss. `(allow mach*)` lets a modern binary complete its Mach-service lookups at startup. `(literal "/")` lets it read the filesystem root entry, which binaries such as `node` stat while resolving real paths. Without either, a `(deny default)` profile fails closed and the process aborts with SIGABRT, which is the sandbox working correctly, not the OS refusing to sandbox. A hidden path is expressed as a pair of `deny` rules, and is skipped when it is an ancestor of the workspace, because denying even `lstat()` on a parent directory would stop the subprocess from resolving paths inside its own workspace.

Read posture on macOS: the profile is `(deny default)`, and the read allowlist is system directories plus the workspace plus tmp plus the literal root. Your home is not on it, so a subprocess cannot read `~/.ssh` or your dotfiles at all. Writes are the workspace and tmp.

`sandbox-exec` is deprecated by Apple in the sense that it prints a deprecation notice, but it still enforces on current macOS, and Astrid applies it on every supported macOS version. The deprecation is a medium-term migration concern (Apple's direction is virtualization-based isolation, on Apple's timeline) and not a reason to skip a working primitive. As on Linux, the right question is whether the primitive applies at runtime, not which OS version is running.

## The cross-platform asymmetry

This difference is real and worth designing around:

- **Writes:** both platforms confine writes to the workspace and tmp. Identical guarantee.
- **Reads:** Linux exposes the whole host filesystem read-only (`--ro-bind / /`), so a subprocess can read your home unless a path is hidden. macOS is `(deny default)`, so a subprocess cannot read your home at all.

If a capsule spawns a subprocess that should never see your credentials, macOS already prevents it; on Linux you must add the sensitive path to the sandbox's hidden set. Do not assume the Linux read posture matches the macOS one.

## Fail secure: SandboxPolicy

When the OS sandbox cannot be applied, behavior is governed by `SandboxPolicy` (`core/crates/astrid-workspace/src/sandbox/mod.rs`), resolved from `ASTRID_SANDBOX_POLICY`:

- `Required` (the default) refuses to launch the subprocess and returns an error with an actionable hint. A native tool never runs uncontained by accident.
- `Off` launches without a sandbox, with no warning. This is an explicit operator opt-out for trusted dev environments or CI runners where the kernel cannot be configured for unprivileged namespaces.

There is deliberately no "warn and run anyway" middle state. A soft fallback hides the fact that the security model stopped applying, which is exactly the failure to avoid. Either the sandbox is applied, or the operator explicitly accepted that it is not.

## What the subprocess gets, and what it loses

| Property | Value |
|---|---|
| Writable | the workspace and `/tmp` only |
| Readable | whole host read-only on Linux; system dirs plus workspace plus tmp on macOS |
| `HOME` | inherited (your real home), but write-locked out of it everywhere, and unreadable on macOS |
| Stripped env | `ASTRID_HOME`, `ASTRID_SOCKET_PATH`, `ASTRID_SESSION_TOKEN` |
| Network | on by default (`--share-net` / `(allow network*)`), removable per spawn |
| SBPL injection | workspace and path strings are rejected if they contain a quote, backslash, null byte, or are not absolute |

The subprocess can do real work in your project and reach the network, and it cannot write outside the project, cannot read your home on macOS, and cannot talk back to the kernel.

## See also

- [The Five-Layer Security Gate](five-layer-gate.md)
- [Packages: IPC, Net, HTTP, Sys, Process](../host-abi/packages-ipc-net-http-sys-process.md)
- [The VFS Copy-on-Write Overlay](../storage/vfs-overlay.md)
- [Capability Gating](../host-abi/capability-gating.md)
