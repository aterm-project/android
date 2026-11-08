import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'refresh parses rotated credentials with stable account and device IDs',
    () async {
      final client = ApiClient(
        baseUrl: 'https://sync.example.test/tenant-a',
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/tenant-a/api/v1/auth/refresh');
          expect(request.headers['authorization'], isNull);
          expect(jsonDecode(request.body), {'refresh_token': 'old-refresh'});
          return http.Response(
            jsonEncode({
              'account_id': '12de0000-0000-4000-8000-000000000001',
              'device_id': '12de0000-0000-4000-8000-000000000002',
              'access_token': 'rotated-access',
              'expires_in': 900,
              'refresh_token': 'rotated-refresh',
            }),
            200,
          );
        }),
      );

      final session = await client.refresh('old-refresh');

      expect(session.accountId, '12de0000-0000-4000-8000-000000000001');
      expect(session.deviceId, '12de0000-0000-4000-8000-000000000002');
      expect(session.accessToken, 'rotated-access');
      expect(session.refreshToken, 'rotated-refresh');
      expect(session.expiresIn, 900);
      expect(session.vaults, isEmpty);
      expect(client.accessToken, 'rotated-access');
    },
  );
}
