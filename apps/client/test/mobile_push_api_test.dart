import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _deviceId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _apnsToken = '0123456789abcdef0123456789abcdef';
const _fcmToken = 'fcm-token-0123456789abcdef';

void main() {
  test(
    'registers the exact provider token only on the authenticated device path',
    () async {
      final requests = <http.Request>[];
      final client = ApiClient(
        baseUrl: 'https://sync.example.test/tenant',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'status': 'registered',
              'device_id': _deviceId,
              'provider': 'apns',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..accessToken = 'access-session';

      final result = await client.registerMobilePushEndpoint(
        deviceId: _deviceId,
        provider: 'apns',
        token: _apnsToken,
      );

      expect(result.status, 'registered');
      expect(result.deviceId, _deviceId);
      expect(result.provider, 'apns');
      expect(requests, hasLength(1));
      expect(requests.single.method, 'PUT');
      expect(
        requests.single.url.path,
        '/tenant/api/v1/notifications/push-endpoints/$_deviceId',
      );
      expect(requests.single.headers['authorization'], 'Bearer access-session');
      expect(jsonDecode(requests.single.body), {
        'provider': 'apns',
        'token': _apnsToken,
      });
      expect(requests.single.body, contains(_apnsToken));

      client.close();
    },
  );

  test(
    'deletes the exact provider and strictly validates response shape',
    () async {
      final requests = <http.Request>[];
      final client = ApiClient(
        baseUrl: 'https://sync.example.test',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'status': 'removed',
              'device_id': _deviceId,
              'provider': 'fcm_v1',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final result = await client.removeMobilePushEndpoint(
        deviceId: _deviceId,
        provider: 'fcm_v1',
      );
      expect(result.status, 'removed');
      expect(result.provider, 'fcm_v1');
      expect(requests.single.method, 'DELETE');
      expect(
        requests.single.url.path,
        '/api/v1/notifications/push-endpoints/$_deviceId/fcm_v1',
      );

      final malformed = ApiClient(
        baseUrl: 'https://sync.example.test',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'status': 'removed',
              'device_id': _deviceId,
              'provider': 'fcm_v1',
              'token': _apnsToken,
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      await expectLater(
        malformed.removeMobilePushEndpoint(
          deviceId: _deviceId,
          provider: 'fcm_v1',
        ),
        throwsFormatException,
      );
      await expectLater(
        client.removeMobilePushEndpoint(
          deviceId: _deviceId,
          provider: 'unknown',
        ),
        throwsArgumentError,
      );
      client.close();
      malformed.close();
    },
  );

  test(
    'registers a valid FCM token with the provider-specific contract',
    () async {
      final client = ApiClient(
        baseUrl: 'https://sync.example.test',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'status': 'registered',
              'device_id': _deviceId,
              'provider': 'fcm_v1',
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );

      final result = await client.registerMobilePushEndpoint(
        deviceId: _deviceId,
        provider: 'fcm_v1',
        token: _fcmToken,
      );
      expect(result.provider, 'fcm_v1');
      client.close();
    },
  );

  test(
    'rejects malformed device IDs and tokens without sending requests',
    () async {
      var requests = 0;
      final client = ApiClient(
        baseUrl: 'https://sync.example.test',
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );

      expect(
        () => client.registerMobilePushEndpoint(
          deviceId: _deviceId.toUpperCase(),
          provider: 'fcm_v1',
          token: 'opaque-mobile-token-0123456789',
        ),
        throwsArgumentError,
      );
      expect(
        () => client.registerMobilePushEndpoint(
          deviceId: _deviceId,
          provider: 'fcm_v1',
          token: 'short',
        ),
        throwsArgumentError,
      );
      expect(
        () => client.registerMobilePushEndpoint(
          deviceId: _deviceId,
          provider: 'fcm_v1',
          token: 'has whitespace token 123456',
        ),
        throwsArgumentError,
      );
      for (final invalidApnsToken in [
        'short',
        List.filled(32, 'g').join(),
        List.filled(33, '0').join(),
        List.filled(514, 'a').join(),
      ]) {
        expect(
          () => client.registerMobilePushEndpoint(
            deviceId: _deviceId,
            provider: 'apns',
            token: invalidApnsToken,
          ),
          throwsArgumentError,
        );
      }
      expect(requests, 0);
      client.close();
    },
  );
}
