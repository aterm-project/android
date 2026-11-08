# Local Drift patch

This directory is based on the Drift 2.35.0 package source. It is kept as a
local dependency override because the Web IndexedDB SharedWorker needs a small
storage correctness patch.

`lib/wasm.dart` serializes requests to one IndexedDB-backed delegate, flushes
SQLite blocks before an outer COMMIT releases Drift's cross-port transaction
lock, and permanently rejects later requests after a failed flush. This keeps
another SharedWorker port from reading an uncertain SQLite page cache. OPFS
and native database connections do not use this patched IndexedDB path.

When upgrading Drift, reapply and revalidate this patch against the new
`_WasmDelegate` and `DriftServer` behavior before updating the override.
