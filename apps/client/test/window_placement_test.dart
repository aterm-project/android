import 'dart:async';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/domain/window_combination.dart';
import 'package:aterm_client/domain/window_placement.dart';
import 'package:aterm_client/platform/window_geometry.dart';
import 'package:aterm_client/platform/window_geometry_rpc.dart';
import 'package:aterm_client/platform/window_chrome.dart';
import 'package:aterm_client/ui/window_combinations.dart';

SavedWindowPlacement placement({
  int x = 10,
  int y = 20,
  bool maximized = false,
}) => SavedWindowPlacement(
  x: x,
  y: y,
  width: 1000,
  height: 600,
  maximized: maximized,
);
WindowCombination recipe({
  List<CombinationWindow> windows = const [],
  SavedWindowPlacement? main,
}) => WindowCombination(
  id: 'layout',
  name: 'Layout',
  panes: [
    CombinationPane(kind: 'ssh', hostId: 'host-a'),
    CombinationPane(kind: 'rdp', hostId: 'host-b'),
  ],
  tree: {'pane': 0},
  activePane: 0,
  mainPlacement: main,
  windows: windows,
);

class _Geometry extends WindowGeometry {
  SavedWindowPlacement? captured = placement();
  bool succeeds = true;
  int restores = 0;
  @override
  Future<SavedWindowPlacement?> capturePlacement() async => captured;
  @override
  Future<bool> restorePlacement(
    SavedWindowPlacement value, {
    bool Function()? isCurrent,
  }) async {
    restores++;
    return succeeds;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('v1 unchanged and strict v2 geometry associations roundtrip without runtime IDs', () {
    final old = recipe();
    expect(old.toJson()['version'], 1);
    expect(old.toJson().length, 6);
    expect(
      () => WindowCombination.fromJson({...old.toJson(), 'version': 1.0}),
      throwsFormatException,
    );
    expect(
      WindowCombination.decode(WindowCombination.encode([old])).single.toJson(),
      old.toJson(),
    );
    final next = recipe(
      main: placement(maximized: true),
      windows: [
        CombinationWindow(
          pane: 1,
          placement: placement(x: -1200),
          viewport: {'x': 0, 'y': 0, 'width': 1920, 'height': 1080},
        ),
      ],
    );
    final encoded = WindowCombination.encode([next]);
    final reopened = WindowCombination.decode(encoded).single;
    expect(reopened.toJson()['version'], 2);
    expect(reopened.windows.single.pane, 1);
    expect(reopened.mainPlacement!.maximized, true);
    expect(encoded, isNot(contains('sessionId')));
    expect(encoded, isNot(contains('capability')));
    expect(encoded, isNot(contains('password')));
    expect(
      () => WindowCombination.fromJson({...next.toJson(), 'process_id': 5}),
      throwsFormatException,
    );
    expect(
      () =>
          recipe(windows: [CombinationWindow(pane: 2, placement: placement())]),
      throwsFormatException,
    );
    expect(
      () => recipe(
        windows: [
          CombinationWindow(
            pane: 0,
            viewport: {'x': 0, 'y': 0, 'width': 10, 'height': 10},
          ),
        ],
      ),
      throwsFormatException,
    );
    expect(
      () => recipe(
        windows: [CombinationWindow(pane: 1), CombinationWindow(pane: 1)],
      ),
      throwsFormatException,
    );
    expect(
      () => SavedWindowPlacement(x: 999999, y: 0, width: 500, height: 400),
      throwsFormatException,
    );
  });
  test('monitor removal selects primary and clamps complete normal rect; negative monitor overlap retained', () {
    const primary = MonitorInfo(
      bounds: Rect.fromLTWH(0, 0, 1280, 800),
      work: Rect.fromLTWH(0, 0, 1280, 760),
      primary: true,
      dpi: 96,
    );
    const left = MonitorInfo(
      bounds: Rect.fromLTWH(-1920, 0, 1920, 1080),
      work: Rect.fromLTWH(-1920, 0, 1920, 1040),
      primary: false,
      dpi: 144,
    );
    expect(
      safeWindowRect(placement(x: 9000, y: 9000), [primary]),
      const Rect.fromLTWH(280, 160, 1000, 600),
    );
    expect(
      safeWindowRect(placement(x: -1800, y: 20), [primary, left]),
      const Rect.fromLTWH(-1800, 20, 1000, 600),
    );
    expect(
      safeWindowRect(
        SavedWindowPlacement(x: -9000, y: 0, width: 3000, height: 2000),
        [primary],
      ),
      const Rect.fromLTWH(0, 0, 1280, 760),
    );
    expect(safeWindowRect(placement(), []), isNull);
  });
  test('native own-window mock captures normal while maximized and applies safe bounds before maximize', () async {
    const channel = MethodChannel('test/window-geometry'),
        chromeChannel = MethodChannel('test/window-chrome');
    final calls = <String>[];
    var maximized = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'getBounds')
            return {
              'bounds': {'x': 0, 'y': 0, 'width': 1280, 'height': 800},
              'normal': {'x': 10, 'y': 20, 'width': 1000, 'height': 600},
              'maximized': maximized,
              'minimized': false,
              'covering': false,
            };
          if (call.method == 'getMonitors')
            return [
              {
                'bounds': {'x': 0, 'y': 0, 'width': 1280, 'height': 800},
                'work': {'x': 0, 'y': 0, 'width': 1280, 'height': 760},
                'primary': true,
                'dpi': 96,
              },
            ];
          if (call.method == 'setBounds') {
            expect(call.arguments, {
              'x': 280,
              'y': 160,
              'width': 1000,
              'height': 600,
            });
            maximized = false;
            return true;
          }
          return false;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(chromeChannel, (call) async {
          calls.add(call.method);
          if (call.method == 'toggleMaximize') {
            maximized = true;
            return null;
          }
          return {
            'enabled': true,
            'maximized': maximized,
            'minimized': false,
            'focused': true,
          };
        });
    final chrome = WindowChromeController(
      channel: chromeChannel,
      supported: true,
    );
    try {
      final geometry = WindowGeometry(channel: channel, chrome: chrome);
      expect(
        (await geometry.capturePlacement())!.toJson(),
        placement(maximized: true).toJson(),
      );
      expect(
        await geometry.restorePlacement(
          placement(x: 9000, y: 9000, maximized: true),
        ),
        true,
      );
      expect(
        calls.indexOf('setBounds'),
        lessThan(calls.indexOf('toggleMaximize')),
      );
    } finally {
      chrome.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(chromeChannel, null);
    }
  });
  test(
    'scope change during monitor lookup prevents moving the current window',
    () async {
      const channel = MethodChannel('test/geometry-stale');
      final monitors = Completer<Object?>();
      var current = true;
      var moves = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getMonitors') return monitors.future;
            if (call.method == 'setBounds') {
              moves++;
              return true;
            }
            return null;
          });
      try {
        final restoring = WindowGeometry(channel: channel)
            .restorePlacement(placement(), isCurrent: () => current);
        current = false;
        monitors.complete([
          {
            'bounds': {'x': 0, 'y': 0, 'width': 1280, 'height': 800},
            'work': {'x': 0, 'y': 0, 'width': 1280, 'height': 760},
            'primary': true,
            'dpi': 96,
          },
        ]);
        expect(await restoring, false);
        expect(moves, 0);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    },
  );
  test('authenticated-socket RPC is bounded, validates exact schema, times out and revokes', () async {
    final owner = WindowGeometryRpcOwner(
      timeout: const Duration(milliseconds: 20),
    );
    final fake = _Geometry();
    void send(Map<String, Object?> message) {
      unawaited(
        handleWindowGeometryRequest(
          Map<String, dynamic>.from(message),
          geometry: fake,
        ).then((reply) => owner.receive(Map<String, dynamic>.from(reply))),
      );
    }

    expect((await owner.capture(send))!.toJson(), placement().toJson());
    expect(await owner.apply(send, placement()), true);
    expect(fake.restores, 1);
    await expectLater(
      handleWindowGeometryRequest({
        'type': 'window_geometry_request',
        'request': 1,
        'action': 'get',
        'hwnd': 5,
      }, geometry: fake),
      throwsFormatException,
    );
    expect(
      owner.receive({
        'type': 'window_geometry_reply',
        'request': 1,
        'placement': null,
        'applied': false,
        'secret': 'x',
      }),
      false,
    );
    final pending = owner.capture((_) {});
    expect(await owner.capture((_) {}), isNull);
    owner.close();
    expect(await pending, isNull);
    expect(await owner.capture(send), isNull);
    final timeout = WindowGeometryRpcOwner(
      timeout: const Duration(milliseconds: 1),
    );
    expect(await timeout.capture((_) {}), isNull);
    timeout.close();
  });
  test('explicit placement restoration reports partial failures and closes stale newly detached mirrors', () async {
    final fake = _Geometry();
    var current = true;
    final pending = Completer<String?>();
    final closed = <String>[];
    var applies = 0;
    final value = recipe(
      main: placement(),
      windows: [CombinationWindow(pane: 1, placement: placement())],
    );
    final restoring = restoreWindowCombinationPlacements(
      recipe: value,
      sessions: {1: 'runtime-new'},
      isCurrent: () => current,
      detach: (_, __, ___) => pending.future,
      applyDetached: (_, __) async {
        applies++;
        return true;
      },
      closeDetached: (id) async {
        closed.add(id);
      },
      geometry: fake,
    );
    current = false;
    pending.complete('new-child');
    await restoring;
    expect(closed, ['new-child']);
    expect(applies, 0);
    expect(fake.restores, 0);
    current = true;
    fake.succeeds = false;
    final failures = await restoreWindowCombinationPlacements(
      recipe: value,
      sessions: {1: 'new'},
      isCurrent: () => current,
      detach: (_, __, ___) async => 'child',
      applyDetached: (_, __) async => false,
      closeDetached: (_) async {},
      geometry: fake,
    );
    expect(failures, 2);
    expect(fake.restores, 1);
  });
}
