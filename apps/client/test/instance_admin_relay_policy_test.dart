import 'support/settings_navigation.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'relay policy GET is authenticated and parses deployment ceilings',
    () async {
      late http.Request captured;
      final api = ApiClient(
        baseUrl: 'https://admin.example.test/prefix',
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode(_policyJson()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..accessToken = 'admin-session-token';
      try {
        final result = await api.instanceAdminRelayPolicy();
        expect(captured.method, 'GET');
        expect(captured.url.path, '/prefix/api/v1/admin/relay-policy');
        expect(captured.headers['authorization'], 'Bearer admin-session-token');
        expect(result.policy.enabled, isTrue);
        expect(result.policy.allowCidrs, ['10.40.0.0/16']);
        expect(result.policy.allowPorts, [22]);
        expect(result.deploymentLimits.allowPorts, [22, 2222]);
        expect(result.maxConnectionsPerUser, 4);
        expect(result.revision, 8);
        expect(result.updatedAt, DateTime.utc(2026, 10, 2, 10));
      } finally {
        api.close();
      }
    },
  );

  test(
    'relay policy PUT sends only the revision and editable policy',
    () async {
      late http.Request captured;
      final limits = InstanceAdminRelayPolicy.fromJson(_policyJson())
          .deploymentLimits;
      final draft = AdminRelayPolicyDraft.parseAndValidate(
        enabled: true,
        allowCidrsText: '10.40.3.0/24',
        allowPortsText: '22\n',
        deploymentLimits: limits,
      );
      final api = ApiClient(
        baseUrl: 'https://admin.example.test/prefix',
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode(
              _policyJson(revision: 9, cidrs: ['10.40.3.0/24'], ports: [22]),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..accessToken = 'admin-session-token';
      try {
        final result = await api.updateInstanceAdminRelayPolicy(
          expectedRevision: 8,
          draft: draft,
          deploymentLimits: limits,
        );
        expect(captured.method, 'PUT');
        expect(captured.url.path, '/prefix/api/v1/admin/relay-policy');
        expect(captured.headers['authorization'], 'Bearer admin-session-token');
        expect(jsonDecode(captured.body), {
          'expected_revision': 8,
          'enabled': true,
          'allow_cidrs': ['10.40.3.0/24'],
          'allow_ports': [22],
        });
        expect(result.revision, 9);
      } finally {
        api.close();
      }
    },
  );

  test('CIDR and port policy inputs cannot widen deployment limits', () async {
    final limits = InstanceAdminRelayPolicy.fromJson(_policyJson())
        .deploymentLimits;
    for (final cidrs in [
      '10.41.0.0/16',
      '10.0.0.0/8',
      '10.40.3.1/24',
      '2001:db8::/32',
    ]) {
      expect(
        () => AdminRelayPolicyDraft.parseAndValidate(
          enabled: false,
          allowCidrsText: cidrs,
          allowPortsText: '22',
          deploymentLimits: limits,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => AdminRelayPolicyDraft.parseAndValidate(
        enabled: false,
        allowCidrsText: '10.40.0.0/16',
        allowPortsText: '22, 2223',
        deploymentLimits: limits,
      ),
      throwsFormatException,
    );
    expect(
      () => AdminRelayPolicyDraft.parseAndValidate(
        enabled: true,
        allowCidrsText: '',
        allowPortsText: '',
        deploymentLimits: const AdminRelayPolicyLimits(
          relayAvailable: false,
          allowCidrs: ['10.40.0.0/16'],
          allowPorts: [22],
        ),
      ),
      throwsFormatException,
    );
  });

  test('CIDR input requires canonical Rust IPv6 display spelling', () {
    const limits = AdminRelayPolicyLimits(
      relayAvailable: true,
      allowCidrs: ['fd00::/8'],
      allowPorts: [22],
    );
    final canonical = AdminRelayPolicyDraft.parseAndValidate(
      enabled: false,
      allowCidrsText: 'fd00::/8',
      allowPortsText: '22',
      deploymentLimits: limits,
    );
    expect(canonical.allowCidrs, ['fd00::/8']);
    for (final nonCanonical in [
      'FD00::/8',
      'fd00:0000:0000:0000:0000:0000:0000:0000/8',
    ]) {
      expect(
        () => AdminRelayPolicyDraft.parseAndValidate(
          enabled: false,
          allowCidrsText: nonCanonical,
          allowPortsText: '22',
          deploymentLimits: limits,
        ),
        throwsFormatException,
      );
    }
  });

  test('relay policy inputs enforce server list-size limits locally', () {
    final limits = InstanceAdminRelayPolicy.fromJson(_policyJson())
        .deploymentLimits;
    final tooManyCidrs = List.generate(
      257,
      (index) => '10.40.${index ~/ 256}.${index % 256}/32',
    ).join('\n');
    expect(
      () => AdminRelayPolicyDraft.parseAndValidate(
        enabled: false,
        allowCidrsText: tooManyCidrs,
        allowPortsText: '22',
        deploymentLimits: limits,
      ),
      throwsFormatException,
    );

    final portLimits = AdminRelayPolicyLimits(
      relayAvailable: true,
      allowCidrs: limits.allowCidrs,
      allowPorts: List.generate(4097, (index) => index + 1),
    );
    expect(
      () => AdminRelayPolicyDraft.parseAndValidate(
        enabled: false,
        allowCidrsText: '10.40.0.0/16',
        allowPortsText: List.generate(4097, (index) => index + 1).join(','),
        deploymentLimits: portLimits,
      ),
      throwsFormatException,
    );
  });

  test(
    'policy response rejects private fields but retains stale selections',
    () {
      final stale = InstanceAdminRelayPolicy.fromJson(
        _policyJson(
          cidrs: ['10.40.0.0/16'],
          ports: [22, 2222],
          limitCidrs: ['10.40.1.0/24'],
          limitPorts: [22],
        ),
      );
      expect(stale.policy.allowCidrs, ['10.40.0.0/16']);
      expect(stale.policy.allowPorts, [22, 2222]);
      expect(stale.policyWithinDeploymentLimits, isFalse);
      expect(
        () => InstanceAdminRelayPolicy.fromJson({
          ..._policyJson(),
          'target_host': 'ssh.example.test',
        }),
        throwsFormatException,
      );
      final selectedButUnavailable = InstanceAdminRelayPolicy.fromJson(
        _policyJson(enabled: true, relayAvailable: false),
      );
      expect(selectedButUnavailable.policy.enabled, isTrue);
      expect(selectedButUnavailable.deploymentLimits.relayAvailable, isFalse);
    },
  );

  test('narrowed draft fits a newly tightened deployment ceiling', () {
    final current = InstanceAdminRelayPolicy.fromJson(
      _policyJson(
        cidrs: ['10.40.0.0/16'],
        ports: [22, 2222],
        limitCidrs: ['10.40.1.0/24'],
        limitPorts: [22],
      ),
    );
    final narrowed = AdminRelayPolicyDraft.parseAndValidate(
      enabled: true,
      allowCidrsText: '10.40.1.0/24',
      allowPortsText: '22',
      deploymentLimits: current.deploymentLimits,
    );
    expect(narrowed.allowCidrs, ['10.40.1.0/24']);
    expect(narrowed.allowPorts, [22]);
  });

  testWidgets('relay policy editor is hidden for non-admin accounts', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: false);
    try {
      await _pumpSettings(tester, harness.app);
      expect(find.text('SSH relay policy'), findsNothing);
      expect(
        find.byKey(const ValueKey('admin-relay-policy-load')),
        findsNothing,
      );
      expect(harness.api.policyLoads, 0);
      expect(harness.api.policySaves, 0);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets(
    'admin policy editor shows ceilings and saves a narrower policy',
    (tester) async {
      final harness = await _Harness.create(isAdmin: true);
      harness.api.currentPolicy = _policyJson(enabled: false);
      try {
        await _pumpSettings(tester, harness.app);
        await tester.ensureVisible(
          find.byKey(const ValueKey('admin-relay-policy-load')),
        );
        await tester.tap(find.byKey(const ValueKey('admin-relay-policy-load')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('ATERMIUS_RELAY_ENABLED=true'),
          findsOneWidget,
        );
        expect(find.textContaining('10.40.0.0/16'), findsWidgets);
        expect(
          find.textContaining('Max SSH relay connections per user'),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const ValueKey('admin-relay-policy-enabled')),
        );
        await tester.pump();
        await tester.enterText(
          find.byKey(const ValueKey('admin-relay-policy-cidrs')),
          '10.40.1.0/24',
        );
        await tester.enterText(
          find.byKey(const ValueKey('admin-relay-policy-ports')),
          '22',
        );
        await tester.tap(find.byKey(const ValueKey('admin-relay-policy-save')));
        await tester.pumpAndSettle();
        expect(harness.api.policySaves, 1);
        expect(harness.api.lastExpectedRevision, 8);
        expect(harness.api.lastDraft?.allowCidrs, ['10.40.1.0/24']);
        expect(harness.api.lastDraft?.allowPorts, [22]);
        expect(harness.api.lastDraft?.enabled, isTrue);
        expect(find.text('SSH relay policy saved.'), findsOneWidget);
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets('admin editor prevents widening and reloads before stale retry', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    harness.api.currentPolicy = _policyJson(enabled: false);
    harness.api.conflictNextSave = true;
    try {
      await _pumpSettings(tester, harness.app);
      await tester.ensureVisible(
        find.byKey(const ValueKey('admin-relay-policy-load')),
      );
      await tester.tap(find.byKey(const ValueKey('admin-relay-policy-load')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('admin-relay-policy-cidrs')),
        '10.41.0.0/16',
      );
      await tester.enterText(
        find.byKey(const ValueKey('admin-relay-policy-ports')),
        '22, 2222',
      );
      await tester.tap(find.byKey(const ValueKey('admin-relay-policy-save')));
      await tester.pumpAndSettle();
      expect(harness.api.policySaves, 0);
      expect(
        find.text('Every CIDR must fit within a server deployment limit.'),
        findsOneWidget,
      );
      expect(
        harness.app.instanceAdminRelayPolicySaveError,
        'Every CIDR must fit within a server deployment limit.',
      );

      await tester.enterText(
        find.byKey(const ValueKey('admin-relay-policy-cidrs')),
        '10.40.1.0/24',
      );
      await tester.enterText(
        find.byKey(const ValueKey('admin-relay-policy-ports')),
        '22',
      );
      await tester.tap(find.byKey(const ValueKey('admin-relay-policy-save')));
      await tester.pumpAndSettle();
      expect(harness.api.policySaves, 1);
      expect(harness.api.lastExpectedRevision, 8);
      expect(
        find.text(
          'The relay policy changed elsewhere. Reload the latest settings before retrying.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('/private/'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('admin-relay-policy-save')),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const ValueKey('admin-relay-policy-load')));
      await tester.pumpAndSettle();
      expect(harness.api.policyLoads, 2);
      expect(harness.app.instanceAdminRelayPolicy?.revision, 9);
      await tester.tap(find.byKey(const ValueKey('admin-relay-policy-save')));
      await tester.pumpAndSettle();
      expect(harness.api.policySaves, 2);
      expect(harness.api.lastExpectedRevision, 9);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets(
    'deployment unavailable state preserves selected policy and edits',
    (tester) async {
      final harness = await _Harness.create(isAdmin: true);
      harness.api.currentPolicy = _policyJson(
        enabled: true,
        relayAvailable: false,
      );
      try {
        await _pumpSettings(tester, harness.app);
        await tester.ensureVisible(
          find.byKey(const ValueKey('admin-relay-policy-load')),
        );
        await tester.tap(find.byKey(const ValueKey('admin-relay-policy-load')));
        await tester.pumpAndSettle();
        expect(find.text('Unavailable (deployment gate)'), findsOneWidget);
        expect(
          find.textContaining('The saved policy remains selected as enabled'),
          findsOneWidget,
        );
        expect(
          find.textContaining('ATERMIUS_RELAY_ENABLED=true'),
          findsOneWidget,
        );

        await tester.enterText(
          find.byKey(const ValueKey('admin-relay-policy-cidrs')),
          '10.40.2.0/24',
        );
        await tester.tap(
          find.byKey(const ValueKey('admin-relay-policy-enabled')),
        );
        await tester.pump();
        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const ValueKey('admin-relay-policy-enabled')),
              )
              .value,
          isFalse,
        );
        await tester.tap(find.byKey(const ValueKey('admin-relay-policy-save')));
        await tester.pumpAndSettle();
        expect(harness.api.policySaves, 1);
        expect(harness.api.lastDraft?.enabled, isFalse);
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets(
    'outside-limits response keeps form edits without server details',
    (tester) async {
      final harness = await _Harness.create(isAdmin: true);
      harness.api.currentPolicy = _policyJson(enabled: false);
      harness.api.outsideLimitsNextSave = true;
      try {
        await _pumpSettings(tester, harness.app);
        await tester.ensureVisible(
          find.byKey(const ValueKey('admin-relay-policy-load')),
        );
        await tester.tap(find.byKey(const ValueKey('admin-relay-policy-load')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('admin-relay-policy-cidrs')),
          '10.40.4.0/24',
        );
        await tester.enterText(
          find.byKey(const ValueKey('admin-relay-policy-ports')),
          '22',
        );
        await tester.tap(find.byKey(const ValueKey('admin-relay-policy-save')));
        await tester.pumpAndSettle();
        expect(harness.api.policySaves, 1);
        expect(
          find.textContaining('Your edits are still here'),
          findsOneWidget,
        );
        expect(find.textContaining('/private/config'), findsNothing);
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('admin-relay-policy-cidrs')),
              )
              .controller!
              .text,
          '10.40.4.0/24',
        );
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  testWidgets(
    'stale policy stays editable and shows effective deployment limits',
    (tester) async {
      final harness = await _Harness.create(isAdmin: true);
      harness.api.currentPolicy = _policyJson(
        cidrs: ['10.40.0.0/16'],
        ports: [22, 2222],
        limitCidrs: ['10.40.1.0/24'],
        limitPorts: [22],
      );
      try {
        await _pumpSettings(tester, harness.app);
        await tester.ensureVisible(
          find.byKey(const ValueKey('admin-relay-policy-load')),
        );
        await tester.tap(find.byKey(const ValueKey('admin-relay-policy-load')));
        await tester.pumpAndSettle();
        expect(
          find.text('Enabled (current limits restrict effective access)'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'The saved policy exceeds the current deployment ceilings.',
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('admin-relay-policy-cidrs')),
              )
              .controller!
              .text,
          '10.40.0.0/16',
        );
        await tester.enterText(
          find.byKey(const ValueKey('admin-relay-policy-cidrs')),
          '10.40.1.0/24',
        );
        await tester.enterText(
          find.byKey(const ValueKey('admin-relay-policy-ports')),
          '22',
        );
        await tester.tap(find.byKey(const ValueKey('admin-relay-policy-save')));
        await tester.pumpAndSettle();
        expect(harness.api.policySaves, 1);
        expect(harness.api.lastDraft?.allowCidrs, ['10.40.1.0/24']);
        expect(harness.api.lastDraft?.allowPorts, [22]);
      } finally {
        await _dispose(tester, harness);
      }
    },
  );
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
  }
  await tester.pump();
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
  final _WidgetRelayPolicyApi api;
  final AppController app;

  static Future<_Harness> create({required bool isAdmin}) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _WidgetRelayPolicyApi();
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
            accountId: 'account-123',
            deviceId: 'device-456',
            accountKeyEnvelopeVersion: 1,
            accountKeyEnvelope: const {},
            policy: {'instance_admin': isAdmin},
          );
    return _Harness(database, api, app);
  }
}

class _WidgetRelayPolicyApi extends ApiClient {
  _WidgetRelayPolicyApi()
    : super(
        baseUrl: 'https://admin-widget.example.test',
        client: MockClient((_) async => throw StateError('Unexpected request')),
      );

  Map<String, dynamic> currentPolicy = _policyJson(enabled: false);
  int policyLoads = 0;
  int policySaves = 0;
  bool conflictNextSave = false;
  bool outsideLimitsNextSave = false;
  int? lastExpectedRevision;
  AdminRelayPolicyDraft? lastDraft;

  @override
  Future<InstanceAdminRelayPolicy> instanceAdminRelayPolicy() async {
    policyLoads++;
    return InstanceAdminRelayPolicy.fromJson(currentPolicy);
  }

  @override
  Future<InstanceAdminRelayPolicy> updateInstanceAdminRelayPolicy({
    required int expectedRevision,
    required AdminRelayPolicyDraft draft,
    required AdminRelayPolicyLimits deploymentLimits,
  }) async {
    policySaves++;
    lastExpectedRevision = expectedRevision;
    lastDraft = draft;
    if (conflictNextSave) {
      conflictNextSave = false;
      currentPolicy = _policyJson(
        revision: 9,
        enabled: false,
        cidrs: ['10.40.1.0/24'],
        ports: [22],
      );
      throw const ApiException(
        statusCode: 409,
        code: 'RELAY_POLICY_CONFLICT',
        message: 'Unsafe server detail /private/config',
      );
    }
    if (outsideLimitsNextSave) {
      outsideLimitsNextSave = false;
      throw const ApiException(
        statusCode: 422,
        code: 'RELAY_POLICY_OUTSIDE_LIMITS',
        message: 'Policy exceeds deployment limits: /private/config',
      );
    }
    currentPolicy = _policyJson(
      revision: expectedRevision + 1,
      enabled: draft.enabled,
      cidrs: draft.allowCidrs,
      ports: draft.allowPorts,
    );
    return InstanceAdminRelayPolicy.fromJson(currentPolicy);
  }
}

Map<String, dynamic> _policyJson({
  int revision = 8,
  bool enabled = true,
  bool relayAvailable = true,
  List<String> cidrs = const ['10.40.0.0/16'],
  List<int> ports = const [22],
  List<String> limitCidrs = const ['10.40.0.0/16'],
  List<int> limitPorts = const [22, 2222],
}) => {
  'policy': {'enabled': enabled, 'allow_cidrs': cidrs, 'allow_ports': ports},
  'deployment_limits': {
    'relay_available': relayAvailable,
    'allow_cidrs': limitCidrs,
    'allow_ports': limitPorts,
  },
  'max_connections_per_user': 4,
  'revision': revision,
  'updated_at': '2026-10-02T10:00:00Z',
};
