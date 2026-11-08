import 'package:aterm_client/console/local_shell.dart';
import 'package:aterm_client/domain/window_combination.dart';
import 'package:flutter_test/flutter_test.dart';

LocalShellHost _posix({
  Map<String, String> env = const {
    'HOME': '/home/u',
    'SHELL': '/bin/bash',
    'PATH': '/usr/local/bin:/usr/bin:relative/bin',
  },
  Set<String> files = const {'/bin/sh', '/bin/bash', '/usr/bin/zsh'},
  Set<String> dirs = const {'/home/u', '/home/u/src', '/tmp'},
}) => LocalShellHost(
  isWindows: false,
  environment: env,
  isFile: files.contains,
  isDirectory: dirs.contains,
);

LocalShellHost _windows({
  Map<String, String> env = const {
    'USERPROFILE': r'C:\Users\u',
    'SystemRoot': r'C:\Windows',
    'ComSpec': r'C:\Windows\System32\cmd.exe',
    'ProgramFiles': r'C:\Program Files',
    'Path': r'C:\Windows\System32;C:\Tools',
  },
  Set<String> files = const {
    r'C:\Windows\System32\cmd.exe',
    r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
    r'C:\Program Files\PowerShell\7\pwsh.exe',
  },
}) => LocalShellHost(
  isWindows: true,
  environment: env,
  isFile: files.contains,
  isDirectory: {r'C:\Users\u', r'D:\work'}.contains,
);

void main() {
  group('POSIX resolution', () {
    test('system shell uses validated SHELL with interactive argv', () {
      final command = resolveLocalShell(LocalShellLaunch.systemDefault, _posix());
      expect(command.executable, '/bin/bash');
      expect(command.arguments, ['-i']);
      expect(command.workingDirectory, '/home/u');
    });

    test('unknown or unsafe SHELL never becomes a command string', () {
      for (final shell in ['bash -c "rm -rf /"', 'bin/bash', '/bin/ba\nsh', '']) {
        final command = resolveLocalShell(
          LocalShellLaunch.systemDefault,
          _posix(env: {'HOME': '/home/u', 'SHELL': shell}),
        );
        expect(command.executable, '/bin/sh', reason: shell);
        expect(command.arguments, ['-i']);
      }
      final custom = resolveLocalShell(
        LocalShellLaunch.systemDefault,
        _posix(
          env: {'HOME': '/home/u', 'SHELL': '/opt/nu/bin/nu'},
          files: {'/opt/nu/bin/nu', '/bin/sh'},
        ),
      );
      expect(custom.executable, '/opt/nu/bin/nu');
      expect(custom.arguments, isEmpty);
    });

    test('explicit shells resolve via absolute PATH entries only', () {
      final zsh = resolveLocalShell(
        const LocalShellLaunch(kind: LocalShellKind.zsh),
        _posix(),
      );
      expect(zsh.executable, '/usr/bin/zsh');
      expect(zsh.arguments, ['-i']);
      final relative = _posix(
        env: {'HOME': '/home/u', 'PATH': 'relative/bin'},
        files: {'relative/bin/fish', '/bin/sh'},
      );
      expect(
        () => resolveLocalShell(
          const LocalShellLaunch(kind: LocalShellKind.fish),
          relative,
        ),
        throwsA(
          isA<LocalShellException>().having(
            (e) => e.issue,
            'issue',
            LocalShellIssue.shellNotInstalled,
          ),
        ),
      );
      for (final kind in [LocalShellKind.cmd, LocalShellKind.powershell]) {
        expect(
          () => resolveLocalShell(LocalShellLaunch(kind: kind), _posix()),
          throwsA(isA<LocalShellException>()),
        );
      }
      expect(availableLocalShells(_posix()), [
        LocalShellKind.system,
        LocalShellKind.bash,
        LocalShellKind.zsh,
        LocalShellKind.sh,
      ]);
    });

    test('working directory: ~ expansion, existence and syntax', () {
      final host = _posix();
      expect(
        resolveLocalShell(
          const LocalShellLaunch(workingDirectory: '~/src'),
          host,
        ).workingDirectory,
        '/home/u/src',
      );
      expect(
        resolveLocalShell(const LocalShellLaunch(workingDirectory: '/tmp'), host)
            .workingDirectory,
        '/tmp',
      );
      for (final (path, issue) in [
        ('relative/dir', LocalShellIssue.invalidWorkingDirectory),
        ('/tmp\n/x', LocalShellIssue.invalidWorkingDirectory),
        ('/does/not/exist', LocalShellIssue.workingDirectoryNotFound),
      ]) {
        expect(
          () => resolveLocalShell(LocalShellLaunch(workingDirectory: path), host),
          throwsA(
            isA<LocalShellException>().having((e) => e.issue, 'issue', issue),
          ),
          reason: path,
        );
      }
    });
  });

  group('Windows resolution', () {
    test('cmd, Windows PowerShell and pwsh use fixed locations and argv', () {
      final host = _windows();
      final system = resolveLocalShell(LocalShellLaunch.systemDefault, host);
      expect(system.executable, r'C:\Windows\System32\cmd.exe');
      expect(system.arguments, isEmpty);
      expect(system.workingDirectory, r'C:\Users\u');
      final ps = resolveLocalShell(
        const LocalShellLaunch(kind: LocalShellKind.powershell),
        host,
      );
      expect(
        ps.executable,
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
      );
      expect(ps.arguments, ['-NoLogo']);
      final pwsh = resolveLocalShell(
        const LocalShellLaunch(
          kind: LocalShellKind.pwsh,
          workingDirectory: r'D:\work',
        ),
        host,
      );
      expect(pwsh.executable, r'C:\Program Files\PowerShell\7\pwsh.exe');
      expect(pwsh.workingDirectory, r'D:\work');
      expect(availableLocalShells(host), [
        LocalShellKind.system,
        LocalShellKind.cmd,
        LocalShellKind.powershell,
        LocalShellKind.pwsh,
      ]);
    });

    test('a non-exe or missing COMSPEC falls back to System32 cmd', () {
      final host = _windows(
        env: {
          'SystemRoot': r'C:\Windows',
          'ComSpec': r'C:\evil\run.bat',
        },
      );
      expect(
        resolveLocalShell(LocalShellLaunch.systemDefault, host).executable,
        r'C:\Windows\System32\cmd.exe',
      );
    });
  });

  group('persisted launch metadata', () {
    test('round trips kind and cwd only and rejects executable/args keys', () {
      const launch = LocalShellLaunch(
        kind: LocalShellKind.pwsh,
        workingDirectory: '~/src',
      );
      expect(LocalShellLaunch.fromJson(launch.toJson()), launch);
      expect(LocalShellLaunch.systemDefault.toJson(), {'kind': 'system'});
      for (final bad in <Object?>[
        {'kind': 'pwsh', 'executable': '/bin/sh'},
        {'kind': 'pwsh', 'args': ['-c', 'id']},
        {'kind': 'python'},
        {'kind': 'bash', 'cwd': 'relative'},
        {'kind': 'bash', 'cwd': '/a\u0000b'},
        'bash',
        null,
      ]) {
        expect(
          () => LocalShellLaunch.fromJson(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });

    test('window-set Console pane keeps shell metadata, serial stays distinct', () {
      final shellPane = CombinationPane(
        kind: 'console',
        shell: const LocalShellLaunch(
          kind: LocalShellKind.zsh,
          workingDirectory: '/srv',
        ),
      );
      final json = shellPane.toJson();
      expect(json['shell'], {'kind': 'zsh', 'cwd': '/srv'});
      final parsed = CombinationPane.fromJson(json);
      expect(parsed.shell?.kind, LocalShellKind.zsh);
      expect(parsed.shell?.workingDirectory, '/srv');
      expect(parsed.serialPort, isNull);
      // System default stays in the legacy 5-key form for older clients.
      final legacy = CombinationPane(
        kind: 'console',
        shell: LocalShellLaunch.systemDefault,
      ).toJson();
      expect(legacy.containsKey('shell'), isFalse);
      expect(CombinationPane.fromJson(legacy).shell, isNull);
      final serial = CombinationPane.fromJson(
        CombinationPane(
          kind: 'console',
          serialPort: 'COM3',
          baudRate: 9600,
        ).toJson(),
      );
      expect(serial.serialPort, 'COM3');
      expect(serial.shell, isNull);
      expect(
        () => CombinationPane(
          kind: 'console',
          serialPort: 'COM3',
          baudRate: 9600,
          shell: const LocalShellLaunch(kind: LocalShellKind.cmd),
        ),
        throwsFormatException,
      );
      expect(
        () => CombinationPane(
          kind: 'ssh',
          hostId: 'host-1',
          shell: const LocalShellLaunch(kind: LocalShellKind.cmd),
        ),
        throwsFormatException,
      );
      expect(
        () => CombinationPane.fromJson({
          ...legacy,
          'shell': {'kind': 'bash', 'executable': '/tmp/x'},
        }),
        throwsFormatException,
      );
    });
  });
}
