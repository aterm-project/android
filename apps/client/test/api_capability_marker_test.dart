import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _digest = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

void main() {
  test('authenticated JSON, upload, object and range requests carry a canonical marker', () async {
    final markers = <String>[];
    final api = ApiClient(
      baseUrl: 'https://sync.example.test',
      client: MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer access-token');
        final marker = request.headers['x-atermius-capability-marker'];
        expect(marker, anyOf('v1', 'v2'));
        markers.add(marker!);

        if (request.method == 'GET' && request.url.path == '/api/v1/me') {
          return http.Response('{}', 200);
        }
        if (request.method == 'PUT') return http.Response('{}', 200);
        if (request.headers.containsKey('range')) {
          expect(request.headers['range'], 'bytes=0-1');
          return http.Response.bytes(
            Uint8List.fromList([97, 98]),
            206,
            headers: {
              'etag': '"sha256-$_digest"',
              'content-range': 'bytes 0-1/3',
              'content-length': '2',
            },
          );
        }
        return http.Response.bytes(
          Uint8List.fromList([97, 98, 99]),
          200,
          headers: {'etag': '"sha256-$_digest"'},
        );
      }),
    )..accessToken = 'access-token';

    await api.get('/api/v1/me');
    await api.putBytes('/api/v1/uploads/chunks/0', [1, 2, 3]);
    final object = await api.downloadObjectWithDigest('vault', 'object');
    expect(object.bytes, [97, 98, 99]);
    final range = await api.downloadObjectRange(
      vaultId: 'vault',
      objectId: 'object',
      start: 0,
      end: 1,
      expectedSize: 3,
      expectedSha256: _digest,
    );
    expect(range, [97, 98]);
    expect(markers, hasLength(4));
    expect(markers.toSet(), hasLength(1));
  });
}
