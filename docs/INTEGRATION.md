# Cross-repository test setup

Build the Web bundle first, then follow the server's [integration guide](https://github.com/aterm-project/server/blob/main/docs/INTEGRATION.md) to assemble a fresh combined test workspace. Both the API source and this frontend are required for browser acceptance.

The helper lives in the server repository as `tools/integration_workspace.py`; it does not exist in this Web-only checkout. Run the copied browser scripts from the assembled workspace. Keep the npm lockfile, use isolated targets and report missing-fixture skips separately from actual passes.

For production use the [installation guide](INSTALLATION.en.md) / [中文指南](INSTALLATION.md), not the disposable test directory.
