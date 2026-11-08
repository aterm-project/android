import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _vaultId = '22222222-2222-4222-8222-222222222222';

void main() {
  test(
    'only pre-response Vault sync GET transport failures are typed',
    () async {
      final client = MockClient((request) async {
        throw http.ClientException('connection unavailable', request.url);
      });
      final api = ApiClient(
        client: client,
        baseUrl: 'https://sync-read-classifier.test',
      );
      addTearDown(api.close);

      await expectLater(
        api.get('/api/v1/vaults/$_vaultId/changes'),
        throwsA(isA<SyncReadTransportUnavailableException>()),
      );
      await expectLater(
        api.get('/api/v1/devices'),
        throwsA(isA<SyncReadTransportUnavailableException>()),
      );
      await expectLater(
        api.get('/api/v1/auth/sessions'),
        throwsA(isA<http.ClientException>()),
      );
      await expectLater(
        api.push(_vaultId, const {}),
        throwsA(isA<http.ClientException>()),
      );
    },
  );

  test(
    'HTTP responses and ambiguous timeout errors are never typed offline',
    () async {
      final responseClient = MockClient(
        (_) async => http.Response(
          '{"error":{"code":"SERVICE_UNAVAILABLE","message":"retry"}}',
          503,
        ),
      );
      final responseApi = ApiClient(
        client: responseClient,
        baseUrl: 'https://sync-read-classifier.test',
      );
      addTearDown(responseApi.close);
      await expectLater(
        responseApi.get('/api/v1/vaults/$_vaultId/changes'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'statusCode', 503)
              .having((error) => error.code, 'code', 'SERVICE_UNAVAILABLE'),
        ),
      );

      final timeoutClient = MockClient((_) async {
        throw TimeoutException('response timing is ambiguous');
      });
      final timeoutApi = ApiClient(
        client: timeoutClient,
        baseUrl: 'https://sync-read-classifier.test',
      );
      addTearDown(timeoutApi.close);
      await expectLater(
        timeoutApi.get('/api/v1/vaults/$_vaultId/changes'),
        throwsA(isA<TimeoutException>()),
      );
    },
  );

  test(
    'control-plane GET transport failures are retryable and writes stay ambiguous',
    () async {
      final offlineClient = MockClient((request) async {
        throw http.ClientException('connection unavailable', request.url);
      });
      final offlineApi = ApiClient(
        client: offlineClient,
        baseUrl: 'https://sync-read-classifier.test',
      );
      addTearDown(offlineApi.close);
      await expectLater(
        offlineApi.get('/api/v1/vaults'),
        throwsA(
          isA<ApiTransportException>()
              .having((error) => error.method, 'method', 'GET')
              .having((error) => error.path, 'path', '/api/v1/vaults'),
        ),
      );
      await expectLater(
        offlineApi.get('/api/v1/vaults/$_vaultId/membership'),
        throwsA(isA<ApiTransportException>()),
      );

      final timeoutClient = MockClient((_) async {
        throw TimeoutException('request timed out');
      });
      final timeoutApi = ApiClient(
        client: timeoutClient,
        baseUrl: 'https://sync-read-classifier.test',
      );
      addTearDown(timeoutApi.close);
      await expectLater(
        timeoutApi.get('/api/v1/devices'),
        throwsA(isA<ApiTransportException>()),
      );

      await expectLater(
        offlineApi.post('/api/v1/vaults', const {'vault_id': _vaultId}),
        throwsA(isA<http.ClientException>()),
      );
    },
  );

  test('control-plane response body errors and stalls are retryable', () async {
    final brokenBodyApi = ApiClient(
      client: _StreamedResponseClient(
        (_) => Stream<List<int>>.error(
          http.ClientException('connection reset while reading body'),
        ),
      ),
      baseUrl: 'https://sync-read-classifier.test',
    );
    addTearDown(brokenBodyApi.close);
    await expectLater(
      brokenBodyApi.get('/api/v1/vaults/$_vaultId/devices'),
      throwsA(
        isA<ApiTransportException>().having(
          (error) => error.path,
          'path',
          '/api/v1/vaults/$_vaultId/devices',
        ),
      ),
    );

    final stalledBodyApi = ApiClient(
      client: _StreamedResponseClient((_) => _neverEndingBody()),
      baseUrl: 'https://sync-read-classifier.test',
      controlPlaneResponseBodyTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(stalledBodyApi.close);
    await expectLater(
      stalledBodyApi.get('/api/v1/vaults'),
      throwsA(isA<ApiTransportException>()),
    );

    final malformedApi = ApiClient(
      client: MockClient((_) async => http.Response('{"vaults":[{}]}', 200)),
      baseUrl: 'https://sync-read-classifier.test',
    );
    addTearDown(malformedApi.close);
    await expectLater(malformedApi.vaults(), throwsA(isA<TypeError>()));

    final ambiguousWriteApi = ApiClient(
      client: _StreamedResponseClient(
        (_) => Stream<List<int>>.error(
          http.ClientException('connection reset while reading body'),
        ),
      ),
      baseUrl: 'https://sync-read-classifier.test',
    );
    addTearDown(ambiguousWriteApi.close);
    await expectLater(
      ambiguousWriteApi.post('/api/v1/vaults', const {'vault_id': _vaultId}),
      throwsA(isA<http.ClientException>()),
    );
  });

  test(
    'auth, device, membership, epoch and CAS HTTP errors stay fail-closed',
    () async {
      const cases = <({int status, String code})>[
        (status: 401, code: 'AUTH_REQUIRED'),
        (status: 403, code: 'DEVICE_REVOKED'),
        (status: 403, code: 'VAULT_ACCESS_REVOKED'),
        (status: 409, code: 'KEY_EPOCH_OUTDATED'),
        (status: 409, code: 'MEMBERSHIP_VERSION_CONFLICT'),
        (status: 409, code: 'REVISION_CONFLICT'),
      ];
      for (final item in cases) {
        final client = MockClient(
          (_) async => http.Response(
            '{"error":{"code":"${item.code}","message":"rejected"}}',
            item.status,
          ),
        );
        final api = ApiClient(
          client: client,
          baseUrl: 'https://sync-read-classifier.test',
        );
        await expectLater(
          api.get('/api/v1/vaults/$_vaultId/changes'),
          throwsA(
            isA<ApiException>()
                .having((error) => error.statusCode, 'statusCode', item.status)
                .having((error) => error.code, 'code', item.code),
          ),
        );
        api.close();
      }
    },
  );

  test('malformed successful sync responses are never typed offline', () async {
    final client = MockClient((_) async => http.Response('{}', 200));
    final api = ApiClient(
      client: client,
      baseUrl: 'https://sync-read-classifier.test',
    );
    addTearDown(api.close);
    await expectLater(api.changes(_vaultId), throwsA(isA<TypeError>()));
  });
}

class _StreamedResponseClient extends http.BaseClient {
  _StreamedResponseClient(this.bodyForRequest);

  final Stream<List<int>> Function(http.BaseRequest request) bodyForRequest;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        bodyForRequest(request),
        200,
        request: request,
        headers: const {'content-type': 'application/json'},
      );
}

Stream<List<int>> _neverEndingBody() => Stream<List<int>>.multi((_) {});
