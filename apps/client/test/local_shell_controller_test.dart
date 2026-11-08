import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/console/local_console.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/fake_local_console.dart';
import 'support/l10n_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useAppLocaleFixture('en');
  late ClientDatabase database;
  late AppController app;
  late FakeConsoleFactory consoles;

  setUp(() async {
    database = ClientDatabase.forTesting(NativeDatabase.memory());
    consoles = FakeConsoleFactory();
    app = AppController(
      sodium: await SodiumSumoInit.init(),
      database: database,
      secureStore: ClientSecureStore(),
    )..stage = ClientStage.workspace;
    app.localConsoleOpenerForTesting = consoles.call;
  });

  tearDown(() async {
    await app.disconnectAllTerminalTabs();
    app.dispose();
    await database.close();
  });

  test('local shell tab keeps chosen shell and routes I/O to its own PTY', () async {
    const launch = LocalShellLaunch(
      kind: LocalShellKind.pwsh,
      workingDirectory: '/work',
    );
    final id = await app.openLocalShellTab(launch: launch);
    final tab = app.terminalTabFor(id)!;
    expect(tab.consoleShell, launch);
    expect(tab.consoleSerialPort, isNull);
    expect(tab.state, 'connected');
    expect(tab.host?.name, 'Local · PowerShell 7 (pwsh)');
    expect(consoles.opened.single.shell, launch);
    app.sendTerminalInputFor(id, 'echo hi\r');
    app.resizeTerminalFor(id, 120, 40);
    expect(consoles.opened.single.inputs, ['echo hi\r']);
    expect(consoles.opened.single.resizes, [(120, 40)]);
    consoles.opened.single.emit('PS /work> ');
    await pumpEventQueue();
    expect(tab.terminal.buffer.lines[0].toString(), contains('PS /work>'));
  });

  test('duplicate shell starts an independent PTY with same kind and live cwd', () async {
    final id = await app.openLocalShellTab(
      launch: const LocalShellLaunch(kind: LocalShellKind.zsh),
    );
    consoles.opened.single.cwd = '/srv/project';
    final copyId = await app.duplicateConsoleTab(id!);
    expect(copyId, isNot(id));
    expect(consoles.opened, hasLength(2));
    final copy = consoles.opened.last;
    expect(copy.shell?.kind, LocalShellKind.zsh);
    expect(copy.shell?.workingDirectory, '/srv/project');
    expect(app.terminalTabFor(copyId)!.consoleShell?.workingDirectory, '/srv/project');
    app.sendTerminalInputFor(copyId, 'pwd\r');
    expect(consoles.opened.first.inputs, isEmpty);
    expect(copy.inputs, ['pwd\r']);
    // Closing one leaves the sibling process alive.
    await app.closeTerminalTab(copyId!);
    expect(copy.closed, isTrue);
    expect(consoles.opened.first.closed, isFalse);
    expect(app.terminalTabFor(id)?.state, 'connected');
  });

  test('duplicating a serial console never turns it into a shell', () async {
    await app.openConsoleTab(serialPort: 'COM7', baudRate: 9600);
    final serialId = app.activeTerminalTabId!;
    final copyId = await app.duplicateConsoleTab(serialId);
    expect(consoles.opened, hasLength(2));
    for (final console in consoles.opened) {
      expect(console.serialPort, 'COM7');
      expect(console.baudRate, 9600);
      expect(console.shell, isNull);
    }
    expect(app.terminalTabFor(copyId)!.consoleSerialPort, 'COM7');
    expect(app.terminalTabFor(copyId)!.consoleShell, isNull);
  });

  test('default console API stays the system shell', () async {
    await app.openConsoleTab();
    expect(consoles.opened.single.shell, LocalShellLaunch.systemDefault);
    expect(app.activeTerminalTab!.host?.name, 'Local Console');
  });

  test('exit, unavailable shell and late output are handled without leaks', () async {
    final id = await app.openLocalShellTab();
    final console = consoles.opened.single;
    console.exit(3);
    await pumpEventQueue();
    final tab = app.terminalTabFor(id)!;
    expect(tab.state, 'disconnected');
    expect(tab.terminal.buffer.lines[1].toString(), contains('3'));

    consoles.failWith = const LocalShellException(
      LocalShellIssue.shellNotInstalled,
    );
    final failedId = await app.openLocalShellTab(
      launch: const LocalShellLaunch(kind: LocalShellKind.fish),
    );
    final failed = app.terminalTabFor(failedId)!;
    expect(failed.state, 'disconnected');
    expect(failed.console, isNull);
    expect(failed.errorMessage, "That shell isn't installed on this computer.");

    consoles.failWith = null;
    final liveId = await app.openLocalShellTab();
    final live = consoles.opened.last;
    final liveTab = app.terminalTabFor(liveId)!;
    await app.closeTerminalTab(liveId!);
    expect(live.closed, isTrue);
    expect(live.outputHasListener, isFalse);
    expect(liveTab.console, isNull);
    expect(liveTab.outputSubscription, isNull);
  });
}
