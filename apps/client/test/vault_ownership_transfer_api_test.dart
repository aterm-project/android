import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const _vaultId = '55555555-5555-4555-8555-555555555555';
const _newOwnerId = '22222222-2222-4222-8222-222222222222';

void main() {
  test(
    'ownership transfer posts the signed rotation to its dedicated route',
    () async {
      final transport = _OwnershipTransferTransport();
      final api = ApiClient(client: transport, baseUrl: 'https://api.example');
      api.accessToken = 'owner-session';
      const request = <String, Object?>{
        'new_owner_user_id': _newOwnerId,
        'new_epoch': 8,
        'membership': {
          'membership_version': 13,
          'previous_digest': 'previous-digest',
          'manifest': {
            'key_epoch': 8,
            'signer_device_id': '11111111-1111-4111-8111-111111111111',
            'ownership_transfer': {
              'from_user_id': '11111111-1111-4111-8111-111111111111',
              'to_user_id': _newOwnerId,
            },
          },
          'signature': 'signed-manifest',
        },
        'key_envelopes': [
          {'recipient_device_id': '33333333-3333-4333-8333-333333333333'},
        ],
      };

      final result = await api.transferVaultOwnership(_vaultId, request);

      expect(result['owner_user_id'], _newOwnerId);
      expect(transport.method, 'POST');
      expect(
        transport.uri!.path,
        '/api/v1/vaults/$_vaultId/ownership/transfer',
      );
      expect(transport.uri!.query, isEmpty);
      expect(transport.headers['authorization'], 'Bearer owner-session');
      expect(jsonDecode(transport.body!) as Map<String, dynamic>, request);
      api.close();
    },
  );
}

class _OwnershipTransferTransport extends http.BaseClient {
  String? method;
  Uri? uri;
  Map<String, String> headers = const {};
  String? body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest baseRequest) async {
    final request = baseRequest as http.Request;
    method = request.method;
    uri = request.url;
    headers = request.headers.map(
      (key, value) => MapEntry(key.toLowerCase(), value),
    );
    body = request.body;
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"owner_user_id":"$_newOwnerId"}')),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}
