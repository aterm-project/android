import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/api/api_client.dart';
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
    'Vault trust confirmation still opens after Hosts page is replaced',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.hosts
            ..activeVault = const VaultDescriptor(
              id: '11111111-1111-4111-8111-111111111111',
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            );
      final semanticsHandle = tester.ensureSemantics();

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AnimatedBuilder(
              animation: app,
              builder: (context, _) => AppShell(controller: app),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(app.askTrustHost, isNotNull);
        expect(app.askTrustHostApproval, isNotNull);

        app.showWorkspacePage(WorkspacePage.terminal);
        await tester.pumpAndSettle();
        expect(find.text('Terminal workspace'), findsOneWidget);

        final confirmation = app.askTrustHostApproval!(
          const KnownHostApprovalRequest(
            host: 'deploy.example.test',
            port: 22,
            algorithm: 'ssh-ed25519',
            fingerprint: 'SHA256:verified-host-fingerprint',
            previouslyRevoked: true,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Verify SSH host key'), findsOneWidget);
        expect(find.textContaining('deploy.example.test:22'), findsOneWidget);
        expect(find.text('Algorithm: ssh-ed25519'), findsOneWidget);
        expect(find.textContaining('was revoked before'), findsOneWidget);
        expect(
          find.textContaining('encrypted trust record for this Vault'),
          findsOneWidget,
        );
        expect(find.text('SHA256:verified-host-fingerprint'), findsOneWidget);
        final fingerprintSemantics = tester.getSemantics(
          find.byKey(const ValueKey('ssh-host-key-fingerprint')),
        );
        expect(
          fingerprintSemantics.label,
          'SSH host key fingerprint: SHA256:verified-host-fingerprint',
        );

        await tester.tap(find.text('Trust after verification'));
        await tester.pumpAndSettle();
        expect(await confirmation, isTrue);
      } finally {
        semanticsHandle.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
      }
    },
  );
}
