# Development and verification / 开发与验证

Use Flutter 3.47.5 / Dart 3.13, the committed lockfile and local dependency forks in `packages/`. / 使用固定工具链、锁文件和 `packages/` 中的本地依赖分支。

## Flutter client / Flutter 客户端

From `apps/client` / 在 `apps/client` 执行:

```sh
flutter pub get --enforce-lockfile
flutter test --concurrency=2 test/session_workspace_actions_test.dart test/workspace_tab_drag_test.dart test/terminal_tools_sidebar_test.dart test/cloud_access_client_test.dart test/cloud_access_interop_test.dart test/credential_escrow_crypto_test.dart test/credential_escrow_interop_test.dart test/credential_escrow_admin_test.dart test/credential_visibility_api_test.dart test/credential_visibility_service_test.dart test/credential_visibility_clipboard_test.dart test/credential_visibility_widget_test.dart
```

These are the repository's focused source-CI checks, not the entire suite. Full Flutter baseline failures remain disclosed. Real-server owner/widget tests require the explicit isolated `ATERMIUS_TEST_SERVER_BINARY` fixture; a skipped env-gated case is not a live pass. / 上述为针对性源码 CI，不能代表全套通过；真实服务端用例必须明确提供隔离 fixture，环境跳过不算真实通过。

`apps/client/` is shared by every platform runner (`android/`, `ios/`, `macos/`, `windows/`, `linux/`, `web/`), so one change can affect all of them. Before the merge, the same code was kept in step across four client repositories by hand. / `apps/client/` 由所有平台启动工程共用，一处修改可能影响全部平台；合并前四个客户端仓库需要手动保持一致。

After intentional schema/catalog edits, run the appropriate generator, review changes and check the affected platforms. Preserve platform ownership and upstream notices. The pre-merge `SOURCE_SNAPSHOT.json` / `SOURCE_PROVENANCE.json` import records are kept unchanged in [provenance](provenance/); Git records subsequent documentation/code changes. / 模型与翻译生成仅在对应改动后进行，并按影响范围验证各平台；保留平台归属和上游说明。合并前的导入记录原样保存在 [provenance](provenance/)。

## Web build / Web 构建

From `apps/client` / 在 `apps/client` 执行:

```sh
flutter build web --release --no-web-resources-cdn
```

Then, from the repository root / 然后在仓库根目录:

```sh
python3 tools/verify_cloud_proxy.py --web-root apps/client/build/web
```

This uses Docker and the pinned real nginx runtime to check landing headers, API proxying and WebSocket upgrade/echo. / 此项使用真实固定 nginx 镜像验证响应头、API 与 WebSocket 转发。

## Server and integration / 服务端与集成测试

Rust build and test commands for `server/` are at the end of the [server installation guide](install/server.en.md) / [服务端部署](install/server.md). Browser/backend integration tests are assembled by the [integration guide](INTEGRATION.md). Do not run mutation fixtures against production. / 前后端集成测试按[集成说明](INTEGRATION.md)组装，不在生产服务上执行写入 fixture。

## Linux SDK helper / Linux SDK 脚本

The checked-in helper is also used by CI. From the repository root:

```sh
bash tools/install_flutter_linux.sh
export PATH="${RUNNER_TEMP:-/tmp}/aterminal-flutter-3.47.5/flutter/bin:$PATH"
flutter --version
```

It writes GitHub's PATH file only inside Actions. In a normal shell use the explicit export above; its default SDK directory is temporary, so use the official archive/PATH installation for a persistent workstation setup. / 普通终端不会因运行子脚本自动修改父进程 PATH，需显式 export；默认临时目录不适合作为永久 SDK 安装位置。
