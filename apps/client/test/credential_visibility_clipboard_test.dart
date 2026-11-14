// SensitiveClipboard: secrets copied from the escrow recovery dialog and the
// admin credential viewer leave the clipboard again. Timers run in the
// testWidgets fake-async zone.
import 'package:aterm_client/credential_visibility/sensitive_clipboard.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeClipboard {
  String? text;
  bool readable = true;
  bool failWrites = false;
  int reads = 0;
  final writes = <String>[];

  SensitiveClipboard create({bool readBack = true}) => SensitiveClipboard(
    readBack: readBack,
    write: (value) async {
      if (failWrites) throw PlatformException(code: 'clipboard');
      writes.add(value);
      text = value;
    },
    read: () async {
      reads++;
      return readable ? text : null;
    },
  );
}

void main() {
  const minute = Duration(minutes: 1);

  testWidgets('clears the copied value after a minute', (tester) async {
    final fake = _FakeClipboard();
    final clipboard = fake.create();
    await clipboard.copy('SENTINEL-PW');
    expect(fake.text, 'SENTINEL-PW');
    expect(clipboard.holdsValue, isTrue);
    await tester.pump(minute - const Duration(seconds: 1));
    expect(fake.text, 'SENTINEL-PW');
    await tester.pump(const Duration(seconds: 1));
    expect(fake.text, '');
    expect(clipboard.holdsValue, isFalse);
    clipboard.dispose();
  });

  testWidgets('never wipes something copied afterwards', (tester) async {
    final fake = _FakeClipboard();
    final clipboard = fake.create();
    await clipboard.copy('SENTINEL-PW');
    fake.text = 'copied by the user later';
    await tester.pump(minute);
    expect(fake.text, 'copied by the user later');
    expect(fake.writes, ['SENTINEL-PW']);
    clipboard.dispose();
  });

  testWidgets('a new copy restarts the timer and replaces the value', (
    tester,
  ) async {
    final fake = _FakeClipboard();
    final clipboard = fake.create();
    await clipboard.copy('first');
    await tester.pump(const Duration(seconds: 40));
    await clipboard.copy('second');
    await tester.pump(const Duration(seconds: 40));
    expect(fake.text, 'second');
    await tester.pump(const Duration(seconds: 20));
    expect(fake.text, '');
    clipboard.dispose();
  });

  testWidgets('an unreadable clipboard is retried, not given up', (
    tester,
  ) async {
    final fake = _FakeClipboard()..readable = false;
    final clipboard = fake.create();
    await clipboard.copy('SENTINEL-PW');
    // Android refuses background reads: nothing is decided yet.
    await tester.pump(minute);
    expect(fake.text, 'SENTINEL-PW');
    expect(clipboard.holdsValue, isTrue);
    // Back in the foreground the next attempt clears it.
    fake.readable = true;
    await tester.pump(minute);
    expect(fake.text, '');
    expect(clipboard.holdsValue, isFalse);
    clipboard.dispose();
  });

  testWidgets('dispose clears at once and stops every timer', (tester) async {
    final fake = _FakeClipboard();
    final clipboard = fake.create();
    await clipboard.copy('RECOVERY-CODE');
    clipboard.dispose();
    await tester.pump();
    expect(fake.text, '');
    // Disposed: no further copies, nothing scheduled (the test would fail
    // on a pending timer).
    await clipboard.copy('late');
    expect(fake.text, '');
  });

  testWidgets('without read-back the value is cleared without reading', (
    tester,
  ) async {
    final fake = _FakeClipboard();
    final clipboard = fake.create(readBack: false);
    await clipboard.copy('SENTINEL-PW');
    await tester.pump(minute);
    expect(fake.text, '');
    expect(fake.reads, 0, reason: 'reading would prompt on iOS/macOS/web');
    clipboard.dispose();
  });

  testWidgets('clipboard failures never throw from clear', (tester) async {
    final fake = _FakeClipboard();
    final clipboard = fake.create();
    await clipboard.copy('SENTINEL-PW');
    fake.failWrites = true;
    await clipboard.clear();
    await tester.pump(minute);
    expect(clipboard.holdsValue, isFalse);
    clipboard.dispose();
  });

  testWidgets('the default uses the platform clipboard channel', (
    tester,
  ) async {
    String? platformText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            platformText = (call.arguments as Map)['text'] as String?;
            return null;
          case 'Clipboard.getData':
            return platformText == null ? null : {'text': platformText};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final clipboard = SensitiveClipboard();
    await clipboard.copy('SENTINEL-PW');
    expect(platformText, 'SENTINEL-PW');
    clipboard.dispose();
    await tester.pump();
    expect(platformText, '');
  });
}
