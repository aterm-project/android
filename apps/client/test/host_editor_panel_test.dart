import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ui/host_editor_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<HostRecord?> editWith(
    WidgetTester tester,
    HostRecord original, {
    CredentialRecord? credential,
    List<HostKeychainChoice> keychain = const [],
    Future<void> Function()? interact,
  }) async {
    HostRecord? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                saved = await showHostEditorPanel(
                  context,
                  existing: original,
                  groups: [],
                  hosts: [],
                  initialCredential: credential,
                  keychain: keychain,
                );
              },
              child: const Text('Edit'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await interact?.call();
    await tester.tap(find.text('Save encrypted host'));
    await tester.pumpAndSettle();
    return saved;
  }

  const shared = CredentialRecord(
    id: 'shared',
    name: 'Shared',
    username: 'root',
    kind: AuthKind.privateKey,
    privateKey: 'key-material',
    certificate: 'ssh-ed25519-cert-v01@openssh.com AAAA',
  );
  const referencing = HostRecord(
    id: 'host',
    name: 'Server',
    address: 'example.test',
    username: 'root',
    credentialId: 'shared',
    authKind: AuthKind.privateKey,
    tags: ['api'],
    color: 3,
    isFavorite: true,
  );

  testWidgets('editing unrelated fields keeps the Keychain reference', (
    tester,
  ) async {
    final saved = await editWith(
      tester,
      referencing,
      credential: shared,
      keychain: const [HostKeychainChoice(id: 'shared', label: 'Shared')],
      interact: () async {
        expect(
          find.byKey(const ValueKey('host_editor_sign_in_note')),
          findsOneWidget,
        );
        // Secrets of the shared item are not copied into Host fields.
        expect(find.byKey(const ValueKey('host_editor_password')), findsNothing);
        expect(find.text('key-material'), findsNothing);
        await tester.enterText(
          find.byKey(const ValueKey('host_editor_name')),
          'Renamed',
        );
      },
    );
    expect(saved?.name, 'Renamed');
    expect(saved?.credentialId, 'shared');
    expect(saved?.login, isNull);
    expect(saved?.tags, ['api']);
    expect(saved?.color, 3);
    expect(saved?.isFavorite, isTrue);
  });

  testWidgets('group-inherited sign-in is not silently copied', (tester) async {
    const inherited = HostRecord(
      id: 'h2',
      name: 'Grouped',
      address: 'example.test',
      username: 'root',
      groupId: 'g',
    );
    final saved = await editWith(
      tester,
      inherited,
      credential: const CredentialRecord(
        id: 'group-cred',
        name: 'Group',
        username: 'root',
        secret: 'group-password',
      ),
    );
    expect(saved?.credentialId, isNull);
    expect(saved?.login, isNull);
  });

  testWidgets('explicitly choosing own sign-in migrates into Host fields', (
    tester,
  ) async {
    const passwordShared = CredentialRecord(
      id: 'shared',
      name: 'Shared',
      username: 'root',
      kind: AuthKind.password,
      secret: 'test-password',
    );
    final saved = await editWith(
      tester,
      const HostRecord(id: 'host', name: 'Server', address: 'example.test', username: 'root', credentialId: 'shared'),
      credential: passwordShared,
      keychain: const [HostKeychainChoice(id: 'shared', label: 'Shared')],
      interact: () async {
        await tester.tap(
          find.byKey(const ValueKey('host_editor_sign_in_source')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('own sign-in').last);
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(
          find.byKey(const ValueKey('host_editor_password')),
        );
        expect(field.obscureText, isTrue);
        expect(field.enableSuggestions, isFalse);
      },
    );
    expect(saved?.credentialId, isNull);
    expect(saved?.login?.password, 'test-password');
    expect(referencing.credentialId, 'shared');
  });

  testWidgets('a Keychain item can be selected for a Host', (tester) async {
    const own = HostRecord(
      id: 'h3',
      name: 'Own',
      address: 'example.test',
      username: 'root',
    );
    final saved = await editWith(
      tester,
      own,
      keychain: const [HostKeychainChoice(id: 'kc-1', label: 'Deploy key')],
      interact: () async {
        await tester.tap(
          find.byKey(const ValueKey('host_editor_sign_in_source')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('Deploy key').last);
        await tester.pumpAndSettle();
      },
    );
    expect(saved?.credentialId, 'kc-1');
    expect(saved?.login, isNull);
  });

  testWidgets('narrow editor validates invalid port', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: HostEditorPanel(
          groups: [],
          hosts: [],
          existing: HostRecord(
            id: 'h',
            name: 'Host',
            address: 'example.test',
            port: 0,
            username: 'root',
          ),
        ),
      ),
    );
    await tester.tap(find.text('Save encrypted host'));
    await tester.pump();
    expect(find.text('Port must be between 1 and 65535'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'private key editor preserves pasted newlines and hides on request',
    (tester) async {
      HostRecord? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await showHostEditorPanel(
                    context,
                    groups: [],
                    hosts: [],
                    existing: const HostRecord(
                      id: 'h',
                      name: 'Host',
                      address: 'example.test',
                      username: 'root',
                      authKind: AuthKind.privateKey,
                    ),
                  );
                },
                child: const Text('Edit'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('host_editor_private_key')),
        findsNothing,
      );
      await tester.ensureVisible(find.text('Edit private key'));
      await tester.tap(find.text('Edit private key'));
      await tester.pump();
      const key =
          '-----BEGIN OPENSSH PRIVATE KEY-----\nexample\n-----END OPENSSH PRIVATE KEY-----';
      await tester.enterText(
        find.byKey(const ValueKey('host_editor_private_key')),
        key,
      );
      await tester.ensureVisible(find.text('Hide private key'));
      await tester.tap(find.text('Hide private key'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('host_editor_private_key')),
        findsNothing,
      );
      await tester.tap(find.text('Save encrypted host'));
      await tester.pumpAndSettle();
      expect(saved?.login?.privateKey, key);
      expect(saved?.login?.password, isNull);
    },
  );
}
