import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/domain/conflict_feed.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _vaultId = '22222222-2222-4222-8222-222222222222';
const _conflictId = '55555555-5555-4555-8555-555555555555';
const _recordId = '33333333-3333-4333-8333-333333333333';
const _generation = '88888888-8888-4888-8888-888888888888';

void main() {
  test(
    'first page omits both cursor and generation query parameters',
    () async {
      final client = ApiClient(
        baseUrl: 'https://sync.example.test',
        client: MockClient((request) async {
          expect(request.url.queryParameters, {'limit': '100'});
          return http.Response(
            jsonEncode({
              'vault_id': _vaultId,
              'after_seq': '0',
              'high_watermark': '0',
              'events': [],
              'next_after_seq': '0',
              'has_more': false,
              'server_generation': _generation,
            }),
            200,
          );
        }),
      );

      final page = await client.conflictChanges(
        _vaultId,
        afterSeq: null,
        serverGeneration: null,
      );

      expect(page.afterSeq, '0');
      expect(page.nextAfterSeq, '0');
      client.close();
    },
  );

  test('requests a generation-scoped page and parses opaque events', () async {
    final client = ApiClient(
      baseUrl: 'https://sync.example.test/tenant-a',
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.path,
          '/tenant-a/api/v1/vaults/$_vaultId/conflict-changes',
        );
        expect(request.url.queryParameters, {
          'after_seq': '900719925474099312345',
          'limit': '100',
          'server_generation': _generation,
        });
        expect(request.headers['authorization'], 'Bearer access-token');
        return http.Response(
          jsonEncode({
            'vault_id': _vaultId,
            'after_seq': '900719925474099312345',
            'high_watermark': '900719925474099312347',
            'events': [
              {
                'seq': '900719925474099312346',
                'type': 'created',
                'conflict_id': _conflictId,
                'record_id': _recordId,
                'base_revision_id': null,
                'resolved_revision_id': null,
                'created_at': '2026-09-27T12:30:00Z',
                'envelope': {'ciphertext': 'opaque'},
              },
              {
                'seq': '900719925474099312347',
                'type': 'resolved',
                'conflict_id': _conflictId,
                'record_id': _recordId,
                'base_revision_id': null,
                'resolved_revision_id': '66666666-6666-4666-8666-666666666666',
                'created_at': '2026-09-27T12:31:00+00:00',
              },
            ],
            'next_after_seq': '900719925474099312347',
            'has_more': false,
            'server_generation': _generation,
          }),
          200,
        );
      }),
    )..accessToken = 'access-token';

    final page = await client.conflictChanges(
      _vaultId,
      afterSeq: '900719925474099312345',
      serverGeneration: _generation,
    );
    expect(page.events.map((event) => event.type), ['created', 'resolved']);
    expect(page.events.first.envelope, {'ciphertext': 'opaque'});
    expect(page.events.last.envelope, isNull);
    expect(page.nextAfterSeq, '900719925474099312347');
    client.close();
  });

  test('redacted conflict events round-trip their minimal wire shape', () {
    final event = ConflictChangeEvent.fromJson({
      'seq': '7',
      'type': 'redacted',
      'conflict_id': _conflictId,
      'record_id': _recordId,
      'redaction': {'redaction_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'},
    });

    expect(event.toJson().keys.toSet(), {
      'seq',
      'type',
      'conflict_id',
      'record_id',
      'redaction',
    });
    expect(
      ConflictChangeEvent.fromJson(event.toJson()).toJson(),
      event.toJson(),
    );
    expect(
      () => ConflictChangeEvent.fromJson({
        ...event.toJson(),
        'created_at': '2026-09-27T12:30:00Z',
      }),
      throwsFormatException,
    );
  });

  test('rejects malformed or ambiguous event pages as a whole', () {
    final base = <String, dynamic>{
      'vault_id': _vaultId,
      'after_seq': '0',
      'high_watermark': '2',
      'events': [
        {
          'seq': '1',
          'type': 'created',
          'conflict_id': _conflictId,
          'record_id': _recordId,
          'base_revision_id': null,
          'resolved_revision_id': null,
          'created_at': '2026-09-27T12:30:00Z',
          'envelope': {'ciphertext': 'opaque'},
        },
      ],
      'next_after_seq': '1',
      'has_more': true,
      'server_generation': _generation,
    };

    expect(
      () => ConflictChangesPage.fromJson(
        {...base, 'unexpected': true},
        expectedVaultId: _vaultId,
        expectedAfterSeq: '0',
        limit: 100,
      ),
      throwsFormatException,
    );
    final extraEventKey = Map<String, dynamic>.from(base);
    extraEventKey['events'] = [
      {...(base['events'] as List).single as Map<String, dynamic>, 'extra': 1},
    ];
    expect(
      () => ConflictChangesPage.fromJson(
        extraEventKey,
        expectedVaultId: _vaultId,
        expectedAfterSeq: '0',
        limit: 100,
      ),
      throwsFormatException,
    );
    expect(
      () => ConflictChangesPage.fromJson(
        {...base, 'next_after_seq': '2'},
        expectedVaultId: _vaultId,
        expectedAfterSeq: '0',
        limit: 100,
      ),
      throwsFormatException,
    );
  });
}
