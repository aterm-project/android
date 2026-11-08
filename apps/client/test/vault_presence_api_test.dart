import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _vaultId = '55555555-5555-4555-8555-555555555555';
const _userId = '11111111-1111-4111-8111-111111111111';
const _deviceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _seenAt = '2026-10-02T12:30:00Z';

void main() {
  test(
    'heartbeat sends no caller principal and parses the bounded lease',
    () async {
      late http.Request request;
      final api = ApiClient(
        client: MockClient((incoming) async {
          request = incoming as http.Request;
          return http.Response(
            jsonEncode({
              'expires_at': '2026-10-02T12:31:30Z',
              'ttl_seconds': 90,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        baseUrl: 'https://api.example',
      )..accessToken = 'session-token';

      await api.heartbeatVaultPresence(_vaultId);

      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/vaults/$_vaultId/presence');
      expect(request.url.query, isEmpty);
      expect(request.headers['authorization'], 'Bearer session-token');
      expect(request.body, isEmpty);
      api.close();
    },
  );

  test(
    'presence snapshot is strict and contains no Vault or payload fields',
    () async {
      final api = ApiClient(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/vaults/$_vaultId/presence');
          return http.Response(
            jsonEncode({
              'devices': [
                {
                  'user_id': _userId,
                  'device_id': _deviceId,
                  'last_seen_at': _seenAt,
                },
              ],
              'ttl_seconds': 90,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        baseUrl: 'https://api.example',
      );

      final presence = await api.vaultPresence(_vaultId);
      expect(presence.ttlSeconds, 90);
      expect(presence.devices, hasLength(1));
      expect(presence.devices.single.userId, _userId);
      expect(presence.devices.single.deviceId, _deviceId);
      expect(presence.devices.single.lastSeenAt, DateTime.parse(_seenAt));

      expect(
        () => VaultPresenceSnapshot.fromJson({
          'vault_id': _vaultId,
          'devices': const [],
          'ttl_seconds': 90,
        }),
        throwsFormatException,
      );
      expect(
        () => VaultPresenceDevice.fromJson({
          'user_id': _userId,
          'device_id': _deviceId,
          'last_seen_at': _seenAt,
          'host': 'ssh.example.test',
        }),
        throwsFormatException,
      );
      api.close();
    },
  );
}
