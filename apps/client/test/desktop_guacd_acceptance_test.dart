// Opt in with --dart-define=DESKTOP_TARGET=<isolated fixture IP>
// --dart-define=GUACD_PORT=<loopback gateway port>. No public network targets.
// The fixture uses an xterm-backed VNC display and xrdp with na/na autorun.
// Set VNC_PORT (default 5900) and RDP_FINGERPRINT (64 hex SHA-256 digits).
// DESKTOP_SCREENSHOT_DIR optionally saves each protocol's final PNG.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const target = String.fromEnvironment('DESKTOP_TARGET');
  const port = int.fromEnvironment('GUACD_PORT');
  for (final protocol in [HostProtocol.vnc, HostProtocol.rdp]) {
    test(
      'real guacd ${protocol.label} draws desktop and receives keyboard',
      () async {
        final session = DesktopSession(
          onErrorForTesting: (error) {
            print(error);
          },
        );
        addTearDown(session.dispose);
        final connected = Completer<void>();
        session.addListener(() {
          if (connected.isCompleted) return;
          if (session.state == 'connected')
            connected.complete();
          else if (session.error != null)
            connected.completeError(StateError(session.error!));
        });
        await session.connectLocal(
          HostRecord(
            id: 'test',
            name: 'Test',
            username: protocol == HostProtocol.rdp ? 'na' : '',
            login: protocol == HostProtocol.rdp
                ? const HostLogin(kind: AuthKind.password, password: 'na')
                : null,
            address: target,
            protocol: protocol,
            rdpCertificateSha256: protocol == HostProtocol.rdp
                ? const String.fromEnvironment('RDP_FINGERPRINT')
                : null,
            port: protocol == HostProtocol.vnc
                ? const int.fromEnvironment('VNC_PORT', defaultValue: 5900)
                : 3389,
          ),
          guacdPort: port,
        );
        await connected.future.timeout(const Duration(seconds: 30));
        expect(session.display.size.width, greaterThan(320));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final first =
            (await session.display
                    .layer(0)
                    .image!
                    .toByteData(format: ui.ImageByteFormat.png))!
                .buffer
                .asUint8List();
        expect(first.length, greaterThan(100));
        // Clicking the xterm window focuses it. A unique command produces a
        // fixture-only file, independently proving actual remote keyboard input.
        session.send(['mouse', 100, 100, 1]);
        session.send(['mouse', 100, 100, 0]);
        final marker = 'aterm_${protocol.name}_acceptance';
        final command = 'printf $marker > /tmp/$marker';
        for (final rune in command.runes) {
          session.send(['key', rune, 1]);
          session.send(['key', rune, 0]);
        }
        session.send(['key', 0xff0d, 1]);
        session.send(['key', 0xff0d, 0]);
        await Future<void>.delayed(const Duration(seconds: 2));
        final second =
            (await session.display
                    .layer(0)
                    .image!
                    .toByteData(format: ui.ImageByteFormat.png))!
                .buffer
                .asUint8List();
        expect(second, isNot(equals(first)));
        final out = Platform.environment['DESKTOP_SCREENSHOT_DIR'];
        if (out != null)
          await File('$out/${protocol.name}.png').writeAsBytes(second);
        await session.close();
      },
      skip: target.isEmpty || port == 0,
      timeout: const Timeout(Duration(seconds: 45)),
    );
  }
}
