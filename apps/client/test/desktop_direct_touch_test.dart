import 'dart:ui';

import 'package:aterm_client/desktop/desktop_direct_touch.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native RDP sends distinct bounded contacts, final position and cancel',
    () {
      final touch = DesktopDirectTouch();
      final contacts = <(int, int, Offset)>[];
      final mouse = <int>[];
      void send(PointerEvent e) => touch.handle(
        e,
        remotePoint: e.position / 2,
        nativeTouch: true,
        sendNative: (id, phase, p) => contacts.add((id, phase, p)),
        sendMouse: (_, buttons) => mouse.add(buttons),
      );
      send(const PointerDownEvent(pointer: 40, position: Offset(100, 100)));
      send(const PointerDownEvent(pointer: 90, position: Offset(200, 100)));
      send(const PointerMoveEvent(pointer: 40, position: Offset(100, 200)));
      send(const PointerUpEvent(pointer: 40, position: Offset(110, 210)));
      touch.reset();
      expect(contacts, [
        (1, 0, const Offset(50, 50)),
        (2, 0, const Offset(100, 50)),
        (1, 1, const Offset(50, 100)),
        (1, 2, const Offset(55, 105)),
        (2, 3, const Offset(100, 50)),
      ]);
      expect(mouse, isEmpty);
      touch.reset();
      expect(contacts, hasLength(5));
      for (int i = 1; i <= 11; i++) send(PointerDownEvent(pointer: i));
      expect(contacts.skip(5), hasLength(10));
      touch.reset();
      expect(contacts.skip(15).map((c) => c.$2), everyElement(3));
    },
  );

  testWidgets(
    'VNC direct mode supports tap, drag and natural two-finger scroll',
    (tester) async {
      final touch = DesktopDirectTouch();
      final packets = <(Offset, int)>[];
      void send(PointerEvent e) => touch.handle(
        e,
        remotePoint: e.position,
        nativeTouch: false,
        sendNative: (_, _, _) => fail('no native VNC contacts'),
        sendMouse: (p, b) => packets.add((p, b)),
      );
      send(const PointerDownEvent(pointer: 1, position: Offset(100, 100)));
      send(const PointerUpEvent(pointer: 1, position: Offset(100, 100)));
      expect(packets.map((p) => p.$2), [0, 1, 0]);
      packets.clear();
      send(const PointerDownEvent(pointer: 2, position: Offset(100, 100)));
      send(
        const PointerMoveEvent(
          pointer: 2,
          position: Offset(100, 150),
          delta: Offset(0, 50),
        ),
      );
      send(const PointerUpEvent(pointer: 2, position: Offset(100, 150)));
      expect(packets.map((p) => p.$2), [0, 1, 1, 0]);
      packets.clear();
      send(const PointerDownEvent(pointer: 3, position: Offset(100, 100)));
      send(const PointerDownEvent(pointer: 4, position: Offset(150, 100)));
      send(
        const PointerMoveEvent(
          pointer: 3,
          position: Offset(100, 40),
          delta: Offset(0, -60),
        ),
      );
      send(
        const PointerMoveEvent(
          pointer: 4,
          position: Offset(150, 40),
          delta: Offset(0, -60),
        ),
      );
      send(const PointerUpEvent(pointer: 3, position: Offset(100, 40)));
      send(const PointerUpEvent(pointer: 4, position: Offset(150, 40)));
      expect(packets.map((p) => p.$2), [0, 16, 0, 16, 0, 16, 0]);
      packets.clear();
      send(const PointerDownEvent(pointer: 5, position: Offset(70, 90)));
      await tester.pump(kLongPressTimeout);
      send(const PointerUpEvent(pointer: 5, position: Offset(70, 90)));
      expect(packets.map((p) => p.$2), [0, 4, 0]);
      touch.reset();
    },
  );

  test('replacement cancels the session that started the gesture', () {
    final touch = DesktopDirectTouch();
    final old = <int>[], replacement = <int>[];
    touch.handle(
      const PointerDownEvent(pointer: 1),
      remotePoint: Offset.zero,
      nativeTouch: true,
      sendNative: (_, phase, _) => old.add(phase),
      sendMouse: (_, _) {},
    );
    touch.reset();
    touch.handle(
      const PointerMoveEvent(pointer: 1),
      remotePoint: Offset.zero,
      nativeTouch: true,
      sendNative: (_, phase, _) => replacement.add(phase),
      sendMouse: (_, _) {},
    );
    expect(old, [0, 3]);
    expect(replacement, isEmpty);
  });
}
