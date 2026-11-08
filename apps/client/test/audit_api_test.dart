import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('audit endpoint sends cursor and limit with bearer auth', () async {
    final api = ApiClient(
      baseUrl: 'https://audit.example.test/tenant',
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/tenant/api/v1/audit');
        expect(request.url.queryParameters, {
          'cursor': 'opaque + cursor',
          'limit': '50',
        });
        expect(request.headers['authorization'], 'Bearer audit-session');
        return http.Response(
          jsonEncode({
            'events': [_accountEvent],
            'next_cursor': 'next-page',
            'has_more': true,
          }),
          200,
        );
      }),
    )..accessToken = 'audit-session';

    final page = await api.audit(cursor: 'opaque + cursor', limit: 50);
    expect(page.events, hasLength(1));
    expect(page.events.single.scope, 'account');
    expect(page.events.single.vaultId, isNull);
    expect(
      page.events.single.actorUserId,
      '33333333-3333-4333-8333-333333333333',
    );
    expect(page.nextCursor, 'next-page');
    expect(page.hasMore, isTrue);
  });

  test('default audit query omits optional cursor and default limit', () async {
    final api = ApiClient(
      baseUrl: 'https://audit.example.test',
      client: MockClient((request) async {
        expect(request.url.queryParameters, isEmpty);
        return http.Response(
          jsonEncode({
            'events': [_vaultEvent],
            'next_cursor': null,
            'has_more': false,
          }),
          200,
        );
      }),
    );

    final page = await api.audit();
    expect(page.events.single.scope, 'vault');
    expect(page.events.single.vaultId, '22222222-2222-4222-8222-222222222222');
    expect(page.hasMore, isFalse);
  });

  test(
    'audit API accepts failure events with null actors and session family',
    () async {
      final refreshReuseEvent = {
        ..._accountEvent,
        'actor_user_id': null,
        'actor_device_id': null,
        'action': 'auth.refresh_reuse_detected',
        'resource_type': 'session_family',
        'resource_id': '55555555-5555-4555-8555-555555555555',
        'result': 'failure',
      };
      final api = ApiClient(
        baseUrl: 'https://audit.example.test',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'events': [refreshReuseEvent],
              'next_cursor': null,
              'has_more': false,
            }),
            200,
          ),
        ),
      );

      final page = await api.audit();
      final event = page.events.single;
      expect(event.action, 'auth.refresh_reuse_detected');
      expect(event.scope, 'account');
      expect(event.actorUserId, isNull);
      expect(event.actorDeviceId, isNull);
      expect(event.resourceType, 'session_family');
      expect(event.resourceId, '55555555-5555-4555-8555-555555555555');
      expect(event.result, 'failure');
    },
  );

  test(
    'invalid audit limits and inconsistent page cursors fail closed',
    () async {
      final api = ApiClient(
        baseUrl: 'https://audit.example.test',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await expectLater(api.audit(limit: 201), throwsArgumentError);
      expect(
        () => AuditPage.fromJson({
          'events': [],
          'next_cursor': null,
          'has_more': true,
        }),
        throwsFormatException,
      );
      expect(
        () => AuditEvent.fromJson({..._accountEvent, 'event_id': '01'}),
        throwsFormatException,
      );
      expect(
        () => AuditEvent.fromJson({..._accountEvent, 'scope': 'vault'}),
        throwsFormatException,
      );
      expect(
        () => AuditEvent.fromJson({..._accountEvent, 'result': 'pending'}),
        throwsFormatException,
      );
      expect(
        () => AuditPage.fromJson({
          'events': ['not-an-event-object'],
          'next_cursor': null,
          'has_more': false,
        }),
        throwsFormatException,
      );
      expect(
        () =>
            AuditEvent.fromJson({..._accountEvent}..remove('actor_device_id')),
        throwsFormatException,
      );
      expect(
        () => AuditEvent.fromJson({
          ..._accountEvent,
          'occurred_at': '2026-09-27T12:00:00',
        }),
        throwsFormatException,
      );
    },
  );
}

const _accountEvent = {
  'event_id': '123',
  'scope': 'account',
  'vault_id': null,
  'actor_user_id': '33333333-3333-4333-8333-333333333333',
  'actor_device_id': '44444444-4444-4444-8444-444444444444',
  'action': 'account.created',
  'resource_type': 'account',
  'resource_id': null,
  'result': 'success',
  'occurred_at': '2026-09-27T12:00:00Z',
  'source': 'api',
};

const _vaultEvent = {
  'event_id': '124',
  'scope': 'vault',
  'vault_id': '22222222-2222-4222-8222-222222222222',
  'actor_user_id': '33333333-3333-4333-8333-333333333333',
  'actor_device_id': null,
  'action': 'vault.key_rotated',
  'resource_type': 'vault',
  'resource_id': '22222222-2222-4222-8222-222222222222',
  'result': 'success',
  'occurred_at': '2026-09-27T12:00:00Z',
  'source': 'maintenance',
};
