import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _operationId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('posts the frozen request and parses the idempotent receipt', () async {
    http.Request? captured;
    final api = ApiClient(
      baseUrl: 'https://password-change.test',
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'status': 'changed',
            'operation_id': _operationId,
            'credential_version': 2,
            'session_preserved': true,
            'other_sessions_revoked': true,
            'already_applied': true,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    )..accessToken = 'session-token';
    const body = <String, Object?>{
      'operation_id': _operationId,
      'current_login_verifier': 'current-derived-verifier',
      'new_kdf': {
        'id': 'argon2id13',
        'salt': 'new-salt',
        'mem_kib': 65536,
        'iterations': 3,
        'parallelism': 1,
        'version': 1,
      },
      'new_login_verifier': 'new-derived-verifier',
      'account_key_envelope': {
        'version': 1,
        'nonce': 'nonce-bytes',
        'ciphertext': 'wrapped-account-key',
      },
    };
    try {
      final receipt = await api.changePassword(body);
      expect(receipt.operationId, _operationId);
      expect(receipt.credentialVersion, 2);
      expect(receipt.alreadyApplied, isTrue);
      expect(captured?.method, 'POST');
      expect(captured?.url.path, '/api/v1/auth/password-change');
      expect(captured?.headers['authorization'], 'Bearer session-token');
      expect(captured?.body, jsonEncode(body));
    } finally {
      api.close();
    }
  });

  test('rejects invalid operation IDs and mismatched receipts', () async {
    var requestCount = 0;
    final api = ApiClient(
      baseUrl: 'https://password-change.test',
      client: MockClient((request) async {
        requestCount++;
        return http.Response(
          jsonEncode({
            'status': 'changed',
            'operation_id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            'credential_version': 2,
            'session_preserved': true,
            'other_sessions_revoked': true,
            'already_applied': false,
          }),
          200,
        );
      }),
    );
    const validBody = <String, Object?>{'operation_id': _operationId};
    try {
      await expectLater(
        api.changePassword(const {'operation_id': 'not-a-uuid'}),
        throwsA(isA<FormatException>()),
      );
      expect(requestCount, 0);
      await expectLater(
        api.changePassword(validBody),
        throwsA(isA<FormatException>()),
      );
      expect(requestCount, 1);
    } finally {
      api.close();
    }
  });
}
