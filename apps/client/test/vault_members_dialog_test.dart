import 'support/settings_navigation.dart';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:sodium/sodium_sumo.dart';

const _ownerId = '11111111-1111-4111-8111-111111111111';
const _editorId = '22222222-2222-4222-8222-222222222222';
const _viewerId = '33333333-3333-4333-8333-333333333333';
const _pendingId = '44444444-4444-4444-8444-444444444444';
const _vaultId = '55555555-5555-4555-8555-555555555555';
const _ownerDeviceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pending invitation displays its expiration time', (
    tester,
  ) async {
    final (controller, database) = await _createController();
    const expiresAt = '2026-10-05T12:30:00Z';
    try {
      _setInvitation(controller, 'pending', expiresAt: expiresAt);
      await _openMembers(tester, controller);
      await _ensureMemberVisible(tester, 'pending@example.test');

      final formattedExpiry = DateFormat.yMMMd().add_jm().format(
        DateTime.parse(expiresAt).toLocal(),
      );
      expect(
        find.textContaining('EDITOR · Invitation pending'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Invitation expires $formattedExpiry'),
        findsOneWidget,
      );
      expect(find.text('INVITED'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await database.close();
    }
  });

  testWidgets('members panel shows temporary online device presence', (
    tester,
  ) async {
    final (controller, database) = await _createController();
    final lastSeen = DateTime.utc(2026, 10, 2, 12, 30);
    try {
      controller.vaultPresenceDevices = [
        VaultPresenceDevice(
          userId: _ownerId,
          deviceId: _ownerDeviceId,
          lastSeenAt: lastSeen,
        ),
      ];
      await _openMembers(tester, controller);
      await _ensureMemberVisible(tester, 'owner@example.test');

      expect(
        find.textContaining(
          '1 device online · last seen ${DateFormat.Hm().format(lastSeen.toLocal())}',
        ),
        findsOneWidget,
      );
      await _ensureMemberVisible(tester, 'editor@example.test');
      expect(find.textContaining('No devices online'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await database.close();
    }
  });

  testWidgets('Viewer can inspect presence but cannot manage members', (
    tester,
  ) async {
    final (controller, database) = await _createController();
    final lastSeen = DateTime.utc(2026, 10, 2, 12, 30);
    try {
      controller
        ..activeVault = const VaultDescriptor(
          id: _vaultId,
          role: 'viewer',
          activeKeyEpoch: '3',
          membershipVersion: '7',
          canWrite: false,
        )
        ..vaultPresenceDevices = [
          VaultPresenceDevice(
            userId: _ownerId,
            deviceId: _ownerDeviceId,
            lastSeenAt: lastSeen,
          ),
        ];
      await _openMembers(tester, controller);
      await _ensureMemberVisible(tester, 'owner@example.test');

      expect(find.text('View Vault members'), findsOneWidget);
      expect(find.text('Members · Operations'), findsOneWidget);
      expect(
        find.textContaining(
          '1 device online · last seen ${DateFormat.Hm().format(lastSeen.toLocal())}',
        ),
        findsOneWidget,
      );
      expect(find.text('Make viewer'), findsNothing);
      expect(find.text('Make editor'), findsNothing);
      expect(find.text('Revoke access'), findsNothing);
      expect(find.text('Transfer ownership'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await database.close();
    }
  });

  testWidgets('Members dialog refreshes presence only while it is open', (
    tester,
  ) async {
    const refreshInterval = Duration(seconds: 5);
    final (controller, database) = await _createController(
      presenceRefreshInterval: refreshInterval,
    );
    final lastSeen = DateTime.utc(2026, 10, 2, 13, 0);
    controller.presenceAfterListRefresh = [
      VaultPresenceDevice(
        userId: _viewerId,
        deviceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        lastSeenAt: lastSeen,
      ),
    ];
    try {
      await _openMembers(tester, controller);
      expect(controller.presenceListRefreshCount, 0);
      expect(controller.memberRefreshCount, 1);

      await tester.pump(refreshInterval);
      await tester.pump();
      expect(controller.presenceListRefreshCount, 1);
      expect(controller.memberRefreshCount, 1);
      await _ensureMemberVisible(tester, 'viewer@example.test');
      expect(
        find.textContaining(
          '1 device online · last seen ${DateFormat.Hm().format(lastSeen.toLocal())}',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      final completedRefreshes = controller.presenceListRefreshCount;
      await tester.pump(refreshInterval * 3);
      await tester.pump();
      expect(controller.presenceListRefreshCount, completedRefreshes);
      expect(controller.memberRefreshCount, 1);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await database.close();
    }
  });

  for (final (invitationStatus, expectedLabel, expectedDetail)
      in <(String, String, String)>[
        (
          'expired',
          'Invitation expired',
          'Send a new invitation from Settings > Invite member.',
        ),
        (
          'stale',
          'Invitation needs reissue',
          'This invitation was invalidated after a Vault membership change.',
        ),
        (
          'reissue_required',
          'Invitation needs reissue',
          'This invitation\'s validity could not be confirmed.',
        ),
      ]) {
    testWidgets(
      '$invitationStatus invitation explains reissue and remains revocable',
      (tester) async {
        final (controller, database) = await _createController();
        try {
          _setInvitation(controller, invitationStatus);
          await _openMembers(tester, controller);
          await _ensureMemberVisible(tester, 'pending@example.test');

          expect(find.textContaining(expectedLabel), findsOneWidget);
          expect(find.textContaining(expectedDetail), findsOneWidget);
          expect(
            find.textContaining('Settings > Invite member'),
            findsOneWidget,
          );
          final revokeButton = find.widgetWithText(
            OutlinedButton,
            'Revoke invitation',
          );
          expect(revokeButton, findsOneWidget);
          expect(
            tester.widget<OutlinedButton>(revokeButton).onPressed,
            isNotNull,
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
          await database.close();
        }
      },
    );
  }

  for (final (description, invitationStatus) in <(String, String?)>[
    ('unknown status', 'future_status'),
    ('missing metadata', null),
  ]) {
    testWidgets('$description fails closed and keeps invitation revocable', (
      tester,
    ) async {
      final (controller, database) = await _createController();
      try {
        _setInvitation(controller, invitationStatus);
        await _openMembers(tester, controller);
        await _ensureMemberVisible(tester, 'pending@example.test');

        expect(
          find.textContaining('EDITOR · Invitation needs reissue'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'This invitation\'s validity could not be confirmed.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('Settings > Invite member'), findsOneWidget);
        expect(find.textContaining('Invitation pending'), findsNothing);
        final revokeButton = find.widgetWithText(
          OutlinedButton,
          'Revoke invitation',
        );
        expect(revokeButton, findsOneWidget);
        expect(
          tester.widget<OutlinedButton>(revokeButton).onPressed,
          isNotNull,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        await database.close();
      }
    });
  }

  testWidgets('owner can change a role after confirming key rotation', (
    tester,
  ) async {
    final (controller, database) = await _createController();
    try {
      await _openMembers(tester, controller);
      expect(find.text('editor@example.test'), findsOneWidget);
      expect(find.textContaining('EDITOR · Active'), findsOneWidget);
      expect(find.text('Make viewer'), findsOneWidget);

      // The last member row can be outside the lazy ListView viewport.
      await _ensureMemberVisible(tester, 'viewer@example.test');
      expect(find.text('viewer@example.test'), findsOneWidget);
      expect(find.text('Make editor'), findsOneWidget);
      await _ensureMemberVisible(tester, 'pending@example.test');
      expect(
        find.textContaining('EDITOR · Invitation pending'),
        findsOneWidget,
      );
      expect(find.text('Revoke invitation'), findsOneWidget);
      await _scrollMembersToTop(tester);

      await tester.tap(find.text('Make viewer'));
      await tester.pumpAndSettle();
      expect(find.text('Rotate key and change role?'), findsOneWidget);
      expect(find.textContaining('rotates the Vault key'), findsOneWidget);
      expect(
        find.textContaining('Pending invitation tokens become invalid'),
        findsOneWidget,
      );

      await tester.tap(find.text('Change to viewer'));
      await tester.pumpAndSettle();
      expect(controller.changedRole, ('$_editorId', 'viewer'));
      expect(
        controller.rows.singleWhere(
          (row) => row['user_id'] == _editorId,
        )['role'],
        'viewer',
      );
      expect(find.textContaining('VIEWER · Active'), findsOneWidget);
      expect(find.text('Make editor'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await database.close();
    }
  });

  testWidgets('member mutations are disabled during Vault sync or recovery', (
    tester,
  ) async {
    final (controller, database) = await _createController();
    try {
      await _openMembers(tester, controller);
      await _ensureMemberVisible(tester, 'editor@example.test');

      controller
        ..syncing = true
        ..notifyListeners();
      await tester.pump();

      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Make viewer'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Transfer ownership'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Revoke access'),
            )
            .onPressed,
        isNull,
      );

      controller
        ..syncing = false
        ..snapshotRecoveryActive = true
        ..notifyListeners();
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Make viewer'),
            )
            .onPressed,
        isNull,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await database.close();
    }
  });

  testWidgets('owner confirms revocation and sees offline-copy warning', (
    tester,
  ) async {
    final (controller, database) = await _createController();
    try {
      await _openMembers(tester, controller);
      await _ensureMemberVisible(tester, 'editor@example.test');
      final revokeButtons = find.text('Revoke access');
      await tester.ensureVisible(revokeButtons.first);
      await tester.pumpAndSettle();
      await tester.tap(revokeButtons.first);
      await tester.pumpAndSettle();
      expect(find.text('Revoke member access?'), findsOneWidget);
      expect(find.textContaining('receives no new key'), findsOneWidget);
      expect(find.textContaining('cannot be erased remotely'), findsOneWidget);
      expect(find.text('Revoke and rotate key'), findsOneWidget);

      await tester.tap(find.text('Revoke and rotate key'));
      await tester.pumpAndSettle();
      expect(controller.revokedUserId, _editorId);
      expect(
        controller.rows.singleWhere(
          (row) => row['user_id'] == _editorId,
        )['state'],
        'revoked',
      );
      expect(find.text('Make viewer'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await database.close();
    }
  });

  testWidgets('owner transfers ownership only to active members', (
    tester,
  ) async {
    final (controller, database) = await _createController();
    try {
      controller.rows = controller.rows
          .where(
            (row) => row['user_id'] == _ownerId || row['user_id'] == _editorId,
          )
          .toList(growable: false);
      controller.vaultMembers = controller.rows;
      await _openMembers(tester, controller);
      final transfer = find.text('Transfer ownership');
      expect(transfer, findsOneWidget);
      await tester.tap(transfer);
      await tester.pumpAndSettle();
      expect(find.text('Transfer Vault ownership?'), findsOneWidget);
      expect(find.textContaining('remain an active editor'), findsOneWidget);
      expect(find.textContaining('one atomic update'), findsOneWidget);
      expect(find.text('Transfer and rotate key'), findsOneWidget);

      await tester.tap(find.text('Transfer and rotate key'));
      await tester.pumpAndSettle();
      expect(controller.transferredUserId, _editorId);
      expect(find.text('Transfer Vault ownership?'), findsNothing);
      expect(find.text('Members · Operations'), findsNothing);
      expect(controller.activeVault?.role, 'editor');
      expect(
        controller.rows.singleWhere(
          (row) => row['user_id'] == _ownerId,
        )['role'],
        'editor',
      );
      expect(
        controller.rows.singleWhere(
          (row) => row['user_id'] == _editorId,
        )['role'],
        'owner',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await database.close();
    }
  });

  testWidgets('member refresh before opening shows a newly pending invite', (
    tester,
  ) async {
    final (controller, database) = await _createController();
    try {
      // Simulate the cached owner-only list from before invitation creation.
      // Opening the dialog must await refreshVaultMembers and render the
      // current owner-plus-invitation response rather than the stale cache.
      controller.vaultMembers = controller.rows
          .where((row) => row['user_id'] == _ownerId)
          .toList(growable: false);
      controller.rows = controller.rows
          .where(
            (row) => row['user_id'] == _ownerId || row['user_id'] == _pendingId,
          )
          .toList(growable: false);
      await _openMembers(tester, controller);
      expect(find.text('pending@example.test'), findsOneWidget);
      expect(
        find.textContaining('EDITOR · Invitation pending'),
        findsOneWidget,
      );
      expect(find.text('Transfer ownership'), findsNothing);
      expect(
        controller.vaultMembers.map((row) => row['state']).toSet(),
        containsAll({'active', 'invited'}),
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await database.close();
    }
  });

  testWidgets('transfer failure keeps the members dialog open with an error', (
    tester,
  ) async {
    final (controller, database) = await _createController();
    try {
      controller.rows = controller.rows
          .where(
            (row) => row['user_id'] == _ownerId || row['user_id'] == _editorId,
          )
          .toList(growable: false);
      controller.vaultMembers = controller.rows;
      controller.failTransfer = true;
      await _openMembers(tester, controller);
      await tester.tap(find.text('Transfer ownership'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transfer and rotate key'));
      await tester.pumpAndSettle();

      expect(find.text('Transfer Vault ownership?'), findsNothing);
      expect(find.text('Members · Operations'), findsOneWidget);
      expect(find.textContaining('synthetic transfer failure'), findsOneWidget);
      expect(controller.transferredUserId, isNull);
      expect(
        controller.rows.singleWhere(
          (row) => row['user_id'] == _editorId,
        )['role'],
        'editor',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await database.close();
    }
  });
}

Future<void> _ensureMemberVisible(WidgetTester tester, String username) async {
  final list = find.byType(ListView).last;
  final scrollable = find.descendant(
    of: list,
    matching: find.byType(Scrollable),
  );
  await tester.scrollUntilVisible(
    find.text(username),
    100,
    scrollable: scrollable,
  );
  await tester.pumpAndSettle();
}

void _setInvitation(
  _MemberController controller,
  String? status, {
  String? expiresAt,
}) {
  controller.rows = controller.rows
      .map((member) {
        if (member['user_id'] != _pendingId) return member;
        final updated = {...member};
        if (status == null) {
          updated.remove('invitation');
        } else {
          updated['invitation'] = {'status': status, 'expires_at': expiresAt};
        }
        return updated;
      })
      .toList(growable: false);
  controller.vaultMembers = controller.rows;
}

Future<void> _scrollMembersToTop(WidgetTester tester) async {
  await tester.drag(find.byType(ListView).last, const Offset(0, 800));
  await tester.pumpAndSettle();
}

Future<void> _openMembers(
  WidgetTester tester,
  _MemberController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: AppShell(controller: controller),
    ),
  );
  await tester.pump();
  if (find.byKey(const ValueKey('cloud_settings')).evaluate().isNotEmpty) {
    await openSettingsCategory(tester, 'vaults', ifAvailable: true);
  }
  await tester.pumpAndSettle();
  final label =
      controller.activeVault?.role == 'owner' &&
          controller.activeVault?.canWrite == true
      ? 'Manage Vault members'
      : 'View Vault members';
  final membersButton = find.text(label);
  await tester.ensureVisible(membersButton);
  await tester.pumpAndSettle();
  await tester.tap(membersButton);
  await tester.pumpAndSettle();
}

Future<(_MemberController, ClientDatabase)> _createController({
  Duration presenceRefreshInterval = const Duration(seconds: 30),
}) async {
  final sodium = await SodiumSumoInit.init();
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final controller =
      _MemberController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
          presenceRefreshInterval: presenceRefreshInterval,
        )
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.settings
        ..activeVault = const VaultDescriptor(
          id: _vaultId,
          role: 'owner',
          activeKeyEpoch: '3',
          membershipVersion: '7',
        )
        ..vaultMembers = [
          {
            'user_id': _ownerId,
            'username': 'owner@example.test',
            'role': 'owner',
            'state': 'active',
          },
          {
            'user_id': _editorId,
            'username': 'editor@example.test',
            'role': 'editor',
            'state': 'active',
          },
          {
            'user_id': _viewerId,
            'username': 'viewer@example.test',
            'role': 'viewer',
            'state': 'active',
          },
          {
            'user_id': _pendingId,
            'username': 'pending@example.test',
            'role': 'editor',
            'state': 'invited',
            'invitation': {
              'status': 'pending',
              'expires_at': '2026-10-05T12:30:00Z',
            },
          },
        ];
  controller.rows = List<Map<String, dynamic>>.from(controller.vaultMembers);
  return (controller, database);
}

class _MemberController extends AppController {
  _MemberController({
    required super.sodium,
    required super.database,
    required super.secureStore,
    required Duration presenceRefreshInterval,
  }) : super(membersPresenceRefreshIntervalForTesting: presenceRefreshInterval);

  static const _descriptor = VaultDescriptor(
    id: _vaultId,
    role: 'owner',
    activeKeyEpoch: '3',
    membershipVersion: '7',
  );

  (String, String)? changedRole;
  String? revokedUserId;
  String? transferredUserId;
  bool failTransfer = false;
  late List<Map<String, dynamic>> rows;
  int memberRefreshCount = 0;
  int presenceListRefreshCount = 0;
  List<VaultPresenceDevice> presenceAfterListRefresh = const [];

  @override
  List<VaultDescriptor> get vaults => const [_descriptor];

  @override
  String get currentVaultName => 'Operations';

  @override
  Future<void> refreshVaultMembers({String? vaultId}) async {
    memberRefreshCount++;
    vaultMembers = rows;
    notifyListeners();
  }

  @override
  Future<void> refreshVaultPresenceList({String? vaultId}) async {
    presenceListRefreshCount++;
    vaultPresenceDevices = presenceAfterListRefresh;
    notifyListeners();
  }

  @override
  Future<void> changeVaultMemberRole({
    required String userId,
    required String role,
  }) async {
    changedRole = (userId, role);
    rows = rows
        .map(
          (member) =>
              member['user_id'] == userId ? {...member, 'role': role} : member,
        )
        .toList(growable: false);
    notifyListeners();
  }

  @override
  Future<void> revokeVaultMember(String userId) async {
    revokedUserId = userId;
    rows = rows
        .map(
          (member) => member['user_id'] == userId
              ? {...member, 'state': 'revoked'}
              : member,
        )
        .toList(growable: false);
    notifyListeners();
  }

  @override
  Future<void> transferVaultOwnership({required String newOwnerUserId}) async {
    if (failTransfer) throw StateError('synthetic transfer failure');
    transferredUserId = newOwnerUserId;
    rows = rows
        .map((member) {
          if (member['user_id'] == _ownerId) {
            return {...member, 'role': 'editor'};
          }
          if (member['user_id'] == newOwnerUserId) {
            return {...member, 'role': 'owner'};
          }
          return member;
        })
        .toList(growable: false);
    vaultMembers = rows;
    activeVault = const VaultDescriptor(
      id: _vaultId,
      role: 'editor',
      activeKeyEpoch: '4',
      membershipVersion: '8',
    );
    notifyListeners();
  }

  @override
  String friendlyError(Object error) => error.toString();
}
