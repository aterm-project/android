# Development and verification / 开发与验证

Use Flutter 3.47.5 / Dart 3.13, the committed lockfile and local dependency forks. / 使用固定工具链、锁文件和本地依赖分支。

From `apps/client` / 在 `apps/client` 执行:

```sh
flutter pub get --enforce-lockfile
flutter test --concurrency=2 test/session_workspace_actions_test.dart test/workspace_tab_drag_test.dart test/terminal_tools_sidebar_test.dart test/cloud_access_client_test.dart test/cloud_access_interop_test.dart
```

These are the repository's focused source-CI checks, not the entire suite. Full Flutter baseline failures remain disclosed. Real-server owner/widget tests require the explicit isolated `ATERMIUS_TEST_SERVER_BINARY` fixture; a skipped env-gated case is not a live pass. / 上述为针对性源码 CI，不能代表全套通过；真实服务端用例必须明确提供隔离 fixture，环境跳过不算真实通过。

Web-only (use the Web repository) / 仅 Web 仓库:

```sh
flutter build web --release --no-web-resources-cdn
```

Then, from that repository root / 然后在该仓库根目录:

```sh
python3 tools/verify_cloud_proxy.py --web-root apps/client/build/web
```

This uses Docker and the pinned real nginx runtime to check landing headers, API proxying and WebSocket upgrade/echo. / 此项使用真实固定 nginx 镜像验证响应头、API 与 WebSocket 转发。

Cross-repository browser/backend tests are assembled by the server's [integration guide](https://github.com/aterm-project/server/blob/main/docs/INTEGRATION.md). Do not run mutation fixtures against production. / 跨仓测试按服务端集成说明组装，不在生产服务上执行写入 fixture。

After intentional schema/catalog edits, run the appropriate generator, review changes and update shared code consistently across four client repositories. Preserve platform ownership and upstream notices. `SOURCE_SNAPSHOT.json` records source provenance; Git records subsequent documentation/code changes. / 模型与翻译生成仅在对应改动后进行，四端共享修改保持一致，保留平台归属和上游说明。

## Linux SDK helper / Linux SDK 脚本

The checked-in helper is also used by CI. From the repository root:

```sh
bash tools/install_flutter_linux.sh
export PATH="${RUNNER_TEMP:-/tmp}/aterminal-flutter-3.47.5/flutter/bin:$PATH"
flutter --version
```

It writes GitHub's PATH file only inside Actions. In a normal shell use the explicit export above; its default SDK directory is temporary, so use the official archive/PATH installation for a persistent workstation setup. / 普通终端不会因运行子脚本自动修改父进程 PATH，需显式 export；默认临时目录不适合作为永久 SDK 安装位置。
