import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:aterm_client/platform/files_window_launch.dart';

void main() {
  test('round trips exact scope, host, protocol and Unicode path', () {
    for (final workspace in FilesWindowWorkspace.values) {
      for (final protocol in FilesWindowProtocol.values) {
        final request = FilesWindowLaunch(
          workspace: workspace,
          scopeId: 'scope-1',
          hostId: 'host-2',
          protocol: protocol,
          initialPath: '/中文/a b',
          serverNamespace: workspace == FilesWindowWorkspace.cloud
              ? 'https://example.test%2Ftenant'
              : null,
          accountId: workspace == FilesWindowWorkspace.cloud
              ? 'account-1'
              : null,
        );
        final parsed = detectFilesWindow(request.toArguments())!;
        expect(
          parsed.matchesScope(
            workspace,
            'scope-1',
            serverNamespace: request.serverNamespace,
            accountId: request.accountId,
          ),
          isTrue,
        );
        expect(parsed.matchesScope(workspace, 'other'), isFalse);
        expect(parsed.hostId, 'host-2');
        expect(parsed.protocol, protocol);
        expect(parsed.initialPath, '/中文/a b');
      }
    }
    expect(detectFilesWindow(['--new-window']), isNull);
  });

  test('rejects malformed and duplicate requests without fallback', () {
    for (final arguments in <List<String>>[
      ['--files-window'],
      ['--files-window', '!'],
      ['--files-window', 'a' * 12289],
      ['--files-window', 'e30=', '--files-window', 'e30='],
      [
        '--files-window',
        base64Url.encode(
          utf8.encode(
            jsonEncode({
              'v': 1,
              'workspace': 'local',
              'scope': 'scope',
              'host': 'host',
              'protocol': 'sftp',
              'path': '.',
              'password': 'forbidden',
            }),
          ),
        ),
      ],
    ]) {
      expect(() => detectFilesWindow(arguments), throwsFormatException);
    }
  });

  test('cloud requests bind server, account and vault independently', () {
    final request = FilesWindowLaunch(
      workspace: FilesWindowWorkspace.cloud,
      scopeId: 'vault',
      hostId: 'host',
      protocol: FilesWindowProtocol.sftp,
      serverNamespace: 'https://server.test',
      accountId: 'account',
    );
    expect(
      request.matchesScope(
        FilesWindowWorkspace.cloud,
        'vault',
        serverNamespace: 'https://server.test',
        accountId: 'other',
      ),
      isFalse,
    );
    expect(
      request.matchesScope(
        FilesWindowWorkspace.cloud,
        'vault',
        serverNamespace: 'https://other.test',
        accountId: 'account',
      ),
      isFalse,
    );
    expect(
      request.matchesScope(
        FilesWindowWorkspace.cloud,
        'other',
        serverNamespace: 'https://server.test',
        accountId: 'account',
      ),
      isFalse,
    );
    expect(
      () => FilesWindowLaunch(
        workspace: FilesWindowWorkspace.cloud,
        scopeId: 'vault',
        hostId: 'host',
        protocol: FilesWindowProtocol.sftp,
      ),
      throwsFormatException,
    );
    expect(
      () => FilesWindowLaunch(
        workspace: FilesWindowWorkspace.cloud,
        scopeId: 'vault',
        hostId: 'host',
        protocol: FilesWindowProtocol.sftp,
        accountId: 'account',
        serverNamespace: 'https://user:password@server.test',
      ),
      throwsFormatException,
    );
  });

  test('rejects unsafe IDs, control characters and oversized paths', () {
    for (final id in ['', '../host', 'host\n', 'a' * 257]) {
      expect(
        () => FilesWindowLaunch(
          workspace: FilesWindowWorkspace.local,
          scopeId: id,
          hostId: 'host',
          protocol: FilesWindowProtocol.scp,
        ),
        throwsFormatException,
      );
    }
    for (final path in ['', '/a\u0000b', '/a\nb', '中' * 1366]) {
      expect(
        () => FilesWindowLaunch(
          workspace: FilesWindowWorkspace.local,
          scopeId: 'scope',
          hostId: 'host',
          protocol: FilesWindowProtocol.scp,
          initialPath: path,
        ),
        throwsFormatException,
      );
    }
  });
}
