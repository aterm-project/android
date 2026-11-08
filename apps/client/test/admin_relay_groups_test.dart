import 'support/settings_navigation.dart';

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

const _adminId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _aliceId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _bobId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _groupId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'ApiClient uses server-managed group routes and strict DTO shapes',
    () async {
      final requests = <http.Request>[];
      final api = ApiClient(
        baseUrl: 'https://relay-groups.example.test',
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'DELETE' &&
              request.url.path == '/api/v1/admin/relay-groups/$_groupId') {
            return http.Response('', 204);
          }
          if (request.method == 'GET' &&
              request.url.path == '/api/v1/admin/relay-groups') {
            return http.Response(
              jsonEncode({
                'groups': [
                  {
                    'group_id': _groupId,
                    'name': '运维',
                    'revision': 1,
                    'membership_revision': 0,
                    'policy_revision': 0,
                    'member_count': 0,
                    'policy_inherited': true,
                    'updated_at': '2026-10-08T12:00:00Z',
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode(_detailJson()),
            request.method == 'POST' ? 201 : 200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      try {
        final groups = await api.adminRelayGroups();
        expect(groups.single.name, '运维');
        expect(groups.single.policyInherited, isTrue);

        final detail = await api.adminRelayGroup(_groupId);
        expect(detail.membershipRevision, 0);
        expect(detail.policy.instancePolicyRevision, 3);

        final created = await api.createAdminRelayGroup(name: ' 运维 ');
        expect(created.name, '运维');
        await api.updateAdminRelayGroup(
          groupId: _groupId,
          expectedRevision: 1,
          name: '运维组',
        );
        await api.updateAdminRelayGroupMembers(
          groupId: _groupId,
          expectedRevision: 0,
          userIds: [_bobId, _aliceId],
        );
        await api.updateAdminRelayGroupPolicy(
          groupId: _groupId,
          expectedRevision: 0,
          expectedInstancePolicyRevision: 3,
          enabled: true,
          allowCidrs: ['10.0.0.0/8'],
          allowPorts: [2222, 22],
        );
        await api.resetAdminRelayGroupPolicy(
          groupId: _groupId,
          expectedRevision: 1,
        );
        await api.deleteAdminRelayGroup(
          groupId: _groupId,
          expectedRevision: 1,
          expectedMembershipRevision: 0,
          expectedPolicyRevision: 0,
        );

        expect(
          requests.map((request) => '${request.method} ${request.url.path}'),
          [
            'GET /api/v1/admin/relay-groups',
            'GET /api/v1/admin/relay-groups/$_groupId',
            'POST /api/v1/admin/relay-groups',
            'PUT /api/v1/admin/relay-groups/$_groupId',
            'PUT /api/v1/admin/relay-groups/$_groupId/members',
            'PUT /api/v1/admin/relay-groups/$_groupId/relay-policy',
            'DELETE /api/v1/admin/relay-groups/$_groupId/relay-policy',
            'DELETE /api/v1/admin/relay-groups/$_groupId',
          ],
        );
        expect(jsonDecode(requests[2].body), {'name': '运维'});
        expect(jsonDecode(requests[4].body), {
          'expected_revision': 0,
          'user_ids': [_aliceId, _bobId],
        });
        expect(jsonDecode(requests[5].body), {
          'expected_revision': 0,
          'expected_instance_policy_revision': 3,
          'enabled': true,
          'allow_cidrs': ['10.0.0.0/8'],
          'allow_ports': [22, 2222],
        });
        expect(jsonDecode(requests[7].body), {
          'expected_revision': 1,
          'expected_membership_revision': 0,
          'expected_policy_revision': 0,
        });
      } finally {
        api.close();
      }
    },
  );

  testWidgets(
    'server-managed groups are distinct and support empty list and creation',
    (tester) async {
      final harness = await _Harness.create(sodium);
      harness.api.groups = const [];
      harness.api.createdDetail = _detail(name: '运维');
      harness.api.detailResponses[_groupId] = Queue.of([_detail(name: '运维')]);
      harness.api.groupsAfterCreate = [_summary(name: '运维')];
      harness.api.updatedMembersDetail = _detail(
        name: '运维',
        membershipRevision: 1,
        members: const [
          AdminRelayGroupMember(
            userId: _aliceId,
            username: 'alice@example.test',
          ),
        ],
      );
      harness.api.instancePolicyResponses = Queue.of([_instancePolicy()]);
      harness.api.memberPolicyResponses = Queue.of([
        _userPolicy(_aliceId, _policy(['10.1.2.0/24'], [2222])),
      ]);
      try {
        await _pumpSettings(tester, harness.app);
        expect(find.text('Server-managed access groups'), findsOneWidget);
        expect(
          find.textContaining('separate from encrypted Workspace groups'),
          findsOneWidget,
        );
        expect(harness.api.groupListCalls, 0);

        final reload = find.byKey(const ValueKey('admin_relay_groups_refresh'));
        await tester.ensureVisible(reload);
        await tester.tap(reload);
        await tester.pumpAndSettle();
        expect(find.text('No server-managed groups yet.'), findsOneWidget);

        final nameField = find.byKey(
          const ValueKey('admin_relay_group_create_name'),
        );
        await tester.ensureVisible(nameField);
        await tester.enterText(nameField, ' 运维 ');
        await tester.ensureVisible(find.text('Create group'));
        await tester.tap(find.text('Create group'));
        await tester.pumpAndSettle();

        expect(harness.api.createdNames, ['运维']);
        expect(harness.api.groupListCalls, 2);
        expect(harness.app.adminRelayGroupId, _groupId);
        expect(find.text('Selected server-managed group'), findsOneWidget);
        expect(
          find.text('Selection: inherited from the instance Relay policy'),
          findsOneWidget,
        );

        final memberPicker = find.byKey(
          const ValueKey('admin_relay_group_member_picker_0'),
        );
        await tester.ensureVisible(memberPicker);
        await tester.tap(memberPicker);
        await tester.pumpAndSettle();
        await tester.tap(find.text('alice@example.test').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Add'));
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        expect(harness.app.adminRelayGroupMemberIdsDraft, [_aliceId]);
        await tester.ensureVisible(find.text('Save membership'));
        await tester.tap(find.text('Save membership'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('server_relay_group_member_$_aliceId')),
          findsOneWidget,
        );
        expect(harness.api.memberWrites.single.$3, [_aliceId]);

        final preview = find.byKey(
          const ValueKey('admin_relay_group_effective_preview_$_groupId'),
        );
        await tester.ensureVisible(preview);
        await tester.tap(preview);
        await tester.pumpAndSettle();
        await tester.tap(find.text('alice@example.test').last);
        await tester.pumpAndSettle();
        expect(harness.api.memberPolicyCalls, [_aliceId]);
        expect(
          find.textContaining(
            'Member effective Relay access: enabled · CIDRs: 10.1.2.0/24 · ports: 2222',
          ),
          findsOneWidget,
        );

        harness.api.createError = const ApiException(
          statusCode: 409,
          code: 'RELAY_GROUP_NAME_TAKEN',
          message: 'normalized group name already exists',
        );
        await tester.ensureVisible(nameField);
        await tester.enterText(nameField, 'ＯＰＳ');
        await tester.ensureVisible(find.text('Create group'));
        await tester.tap(find.text('Create group'));
        await tester.pumpAndSettle();
        expect(find.text('A server access group with the same name already exists (ignoring case and Unicode compatibility characters).'), findsOneWidget);
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  test(
    'controller saves rename, full membership, override and inheritance',
    () async {
      final harness = await _Harness.create(sodium);
      final initial = _detail(
        members: const [
          AdminRelayGroupMember(
            userId: _aliceId,
            username: 'alice@example.test',
          ),
        ],
      );
      harness.api.groups = [_summary()];
      harness.api.detailResponses[_groupId] = Queue.of([initial]);
      harness.api.instancePolicyResponses = Queue.of([_instancePolicy()]);
      harness.api.updatedDetail = _detail(
        name: 'Operations and support',
        revision: 2,
        members: initial.members,
      );
      harness.api.updatedMembersDetail = _detail(
        name: 'Operations and support',
        revision: 2,
        membershipRevision: 1,
        members: const [
          AdminRelayGroupMember(
            userId: _aliceId,
            username: 'alice@example.test',
          ),
          AdminRelayGroupMember(userId: _bobId, username: 'bob@example.test'),
        ],
      );
      harness.api.updatedPolicyDetail = _detail(
        name: 'Operations and support',
        revision: 2,
        membershipRevision: 1,
        policyRevision: 1,
        inherited: false,
        members: harness.api.updatedMembersDetail!.members,
        selected: _policy(['10.1.0.0/16'], [2222]),
      );
      harness.api.resetPolicyDetail = _detail(
        name: 'Operations and support',
        revision: 2,
        membershipRevision: 1,
        policyRevision: 2,
        inherited: true,
        members: harness.api.updatedMembersDetail!.members,
      );
      harness.api.groupsAfterCreate = [
        _summary(name: 'Operations and support'),
      ];
      try {
        await harness.app.loadAdminRelayGroups();
        await harness.app.selectAdminRelayGroup(groupId: _groupId);
        expect(harness.app.adminRelayGroupDetail?.name, 'Operations');

        harness.app.editAdminRelayGroupNameDraft('Operations and support');
        expect(await harness.app.saveAdminRelayGroupName(), isTrue);
        expect(harness.api.nameWrites.single, (
          _groupId,
          1,
          'Operations and support',
        ));

        harness.app.editAdminRelayGroupMemberIdsDraft([_aliceId, _bobId]);
        expect(await harness.app.saveAdminRelayGroupMembers(), isTrue);
        final memberWrite = harness.api.memberWrites.single;
        expect(memberWrite.$1, _groupId);
        expect(memberWrite.$2, 0);
        expect(memberWrite.$3, [_aliceId, _bobId]);

        harness.app.editAdminRelayGroupPolicyDraft(
          allowCidrsText: '10.1.0.0/16',
          allowPortsText: '2222',
        );
        expect(await harness.app.saveAdminRelayGroupPolicy(), isTrue);
        final policyWrite = harness.api.policyWrites.single;
        expect(policyWrite.$1, _groupId);
        expect(policyWrite.$2, 0);
        expect(policyWrite.$3, 3);
        expect(policyWrite.$4, isTrue);
        expect(policyWrite.$5, ['10.1.0.0/16']);
        expect(policyWrite.$6, [2222]);
        expect(harness.app.adminRelayGroupDetail?.policy.inherited, isFalse);

        expect(await harness.app.resetAdminRelayGroupPolicyToInherit(), isTrue);
        expect(harness.api.policyResets.single, (_groupId, 1));
        expect(harness.app.adminRelayGroupDetail?.policy.revision, 2);
        expect(harness.app.adminRelayGroupDetail?.policy.inherited, isTrue);
      } finally {
        await _disposeDirect(harness);
      }
    },
  );

  test(
    'CAS conflict retains all drafts until reload resolves the conflict',
    () async {
      final harness = await _Harness.create(sodium);
      final initial = _detail(
        members: const [
          AdminRelayGroupMember(
            userId: _aliceId,
            username: 'alice@example.test',
          ),
        ],
      );
      harness.api.groups = [_summary()];
      harness.api.detailResponses[_groupId] = Queue.of([
        initial,
        _detail(
          name: 'Operations updated elsewhere',
          revision: 2,
          membershipRevision: 1,
          policyRevision: 1,
          inherited: false,
          members: const [
            AdminRelayGroupMember(
              userId: _aliceId,
              username: 'alice@example.test',
            ),
            AdminRelayGroupMember(userId: _bobId, username: 'bob@example.test'),
          ],
          selected: _policy(['10.2.0.0/16'], [2222]),
        ),
      ]);
      harness.api.instancePolicyResponses = Queue.of([
        _instancePolicy(),
        _instancePolicy(),
      ]);
      harness.api.memberUpdateError = const ApiException(
        statusCode: 409,
        code: 'RELAY_GROUP_MEMBERSHIP_CONFLICT',
        message: 'membership changed concurrently',
      );
      try {
        await harness.app.loadAdminRelayGroups();
        await harness.app.selectAdminRelayGroup(groupId: _groupId);
        harness.app.editAdminRelayGroupNameDraft('Local name draft');
        harness.app.editAdminRelayGroupMemberIdsDraft([_aliceId, _bobId]);
        harness.app.editAdminRelayGroupPolicyDraft(
          allowCidrsText: '10.3.0.0/16',
          allowPortsText: '2222',
        );

        expect(await harness.app.saveAdminRelayGroupMembers(), isFalse);
        expect(harness.app.adminRelayGroupConflict, isTrue);
        expect(harness.app.adminRelayGroupNameDraft, 'Local name draft');
        expect(harness.app.adminRelayGroupMemberIdsDraft, [_aliceId, _bobId]);
        expect(harness.app.adminRelayGroupPolicyCidrsDraft, '10.3.0.0/16');

        await harness.app.loadAdminRelayGroupDetail(
          groupId: _groupId,
          preserveDraft: true,
        );
        expect(harness.app.adminRelayGroupConflict, isFalse);
        expect(harness.app.adminRelayGroupDetail?.membershipRevision, 1);
        expect(harness.app.adminRelayGroupNameDraft, 'Local name draft');
        expect(harness.app.adminRelayGroupMemberIdsDraft, [_aliceId, _bobId]);
        expect(harness.app.adminRelayGroupPolicyCidrsDraft, '10.3.0.0/16');
        expect(harness.app.adminRelayGroupDetail?.members.length, 2);
      } finally {
        await _disposeDirect(harness);
      }
    },
  );

  test(
    '422 validation keeps drafts editable and does not require reload',
    () async {
      final harness = await _Harness.create(sodium);
      harness.api.groups = [_summary()];
      harness.api.detailResponses[_groupId] = Queue.of([_detail()]);
      harness.api.instancePolicyResponses = Queue.of([_instancePolicy()]);
      harness.api.updatedMembersDetail = _detail(
        membershipRevision: 1,
        members: const [
          AdminRelayGroupMember(
            userId: _aliceId,
            username: 'alice@example.test',
          ),
        ],
      );
      harness.api.memberUpdateError = const ApiException(
        statusCode: 422,
        code: 'INVALID_RELAY_GROUP_REQUEST',
        message: 'one selected account is not active',
      );
      try {
        await harness.app.loadAdminRelayGroups();
        await harness.app.selectAdminRelayGroup(groupId: _groupId);
        harness.app.editAdminRelayGroupNameDraft('Operations draft');
        harness.app.editAdminRelayGroupMemberIdsDraft([_bobId]);
        harness.app.editAdminRelayGroupPolicyDraft(
          allowCidrsText: '10.4.0.0/16',
          allowPortsText: '2222',
        );

        expect(await harness.app.saveAdminRelayGroupMembers(), isFalse);
        expect(harness.app.adminRelayGroupConflict, isFalse);
        expect(harness.app.adminRelayGroupNameDraft, 'Operations draft');
        expect(harness.app.adminRelayGroupMemberIdsDraft, [_bobId]);
        expect(harness.app.adminRelayGroupPolicyCidrsDraft, '10.4.0.0/16');

        harness.api.memberUpdateError = null;
        harness.app.editAdminRelayGroupMemberIdsDraft([_aliceId]);
        expect(await harness.app.saveAdminRelayGroupMembers(), isTrue);
        expect(harness.api.memberWrites, hasLength(2));
        expect(harness.api.memberWrites.last.$2, 0);
        expect(harness.api.memberWrites.last.$3, [_aliceId]);
      } finally {
        await _disposeDirect(harness);
      }
    },
  );
}

class _Harness {
  _Harness(this.database, this.api, this.app);

  final ClientDatabase database;
  final _RelayGroupsApi api;
  final AppController app;

  static Future<_Harness> create(SodiumSumo sodium) async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _RelayGroupsApi();
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

class _RelayGroupsApi extends ApiClient {
  _RelayGroupsApi()
    : super(
        baseUrl: 'https://admin-relay-groups.example.test',
        client: MockClient((_) async => throw StateError('Unexpected request')),
      );

  List<AdminRelayGroupSummary> groups = const [];
  List<AdminRelayGroupSummary> groupsAfterCreate = const [];
  int groupListCalls = 0;
  final Map<String, Queue<AdminRelayGroupDetail>> detailResponses = {};
  Queue<InstanceAdminRelayPolicy> instancePolicyResponses = Queue();
  Queue<InstanceAdminRelayUserPolicy> memberPolicyResponses = Queue();
  final List<String> memberPolicyCalls = [];
  AdminRelayGroupDetail? createdDetail;
  AdminRelayGroupDetail? updatedDetail;
  AdminRelayGroupDetail? updatedMembersDetail;
  AdminRelayGroupDetail? updatedPolicyDetail;
  AdminRelayGroupDetail? resetPolicyDetail;
  ApiException? memberUpdateError;
  ApiException? createError;
  final List<String> createdNames = [];
  final List<(String, int, String)> nameWrites = [];
  final List<(String, int, List<String>)> memberWrites = [];
  final List<(String, int, int, bool, List<String>, List<int>)> policyWrites =
      [];
  final List<(String, int)> policyResets = [];

  @override
  Future<List<AdminRelayGroupSummary>> adminRelayGroups() async {
    groupListCalls++;
    if (groupListCalls > 1 && groupsAfterCreate.isNotEmpty) {
      groups = groupsAfterCreate;
    }
    return groups;
  }

  @override
  Future<AdminRelayGroupDetail> adminRelayGroup(String groupId) async {
    final responses = detailResponses[groupId];
    if (responses == null || responses.isEmpty) {
      throw StateError('No fake server-managed group detail configured');
    }
    return responses.removeFirst();
  }

  @override
  Future<InstanceAdminRelayPolicy> instanceAdminRelayPolicy() async {
    if (instancePolicyResponses.isEmpty) return _instancePolicy();
    return instancePolicyResponses.removeFirst();
  }

  @override
  Future<InstanceAdminRelayUserPolicy> instanceAdminRelayUserPolicy(
    String userId,
  ) async {
    memberPolicyCalls.add(userId);
    return memberPolicyResponses.removeFirst();
  }

  @override
  Future<AdminRelayGroupDetail> createAdminRelayGroup({
    required String name,
  }) async {
    createdNames.add(name);
    if (createError case final error?) throw error;
    return createdDetail ??
        (throw StateError('No fake created server group configured'));
  }

  @override
  Future<AdminRelayGroupDetail> updateAdminRelayGroup({
    required String groupId,
    required int expectedRevision,
    required String name,
  }) async {
    nameWrites.add((groupId, expectedRevision, name));
    return updatedDetail ??
        (throw StateError('No fake renamed server group configured'));
  }

  @override
  Future<void> deleteAdminRelayGroup({
    required String groupId,
    required int expectedRevision,
    required int expectedMembershipRevision,
    required int expectedPolicyRevision,
  }) async {}

  @override
  Future<AdminRelayGroupDetail> updateAdminRelayGroupMembers({
    required String groupId,
    required int expectedRevision,
    required List<String> userIds,
  }) async {
    memberWrites.add((groupId, expectedRevision, List.unmodifiable(userIds)));
    if (memberUpdateError case final error?) throw error;
    return updatedMembersDetail ??
        (throw StateError('No fake updated membership configured'));
  }

  @override
  Future<AdminRelayGroupDetail> updateAdminRelayGroupPolicy({
    required String groupId,
    required int expectedRevision,
    required int expectedInstancePolicyRevision,
    required bool enabled,
    required List<String> allowCidrs,
    required List<int> allowPorts,
  }) async {
    policyWrites.add((
      groupId,
      expectedRevision,
      expectedInstancePolicyRevision,
      enabled,
      List.unmodifiable(allowCidrs),
      List.unmodifiable(allowPorts),
    ));
    return updatedPolicyDetail ??
        (throw StateError('No fake updated group policy configured'));
  }

  @override
  Future<AdminRelayGroupDetail> resetAdminRelayGroupPolicy({
    required String groupId,
    required int expectedRevision,
  }) async {
    policyResets.add((groupId, expectedRevision));
    return resetPolicyDetail ??
        (throw StateError('No fake reset group policy configured'));
  }
}

AdminRelayGroupSummary _summary({String name = 'Operations'}) =>
    AdminRelayGroupSummary(
      groupId: _groupId,
      name: name,
      revision: name == 'Operations' ? 1 : 2,
      membershipRevision: 0,
      policyRevision: 0,
      memberCount: 0,
      policyInherited: true,
      updatedAt: DateTime.utc(2026, 10, 8, 12),
    );

Map<String, dynamic> _detailJson() => {
  'group': {
    'group_id': _groupId,
    'name': '运维',
    'revision': 1,
    'created_at': '2026-10-01T00:00:00Z',
    'updated_at': '2026-10-08T12:00:00Z',
  },
  'members': {'revision': 0, 'items': <Object>[]},
  'policy': {
    'inherited': true,
    'revision': 0,
    'updated_at': null,
    'instance_policy_revision': 3,
    'policy': {
      'enabled': true,
      'allow_cidrs': ['10.0.0.0/8'],
      'allow_ports': [22, 2222],
    },
    'effective_policy': {
      'enabled': true,
      'allow_cidrs': ['10.0.0.0/8'],
      'allow_ports': [22, 2222],
    },
  },
};

AdminRelayGroupDetail _detail({
  String name = 'Operations',
  int revision = 1,
  int membershipRevision = 0,
  int policyRevision = 0,
  bool inherited = true,
  int instanceRevision = 3,
  List<AdminRelayGroupMember> members = const [],
  AdminRelayPolicyValue? selected,
  AdminRelayPolicyValue? effective,
}) => AdminRelayGroupDetail(
  groupId: _groupId,
  name: name,
  revision: revision,
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 8, 12),
  membershipRevision: membershipRevision,
  members: List.unmodifiable(members),
  policy: AdminRelayGroupPolicy(
    inherited: inherited,
    revision: policyRevision,
    updatedAt: inherited ? null : DateTime.utc(2026, 10, 8, 12),
    instancePolicyRevision: instanceRevision,
    policy: selected ?? _policy(['10.0.0.0/8'], [22, 2222]),
    effectivePolicy:
        effective ?? selected ?? _policy(['10.0.0.0/8'], [22, 2222]),
  ),
);

InstanceAdminRelayPolicy _instancePolicy() => InstanceAdminRelayPolicy(
  policy: _policy(['10.0.0.0/8'], [22, 2222]),
  deploymentLimits: const AdminRelayPolicyLimits(
    relayAvailable: true,
    allowCidrs: ['10.0.0.0/8'],
    allowPorts: [22, 2222],
  ),
  maxConnectionsPerUser: 4,
  revision: 3,
  updatedAt: DateTime.utc(2026, 10, 8, 12),
);

AdminRelayPolicyValue _policy(List<String> cidrs, List<int> ports) =>
    AdminRelayPolicyValue(
      enabled: true,
      allowCidrs: List.unmodifiable(cidrs),
      allowPorts: List.unmodifiable(ports),
    );

InstanceAdminRelayUserPolicy _userPolicy(
  String userId,
  AdminRelayPolicyValue effective,
) => InstanceAdminRelayUserPolicy(
  userId: userId,
  inherited: true,
  policy: _policy(['10.0.0.0/8'], [22, 2222]),
  effectivePolicy: effective,
  instancePolicyRevision: 3,
  revision: 0,
  updatedAt: null,
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
