import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ui/host_editor_panel.dart';
import 'package:aterm_client/ui/new_session_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<HostRecord?> edit(
    WidgetTester tester, {
    HostRecord? existing,
    HostProtocol initialProtocol = HostProtocol.ssh,
    required Future<void> Function() interact,
  }) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    HostRecord? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                saved = await showHostEditorPanel(
                  context,
                  existing: existing,
                  initialProtocol: initialProtocol,
                  groups: const [],
                  hosts: const [],
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
    await interact();
    await tester.tap(find.text('Save encrypted host'));
    await tester.pumpAndSettle();
    return saved;
  }

  testWidgets('new Telnet host shows the plaintext notice and no sign-in', (
    tester,
  ) async {
    final saved = await edit(
      tester,
      initialProtocol: HostProtocol.telnet,
      interact: () async {
        expect(
          find.byKey(const ValueKey('telnet_plaintext_notice')),
          findsOneWidget,
        );
        expect(find.text('Telnet is not encrypted'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('host_editor_password')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('host_editor_username')), findsNothing);
        expect(find.byKey(const ValueKey('host_editor_jump_host')), findsNothing);
        await tester.enterText(
          find.byKey(const ValueKey('host_editor_name')),
          'Core switch',
        );
        await tester.enterText(
          find.byKey(const ValueKey('host_editor_address')),
          '192.0.2.20',
        );
      },
    );
    expect(saved, isNotNull);
    expect(saved!.protocol, HostProtocol.telnet);
    expect(saved.port, 23);
    expect(saved.login, isNull);
    expect(saved.credentialId, isNull);
    expect(saved.username, isEmpty);
    expect(saved.validate(), isNull);
  });

  testWidgets('switching an SSH host with a saved password to Telnet drops it', (
    tester,
  ) async {
    const ssh = HostRecord(
      id: 'h',
      name: 'Router',
      address: '192.0.2.21',
      username: 'admin',
      login: HostLogin(kind: AuthKind.password, password: 'saved-secret'),
    );
    final saved = await edit(
      tester,
      existing: ssh,
      interact: () async {
        // Positive control: SSH shows the sign-in fields before switching.
        expect(find.byKey(const ValueKey('host_editor_password')), findsOneWidget);
        expect(find.byKey(const ValueKey('host_editor_username')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('host_editor_protocol')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Telnet').last);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('telnet_plaintext_notice')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('host_editor_password')), findsNothing);
      },
    );
    expect(saved, isNotNull);
    expect(saved!.protocol, HostProtocol.telnet);
    expect(saved.port, 23, reason: 'default port follows the protocol');
    expect(saved.login, isNull, reason: 'a saved password is never kept');
    expect(saved.username, isEmpty);
    expect(saved.toJson().toString(), isNot(contains('saved-secret')));
  });

  testWidgets('unified plus menu offers a Telnet host', (tester) async {
    HostProtocol? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewSessionMenu(onHost: (protocol) => chosen = protocol),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('Telnet host'), findsOneWidget);
    await tester.tap(find.text('Telnet host'));
    await tester.pumpAndSettle();
    expect(chosen, HostProtocol.telnet);
  });
}
