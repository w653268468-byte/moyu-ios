# Gavin QuickJS-Swift patch

Upstream: https://github.com/zqqf16/QuickJS-Swift

Exact base commit: `50eb132d6bc89736f478cf8336948fb62133a264`.
The downloaded archive's 40 Git blob hashes were verified against that commit.
Upstream sources, tests and MIT notices are retained; package metadata and engine
version are unchanged.

Local change: `JSRuntime.perform` calls QuickJS's `JS_UpdateStackTop` before the
outermost engine entry. A serial dispatch queue serializes work but can execute
successive synchronous calls on different OS threads. Without updating the
recorded stack origin, cached source runtimes can report false stack overflows
after an asynchronous network request. Nested host calls keep the outer stack
origin, so the engine's stack bound is preserved across re-entrant callbacks.

Verification: the application's delayed multi-source script test and explicit
cross-thread script regression test, plus the upstream package tests. Stack,
CPU and memory limits remain enabled. The pinned source is included here so
both SwiftPM and Xcode build the same patched implementation offline.
