import 'dart:io';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/main.dart' as product;
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/workspace_mode.dart';
import 'package:aterm_client/storage/workspace_mode_store_native.dart';
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

  for (final savedLocal in [false, true]) {
    testWidgets(
      savedLocal
          ? 'Windows native startup restores an isolated saved local mode'
          : 'Windows native first startup offers workspace choices',
      (tester) async {
        final directory = await tester.runAsync(
          () => Directory.systemTemp.createTemp('atermius-startup-mode-'),
        );
        final store = FileWorkspaceModeStore(directory: () async => directory!);
        var localStarts = 0;
        var serverStarts = 0;
        try {
          if (savedLocal) {
            await tester.runAsync(() => store.write(WorkspaceMode.local));
          }
          await tester.pumpWidget(
            product.AtermiusStartup(
              initialize: () async => product.AtermiusApp(
                enableProfileModeSelection: true,
                crypto: crypto,
                modeStore: FileWorkspaceModeStore(
                  directory: () async => directory!,
                ),
                localProfileCatalogInitializer: () async {
                  localStarts++;
                  return LocalProfileCatalog.forTesting(
                    NativeDatabase.memory(),
                  );
                },
                serverInitializer: () async {
                  serverStarts++;
                  throw StateError('Startup must defer the server database');
                },
              ),
            ),
          );
          final target = savedLocal
              ? find.byKey(const ValueKey('local_profile_create_password'))
              : find.text('Choose a workspace');
          for (var attempt = 0; attempt < 100; attempt++) {
            await tester.pump(const Duration(milliseconds: 25));
            if (target.evaluate().isNotEmpty) break;
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 25)),
            );
          }
          expect(tester.takeException(), isNull);
          expect(target, findsOneWidget);
          expect(serverStarts, 0);
          expect(localStarts, savedLocal ? 1 : 0);
          if (savedLocal) {
            expect(find.text('Choose a workspace'), findsNothing);
            expect(
              find.byKey(const ValueKey('local_profile_preferences_toggle')),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('local_profile_exit')),
              findsNothing,
            );
          } else {
            expect(find.text('Server account and sync'), findsOneWidget);
            expect(find.text('Local-only profile'), findsOneWidget);
            expect(find.text('Open locally'), findsOneWidget);
            expect(find.text('Continue'), findsOneWidget);
          }
          expect(
            await tester.runAsync(() => store.read()),
            savedLocal ? WorkspaceMode.local : isNull,
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await tester.runAsync(() => directory!.delete(recursive: true));
        }
      },
      skip: !Platform.isWindows,
    );
  }
}
