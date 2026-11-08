import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/domain/window_placement.dart';
import 'package:aterm_client/platform/application_windows.dart';
import 'package:aterm_client/platform/window_chrome.dart';
import 'package:aterm_client/platform/window_geometry.dart';
import 'package:aterm_client/terminal/live_terminal_window.dart';
import 'package:aterm_client/terminal/mirrored_terminal.dart';
import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/window/desktop_window.dart';
import 'package:aterm_client/domain/window_combination.dart';
import 'package:aterm_client/ui/window_combinations.dart';
import 'package:aterm_client/ui/session_workspace.dart';

SavedWindowPlacement _placement() => SavedWindowPlacement(
  x: 20,
  y: 30,
  width: 800,
  height: 600,
  maximized: false,
);

class _RealNetwork extends HttpOverrides {}

class _Chrome extends WindowChromeController {
  _Chrome() : super(supported: true);
  @override
  WindowChromeState get state => const WindowChromeState(enabled: true);
  @override
  Future<void> show() async {}
  @override
  Future<void> hide() async {}
}

class _Geometry extends WindowGeometry {
  int captures = 0, restores = 0;
  @override
  Future<bool> restorePlacement(
    SavedWindowPlacement value, {
    bool Function()? isCurrent,
  }) async {
    if (isCurrent?.call() == false) return false;
    restores++;
    return true;
  }

  @override
  Future<SavedWindowPlacement?> capturePlacement() async {
    captures++;
    return _placement();
  }
}

class _Child {
  final outcome = Completer<LiveTerminalWindowCloseReason>();
  Completer<SavedWindowPlacement?>? captureGate;
  Completer<bool>? applyGate;
  int closes = 0, applies = 0;
  late final handle = LiveTerminalWindowHandle(
    ready: Future.value(true),
    closed: outcome.future.then((_) {}),
    outcome: outcome.future,
    processExited: Future.value(),
    port: 1234,
    sessionId: 'runtime-child',
    close: () async {
      closes++;
      if (!outcome.isCompleted)
        outcome.complete(LiveTerminalWindowCloseReason.parentClosed);
    },
    capturePlacement: () => captureGate?.future ?? Future.value(_placement()),
    applyPlacement: (_) async {
      applies++;
      return applyGate?.future ?? true;
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  void mockGeometry() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('atermius/window_geometry'),
          (call) async {
            const rect = {'x': 20, 'y': 30, 'width': 800, 'height': 600};
            if (call.method == 'getBounds')
              return {
                'bounds': rect,
                'normal': rect,
                'maximized': false,
                'minimized': false,
                'covering': false,
              };
            if (call.method == 'getMonitors')
              return [
                {
                  'bounds': {'x': 0, 'y': 0, 'width': 1920, 'height': 1080},
                  'work': {'x': 0, 'y': 0, 'width': 1920, 'height': 1040},
                  'primary': true,
                  'dpi': 96,
                },
              ];
            if (call.method == 'setBounds') return true;
            return false;
          },
        );
  }

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('atermius/window_geometry'),
          null,
        ),
  );
  test(
    'terminal geometry crosses only the authenticated ready mirror socket',
    () async {
      mockGeometry();
      await HttpOverrides.runWithHttpOverrides(() async {
        final broker = await LiveTerminalBroker.bind(
          terminal: MirroredTerminal(),
          title: 'SSH',
        );
        final child = await connectLiveTerminalWindow(broker.launch);
        try {
          expect(await broker.capturePlacement(), isNull);
          child.confirmReady();
          expect(await broker.ready, true);
          expect(
            (await broker.capturePlacement())!.toJson(),
            _placement().toJson(),
          );
          expect(await broker.applyPlacement(_placement()), true);
        } finally {
          await broker.close();
          await child.close();
        }
        expect(await broker.capturePlacement(), isNull);
      }, _RealNetwork());
    },
  );
  test('desktop geometry uses the same ready capability socket without RDP or Windows', () async {
    mockGeometry();
    await HttpOverrides.runWithHttpOverrides(() async {
      final session = DesktopSession();
      final broker = await DesktopWindowBroker.bind(
        session: session,
        spec: const DesktopWindowSpec(title: 'Desktop'),
      );
      final child = await connectDesktopWindow(broker.launch);
      try {
        child.confirmReady();
        expect(await broker.ready, true);
        expect(
          (await broker.capturePlacement())!.toJson(),
          _placement().toJson(),
        );
        expect(await broker.applyPlacement(_placement()), true);
      } finally {
        await broker.close();
        await child.close();
        await session.close();
        session.dispose();
      }
    }, _RealNetwork());
  });
  test('manager capture is owner bound and source close closes restored monitor family', () async {
    final children = <_Child>[];
    final manager = ApplicationWindows(
      windowChrome: _Chrome(),
      liveWindowsSupported: true,
      opener:
          ({
            required terminal,
            required title,
            onReady,
            onClosed,
            onOpenFiles,
          }) async {
            final child = _Child();
            children.add(child);
            onReady?.call();
            return child.handle;
          },
    );
    final owner = Object(), other = Object();
    Future<bool> open(Object owner, String id) => manager.detach(
      owner: owner,
      sessionId: id,
      terminal: MirroredTerminal(),
      title: id,
      onDetached: () {},
      onUserClosed: () {},
      onRestored: () {},
    );
    await open(owner, 'session');
    await open(owner, 'session#savedMonitor0');
    await open(other, 'foreign');
    expect(
      (await manager.captureWindowPlacements(owner))
          .map((w) => w.windowId)
          .toSet(),
      {'session', 'session#savedMonitor0'},
    );
    expect(
      await manager.applyWindowPlacement(other, 'session', _placement()),
      false,
    );
    expect(children.first.applies, 0);
    await manager.closeSession(owner, 'session');
    expect(children[0].closes, 1);
    expect(children[1].closes, 1);
    expect(children[2].closes, 0);
    expect(await manager.captureWindowPlacements(owner), isEmpty);
    await manager.closeAll();
    manager.dispose();
  });
  test('desktop monitor capture preserves pane viewport and geometry without runtime/title data', () async {
    final child = _Child();
    final geometry = _Geometry(), owner = Object();
    final session = DesktopSession();
    final manager = ApplicationWindows(
      windowChrome: _Chrome(),
      liveWindowsSupported: true,
      desktopOpener: ({required session, required spec, onReady}) async {
        onReady?.call();
        return child.handle;
      },
    );
    await manager.detachDesktop(
      owner: owner,
      windowId: 'runtime-secret#monitor0',
      session: session,
      spec: const DesktopWindowSpec(
        title: 'private-visible-title',
        viewport: Rect.fromLTWH(1920, 0, 1920, 1080),
        coverMonitor: Rect.fromLTWH(0, 0, 1920, 1080),
      ),
      onDetached: () {},
      onUserClosed: () {},
      onRestored: () {},
    );
    final recipe = await captureWindowCombinationWithPlacements(
      id: 'layout',
      name: 'Monitor',
      sessionIds: ['runtime-secret'],
      workspace: SessionWorkspaceController()..activate('runtime-secret'),
      describe: (_) => CombinationPane(kind: 'rdp', hostId: 'current-host'),
      owner: owner,
      isCurrent: () => true,
      applicationWindows: manager,
      geometry: geometry,
    );
    expect(recipe.windows.single.viewport, {
      'x': 1920,
      'y': 0,
      'width': 1920,
      'height': 1080,
    });
    expect(recipe.windows.single.pane, 0);
    final encoded = WindowCombination.encode([recipe]);
    expect(encoded, isNot(contains('runtime-secret')));
    expect(encoded, isNot(contains('private-visible-title')));
    expect(encoded, isNot(contains('coverMonitor')));
    await manager.closeSession(owner, 'runtime-secret');
    expect(child.closes, 1);
    await session.close();
    session.dispose();
    manager.dispose();
  });
  test('revocation during capture/apply discards stale results', () async {
    final child = _Child()
      ..captureGate = Completer<SavedWindowPlacement?>()
      ..applyGate = Completer<bool>();
    final manager = ApplicationWindows(
      windowChrome: _Chrome(),
      liveWindowsSupported: true,
      opener:
          ({
            required terminal,
            required title,
            onReady,
            onClosed,
            onOpenFiles,
          }) async {
            onReady?.call();
            return child.handle;
          },
    );
    final owner = Object();
    await manager.detach(
      owner: owner,
      sessionId: 'session',
      terminal: MirroredTerminal(),
      title: 'S',
      onDetached: () {},
      onUserClosed: () {},
      onRestored: () {},
    );
    final capture = manager.captureWindowPlacements(owner),
        apply = manager.applyWindowPlacement(owner, 'session', _placement());
    await manager.closeOwner(owner);
    child.captureGate!.complete(_placement());
    child.applyGate!.complete(true);
    expect(await capture, isEmpty);
    expect(await apply, false);
    manager.dispose();
  });
  test('capture associates actual detached owner IDs to pane indices and supports all-detached layouts', () async {
    final child = _Child();
    final geometry = _Geometry();
    final manager = ApplicationWindows(
      windowChrome: _Chrome(),
      liveWindowsSupported: true,
      opener:
          ({
            required terminal,
            required title,
            onReady,
            onClosed,
            onOpenFiles,
          }) async {
            onReady?.call();
            return child.handle;
          },
    );
    final owner = Object();
    await manager.detach(
      owner: owner,
      sessionId: 'runtime-secret',
      terminal: MirroredTerminal(),
      title: 'S',
      onDetached: () {},
      onUserClosed: () {},
      onRestored: () {},
    );
    final layout = await captureWindowCombinationWithPlacements(
      id: 'layout',
      name: 'Detached',
      sessionIds: ['runtime-secret'],
      workspace: SessionWorkspaceController(),
      describe: (_) =>
          CombinationPane(kind: 'ssh', hostId: 'host-current-scope'),
      owner: owner,
      isCurrent: () => true,
      applicationWindows: manager,
      geometry: geometry,
    );
    expect(layout.windows.single.pane, 0);
    expect(layout.mainPlacement!.toJson(), _placement().toJson());
    final encoded = WindowCombination.encode([layout]);
    expect(encoded, isNot(contains('runtime-secret')));
    expect(encoded, isNot(contains('runtime-child')));
    expect(
      WindowCombination.decode(encoded).single.windows.single.placement!
          .toJson(),
      _placement().toJson(),
    );
    expect(
      child.applies,
      0,
    ); // Saving/decoding never moves a window or connects.
    var connections = 0;
    final reopened = WindowCombination.decode(encoded).single;
    final restored = await CombinationRestoreCoordinator().restore(
      recipe: reopened,
      isCurrent: () => true,
      canResolve: (pane) => pane.hostId == 'host-current-scope',
      open: (_) async {
        connections++;
        return 'new-runtime';
      },
    );
    final target = SessionWorkspaceController();
    applyWindowCombination(reopened, target, restored!.sessions);
    expect(connections, 1);
    final placementFailures = await restoreWindowCombinationPlacements(
      recipe: reopened,
      sessions: restored.sessions,
      isCurrent: () => true,
      detach: (_, __, sessionId) async {
        final opened = await manager.detach(
          owner: owner,
          sessionId: sessionId,
          terminal: MirroredTerminal(),
          title: 'Resolved current Host',
          onDetached: () => target.remove(sessionId),
          onUserClosed: () {},
          onRestored: () => target.activate(sessionId),
        );
        return opened ? sessionId : null;
      },
      applyDetached: (id, value) =>
          manager.applyWindowPlacement(owner, id, value),
      closeDetached: (id) => manager.closeSession(owner, id),
      geometry: geometry,
    );
    expect(placementFailures, 0);
    expect(geometry.restores, 1);
    expect(child.applies, 1);
    expect(target.sessionIds, isEmpty);
    expect(manager.isDetached(owner, 'new-runtime'), true);

    await manager.closeAll();
    manager.dispose();
  });
}
