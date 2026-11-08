import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test(
    'registration sends exactly the token matching the instance phase',
    () async {
      final transport = _RegistrationTransport();
      final api = ApiClient(client: transport, baseUrl: 'https://api.example');
      Future<AuthSession> register({
        String? bootstrapToken,
        String? instanceInvitationToken,
      }) => api.register(
        accountId: '11111111-1111-4111-8111-111111111111',
        username: 'member@example.test',
        bootstrapToken: bootstrapToken,
        instanceInvitationToken: instanceInvitationToken,
        kdf: const {'id': 'argon2id13'},
        loginVerifier: 'verifier',
        accountKeyEnvelope: const {'version': 1},
        device: const {'device_id': 'device'},
        initialVault: const {'vault_id': 'vault'},
      );

      await register(bootstrapToken: 'first-owner-token');
      final bootstrapBody =
          jsonDecode(transport.lastBody!) as Map<String, dynamic>;
      expect(bootstrapBody['bootstrap_token'], 'first-owner-token');
      expect(bootstrapBody.containsKey('instance_invitation_token'), isFalse);

      await register(instanceInvitationToken: 'operator-invite-token');
      final inviteBody =
          jsonDecode(transport.lastBody!) as Map<String, dynamic>;
      expect(inviteBody['instance_invitation_token'], 'operator-invite-token');
      expect(inviteBody.containsKey('bootstrap_token'), isFalse);

      await expectLater(register(), throwsArgumentError);
      await expectLater(
        register(
          bootstrapToken: 'bootstrap',
          instanceInvitationToken: 'invite',
        ),
        throwsArgumentError,
      );
      api.close();
    },
  );
}

class _RegistrationTransport extends http.BaseClient {
  String? lastBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastBody = (request as http.Request).body;
    final response = jsonEncode({
      'account_id': '11111111-1111-4111-8111-111111111111',
      'access_token': 'access',
      'expires_in': 900,
      'refresh_token': 'refresh',
      'device_id': 'device',
      'vaults': const [],
    });
    return http.StreamedResponse(
      Stream.value(utf8.encode(response)),
      201,
      request: request,
      headers: const {'content-type': 'application/json'},
    );
  }
}
