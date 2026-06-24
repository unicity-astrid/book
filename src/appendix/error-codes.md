# Appendix: Host ABI Error Codes

Generated from the `error-code` variants in `wit/host/*.wit`. Every fallible host function returns `result<_, error-code>`. The `unknown(string)` arm carries a host-formatted detail string and is the catch-all; the named arms let a capsule match a specific failure without parsing text.

## `approval@1.0.0`

`invalid-input`: The provided input does not meet the required format or criteria., `timeout`, `store-unavailable`, `unknown(string)`

## `elicit@1.0.0`

`not-in-lifecycle`, `timeout`, `cancelled`, `invalid-input`, `store-unavailable`, `unknown(string)`

## `fs@1.0.0`

`not-found`, `access`, `capability-denied`, `boundary-escape`, `invalid-path`, `would-block`, `is-directory`, `not-directory`, `not-empty`, `too-large`, `quota`, `cross-vfs`, `already-exists`, `closed`, `unknown(string)`

## `http@1.0.0`

`capability-denied`, `invalid-request`, `dns-error`, `airlock-rejected`, `tls-error`, `timeout`, `connection-error`, `body-too-large`, `closed`, `quota`, `protocol(string)`, `unknown(string)`

## `identity@1.0.0`

`capability-denied`, `invalid-input`, `user-not-found`, `link-not-found`, `already-linked`, `store-unavailable`, `unknown(string)`

## `io@1.0.0`

`invalid-input`, `closed`, `too-large`, `cancelled`, `unknown(string)`

## `ipc@1.0.0`

`capability-denied`, `invalid-input`, `closed`, `rate-limited`, `backpressure`, `quota`, `timeout`, `unknown(string)`

## `kv@1.0.0`

`invalid-key`, `too-large`, `quota`, `cas-mismatch`, `unknown(string)`

## `net@1.0.0`

`would-block`, `closed`, `capability-denied`, `airlock-rejected`, `connection-refused`, `connection-reset`, `timeout`, `address-in-use`, `address-not-available`, `name-unresolvable`, `invalid-handle`, `not-tcp`, `quota`, `unknown(string)`

## `process@1.0.0`

`capability-denied`, `invalid-input`, `boundary-escape`, `quota`, `too-large`, `closed`, `cancelled`, `wait-timeout`, `unknown(string)`

## `sys@1.0.0`

`capability-denied`, `config-key-reserved`, `too-large`, `registry-unavailable`, `cancelled`, `unknown(string)`

## `uplink@1.0.0`

`capability-denied`, `invalid-input`, `invalid-profile`, `unknown-uplink`, `no-session`, `quota`, `unknown(string)`

