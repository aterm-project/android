import 'support/settings_navigation.dart';

import 'dart:async';
import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

const _adminId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _activeId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _deletingId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _disabledId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const _sessionId = '11111111-1111-4111-8111-111111111111';
const _secondSessionId = '22222222-2222-4222-8222-222222222222';
const _deviceId = '33333333-3333-4333-8333-333333333333';
const _otherDeviceId = '44444444-4444-4444-8444-444444444444';
const _invitationId = '55555555-5555-4555-8555-555555555555';
const _secondInvitationId = '66666666-6666-4666-8666-666666666666';
const _thirdInvitationId = '77777777-7777-4777-8777-777777777777';
final _invitationToken = base64Url
    .encode(List<int>.generate(32, (index) => index))
    .replaceAll('=', '');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'admin account API lists and mutates accounts with bearer auth',
    () async {
      final requests = <http.Request>[];
      final api = ApiClient(
        baseUrl: 'https://admin-accounts.example.test/root',
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') {
            if (request.url.path.endsWith('/sessions')) {
              return http.Response(
                jsonEncode({
                  'sessions': [_sessionJson(_sessionId, active: false)],
                  'total': 51,
                  'limit': 50,
                  'offset': 0,
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response(
              jsonEncode({
                'accounts': [_accountJson(_activeId)],
                'total': 51,
                'limit': 50,
                'offset': 0,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.method == 'PUT') {
            return http.Response(
              jsonEncode({
                'account_id': _activeId,
                'status': 'disabled',
                'revoked_sessions': 3,
                'updated_at': '2026-09-29T14:00:00Z',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.url.path.endsWith('/$_sessionId/revoke')) {
            return http.Response(
              jsonEncode({
                'account_id': _activeId,
                'session_id': _sessionId,
                'revoked': true,
                'updated_at': '2026-09-29T14:02:00Z',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'account_id': _activeId,
              'revoked_sessions': 2,
              'updated_at': '2026-09-29T14:01:00Z',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..accessToken = 'session-access-token';
      try {
        final page = await api.adminAccounts();
        expect(page.accounts.single.userId, _activeId);
        expect(page.accounts.single.activeDeviceCount, 2);
        expect(page.accounts.single.activeSessionCount, 3);
        expect(page.hasNext, isTrue);
        expect(requests.single.url.path, '/root/api/v1/admin/accounts');
        expect(requests.single.url.queryParameters, {
          'limit': '50',
          'offset': '0',
        });
        expect(
          requests.single.headers['authorization'],
          'Bearer session-access-token',
        );

        final status = await api.setAdminAccountStatus(
          userId: _activeId,
          status: 'disabled',
        );
        expect(status.accountId, _activeId);
        expect(status.status, 'disabled');
        expect(status.revokedSessions, 3);
        expect(requests.last.method, 'PUT');
        expect(
          requests.last.url.path,
          '/root/api/v1/admin/accounts/$_activeId/status',
        );
        expect(jsonDecode(requests.last.body), {'status': 'disabled'});
        expect(
          requests.last.headers['authorization'],
          'Bearer session-access-token',
        );

        final sessions = await api.adminAccountSessions(userId: _activeId);
        expect(sessions.sessions.single.sessionId, _sessionId);
        expect(sessions.sessions.single.deviceName, 'Linux workstation');
        expect(sessions.sessions.single.active, isFalse);
        expect(sessions.sessions.single.revokedAt, isNull);
        final missingEffectiveState = _sessionJson(_sessionId)
          ..remove('active');
        expect(
          () => AdminAccountSessionMetadata.fromJson(missingEffectiveState),
          throwsFormatException,
        );
        expect(sessions.hasNext, isTrue);
        expect(
          requests.last.url.path,
          '/root/api/v1/admin/accounts/$_activeId/sessions',
        );
        expect(requests.last.url.queryParameters, {
          'limit': '50',
          'offset': '0',
        });
        expect(
          requests.last.headers['authorization'],
          'Bearer session-access-token',
        );

        final individual = await api.revokeAdminAccountSession(
          userId: _activeId,
          sessionId: _sessionId,
        );
        expect(individual.accountId, _activeId);
        expect(individual.sessionId, _sessionId);
        expect(individual.revoked, isTrue);
        expect(requests.last.method, 'POST');
        expect(
          requests.last.url.path,
          '/root/api/v1/admin/accounts/$_activeId/sessions/$_sessionId/revoke',
        );
        expect(
          requests.last.headers['authorization'],
          'Bearer session-access-token',
        );

        final revoked = await api.revokeAdminAccountSessions(userId: _activeId);
        expect(revoked.accountId, _activeId);
        expect(revoked.revokedSessions, 2);
        expect(requests.last.method, 'POST');
        expect(
          requests.last.url.path,
          '/root/api/v1/admin/accounts/$_activeId/sessions/revoke',
        );
        expect(
          requests.last.headers['authorization'],
          'Bearer session-access-token',
        );
        await expectLater(
          api.setAdminAccountStatus(
            userId: _activeId.toUpperCase(),
            status: 'disabled',
          ),
          throwsArgumentError,
        );
        await expectLater(
          api.setAdminAccountStatus(userId: _activeId, status: 'deleting'),
          throwsArgumentError,
        );
      } finally {
        api.close();
      }
    },
  );

  test(
    'admin account invitation API uses the agreed DTOs and routes',
    () async {
      final requests = <http.Request>[];
      final api = ApiClient(
        baseUrl: 'https://admin-accounts.example.test/root',
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'invitations': [_invitationJson(_invitationId)],
                'total': 51,
                'limit': 50,
                'offset': 0,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.url.path.endsWith('/revoke')) {
            return http.Response(
              jsonEncode({
                'invitation_id': _invitationId,
                'status': 'revoked',
                'revoked_at': '2026-10-01T10:00:00Z',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'invitation': {
                'invitation_id': _secondInvitationId,
                'username': 'new.user@example.test',
                'created_at': '2026-10-01T09:00:00Z',
                'expires_at': '2026-10-08T09:00:00Z',
                'token': _invitationToken,
              },
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..accessToken = 'session-access-token';
      try {
        final page = await api.adminAccountInvitations();
        expect(page.invitations.single.invitationId, _invitationId);
        expect(page.invitations.single.username, 'alice@example.test');
        expect(page.invitations.single.status, 'pending');
        expect(page.hasNext, isTrue);
        expect(
          requests.single.url.path,
          '/root/api/v1/admin/account-invitations',
        );
        expect(requests.single.url.queryParameters, {
          'limit': '50',
          'offset': '0',
        });
        expect(
          requests.single.headers['authorization'],
          'Bearer session-access-token',
        );
        expect(
          () => AdminAccountInvitationMetadata.fromJson({
            ..._invitationJson(_invitationId),
            'token': 'must-not-appear-in-list',
          }),
          throwsFormatException,
        );
        expect(
          () => AdminAccountInvitationIssueReceipt.fromJson({
            'invitation': {
              'invitation_id': _secondInvitationId,
              'username': 'new.user@example.test',
              'created_at': '2026-10-01T09:00:00Z',
              'expires_at': '2026-10-08T09:00:00Z',
              'token': 'not-a-canonical-invitation-token',
            },
          }),
          throwsFormatException,
        );

        final issued = await api.createAdminAccountInvitation(
          username: ' New.User@Example.Test ',
          expiresInSeconds: const Duration(days: 7).inSeconds,
        );
        expect(issued.invitationId, _secondInvitationId);
        expect(issued.username, 'new.user@example.test');
        expect(issued.token, _invitationToken);
        expect(requests.last.method, 'POST');
        expect(
          requests.last.url.path,
          '/root/api/v1/admin/account-invitations',
        );
        expect(jsonDecode(requests.last.body), {
          'username': 'new.user@example.test',
          'expires_in_seconds': 604800,
        });
        expect(
          requests.last.headers['authorization'],
          'Bearer session-access-token',
        );

        final revoked = await api.revokeAdminAccountInvitation(
          invitationId: _invitationId,
        );
        expect(revoked.invitationId, _invitationId);
        expect(revoked.status, 'revoked');
        expect(requests.last.method, 'POST');
        expect(
          requests.last.url.path,
          '/root/api/v1/admin/account-invitations/$_invitationId/revoke',
        );
        expect(requests.last.body, isEmpty);

        await expectLater(
          api.adminAccountInvitations(limit: 101),
          throwsArgumentError,
        );
        await expectLater(
          api.createAdminAccountInvitation(
            username: 'alice@example.test',
            expiresInSeconds: 59,
          ),
          throwsArgumentError,
        );
        await expectLater(
          api.revokeAdminAccountInvitation(
            invitationId: _invitationId.replaceFirst('5', 'A'),
          ),
          throwsArgumentError,
        );
      } finally {
        api.close();
      }
    },
  );

  testWidgets(
    'admin account directory loads, pages and hides self/deleting actions',
    (tester) async {
      final harness = await _Harness.create(sodium, isAdmin: true);
      harness.api.pages.addAll([
        _accountPage(
          [
            _account(_adminId, 'admin@example.test'),
            _account(_activeId, 'alice@example.test'),
            _account(_deletingId, 'deleting@example.test', status: 'deleting'),
          ],
          total: 51,
          offset: 0,
        ),
        _accountPage(
          [_account(_disabledId, 'dana@example.test', status: 'disabled')],
          total: 51,
          offset: 50,
        ),
        _accountPage(
          [
            _account(_adminId, 'admin@example.test'),
            _account(_activeId, 'alice@example.test'),
            _account(_deletingId, 'deleting@example.test', status: 'deleting'),
          ],
          total: 51,
          offset: 0,
        ),
      ]);
      try {
        await _pumpSettings(tester, harness.app);
        expect(find.text('Instance accounts and sessions'), findsOneWidget);
        await _tapAdminAccountsLoad(tester);
        await tester.pumpAndSettle();
        expect(find.text('alice@example.test'), findsOneWidget);
        expect(find.text('Active devices'), findsNWidgets(3));
        expect(find.text('Active sessions'), findsNWidgets(3));
        expect(find.text('Disable account'), findsOneWidget);
        expect(find.text('Revoke all sessions'), findsOneWidget);
        expect(find.text('View sessions'), findsOneWidget);
        expect(
          find.text(
            'Current signed-in account · administrative actions hidden',
          ),
          findsOneWidget,
        );
        expect(
          find.text('Deleting account · administrative actions unavailable'),
          findsOneWidget,
        );
        expect(harness.api.listOffsets, [0]);

        await tester.ensureVisible(find.text('Next'));
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        expect(harness.api.listOffsets, [0, 50]);
        expect(find.text('dana@example.test'), findsOneWidget);
        expect(find.text('Re-enable account'), findsOneWidget);
        expect(find.text('Disable account'), findsNothing);

        await tester.ensureVisible(find.text('Previous'));
        await tester.tap(find.text('Previous'));
        await tester.pumpAndSettle();
        expect(harness.api.listOffsets, [0, 50, 0]);
        expect(find.text('alice@example.test'), findsOneWidget);
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets('account controls are hidden without instance admin policy', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: false);
    try {
      await _pumpSettings(tester, harness.app);
      expect(find.text('Instance accounts and sessions'), findsNothing);
      expect(find.text('Account invitations'), findsNothing);
      expect(find.text('Issue account invitation'), findsNothing);
      expect(find.text('Load admin accounts'), findsNothing);
      expect(find.text('Load account invitations'), findsNothing);
      expect(harness.api.listOffsets, isEmpty);
      expect(harness.api.invitationListOffsets, isEmpty);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets(
    'account invitation issue, one-time token copy, safe history and revoke',
    (tester) async {
      String? clipboardText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboardText = (call.arguments as Map)['text'] as String;
            }
            if (call.method == 'Clipboard.getData' && clipboardText != null) {
              return {'text': clipboardText};
            }
            return null;
          });
      final harness = await _Harness.create(sodium, isAdmin: true);
      harness.api.invitationPages.addAll([
        _invitationPage(
          [
            _invitation(_invitationId, 'alice@example.test'),
            _invitation(
              _secondInvitationId,
              'expired@example.test',
              status: 'expired',
            ),
            _invitation(
              _thirdInvitationId,
              'consumed@example.test',
              status: 'consumed',
            ),
            _invitation(
              '88888888-8888-4888-8888-888888888888',
              'revoked@example.test',
              status: 'revoked',
            ),
          ],
          total: 4,
          offset: 0,
        ),
        _invitationPage(
          [
            _invitation(_invitationId, 'alice@example.test'),
            _invitation(_secondInvitationId, 'new.user@example.test'),
            _invitation(
              _thirdInvitationId,
              'consumed@example.test',
              status: 'consumed',
            ),
          ],
          total: 3,
          offset: 0,
        ),
        _invitationPage(
          [
            _invitation(_invitationId, 'alice@example.test', status: 'revoked'),
            _invitation(_secondInvitationId, 'new.user@example.test'),
            _invitation(
              _thirdInvitationId,
              'consumed@example.test',
              status: 'consumed',
            ),
          ],
          total: 3,
          offset: 0,
        ),
      ]);
      harness.api.pages.addAll([
        _accountPage(
          [_account(_activeId, 'alice@example.test')],
          total: 1,
          offset: 0,
        ),
        _accountPage(
          [_account(_activeId, 'alice@example.test')],
          total: 1,
          offset: 0,
        ),
        _accountPage(
          [_account(_activeId, 'alice@example.test')],
          total: 1,
          offset: 0,
        ),
      ]);
      harness.api.invitationIssueReceipts.add(
        AdminAccountInvitationIssueReceipt(
          invitationId: _secondInvitationId,
          username: 'new.user@example.test',
          createdAt: DateTime.utc(2026, 10, 1, 9),
          expiresAt: DateTime.utc(2026, 10, 15, 9),
          token: _invitationToken,
        ),
      );
      try {
        await _pumpSettings(tester, harness.app);
        expect(find.text('Account invitations'), findsOneWidget);
        await tester.ensureVisible(find.text('Load account invitations'));
        await tester.tap(find.text('Load account invitations'));
        await tester.pumpAndSettle();
        expect(harness.api.invitationListOffsets, [0]);
        expect(find.text('Pending'), findsOneWidget);
        expect(find.text('Expired'), findsOneWidget);
        expect(find.text('Consumed'), findsOneWidget);
        expect(find.text('Revoked'), findsOneWidget);
        expect(find.text('Revoke invitation'), findsOneWidget);
        expect(find.text(_invitationToken), findsNothing);
        expect(find.text('Refresh account invitations'), findsOneWidget);

        await tester.ensureVisible(find.text('Issue account invitation'));
        await tester.tap(find.text('Issue account invitation'));
        await tester.pumpAndSettle();
        expect(find.text('Invitation username'), findsOneWidget);
        expect(find.text('Invitation expires in days'), findsOneWidget);
        expect(find.text('7 days'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('admin_account_invitation_expiry')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('14 days'));
        await tester.pumpAndSettle();
        expect(find.text('14 days'), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('admin_account_invitation_username')),
          ' New.User@Example.Test ',
        );
        await tester.tap(find.text('Create invitation'));
        await tester.pumpAndSettle();
        expect(harness.api.invitationIssues, [
          ('new.user@example.test', 1209600),
        ]);
        expect(find.text('One-time invitation token'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('admin_account_invitation_token_value')),
          findsOneWidget,
        );
        expect(find.text(_invitationToken), findsOneWidget);
        expect(harness.app.adminAccountInvitationToken, isNotNull);
        await tester.tap(find.text('Copy invitation token'));
        await tester.pumpAndSettle();
        expect(find.text(_invitationToken), findsNothing);
        expect(harness.app.adminAccountInvitationToken, isNull);
        expect((await Clipboard.getData('text/plain'))?.text, _invitationToken);
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(find.text('One-time invitation token'), findsNothing);

        final pendingRow = find.byKey(
          const ValueKey('admin_account_invitation_$_invitationId'),
        );
        final revokeButton = find.descendant(
          of: pendingRow,
          matching: find.text('Revoke invitation'),
        );
        await tester.ensureVisible(revokeButton);
        await tester.tap(revokeButton);
        await tester.pumpAndSettle();
        expect(find.text('Revoke account invitation?'), findsOneWidget);
        expect(harness.api.invitationRevocations, isEmpty);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        await tester.ensureVisible(revokeButton);
        await tester.tap(revokeButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Confirm revoke invitation'));
        await tester.pumpAndSettle();
        expect(harness.api.invitationRevocations, [_invitationId]);
        expect(harness.api.invitationListOffsets, [0, 0, 0]);
        expect(harness.api.listOffsets, [0, 0, 0]);
        expect(find.text('Revoked'), findsOneWidget);
        expect(find.text('Pending'), findsOneWidget);
        expect(find.text(_invitationToken), findsNothing);
      } finally {
        await _dispose(tester, harness);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      }
    },
  );

  testWidgets('account invitation loading error can be refreshed', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: true);
    harness.api.invitationErrors.add(
      const ApiException(
        statusCode: 403,
        code: 'INSTANCE_ADMIN_REQUIRED',
        message: 'Invitation list denied.',
      ),
    );
    harness.api.pages.addAll([
      _accountPage([], total: 0, offset: 0),
      _accountPage([], total: 0, offset: 0),
    ]);
    harness.api.invitationPages.add(_invitationPage([], total: 0, offset: 0));
    try {
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(find.text('Load account invitations'));
      await tester.tap(find.text('Load account invitations'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Invitation list denied.'), findsOneWidget);

      await tester.ensureVisible(find.text('Retry account invitations'));
      await tester.tap(find.text('Retry account invitations'));
      await tester.pumpAndSettle();
      expect(find.text('No account invitations found.'), findsOneWidget);
      expect(find.textContaining('Invitation list denied.'), findsNothing);
      expect(harness.api.invitationListOffsets, [0, 0]);
      expect(harness.api.listOffsets, [0, 0]);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets(
    'status change and session revoke require confirmation and refresh',
    (tester) async {
      final harness = await _Harness.create(sodium, isAdmin: true);
      harness.api.pages.addAll([
        _accountPage(
          [
            _account(_adminId, 'admin@example.test'),
            _account(_activeId, 'alice@example.test'),
          ],
          total: 2,
          offset: 0,
        ),
        _accountPage(
          [
            _account(_adminId, 'admin@example.test'),
            _account(_activeId, 'alice@example.test', status: 'disabled'),
          ],
          total: 2,
          offset: 0,
        ),
        _accountPage(
          [
            _account(_adminId, 'admin@example.test', activeSessions: 2),
            _account(
              _activeId,
              'alice@example.test',
              status: 'disabled',
              activeSessions: 0,
            ),
          ],
          total: 2,
          offset: 0,
        ),
      ]);
      harness.api.statusErrors.add(
        const ApiException(
          statusCode: 403,
          code: 'INSTANCE_ADMIN_REQUIRED',
          message: 'Account update denied.',
        ),
      );
      try {
        await _pumpSettings(tester, harness.app);
        await _tapAdminAccountsLoad(tester);
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('Disable account'));
        await tester.tap(find.text('Disable account'));
        await tester.pumpAndSettle();
        expect(find.text('Disable account?'), findsOneWidget);
        expect(
          find.textContaining('Cached device data will not be erased'),
          findsOneWidget,
        );
        expect(
          find.textContaining('existing direct SSH connections may continue'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Server sessions will be revoked'),
          findsOneWidget,
        );
        expect(harness.api.statusWrites, isEmpty);
        await tester.tap(find.widgetWithText(FilledButton, 'Disable account'));
        await tester.pumpAndSettle();
        expect(harness.api.statusWrites, [(_activeId, 'disabled')]);
        expect(find.textContaining('Account update denied.'), findsOneWidget);

        await tester.ensureVisible(find.text('Disable account'));
        await tester.tap(find.text('Disable account'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Disable account'));
        await tester.pumpAndSettle();
        expect(harness.api.statusWrites, [
          (_activeId, 'disabled'),
          (_activeId, 'disabled'),
        ]);
        expect(harness.api.listOffsets, [0, 0]);
        expect(find.text('Re-enable account'), findsOneWidget);
        expect(
          find.textContaining('status updated to disabled'),
          findsOneWidget,
        );

        await tester.ensureVisible(find.text('Revoke all sessions'));
        await tester.tap(find.text('Revoke all sessions'));
        await tester.pumpAndSettle();
        expect(find.text('Revoke all sessions?'), findsOneWidget);
        expect(harness.api.sessionRevocations, isEmpty);
        await tester.tap(find.widgetWithText(FilledButton, 'Revoke sessions'));
        await tester.pumpAndSettle();
        expect(harness.api.sessionRevocations, [_activeId]);
        expect(harness.api.listOffsets, [0, 0, 0]);
        expect(find.text('0'), findsOneWidget);
        expect(find.textContaining('2 sessions revoked'), findsOneWidget);
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets(
    'status conflict refreshes stale deleting account and clears sessions',
    (tester) async {
      final harness = await _Harness.create(sodium, isAdmin: true);
      harness.api.pages.addAll([
        _accountPage(
          [_account(_activeId, 'alice@example.test', activeSessions: 1)],
          total: 1,
          offset: 0,
        ),
        _accountPage(
          [
            _account(
              _activeId,
              'alice@example.test',
              status: 'deleting',
              activeSessions: 1,
            ),
          ],
          total: 1,
          offset: 0,
        ),
      ]);
      harness.api.sessionPages.addAll([
        _accountSessionsPage(
          [_adminSession(_sessionId, active: true, revokedAt: null)],
          total: 1,
          offset: 0,
        ),
        _accountSessionsPage(
          [
            _adminSession(
              _sessionId,
              active: false,
              revokedAt: DateTime.utc(2026, 10, 8, 10),
            ),
          ],
          total: 1,
          offset: 0,
        ),
      ]);
      harness.api.statusErrors.add(
        const ApiException(
          statusCode: 409,
          code: 'ACCOUNT_DELETING',
          message:
              'a deleting account cannot be changed by instance administration',
        ),
      );
      try {
        await _pumpSettings(tester, harness.app);
        await _tapAdminAccountsLoad(tester);
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('View sessions'));
        await tester.tap(find.text('View sessions'));
        await tester.pumpAndSettle();
        expect(find.text(_sessionId), findsOneWidget);
        expect(harness.app.adminAccountSessionsPage?.sessions, hasLength(1));

        await tester.ensureVisible(find.text('Disable account'));
        await tester.tap(find.text('Disable account'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Disable account'));
        await tester.pumpAndSettle();

        expect(harness.api.statusWrites, [(_activeId, 'disabled')]);
        expect(harness.api.listOffsets, [0, 0]);
        expect(harness.api.sessionOffsets, [(_activeId, 0), (_activeId, 0)]);
        expect(
          harness.app.adminAccountsPage?.accounts.single.status,
          'deleting',
        );
        expect(harness.app.adminAccountSessionsUserId, isNull);
        expect(harness.app.adminAccountSessionsPage, isNull);
        expect(harness.app.adminAccountActionBusyId, isNull);
        expect(
          harness.app.adminAccountActionError,
          contains('ACCOUNT_DELETING'),
        );
        expect(harness.app.adminAccountActionNotice, isNull);
        expect(find.text('deleting'), findsOneWidget);
        expect(
          find.text('Deleting account · administrative actions unavailable'),
          findsOneWidget,
        );
        expect(find.textContaining('ACCOUNT_DELETING'), findsOneWidget);
        expect(find.text('Disable account'), findsNothing);
        expect(find.text('Re-enable account'), findsNothing);
        expect(find.text('Revoke all sessions'), findsNothing);
        expect(find.text('View sessions'), findsNothing);
        expect(find.text(_sessionId), findsNothing);
        expect(find.text('Account sessions'), findsNothing);
        expect(find.textContaining('status updated to'), findsNothing);
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets('admin account list shows loading and access errors with retry', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: true);
    final pendingPage = Completer<AdminAccountPage>();
    harness.api.pendingPage = pendingPage.future;
    try {
      await _pumpSettings(tester, harness.app);
      await _tapAdminAccountsLoad(tester);
      await tester.pump();
      expect(find.text('Reading admin account list…'), findsOneWidget);
      pendingPage.complete(
        _accountPage(
          [_account(_activeId, 'alice@example.test')],
          total: 1,
          offset: 0,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('alice@example.test'), findsOneWidget);

      harness.api.errors.add(
        const ApiException(
          statusCode: 403,
          code: 'INSTANCE_ADMIN_REQUIRED',
          message: 'Account list denied.',
        ),
      );
      await _tapAdminAccountsLoad(tester, refresh: true);
      await tester.pumpAndSettle();
      expect(find.textContaining('Couldn\'t load the account list:'), findsOneWidget);
      expect(find.textContaining('Account list denied.'), findsOneWidget);

      harness.api.pages.add(
        _accountPage(
          [_account(_activeId, 'alice@example.test')],
          total: 1,
          offset: 0,
        ),
      );
      await tester.ensureVisible(find.text('Retry account list'));
      await tester.tap(find.text('Retry account list'));
      await tester.pumpAndSettle();
      expect(find.text('alice@example.test'), findsOneWidget);
      expect(find.textContaining('Couldn\'t load the account list:'), findsNothing);
    } finally {
      if (!pendingPage.isCompleted) {
        pendingPage.completeError(StateError('test disposed'));
      }
      await _dispose(tester, harness);
    }
  });

  testWidgets(
    'expanded sessions page, individual revoke confirmation and pagination',
    (tester) async {
      final harness = await _Harness.create(sodium, isAdmin: true);
      harness.api.pages.addAll([
        _accountPage(
          [_account(_activeId, 'alice@example.test')],
          total: 1,
          offset: 0,
        ),
        _accountPage(
          [_account(_activeId, 'alice@example.test', activeSessions: 1)],
          total: 1,
          offset: 0,
        ),
      ]);
      harness.api.sessionPages.addAll([
        _accountSessionsPage(
          [
            _adminSession(_sessionId, active: true, revokedAt: null),
            _adminSession(_secondSessionId, active: false, revokedAt: null),
          ],
          total: 51,
          offset: 0,
        ),
        _accountSessionsPage(
          [
            _adminSession(
              _secondSessionId,
              active: false,
              revokedAt: DateTime.utc(2026, 9, 29),
            ),
          ],
          total: 51,
          offset: 50,
        ),
        _accountSessionsPage(
          [
            _adminSession(_sessionId, active: true, revokedAt: null),
            _adminSession(_secondSessionId, active: false, revokedAt: null),
          ],
          total: 51,
          offset: 0,
        ),
        _accountSessionsPage(
          [
            _adminSession(
              _sessionId,
              active: false,
              revokedAt: DateTime.utc(2026, 9, 29, 14),
            ),
            _adminSession(_secondSessionId, active: false, revokedAt: null),
          ],
          total: 51,
          offset: 0,
        ),
      ]);
      try {
        await _pumpSettings(tester, harness.app);
        await _tapAdminAccountsLoad(tester);
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('View sessions'));
        await tester.tap(find.text('View sessions'));
        await tester.pumpAndSettle();
        expect(harness.api.sessionOffsets, [(_activeId, 0)]);
        expect(find.text('Linux workstation'), findsOneWidget);
        expect(find.text(_sessionId), findsOneWidget);
        expect(find.text(_deviceId), findsOneWidget);
        expect(find.text('inactive'), findsOneWidget);
        expect(find.text('Device with ineffective session'), findsOneWidget);
        expect(find.text('Revoke session'), findsOneWidget);
        expect(find.text('Access expires'), findsNWidgets(2));
        expect(find.text('Refresh expires'), findsNWidgets(2));
        expect(find.text('IP address'), findsNothing);
        expect(find.textContaining('token hash'), findsNothing);

        await tester.ensureVisible(find.text('Next sessions'));
        await tester.tap(find.text('Next sessions'));
        await tester.pumpAndSettle();
        expect(harness.api.sessionOffsets, [(_activeId, 0), (_activeId, 50)]);
        expect(find.text(_secondSessionId), findsOneWidget);
        expect(find.text('Revoke session'), findsNothing);

        await tester.ensureVisible(find.text('Previous sessions'));
        await tester.tap(find.text('Previous sessions'));
        await tester.pumpAndSettle();
        expect(harness.api.sessionOffsets.last, (_activeId, 0));
        await tester.ensureVisible(find.text('Revoke session'));
        await tester.tap(find.text('Revoke session'));
        await tester.pumpAndSettle();
        expect(find.text('Revoke this session?'), findsOneWidget);
        expect(harness.api.individualRevocations, isEmpty);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('Revoke session'));
        await tester.tap(find.text('Revoke session'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Revoke session'));
        await tester.pumpAndSettle();
        expect(harness.api.individualRevocations, [(_activeId, _sessionId)]);
        expect(find.text('revoked'), findsOneWidget);
        expect(find.text('Revoke session'), findsNothing);
        expect(harness.api.sessionOffsets.last, (_activeId, 0));
        expect(harness.api.listOffsets, [0, 0]);
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets('expanded sessions loading, access errors and retry', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium, isAdmin: true);
    harness.api.pages.add(
      _accountPage(
        [_account(_activeId, 'alice@example.test')],
        total: 1,
        offset: 0,
      ),
    );
    final pending = Completer<AdminAccountSessionsPage>();
    harness.api.pendingSessionsPage = pending.future;
    try {
      await _pumpSettings(tester, harness.app);
      await _tapAdminAccountsLoad(tester);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('View sessions'));
      await tester.tap(find.text('View sessions'));
      await tester.pump();
      expect(find.text('Loading account sessions…'), findsOneWidget);
      pending.complete(
        _accountSessionsPage(
          [_adminSession(_sessionId, active: true, revokedAt: null)],
          total: 1,
          offset: 0,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(_sessionId), findsOneWidget);

      harness.api.sessionErrors.add(
        const ApiException(
          statusCode: 403,
          code: 'INSTANCE_ADMIN_REQUIRED',
          message: 'Session list denied.',
        ),
      );
      await tester.ensureVisible(find.byTooltip('Refresh account sessions'));
      await tester.tap(find.byTooltip('Refresh account sessions'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Couldn\'t load the session list:'), findsOneWidget);
      expect(find.textContaining('Session list denied.'), findsOneWidget);

      harness.api.sessionPages.add(
        _accountSessionsPage(
          [_adminSession(_sessionId, active: true, revokedAt: null)],
          total: 1,
          offset: 0,
        ),
      );
      await tester.ensureVisible(find.text('Retry session list'));
      await tester.tap(find.text('Retry session list'));
      await tester.pumpAndSettle();
      expect(find.text(_sessionId), findsOneWidget);
      expect(find.textContaining('Couldn\'t load the session list:'), findsNothing);
    } finally {
      if (!pending.isCompleted) pending.completeError(StateError('disposed'));
      await _dispose(tester, harness);
    }
  });
}

Future<void> _pumpSettings(WidgetTester tester, AppController app) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: AppShell(controller: app),
    ),
  );
  await tester.pump();
  if (find.byKey(const ValueKey('cloud_settings')).evaluate().isNotEmpty) {
    await openSettingsCategory(tester, 'access', ifAvailable: true);
    expect(tester.takeException(), isNull);
  }
  await tester.pump();
}

Future<void> _tapAdminAccountsLoad(
  WidgetTester tester, {
  bool refresh = false,
}) async {
  final button = find.byTooltip(
    refresh ? 'Refresh admin accounts' : 'Load admin accounts',
  );
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
}

Future<void> _dispose(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(const SizedBox.shrink());
  harness.app.dispose();
  harness.api.close();
  await harness.database.close();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

class _Harness {
  _Harness(this.database, this.api, this.app);

  final ClientDatabase database;
  final _WidgetAdminAccountsApi api;
  final AppController app;

  static Future<_Harness> create(
    SodiumSumo sodium, {
    required bool isAdmin,
  }) async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _WidgetAdminAccountsApi();
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..api = api
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.settings
          ..account = AccountProfile(
            accountId: _adminId,
            deviceId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
            accountKeyEnvelopeVersion: 1,
            accountKeyEnvelope: const {},
            policy: {'instance_admin': isAdmin},
          );
    return _Harness(database, api, app);
  }
}

class _WidgetAdminAccountsApi extends ApiClient {
  _WidgetAdminAccountsApi()
    : super(
        baseUrl: 'https://admin-accounts-widget.example.test',
        client: MockClient((_) async => throw StateError('Unexpected request')),
      );

  final List<int> listOffsets = [];
  final List<AdminAccountPage> pages = [];
  final List<ApiException> errors = [];
  final List<int> invitationListOffsets = [];
  final List<AdminAccountInvitationsPage> invitationPages = [];
  final List<ApiException> invitationErrors = [];
  final List<(String, int)> invitationIssues = [];
  final List<String> invitationRevocations = [];
  final List<AdminAccountInvitationIssueReceipt> invitationIssueReceipts = [];
  Future<AdminAccountInvitationsPage>? pendingInvitationPage;
  final List<ApiException> statusErrors = [];
  final List<ApiException> sessionErrors = [];
  final List<(String, String)> statusWrites = [];
  final List<String> sessionRevocations = [];
  final List<(String, int)> sessionOffsets = [];
  final List<(String, String)> individualRevocations = [];
  Future<AdminAccountPage>? pendingPage;
  Future<AdminAccountSessionsPage>? pendingSessionsPage;
  final List<AdminAccountSessionsPage> sessionPages = [];

  @override
  Future<AdminAccountPage> adminAccounts({
    int limit = 50,
    int offset = 0,
  }) async {
    listOffsets.add(offset);
    if (errors.isNotEmpty) throw errors.removeAt(0);
    if (pendingPage case final pending?) {
      pendingPage = null;
      return pending;
    }
    if (pages.isEmpty) throw StateError('No fake account page configured');
    return pages.removeAt(0);
  }

  @override
  Future<AdminAccountInvitationsPage> adminAccountInvitations({
    int limit = 50,
    int offset = 0,
  }) async {
    invitationListOffsets.add(offset);
    if (invitationErrors.isNotEmpty) {
      throw invitationErrors.removeAt(0);
    }
    if (pendingInvitationPage case final pending?) {
      pendingInvitationPage = null;
      return pending;
    }
    if (invitationPages.isEmpty) {
      throw StateError('No fake account invitation page configured');
    }
    return invitationPages.removeAt(0);
  }

  @override
  Future<AdminAccountInvitationIssueReceipt> createAdminAccountInvitation({
    required String username,
    int? expiresInSeconds,
  }) async {
    final normalizedUsername = username.trim().toLowerCase();
    final lifetime = expiresInSeconds ?? const Duration(days: 7).inSeconds;
    invitationIssues.add((normalizedUsername, lifetime));
    if (invitationIssueReceipts.isNotEmpty) {
      return invitationIssueReceipts.removeAt(0);
    }
    final createdAt = DateTime.utc(2026, 10, 1, 9);
    return AdminAccountInvitationIssueReceipt(
      invitationId: _secondInvitationId,
      username: normalizedUsername,
      createdAt: createdAt,
      expiresAt: createdAt.add(Duration(seconds: lifetime)),
      token: _invitationToken,
    );
  }

  @override
  Future<AdminAccountInvitationRevokeReceipt> revokeAdminAccountInvitation({
    required String invitationId,
  }) async {
    invitationRevocations.add(invitationId);
    return AdminAccountInvitationRevokeReceipt(
      invitationId: invitationId,
      status: 'revoked',
      revokedAt: DateTime.utc(2026, 10, 1, 10),
    );
  }

  @override
  Future<AdminAccountStatusReceipt> setAdminAccountStatus({
    required String userId,
    required String status,
  }) async {
    statusWrites.add((userId, status));
    if (statusErrors.isNotEmpty) throw statusErrors.removeAt(0);
    return AdminAccountStatusReceipt(
      accountId: userId,
      status: status,
      revokedSessions: 3,
      updatedAt: DateTime.utc(2026, 9, 29, 14),
    );
  }

  @override
  Future<AdminAccountSessionsReceipt> revokeAdminAccountSessions({
    required String userId,
  }) async {
    sessionRevocations.add(userId);
    return AdminAccountSessionsReceipt(
      accountId: userId,
      revokedSessions: 2,
      updatedAt: DateTime.utc(2026, 9, 29, 14, 1),
    );
  }

  @override
  Future<AdminAccountSessionsPage> adminAccountSessions({
    required String userId,
    int limit = 50,
    int offset = 0,
  }) async {
    sessionOffsets.add((userId, offset));
    if (sessionErrors.isNotEmpty) throw sessionErrors.removeAt(0);
    if (pendingSessionsPage case final pending?) {
      pendingSessionsPage = null;
      return pending;
    }
    if (sessionPages.isEmpty) {
      throw StateError('No fake session page configured');
    }
    return sessionPages.removeAt(0);
  }

  @override
  Future<AdminAccountSessionRevokeReceipt> revokeAdminAccountSession({
    required String userId,
    required String sessionId,
  }) async {
    individualRevocations.add((userId, sessionId));
    return AdminAccountSessionRevokeReceipt(
      accountId: userId,
      sessionId: sessionId,
      revoked: true,
      updatedAt: DateTime.utc(2026, 9, 29, 14, 2),
    );
  }
}

AdminAccountPage _accountPage(
  List<AdminAccountMetadata> accounts, {
  required int total,
  required int offset,
}) => AdminAccountPage(
  accounts: accounts,
  total: total,
  limit: 50,
  offset: offset,
);

AdminAccountInvitationsPage _invitationPage(
  List<AdminAccountInvitationMetadata> invitations, {
  required int total,
  required int offset,
}) => AdminAccountInvitationsPage(
  invitations: invitations,
  total: total,
  limit: 50,
  offset: offset,
);

AdminAccountInvitationMetadata _invitation(
  String invitationId,
  String username, {
  String status = 'pending',
}) => AdminAccountInvitationMetadata(
  invitationId: invitationId,
  username: username,
  createdAt: DateTime.utc(2026, 10, 1, 9),
  expiresAt: DateTime.utc(2026, 10, 8, 9),
  status: status,
);

AdminAccountMetadata _account(
  String userId,
  String username, {
  String status = 'active',
  int activeDevices = 1,
  int activeSessions = 2,
}) => AdminAccountMetadata(
  userId: userId,
  username: username,
  status: status,
  createdAt: DateTime.utc(2026, 9, 1),
  activeDeviceCount: activeDevices,
  activeSessionCount: activeSessions,
);

AdminAccountSessionsPage _accountSessionsPage(
  List<AdminAccountSessionMetadata> sessions, {
  required int total,
  required int offset,
}) => AdminAccountSessionsPage(
  sessions: sessions,
  total: total,
  limit: 50,
  offset: offset,
);

AdminAccountSessionMetadata _adminSession(
  String sessionId, {
  required bool active,
  required DateTime? revokedAt,
}) => AdminAccountSessionMetadata(
  sessionId: sessionId,
  deviceId: sessionId == _sessionId ? _deviceId : _otherDeviceId,
  deviceName: active ? 'Linux workstation' : 'Device with ineffective session',
  createdAt: DateTime.utc(2026, 9, 28, 9),
  accessExpiresAt: DateTime.utc(2026, 9, 29, 9),
  refreshExpiresAt: DateTime.utc(2026, 10, 29, 9),
  active: active,
  revokedAt: revokedAt,
);

Map<String, dynamic> _accountJson(String userId) => {
  'user_id': userId,
  'username': 'alice@example.test',
  'status': 'active',
  'created_at': '2026-09-01T00:00:00Z',
  'active_device_count': 2,
  'active_session_count': 3,
};

Map<String, dynamic> _invitationJson(String invitationId) => {
  'invitation_id': invitationId,
  'username': 'alice@example.test',
  'created_at': '2026-10-01T09:00:00Z',
  'expires_at': '2026-10-08T09:00:00Z',
  'status': 'pending',
};

Map<String, dynamic> _sessionJson(String sessionId, {bool active = true}) => {
  'session_id': sessionId,
  'device_id': _deviceId,
  'device_name': 'Linux workstation',
  'created_at': '2026-09-28T09:00:00Z',
  'access_expires_at': '2026-09-29T09:00:00Z',
  'refresh_expires_at': '2026-10-29T09:00:00Z',
  'active': active,
  'revoked_at': null,
};
