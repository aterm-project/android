import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _userId = '12345678-1234-4234-8234-123456789abc';
const _baseUserPolicy = {
  'user_id': _userId,
  'inherited': false,
  'policy': {
    'enabled': true,
    'allow_cidrs': ['10.24.0.0/16', '2001:db8:1::/48'],
    'allow_ports': [22, 2222],
  },
  'effective_policy': {
    'enabled': true,
    'allow_cidrs': ['10.24.1.0/24'],
    'allow_ports': [22],
  },
  'instance_policy_revision': 5,
  'revision': 7,
  'updated_at': '2026-10-08T15:00:00Z',
};

void main() {
  group('InstanceAdminRelayUserPolicy', () {
    test('parses the strict response and makes policy lists immutable', () {
      final policy = InstanceAdminRelayUserPolicy.fromJson(_baseUserPolicy);

      expect(policy.userId, _userId);
      expect(policy.inherited, isFalse);
      expect(policy.policy.enabled, isTrue);
      expect(policy.policy.allowCidrs, ['10.24.0.0/16', '2001:db8:1::/48']);
      expect(policy.policy.allowPorts, [22, 2222]);
      expect(policy.effectivePolicy.allowCidrs, ['10.24.1.0/24']);
      expect(policy.effectivePolicy.allowPorts, [22]);
      expect(policy.instancePolicyRevision, 5);
      expect(policy.revision, 7);
      expect(policy.updatedAt, DateTime.utc(2026, 10, 8, 15));
      expect(
        () => policy.policy.allowCidrs.add('192.0.2.0/24'),
        throwsUnsupportedError,
      );
      expect(
        () => policy.effectivePolicy.allowPorts.add(2222),
        throwsUnsupportedError,
      );
    });

    test('rejects missing, unknown, or noncanonical response fields', () {
      expect(
        () => InstanceAdminRelayUserPolicy.fromJson({
          ..._baseUserPolicy,
          'unexpected': true,
        }),
        throwsFormatException,
      );
      expect(
        () => InstanceAdminRelayUserPolicy.fromJson(
          Map<String, dynamic>.from(_baseUserPolicy)..remove('user_id'),
        ),
        throwsFormatException,
      );
      expect(
        () => InstanceAdminRelayUserPolicy.fromJson({
          ..._baseUserPolicy,
          'user_id': _userId.toUpperCase(),
        }),
        throwsFormatException,
      );
      expect(
        () => InstanceAdminRelayUserPolicy.fromJson({
          ..._baseUserPolicy,
          'instance_policy_revision': -1,
        }),
        throwsFormatException,
      );
      expect(
        () => InstanceAdminRelayUserPolicy.fromJson({
          ..._baseUserPolicy,
          'revision': -1,
        }),
        throwsFormatException,
      );
      expect(
        () => InstanceAdminRelayUserPolicy.fromJson({
          ..._baseUserPolicy,
          'updated_at': '2026-10-08T15:00:00',
        }),
        throwsFormatException,
      );
      expect(
        () => InstanceAdminRelayUserPolicy.fromJson({
          ..._baseUserPolicy,
          'updated_at': '2026-02-30T15:00:00Z',
        }),
        throwsFormatException,
      );
      expect(
        () => InstanceAdminRelayUserPolicy.fromJson({
          ..._baseUserPolicy,
          'policy': {
            ...(_baseUserPolicy['policy'] as Map<String, dynamic>),
            'enabled_extra': false,
          },
        }),
        throwsFormatException,
      );
      expect(
        () => InstanceAdminRelayUserPolicy.fromJson({
          ..._baseUserPolicy,
          'policy': <Object, Object>{
            'enabled': true,
            'allow_cidrs': ['10.24.0.0/16'],
            'allow_ports': [22],
            1: 'unexpected key',
          },
        }),
        throwsFormatException,
      );
      expect(
        () => InstanceAdminRelayUserPolicy.fromJson({
          ..._baseUserPolicy,
          'policy': {
            'enabled': true,
            'allow_cidrs': ['10.24.1.3/24'],
            'allow_ports': [22],
          },
        }),
        throwsFormatException,
      );
      expect(
        () => InstanceAdminRelayUserPolicy.fromJson({
          ..._baseUserPolicy,
          'policy': {
            'enabled': true,
            'allow_cidrs': ['10.24.0.0/16'],
          },
        }),
        throwsFormatException,
      );
      expect(
        () => InstanceAdminRelayUserPolicy.fromJson({
          ..._baseUserPolicy,
          'policy': {
            'enabled': true,
            'allow_cidrs': ['10.24.0.0/16', '10.0.0.0/8'],
            'allow_ports': [22],
          },
        }),
        throwsFormatException,
      );
      expect(
        () => InstanceAdminRelayUserPolicy.fromJson({
          ..._baseUserPolicy,
          'effective_policy': {
            'enabled': true,
            'allow_cidrs': ['10.24.1.0/24'],
            'allow_ports': [2222, 22],
          },
        }),
        throwsFormatException,
      );
    });

    test(
      'allows a null update timestamp for a never-changed inherited policy',
      () {
        final policy = InstanceAdminRelayUserPolicy.fromJson({
          ..._baseUserPolicy,
          'inherited': true,
          'revision': 0,
          'updated_at': null,
        });
        expect(policy.inherited, isTrue);
        expect(policy.revision, 0);
        expect(policy.updatedAt, isNull);
      },
    );
  });

  test(
    'typed GET PUT and DELETE use the account policy route and exact bodies',
    () async {
      var putObserved = false;
      var deleteObserved = false;
      final api = ApiClient(
        baseUrl: 'https://admin.example.test/proxy/root',
        client: MockClient((request) async {
          expect(
            request.url.path,
            '/proxy/root/api/v1/admin/relay-policy/users/$_userId',
          );
          expect(request.url.hasQuery, isFalse);
          expect(request.headers['authorization'], 'Bearer admin-session');
          switch (request.method) {
            case 'GET':
              expect(request.body, isEmpty);
              return http.Response(jsonEncode(_baseUserPolicy), 200);
            case 'PUT':
              putObserved = true;
              expect(jsonDecode(request.body), {
                'expected_revision': 7,
                'expected_instance_policy_revision': 5,
                'enabled': false,
                'allow_cidrs': ['10.24.0.0/16', '2001:db8:1::/48'],
                'allow_ports': [22, 2222],
              });
              return http.Response(
                jsonEncode({
                  ..._baseUserPolicy,
                  'policy': {
                    ...(_baseUserPolicy['policy'] as Map<String, dynamic>),
                    'enabled': false,
                    'allow_cidrs': ['10.24.0.0/16', '2001:db8:1::/48'],
                  },
                  'effective_policy': {
                    'enabled': false,
                    'allow_cidrs': ['10.24.1.0/24'],
                    'allow_ports': [22],
                  },
                  'revision': 8,
                  'updated_at': '2026-10-08T15:00:30Z',
                }),
                200,
              );
            case 'DELETE':
              deleteObserved = true;
              expect(jsonDecode(request.body), {'expected_revision': 8});
              return http.Response(
                jsonEncode({
                  ..._baseUserPolicy,
                  'inherited': true,
                  'policy': {
                    'enabled': true,
                    'allow_cidrs': ['10.24.0.0/16', '2001:db8:1::/48'],
                    'allow_ports': [22, 2222],
                  },
                  'effective_policy': {
                    'enabled': true,
                    'allow_cidrs': ['10.24.1.0/24'],
                    'allow_ports': [22],
                  },
                  'revision': 9,
                  'updated_at': '2026-10-08T15:01:00Z',
                }),
                200,
              );
            default:
              fail('Unexpected HTTP method ${request.method}.');
          }
        }),
      )..accessToken = 'admin-session';

      final fetched = await api.instanceAdminRelayUserPolicy(_userId);
      expect(fetched.revision, 7);

      final updated = await api.updateInstanceAdminRelayUserPolicy(
        userId: _userId,
        expectedRevision: 7,
        expectedInstancePolicyRevision: 5,
        enabled: false,
        allowCidrs: const ['2001:db8:1::/48', '10.24.0.0/16'],
        allowPorts: const [2222, 22],
      );
      expect(updated.policy.enabled, isFalse);
      expect(updated.policy.allowCidrs, ['10.24.0.0/16', '2001:db8:1::/48']);
      expect(updated.policy.allowPorts, [22, 2222]);
      expect(updated.revision, 8);

      final reset = await api.resetInstanceAdminRelayUserPolicy(
        userId: _userId,
        expectedRevision: 8,
      );
      expect(reset.inherited, isTrue);
      expect(reset.revision, 9);
      expect(putObserved, isTrue);
      expect(deleteObserved, isTrue);
      api.close();
    },
  );

  test(
    'typed user policy writes validate identity, revision, and canonical lists before I/O',
    () async {
      var sent = false;
      final api = ApiClient(
        baseUrl: 'https://admin.example.test',
        client: MockClient((_) async {
          sent = true;
          return http.Response(jsonEncode(_baseUserPolicy), 200);
        }),
      );

      await expectLater(
        api.instanceAdminRelayUserPolicy(_userId.toUpperCase()),
        throwsArgumentError,
      );
      await expectLater(
        api.updateInstanceAdminRelayUserPolicy(
          userId: _userId,
          expectedRevision: -1,
          expectedInstancePolicyRevision: 0,
          enabled: true,
          allowCidrs: const [],
          allowPorts: const [],
        ),
        throwsArgumentError,
      );
      await expectLater(
        api.updateInstanceAdminRelayUserPolicy(
          userId: _userId,
          expectedRevision: 0,
          expectedInstancePolicyRevision: -1,
          enabled: true,
          allowCidrs: const [],
          allowPorts: const [],
        ),
        throwsArgumentError,
      );
      await expectLater(
        api.resetInstanceAdminRelayUserPolicy(
          userId: _userId,
          expectedRevision: -1,
        ),
        throwsArgumentError,
      );
      await expectLater(
        api.updateInstanceAdminRelayUserPolicy(
          userId: _userId,
          expectedRevision: 0,
          expectedInstancePolicyRevision: 0,
          enabled: true,
          allowCidrs: const ['10.24.0.0/16', '10.24.0.0/16'],
          allowPorts: const [22],
        ),
        throwsFormatException,
      );
      expect(sent, isFalse);
      api.close();
    },
  );

  test('rejects a policy response for a different account', () async {
    final api = ApiClient(
      baseUrl: 'https://admin.example.test',
      client: MockClient((_) async {
        return http.Response(
          jsonEncode({
            ..._baseUserPolicy,
            'user_id': '87654321-1234-4234-8234-123456789abc',
          }),
          200,
        );
      }),
    );

    await expectLater(
      api.instanceAdminRelayUserPolicy(_userId),
      throwsFormatException,
    );
    api.close();
  });

  group('effective account edit ceiling', () {
    test(
      'intersects and normalizes nested and disjoint IPv4 and IPv6 CIDRs',
      () {
        final instance = InstanceAdminRelayPolicy.fromJson(
          _instancePolicyResponse(),
        );
        final ceiling = instance.effectiveUserRelayPolicyLimits;

        expect(ceiling.relayAvailable, isTrue);
        expect(ceiling.allowCidrs, [
          '10.1.0.0/16',
          '10.2.0.0/16',
          '172.16.1.0/24',
          '2001:db8:1::/48',
          '2001:db8:2::/48',
          '2001:db9:1::/48',
        ]);
        expect(ceiling.allowPorts, [22, 2222]);
        expect(
          () => ceiling.allowCidrs.add('203.0.113.0/24'),
          throwsUnsupportedError,
        );
        expect(() => ceiling.allowPorts.add(80), throwsUnsupportedError);
      },
    );

    test(
      'is disabled when either the deployment gate or instance policy is off',
      () {
        final disabledByPolicy = InstanceAdminRelayPolicy.fromJson(
          _instancePolicyResponse(policyEnabled: false),
        ).effectiveUserRelayPolicyLimits;
        final disabledByDeployment = InstanceAdminRelayPolicy.fromJson(
          _instancePolicyResponse(relayAvailable: false),
        ).effectiveUserRelayPolicyLimits;

        expect(disabledByPolicy.relayAvailable, isFalse);
        expect(disabledByDeployment.relayAvailable, isFalse);
        expect(disabledByPolicy.allowCidrs, isNotEmpty);
        expect(disabledByDeployment.allowCidrs, isNotEmpty);
      },
    );
  });
}

Map<String, dynamic> _instancePolicyResponse({
  bool policyEnabled = true,
  bool relayAvailable = true,
}) => {
  'policy': {
    'enabled': policyEnabled,
    'allow_cidrs': [
      '10.0.0.0/8',
      '172.16.1.0/24',
      '192.0.2.0/24',
      '2001:db8::/32',
      '2001:db9:1::/48',
    ],
    'allow_ports': [22, 2222, 3306],
  },
  'deployment_limits': {
    'relay_available': relayAvailable,
    'allow_cidrs': [
      '10.1.0.0/16',
      '10.2.0.0/16',
      '172.16.0.0/16',
      '198.51.100.0/24',
      '2001:db8:1::/48',
      '2001:db8:2::/48',
      '2001:db9::/32',
      '2001:dba::/32',
    ],
    'allow_ports': [2222, 80, 22],
  },
  'max_connections_per_user': 1,
  'revision': 4,
  'updated_at': '2026-10-08T14:00:00Z',
};
