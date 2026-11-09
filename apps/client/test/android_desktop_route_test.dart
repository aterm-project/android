import 'dart:io';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/l10n_fixture.dart';

// Route selection for remote desktops in a signed-in (cloud) workspace.
// Android is direct-only: RDP must never be handed to the server desktop
// gateway (or a local guacd) because the APK lacks an engine.

const _rdp = HostRecord(
  id: '44444444-4444-4444-8444-444444444444',
  name: 'RDP',
  address: '192.0.2.10',
  port: 3389,
  protocol: HostProtocol.rdp,
);

class _RecordingRelayApi extends ApiClient {
  _RecordingRelayApi() : super(baseUrl: 'https://relay.example.test/tenant');

  final targets = <(String, int)>[];

  @override
  Future<RelayTicket> createRelayTicket({
    required String deviceId,
    required String targetHost,
    required int targetPort,
  }) async {
    targets.add((targetHost, targetPort));
    throw StateError('test relay is offline');
  }
}

Future<AppController> _workspace(ApiClient api) async {
  final sodium = await SodiumSumoInit.init();
  final identity = DeviceIdentity.create(sodium);
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  addTearDown(database.close);
  return AppController(
      sodium: sodium,
      database: database,
      secureStore: ClientSecureStore(),
    )
    ..api = api
    ..session = AuthSession(
      accountId: 'account-test',
      accessToken: 'access-test',
      expiresIn: 3600,
      refreshToken: 'refresh-test',
      deviceId: identity.deviceId,
      vaults: const [],
    )
    ..identity = identity
    ..stage = ClientStage.workspace;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useAppLocaleFixture('en');
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  final engineOverride = Platform.environment.containsKey(
    'ATERMIUS_RDP_LIBRARY',
  );

  test(
    'Android routes RDP directly; no engine is reported, never a gateway',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(DesktopSession.supportsDirect(HostProtocol.rdp), isTrue);
      expect(DesktopSession.supportsDirect(HostProtocol.vnc), isTrue);
      final api = _RecordingRelayApi();
      final app = await _workspace(api);
      await app.openTerminalTab(_rdp);
      final tab = app.terminalTabs.single;
      expect(api.targets, isEmpty, reason: 'server desktop gateway was used');
      expect(tab.desktop?.isDirect, isFalse);
      expect(tab.desktop?.error, currentL10n.couldntStartTheRdpEngineCheck);
      await tab.desktop?.close();
    },
    skip: engineOverride ? 'ATERMIUS_RDP_LIBRARY provides an engine' : false,
  );

  test(
    'Linux without an engine keeps the signed-in server gateway route',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(DesktopSession.supportsDirect(HostProtocol.rdp), isFalse);
      expect(DesktopSession.supportsDirect(HostProtocol.vnc), isTrue);
      final api = _RecordingRelayApi();
      final app = await _workspace(api);
      await app.openTerminalTab(_rdp);
      expect(api.targets, [('192.0.2.10', 3389)]);
      await app.terminalTabs.single.desktop?.close();
    },
    skip: engineOverride ? 'ATERMIUS_RDP_LIBRARY provides an engine' : false,
  );
}
