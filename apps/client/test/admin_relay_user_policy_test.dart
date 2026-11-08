import 'support/settings_navigation.dart';

import 'dart:async';
import 'dart:collection';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

const _adminId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _aliceId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _bobId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  testWidgets('Relay policy loads lazily, saves an override, then resets', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium);
    harness.api.instanceResponses.addAll([Future.value(_instancePolicy(4))]);
    harness.api.userResponses[_aliceId] = Queue.of([
      Future.value(_userPolicy(_aliceId, inherited: true, revision: 0)),
    ]);
    harness.api.updatedUserPolicy = _userPolicy(
      _aliceId,
      inherited: false,
      revision: 1,
      selected: _policy(['10.1.0.0/16'], [2222]),
    );
    harness.api.resetUserPolicy = _userPolicy(
      _aliceId,
      inherited: true,
      revision: 2,
    );
    try {
      await _pumpSettings(tester, harness.app);
      expect(harness.api.instanceCalls, 0);
      expect(harness.api.userPolicyCalls, isEmpty);

      final relayPolicyButton = find.byKey(
        const ValueKey('admin_account_relay_policy_$_aliceId'),
      );
      await tester.ensureVisible(relayPolicyButton);
      await tester.tap(relayPolicyButton);
      await tester.pumpAndSettle();
      expect(harness.api.instanceCalls, 1);
      expect(harness.api.userPolicyCalls, [_aliceId]);
      expect(
        find.text('Selection: inherited from the instance policy'),
        findsOneWidget,
      );
      expect(find.textContaining('Account revision 0'), findsOneWidget);
      expect(find.textContaining('Instance revision 4'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('relay_policy_cidrs_$_aliceId')),
            )
            .controller!
            .text,
        '10.0.0.0/8',
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('relay_policy_ports_$_aliceId')),
            )
            .controller!
            .text,
        '22, 2222',
      );

      final cidrField = find.byKey(
        const ValueKey('relay_policy_cidrs_$_aliceId'),
      );
      await tester.ensureVisible(cidrField);
      await tester.enterText(cidrField, '10.1.0.0/16');
      final portsField = find.byKey(
        const ValueKey('relay_policy_ports_$_aliceId'),
      );
      await tester.ensureVisible(portsField);
      await tester.enterText(portsField, '2222');
      await tester.ensureVisible(find.text('Save override'));
      await tester.tap(find.text('Save override'));
      await tester.pumpAndSettle();
      final write = harness.api.userPolicyWrites.single;
      expect(write.$1, _aliceId);
      expect(write.$2, 0);
      expect(write.$3, isTrue);
      expect(write.$4, ['10.1.0.0/16']);
      expect(write.$5, [2222]);
      expect(harness.api.expectedInstancePolicyRevisions, [4]);
      expect(find.text('Selection: account override'), findsOneWidget);
      expect(find.textContaining('Account revision 1'), findsOneWidget);

      await tester.ensureVisible(find.text('Reset to inherit'));
      await tester.tap(find.text('Reset to inherit'));
      await tester.pumpAndSettle();
      expect(harness.api.userPolicyResets, [(_aliceId, 1)]);
      expect(
        find.text('Selection: inherited from the instance policy'),
        findsOneWidget,
      );
      expect(find.textContaining('Account revision 2'), findsOneWidget);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('saving an unchanged inherited selection preserves inheritance', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium);
    harness.api.instanceResponses.add(Future.value(_narrowedInstancePolicy(5)));
    harness.api.userResponses[_aliceId] = Queue.of([
      Future.value(
        _userPolicy(
          _aliceId,
          inherited: true,
          revision: 0,
          instanceRevision: 5,
          selected: _policy(['10.0.0.0/8'], [22, 2222]),
          effective: _policy(['10.1.0.0/16'], [2222]),
        ),
      ),
    ]);
    harness.api.updatedUserPolicy = _userPolicy(
      _aliceId,
      inherited: true,
      revision: 0,
      instanceRevision: 5,
      selected: _policy(['10.0.0.0/8'], [22, 2222]),
      effective: _policy(['10.1.0.0/16'], [2222]),
    );
    try {
      await _pumpSettings(tester, harness.app);
      final relayPolicyButton = find.byKey(
        const ValueKey('admin_account_relay_policy_$_aliceId'),
      );
      await tester.ensureVisible(relayPolicyButton);
      await tester.tap(relayPolicyButton);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('relay_policy_cidrs_$_aliceId')),
            )
            .controller!
            .text,
        '10.0.0.0/8',
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('relay_policy_ports_$_aliceId')),
            )
            .controller!
            .text,
        '22, 2222',
      );
      expect(find.textContaining('Effective state:'), findsOneWidget);

      await tester.ensureVisible(find.text('Save override'));
      await tester.tap(find.text('Save override'));
      await tester.pumpAndSettle();
      final write = harness.api.userPolicyWrites.single;
      expect(write.$2, 0);
      expect(write.$4, ['10.0.0.0/8']);
      expect(write.$5, [22, 2222]);
      expect(harness.api.expectedInstancePolicyRevisions, [5]);
      expect(harness.app.adminAccountRelayUserPolicy?.inherited, isTrue);
      expect(harness.app.adminAccountRelayUserPolicy?.revision, 0);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('revision conflict preserves the draft and offers reload', (
    tester,
  ) async {
    final harness = await _Harness.create(sodium);
    harness.api.instanceResponses.addAll([
      Future.value(_instancePolicy(8)),
      Future.value(_instancePolicy(8)),
    ]);
    harness.api.userResponses[_aliceId] = Queue.of([
      Future.value(
        _userPolicy(
          _aliceId,
          inherited: false,
          revision: 3,
          instanceRevision: 8,
          selected: _policy(['10.0.0.0/8'], [22]),
        ),
      ),
      Future.value(
        _userPolicy(
          _aliceId,
          inherited: false,
          revision: 4,
          instanceRevision: 8,
          selected: _policy(['10.0.0.0/8'], [22]),
        ),
      ),
    ]);
    harness.api.updateError = const ApiException(
      statusCode: 409,
      code: 'RELAY_USER_POLICY_CONFLICT',
      message: 'stale revision',
    );
    try {
      await _pumpSettings(tester, harness.app);
      final relayPolicyButton = find.byKey(
        const ValueKey('admin_account_relay_policy_$_aliceId'),
      );
      await tester.ensureVisible(relayPolicyButton);
      await tester.tap(relayPolicyButton);
      await tester.pumpAndSettle();

      final cidrField = find.byKey(
        const ValueKey('relay_policy_cidrs_$_aliceId'),
      );
      await tester.ensureVisible(cidrField);
      await tester.enterText(cidrField, '10.2.0.0/16');
      final portsField = find.byKey(
        const ValueKey('relay_policy_ports_$_aliceId'),
      );
      await tester.ensureVisible(portsField);
      await tester.enterText(portsField, '2222');
      await tester.ensureVisible(find.text('Save override'));
      await tester.tap(find.text('Save override'));
      await tester.pumpAndSettle();

      expect(harness.app.adminAccountRelayPolicyCidrsDraft, '10.2.0.0/16');
      expect(harness.app.adminAccountRelayPolicyPortsDraft, '2222');
      expect(find.text('Reload latest policy, keep draft'), findsOneWidget);
      expect(harness.api.expectedInstancePolicyRevisions, [8]);
      await tester.tap(find.text('Reload latest policy, keep draft'));
      await tester.pumpAndSettle();
      expect(harness.app.adminAccountRelayUserPolicy?.revision, 4);
      expect(harness.app.adminAccountRelayPolicyCidrsDraft, '10.2.0.0/16');
      expect(harness.app.adminAccountRelayPolicyPortsDraft, '2222');
      expect(harness.api.instanceCalls, 2);
      expect(harness.api.userPolicyCalls, [_aliceId, _aliceId]);

      harness.api.updateError = const ApiException(
        statusCode: 422,
        code: 'RELAY_USER_POLICY_OUTSIDE_LIMITS',
        message: 'policy limits changed',
      );
      await tester.ensureVisible(find.text('Save override'));
      await tester.tap(find.text('Save override'));
      await tester.pumpAndSettle();
      expect(harness.app.adminAccountRelayPolicyCidrsDraft, '10.2.0.0/16');
      expect(harness.app.adminAccountRelayPolicyPortsDraft, '2222');
      expect(find.text('Reload latest policy, keep draft'), findsOneWidget);
      expect(harness.api.expectedInstancePolicyRevisions, [8, 8]);
    } finally {
      await _dispose(tester, harness);
    }
  });

  test(
    'a write response for a newer instance revision is not applied',
    () async {
      final harness = await _Harness.create(sodium);
      harness.api.instanceResponses.addAll([
        Future.value(_instancePolicy(5)),
        Future.value(_instancePolicy(6)),
      ]);
      harness.api.userResponses[_aliceId] = Queue.of([
        Future.value(
          _userPolicy(
            _aliceId,
            inherited: true,
            revision: 0,
            instanceRevision: 5,
          ),
        ),
        Future.value(
          _userPolicy(
            _aliceId,
            inherited: false,
            revision: 1,
            instanceRevision: 6,
            selected: _policy(['10.1.0.0/16'], [2222]),
          ),
        ),
      ]);
      harness.api.updatedUserPolicy = _userPolicy(
        _aliceId,
        inherited: false,
        revision: 1,
        instanceRevision: 6,
        selected: _policy(['10.1.0.0/16'], [2222]),
      );
      try {
        await harness.app.toggleAdminAccountRelayPolicy(userId: _aliceId);
        harness.app.editAdminAccountRelayPolicyDraft(
          userId: _aliceId,
          allowCidrsText: '10.1.0.0/16',
          allowPortsText: '2222',
        );

        expect(
          await harness.app.saveAdminAccountRelayPolicyDraft(userId: _aliceId),
          isFalse,
        );
        expect(harness.app.adminAccountRelayUserPolicy, isNull);
        expect(harness.app.adminAccountRelayInstancePolicy, isNull);
        expect(harness.app.adminAccountRelayPolicyConflict, isTrue);
        expect(harness.app.adminAccountRelayPolicyCidrsDraft, '10.1.0.0/16');
        expect(harness.app.adminAccountRelayPolicyPortsDraft, '2222');
        expect(harness.api.expectedInstancePolicyRevisions, [5]);

        await harness.app.loadAdminAccountRelayPolicy(
          userId: _aliceId,
          preserveDraft: true,
        );
        expect(harness.app.adminAccountRelayUserPolicy?.revision, 1);
        expect(
          harness.app.adminAccountRelayUserPolicy?.instancePolicyRevision,
          6,
        );
        expect(harness.app.adminAccountRelayPolicyConflict, isFalse);
        expect(harness.app.adminAccountRelayPolicyCidrsDraft, '10.1.0.0/16');
        expect(harness.app.adminAccountRelayPolicyPortsDraft, '2222');
      } finally {
        await _disposeDirect(harness);
      }
    },
  );

  test(
    'a user policy is retried when its instance revision is stale',
    () async {
      final harness = await _Harness.create(sodium);
      harness.api.instanceResponses.addAll([
        Future.value(_instancePolicy(10)),
        Future.value(_instancePolicy(11)),
      ]);
      harness.api.userResponses[_aliceId] = Queue.of([
        Future.value(
          _userPolicy(
            _aliceId,
            inherited: false,
            revision: 2,
            instanceRevision: 9,
            selected: _policy(['10.0.0.0/8'], [22]),
          ),
        ),
        Future.value(
          _userPolicy(
            _aliceId,
            inherited: false,
            revision: 2,
            instanceRevision: 11,
            selected: _policy(['10.0.0.0/8'], [22]),
          ),
        ),
      ]);
      try {
        await harness.app.toggleAdminAccountRelayPolicy(userId: _aliceId);
        expect(harness.api.instanceCalls, 2);
        expect(harness.api.userPolicyCalls, [_aliceId, _aliceId]);
        expect(harness.app.adminAccountRelayInstancePolicy?.revision, 11);
        expect(
          harness.app.adminAccountRelayUserPolicy?.instancePolicyRevision,
          11,
        );
        expect(harness.app.adminAccountRelayPolicyConflict, isFalse);
      } finally {
        await _disposeDirect(harness);
      }
    },
  );

  test(
    'late policy results cannot replace the newly selected account',
    () async {
      final harness = await _Harness.create(sodium);
      final aliceInstance = Completer<InstanceAdminRelayPolicy>();
      final aliceUser = Completer<InstanceAdminRelayUserPolicy>();
      harness.api.instanceResponses.addAll([
        aliceInstance.future,
        Future.value(_instancePolicy(12)),
      ]);
      harness.api.userResponses[_aliceId] = Queue.of([aliceUser.future]);
      harness.api.userResponses[_bobId] = Queue.of([
        Future.value(
          _userPolicy(
            _bobId,
            inherited: true,
            revision: 0,
            instanceRevision: 12,
          ),
        ),
      ]);
      try {
        final aliceLoad = harness.app.toggleAdminAccountRelayPolicy(
          userId: _aliceId,
        );
        await Future<void>.delayed(Duration.zero);
        await harness.app.toggleAdminAccountRelayPolicy(userId: _bobId);
        expect(harness.app.adminAccountRelayPolicyUserId, _bobId);

        aliceInstance.complete(_instancePolicy(11));
        aliceUser.complete(
          _userPolicy(
            _aliceId,
            inherited: true,
            revision: 0,
            instanceRevision: 11,
          ),
        );
        await aliceLoad;

        expect(harness.app.adminAccountRelayPolicyUserId, _bobId);
        expect(harness.app.adminAccountRelayUserPolicy?.userId, _bobId);
        expect(harness.app.adminAccountRelayInstancePolicy?.revision, 12);
      } finally {
        if (!aliceInstance.isCompleted)
          aliceInstance.complete(_instancePolicy(11));
        if (!aliceUser.isCompleted) {
          aliceUser.complete(
            _userPolicy(
              _aliceId,
              inherited: true,
              revision: 0,
              instanceRevision: 11,
            ),
          );
        }
        await _disposeDirect(harness);
      }
    },
  );
}

class _Harness {
  _Harness(this.database, this.api, this.app);

  final ClientDatabase database;
  final _RelayPolicyApi api;
  final AppController app;

  static Future<_Harness> create(SodiumSumo sodium) async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _RelayPolicyApi();
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
            policy: {'instance_admin': true},
          )
          ..adminAccountsPage = AdminAccountPage(
            accounts: [
              _account(_aliceId, 'alice@example.test'),
              _account(_bobId, 'bob@example.test'),
              _account(_adminId, 'admin@example.test'),
            ],
            total: 3,
            limit: 50,
            offset: 0,
          );
    return _Harness(database, api, app);
  }
}

class _RelayPolicyApi extends ApiClient {
  _RelayPolicyApi()
    : super(
        baseUrl: 'https://admin-relay-policy.example.test',
        client: MockClient((_) async => throw StateError('Unexpected request')),
      );

  final Queue<Future<InstanceAdminRelayPolicy>> instanceResponses = Queue();
  final Map<String, Queue<Future<InstanceAdminRelayUserPolicy>>> userResponses =
      {};
  final List<String> userPolicyCalls = [];
  final List<(String, int, bool, List<String>, List<int>)> userPolicyWrites =
      [];
  final List<int> expectedInstancePolicyRevisions = [];
  final List<(String, int)> userPolicyResets = [];
  int instanceCalls = 0;
  ApiException? updateError;
  InstanceAdminRelayUserPolicy? updatedUserPolicy;
  ApiException? resetError;
  InstanceAdminRelayUserPolicy? resetUserPolicy;

  @override
  Future<InstanceAdminRelayPolicy> instanceAdminRelayPolicy() async {
    instanceCalls++;
    if (instanceResponses.isEmpty) {
      throw StateError('No fake instance Relay policy configured');
    }
    return instanceResponses.removeFirst();
  }

  @override
  Future<InstanceAdminRelayUserPolicy> instanceAdminRelayUserPolicy(
    String userId,
  ) async {
    userPolicyCalls.add(userId);
    final responses = userResponses[userId];
    if (responses == null || responses.isEmpty) {
      throw StateError('No fake user Relay policy configured for $userId');
    }
    return responses.removeFirst();
  }

  @override
  Future<InstanceAdminRelayUserPolicy> updateInstanceAdminRelayUserPolicy({
    required String userId,
    required int expectedRevision,
    required int expectedInstancePolicyRevision,
    required bool enabled,
    required List<String> allowCidrs,
    required List<int> allowPorts,
  }) async {
    expectedInstancePolicyRevisions.add(expectedInstancePolicyRevision);
    userPolicyWrites.add((
      userId,
      expectedRevision,
      enabled,
      List<String>.unmodifiable(allowCidrs),
      List<int>.unmodifiable(allowPorts),
    ));
    if (updateError case final error?) throw error;
    return updatedUserPolicy ??
        (throw StateError('No fake updated user policy configured'));
  }

  @override
  Future<InstanceAdminRelayUserPolicy> resetInstanceAdminRelayUserPolicy({
    required String userId,
    required int expectedRevision,
  }) async {
    userPolicyResets.add((userId, expectedRevision));
    if (resetError case final error?) throw error;
    return resetUserPolicy ??
        (throw StateError('No fake reset user policy configured'));
  }
}

InstanceAdminRelayPolicy _instancePolicy(int revision) =>
    InstanceAdminRelayPolicy(
      policy: _policy(['10.0.0.0/8'], [22, 2222]),
      deploymentLimits: const AdminRelayPolicyLimits(
        relayAvailable: true,
        allowCidrs: ['10.0.0.0/8'],
        allowPorts: [22, 2222],
      ),
      maxConnectionsPerUser: 4,
      revision: revision,
      updatedAt: DateTime.utc(2026, 10, 7, 12),
    );

InstanceAdminRelayPolicy _narrowedInstancePolicy(int revision) =>
    InstanceAdminRelayPolicy(
      policy: _policy(['10.0.0.0/8'], [22, 2222]),
      deploymentLimits: const AdminRelayPolicyLimits(
        relayAvailable: true,
        allowCidrs: ['10.1.0.0/16'],
        allowPorts: [2222],
      ),
      maxConnectionsPerUser: 4,
      revision: revision,
      updatedAt: DateTime.utc(2026, 10, 7, 12),
    );

InstanceAdminRelayUserPolicy _userPolicy(
  String userId, {
  required bool inherited,
  required int revision,
  int instanceRevision = 4,
  AdminRelayPolicyValue? selected,
  AdminRelayPolicyValue? effective,
}) {
  final value = selected ?? _policy(['10.0.0.0/8'], [22, 2222]);
  return InstanceAdminRelayUserPolicy(
    userId: userId,
    inherited: inherited,
    policy: value,
    effectivePolicy: effective ?? value,
    instancePolicyRevision: instanceRevision,
    revision: revision,
    updatedAt: inherited ? null : DateTime.utc(2026, 10, 7, 13),
  );
}

AdminRelayPolicyValue _policy(List<String> cidrs, List<int> ports) =>
    AdminRelayPolicyValue(
      enabled: true,
      allowCidrs: List.unmodifiable(cidrs),
      allowPorts: List.unmodifiable(ports),
    );

AdminAccountMetadata _account(String id, String username) =>
    AdminAccountMetadata(
      userId: id,
      username: username,
      status: 'active',
      createdAt: DateTime.utc(2026, 9, 1),
      activeDeviceCount: 1,
      activeSessionCount: 1,
    );

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
  }
  await tester.pump();
}

Future<void> _dispose(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _disposeDirect(harness);
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

Future<void> _disposeDirect(_Harness harness) async {
  harness.app.dispose();
  harness.api.close();
  await harness.database.close();
}
