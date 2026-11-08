import 'support/settings_navigation.dart';

import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Settings shows a comparable public instance signing fingerprint',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final signingPublicKey = base64Url
          .encode(List<int>.filled(32, 0x42))
          .replaceAll('=', '');
      final controller =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.settings
            ..instance = InstanceInfo(
              instanceId: '11111111-1111-4111-8111-111111111111',
              serverSpaceId: '22222222-2222-4222-8222-222222222222',
              generation: '1',
              protocolVersion: 1,
              setupRequired: false,
              capabilities: const [],
              signingPublicKey: signingPublicKey,
            );
      final expectedFingerprint = await controller.publicKeyFingerprint(
        signingPublicKey,
      );

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: controller),
          ),
        );
        await tester.pump();
        if (find
            .byKey(const ValueKey('cloud_settings'))
            .evaluate()
            .isNotEmpty) {
          await openSettingsCategory(tester, 'about', ifAvailable: true);
        }
        await tester.pumpAndSettle();

        expect(
          find.text('Instance signing key fingerprint · SHA-256'),
          findsOneWidget,
        );
        expect(find.text(expectedFingerprint), findsOneWidget);
        expect(
          find.textContaining('trusted administrator over a separate channel'),
          findsOneWidget,
        );
        expect(find.text(signingPublicKey), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        await database.close();
      }
    },
  );
}
