# Integration tests (API + Web)

[Deployment](install/server.en.md) · [中文部署](install/server.md) · [Browser fixture reference](../integration/web/README.md)

The API (`server/`) and the browser frontend (`apps/client/`) now live in one repository, and both are required for browser acceptance. Tests that need both the API and a compiled Web bundle still run in a new disposable workspace assembled by `tools/integration_workspace.py`. It copies the test/deploy/protocol harness and links only the `server/`, `apps/` and `packages/` source directories; it does not copy `.env`, user state or credential files. Run the copied browser scripts from the assembled workspace, not from the repository.

For production use the [installation guide](install/server.en.md) / [中文指南](install/server.md), not the disposable test directory.

## Prepare the frontend

Use the pinned Flutter SDK. From the repository root:

```sh
cd apps/client
flutter pub get --enforce-lockfile
flutter build web --release --no-web-resources-cdn
```

The backend fixture uses the existing `apps/client/build/web` through its source link. A synthetic static handler fixture is not proof that the Flutter UI worked.

## Assemble a fresh test workspace

From the repository root (the output must not already exist):

```sh
python3 tools/integration_workspace.py --web . --output ../atermius-integration
cd ../atermius-integration
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install pytest PyYAML PyNaCl cryptography
```

Pass `--web .`: without it the helper still looks for a sibling `web` checkout, the layout used before the 2026-11-14 merge.

Install Cargo/Rust 1.94.1 and OpenSSL for cases that build/bootstrap a disposable API. Use an [officially supported Node.js LTS](https://nodejs.org/en/about/previous-releases) and the committed npm lockfile for browser cases. Some SSH/PG/container cases have additional OS/Docker/database requirements documented in their file headers.

## Start with a bounded check

From the assembled workspace:

```sh
CARGO_BUILD_JOBS=2 python3 -m pytest -q integration/test_deploy_config.py integration/test_openapi_contract.py
cd integration/web
npm ci
npx playwright install chromium
```

The [browser reference](../integration/web/README.md) lists individual npm scripts; run the case you need from the assembled `integration/web`, not from an incomplete checkout. Keep the npm lockfile. Root/SSH/database fixtures can mutate their own isolated targets; never point them at a production service.

The cloud suite is `integration/test_cloud_sharing.py`. It requires its named guacd/OpenSSH/xrdp Docker fixtures and a real compiled Web bundle for the browser case. Missing fixture images/browser/build can produce skips; report those as skips, not successful live acceptance. The repository does not supply every prebuilt fixture image as a downloadable release.

## Scope and cleanup

The 2026-11-09 cloud source gate (before the merge) passed 426 Rust cases with 114 existing PG-gated ignores; the focused source CI in each of the four client repositories passed 37 cases. Separate local merged-client checks covered 134 unique cases and actual gateway/browser fixtures. These are bounded evidence, not a full Flutter/native/hardware pass. Future changes need checks appropriate to their own diff.

Stop only the fixture processes/containers created by your run. Delete only the disposable workspace; its source directories are symlinks and must not be traversed during cleanup. Production deployment uses the repository's own `deploy/` Compose files, never this assembled test directory. Keep user databases, tokens, gateway/private keys and generated browser profiles out of Git.
