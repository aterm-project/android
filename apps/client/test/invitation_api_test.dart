import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test(
    'vault invitation is authenticated and token stays in JSON body',
    () async {
      final transport = _InvitationTransport();
      final api = ApiClient(client: transport, baseUrl: 'https://api.example');
      api.accessToken = 'session-secret';

      final created = await api.invite('vault-uuid', const {
        'role': 'viewer',
        'recipient_device_id': 'target-device',
        'recipient_encryption_public_key': 'registered-device-key',
        'key_envelope': {'key_epoch': 1},
        'membership': {'membership_version': 2},
      });
      expect(created['token'], 'one-time-token');
      expect(transport.lastUri!.path, '/api/v1/vaults/vault-uuid/invitations');
      expect(transport.lastHeaders['authorization'], 'Bearer session-secret');
      expect(
        jsonDecode(transport.lastBody!)['recipient_encryption_public_key'],
        'registered-device-key',
      );

      await api.acceptInvitation('invitation-secret', const {});
      expect(transport.lastUri!.path, '/api/v1/invitations/accept');
      expect(transport.lastUri!.query, isEmpty);
      expect(transport.lastHeaders['authorization'], 'Bearer session-secret');
      expect(jsonDecode(transport.lastBody!)['token'], 'invitation-secret');
      api.close();
    },
  );
}

class _InvitationTransport extends http.BaseClient {
  Uri? lastUri;
  Map<String, String> lastHeaders = const {};
  String? lastBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastUri = request.url;
    lastHeaders = request.headers;
    lastBody = (request as http.Request).body;
    final payload = request.url.path.endsWith('/invitations')
        ? {'token': 'one-time-token'}
        : {'invitation_id': 'id', 'vault_id': 'vault', 'status': 'accepted'};
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(payload))),
      200,
      request: request,
      headers: const {'content-type': 'application/json'},
    );
  }
}
