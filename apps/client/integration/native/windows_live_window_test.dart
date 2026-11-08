// Run with FlutterTester on the build worker's own Windows session:
// $env:ATERMIUS_WINDOW_TEST_EXE = 'C:\path\to\release\aterm_client.exe'
// flutter test integration/native/windows_live_window_test.dart --concurrency=1
// Optional: ATERMIUS_WINDOW_TEST_EVIDENCE_DIR saves token-free JSON evidence.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/terminal/live_terminal_window.dart';
import 'package:aterm_client/terminal/mirrored_terminal.dart';
import 'package:flutter_test/flutter_test.dart';

class _NativeHttp extends HttpOverrides {}

final _executable = Platform.environment['ATERMIUS_WINDOW_TEST_EXE'];
final _skip =
    !Platform.isWindows || _executable == null || _executable!.isEmpty;
const _skipReason =
    'Requires Windows and ATERMIUS_WINDOW_TEST_EXE pointing to the built release executable.';

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Native terminal condition not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void>? _serviceSession;
Future<void> _requireServiceSession() => _serviceSession ??= (() async {
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    '(Get-Process -Id $pid).SessionId',
  ]).timeout(const Duration(seconds: 10));
  if (result.exitCode != 0 || (result.stdout as String).trim() != '0') {
    throw StateError('This owned-window probe must run in Windows Session 0.');
  }
})();

Future<Process> _launchOwnedChild(LiveTerminalBroker broker) async {
  await _requireServiceSession();
  final file = File(_executable!);
  if (!await file.exists()) {
    throw StateError('The supplied release executable does not exist.');
  }
  final launch = broker.launch;
  final child = await Process.start(
    file.path,
    [
      '--terminal-window-port=${launch.port}',
      '--terminal-window-session=${launch.sessionId}',
    ],
    workingDirectory: file.parent.path,
    includeParentEnvironment: true,
    environment: {'ATERMIUS_TERMINAL_WINDOW_CAPABILITY': launch.capability},
  );
  // Never print child output or launch environment: neither is needed as an
  // authentication oracle, and normal app logging does not belong in a probe.
  unawaited(child.stdout.drain<void>());
  unawaited(child.stderr.drain<void>());
  // Match production ownership: a failed renderer process must fail readiness
  // immediately, rather than making a dead child wait for the 40s paint timer.
  unawaited(
    child.exitCode.then(
      (_) => broker.close(reason: LiveTerminalWindowCloseReason.transportLost),
    ),
  );
  return child;
}

// Every Win32 operation verifies that the target HWND belongs to the exact
// Process.start PID. It does not enumerate another user's applications, inject
// keyboard input, touch RDP or target a title/global desktop window.
Future<void> _ownedWindowAction(Process child, String operation) async {
  if (!const ['resize', 'close'].contains(operation)) {
    throw ArgumentError('Unsupported owned-window action.');
  }
  const script = r'''
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OwnTerminalProbe {
  public delegate bool EnumWindowProc(IntPtr hwnd, IntPtr state);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowProc callback, IntPtr state);
  public static IntPtr FindOwned(uint target) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((hwnd, state) => {
      uint owner; GetWindowThreadProcessId(hwnd, out owner);
      if (owner == target) { found = hwnd; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  [DllImport("user32.dll", SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool MoveWindow(IntPtr hwnd, int x, int y, int width, int height, bool repaint);
}
'@
$ownWindowProcessId = __CHILD_PID__
$ownWindowHandle = [IntPtr]::Zero
for ($attempt = 0; $attempt -lt 80; $attempt++) {
  $ownProcess = Get-Process -Id $ownWindowProcessId -ErrorAction Stop
  $ownProcess.Refresh()
  if ($ownProcess.SessionId -ne 0) { throw 'Owned child is not in Session 0.' }
  $expectedExecutable = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__EXE_PATH_BASE64__'))
  if ([IO.Path]::GetFullPath($ownProcess.Path) -ne [IO.Path]::GetFullPath($expectedExecutable)) { throw 'Owned child executable identity changed.' }
  $ownWindowHandle = [OwnTerminalProbe]::FindOwned([uint32]$ownWindowProcessId)
  if ($ownWindowHandle -ne [IntPtr]::Zero) { break }
  Start-Sleep -Milliseconds 100
}
if ($ownWindowHandle -eq [IntPtr]::Zero) { throw 'Owned child window was not created.' }
[uint32]$verifiedWindowProcessId = 0
[void][OwnTerminalProbe]::GetWindowThreadProcessId($ownWindowHandle, [ref]$verifiedWindowProcessId)
if ($verifiedWindowProcessId -ne $ownWindowProcessId) { throw 'Owned HWND verification failed.' }
if ('__OPERATION__' -eq 'close') {
  if (-not [OwnTerminalProbe]::PostMessage($ownWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) { throw 'Owned WM_CLOSE failed.' }
} else {
  if (-not [OwnTerminalProbe]::MoveWindow($ownWindowHandle, 0, 0, 1170, 790, $true)) { throw 'Owned resize failed.' }
}
''';
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-Command',
    script
        .replaceAll('__CHILD_PID__', child.pid.toString())
        .replaceAll('__OPERATION__', operation)
        .replaceAll(
          '__EXE_PATH_BASE64__',
          base64Encode(utf8.encode(File(_executable!).absolute.path)),
        ),
  ]).timeout(const Duration(seconds: 15));
  if (result.exitCode != 0) {
    throw StateError(
      'Own-process $operation failed (${result.exitCode}): ${result.stderr}',
    );
  }
}

Future<void> _evidence(String name, Map<String, Object?> checks) async {
  final path = Platform.environment['ATERMIUS_WINDOW_TEST_EVIDENCE_DIR'];
  if (path == null || path.isEmpty) return;
  final directory = await Directory(path).create(recursive: true);
  await File(
    '${directory.path}${Platform.pathSeparator}windows-live-window-$name.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'probe': 'FlutterTester broker to built Windows release child',
      'utc': DateTime.now().toUtc().toIso8601String(),
      'executable': _executable,
      'uses_real_ssh': false,
      'touches_user_desktop': false,
      'requires_verified_session_zero': true,
      'checks': checks,
    }),
    flush: true,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'release child paint ready, VT reply ownership, real HWND resize and WM_CLOSE intent',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final replies = <String>[];
      final sizes = <(int, int)>[];
      final terminal = MirroredTerminal(
        onOutput: replies.add,
        onResize: (columns, rows, _, _) => sizes.add((columns, rows)),
      );
      // The old query belongs to the parent and must stay silent during child replay.
      terminal.write('native-window-probe\r\n\x1b[6n');
      expect(replies, hasLength(1));
      final broker = await LiveTerminalBroker.bind(
        terminal: terminal,
        title: 'Atermius native broker probe',
        readyTimeout: const Duration(seconds: 40),
      );
      Process? child;
      var exited = false;
      try {
        child = await _launchOwnedChild(broker);
        final ownedChild = child;
        unawaited(ownedChild.exitCode.then((_) => exited = true));
        expect(
          await broker.ready.timeout(const Duration(seconds: 45)),
          isTrue,
          reason: 'The real release renderer must acknowledge its first terminal frame.',
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          replies,
          hasLength(1),
          reason: 'Historical device queries cannot be replayed as input.',
        );
        terminal.write('\x1b[6n');
        await _until(() => replies.length >= 2);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          replies,
          hasLength(2),
          reason: 'Exactly one renderer must own live VT device replies.',
        );
        expect(replies.last, matches(RegExp(r'^\x1b\[\d+;\d+R$')));
        var resized = false;
        if (Platform.environment['ATERMIUS_WINDOW_TEST_RESIZE'] != '0') {
          await _until(() => sizes.isNotEmpty);
          final previous = sizes.last;
          await _ownedWindowAction(ownedChild, 'resize');
          await _until(() => sizes.last != previous);
          resized = true;
        }
        await _ownedWindowAction(ownedChild, 'close');
        expect(
          await broker.outcome.timeout(const Duration(seconds: 8)),
          LiveTerminalWindowCloseReason.user,
        );
        expect(
          await ownedChild.exitCode.timeout(const Duration(seconds: 15)),
          0,
        );
        expect(terminal.onOutput, isNotNull);
        terminal.textInput('parent-callback-restored');
        expect(replies.last, 'parent-callback-restored');
        await _evidence('user-close', {
          'paint_ready': true,
          'historical_query_silent': true,
          'live_query_exactly_once': true,
          'real_hwnd_resize_observed': resized,
          'wm_close_user_intent': true,
          'child_exit_code': 0,
          'parent_callback_restored': true,
        });
      } finally {
        if (child != null && !exited) {
          child.kill();
          try {
            await child.exitCode.timeout(const Duration(seconds: 5));
          } catch (_) {}
        }
        await broker.close();
        await terminal.closeMirror();
      }
    }, _NativeHttp()),
    skip: _skip ? _skipReason : false,
    timeout: const Timeout(Duration(seconds: 100)),
  );

  test(
    'terminating only the owned release child restores source transport without reconnecting SSH',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final input = <String>[];
      final terminal = MirroredTerminal(onOutput: input.add);
      final broker = await LiveTerminalBroker.bind(
        terminal: terminal,
        title: 'Atermius owned crash probe',
        readyTimeout: const Duration(seconds: 40),
      );
      Process? child;
      var exited = false;
      try {
        child = await _launchOwnedChild(broker);
        final ownedChild = child;
        unawaited(ownedChild.exitCode.then((_) => exited = true));
        expect(await broker.ready.timeout(const Duration(seconds: 45)), isTrue);
        expect(ownedChild.kill(), isTrue);
        await ownedChild.exitCode.timeout(const Duration(seconds: 10));
        expect(
          await broker.outcome.timeout(const Duration(seconds: 8)),
          LiveTerminalWindowCloseReason.transportLost,
        );
        terminal.textInput('same-parent-terminal');
        expect(input, ['same-parent-terminal']);
        await _evidence('owned-process-kill', {
          'paint_ready': true,
          'terminated_only_spawned_pid': true,
          'outcome': 'transportLost',
          'parent_callback_restored': true,
          'reconnect_attempted': false,
        });
      } finally {
        if (child != null && !exited) {
          child.kill();
          try {
            await child.exitCode.timeout(const Duration(seconds: 5));
          } catch (_) {}
        }
        await broker.close();
        await terminal.closeMirror();
      }
    }, _NativeHttp()),
    skip: _skip ? _skipReason : false,
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'owner revoke physically exits its already-painted release child and clears the old terminal window',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final input = <String>[];
      final terminal = MirroredTerminal(onOutput: input.add);
      final broker = await LiveTerminalBroker.bind(
        terminal: terminal,
        title: 'Atermius owner revoke probe',
        readyTimeout: const Duration(seconds: 40),
      );
      Process? child;
      var exited = false;
      try {
        child = await _launchOwnedChild(broker);
        final ownedChild = child;
        unawaited(ownedChild.exitCode.then((_) => exited = true));
        final lifecycle = OwnedLiveTerminalChild(
          process: ownedChild,
          stopBroker: broker.close,
          onProcessExit: () =>
              broker.close(reason: LiveTerminalWindowCloseReason.transportLost),
        );
        expect(await broker.ready.timeout(const Duration(seconds: 45)), isTrue);
        await lifecycle.closeOwner();
        await lifecycle.exited;
        final exitCode = await ownedChild.exitCode;
        expect(
          await broker.outcome,
          LiveTerminalWindowCloseReason.parentClosed,
        );
        terminal.textInput('revoked-window-gone');
        expect(input, ['revoked-window-gone']);
        await _evidence('owner-revoke', {
          'paint_ready': true,
          'owner_revoke_completed': true,
          'owned_child_process_exited': true,
          'child_exit_code': exitCode,
          'outcome': 'parentClosed',
          'old_terminal_window_left_running': false,
        });
      } finally {
        if (child != null && !exited) {
          child.kill();
          try {
            await child.exitCode.timeout(const Duration(seconds: 5));
          } catch (_) {}
        }
        await broker.close();
        await terminal.closeMirror();
      }
    }, _NativeHttp()),
    skip: _skip ? _skipReason : false,
    timeout: const Timeout(Duration(seconds: 75)),
  );
}
