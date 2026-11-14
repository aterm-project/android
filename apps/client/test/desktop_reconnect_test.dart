import 'dart:async';
import 'dart:typed_data';

import 'package:aterm_client/desktop/desktop_display.dart';
import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/desktop/rdp_features.dart';
import 'package:aterm_client/desktop/rdp_local_drives.dart';
import 'package:aterm_client/desktop/rdp_settings.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/rdp_local_volumes_fake.dart';

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

  group('reconnect uses the latest saved Host', () {
    const features = RdpFeatures(RdpFeatures.configV1 | RdpFeatures.drive);
    const v1 = HostRecord(
      id: 'win',
      name: 'Win',
      address: 'win.example',
      protocol: HostProtocol.rdp,
    );
    final v2 = v1.copyWith(
      manifest: const RdpSettings(
        drives: [RdpDriveRedirect(name: 'Work', path: '/srv/work')],
      ).applyTo(null),
    );

    Future<(DesktopSession, List<_Connection>, List<HostRecord>)> open({
      HostRecord? Function(String id)? latestHost,
      RdpLocalDrivesController? localDrives,
    }) async {
      final connections = <_Connection>[];
      final connected = <HostRecord>[];
      final session = DesktopSession(
        latestHost: latestHost,
        localDrives:
            localDrives ??
            await fakeLocalDrives(
              FakeLocalVolumes(os: null, windowsPaths: false),
            ),
        directConnectionForTesting: (host) {
          connected.add(host);
          final c = _Connection();
          connections.add(c);
          return c;
        },
      )..rdpFeaturesForTesting = features;
      addTearDown(() async {
        await session.close();
        session.dispose();
      });
      await session.connectLocal(v1);
      return (session, connections, connected);
    }

    Future<void> drop(DesktopSession session, _Connection connection) async {
      connection.controller.addError(StateError('Disconnected'));
      await Future<void>.delayed(Duration.zero);
      expect(session.state, 'disconnected');
    }

    test('a mapping saved after the first connect applies on reconnect '
        '(AppController and local profile pass the Host)', () async {
      final (session, connections, connected) = await open();
      expect(session.rdpConfig!.text, isNot(contains('drive=')));
      // An in-session display choice of the same Host carries over.
      await session.changeResolution(width: 1024, height: 768);
      await drop(session, connections.single);
      await session.reconnect(host: v2);
      expect(connected.map((h) => h.manifest), [null, v2.manifest]);
      expect(session.rdpConfig!.text, contains('\ndrive=Work|/srv/work\n'));
      expect(session.rdpSettings.resolution, RdpResolutionMode.fixed);
      expect(session.rdpSettings.width, 1024);
      expect(session.rdpSettings.drives.single.name, 'Work');
    });

    test('Restore connection resolves the saved Host itself', () async {
      var saved = v1;
      final (session, connections, _) = await open(
        latestHost: (id) => id == v1.id ? saved : null,
      );
      saved = v2;
      await drop(session, connections.single);
      // The view's button calls reconnect() without a Host.
      await session.reconnect();
      expect(session.rdpConfig!.text, contains('\ndrive=Work|/srv/work\n'));
    });

    test('another Host or a terminal revision never replaces the session Host',
        () async {
      final (session, connections, connected) = await open();
      await drop(session, connections.single);
      await session.reconnect(
        host: HostRecord(
          id: 'other',
          name: 'Other',
          address: 'other.example',
          protocol: HostProtocol.rdp,
          manifest: v2.manifest,
        ),
      );
      expect(connected.last.id, v1.id);
      expect(session.rdpConfig!.text, isNot(contains('drive=')));
      await drop(session, connections.last);
      await session.reconnect(
        host: v2.copyWith(protocol: HostProtocol.ssh, port: 22),
      );
      expect(connected.last.protocol, HostProtocol.rdp);
    });

    test('turning the device-local switch off applies on reconnect', () async {
      final local = await fakeLocalDrives(
        FakeLocalVolumes(volumes: const [windowsC, windowsE]),
      );
      final (session, connections, _) = await open(localDrives: local);
      expect(session.rdpConfig!.text, contains('\ndrive=C|C:\\\n'));
      expect(session.rdpConfig!.text, contains('\ndrive=E|E:\\\n'));
      await local.setEnabled(v1.id, false);
      await drop(session, connections.single);
      await session.reconnect();
      expect(session.rdpConfig!.text, isNot(contains('drive=')));
      await local.setEnabled(v1.id, true);
      await drop(session, connections.last);
      await session.reconnect();
      expect(session.rdpConfig!.text, contains('\ndrive=C|C:\\\n'));
      // Local disks never enter the Host's settings (saved back to the Host).
      expect(session.rdpSettings.drives, isEmpty);
    });
  });
}
