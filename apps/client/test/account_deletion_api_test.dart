import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('account deletion uses authenticated verifier-only JSON', () async {
    final api = ApiClient(
      baseUrl: 'https://account-delete.test/tenant',
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/tenant/api/v1/account/delete');
        expect(request.headers['authorization'], 'Bearer session-token');
        expect(jsonDecode(request.body), {'login_verifier': 'v' * 43});
        return _json({
          'status': 'deleting',
          'requested_at': '2026-09-27T00:00:00Z',
          'purge_after': '2026-10-04T00:00:00Z',
          'can_cancel': true,
        });
      }),
    )..accessToken = 'session-token';
    try {
      final response = await api.deleteAccount({'login_verifier': 'v' * 43});
      expect(response['status'], 'deleting');
      expect(response['purge_after'], '2026-10-04T00:00:00Z');
    } finally {
      api.close();
    }
  });

  test(
    'account deletion cancellation is sessionless and returns no session',
    () async {
      final api = ApiClient(
        baseUrl: 'https://account-delete.test/tenant',
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/tenant/api/v1/account/delete/cancel');
          expect(request.headers.containsKey('authorization'), isFalse);
          expect(jsonDecode(request.body), {
            'username': 'user@example.test',
            'login_verifier': 'v' * 43,
          });
          return _json({
            'status': 'active',
            'requested_at': null,
            'purge_after': null,
            'can_cancel': false,
          });
        }),
      )..accessToken = 'stale-revoked-token';
      try {
        final response = await api.cancelAccountDeletion(
          username: 'user@example.test',
          body: {'login_verifier': 'v' * 43},
        );
        expect(response['status'], 'active');
        expect(response.containsKey('access_token'), isFalse);
        expect(api.accessToken, 'stale-revoked-token');
      } finally {
        api.close();
      }
    },
  );
}

http.Response _json(Map<String, Object?> value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);
