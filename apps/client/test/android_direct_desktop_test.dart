import 'dart:async';
import 'dart:io';

import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/direct/rdp_io.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/l10n_fixture.dart';

// Android has no local guacd. Remote desktops there connect to the Host
// directly (VNC: pure-Dart RFB, RDP: the engine packaged in the APK) and must
// never dial 127.0.0.1:4822.

const rdpHost = HostRecord(
  id: '22222222-2222-4222-8222-222222222222',
  name: 'RDP',
  address: '127.0.0.1',
  port: 3389,
  protocol: HostProtocol.rdp,
);

/// A listener on the guacd port that records dials. Null when the port is
/// already taken on this machine.
Future<(ServerSocket, List<Socket>)?> _guacdWatch() async {
  try {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 4822);
    final dials = <Socket>[];
    server.listen((socket) {
      dials.add(socket);
      // Drain what the client sends so a hang-up is a clean FIN, not a reset.
      socket.listen((_) {}, onError: (_) {});
    });
    return (server, dials);
  } on SocketException {
    return null;
  }
}

void main() {
  useAppLocaleFixture('en');
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  final engineOverride = Platform.environment.containsKey(
    'ATERMIUS_RDP_LIBRARY',
  );

  test('Android RDP without a packaged engine fails plainly and never dials local guacd', () async {
    expect(bundledRdpAvailable, isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final guacd = await _guacdWatch();
    addTearDown(() async => guacd?.$1.close());
    final session = DesktopSession();
    await session.connectLocal(rdpHost);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(session.state, 'disconnected');
    expect(session.error, currentL10n.couldntStartTheRdpEngineCheck);
    expect(session.error, isNot(currentL10n.couldntConnectToTheLocalGuacd));
    expect(session.isDirect, isFalse);
    if (guacd != null) expect(guacd.$2, isEmpty);
    await session.close();
  }, skip: engineOverride ? 'ATERMIUS_RDP_LIBRARY provides an engine' : false);

  test(
    'Linux without an engine keeps its existing local gateway path',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final guacd = await _guacdWatch();
      if (guacd == null) {
        markTestSkipped('127.0.0.1:4822 is in use on this machine');
        return;
      }
      addTearDown(() async => guacd.$1.close());
      final session = DesktopSession();
      unawaited(session.connectLocal(rdpHost));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (guacd.$2.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(guacd.$2, hasLength(1));
      // The fake gateway hangs up; the session reports it and stops.
      for (final socket in guacd.$2) {
        await socket.close();
      }
      final closedBy = DateTime.now().add(const Duration(seconds: 20));
      while (session.state != 'disconnected' &&
          DateTime.now().isBefore(closedBy)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(session.state, 'disconnected');
      await session.close();
    },
    skip: engineOverride ? 'ATERMIUS_RDP_LIBRARY provides an engine' : false,
  );

  test(
    'Android VNC dials the Host address directly without a gateway',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(DesktopSession.supportsDirect(HostProtocol.vnc), isTrue);
      final guacd = await _guacdWatch();
      addTearDown(() async => guacd?.$1.close());
      final target = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(target.close);
      final accepted = target.first;
      final session = DesktopSession();
      final host = HostRecord(
        id: '33333333-3333-4333-8333-333333333333',
        name: 'VNC',
        address: '127.0.0.1',
        port: target.port,
        protocol: HostProtocol.vnc,
      );
      await session.connectLocal(host);
      final socket = await accepted.timeout(const Duration(seconds: 5));
      addTearDown(socket.destroy);
      expect(session.isDirect, isTrue);
      // The RFB greeting reaches the client unmodified (no gateway framing).
      final greeting = Completer<List<int>>();
      socket.listen((data) {
        if (!greeting.isCompleted) greeting.complete(data);
      });
      socket.add('RFB 003.008\n'.codeUnits);
      expect(
        await greeting.future.timeout(const Duration(seconds: 5)),
        'RFB 003.008\n'.codeUnits,
      );
      if (guacd != null) expect(guacd.$2, isEmpty);
      await session.close();
    },
  );
}
