import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/attachments/attachment_file_saver.dart'
    show supportsStreamingAttachmentSave;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'every bearer JSON, byte and range request carries exactly one marker',
    () async {
      final digest = List.filled(64, 'a').join();
      final requests = <http.Request>[];
      final api = ApiClient(
        baseUrl: 'https://sync.example.test',
        client: MockClient((request) async {
          requests.add(request);
          if (request.headers.containsKey('range')) {
            return http.Response.bytes(
              [0x5a],
              206,
              headers: {
                'etag': '"sha256-$digest"',
                'content-range': 'bytes 0-0/1',
                'content-length': '1',
              },
            );
          }
          if (request.url.path.contains('/objects/')) {
            return http.Response.bytes(
              [0x5a],
              200,
              headers: {'etag': '"sha256-$digest"'},
            );
          }
          return http.Response('{}', 200);
        }),
      )..accessToken = 'test-access-token';

      await api.get('/api/v1/instance');
      await api.updateDeviceRedactionCapabilities(const {'revision': 1});
      await api.purgeRecord(
        vaultId: '11111111-1111-4111-8111-111111111111',
        recordId: '22222222-2222-4222-8222-222222222222',
        expectedDeletedRevisionId: '33333333-3333-4333-8333-333333333333',
        expectedDeletedSeq: '12',
      );
      await api.setRecordAutomaticPurge(
        vaultId: '11111111-1111-4111-8111-111111111111',
        recordId: '22222222-2222-4222-8222-222222222222',
        expectedDeletedRevisionId: '33333333-3333-4333-8333-333333333333',
        expectedDeletedSeq: '12',
        expectedPolicyRevision: '0',
        enabled: true,
      );
      await api.completeUpload('upload-id', const {});
      await api.putBytes(
        '/api/v1/uploads/chunk',
        [1, 2, 3],
        headers: const {'X-ATERMIUS-REDACTION-MARKER': 'spoofed'},
      );
      await api.downloadObjectWithDigest('vault', 'object');
      final range = await api.downloadObjectRange(
        vaultId: 'vault',
        objectId: 'object',
        start: 0,
        end: 0,
        expectedSize: 1,
        expectedSha256: digest,
      );

      expect(range, [0x5a]);
      expect(requests, hasLength(8));
      final purge = requests.singleWhere(
        (request) => request.url.path.endsWith('/purge'),
      );
      expect(purge.method, 'POST');
      expect(purge.body, contains('"expected_deleted_revision_id"'));
      expect(purge.body, contains('"expected_deleted_seq":"12"'));
      final automaticPurge = requests.singleWhere(
        (request) => request.url.path.endsWith('/automatic-purge'),
      );
      expect(automaticPurge.method, 'PUT');
      const expectedVaultPath =
          '/api/v1/vaults/11111111-1111-4111-8111-111111111111';
      const expectedRecordPath =
          '/records/22222222-2222-4222-8222-222222222222/automatic-purge';
      expect(automaticPurge.url.path, '$expectedVaultPath$expectedRecordPath');
      expect(jsonDecode(automaticPurge.body), {
        'expected_deleted_revision_id': '33333333-3333-4333-8333-333333333333',
        'expected_deleted_seq': '12',
        'expected_policy_revision': '0',
        'enabled': true,
      });
      final marker = supportsStreamingAttachmentSave ? 'v2' : 'v1';
      for (final request in requests) {
        expect(request.headers['authorization'], 'Bearer test-access-token');
        expect(request.headers['x-atermius-capability-marker'], marker);
        final redactionMarkers = request.headers.entries
            .where(
              (entry) =>
                  entry.key.toLowerCase() == 'x-atermius-redaction-marker',
            )
            .toList();
        expect(redactionMarkers, hasLength(1));
        expect(redactionMarkers.single.value, 'v1');
      }
    },
  );

  test('public JSON requests do not send bearer capability markers', () async {
    final api = ApiClient(
      baseUrl: 'https://sync.example.test',
      client: MockClient((request) async {
        expect(request.headers['authorization'], isNull);
        expect(request.headers['x-atermius-capability-marker'], isNull);
        expect(request.headers['x-atermius-redaction-marker'], isNull);
        return http.Response('{}', 200);
      }),
    )..accessToken = 'test-access-token';

    await api.postPublic('/api/v1/auth/login', const {});
  });
}
