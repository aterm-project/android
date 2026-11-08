# Local patch

This directory is the upstream `sqlite3` Dart package at version 3.6.0, copied
from the locked Pub release so the Web storage fix is reproducible. The local
change makes an IndexedDB transaction abort fail the pending VFS flush instead
of resolving it like a successful commit. A failed VFS operation also waits for
its abort event before returning the original error.

The source is licensed under the included `LICENSE`. Review this patch against
the upstream package when upgrading `sqlite3`, then remove the dependency
override if upstream provides the same failure semantics.
