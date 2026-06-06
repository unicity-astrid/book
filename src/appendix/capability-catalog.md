# Appendix: Capability Catalog

Generated from `CAPABILITY_CATALOG` in `core/crates/astrid-core/src/capability_grammar.rs`, the single source of truth shared by the kernel drift tests and the gateway `/api/sys/capabilities` route. Do not hand-edit. Regenerate with `astrid-book/tools/gen-appendices.sh`.

Scope `self` means the capability acts only on the caller's own principal. `global` means it can target any principal or system-wide state. Danger tiers, lowest to highest: Safe, Normal, Elevated, Extreme. Order matches the catalog, which is part of the stable wire contract.

| Capability | Scope | Danger | Description |
|---|---|---|---|
| `system:shutdown` | global | Extreme | Gracefully stop the Astrid daemon. The CLI and dashboard disconnect; pending work is allowed to finish under the configured shutdown grace period. |
| `system:status` | global | Safe | View daemon PID, uptime, connected-client count, and loaded-capsule list. |
| `capsule:install` | global | Extreme | Install a new capsule into the system-wide capsule directory. Affects every principal on the host. |
| `self:capsule:install` | self | Elevated | Install a capsule into the caller's own workspace. Future kernel work; see also: capsule:install. |
| `capsule:reload` | global | Normal | Trigger a re-discovery of installed capsules system-wide. Causes a brief pause as capsules unload and reload. |
| `self:capsule:reload` | self | Normal | Self-scoped variant of capsule:reload. |
| `capsule:list` | global | Safe | Enumerate every capsule installed on the host, including manifest metadata. |
| `self:capsule:list` | self | Safe | Self-scoped variant of capsule:list. Always granted to the agent built-in. |
| `agent:create` | global | Normal | Provision a new agent principal. Doesn't grant any caps by itself, combine with caps:grant or move the new agent into a group. |
| `agent:delete` | global | Elevated | Remove an agent principal. Cannot delete the bootstrap `default` principal. The principal's home directory is NOT scrubbed (ops concern). |
| `agent:enable` | global | Normal | Re-enable a previously disabled agent. New invocations resume. |
| `agent:disable` | global | Elevated | Suspend an agent without deleting it. In-flight invocations finish under the old value; new ones are refused. |
| `agent:modify` | global | Elevated | Add or remove group memberships on an agent. Changes which capabilities the agent inherits. |
| `agent:list` | global | Safe | Enumerate every agent principal on this host with their groups, grants, and revokes. |
| `self:agent:list` | self | Safe | Read this principal's own AgentSummary. Always granted to the agent built-in so members can introspect their own permissions. |
| `quota:set` | global | Normal | Set resource ceilings (RAM, CPU time, IPC throughput) on any agent. |
| `self:quota:set` | self | Normal | Self-scoped quota:set, typically only used to relax quotas the operator already permits. |
| `quota:get` | global | Safe | View the resource ceilings configured on any agent. |
| `self:quota:get` | self | Safe | Read the caller's own resource ceilings. Always granted to the agent built-in. |
| `group:create` | global | Elevated | Define a new custom capability group. Members inherit the group's capabilities. |
| `group:delete` | global | Elevated | Remove a custom capability group. Built-in groups (admin, agent, restricted) cannot be deleted. |
| `group:modify` | global | Elevated | Edit the capabilities, description, or `unsafe_admin` flag on a custom group. Changes propagate to every member on the next authz check. |
| `group:list` | global | Safe | Enumerate every group (built-in + custom) with its capability set. |
| `self:group:list` | self | Safe | Self-scoped group:list, for resolving the caller's own inherited capabilities. Always granted to the agent built-in. |
| `caps:grant` | global | Extreme | Append capability patterns to a principal's grants. With `unsafe_admin`, can mint wildcard (`*`) grants. Effectively a meta-permission, anyone with this can elevate themselves. |
| `caps:revoke` | global | Elevated | Append capability patterns to a principal's revokes (highest-precedence deny). Cannot revoke from the bootstrap `default` principal. |
| `invite:issue` | global | Elevated | Mint invite tokens that let new principals self-enroll into a designated group. The token IS the auth, anyone holding it can redeem. |
| `invite:redeem` | global | Normal | Capability name preserved for completeness, the kernel bypasses the cap check on redemption because the token itself is the auth. Granting this to anyone is a no-op. |
| `invite:list` | global | Safe | Enumerate outstanding invite tokens by fingerprint (never the raw token). |
| `invite:revoke` | global | Normal | Invalidate an outstanding invite token before it's redeemed. |
| `audit:read_all` | global | Elevated | Subscribe to every audit entry across every principal via /api/events. Without this cap, the SSE stream is filtered to the caller's own entries only. |
| `self:approval:respond` | self | Safe | Respond to capability-approval prompts addressed to this principal. Always granted to the agent built-in (an agent can only approve its own requests, never another's). |
| `self:auth:pair` | self | Normal | Mint a short-lived pair-device token that lets a new device add its ed25519 public key to this principal's AuthConfig.public_keys. The kernel always binds the token to the caller's own principal regardless of wire-level hints. |
| `auth:pair:redeem` | global | Normal | Capability name preserved for completeness, the kernel bypasses the cap check on pair-device redemption because the token itself is the auth. Granting this to anyone is a no-op. |

_34 capabilities._

## Runtime exemption capabilities

These are not management-API capabilities. They are operator-granted profile capabilities that lift a runtime ceiling (the per-invocation CPU epoch interrupt or the bind/uplink restriction). A capsule cannot self-grant them through its manifest.

| Constant | Capability string |
|---|---|
| `CAP_RESOURCES_UNBOUNDED` | `system:resources:unbounded` |
| `CAP_NET_BIND` | `net_bind` |
| `CAP_UPLINK` | `uplink` |

