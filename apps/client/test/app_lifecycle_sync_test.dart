import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/main.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SodiumSumo sodium;
  late VaultCrypto crypto;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    crypto = VaultCrypto(sodium);
  });

  testWidgets('resuming the server workspace triggers one sync', (
    tester,
  ) async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final controller = _LifecycleSyncController(
      sodium: sodium,
      database: database,
    );
    await tester.pumpWidget(AtermiusApp(controller: controller));
    await tester.pumpAndSettle();

    await _pauseAndResume(tester);

    expect(controller.syncCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await database.close();
  });

  testWidgets('resuming local-only mode does not trigger a server sync', (
    tester,
  ) async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final controller = _LifecycleSyncController(
      sodium: sodium,
      database: database,
    );
    final catalog = LocalProfileCatalog.forTesting(NativeDatabase.memory());
    await tester.pumpWidget(
      AtermiusApp(
        controller: controller,
        localProfileCatalog: catalog,
        localProfileService: LocalProfileService(
          catalog: catalog,
          crypto: crypto,
        ),
        crypto: crypto,
        enableProfileModeSelection: true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('local_mode_start')));
    await tester.pumpAndSettle();
    expect(find.text('No local profiles yet'), findsOneWidget);

    await _pauseAndResume(tester);

    expect(controller.syncCalls, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    await database.close();
  });
}

Future<void> _pauseAndResume(WidgetTester tester) async {
  for (final state in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }
}

class _LifecycleSyncController extends AppController {
  _LifecycleSyncController({required super.sodium, required super.database})
    : super(secureStore: ClientSecureStore()) {
    session = const AuthSession(
      accountId: 'account-1',
      accessToken: 'access',
      expiresIn: 900,
      refreshToken: 'refresh',
      deviceId: 'device-1',
      vaults: [],
    );
    stage = ClientStage.workspace;
  }

  int syncCalls = 0;

  @override
  Future<void> restoreLastServer() async {}

  @override
  Future<void> synchronize({
    bool background = false,
    bool suppressSuccessNotice = false,
  }) async {
    syncCalls++;
  }
}
