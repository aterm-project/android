import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/desktop/rdp_features.dart';
import 'package:aterm_client/desktop/rdp_settings.dart';
import 'package:aterm_client/desktop/window/desktop_tab_windows.dart';
import 'package:aterm_client/desktop/window/desktop_window.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/platform/application_windows.dart';
import 'package:aterm_client/platform/window_chrome.dart';
import 'package:aterm_client/terminal/live_terminal_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/l10n/l10n.dart';

class _Fake implements DirectDesktopConnection {
  final controller = StreamController<DesktopEvent>();
  @override
  Stream<DesktopEvent> get events => controller.stream;
  @override
  void send(List<Object> command) {}
  @override
  void paste(String text) {}
  @override
  Future<void> close() async {
    if (!controller.isClosed) await controller.close();
  }
}

class _Chrome extends WindowChromeController {
  _Chrome() : super(supported: true);
  @override
  WindowChromeState get state => const WindowChromeState(enabled: true);
  @override
  Future<void> start() async {}
  @override
  Future<void> setCloseGuard(Future<void> Function()? guard) async {}
  @override
  Future<void> hide() async {}
  @override
  Future<void> show() async {}
  @override
  Future<void> closeNow() async {}
}

class _Child {
  _Child(this.id, this.spec, this.onReady);
  final String id;
  final DesktopWindowSpec spec;
  final VoidCallback? onReady;
  final _ready = Completer<bool>(), _outcome = Completer<LiveTerminalWindowCloseReason>();
  bool closedByOwner = false;
  late final handle = LiveTerminalWindowHandle(
    ready: _ready.future,
    closed: _outcome.future.then((_) {}),
    outcome: _outcome.future,
    close: () async {
      closedByOwner = true;
      finish(LiveTerminalWindowCloseReason.parentClosed);
    },
    port: 1,
    sessionId: id,
  );
  void ready(bool ok) {
    if (ok) onReady?.call();
    _ready.complete(ok);
    if (!ok) finish(LiveTerminalWindowCloseReason.startupFailed);
  }

  void finish(LiveTerminalWindowCloseReason reason) {
    if (!_ready.isCompleted) _ready.complete(false);
    if (!_outcome.isCompleted) _outcome.complete(reason);
  }
}

/// Multi-monitor RDP session (two monitors) connected through a fake engine.
Future<DesktopSession> _multimonSession() async {
  final fake = _Fake();
  final session = DesktopSession(directConnectionForTesting: (_) => fake)
    ..rdpFeaturesForTesting = const RdpFeatures(0x0ff);
  await session.connectLocal(
    const HostRecord(
      id: 'h',
      name: 'Win',
      address: 'win',
      protocol: HostProtocol.rdp,
      manifest: {
        'rdp_settings_v1': {'version': 1, 'multimon': true},
      },
    ),
  );
  var acked = false;
  fake.controller.add(DesktopFrame(64, 32, Uint8List(64 * 32 * 4), onConsumed: () => acked = true));
  for (var i = 0; i < 200 && !acked; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return session;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<_Child> children;
  late ApplicationWindows windows;
  late bool Function(String id) shouldFail;
  setUp(() {
    children = [];
    shouldFail = (_) => false;
    windows = ApplicationWindows(
      windowChrome: _Chrome(),
      liveWindowsSupported: true,
      desktopOpener: ({required session, required spec, onReady}) async {
        final child = _Child('w${children.length}', spec, onReady);
        children.add(child);
        final fail = shouldFail(spec.title);
        scheduleMicrotask(() => child.ready(!fail));
        return child.handle;
      },
    );
  });

  test('detach requires a connected desktop and tracks the tab id', () async {
    final owner = Object();
    final idle = DesktopSession();
    expect(
      await DesktopTabWindows.detach(
        windows: windows,
        owner: owner,
        tabId: 't',
        session: idle,
        title: 'x',
        onDetached: () {},
        onUserClosed: () {},
        onRestored: () {},
      ),
      isFalse,
    );
    expect(children, isEmpty);
    final session = await _multimonSession();
    var detached = 0;
    expect(
      await DesktopTabWindows.detach(
        windows: windows,
        owner: owner,
        tabId: 't',
        session: session,
        title: 'Win',
        onDetached: () => detached++,
        onUserClosed: () {},
        onRestored: () {},
      ),
      isTrue,
    );
    expect(detached, 1);
    expect(windows.detachedSessionIds(owner), {'t'});
    await DesktopTabWindows.closeAll(windows: windows, owner: owner, tabId: 't');
    expect(children.single.closedByOwner, isTrue);
    expect(windows.detachedSessionIds(owner), isEmpty);
    await session.close();
  });

  test('monitor windows: one per monitor, retry reopens only missing, closeAll and owner revocation clean up', () async {
    final owner = Object();
    final session = await _multimonSession();
    // Without a reported layout there is nothing to open.
    expect(
      await DesktopTabWindows.openMonitors(
        windows: windows,
        owner: owner,
        tabId: 't',
        session: session,
        title: 'Win',
      ),
      0,
    );
    expect(children, isEmpty);
    session.rdpConfig = const RdpNativeConfig('', [], [
      RdpMonitorLayout(x: 0, y: 0, width: 1920, height: 1080, primary: true),
      RdpMonitorLayout(x: 1920, y: 0, width: 1280, height: 1024, primary: false),
    ]);
    // Fail exactly the second monitor window, whatever the display language.
    final secondMonitor = currentL10n.titleMonitorValuevalueValuevalue2(
      'Win',
      2,
      '',
    );
    shouldFail = (title) => title == secondMonitor;
    expect(
      await DesktopTabWindows.openMonitors(
        windows: windows,
        owner: owner,
        tabId: 't',
        session: session,
        title: 'Win',
      ),
      1,
    );
    expect(windows.detachedSessionIds(owner), {'t#monitor0'});
    expect(children.map((c) => c.spec.viewport), [
      const Rect.fromLTWH(0, 0, 1920, 1080),
      const Rect.fromLTWH(1920, 0, 1280, 1024),
    ]);
    // Retry (a later user action): the open window is de-duplicated, only
    // monitor 2 relaunches.
    await Future<void>.delayed(Duration.zero);
    shouldFail = (_) => false;
    expect(
      await DesktopTabWindows.openMonitors(
        windows: windows,
        owner: owner,
        tabId: 't',
        session: session,
        title: 'Win',
      ),
      2,
    );
    expect(children, hasLength(3));
    expect(windows.detachedSessionIds(owner), {'t#monitor0', 't#monitor1'});
    // A monitor window closed by the user does not affect the session.
    children[2].finish(LiveTerminalWindowCloseReason.user);
    await Future<void>.delayed(Duration.zero);
    expect(session.state, 'connected');
    expect(windows.detachedSessionIds(owner), {'t#monitor0'});
    // Tab close: every remaining renderer is closed before the session.
    await DesktopTabWindows.closeAll(windows: windows, owner: owner, tabId: 't');
    expect(children[0].closedByOwner, isTrue);
    expect(windows.detachedSessionIds(owner), isEmpty);
    // Lock/exit path: closeOwner revokes monitor windows too.
    await DesktopTabWindows.openMonitors(
      windows: windows,
      owner: owner,
      tabId: 't',
      session: session,
      title: 'Win',
    );
    await windows.closeOwner(owner);
    expect(children.skip(3).every((c) => c.closedByOwner), isTrue);
    expect(windows.detachedSessionIds(owner), isEmpty);
    await session.close();
  });

  test('desktop launch detection rejects malformed or capability-less launches', () {
    expect(detectDesktopWindow(const []), isNull);
    expect(detectDesktopWindow(const ['--other']), isNull);
    // No capability in the environment (tests never set it) → rejected.
    expect(
      () => detectDesktopWindow(const [
        '--desktop-window-port=4000',
        '--desktop-window-session=AAAAAAAAAAAAAAAAAAAAAA',
      ]),
      throwsFormatException,
    );
    expect(
      () => detectDesktopWindow(const ['--desktop-window-port=4000']),
      throwsFormatException,
    );
    expect(
      () => detectDesktopWindow(const [
        '--desktop-window-port=99999',
        '--desktop-window-session=x',
      ]),
      throwsFormatException,
    );
  });

  test('display persistence refused by a changed scope stays session-only', () async {
    final fake = _Fake();
    final notices = <String>[];
    var calls = 0;
    final session = DesktopSession(
      directConnectionForTesting: (_) => fake,
      saveDisplaySettings: (updated) async {
        calls++;
        throw StateError('The workspace changed.'); // e.g. locked or Host changed meanwhile
      },
    )..onNotice = notices.add;
    await session.connectLocal(
      const HostRecord(id: 'r', name: 'R', address: 'r', protocol: HostProtocol.rdp),
    );
    await session.changeResolution(width: 1600, height: 900);
    expect(calls, 1);
    expect(session.rdpSettings.width, 1600); // applied for this session
    expect(notices.last, contains('The resolution setting applies to this session only; it couldn\'t be saved to the host.'));
    await session.close();
  });
}
