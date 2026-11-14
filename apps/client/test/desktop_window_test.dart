import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/desktop/rdp_settings.dart';
import 'package:aterm_client/desktop/window/desktop_window.dart';
import 'package:aterm_client/desktop/window/monitor_windows.dart';
import 'package:aterm_client/platform/application_windows.dart';
import 'package:aterm_client/platform/window_chrome.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/terminal/live_terminal_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/l10n_fixture.dart';

class _Fake implements DirectDesktopConnection {
  final controller = StreamController<DesktopEvent>();
  final sent = <List<Object>>[];
  final pasted = <String>[];
  @override
  Stream<DesktopEvent> get events => controller.stream;
  @override
  void send(List<Object> command) => sent.add(command);
  @override
  void paste(String text) => pasted.add(text);
  @override
  Future<void> close() async {
    if (!controller.isClosed) await controller.close();
  }
}

Uint8List _solid(int w, int h, int b, int g, int r) {
  final out = Uint8List(w * h * 4);
  for (var i = 0; i < out.length; i += 4) {
    out[i] = b;
    out[i + 1] = g;
    out[i + 2] = r;
    out[i + 3] = 255;
  }
  return out;
}

Future<void> _until(bool Function() condition, {String what = 'condition'}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<(DesktopSession, _Fake)> _connected() async {
  final fake = _Fake();
  final session = DesktopSession(directConnectionForTesting: (_) => fake);
  await session.connectLocal(
    const HostRecord(id: 'r', name: 'R', address: 'r', protocol: HostProtocol.rdp),
  );
  var acked = 0;
  fake.controller.add(DesktopFrame(64, 48, _solid(64, 48, 10, 20, 30), onConsumed: () => acked++));
  await _until(() => acked == 1 && session.state == 'connected', what: 'first frame');
  return (session, fake);
}

void main() {
  useAppLocaleFixture('zh');
  TestWidgetsFlutterBinding.ensureInitialized();
  // The binding mocks HttpClient; these tests need real loopback sockets.
  setUp(() => HttpOverrides.global = null);

  test('monitor specs map each monitor into the spanning framebuffer', () {
    final specs = monitorWindowSpecs(
      RdpMonitorLayout.normalize(const [
        RdpMonitorLayout(x: -1920, y: 120, width: 1920, height: 1080, primary: false),
        RdpMonitorLayout(x: 0, y: 0, width: 2560, height: 1440, primary: true),
      ]),
      'Win',
    );
    expect(specs, hasLength(2));
    expect(specs[0].viewport, const Rect.fromLTWH(0, 120, 1920, 1080));
    expect(specs[1].viewport, const Rect.fromLTWH(1920, 0, 2560, 1440));
    expect(specs[1].coverMonitor, const Rect.fromLTWH(0, 0, 2560, 1440));
    expect(specs[1].title, contains('主'));
    expect(monitorWindowSpecs(const [], 'x'), isEmpty);
  });

  test('child mirrors frames and returns validated input; credentials never cross', () async {
    final (session, fake) = await _connected();
    final broker = await DesktopWindowBroker.bind(
      session: session,
      spec: const DesktopWindowSpec(title: 'Win'),
    );
    final child = await connectDesktopWindow(broker.launch);
    child.confirmReady();
    expect(await broker.ready, isTrue);
    await _until(() => child.display.size == const Size(64, 48), what: 'snapshot');
    expect(child.state, 'connected');
    // A partial update after the snapshot reaches the child.
    var acked = 0;
    fake.controller.add(
      DesktopFrame(64, 48, _solid(4, 4, 1, 2, 3), x: 8, y: 8, regionWidth: 4, regionHeight: 4,
          onConsumed: () => acked++),
    );
    await _until(() => acked == 1, what: 'partial frame');
    child.send(['key', 0x61, 1]);
    child.send(['key', 0x1008ff13, 1]); // XF86AudioRaiseVolume (29-bit keysym)
    child.send(['mouse', 10, 12, 1]);
    child.paste('hi');
    await _until(() => fake.sent.length >= 3 && fake.pasted.isNotEmpty, what: 'input');
    expect(fake.sent, containsAllInOrder([
      ['key', 0x61, 1],
      ['key', 0x1008ff13, 1],
      ['mouse', 10, 12, 1],
    ]));
    expect(fake.pasted, ['hi']);
    // The child is a renderer only: it has no Host or protocol connection.
    expect(child.protocol, isNull);
    expect(child.rdpConfig, isNull);
    await broker.close();
    await _until(() => child.state == 'disconnected', what: 'revocation reaches child');
    await session.close();
  });

  test('broker rejects wrong capability, browser origins, reuse and out-of-range input', () async {
    final (session, fake) = await _connected();
    final broker = await DesktopWindowBroker.bind(
      session: session,
      spec: const DesktopWindowSpec(title: 'Win', viewport: Rect.fromLTWH(0, 0, 32, 32)),
    );
    final launch = broker.launch;
    final wrong = DesktopWindowLaunch(
      port: launch.port,
      sessionId: launch.sessionId,
      capability: 'A' * 43,
    );
    await expectLater(connectDesktopWindow(wrong), throwsA(isA<WebSocketException>()));
    final browser = await HttpClient().getUrl(
      Uri.parse('http://127.0.0.1:${launch.port}/desktop/${launch.sessionId}'),
    );
    browser.headers
      ..set('origin', 'http://localhost')
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${launch.capability}');
    expect((await browser.close()).statusCode, HttpStatus.forbidden);
    final child = await connectDesktopWindow(launch);
    child.confirmReady();
    await broker.ready;
    // The capability is single-use.
    await expectLater(connectDesktopWindow(launch), throwsA(isA<WebSocketException>()));
    // A monitor viewport window may not resize the remote desktop.
    child.send(['size', 1000, 800]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(fake.sent.where((c) => c[0] == 'size'), isEmpty);
    // Out-of-range pointer input is a protocol violation and ends the window.
    child.send(['mouse', 9999, 0, 0]);
    expect(await broker.outcome, LiveTerminalWindowCloseReason.transportLost);
    expect(fake.sent.where((c) => c[0] == 'mouse'), isEmpty);
    await session.close();
  });

  test('user close is reported as user and owner revocation closes desktop windows', () async {
    final (session, _) = await _connected();
    final chrome = _Chrome();
    final children = <_Child>[];
    final manager = ApplicationWindows(
      windowChrome: chrome,
      liveWindowsSupported: true,
      desktopOpener: ({required session, required spec, onReady}) async {
        final child = _Child(onReady);
        children.add(child);
        return child.handle;
      },
    );
    final owner = Object();
    final events = <String>[];
    Future<bool> open(String id) => manager.detachDesktop(
      owner: owner,
      windowId: id,
      session: session,
      spec: DesktopWindowSpec(title: id),
      onDetached: () => events.add('detached:$id'),
      onUserClosed: () => events.add('user:$id'),
      onRestored: () => events.add('restored:$id'),
    );
    final a = open('tab#0'), b = open('tab#1');
    await Future<void>.delayed(Duration.zero);
    for (final c in children) {
      c.ready();
    }
    expect(await a, isTrue);
    expect(await b, isTrue);
    expect(manager.detachedSessionIds(owner), {'tab#0', 'tab#1'});
    children[0].finish(LiveTerminalWindowCloseReason.user);
    await _until(() => events.contains('user:tab#0'), what: 'user close');
    await manager.closeOwner(owner);
    expect(children[1].ownerCloses, 1);
    expect(manager.detachedSessionIds(owner), isEmpty);
    expect(events, isNot(contains('restored:tab#1')));
    await session.close();
  });

  group('review fixes', () {
    test('transport loss releases keys and buttons the child held', () async {
      final (session, fake) = await _connected();
      final broker = await DesktopWindowBroker.bind(
        session: session,
        spec: const DesktopWindowSpec(title: 'Win'),
      );
      final child = await connectDesktopWindow(broker.launch);
      child.confirmReady();
      await broker.ready;
      child.send(['key', 0xffe3, 1]); // Ctrl down
      child.send(['mouse', 10, 10, 1]); // left button down
      await _until(() => fake.sent.length >= 2, what: 'input');
      await child.close(); // child dies / socket lost without key-up
      expect(await broker.outcome, LiveTerminalWindowCloseReason.transportLost);
      expect(fake.sent, containsAllInOrder([
        ['key', 0xffe3, 1],
        ['mouse', 10, 10, 1],
        ['key', 0xffe3, 0],
        ['mouse', 10, 10, 0],
      ]));
      // The parent session itself is untouched.
      expect(session.state, 'connected');
      await session.close();
    });

    test('owner revocation also releases input; released keys are not repeated', () async {
      final (session, fake) = await _connected();
      final broker = await DesktopWindowBroker.bind(
        session: session,
        spec: const DesktopWindowSpec(title: 'Win'),
      );
      final child = await connectDesktopWindow(broker.launch);
      child.confirmReady();
      await broker.ready;
      child.send(['key', 0x61, 1]);
      child.send(['key', 0x61, 0]);
      child.send(['key', 0xffe9, 1]); // Alt held
      await _until(() => fake.sent.length >= 3, what: 'input');
      await broker.close();
      final ups = fake.sent.where((c) => c[0] == 'key' && c[2] == 0).toList();
      expect(ups, [
        ['key', 0x61, 0],
        ['key', 0xffe9, 0],
      ]);
      await _until(() => child.state == 'disconnected', what: 'child notified');
      await session.close();
    });

    test('user close of a covered monitor window ends only the renderer process', () async {
      final (session, fake) = await _connected();
      final process = _FakeProcess();
      late MirroredDesktopSession child;
      final handle = await openDesktopWindow(
        session: session,
        spec: const DesktopWindowSpec(
          title: 'Win · 显示器 2',
          viewport: Rect.fromLTWH(0, 0, 32, 24),
          coverMonitor: Rect.fromLTWH(1920, 0, 1920, 1080),
        ),
        startProcess: (exe, args, env) async {
          final port = int.parse(args[0].split('=').last);
          final id = args[1].split('=').last;
          final capability = env.values.single;
          // The "child process": a renderer connecting with the launch data.
          unawaited(() async {
            child = await connectDesktopWindow(
              DesktopWindowLaunch(port: port, sessionId: id, capability: capability),
            );
            child.confirmReady();
          }());
          return process;
        },
      );
      expect(await handle.ready, isTrue);
      expect(child.coverMonitor, const Rect.fromLTWH(1920, 0, 1920, 1080));
      // The close icon's guarded path ends in requestUserClose + process exit;
      // even if the child never exits by itself, the parent terminates it.
      await child.requestUserClose();
      expect(await handle.outcome, LiveTerminalWindowCloseReason.user);
      await handle.processExited.timeout(const Duration(seconds: 5));
      expect(process.killed, isTrue);
      expect(session.state, 'connected');
      expect(fake.controller.isClosed, isFalse);
      await session.close();
    });
  });
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
  _Child(this.onReady);
  final VoidCallback? onReady;
  final _ready = Completer<bool>(), _outcome = Completer<LiveTerminalWindowCloseReason>();
  final _exited = Completer<void>();
  int ownerCloses = 0;
  late final handle = LiveTerminalWindowHandle(
    ready: _ready.future,
    closed: _outcome.future.then((_) {}),
    outcome: _outcome.future,
    processExited: _exited.future,
    close: () async {
      ownerCloses++;
      finish(LiveTerminalWindowCloseReason.parentClosed);
    },
    port: 1,
    sessionId: 'x',
  );
  void ready() {
    onReady?.call();
    _ready.complete(true);
  }

  void finish(LiveTerminalWindowCloseReason reason) {
    if (!_ready.isCompleted) _ready.complete(false);
    if (!_outcome.isCompleted) _outcome.complete(reason);
    if (!_exited.isCompleted) _exited.complete();
  }
}


class _FakeProcess implements Process {
  final _exit = Completer<int>();
  bool killed = false;
  @override
  int get pid => 4242;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(-1);
    return true;
  }

  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
