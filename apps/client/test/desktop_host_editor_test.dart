import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ui/host_editor_panel.dart';
import 'package:aterm_client/ui/new_session_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final protocol in [
    HostProtocol.ssh,
    HostProtocol.rdp,
    HostProtocol.vnc,
  ]) {
    testWidgets(
      'new session menu opens ${protocol.name} with correct default port',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => NewSessionMenu(
                  onHost: (selected) => showHostEditorPanel(
                    context,
                    groups: [],
                    hosts: [],
                    initialProtocol: selected,
                  ),
                  onConsole: () {},
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('New session'));
        await tester.pumpAndSettle();
        expect(find.text('Local Console'), findsOneWidget);
        await tester.tap(
          find.text(switch (protocol) {
            HostProtocol.ssh => 'SSH host',
            HostProtocol.rdp => 'RDP remote desktop',
            HostProtocol.vnc => 'VNC remote desktop',
          }),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('host_editor_port')))
              .controller!
              .text,
          '${protocol.defaultPort}',
        );
        if (protocol != HostProtocol.ssh)
          expect(find.byKey(const ValueKey('host_editor_kind')), findsNothing);
      },
    );
  }

  testWidgets(
    'protocol selector changes default ports and saves VNC without SSH fields',
    (tester) async {
      HostRecord? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                saved = await showHostEditorPanel(
                  context,
                  groups: [],
                  hosts: [],
                );
              },
              child: const Text('Edit'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('host_editor_name')),
        'Desktop',
      );
      await tester.enterText(
        find.byKey(const ValueKey('host_editor_address')),
        'desktop.example',
      );
      await tester.tap(find.byKey(const ValueKey('host_editor_protocol')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('VNC').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('host_editor_port')))
            .controller!
            .text,
        '5900',
      );
      expect(find.byKey(const ValueKey('host_editor_kind')), findsNothing);
      expect(find.byKey(const ValueKey('host_editor_jump_host')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('host_editor_save')));
      await tester.pumpAndSettle();
      expect(saved?.protocol, HostProtocol.vnc);
      expect(saved?.port, 5900);
      expect(saved?.username, '');
    },
  );
  testWidgets('changing protocol preserves a custom port', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HostEditorPanel(
          groups: [],
          hosts: [],
          existing: HostRecord(
            id: 'h',
            name: 'H',
            address: 'server',
            port: 3390,
            protocol: HostProtocol.rdp,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('host_editor_protocol')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('VNC').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('host_editor_port')))
          .controller!
          .text,
      '3390',
    );
  });
}
