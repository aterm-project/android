import 'package:aterm_client/main.dart';
import 'package:aterm_client/storage/web_storage_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'unsupported storage stays before database open and retry recovers',
    (tester) async {
      var available = <String>['unsafeIndexedDb'];
      var openCalls = 0;
      var attempts = 0;

      Future<Widget> initialize() async {
        attempts++;
        await openWithSafeDriftStorage<void>(
          databaseName: 'atermius_vault',
          availableImplementations: available,
          existingDatabases: const [],
          open: (_) async {
            openCalls++;
          },
        );
        return const MaterialApp(home: Scaffold(body: Text('Vault ready')));
      }

      await tester.pumpWidget(AtermiusStartup(initialize: initialize));
      await tester.pumpAndSettle();

      expect(attempts, 1);
      expect(openCalls, 0);
      expect(find.text('Supported browser storage required'), findsOneWidget);
      expect(find.text('Vault ready'), findsNothing);
      expect(find.bySemanticsLabel('Retry'), findsOneWidget);

      available = ['sharedIndexedDb'];
      await tester.tap(find.byKey(const ValueKey('startup_retry')));
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(openCalls, 1);
      expect(find.text('Vault ready'), findsOneWidget);
    },
  );

  testWidgets('startup errors never expose exception or account details', (
    tester,
  ) async {
    await tester.pumpWidget(
      AtermiusStartup(
        initialize: () async => throw Exception(
          'alice@example.test refresh-token-secret server-private-name',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("Couldn't initialize the secure workspace"), findsOneWidget);
    expect(find.textContaining('alice@example.test'), findsNothing);
    expect(find.textContaining('refresh-token-secret'), findsNothing);
    expect(find.textContaining('server-private-name'), findsNothing);
    expect(find.bySemanticsLabel('Retry'), findsOneWidget);
  });
}
