# Summary

[Introduction](./introduction.md)

# Part I: Foundations

- [The Kernel Is Dumb](./foundations/kernel-is-dumb.md)
- [The Boot Sequence](./foundations/boot-sequence.md)

# Part II: The Capsule Model

- [The Capsule Manifest and Engines](./capsule-model/manifest-and-engines.md)
- [Imports, Exports, and Dependency Resolution](./capsule-model/imports-exports-resolution.md)
- [Capsule Lifecycle](./capsule-model/lifecycle.md)

# Part III: The Host ABI

- [The Syscall Surface](./host-abi/the-syscall-surface.md)
- [Packages: Filesystem, IO, and Storage](./host-abi/packages-fs-io-storage.md)
- [Packages: IPC, Net, HTTP, Sys, Process](./host-abi/packages-ipc-net-http-sys-process.md)
- [Packages: Approval, Identity, Uplink](./host-abi/packages-approval-identity-uplink.md)
- [Capability Gating](./host-abi/capability-gating.md)
- [ABI Evolution](./host-abi/abi-evolution.md)

# Part IV: The Bus

- [Topics and Wildcards](./bus/topics-and-wildcards.md)
- [Interceptors](./bus/interceptors.md)
- [Tools as an IPC Convention](./bus/tools-as-ipc.md)
- [Per-Principal Routing and Backpressure](./bus/routing-and-backpressure.md)

# Part V: Security

- [The Five-Layer Security Gate](./security/five-layer-gate.md)
- [Capabilities, Tokens, and Delegation](./security/capabilities-and-tokens.md)
- [Policy, Budget, Approval, and Audit](./security/policy-budget-approval-audit.md)
- [The OS Process Sandbox](./security/os-process-sandbox.md)

# Part VI: Storage and State

- [The VFS Copy-on-Write Overlay](./storage/vfs-overlay.md)
- [KV Storage](./storage/kv.md)
- [The Cryptographic Audit Chain](./storage/audit-chain.md)

# Part VII: Identity and Multi-Principal

- [PrincipalId and Per-Invocation Isolation](./identity/principal-and-isolation.md)
- [Profiles, Groups, and Quotas](./identity/profiles-groups-quotas.md)

# Part VIII: Distribution

- [Distros and the Content-Addressed Store](./distribution/distros-and-store.md)
- [The Build Pipeline and WASM Targets](./distribution/build-pipeline.md)

# Part IX: Evolution

- [The RFC Process](./evolution/rfc-process.md)
- [WIT Contracts and the Three-Repo Flow](./evolution/wit-contracts.md)

# Appendices

- [Capability Catalog](./appendix/capability-catalog.md)
- [Host ABI Error Codes](./appendix/error-codes.md)
- [Topic Registry](./appendix/topic-registry.md)
