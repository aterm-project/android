import 'dart:async';

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

  testWidgets('interactive challenge collects visible and hidden answers', (
    tester,
  ) async {
    final harness = await _makeHarness();
    final cancelled = Completer<void>();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: harness.app),
        ),
      );
      await tester.pumpAndSettle();

      final challenge = harness.app.askSshUserInfo!(
        const HostRecord(
          id: 'host-1',
          name: 'Production',
          address: '192.0.2.20',
          port: 2222,
        ),
        SSHUserInfoRequest(
          'PAM\u202echallenge\nSecond line',
          'Enter a visible\u2028code and a hidden one.\nNo server markup.',
          [
            SSHUserInfoPrompt('First\u061ccode', true),
            SSHUserInfoPrompt('One-time code', false),
          ],
        ),
        cancelled.future,
      );
      await tester.pumpAndSettle();

      expect(find.text('SSH authentication challenge'), findsOneWidget);
      expect(find.text('Production · 192.0.2.20:2222'), findsOneWidget);
      expect(find.text('PAM challenge Second line'), findsOneWidget);
      expect(
        find.text('Enter a visible code and a hidden one. No server markup.'),
        findsOneWidget,
      );
      expect(find.text('First code'), findsOneWidget);
      final first = tester.widget<TextField>(
        find.byKey(const ValueKey('ssh-user-info-response-0')),
      );
      final second = tester.widget<TextField>(
        find.byKey(const ValueKey('ssh-user-info-response-1')),
      );
      expect(first.obscureText, isFalse);
      expect(second.obscureText, isTrue);

      await tester.enterText(
        find.byKey(const ValueKey('ssh-user-info-response-0')),
        'visible-response',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ssh-user-info-response-1')),
        'one-time-secret',
      );
      await tester.tap(find.byKey(const ValueKey('ssh-user-info-submit')));
      await tester.pumpAndSettle();

      expect(await challenge, ['visible-response', 'one-time-secret']);
      expect(find.text('one-time-secret'), findsNothing);
      expect(find.byKey(const ValueKey('ssh-user-info-dialog')), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.app.dispose();
      await harness.database.close();
    }
  });

  testWidgets('cancellation signal removes its active challenge dialog', (
    tester,
  ) async {
    final harness = await _makeHarness();
    final cancelled = Completer<void>();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: harness.app),
        ),
      );
      await tester.pumpAndSettle();

      final challenge = harness.app.askSshUserInfo!(
        const HostRecord(
          id: 'host-2',
          name: 'Bastion',
          address: '192.0.2.21',
          port: 22,
        ),
        SSHUserInfoRequest(
          'Second factor',
          'Enter the current one-time code.',
          [SSHUserInfoPrompt('Code', false)],
        ),
        cancelled.future,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ssh-user-info-dialog')),
        findsOneWidget,
      );

      cancelled.complete();
      await tester.pumpAndSettle();

      expect(await challenge, isNull);
      expect(find.byKey(const ValueKey('ssh-user-info-dialog')), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.app.dispose();
      await harness.database.close();
    }
  });

  testWidgets('empty final challenge round is acknowledged without a dialog', (
    tester,
  ) async {
    final harness = await _makeHarness();
    final cancelled = Completer<void>();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: harness.app),
        ),
      );
      await tester.pumpAndSettle();

      final responses = await harness.app.askSshUserInfo!(
        const HostRecord(
          id: 'host-empty-round',
          name: 'Production',
          address: '192.0.2.20',
          port: 22,
        ),
        SSHUserInfoRequest('', '', []),
        cancelled.future,
      );

      expect(responses, isEmpty);
      expect(find.byKey(const ValueKey('ssh-user-info-dialog')), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.app.dispose();
      await harness.database.close();
    }
  });

  testWidgets('informational challenge without prompts stays visible', (
    tester,
  ) async {
    final harness = await _makeHarness();
    final cancelled = Completer<void>();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: harness.app),
        ),
      );
      await tester.pumpAndSettle();

      final response = harness.app.askSshUserInfo!(
        const HostRecord(
          id: 'host-info-round',
          name: 'Production',
          address: '192.0.2.20',
          port: 22,
        ),
        SSHUserInfoRequest(
          'Additional verification',
          'The server has no more response fields.',
          [],
        ),
        cancelled.future,
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('ssh-user-info-dialog')),
        findsOneWidget,
      );
      expect(find.text('Additional verification'), findsOneWidget);
      expect(
        find.text('The server has no more response fields.'),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ssh-user-info-submit')));
      await tester.pumpAndSettle();

      expect(await response, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.app.dispose();
      await harness.database.close();
    }
  });

  testWidgets('excessive prompt count fails closed without sending responses', (
    tester,
  ) async {
    final harness = await _makeHarness();
    final cancelled = Completer<void>();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: harness.app),
        ),
      );
      await tester.pumpAndSettle();

      final challenge = harness.app.askSshUserInfo!(
        const HostRecord(
          id: 'host-3',
          name: 'Target',
          address: 'target.internal',
          port: 22,
        ),
        SSHUserInfoRequest(
          'Many prompts',
          '',
          List.generate(
            9,
            (index) => SSHUserInfoPrompt('Prompt $index', false),
          ),
        ),
        cancelled.future,
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('ssh-user-info-prompt-limit')),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(const ValueKey('ssh-user-info-submit')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ssh-user-info-cancel')));
      await tester.pumpAndSettle();

      expect(await challenge, isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.app.dispose();
      await harness.database.close();
    }
  });
}

Future<_Harness> _makeHarness() async {
  final sodium = await SodiumSumoInit.init();
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final app =
      _EmptyWorkspaceController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
        )
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.hosts;
  return _Harness(app, database);
}

class _Harness {
  const _Harness(this.app, this.database);

  final _EmptyWorkspaceController app;
  final ClientDatabase database;
}

class _EmptyWorkspaceController extends AppController {
  _EmptyWorkspaceController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  @override
  bool get authenticated => true;
}
