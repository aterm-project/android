import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _vaultId = '22222222-2222-4222-8222-222222222222';

void main() {
  testWidgets('owner sees server deadline and can cancel scheduled deletion', (
    tester,
  ) async {
    var canceled = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: VaultLifecycleTile(
            vault: _deletingVault,
            displayName: 'Operations',
            isCurrent: true,
            busy: false,
            onCancel: () async {
              canceled++;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('DELETION SCHEDULED'), findsOneWidget);
    expect(find.text('Deletion requested'), findsOneWidget);
    expect(find.text('Permanent purge after'), findsOneWidget);
    expect(find.textContaining('2026'), findsNWidgets(2));
    expect(find.text('Cancel deletion'), findsOneWidget);

    await tester.tap(find.text('Cancel deletion'));
    await tester.pump();
    expect(canceled, 1);
  });

  testWidgets(
    'member sees read-only deadline but cannot cancel an owner deletion',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: const Scaffold(
            body: VaultLifecycleTile(
              vault: VaultDescriptor(
                id: _vaultId,
                role: 'editor',
                activeKeyEpoch: '2',
                membershipVersion: '4',
                status: 'deleting',
                requestedAt: '2026-09-26T12:00:00Z',
                purgeAfter: '2026-10-03T12:00:00Z',
                canCancel: false,
                canWrite: false,
              ),
              displayName: 'Operations',
              isCurrent: false,
              busy: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Read-only grace period · All members can keep reading; writes and member changes are paused. You can create a separately password-protected encrypted archive in Settings.',
        ),
        findsOneWidget,
      );
      expect(find.text('Cancel deletion'), findsNothing);
      expect(find.textContaining('Permanent purge after'), findsOneWidget);
    },
  );
}

const VaultDescriptor _deletingVault = VaultDescriptor(
  id: _vaultId,
  role: 'owner',
  activeKeyEpoch: '2',
  membershipVersion: '4',
  status: 'deleting',
  requestedAt: '2026-09-26T12:00:00Z',
  purgeAfter: '2026-10-03T12:00:00Z',
  canCancel: true,
  canWrite: false,
);
