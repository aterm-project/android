import 'dart:async';
import 'dart:io';

import 'package:aterm_client/desktop/desktop_keyboard_mode.dart';
import 'package:aterm_client/desktop/desktop_resolution.dart';
import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/desktop_view.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/desktop/direct/rdp_io.dart' show rdpKeyEvents;
import 'package:aterm_client/desktop/keyboard_capture.dart';
import 'package:aterm_client/desktop/keyboard_capture_keymaps.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/platform/fullscreen.dart';
import 'package:aterm_client/storage/desktop_keyboard_store.dart';
import 'package:aterm_client/storage/keyboard_capture_store.dart';
import 'package:aterm_client/storage/keyboard_capture_store_native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/l10n_fixture.dart';

const _channel = MethodChannel('atermius/keyboard_capture');

/// Records Dart -> native calls and answers like a runner.
class _Native {
  _Native({
    this.permission = 'notRequired',
    this.windowFocused = true,
    this.supported = true,
  });
  final calls = <MethodCall>[];
  String permission;
  bool windowFocused, supported;
  Object? error;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          final failure = error;
          if (failure != null) throw failure;
          return {
            'supported': supported,
            'permission': permission,
            if (call.method == 'getState') 'windowFocused': windowFocused,
          };
        });
  }

  List<bool> get configured => [
    for (final call in calls)
      if (call.method == 'configure')
        (call.arguments as Map<Object?, Object?>)['armed']! as bool,
  ];
}

void _uninstall() => TestDefaultBinaryMessengerBinding
    .instance
    .defaultBinaryMessenger
    .setMockMethodCallHandler(_channel, null);

/// Native -> Dart invocation, as the runner sends it.
Future<void> _fromNative(String method, Map<String, Object?> arguments) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, arguments),
        ),
        (_) {},
      );
}

Future<void> _key(
  String platform,
  int code, {
  required bool down,
  String char = '',
  bool extended = false,
  int scan = 0,
  int? modifiers,
}) => _fromNative('key', {
  'platform': platform,
  'down': down,
  'code': code,
  'scan': scan,
  'extended': extended,
  'char': char,
  'modifiers': ?modifiers,
});

class _Sent {
  final events = <(int, bool)>[];
  void call(int keysym, bool down) => events.add((keysym, down));
}

class _KeyTarget implements DirectDesktopConnection {
  final stream = StreamController<DesktopEvent>();
  final keys = <(int, bool)>[];
  @override
  Stream<DesktopEvent> get events => stream.stream;
  @override
  void send(List<Object> command) {
    if (command.first == 'key') {
      keys.add((command[1] as int, command[2] == 1));
    }
  }

  @override
  void paste(String text) {}
  @override
  Future<void> close() async {
    unawaited(stream.close());
  }
}

class _FailingStore implements KeyboardCaptureStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async => throw const FileSystemException();
}

class _SlowStore implements KeyboardCaptureStore {
  _SlowStore(this.value);
  String? value;
  int reads = 0;
  Completer<String?>? _next;

  /// The next read waits until the returned completer completes.
  Completer<String?> hold() => _next = Completer<String?>();
  @override
  Future<String?> read() {
    reads++;
    final next = _next;
    _next = null;
    return next?.future ?? Future.value(value);
  }

  @override
  Future<void> write(String value) async => this.value = value;
}

void _platform(TargetPlatform? platform) {
  debugDefaultTargetPlatformOverride = platform;
  if (platform != null) {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StreamController<bool> fullscreenChanges;
  late FullscreenController fullscreen;
  setUp(() {
    fullscreenChanges = StreamController<bool>.broadcast();
    fullscreen = FullscreenController(
      supported: true,
      read: () async => null,
      changes: fullscreenChanges.stream,
      apply: (value) async => value,
    );
    FullscreenController.debugInstance = fullscreen;
  });
  tearDown(() {
    _uninstall();
    FullscreenController.debugInstance = null;
    fullscreen.dispose();
    unawaited(fullscreenChanges.close());
  });

  KeyboardCaptureController controller() {
    final value = KeyboardCaptureController();
    addTearDown(value.dispose);
    return value;
  }

  group('arming rule', () {
    for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
      test('${platform.name} needs keyboard focus and the pointer', () async {
        _platform(platform);
        final native = _Native()..install();
        final capture = controller();
        final target = capture.register(_Sent().call);
        target.update(focused: true);
        expect(target.armed, isFalse);
        target.update(hovered: true);
        expect(target.armed, isTrue);
        // The window focus report does not replace the pointer rule here:
        // the runner itself checks the foreground window per event.
        await _fromNative('windowFocus', {'focused': false});
        expect(capture.nativeWindowFocused, isFalse);
        expect(target.armed, isTrue);
        target.update(enabled: false);
        expect(target.armed, isFalse, reason: 'the session is not connected');
        target.update(enabled: true);
        expect(target.armed, isTrue);
        target.update(hovered: false);
        expect(target.armed, isFalse);
        target.update(hovered: true, focused: false);
        expect(target.armed, isFalse);
        expect(native.configured, [true, false, true, false]);
      });
    }
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      test('${platform.name} needs focus and the front window', () async {
        _platform(platform);
        final native = _Native()..install();
        final capture = controller();
        final target = capture.register(_Sent().call);
        target.update(focused: true);
        expect(target.armed, isTrue, reason: 'no pointer on a phone');
        await _fromNative('windowFocus', {'focused': false});
        expect(target.armed, isFalse);
        target.update(hovered: true);
        expect(target.armed, isFalse);
        await _fromNative('windowFocus', {'focused': true});
        expect(target.armed, isTrue);
        target.update(focused: false);
        expect(target.armed, isFalse);
        expect(native.configured, [true, false, true, false]);
      });
    }
    for (final platform in [TargetPlatform.linux, TargetPlatform.fuchsia]) {
      test('${platform.name} never arms and has no channel', () async {
        _platform(platform);
        final native = _Native()..install();
        final capture = controller();
        await capture.load(MemoryKeyboardCaptureStore());
        final target = capture.register(_Sent().call);
        target.update(focused: true, hovered: true);
        expect(target.armed, isFalse);
        await capture.refreshState();
        await capture.requestPermission();
        expect(native.calls, isEmpty);
        expect(keyboardCaptureAvailable(), isFalse);
        expect(remoteDesktopSettingsAvailable(platform), isFalse);
      });
    }
    test('settings section is shown wherever capture or touch applies', () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      ]) {
        expect(remoteDesktopSettingsAvailable(platform), isTrue);
        expect(keyboardCaptureAvailable(platform), isTrue);
      }
    });
  });

  test('configure is sent only when the armed state changes', () async {
    _platform(TargetPlatform.windows);
    final native = _Native()..install();
    final capture = KeyboardCaptureController();
    final aKeys = _Sent();
    final a = capture.register(aKeys.call);
    final b = capture.register(_Sent().call);
    a.update(focused: true, hovered: true);
    a.update(hovered: true);
    a.update(focused: true);
    b.update(hovered: true);
    expect(native.configured, [true]);
    expect(a.armed, isTrue);
    await _key('windows', 0xa2, down: true);
    // The armed view changes without a disarmed gap: nothing to reconfigure,
    // but keys captured for the previous view are released there.
    b.update(focused: true);
    expect(b.armed, isTrue);
    expect(aKeys.events, [(0xffe3, true), (0xffe3, false)]);
    a.update(focused: false);
    a.unregister();
    expect(native.configured, [true]);
    b.unregister();
    expect(native.configured, [true, false]);
    final c = capture.register(_Sent().call);
    c.update(focused: true, hovered: true);
    capture.dispose();
    expect(native.configured, [true, false, true, false]);
    c.update(hovered: false);
    expect(native.configured, hasLength(4), reason: 'disposed is inert');
  });

  test('full screen mode arms only while this window is full screen', () async {
    _platform(TargetPlatform.windows);
    final native = _Native()..install();
    final capture = controller();
    await capture.select(KeyboardCaptureMode.fullscreen);
    final target = capture.register(_Sent().call);
    target.update(focused: true, hovered: true);
    expect(target.armed, isFalse);
    fullscreenChanges.add(true);
    await pumpEventQueue();
    expect(target.armed, isTrue);
    fullscreenChanges.add(false);
    await pumpEventQueue();
    expect(target.armed, isFalse);
    fullscreenChanges.add(true);
    await pumpEventQueue();
    await capture.select(KeyboardCaptureMode.off);
    expect(target.armed, isFalse);
    await capture.select(KeyboardCaptureMode.focused);
    expect(target.armed, isTrue);
    expect(native.configured, [true, false, true, false, true]);
  });

  group('native key codes map to X11 keysyms', () {
    final cases = <String, List<(int, String, bool, int, int?)>>{
      'windows': [
        (0x5b, '', false, 0, 0xffeb), // VK_LWIN
        (0x5c, '', false, 0, 0xffec), // VK_RWIN
        (0x09, '', false, 0, 0xff09), // Tab
        (0x1b, '', false, 0, 0xff1b), // Esc
        (0x20, ' ', false, 0, 0x20),
        (0x0d, '\r', false, 0, 0xff0d),
        (0x0d, '\r', true, 0, 0xff8d), // keypad Enter
        (0x08, '\b', false, 0, 0xff08),
        (0x2e, '', true, 0, 0xffff),
        (0x2d, '', true, 0, 0xff63),
        (0x24, '', true, 0, 0xff50),
        (0x23, '', true, 0, 0xff57),
        (0x21, '', true, 0, 0xff55),
        (0x22, '', true, 0, 0xff56),
        (0x25, '', true, 0, 0xff51),
        (0x26, '', true, 0, 0xff52),
        (0x27, '', true, 0, 0xff53),
        (0x28, '', true, 0, 0xff54),
        (0x2c, '', false, 0, 0xff61), // PrintScreen
        (0x5d, '', false, 0, 0xff67), // Menu
        (0x70, '', false, 0, 0xffbe), // F1
        (0x73, '', false, 0, 0xffc1), // F4
        (0x87, '', false, 0, 0xffd5), // F24
        (0xa0, '', false, 0, 0xffe1),
        (0xa1, '', false, 0, 0xffe2),
        (0xa2, '', false, 0, 0xffe3),
        (0xa3, '', true, 0, 0xffe4),
        (0xa4, '', false, 0, 0xffe9),
        (0xa5, '', true, 0, 0xffea),
        (0x10, '', false, 0x36, 0xffe2), // generic Shift, right scan code
        (0x11, '', true, 0, 0xffe4),
        (0x12, '', false, 0, 0xffe9),
        (0x41, 'a', false, 0x1e, 0x61),
        (0x41, '', false, 0x1e, 0x61), // US fallback without a character
        (0x5a, 'Z', false, 0, 0x7a), // lowercased
        (0x31, '1', false, 0, 0x31),
        (0x32, 'é', false, 0, 0xe9), // AZERTY top row
        (0xba, 'ö', false, 0, 0xf6), // German layout
        (0xba, '', false, 0, 0x3b),
        (0x4a, 'о', false, 0, 0x0100043e), // Cyrillic layout
        (0x65, '', false, 0, 0xffb5), // VK_NUMPAD5
        (0x6a, '*', false, 0, 0xffaa),
        (0x13, '', false, 0x45, 0xff13), // Pause
        (0x91, '', false, 0x46, 0xff14), // Scroll Lock
        (0x7c, '', false, 0x64, 0xffca), // F13
        (0x15, '', false, 0x72, 0xff31), // VK_HANGUL
        (0x15, '', true, 0x38, 0xff31), // Right Alt as Han/Yeong
        (0x15, '', false, 0x70, 0xff27), // VK_KANA (カタカナ/ひらがな)
        (0x19, '', false, 0x71, 0xff34), // VK_HANJA
        (0x19, '', false, 0x29, 0xff21), // VK_KANJI (Alt+半角/全角)
        (0xf0, '', false, 0x3a, 0xff30), // 英数
        (0xf2, '', false, 0x70, 0xff27),
        (0x5f, '', true, 0x5f, 0x1008ff2f), // VK_SLEEP
        (0xa6, '', true, 0x6a, 0x1008ff26), // VK_BROWSER_BACK
        (0xac, '', true, 0x32, 0x1008ff18), // VK_BROWSER_HOME
        (0xad, '', true, 0x20, 0x1008ff12), // VK_VOLUME_MUTE
        (0xae, '', true, 0x2e, 0x1008ff11),
        (0xaf, '', true, 0x30, 0x1008ff13),
        (0xb0, '', true, 0x19, 0x1008ff17), // VK_MEDIA_NEXT_TRACK
        (0xb3, '', true, 0x22, 0x1008ff14), // VK_MEDIA_PLAY_PAUSE
        (0xb4, '', true, 0x6c, 0x1008ff19), // VK_LAUNCH_MAIL
        (0xb6, '', true, 0x6b, 0x1008ff33), // VK_LAUNCH_APP1
        (0xb7, '', true, 0x21, 0x1008ff1d), // VK_LAUNCH_APP2
        (0xff, '', false, 0, null),
      ],
      'macos': [
        (0x37, '', false, 0, 0xffeb), // Command
        (0x36, '', false, 0, 0xffec),
        (0x3a, '', false, 0, 0xffe9), // Option
        (0x3b, '', false, 0, 0xffe3),
        (0x38, '', false, 0, 0xffe1),
        (0x30, '\t', false, 0, 0xff09),
        (0x31, ' ', false, 0, 0x20),
        (0x35, '\u001b', false, 0, 0xff1b),
        (0x24, '\r', false, 0, 0xff0d),
        (0x33, '\u007f', false, 0, 0xff08),
        (0x75, '', false, 0, 0xffff),
        (0x72, '', false, 0, 0xff63), // Help = Insert
        (0x7b, '', false, 0, 0xff51),
        (0x7e, '', false, 0, 0xff52),
        (0x7a, '', false, 0, 0xffbe), // F1
        (0x69, '', false, 0, 0xffca), // F13
        (0x5a, '', false, 0, 0xffd1), // F20
        (0x4c, '\u0003', false, 0, 0xff8d),
        (0x0c, 'a', false, 0, 0x61), // AZERTY: the Q position types a
        (0x0c, '', false, 0, 0x71),
        (0x12, '', false, 0, 0x31),
        (0x7f, '', false, 0, null),
      ],
      'ios': [
        (0xe3, '', false, 0, 0xffeb), // left GUI
        (0xe7, '', false, 0, 0xffec),
        (0xe0, '', false, 0, 0xffe3),
        (0xe2, '', false, 0, 0xffe9),
        (0x2b, '\t', false, 0, 0xff09),
        (0x29, '', false, 0, 0xff1b),
        (0x28, '\r', false, 0, 0xff0d),
        (0x2c, ' ', false, 0, 0x20),
        (0x46, '', false, 0, 0xff61),
        (0x65, '', false, 0, 0xff67),
        (0x3a, '', false, 0, 0xffbe),
        (0x45, '', false, 0, 0xffc9),
        (0x68, '', false, 0, 0xffca),
        (0x73, '', false, 0, 0xffd5),
        (0x4a, '', false, 0, 0xff50),
        (0x4d, '', false, 0, 0xff57),
        (0x4c, '', false, 0, 0xffff),
        (0x59, '', false, 0, 0xffb1),
        (0x62, '', false, 0, 0xffb0),
        (0x04, 'q', false, 0, 0x71),
        (0x04, '', false, 0, 0x61),
        (0x27, '', false, 0, 0x30),
        (0x1e, '', false, 0, 0x31),
        (0x01, '', false, 0, null),
      ],
      'android': [
        (117, '', false, 0, 0xffeb), // META_LEFT
        (118, '', false, 0, 0xffec),
        (113, '', false, 0, 0xffe3),
        (57, '', false, 0, 0xffe9),
        (59, '', false, 0, 0xffe1),
        (61, '', false, 0, 0xff09),
        (111, '', false, 0, 0xff1b),
        (62, ' ', false, 0, 0x20),
        (66, '', false, 0, 0xff0d),
        (67, '', false, 0, 0xff08),
        (112, '', false, 0, 0xffff),
        (120, '', false, 0, 0xff61), // SYSRQ
        (82, '', false, 0, 0xff67),
        (122, '', false, 0, 0xff50),
        (123, '', false, 0, 0xff57),
        (19, '', false, 0, 0xff52),
        (131, '', false, 0, 0xffbe),
        (142, '', false, 0, 0xffc9),
        (144, '', false, 0, 0xffb0),
        (29, '', false, 0, 0x61),
        (29, 'ф', false, 0, 0x01000444),
        (29, 'Ф', false, 0, 0x01000444),
        (7, '', false, 0, 0x30),
        (16, '', false, 0, 0x39),
        (3, '', false, 0, null), // HOME (the Android system key)
      ],
    };
    for (final MapEntry(key: platform, value: rows) in cases.entries) {
      test(platform, () {
        for (final (code, char, extended, scan, keysym) in rows) {
          expect(
            keyboardCaptureKeysym(
              platform: platform,
              code: code,
              char: char,
              extended: extended,
              scan: scan,
            ),
            keysym,
            reason: '$platform code 0x${code.toRadixString(16)} "$char"',
          );
        }
      });
    }
    test('unknown platform', () {
      expect(keyboardCaptureKeysym(platform: 'linux', code: 0x41), isNull);
    });
  });

  test('direct RDP sends captured keys as scancodes, never as characters', () {
    final scancodes = <int, int>{
      0xff61: 0x137, // Print Screen
      0xff67: 0x15d, // Menu
      0xff14: 0x46, // Scroll Lock
      0xffeb: 0x15b, // Super_L
      0xffca: 0x64, // F13
      0xffd4: 0x6e, // F23
      0xffd5: 0x76, // F24
      0xffb1: 0x4f, // keypad 1
      0xffaa: 0x37, // keypad *
      0xffaf: 0x135, // keypad /
      0x1008ff12: 0x120, // XF86AudioMute
      0x1008ff13: 0x130, // XF86AudioRaiseVolume
      0x1008ff14: 0x122, // XF86AudioPlay
      0x1008ff26: 0x16a, // XF86Back
      0x1008ff2f: 0x15f, // XF86Sleep
      0xff31: 0x72, // Hangul
      0xff34: 0x71, // Hangul_Hanja
      0xff27: 0x70, // Hiragana_Katakana
      0x61: 0x1e, // a
    };
    for (final MapEntry(key: keysym, value: scan) in scancodes.entries) {
      expect(rdpKeyEvents(keysym), [
        (scan, false),
      ], reason: '0x${keysym.toRadixString(16)}');
    }
    // Pause needs an E1 sequence the engine cannot send; unknown function,
    // dead and vendor keysyms are dropped instead of typed as characters.
    for (final keysym in [0xff13, 0xff6b, 0xfe50, 0x1008ff99, 0x10000041]) {
      expect(
        rdpKeyEvents(keysym),
        isEmpty,
        reason: '0x${keysym.toRadixString(16)}',
      );
    }
    // Characters without a scancode still type as Unicode.
    expect(rdpKeyEvents(0xe9), [(0xe9, true)]);
    expect(rdpKeyEvents(0x0100043e), [(0x43e, true)]);
    expect(rdpKeyEvents(0x0101f600), [(0xd83d, true), (0xde00, true)]);

    // Sweep every code each runner can report.
    final dropped = <int>{};
    for (final (platform, codes) in [
      ('windows', 0x100),
      ('macos', 0x80),
      ('ios', 0x100),
      ('android', 0x120),
    ]) {
      for (var code = 0; code < codes; code++) {
        for (final scan in [0, 0x29, 0x36, 0x70]) {
          for (final extended in [false, true]) {
            final keysym = keyboardCaptureKeysym(
              platform: platform,
              code: code,
              extended: extended,
              scan: scan,
            );
            if (keysym == null) continue;
            final events = rdpKeyEvents(keysym);
            final where =
                '$platform 0x${code.toRadixString(16)} -> '
                '0x${keysym.toRadixString(16)}';
            final character =
                (keysym >= 0x20 && keysym <= 0xff) || keysym >> 24 == 0x01;
            if (character) {
              expect(events, isNotEmpty, reason: where);
            } else {
              expect(events.where((event) => event.$2), isEmpty, reason: where);
              if (events.isEmpty) dropped.add(keysym);
            }
          }
        }
      }
    }
    expect(dropped, {0xff13}, reason: 'only Pause has no scancode');
  });

  test(
    'captured keys reach the armed view and are released on disarm',
    () async {
      _platform(TargetPlatform.windows);
      _Native().install();
      final capture = controller();
      final sent = _Sent();
      final target = capture.register(sent.call);
      // Not armed: a press racing with disarming is dropped, not misrouted.
      await _key('windows', 0x5b, down: true);
      await _key('windows', 0x5b, down: false);
      expect(sent.events, isEmpty);
      target.update(focused: true, hovered: true);
      await _key('windows', 0x5b, down: true);
      await _key('windows', 0x52, down: true, char: 'r');
      await _key('windows', 0x52, down: true, char: 'r'); // auto-repeat
      await _key('windows', 0x52, down: false, char: 'r');
      expect(sent.events, [
        (0xffeb, true),
        (0x72, true),
        (0x72, true),
        (0x72, false),
      ]);
      sent.events.clear();
      target.update(hovered: false);
      expect(sent.events, [(0xffeb, false)], reason: 'Win released remotely');
      // The runner's synthesized release after disarming is not sent twice.
      await _key('windows', 0x5b, down: false);
      expect(sent.events, [(0xffeb, false)]);
      sent.events.clear();
      target.update(hovered: true);
      await _key('windows', 0xa4, down: true);
      await _key('windows', 0x09, down: true, char: '\t');
      target.unregister();
      expect(sent.events, [
        (0xffe9, true),
        (0xff09, true),
        (0xffe9, false),
        (0xff09, false),
      ]);
      await _key('windows', 0x09, down: false);
      expect(sent.events, hasLength(4));
    },
  );

  test(
    'a released key whose press reached Flutter is still released',
    () async {
      _platform(TargetPlatform.android);
      _Native().install();
      final capture = controller();
      final sent = _Sent();
      capture.register(sent.call).update(focused: true);
      await _key('android', 59, down: false);
      expect(sent.events, [(0xffe1, false)]);
    },
  );

  test('main and keypad Enter are tracked separately', () async {
    _platform(TargetPlatform.windows);
    _Native().install();
    final capture = controller();
    final sent = _Sent();
    capture.register(sent.call).update(focused: true, hovered: true);
    await _key('windows', 0x0d, down: true, char: '\r');
    await _key('windows', 0x0d, down: true, char: '\r', extended: true);
    await _key('windows', 0x0d, down: false, char: '\r');
    await _key('windows', 0x0d, down: false, char: '\r', extended: true);
    expect(sent.events, [
      (0xff0d, true),
      (0xff8d, true),
      (0xff0d, false),
      (0xff8d, false),
    ]);
  });

  test('switching receivers releases keys on the previous session', () async {
    _platform(TargetPlatform.iOS);
    _Native().install();
    final capture = controller();
    final first = _Sent(), second = _Sent();
    final target = capture.register(first.call)..update(focused: true);
    await _key('ios', 0xe3, down: true);
    target.retarget(second.call);
    await _key('ios', 0x04, down: true, char: 'a');
    await _key('ios', 0x04, down: false, char: 'a');
    expect(first.events, [(0xffeb, true), (0xffeb, false)]);
    expect(second.events, [(0x61, true), (0x61, false)]);
  });

  test('Ctrl+Alt+End sends Delete and Ctrl+Alt+Home stays local', () async {
    _platform(TargetPlatform.windows);
    _Native().install();
    final capture = controller();
    final sent = _Sent();
    var menus = 0;
    final target = capture.register(sent.call, onMenuShortcut: () => menus++)
      ..update(focused: true, hovered: true);
    await _key('windows', 0xa2, down: true);
    await _key('windows', 0xa4, down: true);
    expect(target.controlAndAltHeld, isTrue);
    await _key('windows', 0x23, down: true, extended: true);
    await _key('windows', 0x23, down: true, extended: true); // repeat
    await _key('windows', 0x23, down: false, extended: true);
    expect(sent.events, [
      (0xffe3, true),
      (0xffe9, true),
      (0xffff, true),
      (0xffff, false),
    ]);
    sent.events.clear();
    await _key('windows', 0x24, down: true, extended: true);
    await _key('windows', 0x24, down: true, extended: true); // repeat
    await _key('windows', 0x24, down: false, extended: true);
    expect(menus, 1);
    expect(
      sent.events,
      unorderedEquals([(0xffe3, false), (0xffe9, false)]),
      reason: 'Home is never sent; held modifiers are released for the menu',
    );
    expect(target.controlAndAltHeld, isFalse);
  });

  test('a runner without the bridge is unsupported and never throws', () async {
    _platform(TargetPlatform.windows);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _channel,
          (call) async => throw MissingPluginException(),
        );
    final capture = controller();
    expect(capture.supported, isNull);
    final target = capture.register(_Sent().call);
    target.update(focused: true, hovered: true);
    await pumpEventQueue();
    expect(capture.supported, isFalse);
    target.update(hovered: false);
    await capture.refreshState();
    await capture.requestPermission();
    expect(capture.supported, isFalse);

    final failing = controller();
    final native = _Native()..install();
    native.error = PlatformException(code: 'capture');
    await failing.refreshState();
    expect(failing.supported, isFalse);
    native.error = null;
    await failing.refreshState();
    expect(failing.supported, isTrue);
  });

  test('state, permission and window focus come from the runner', () async {
    _platform(TargetPlatform.macOS);
    final native = _Native(permission: 'required', windowFocused: false)
      ..install();
    final capture = controller();
    var notifications = 0;
    capture.addListener(() => notifications++);
    await capture.refreshState();
    expect(capture.supported, isTrue);
    expect(capture.permission, KeyboardCapturePermission.required);
    expect(capture.nativeWindowFocused, isFalse);
    expect(notifications, greaterThan(0));
    native.permission = 'granted';
    await capture.requestPermission();
    expect(capture.permission, KeyboardCapturePermission.granted);
    expect(native.calls.map((call) => call.method), [
      'getState',
      'requestPermission',
    ]);
  });

  test('mode persists by name with the focused default', () async {
    final capture = controller();
    final store = MemoryKeyboardCaptureStore('unknown');
    await capture.load(store);
    expect(capture.mode, KeyboardCaptureMode.focused);
    final first = capture.select(KeyboardCaptureMode.off);
    final second = capture.select(KeyboardCaptureMode.fullscreen);
    await Future.wait([first, second]);
    expect(store.value, 'fullscreen');
    final loaded = controller();
    await loaded.load(store);
    expect(loaded.mode, KeyboardCaptureMode.fullscreen);

    final failing = controller();
    await failing.load(_FailingStore());
    await failing.select(KeyboardCaptureMode.off);
    expect(failing.mode, KeyboardCaptureMode.off);
    expect(failing.writeFailed, isTrue);
  });

  test('a focused window follows the mode another process chose', () async {
    _platform(TargetPlatform.windows);
    final native = _Native()..install();
    final capture = controller();
    final store = MemoryKeyboardCaptureStore();
    await capture.load(store);
    final target = capture.register(_Sent().call)
      ..update(focused: true, hovered: true);
    expect(target.armed, isTrue);
    var notifications = 0;
    capture.addListener(() => notifications++);
    store.value = 'off'; // Settings in the main window's process.
    await _fromNative('windowFocus', {'focused': false});
    await pumpEventQueue();
    expect(capture.mode, KeyboardCaptureMode.focused);
    await _fromNative('windowFocus', {'focused': true});
    await pumpEventQueue();
    expect(capture.mode, KeyboardCaptureMode.off);
    expect(target.armed, isFalse);
    expect(notifications, greaterThan(0));
    store.value = 'unknown';
    await _fromNative('windowFocus', {'focused': true});
    await pumpEventQueue();
    expect(capture.mode, KeyboardCaptureMode.off, reason: 'kept');
    store.value = 'focused';
    await _fromNative('windowFocus', {'focused': true});
    await pumpEventQueue();
    expect(target.armed, isTrue);
    expect(native.configured, [true, false, true]);
  });

  test('a choice made during a slow re-read is never overridden', () async {
    _platform(TargetPlatform.macOS);
    _Native().install();
    final capture = controller();
    final store = _SlowStore('focused');
    await capture.load(store);
    final read = store.hold();
    await _fromNative('windowFocus', {'focused': true});
    await pumpEventQueue();
    expect(store.reads, 2, reason: 'load, then the re-read');
    await capture.select(KeyboardCaptureMode.off);
    read.complete('fullscreen'); // Read before the newer choice was written.
    await pumpEventQueue();
    expect(capture.mode, KeyboardCaptureMode.off);
    expect(store.value, 'off');
    // The next focus reads this process's own choice back.
    await _fromNative('windowFocus', {'focused': true});
    await pumpEventQueue();
    expect(capture.mode, KeyboardCaptureMode.off);
  });

  test('device preference file round trip', () async {
    final directory = await Directory.systemTemp.createTemp(
      'keyboard-capture-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = FileKeyboardCaptureStore(directory: () async => directory);
    expect(await store.read(), isNull);
    await store.write('off');
    expect(
      await FileKeyboardCaptureStore(directory: () async => directory).read(),
      'off',
    );
    await store.write('focused');
    expect(await store.read(), 'focused');
    expect(await directory.list().length, 1);
  });

  group('DesktopView', () {
    Future<(DesktopSession, _KeyTarget)> connect(
      WidgetTester tester, {
      bool connected = true,
    }) async {
      final target = _KeyTarget();
      final session = DesktopSession(directConnectionForTesting: (_) => target);
      await session.connectLocal(
        HostRecord(
          id: 'capture',
          name: 'Capture',
          address: 'localhost',
          protocol: HostProtocol.vnc,
          manifest: const VncSettings(resolution: VncResolutionMode.fitWindow)
              .applyTo(null),
        ),
      );
      target.stream.add(DesktopReady());
      if (connected) session.state = 'connected';
      return (session, target);
    }

    Future<void> close(WidgetTester tester, DesktopSession session) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(session.close);
      session.dispose();
    }

    testWidgets('Ctrl+Alt+End sends Delete with Ctrl+Alt held', (tester) async {
      final capture = KeyboardCaptureController();
      KeyboardCaptureController.debugInstance = capture;
      addTearDown(() {
        KeyboardCaptureController.debugInstance = null;
        capture.dispose();
      });
      final (session, target) = await connect(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DesktopView(session: session)),
        ),
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.end);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.end);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.end);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(target.keys, [
        (0xffe3, true),
        (0xffe9, true),
        (0xffff, true),
        (0xffff, false),
        (0xffe9, false),
        (0xffe3, false),
      ]);
      target.keys.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      expect(target.keys, [(0xff57, true), (0xff57, false)]);
      await close(tester, session);
    });

    testWidgets('a repeat keeps the pressed keysym, so nothing stays held', (
      tester,
    ) async {
      final capture = KeyboardCaptureController();
      KeyboardCaptureController.debugInstance = capture;
      addTearDown(() {
        KeyboardCaptureController.debugInstance = null;
        capture.dispose();
      });
      final (session, target) = await connect(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DesktopView(session: session)),
        ),
      );
      await tester.pump();
      // Ctrl+Alt+End, then Ctrl and Alt are released while End repeats.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.end);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.end);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.end);
      expect(target.keys, [
        (0xffe3, true),
        (0xffe9, true),
        (0xffff, true),
        (0xffe9, false),
        (0xffe3, false),
        (0xffff, false),
      ]);
      target.keys.clear();
      // Modifiers pressed during a repeat do not change the repeated keysym.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(target.keys, [
        (0x61, true),
        (0xffe1, true),
        (0x61, true),
        (0x61, false),
        (0xffe1, false),
      ]);
      // A repeated Delete key still repeats Delete.
      target.keys.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.delete);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.delete);
      expect(target.keys, [(0xffff, true), (0xffff, true), (0xffff, false)]);
      await close(tester, session);
    });

    testWidgets('Windows arms under the pointer and releases on exit', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final native = _Native()..install();
        final capture = KeyboardCaptureController();
        KeyboardCaptureController.debugInstance = capture;
        addTearDown(() {
          KeyboardCaptureController.debugInstance = null;
          capture.dispose();
        });
        final (session, target) = await connect(tester);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  height: 300,
                  child: DesktopView(session: session),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(native.configured, isEmpty, reason: 'focused, no pointer');
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(200, 150));
        await tester.pump();
        expect(native.configured, [true]);
        await _key('windows', 0x5b, down: true);
        await _key('windows', 0x44, down: true, char: 'd');
        await _key('windows', 0x44, down: false, char: 'd');
        expect(target.keys, [(0xffeb, true), (0x64, true), (0x64, false)]);
        await mouse.moveTo(const Offset(700, 500));
        await tester.pump();
        expect(native.configured, [true, false]);
        expect(target.keys.last, (0xffeb, false));
        await mouse.removePointer();
        await close(tester, session);
        expect(native.configured, [true, false]);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  testWidgets('a captured press waits for modifiers Flutter delivers late', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      _Native().install();
      final capture = KeyboardCaptureController();
      KeyboardCaptureController.debugInstance = capture;
      addTearDown(() {
        KeyboardCaptureController.debugInstance = null;
        capture.dispose();
      });
      final target = _KeyTarget();
      final session = DesktopSession(directConnectionForTesting: (_) => target);
      await session.connectLocal(
        HostRecord(
          id: 'capture',
          name: 'Capture',
          address: 'localhost',
          protocol: HostProtocol.vnc,
          manifest: const VncSettings(resolution: VncResolutionMode.fitWindow)
              .applyTo(null),
        ),
      );
      target.stream.add(DesktopReady());
      session.state = 'connected';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                height: 300,
                child: DesktopView(session: session),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(200, 150));
      await tester.pump();
      expect(capture.armed, isTrue);
      const alt = 0xffe9, control = 0xffe3, shift = 0xffe1;
      const tab = 0xff09, escape = 0xff1b;

      // Alt+Tab while Flutter still holds Alt back: the captured Tab, and
      // the release queued behind it, wait until Alt reached the remote.
      await _key('windows', 0x09, down: true, char: '\t', modifiers: 4);
      await _key('windows', 0x09, down: false, char: '\t');
      expect(target.keys, isEmpty);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      expect(target.keys, [(alt, true), (tab, true), (tab, false)]);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      target.keys.clear();

      // Modifiers Flutter delivered already: no wait (Ctrl+Shift+Esc).
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _key('windows', 0x1b, down: true, modifiers: 3);
      await _key('windows', 0x1b, down: false);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(target.keys, [
        (control, true),
        (shift, true),
        (escape, true),
        (escape, false),
        (shift, false),
        (control, false),
      ]);
      target.keys.clear();

      // Only the missing modifier is waited for: Shift is there, Ctrl not.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _key('windows', 0x1b, down: true, modifiers: 3);
      expect(target.keys, [(shift, true)]);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlRight);
      await _key('windows', 0x1b, down: false);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(target.keys, [
        (shift, true),
        (0xffe4, true),
        (escape, true),
        (escape, false),
        (0xffe4, false),
        (shift, false),
      ]);
      target.keys.clear();

      // A modifier Flutter never delivers (pressed while another window was
      // active): the press goes out after a short wait, keys keep their order.
      await _key('windows', 0x1b, down: true, modifiers: 2);
      await _key('windows', 0x1b, down: false);
      await tester.pump(const Duration(milliseconds: 400));
      expect(target.keys, isEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      expect(target.keys, [(escape, true), (escape, false)]);
      target.keys.clear();

      // A modifier held through the capture itself counts as delivered.
      await _key('windows', 0x5b, down: true);
      await _key('windows', 0xa4, down: true);
      await _key('windows', 0x09, down: true, char: '\t', modifiers: 4);
      expect(target.keys, [(0xffeb, true), (alt, true), (tab, true)]);
      await _key('windows', 0x09, down: false, char: '\t');
      await _key('windows', 0xa4, down: false);
      await _key('windows', 0x5b, down: false);
      target.keys.clear();

      // A waiting press is still delivered, then released, when the pointer
      // leaves: nothing stays down remotely.
      await _key('windows', 0x09, down: true, char: '\t', modifiers: 4);
      expect(target.keys, isEmpty);
      await mouse.moveTo(const Offset(700, 500));
      await tester.pump();
      expect(capture.armed, isFalse);
      expect(target.keys, [(tab, true), (tab, false)]);
      await _key('windows', 0x09, down: false, char: '\t');
      expect(target.keys, hasLength(2));
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(session.close);
      session.dispose();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('disposing while a press waits drops it and its timer', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      _Native().install();
      final capture = KeyboardCaptureController();
      final sent = _Sent();
      capture.register(sent.call).update(focused: true, hovered: true);
      await _key('windows', 0x09, down: true, char: '\t', modifiers: 4);
      expect(sent.events, isEmpty);
      capture.dispose();
      // No pump: a timer still pending would fail the test when it ends.
      expect(sent.events, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a session that is not connected never takes the shortcuts', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final native = _Native()..install();
      final capture = KeyboardCaptureController();
      KeyboardCaptureController.debugInstance = capture;
      addTearDown(() {
        KeyboardCaptureController.debugInstance = null;
        capture.dispose();
      });
      final target = _KeyTarget();
      final session = DesktopSession(directConnectionForTesting: (_) => target);
      expect(session.state, isNot('connected'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DesktopView(session: session)),
        ),
      );
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(200, 150));
      await tester.pump();
      expect(capture.armed, isFalse);
      expect(native.configured, isEmpty);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final locale in ['en', 'zh', 'ja', 'ru']) {
    group(locale, () {
      useAppLocaleFixture(locale);
      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        testWidgets('390px ${platform.name} full keyboard mapping settings', (
          tester,
        ) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          debugDefaultTargetPlatformOverride = platform;
          try {
            // Android below 16 QPR2 (non-Samsung) has no capture mechanism.
            final supported = platform != TargetPlatform.android;
            final native = _Native(
              permission: platform == TargetPlatform.macOS
                  ? 'required'
                  : 'notRequired',
              supported: supported,
            )..install();
            final capture = KeyboardCaptureController();
            KeyboardCaptureController.debugInstance = capture;
            final keyboard = DesktopKeyboardController();
            DesktopKeyboardController.debugInstance = keyboard;
            addTearDown(() {
              KeyboardCaptureController.debugInstance = null;
              DesktopKeyboardController.debugInstance = null;
              capture.dispose();
              keyboard.dispose();
            });
            final store = MemoryKeyboardCaptureStore();
            await capture.load(store);
            await keyboard.load(MemoryDesktopKeyboardStore());
            await tester.pumpWidget(
              const MaterialApp(
                home: Scaffold(
                  body: SingleChildScrollView(
                    padding: EdgeInsets.all(16),
                    child: DesktopKeyboardSettings(),
                  ),
                ),
              ),
            );
            await tester.pump();
            final l10n = currentL10n;
            final mobile =
                platform == TargetPlatform.android ||
                platform == TargetPlatform.iOS;
            expect(
              find.byKey(const ValueKey('desktop_keyboard_mode')),
              mobile ? findsOneWidget : findsNothing,
            );
            expect(
              find.text(l10n.keyboardCaptureCtrlAltDelete),
              findsOneWidget,
            );
            final descriptions = {
              TargetPlatform.windows: l10n.keyboardCaptureWindowsDescription,
              TargetPlatform.macOS: l10n.keyboardCaptureMacDescription,
              TargetPlatform.android: l10n.keyboardCaptureAndroidDescription,
              TargetPlatform.iOS: l10n.keyboardCaptureIosDescription,
            };
            expect(descriptions.values.toSet(), hasLength(4));
            for (final MapEntry(key: shown, value: text)
                in descriptions.entries) {
              expect(
                find.text(text),
                shown == platform ? findsOneWidget : findsNothing,
                reason: shown.name,
              );
            }
            expect(
              find.text(l10n.keyboardCaptureUnsupported),
              supported ? findsNothing : findsOneWidget,
            );
            final permission = find.byKey(
              const ValueKey('keyboard_capture_permission'),
            );
            if (platform == TargetPlatform.macOS) {
              expect(
                find.text(l10n.keyboardCapturePermissionRequired),
                findsOneWidget,
              );
              await tester.tap(permission);
              await tester.pump();
              expect(native.calls.last.method, 'requestPermission');
            } else {
              expect(permission, findsNothing);
            }
            await tester.tap(
              find.byKey(const ValueKey('keyboard_capture_mode')),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text(l10n.keyboardCaptureOff).last);
            await tester.pumpAndSettle();
            expect(capture.mode, KeyboardCaptureMode.off);
            expect(store.value, 'off');
            await tester.tap(
              find.byKey(const ValueKey('keyboard_capture_mode')),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text(l10n.keyboardCaptureFullscreen).last);
            await tester.pumpAndSettle();
            expect(store.value, 'fullscreen');
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });
      }
    });
  }
}
