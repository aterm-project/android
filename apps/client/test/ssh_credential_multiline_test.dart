import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('credential action menus expose a unique accessible name', (
    tester,
  ) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app =
        _CredentialController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.credentials
          ..activeVault = const VaultDescriptor(
            id: '55555555-5555-4555-8555-555555555555',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          )
          ..credentials.addAll(const [
            CredentialRecord(
              id: 'credential-password',
              name: 'Deploy password',
              username: 'deploy',
              secret: 'test-only-secret',
            ),
            CredentialRecord(
              id: 'credential-key',
              name: 'Deploy key',
              username: 'automation',
              kind: AuthKind.privateKey,
              privateKey: 'test-only-private-key',
            ),
          ]);

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel('Credential: Deploy password; deploy; Password'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'Credential: Deploy key; automation; Private key',
        ),
        findsOneWidget,
      );
      expect(
        find.byTooltip('Credential actions: Deploy password'),
        findsOneWidget,
      );
      expect(
        tester
            .getSemantics(find.byTooltip('Credential actions: Deploy password'))
            .getSemanticsData()
            .tooltip,
        'Credential actions: Deploy password',
      );
      expect(find.byTooltip('Credential actions: Deploy key'), findsOneWidget);
      expect(
        tester
            .getSemantics(find.byTooltip('Credential actions: Deploy key'))
            .getSemanticsData()
            .tooltip,
        'Credential actions: Deploy key',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('private key remains multiline and saves embedded newlines', (
    tester,
  ) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app =
        _CredentialController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.credentials
          ..activeVault = const VaultDescriptor(
            id: '55555555-5555-4555-8555-555555555555',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add credential'));
      await tester.pumpAndSettle();
      final passwordField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Password',
      );
      final passwordEditable = tester.state<EditableTextState>(
        find.descendant(of: passwordField, matching: find.byType(EditableText)),
      );
      await tester.tap(find.text('Private key'));
      await tester.pumpAndSettle();

      final privateKeyField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'PEM private key',
      );
      expect(privateKeyField, findsOneWidget);
      final field = tester.widget<TextField>(privateKeyField);
      final privateKeyEditable = tester.state<EditableTextState>(
        find.descendant(
          of: privateKeyField,
          matching: find.byType(EditableText),
        ),
      );
      expect(identical(privateKeyEditable, passwordEditable), isFalse);
      expect(field.maxLines, greaterThan(1));
      expect(field.minLines, greaterThan(1));
      expect(field.obscureText, isFalse);
      expect(field.keyboardType, TextInputType.multiline);
      expect(field.textInputAction, TextInputAction.newline);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(find.bySemanticsLabel('PEM private key'), findsOneWidget);

      const pem =
          '-----BEGIN EC PRIVATE KEY-----\n'
          'MHcCAQEEIJhRXAi/dEpIS6ywVfmAy6DESiGdmEalpujaDEuNXy77oAoGCCqGSM49\n'
          'AwEHoUQDQgAEbG+9rtBrkd3rlhF/dDKBEOTLJaSEMw3aUHwIs/4GOxPzBLGPrYIa\n'
          'EnNEA6tk4cu6J+hrvX1U2HiIav0JBVRYwA==\n'
          '-----END EC PRIVATE KEY-----\n';
      await tester.enterText(privateKeyField, pem);
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText == 'Credential name',
        ),
        'deploy key',
      );
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText == 'SSH username',
        ),
        'deploy',
      );
      await tester.tap(find.text('Save encrypted credential'));
      await tester.pumpAndSettle();

      expect(app.savedCredential, isNotNull);
      expect(app.savedCredential!.kind, AuthKind.privateKey);
      expect(app.savedCredential!.privateKey, pem);
      expect(
        SSHKeyPair.fromPem(app.savedCredential!.privateKey!),
        hasLength(1),
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });
}

class _CredentialController extends AppController {
  _CredentialController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  CredentialRecord? savedCredential;

  @override
  Future<void> saveCredential(CredentialRecord credential) async {
    savedCredential = credential;
  }
}
