# Cross-repository integration tests

The existing Python/browser tests require both the backend and the frontend in
one temporary directory. Keep the production repositories independent; assemble
the test layout with `python3 tools/integration_workspace.py --web ../web` from
the server repository. The command prints a new disposable directory, copies
the test/deployment harness, and links source from the two explicit checkouts.
It does not copy `.env`, credentials, application data or generated artifacts.

Build the web application in the web repository first. Install the test harness
dependencies and run the documented integration checks from the printed
directory. Do not point mutation tests at a production service. Test results
from the old monorepo are historical evidence, not new passing results for this
split. Windows/Android application tests remain in their respective repositories.

For production deployment use the repositories' Compose files directly, not the
temporary integration directory. Delete only the generated temporary directory
when finished; the source symlinks must not be followed during cleanup.
