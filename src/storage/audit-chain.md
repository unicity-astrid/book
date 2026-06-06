# The Cryptographic Audit Chain

Every action that Astrid takes on behalf of a user is recorded as an immutable, chain-linked, cryptographically signed audit entry. The audit log is not a passive log file. It is a tamper-evident ledger: any modification to a historical entry breaks the chain and is detectable at verification time. This page covers the data model, cryptographic construction, per-principal chain splitting, verification algorithms, and key rotation semantics as implemented in `core/crates/astrid-audit`.

## Overview

The audit subsystem has three layers:

1. **Entry** (`entry.rs`): the signed, chain-linked record of a single event.
2. **Log** (`log.rs`): the high-level API that creates, stores, and verifies entries.
3. **Storage** (`storage.rs`): a pluggable `AuditStorage` trait backed by `SurrealKV`.

The crate re-exports `AuditEntryId` from `astrid-capabilities`, so callers reference a single canonical ID type.

```
[AuditLog]
  |-- append() / append_with_principal()
  |       \-- AuditEntry::create / ::create_with_principal
  |               \-- runtime_key.sign(signing_data)
  |-- verify_chain() / verify_principal_chain()
  |-- storage: Box<dyn AuditStorage>
         \-- SurrealKvAuditStorage (production)
         \-- SurrealKvAuditStorage::in_memory() (tests, backed by MemoryKvStore)
```

## The AuditEntry Structure

`entry.rs:16`

```rust
pub struct AuditEntry {
    pub id: AuditEntryId,
    pub timestamp: Timestamp,
    pub session_id: SessionId,
    pub principal: Option<PrincipalId>,   // None = system action
    pub action: AuditAction,
    pub authorization: AuthorizationProof,
    pub outcome: AuditOutcome,
    pub previous_hash: ContentHash,        // BLAKE3 hash of previous entry
    pub runtime_key: PublicKey,            // embedded at write time
    pub signature: Signature,              // ed25519 over all fields above
}
```

Every field up to and including `runtime_key` contributes to the signature. The embedded `runtime_key` is the public half of whichever runtime keypair was active when the entry was created. This is the mechanism that makes key rotation safe: verification always uses the key recorded inside the entry, not the key currently held by the `AuditLog`.

## Cryptographic Primitives

**Hashing: BLAKE3** (`astrid-crypto/src/hash.rs:16`)

```rust
pub struct ContentHash([u8; 32]);

impl ContentHash {
    pub fn hash(data: &[u8]) -> Self {
        Self(*blake3::hash(data).as_bytes())
    }
    pub const fn zero() -> Self { Self([0u8; 32]) }
    pub fn is_zero(&self) -> bool { self.0 == [0u8; 32] }
}
```

`ContentHash::zero()` is the sentinel for the genesis entry: a chain's first entry has `previous_hash == ContentHash::zero()`. Verification checks this invariant explicitly.

**Signing: Ed25519** (`astrid-crypto/src/keypair.rs:19`)

```rust
#[derive(ZeroizeOnDrop)]
pub struct KeyPair {
    #[zeroize(skip)]
    verifying_key: VerifyingKey,  // ed25519-dalek
    signing_key: SigningKey,
}
```

`ZeroizeOnDrop` is derived on the `KeyPair` struct itself. The `verifying_key` field carries `#[zeroize(skip)]` because `VerifyingKey` does not implement `Zeroize`. `KeyPair::generate()` draws entropy from `OsRng`. There is no static or hardcoded key; the kernel generates a fresh keypair at startup.

**Signature verification** (`astrid-crypto/src/signature.rs:89`)

```rust
pub fn verify(&self, message: &[u8], public_key: &[u8; 32]) -> CryptoResult<()> {
    let verifying_key = VerifyingKey::from_bytes(public_key)?;
    let sig = DalekSignature::from_bytes(&self.0);
    verifying_key.verify(message, &sig)
        .map_err(|_| CryptoError::SignatureVerificationFailed)
}
```

Notice that `verify` takes the public key as a plain byte slice, not a `KeyPair`. The `AuditEntry::verify_signature` method supplies `entry.runtime_key.as_bytes()` directly, so each entry is self-verifying without access to the live signing key.

## Signing Data Construction

The signed payload is constructed deterministically by `AuditEntry::signing_data()` (`entry.rs:123`). Field order and encoding are fixed:

| Field | Encoding |
|---|---|
| `id` | 16-byte UUID raw bytes |
| `timestamp` | i64 Unix seconds, little-endian |
| `session_id` | 16-byte UUID raw bytes |
| `principal` | `0xFF` + u32 length LE + UTF-8 bytes, or `0x00` |
| `action` | `serde_json::to_vec` |
| `authorization` | `serde_json::to_vec` |
| `outcome` | 1-byte boolean (success = 1, failure = 0) |
| `previous_hash` | 32 raw bytes |
| `runtime_key` | 32 raw bytes |

The principal field uses a length-delimited encoding with explicit presence markers (`0xFF` / `0x00`) to prevent ambiguity between an absent principal and a zero-length principal value adjacent to the next field.

The content hash of an entry is `ContentHash::hash(&entry.signing_data())`. This is the value stored in the next entry's `previous_hash`.

```rust
pub fn content_hash(&self) -> ContentHash {
    ContentHash::hash(&self.signing_data())
}
```

## Entry Creation

`AuditEntry::create` (`entry.rs:67`) is the primary constructor. It takes the previous hash and the live `KeyPair` as arguments:

```rust
pub fn create(
    session_id: SessionId,
    action: AuditAction,
    authorization: AuthorizationProof,
    outcome: AuditOutcome,
    previous_hash: ContentHash,
    runtime_key: &KeyPair,
) -> Self {
    let mut entry = Self::new_unsigned(
        session_id, action, authorization, outcome,
        previous_hash,
        runtime_key.export_public_key(),  // snapshot the public key
    );
    let signing_data = entry.signing_data();
    entry.signature = runtime_key.sign(&signing_data);
    entry
}
```

`new_unsigned` sets the `signature` field to `[0u8; 64]` as a placeholder. The real signature replaces it before the entry is returned. The placeholder is never persisted: `create` returns the fully signed entry.

`AuditEntry::create_with_principal` is identical but also sets `entry.principal = Some(principal)` before computing the signing data. Because `principal` contributes to the payload, an entry created without a principal cannot be retroactively attributed to one without invalidating its signature.

## The Chain Invariant

A chain is a sequence of entries where:

1. The first entry's `previous_hash` is `ContentHash::zero()` (genesis).
2. Each subsequent entry's `previous_hash` equals the `content_hash()` of the entry before it.
3. Every entry's `signature` verifies against its own embedded `runtime_key`.

The `follows` method encodes condition 2:

```rust
pub fn follows(&self, previous: &AuditEntry) -> bool {
    self.previous_hash == previous.content_hash()
}
```

Any out-of-order insertion, deletion, or field mutation breaks at least one of these invariants.

## Per-Principal Chain Splitting

A single session can involve multiple principals (users) plus system actions. Rather than interleaving all entries into one chain, the audit log maintains independent chains keyed by `(SessionId, Option<PrincipalId>)`.

`log.rs:20`

```rust
type ChainKey = (SessionId, Option<PrincipalId>);
```

The `chain_heads` map in `AuditLog` caches the current head of each chain as a `ContentHash`. On every append, the relevant chain head is looked up, used as `previous_hash`, and then updated to the new entry's hash.

```rust
// log.rs:106
let chain_key: ChainKey = (session_id.clone(), principal.clone());
let previous_hash = self.get_previous_hash(&chain_key)?;
```

`get_previous_hash` checks the in-memory cache first, then falls back to the storage backend's `get_chain_head`, which stores the latest `AuditEntryId` per chain under the namespace `audit:chain_heads`. The storage key format is:

- System chain: `"{session_uuid}"`
- Principal chain: `"{session_uuid}:{principal}"`

(`storage.rs:150`)

This design means Alice's tool calls form a completely separate chain from Bob's tool calls, even within the same session. A tampered entry in Alice's chain does not affect Bob's chain or the system chain.

## AuditLog API

### Construction

```rust
// Production: SurrealKV on disk
let log = AuditLog::open("/var/lib/astrid/audit", runtime_key)?;

// Tests: in-memory MemoryKvStore
let log = AuditLog::in_memory(runtime_key);
```

### Appending Entries

```rust
// System action (no principal)
let id = log.append(
    session_id,
    AuditAction::SessionStarted { user_id, platform: "cli".to_string() },
    AuthorizationProof::System { reason: "session start".to_string() },
    AuditOutcome::success(),
)?;

// Principal-attributed action
let id = log.append_with_principal(
    session_id,
    alice_principal,
    AuditAction::FileWrite { path: "/tmp/out.txt".into(), content_hash },
    AuthorizationProof::Capability { token_id, token_hash },
    AuditOutcome::success(),
)?;
```

Both methods are synchronous from the caller's perspective. The storage backend performs I/O inside `block_on`, which uses `tokio::task::block_in_place` on the multi-threaded runtime (production) and a scoped thread on single-threaded runtimes (tests). See `storage.rs:106` for the three-way dispatch logic.

### Retrieving Entries

```rust
// Single entry by ID
let entry: Option<AuditEntry> = log.get(&entry_id)?;

// All entries in a session (insertion order)
let entries: Vec<AuditEntry> = log.get_session_entries(&session_id)?;

// Entries for one chain only
let alice_entries = log.get_principal_entries(&session_id, Some(&alice))?;
let system_entries = log.get_principal_entries(&session_id, None)?;
```

## Verification

### verify_chain

`AuditLog::verify_chain` verifies every chain in a session. It groups entries by `principal`, sorts each group by timestamp, and checks three properties in order:

1. Genesis: `chain_entries[0].previous_hash.is_zero()`
2. Signatures: `entry.verify_signature()` for every entry.
3. Links: `curr.follows(prev)` for each consecutive pair.

```rust
pub fn verify_chain(&self, session_id: &SessionId) -> AuditResult<ChainVerificationResult>
```

The result type carries `valid`, `entries_verified`, and a `Vec<ChainIssue>`:

```rust
pub enum ChainIssue {
    InvalidGenesis { entry_id: AuditEntryId },
    InvalidSignature { entry_id: AuditEntryId },
    BrokenLink {
        entry_id: AuditEntryId,
        expected_previous: ContentHash,
        actual_previous: ContentHash,
    },
}
```

`verify_chain` never short-circuits on the first failure. It collects all issues so an auditor can see the full extent of tampering.

### verify_principal_chain

For targeted verification of a single chain:

```rust
// Verify Alice's chain only
let result = log.verify_principal_chain(&session_id, Some(&alice))?;

// Verify the system chain
let result = log.verify_principal_chain(&session_id, None)?;
```

This is equivalent to calling `verify_chain` on a session that contains only entries for the specified principal. The same three-check sequence applies.

### verify_all

```rust
let results: Vec<(SessionId, ChainVerificationResult)> = log.verify_all()?;
```

Iterates every session returned by `storage.list_sessions()` and calls `verify_chain` on each. Useful for a background integrity sweep or a startup self-check.

## Tamper Detection in Practice

The test suite in `log_tests.rs` demonstrates the three tamper scenarios:

**Corrupted signature** (`test_verify_detects_tampered_signature`): XOR the first byte of an entry's signature. `verify_chain` reports `ChainIssue::InvalidSignature` for that entry.

**Broken link** (`test_verify_detects_broken_link`): Overwrite `previous_hash` and re-sign with the original key (so the signature is valid). `verify_chain` reports only `ChainIssue::BrokenLink`, not `InvalidSignature`. This proves the two checks are independent and that a valid signature does not imply chain integrity.

**Invalid genesis** (`test_verify_detects_invalid_genesis`): Set a non-zero `previous_hash` on the first entry and re-sign. `verify_chain` reports only `ChainIssue::InvalidGenesis`.

All three are distinct, non-overlapping failure modes.

## Key Rotation

Entries embed the public key at the time of creation (`runtime_key: PublicKey`). Verification calls `entry.runtime_key.verify(signing_data, &entry.signature)`, using the entry's own embedded key rather than the `AuditLog`'s current `runtime_key` field.

This means entries written under key A remain verifiable after the runtime rotates to key B. The test `test_key_rotation_entries_verify_via_embedded_pubkey` (`log_tests.rs:233`) demonstrates this explicitly:

```rust
// Write 3 entries signed by key A.
let log_a = AuditLog::in_memory(keypair_a);
append_test_entries(&log_a, &session_id, 3);

// Move entries into a log that holds key B.
let log_b = AuditLog::in_memory(keypair_b);
for entry in log_a.get_session_entries(&session_id)? {
    log_b.storage.store(&entry)?;
}

// Verification succeeds because each entry carries its own public key.
let result = log_b.verify_chain(&session_id)?;
assert!(result.valid);
```

An auditor reading the chain sees exactly which runtime key signed each entry. If a key was compromised on a specific date, the auditor can identify which entries were produced under that key and which were produced under its successor.

## AuditAction Catalog

The `AuditAction` enum (`entry.rs:190`) covers every security-relevant event class. Selected variants:

| Variant | Privacy note |
|---|---|
| `McpToolCall { server, tool, args_hash }` | Arguments are hashed, not stored plaintext |
| `CapsuleToolCall { capsule_id, tool, args_hash }` | Same hashing policy |
| `FileWrite { path, content_hash }` | Content is hashed, not stored |
| `CapabilityCreated { token_id, resource, permissions, scope }` | Full grant detail |
| `ApprovalGranted { action, resource, scope }` | Consent chain |
| `SubAgentSpawned { parent_session_id, child_session_id, description }` | Parent-child linkage |
| `AdminRequest { method, required_capability, target_principal, params }` | Forensic params field |
| `SecurityViolation { violation_type, details }` | Policy enforcement |

The `args_hash` pattern lets the chain prove that a specific tool was called with specific arguments (by presenting the preimage), without storing potentially sensitive argument values in the audit store.

## AuthorizationProof

Every entry carries an `AuthorizationProof` that records why the action was permitted:

```rust
pub enum AuthorizationProof {
    User { user_id: [u8; 8], message_id: String },
    Capability { token_id: TokenId, token_hash: ContentHash },
    UserApproval { user_id: [u8; 8], approval_entry_id: Option<AuditEntryId> },
    NotRequired { reason: String },
    System { reason: String },
    Denied { reason: String },
}
```

`Capability::token_hash` links the audit record to the exact capability token that authorized the action. `UserApproval::approval_entry_id` links back to the `ApprovalGranted` entry in the same chain, creating a cross-reference between the consent event and the action it authorized.

Denied actions use `AuthorizationProof::Denied` paired with `AuditOutcome::failure`. This means denials are audited with the same chain-linked guarantees as successes.

## Storage Layout

The `SurrealKvAuditStorage` backend uses three namespaces inside `astrid-storage`'s `KvStore`:

| Namespace | Key | Value |
|---|---|---|
| `audit:entries` | `{entry_uuid}` | JSON-serialized `AuditEntry` |
| `audit:session_index` | `{session_uuid}` | JSON array of `AuditEntryId` (insertion order) |
| `audit:chain_heads` | `{session_uuid}` or `{session_uuid}:{principal}` | UTF-8 UUID of the latest entry for that chain |

The session index is an ordered list of all entry IDs for a session, regardless of which chain they belong to. Chain-specific ordering is recovered by filtering on `entry.principal` and sorting by timestamp. The storage never deletes or updates entries; it only appends.

## Error Handling

All public methods return `AuditResult<T>`, which is `Result<T, AuditError>`:

```rust
pub enum AuditError {
    StorageError(String),
    SerializationError(String),
    EntryNotFound { entry_id: String },
    IntegrityViolation { entry_id: String, reason: String },
    InvalidSignature { entry_id: String },
    SessionNotFound { session_id: String },
    CryptoError(#[from] astrid_crypto::CryptoError),
}
```

`IntegrityViolation` is returned from the storage layer when a structural problem is found during retrieval. `InvalidSignature` as an `AuditError` is distinct from `ChainIssue::InvalidSignature`: the `AuditError` variant is returned by `AuditEntry::verify_signature` and bubbled up only when verification is called as a standalone operation. During `verify_chain`, the issue is collected into `Vec<ChainIssue>` rather than returned as an error, so the caller sees the complete picture.

## Summary

The audit chain provides three layered guarantees:

1. **Integrity per entry**: the ed25519 signature over all fields means any single-byte mutation to a stored entry is detected by `verify_signature`.
2. **Ordering integrity**: the BLAKE3 `previous_hash` linkage means insertions, deletions, and reorderings are detected by `verify_chain`.
3. **Attribution clarity**: per-principal chain splitting means Alice's chain and Bob's chain are independently verifiable, and a corrupted entry in one does not pollute the verification result of the other.

Key rotation is handled transparently because the public key is embedded in every entry at write time, and `verify_signature` uses only that embedded key.

## See also

- [The Five-Layer Security Gate](../security/five-layer-gate.md)
- [Capabilities, Tokens, and Delegation](../security/capabilities-and-tokens.md)
