import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _ticket() => base64Url
    .encode(List<int>.generate(32, (index) => index))
    .replaceAll('=', '');

void main() {
  test(
    'relay ticket request is scoped, authenticated, and validates response',
    () async {
      final ticketValue = _ticket();
      final api = ApiClient(
        baseUrl: 'https://relay.example.test/proxy/space%20one',
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/proxy/space%20one/api/v1/relay/tickets');
          expect(request.url.hasQuery, isFalse);
          expect(request.headers['authorization'], 'Bearer active-session');
          expect(jsonDecode(request.body), {
            'device_id': 'device-123',
            'target_host': '10.24.0.7',
            'target_port': 2222,
          });
          return http.Response(
            jsonEncode({
              'ticket': ticketValue,
              'expires_at': DateTime.now()
                  .toUtc()
                  .add(const Duration(seconds: 20))
                  .toIso8601String(),
              'connect_path': '/relay/v1/connect',
            }),
            200,
          );
        }),
      )..accessToken = 'active-session';

      final ticket = await api.createRelayTicket(
        deviceId: 'device-123',
        targetHost: '10.24.0.7',
        targetPort: 2222,
      );

      expect(ticket.value, ticketValue);
      expect(ticket.expiresAt.isAfter(DateTime.now().toUtc()), isTrue);
      expect(
        api.relayUri().toString(),
        'wss://relay.example.test/proxy/space%20one/relay/v1/connect',
      );
      expect(api.relayUri().hasQuery, isFalse);
      expect(api.relayUri().hasFragment, isFalse);
      api.close();
    },
  );

  test(
    'relay ticket parser rejects malformed, expired, long-lived, or wrong-path replies',
    () {
      final now = DateTime.utc(2026, 9, 27, 12);
      Map<String, dynamic> payload({
        String? ticket,
        String? expiresAt,
        String path = '/relay/v1/connect',
      }) => {
        'ticket': ticket ?? _ticket(),
        'expires_at':
            expiresAt ?? now.add(const Duration(seconds: 30)).toIso8601String(),
        'connect_path': path,
      };

      expect(
        () => RelayTicket.fromJson(payload(ticket: '${_ticket()}='), now: now),
        throwsFormatException,
      );
      expect(
        () => RelayTicket.fromJson(payload(ticket: 'A' * 42), now: now),
        throwsFormatException,
      );
      expect(
        () => RelayTicket.fromJson(
          payload(
            expiresAt: now
                .subtract(const Duration(seconds: 1))
                .toIso8601String(),
          ),
          now: now,
        ),
        throwsFormatException,
      );
      expect(
        () => RelayTicket.fromJson(
          payload(
            expiresAt: now.add(const Duration(seconds: 36)).toIso8601String(),
          ),
          now: now,
        ),
        throwsFormatException,
      );
      expect(
        () => RelayTicket.fromJson(payload(path: '/other/path'), now: now),
        throwsFormatException,
      );
    },
  );

  test(
    'relay websocket URI is secure remotely and permits ws only on loopback',
    () {
      final secure = ApiClient(baseUrl: 'https://public.example.test/tenant');
      expect(secure.relayUri().scheme, 'wss');
      expect(secure.relayUri().path, '/tenant/relay/v1/connect');
      secure.close();

      final loopback = ApiClient(baseUrl: 'http://localhost:8080/tenant');
      expect(
        loopback.relayUri().toString(),
        'ws://localhost:8080/tenant/relay/v1/connect',
      );
      loopback.close();

      expect(
        () => ApiClient(baseUrl: 'http://public.example.test'),
        throwsFormatException,
      );
    },
  );

  test('relay target is validated before a network request', () async {
    var sent = false;
    final api = ApiClient(
      baseUrl: 'https://relay.example.test',
      client: MockClient((_) async {
        sent = true;
        return http.Response('{}', 200);
      }),
    );
    await expectLater(
      api.createRelayTicket(
        deviceId: 'device',
        targetHost: ' 10.0.0.1',
        targetPort: 22,
      ),
      throwsArgumentError,
    );
    await expectLater(
      api.createRelayTicket(
        deviceId: 'device',
        targetHost: '10.0.0.1',
        targetPort: 0,
      ),
      throwsArgumentError,
    );
    expect(sent, isFalse);
    api.close();
  });
}
