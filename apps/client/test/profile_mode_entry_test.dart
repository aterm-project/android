import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/main.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/database_quarantine.dart';
import 'package:aterm_client/storage/web_storage_policy.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VaultCrypto crypto;

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  testWidgets('mode chooser fits a narrow mobile viewport without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      AtermiusApp(
        enableProfileModeSelection: true,
        serverInitializer: () async => throw StateError('not selected'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Choose a workspace'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'local selection opens the isolated flow without initializing server',
    (tester) async {
      final catalog = LocalProfileCatalog.forTesting(NativeDatabase.memory());
      var serverInitializations = 0;
      await tester.pumpWidget(
        AtermiusApp(
          enableProfileModeSelection: true,
          localProfileCatalog: catalog,
          localProfileService: LocalProfileService(
            catalog: catalog,
            crypto: crypto,
          ),
          crypto: crypto,
          serverInitializer: () async {
            serverInitializations++;
            throw StateError('server backend must stay unopened');
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(serverInitializations, 0);
      await tester.tap(find.byKey(const ValueKey('local_mode_start')));
      await tester.pumpAndSettle();

      expect(find.text('No local profiles yet'), findsOneWidget);
      expect(find.text('仅本地：数据保存在此浏览器/设备中；暂不支持跨设备同步。'), findsOneWidget);
      expect(serverInitializations, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('local catalog initialization failure can be retried', (
    tester,
  ) async {
    final catalog = LocalProfileCatalog.forTesting(NativeDatabase.memory());
    var catalogInitializations = 0;
    var serverInitializations = 0;
    await tester.pumpWidget(
      AtermiusApp(
        enableProfileModeSelection: true,
        localProfileCatalogInitializer: () async {
          catalogInitializations++;
          if (catalogInitializations == 1) {
            throw StateError('private browser database detail');
          }
          return catalog;
        },
        crypto: crypto,
        serverInitializer: () async {
          serverInitializations++;
          throw StateError('server must remain unopened');
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(catalogInitializations, 0);
    await tester.tap(find.byKey(const ValueKey('local_mode_start')));
    await tester.pumpAndSettle();

    expect(catalogInitializations, 1);
    expect(find.text('Choose a workspace'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('local_catalog_open_error')),
      findsOneWidget,
    );
    expect(
      find.textContaining('private browser database detail'),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('local_mode_start')));
    await tester.pumpAndSettle();

    expect(catalogInitializations, 2);
    expect(serverInitializations, 0);
    expect(find.text('No local profiles yet'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('local_catalog_open_error')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('quarantined catalog initialization requires a page reload', (
    tester,
  ) async {
    await tester.pumpWidget(
      AtermiusApp(
        enableProfileModeSelection: true,
        localProfileCatalogInitializer: () async =>
            throw const DatabaseRecoveryRequiredException(),
        crypto: crypto,
        serverInitializer: () async =>
            throw StateError('server stays unopened'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('local_mode_start')));
    await tester.pumpAndSettle();

    expect(find.text('Choose a workspace'), findsOneWidget);
    expect(
      find.text('A local storage write was interrupted. Free up storage space and close other Atermius tabs for this site, then reload the page to recover and try again.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('local_catalog_reload')), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('local_mode_start')),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('No local profiles yet'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('server storage errors are lazy, retryable, and redacted', (
    tester,
  ) async {
    var serverInitializations = 0;
    await tester.pumpWidget(
      AtermiusApp(
        enableProfileModeSelection: true,
        serverInitializer: () async {
          serverInitializations++;
          throw StateError('private sqlite path /secret/credentials.db');
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(serverInitializations, 0);
    expect(find.text('Choose a workspace'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('server_mode_start')));
    await tester.pumpAndSettle();

    expect(serverInitializations, 1);
    expect(find.text("Couldn't open the cloud workspace or save the workspace mode. Check local storage and try again."), findsOneWidget);
    expect(find.textContaining('/secret/credentials.db'), findsNothing);
    expect(find.byKey(const ValueKey('server_mode_start')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('server_mode_start')));
    await tester.pumpAndSettle();
    expect(serverInitializations, 2);
    expect(find.textContaining('/secret/credentials.db'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported server storage gives actionable retry guidance', (
    tester,
  ) async {
    await tester.pumpWidget(
      AtermiusApp(
        enableProfileModeSelection: true,
        serverInitializer: () async =>
            throw const UnsupportedWebStorageException(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('server_mode_start')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Supported browser storage'), findsOneWidget);
    expect(find.byKey(const ValueKey('server_mode_start')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
