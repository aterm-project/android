import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'ticket request is authenticated, body is empty, and ticket is validated',
    () async {
      var requests = 0;
      final client = ApiClient(
        baseUrl: 'https://sync.example.test/tenant-a',
        client: MockClient((request) async {
          requests++;
          expect(request.method, 'POST');
          expect(request.url.path, '/tenant-a/api/v1/notifications/tickets');
          expect(request.headers['authorization'], 'Bearer session-access');
          expect(jsonDecode(request.body), isEmpty);
          return http.Response(
            jsonEncode({
              'ticket': 'A' * 43,
              'expires_at': '2026-09-27T10:00:30Z',
              'expires_in_seconds': 30,
            }),
            200,
          );
        }),
      )..accessToken = 'session-access';

      final ticket = await client.createNotificationTicket();
      expect(requests, 1);
      expect(ticket.ticket, 'A' * 43);
      expect(ticket.expiresInSeconds, 30);
      expect(ticket.expiresAt.isUtc, isTrue);
      expect(
        client.notificationsWebSocketUri().toString(),
        'wss://sync.example.test/tenant-a/api/v1/notifications',
      );
      expect(client.notificationsOrigin, 'https://sync.example.test');
    },
  );

  test('ticket parser rejects malformed, padded, and wrong-size tickets', () {
    expect(
      () => NotificationTicket.fromJson({
        'ticket': 'A' * 44,
        'expires_at': '2026-09-27T10:00:30Z',
        'expires_in_seconds': 30,
      }),
      throwsFormatException,
    );
    expect(
      () => NotificationTicket.fromJson({
        'ticket': 'A' * 42 + '=',
        'expires_at': '2026-09-27T10:00:30Z',
        'expires_in_seconds': 30,
      }),
      throwsFormatException,
    );
    expect(
      () => NotificationTicket.fromJson({
        'ticket': 'A' * 43,
        'expires_at': '2026-09-27T10:00:30Z',
        'expires_in_seconds': 0,
      }),
      throwsFormatException,
    );
  });
}
