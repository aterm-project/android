import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/main.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

const _vaultId = '22222222-2222-4222-8222-222222222222';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'audit page localizes and scopes actions, errors, and empty state',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final api = _WidgetAuditApi();
      final controller =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..api = api
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.audit
            ..activeVault = const VaultDescriptor(
              id: _vaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            );
      final semantics = tester.ensureSemantics();

      try {
        await tester.pumpWidget(AtermiusApp(controller: controller));
        final pendingLoad = controller.loadAudit();
        expect(controller.auditLoading, isTrue);
        expect(controller.auditPageEvents, isEmpty);
        await tester.pump();
        expect(find.text('Reading audit records…'), findsOneWidget);

        api.response.complete(
          AuditPage(events: _allAuditEvents, nextCursor: null, hasMore: false),
        );
        await pendingLoad;
        await tester.pump();
        expect(find.text('Account created'), findsOneWidget);
        expect(find.text('Signed in'), findsOneWidget);
        expect(find.text('Sign-in failed'), findsOneWidget);
        expect(find.text('Signed out'), findsOneWidget);
        expect(find.text('Refresh credential replay detected; the related sessions were revoked'), findsOneWidget);
        for (final label in _accountAuditLabels) {
          expect(
            find.text(label),
            findsOneWidget,
            reason: 'missing account action label: $label',
          );
        }
        for (final label in _vaultAuditLabels) {
          expect(
            find.text(label),
            findsNothing,
            reason: 'Vault action leaked into account scope: $label',
          );
        }

        api.pages.add(
          AuditPage(events: _allAuditEvents, nextCursor: null, hasMore: false),
        );
        await tester.tap(find.text('Current Vault'));
        await tester.pumpAndSettle();
        expect(find.text('Account created'), findsNothing);
        expect(find.text('Signed in'), findsNothing);
        expect(find.text('Sign-in failed'), findsNothing);
        expect(find.text('Signed out'), findsNothing);
        expect(find.text('Refresh credential replay detected; the related sessions were revoked'), findsNothing);
        for (final label in _accountAuditLabels) {
          expect(
            find.text(label),
            findsNothing,
            reason: 'account action leaked into Vault scope: $label',
          );
        }
        for (final label in _vaultAuditLabels) {
          expect(
            find.text(label),
            findsOneWidget,
            reason: 'missing Vault action label: $label',
          );
        }
        expect(find.textContaining('当前显示 Personal vault 的事件'), findsOneWidget);

        api.errors.add(
          const ApiException(
            statusCode: 410,
            code: 'AUDIT_CURSOR_EXPIRED',
            message: 'expired',
          ),
        );
        api.pages.add(
          const AuditPage(events: [], nextCursor: null, hasMore: false),
        );
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(find.text("Couldn't load audit records"), findsOneWidget);
        expect(find.bySemanticsLabel("Couldn't load audit records"), findsOneWidget);
        expect(find.textContaining('游标已过期'), findsOneWidget);

        await tester.tap(find.text('Retry from the first page'));
        await tester.pumpAndSettle();
        expect(find.text('No audit records in the current scope'), findsOneWidget);
        expect(find.text("Couldn't load audit records"), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
        await database.close();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );
}

class _WidgetAuditApi extends ApiClient {
  _WidgetAuditApi()
    : super(
        baseUrl: 'https://audit-widget.example.test',
        client: MockClient((request) async {
          fail('Unexpected request ${request.method} ${request.url}');
        }),
      );

  final Completer<AuditPage> response = Completer<AuditPage>();
  final List<AuditPage> pages = [];
  final List<ApiException> errors = [];

  @override
  Future<AuditPage> audit({String? cursor, int limit = 100}) async {
    if (!response.isCompleted) return response.future;
    if (errors.isNotEmpty) throw errors.removeAt(0);
    if (pages.isEmpty) throw StateError('No fake audit page configured');
    return pages.removeAt(0);
  }
}

final _accountEvent = AuditEvent(
  eventId: '1',
  scope: 'account',
  vaultId: null,
  actorUserId: '33333333-3333-4333-8333-333333333333',
  actorDeviceId: null,
  action: 'account.created',
  resourceType: 'account',
  resourceId: null,
  result: 'success',
  occurredAt: DateTime.utc(2026, 9, 27),
  source: 'api',
);

final _loginSucceededEvent = AuditEvent(
  eventId: '8',
  scope: 'account',
  vaultId: null,
  actorUserId: '33333333-3333-4333-8333-333333333333',
  actorDeviceId: '44444444-4444-4444-8444-444444444444',
  action: 'auth.login_succeeded',
  resourceType: 'session',
  resourceId: '88888888-8888-4888-8888-888888888888',
  result: 'success',
  occurredAt: DateTime.utc(2026, 9, 27, 12, 6),
  source: 'api',
);

final _loginFailedEvent = AuditEvent(
  eventId: '9',
  scope: 'account',
  vaultId: null,
  actorUserId: null,
  actorDeviceId: null,
  action: 'auth.login_failed',
  resourceType: 'account',
  resourceId: null,
  result: 'failure',
  occurredAt: DateTime.utc(2026, 9, 27, 12, 7),
  source: 'api',
);

final _logoutEvent = AuditEvent(
  eventId: '6',
  scope: 'account',
  vaultId: null,
  actorUserId: '33333333-3333-4333-8333-333333333333',
  actorDeviceId: '44444444-4444-4444-8444-444444444444',
  action: 'auth.logout_succeeded',
  resourceType: 'session',
  resourceId: '66666666-6666-4666-8666-666666666666',
  result: 'success',
  occurredAt: DateTime.utc(2026, 9, 27, 12, 4),
  source: 'api',
);

final _refreshReuseEvent = AuditEvent(
  eventId: '7',
  scope: 'account',
  vaultId: null,
  actorUserId: null,
  actorDeviceId: null,
  action: 'auth.refresh_reuse_detected',
  resourceType: 'session_family',
  resourceId: '77777777-7777-4777-8777-777777777777',
  result: 'failure',
  occurredAt: DateTime.utc(2026, 9, 27, 12, 5),
  source: 'api',
);

final _vaultEvent = AuditEvent(
  eventId: '2',
  scope: 'vault',
  vaultId: _vaultId,
  actorUserId: '33333333-3333-4333-8333-333333333333',
  actorDeviceId: '44444444-4444-4444-8444-444444444444',
  action: 'vault.key_rotated',
  resourceType: 'vault',
  resourceId: _vaultId,
  result: 'success',
  occurredAt: DateTime.utc(2026, 9, 27, 12),
  source: 'api',
);

final _memberRoleEvent = AuditEvent(
  eventId: '3',
  scope: 'vault',
  vaultId: _vaultId,
  actorUserId: '33333333-3333-4333-8333-333333333333',
  actorDeviceId: '44444444-4444-4444-8444-444444444444',
  action: 'vault.member_role_changed',
  resourceType: 'membership',
  resourceId: '55555555-5555-4555-8555-555555555555',
  result: 'success',
  occurredAt: DateTime.utc(2026, 9, 27, 12, 1),
  source: 'api',
);

final _memberRevokedEvent = AuditEvent(
  eventId: '4',
  scope: 'vault',
  vaultId: _vaultId,
  actorUserId: '33333333-3333-4333-8333-333333333333',
  actorDeviceId: '44444444-4444-4444-8444-444444444444',
  action: 'vault.member_revoked',
  resourceType: 'membership',
  resourceId: '55555555-5555-4555-8555-555555555555',
  result: 'success',
  occurredAt: DateTime.utc(2026, 9, 27, 12, 2),
  source: 'api',
);

final _ownershipTransferredEvent = AuditEvent(
  eventId: '5',
  scope: 'vault',
  vaultId: _vaultId,
  actorUserId: '33333333-3333-4333-8333-333333333333',
  actorDeviceId: '44444444-4444-4444-8444-444444444444',
  action: 'vault.ownership_transferred',
  resourceType: 'membership',
  resourceId: '55555555-5555-4555-8555-555555555555',
  result: 'success',
  occurredAt: DateTime.utc(2026, 9, 27, 12, 3),
  source: 'api',
);

final _vaultConflictResolvedEvent = AuditEvent(
  eventId: '29',
  scope: 'vault',
  vaultId: _vaultId,
  actorUserId: '33333333-3333-4333-8333-333333333333',
  actorDeviceId: '44444444-4444-4444-8444-444444444444',
  action: 'vault.conflict_resolved',
  resourceType: 'conflict',
  resourceId: '99999999-9999-4999-8999-999999999999',
  result: 'success',
  occurredAt: DateTime.utc(2026, 9, 27, 12, 10),
  source: 'api',
);

final _vaultSyncBatchCommittedEvent = AuditEvent(
  eventId: '30',
  scope: 'vault',
  vaultId: _vaultId,
  actorUserId: '33333333-3333-4333-8333-333333333333',
  actorDeviceId: '44444444-4444-4444-8444-444444444444',
  action: 'vault.sync_batch_committed',
  resourceType: 'sync_batch',
  resourceId: null,
  result: 'success',
  occurredAt: DateTime.utc(2026, 9, 27, 12, 11),
  source: 'api',
);

final _vaultPurgedEvent = AuditEvent(
  eventId: '31',
  scope: 'vault',
  vaultId: _vaultId,
  actorUserId: null,
  actorDeviceId: null,
  action: 'vault.purged',
  resourceType: 'vault',
  resourceId: _vaultId,
  result: 'success',
  occurredAt: DateTime.utc(2026, 9, 27, 12, 12),
  source: 'maintenance',
);

final _accountDeletionRequestedEvent = _accountAction(
  eventId: '10',
  action: 'account.deletion_requested',
  resourceId: null,
);

final _accountDeletionCancelledEvent = _accountAction(
  eventId: '11',
  action: 'account.deletion_cancelled',
  resourceId: null,
  actorDeviceId: null,
);

final _accountPurgedEvent = _accountAction(
  eventId: '12',
  action: 'account.purged',
  resourceId: null,
  actorUserId: null,
  actorDeviceId: null,
  source: 'maintenance',
);

final _accountRecoveredEvent = _accountAction(
  eventId: '13',
  action: 'auth.account_recovered',
);

final _accountRecoveryDisabledEvent = _accountAction(
  eventId: '14',
  action: 'auth.account_recovery_disabled',
);

final _accountRecoveryEnabledEvent = _accountAction(
  eventId: '15',
  action: 'auth.account_recovery_enabled',
);

final _accountRecoveryEnvelopesUpdatedEvent = _accountAction(
  eventId: '16',
  action: 'auth.account_recovery_key_envelopes_updated',
);

final _accountRecoveryRotatedEvent = _accountAction(
  eventId: '17',
  action: 'auth.account_recovery_rotated',
);

final _mfaLoginChallengeCreatedEvent = _accountAction(
  eventId: '31',
  action: 'auth.mfa_login_challenge_created',
);

final _mfaRecoveryCodesRotatedEvent = _accountAction(
  eventId: '32',
  action: 'auth.mfa_recovery_codes_rotated',
);

final _mfaResetByRecoveryEvent = _accountAction(
  eventId: '33',
  action: 'auth.mfa_reset_by_recovery',
);

final _mfaStateResetByRestoreEvent = _accountAction(
  eventId: '34',
  action: 'auth.mfa_state_reset_by_restore',
  actorDeviceId: null,
  source: 'maintenance',
);

final _mfaTotpDisabledEvent = _accountAction(
  eventId: '35',
  action: 'auth.mfa_totp_disabled',
);

final _mfaTotpEnabledEvent = _accountAction(
  eventId: '36',
  action: 'auth.mfa_totp_enabled',
);

final _passwordChangedEvent = _accountAction(
  eventId: '18',
  action: 'auth.password_changed',
);

final _passwordChangeFailedEvent = _accountAction(
  eventId: '19',
  action: 'auth.password_change_failed',
  result: 'failure',
);

final _relayTicketIssuedEvent = _accountAction(
  eventId: '20',
  action: 'relay.ticket_issued',
  resourceType: 'relay',
  resourceId: null,
);

final _relayConnectedEvent = _accountAction(
  eventId: '21',
  action: 'relay.connected',
  resourceType: 'relay',
  resourceId: null,
);

final _deviceRegisteredEvent = _accountAction(
  eventId: '27',
  action: 'device.registered',
  resourceType: 'device',
  resourceId: '44444444-4444-4444-8444-444444444444',
);

final _deviceRevokedEvent = _accountAction(
  eventId: '28',
  action: 'device.revoked',
  resourceType: 'device',
  resourceId: '44444444-4444-4444-8444-444444444444',
);

final _vaultInvitationCreatedEvent = _vaultAction(
  eventId: '23',
  action: 'vault.invitation_created',
  resourceType: 'invitation',
  resourceId: '22222222-2222-4222-8222-222222222223',
);

final _vaultCreatedEvent = _vaultAction(
  eventId: '22',
  action: 'vault.created',
  resourceType: 'vault',
  resourceId: _vaultId,
);

final _vaultInvitationAcceptedEvent = _vaultAction(
  eventId: '26',
  action: 'vault.invitation_accepted',
  resourceType: 'invitation',
  resourceId: '22222222-2222-4222-8222-222222222224',
);

final _vaultDeletionRequestedEvent = _vaultAction(
  eventId: '24',
  action: 'vault.deletion_requested',
  resourceType: 'vault',
  resourceId: _vaultId,
);

final _vaultDeletionCancelledEvent = _vaultAction(
  eventId: '25',
  action: 'vault.deletion_cancelled',
  resourceType: 'vault',
  resourceId: _vaultId,
);

AuditEvent _accountAction({
  required String eventId,
  required String action,
  String resourceType = 'account',
  String? resourceId = '33333333-3333-4333-8333-333333333333',
  String? actorUserId = '33333333-3333-4333-8333-333333333333',
  String? actorDeviceId = '44444444-4444-4444-8444-444444444444',
  String result = 'success',
  String source = 'api',
}) => AuditEvent(
  eventId: eventId,
  scope: 'account',
  vaultId: null,
  actorUserId: actorUserId,
  actorDeviceId: actorDeviceId,
  action: action,
  resourceType: resourceType,
  resourceId: resourceId,
  result: result,
  occurredAt: DateTime.utc(2026, 9, 27, 12, 8),
  source: source,
);

AuditEvent _vaultAction({
  required String eventId,
  required String action,
  required String resourceType,
  required String resourceId,
}) => AuditEvent(
  eventId: eventId,
  scope: 'vault',
  vaultId: _vaultId,
  actorUserId: '33333333-3333-4333-8333-333333333333',
  actorDeviceId: '44444444-4444-4444-8444-444444444444',
  action: action,
  resourceType: resourceType,
  resourceId: resourceId,
  result: 'success',
  occurredAt: DateTime.utc(2026, 9, 27, 12, 9),
  source: 'api',
);

final _allAuditEvents = <AuditEvent>[
  _accountEvent,
  _loginSucceededEvent,
  _loginFailedEvent,
  _logoutEvent,
  _refreshReuseEvent,
  _accountDeletionRequestedEvent,
  _accountDeletionCancelledEvent,
  _accountPurgedEvent,
  _accountRecoveredEvent,
  _accountRecoveryDisabledEvent,
  _accountRecoveryEnabledEvent,
  _accountRecoveryEnvelopesUpdatedEvent,
  _accountRecoveryRotatedEvent,
  _mfaLoginChallengeCreatedEvent,
  _mfaRecoveryCodesRotatedEvent,
  _mfaResetByRecoveryEvent,
  _mfaStateResetByRestoreEvent,
  _mfaTotpDisabledEvent,
  _mfaTotpEnabledEvent,
  _passwordChangedEvent,
  _passwordChangeFailedEvent,
  _relayTicketIssuedEvent,
  _relayConnectedEvent,
  _deviceRegisteredEvent,
  _deviceRevokedEvent,
  _vaultEvent,
  _vaultCreatedEvent,
  _vaultInvitationCreatedEvent,
  _vaultInvitationAcceptedEvent,
  _vaultDeletionRequestedEvent,
  _vaultDeletionCancelledEvent,
  _memberRoleEvent,
  _memberRevokedEvent,
  _vaultConflictResolvedEvent,
  _vaultSyncBatchCommittedEvent,
  _vaultPurgedEvent,
  _ownershipTransferredEvent,
];

const _accountAuditLabels = <String>[
  'Account created',
  'Signed in',
  'Sign-in failed',
  'Signed out',
  'Refresh credential replay detected; the related sessions were revoked',
  'Account deletion scheduled',
  'Account deletion cancelled',
  'Account data cleared',
  'Account recovery completed',
  'Account recovery disabled',
  'Account recovery enabled',
  'Recovery key device envelopes updated',
  'Account recovery key rotated',
  'Multi-factor sign-in started',
  'Multi-factor recovery codes rotated',
  'Multi-factor authentication was reset after account recovery',
  'Multi-factor authentication was reset after archive restore',
  'Multi-factor authentication turned off',
  'Multi-factor authentication enabled',
  'Master password changed',
  "Couldn't change the master password",
  'SSH Relay connection ticket issued',
  'SSH Relay connected',
  'Device approved',
  'Device revoked',
];

const _vaultAuditLabels = <String>[
  'Vault created',
  'Vault key rotated',
  'Vault encrypted data synced',
  'Member invitation created',
  'Member invitation accepted',
  'Vault deletion scheduled',
  'Vault deletion cancelled',
  'Member permissions changed',
  'Member access revoked',
  'Vault conflict resolved',
  'Vault ownership transferred',
  'Vault purged',
];
