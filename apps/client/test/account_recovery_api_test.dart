import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'authenticated recovery endpoints use the expected verbs and DTOs',
    () async {
      final requests = <http.Request>[];
      final api = ApiClient(
        baseUrl: 'https://recovery.test/root',
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/recovery/contexts')) {
            return http.Response(
              jsonEncode({
                'status': 'disabled',
                'recovery_generation': 7,
                'recovery_identity_envelope': null,
                'recovery_public_signing_key': null,
                'recovery_public_encryption_key': null,
                'descriptor_hash': null,
                'required_contexts': [
                  {
                    'vault_id': '11111111-1111-4111-8111-111111111111',
                    'key_epoch': 2,
                    'membership_version': 3,
                  },
                ],
                'present_contexts': [],
                'key_envelopes': [],
              }),
              200,
            );
          }
          return http.Response(jsonEncode({'status': 'ok'}), 200);
        }),
      )..accessToken = 'session-token';
      try {
        final contexts = await api.accountRecoveryContexts();
        expect(contexts.status, 'disabled');
        expect(contexts.generation, 7);
        expect(contexts.required.single.keyEpoch, 2);
        expect(contexts.required.single.membershipVersion, 3);
        await api.configureAccountRecovery(const {'operation_id': 'setup'});
        await api.uploadAccountRecoveryKeyEnvelopes(const {
          'operation_id': 'upload',
        });
        await api.disableAccountRecovery(const {'operation_id': 'delete'});
        expect(requests.map((request) => request.method), [
          'GET',
          'PUT',
          'PUT',
          'DELETE',
        ]);
        expect(requests.map((request) => request.url.path), [
          '/root/api/v1/auth/recovery/contexts',
          '/root/api/v1/auth/recovery',
          '/root/api/v1/auth/recovery/key-envelopes',
          '/root/api/v1/auth/recovery',
        ]);
        expect(requests.first.headers['authorization'], 'Bearer session-token');
      } finally {
        api.close();
      }
    },
  );

  test('anonymous recovery endpoints omit bearer authentication', () async {
    final requests = <http.Request>[];
    final api = ApiClient(
      baseUrl: 'https://recovery.test',
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(jsonEncode({'status': 'ok'}), 200);
      }),
    )..accessToken = 'must-not-leak';
    try {
      await api.startAccountRecovery('person@example.test');
      await api.inspectAccountRecovery(const {'challenge_id': 'challenge'});
      await api.completeAccountRecovery(const {'operation_id': 'operation'});
      expect(requests.map((request) => request.method), [
        'POST',
        'POST',
        'POST',
      ]);
      expect(requests.map((request) => request.url.path), [
        '/api/v1/auth/recovery/start',
        '/api/v1/auth/recovery/inspect',
        '/api/v1/auth/recovery/complete',
      ]);
      expect(
        requests.every((request) => request.headers['authorization'] == null),
        isTrue,
      );
    } finally {
      api.close();
    }
  });
}
