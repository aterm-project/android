import 'dart:async';
import 'dart:typed_data';

import 'package:aterm_client/desktop/desktop_display.dart';
import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _Connection implements DirectDesktopConnection {
  final controller = StreamController<DesktopEvent>();
  int closed = 0;
  @override
  Stream<DesktopEvent> get events => controller.stream;
  @override
  Future<void> close() async {
    closed++;
    if (!controller.isClosed) await controller.close();
  }

  @override
  void send(List<Object> command) {}
  @override
  void paste(String text) {}
}

class _HeldDisplay extends DesktopDisplay {
  final completing = Completer<void>();
  @override
  Future<void> frame(
    int width,
    int height,
    Uint8List bgra, {
    int x = 0,
    int y = 0,
    int? regionWidth,
    int? regionHeight,
  }) => completing.future;
}

class _HeldSession extends DesktopSession {
  _HeldSession(DirectDesktopConnection Function(HostRecord) connector)
    : super(directConnectionForTesting: connector);
  @override
  final _HeldDisplay display = _HeldDisplay();
}

void main() {
  for (final fail in [false, true]) {
    test(
      'late frame from a previous attempt cannot change restored state (failure=$fail)',
      () async {
        final connections = <_Connection>[];
        final session = _HeldSession((_) {
          final c = _Connection();
          connections.add(c);
          return c;
        });
        try {
          await session.connectLocal(
            const HostRecord(
              id: 'owned',
              name: 'Owned',
              address: 'localhost',
              protocol: HostProtocol.vnc,
            ),
          );
          connections.single.controller.add(DesktopFrame(1, 1, Uint8List(4)));
          await Future<void>.delayed(Duration.zero);
          connections.single.controller.addError(StateError('Disconnected'));
          await Future<void>.delayed(Duration.zero);
          await session.reconnect();
          if (fail) {
            session.display.completing.completeError(
              const FormatException('Old image'),
            );
          } else {
            session.display.completing.complete();
          }
          await Future<void>.delayed(Duration.zero);
          expect(session.state, 'connecting');
          expect(session.error, isNull);
        } finally {
          await session.close();
          session.dispose();
        }
      },
    );
  }
  for (final protocol in [HostProtocol.rdp, HostProtocol.vnc]) {
    test(
      '$protocol restores its session after the previous transport has closed',
      () async {
        final connections = <_Connection>[];
        final session = DesktopSession(
          directConnectionForTesting: (_) {
            final c = _Connection();
            connections.add(c);
            return c;
          },
        );
        try {
          await session.connectLocal(
            HostRecord(
              id: 'owned',
              name: 'Owned',
              address: 'localhost',
              protocol: protocol,
            ),
          );
          connections.single.controller.addError(StateError('Disconnected'));
          await Future<void>.delayed(Duration.zero);
          expect(session.state, 'disconnected');
          await session.reconnect();
          expect(connections, hasLength(2));
          expect(connections.first.closed, 1);
          expect(session.state, 'connecting');
          expect(session.error, isNull);
        } finally {
          await session.close();
          session.dispose();
        }
      },
    );
  }
  test(
    'scope removal and disposal prohibit reopening a desktop connection',
    () async {
      var current = true, attempts = 0;
      final c = _Connection();
      final session = DesktopSession(
        reconnectAllowed: () => current,
        directConnectionForTesting: (_) {
          attempts++;
          return c;
        },
      );
      await session.connectLocal(
        const HostRecord(
          id: 'owned',
          name: 'Owned',
          address: 'localhost',
          protocol: HostProtocol.vnc,
        ),
      );
      c.controller.addError(StateError('Disconnected'));
      await Future<void>.delayed(Duration.zero);
      current = false;
      await session.reconnect();
      expect(attempts, 1);
      await session.close();
      session.dispose();
      current = true;
      await session.reconnect();
      expect(attempts, 1);
    },
  );
}
