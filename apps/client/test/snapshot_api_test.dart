import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'snapshot without paging arguments keeps the legacy query-free request',
    () async {
      final api = ApiClient(
        baseUrl: 'https://sync.example.test/tenant-a',
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(
            request.url.path,
            '/tenant-a/api/v1/snapshots/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          );
          expect(request.url.queryParameters, isEmpty);
          return http.Response(jsonEncode({'snapshot_id': 'snapshot'}), 200);
        }),
      );

      final result = await api.snapshot('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');

      expect(result['snapshot_id'], 'snapshot');
      api.close();
    },
  );

  test(
    'snapshot page sends limit and opaque page_cursor query parameters',
    () async {
      final api = ApiClient(
        baseUrl: 'https://sync.example.test',
        client: MockClient((request) async {
          expect(request.url.queryParameters, {
            'limit': '100',
            'page_cursor': 'opaque/page+2==',
          });
          return http.Response(jsonEncode({'has_more': false}), 200);
        }),
      );

      final result = await api.snapshot(
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        limit: 100,
        pageCursor: 'opaque/page+2==',
      );

      expect(result['has_more'], isFalse);
      api.close();
    },
  );

  test(
    'snapshot page validates limit and cursor bounds before sending',
    () async {
      final api = ApiClient(baseUrl: 'https://sync.example.test');

      expect(
        () => api.snapshot('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', limit: 101),
        throwsArgumentError,
      );
      expect(
        () => api.snapshot(
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          pageCursor: '',
        ),
        throwsArgumentError,
      );
      api.close();
    },
  );
}
