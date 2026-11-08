import 'dart:async';

import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/desktop_view.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/l10n_fixture.dart';
import 'package:aterm_client/l10n/l10n.dart';

final pinA = 'a' * 64, pinB = 'b' * 64;
const host = HostRecord(
  id: '11111111-1111-4111-8111-111111111111',
  name: 'RDP',
  address: 'example.test',
  port: 3389,
  protocol: HostProtocol.rdp,
);

class FakeDesktop implements DirectDesktopConnection {
  final stream = StreamController<DesktopEvent>();
  @override
  Stream<DesktopEvent> get events => stream.stream;
  @override
  Future<void> close() async {
    if (!stream.isClosed) await stream.close();
  }

  @override
  void send(List<Object> command) {}
  @override
  void paste(String text) {}
}

void main() {
  useAppLocaleFixture('zh');
  testWidgets(
    'unknown certificate prompts, saves before retry, and changed pin prompts again',
    (tester) async {
      final connections = <FakeDesktop>[], attempts = <HostRecord>[];
      final saved = Completer<HostRecord>();
      var saves = 0;
      final session = DesktopSession(
        directConnectionForTesting: (h) {
          attempts.add(h);
          final c = FakeDesktop();
          connections.add(c);
          return c;
        },
        saveRdpCertificate: (h, pin) {
          saves++;
          if (saves == 1) {
            expect(pin, pinA);
            return saved.future;
          }
          expect(pin, pinB);
          return Future.value(h.copyWith(rdpCertificateSha256: pin));
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DesktopView(session: session)),
        ),
      );
      await session.connectLocal(host);
      connections.single.stream.addError(RdpCertificateException(pinA));
      unawaited(connections.single.stream.close());
      await tester.pumpAndSettle();
      expect(find.text(currentL10n.trustThisRdpCertificate), findsOneWidget);
      expect(session.state, 'certificate');
      await tester.tap(find.byKey(const ValueKey('rdp_certificate_accept')));
      await tester.pump();
      expect(saves, 1);
      expect(attempts.length, 1);
      await tester.runAsync(() async {
        saved.complete(host.copyWith(rdpCertificateSha256: pinA));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        attempts.length,
        2,
        reason:
            "${session.state}: ${session.error}; saving=${session.savingCertificate}",
      );
      expect(attempts.last.rdpCertificateSha256, pinA);
      connections.last.stream.addError(RdpCertificateException(pinB));
      await tester.pumpAndSettle();
      expect(find.text(currentL10n.rdpCertificateFingerprintChanged), findsOneWidget);
      expect(find.text(pinA), findsOneWidget);
      expect(find.text(pinB), findsOneWidget);
      await tester.tap(find.text(currentL10n.updateAndConnect));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(saves, 2);
      expect(attempts.length, 3);
      expect(attempts.last.rdpCertificateSha256, pinB);
      connections.last.stream.addError(RdpCertificateException('c' * 64));
      await tester.pumpAndSettle();
      await tester.tap(find.text(currentL10n.cancel));
      await tester.pumpAndSettle();
      expect(session.state, 'disconnected');
      expect(attempts.length, 3);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      session.dispose();
    },
  );
  testWidgets(
    'failed save keeps dialog and connection blocked; closing pane removes prompt',
    (tester) async {
      final connection = FakeDesktop();
      var attempts = 0;
      final session = DesktopSession(
        directConnectionForTesting: (_) {
          attempts++;
          return connection;
        },
        saveRdpCertificate: (_, _) async => throw StateError('conflict'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DesktopView(session: session)),
        ),
      );
      await session.connectLocal(host);
      connection.stream.addError(RdpCertificateException(pinA));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rdp_certificate_accept')));
      await tester.pumpAndSettle();
      expect(find.textContaining('证书未能保存'), findsOneWidget);
      expect(attempts, 1);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox())),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('rdp_certificate_dialog')),
        findsNothing,
      );
      session.dispose();
    },
  );
  test('closing while save is pending prevents reconnection', () async {
    final connection = FakeDesktop();
    final saved = Completer<HostRecord>();
    var attempts = 0;
    final session = DesktopSession(
      directConnectionForTesting: (_) {
        attempts++;
        return connection;
      },
      saveRdpCertificate: (_, _) => saved.future,
    );
    await session.connectLocal(host);
    connection.stream.addError(RdpCertificateException(pinA));
    await Future<void>.delayed(Duration.zero);
    final approval = session.trustCertificate(session.certificateRequest!);
    await session.close();
    saved.complete(host.copyWith(rdpCertificateSha256: pinA));
    expect(await approval, isFalse);
    expect(attempts, 1);
    session.dispose();
  });
}
