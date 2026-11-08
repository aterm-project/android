import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const _vaultId = '22222222-2222-4222-8222-222222222222';
const _requestedAt = '2026-09-26T12:00:00Z';
const _purgeAfter = '2026-10-03T12:00:00Z';

void main() {
  test('vault lifecycle DTO parses active and deletion grace fields', () {
    final deleting = VaultDescriptor.fromJson({
      'vault_id': _vaultId,
      'role': 'owner',
      'active_key_epoch': 3,
      'membership_version': 5,
      'status': 'deleting',
      'requested_at': _requestedAt,
      'purge_after': _purgeAfter,
      'can_cancel': true,
      'can_write': false,
      'name_envelope': {'version': 1},
      'key_envelopes': const [],
    });

    expect(deleting.id, _vaultId);
    expect(deleting.status, 'deleting');
    expect(deleting.requestedAt, _requestedAt);
    expect(deleting.purgeAfter, _purgeAfter);
    expect(deleting.canCancel, isTrue);
    expect(deleting.canWrite, isFalse);
    expect(deleting.role, 'owner');

    final restored = deleting.withLifecycleResponse({
      'vault_id': _vaultId,
      'status': 'active',
      'requested_at': null,
      'purge_after': null,
      'can_cancel': false,
      'can_write': true,
    });
    expect(restored.status, 'active');
    expect(restored.requestedAt, isNull);
    expect(restored.purgeAfter, isNull);
    expect(restored.canCancel, isFalse);
    expect(restored.canWrite, isTrue);
    expect(restored.role, 'owner');
    expect(restored.activeKeyEpoch, '3');
    expect(restored.keyEnvelopes, isEmpty);
  });

  test(
    'delete and cancel send only login_verifier in authenticated JSON',
    () async {
      final transport = _VaultLifecycleTransport();
      final api = ApiClient(client: transport, baseUrl: 'https://api.example');
      api.accessToken = 'session-token';

      final deleting = await api.deleteVault(_vaultId, const {
        'login_verifier': 'derived-client-verifier',
      });
      expect(deleting['status'], 'deleting');
      expect(transport.lastMethod, 'DELETE');
      expect(transport.lastUri!.path, '/api/v1/vaults/$_vaultId');
      expect(transport.lastUri!.query, isEmpty);
      expect(transport.lastHeaders['authorization'], 'Bearer session-token');
      expect(
        jsonDecode(transport.lastBody!)['login_verifier'],
        'derived-client-verifier',
      );
      expect(transport.lastBody, isNot(contains('master-password')));

      final active = await api.cancelVaultDeletion(_vaultId, const {
        'login_verifier': 'another-derived-verifier',
      });
      expect(active['status'], 'active');
      expect(transport.lastMethod, 'POST');
      expect(
        transport.lastUri!.path,
        '/api/v1/vaults/$_vaultId/deletion/cancel',
      );
      expect(transport.lastUri!.query, isEmpty);
      expect(transport.lastHeaders['authorization'], 'Bearer session-token');
      expect(
        jsonDecode(transport.lastBody!)['login_verifier'],
        'another-derived-verifier',
      );
      api.close();
    },
  );

  test(
    'vault list includes server lifecycle state without losing key metadata',
    () async {
      final transport = _VaultLifecycleTransport();
      final api = ApiClient(client: transport, baseUrl: 'https://api.example');
      api.accessToken = 'session-token';
      final vaults = await api.vaults();
      expect(vaults, hasLength(1));
      expect(vaults.single.status, 'deleting');
      expect(vaults.single.canWrite, isFalse);
      expect(vaults.single.purgeAfter, _purgeAfter);
      expect(vaults.single.keyEnvelopes, hasLength(1));
      api.close();
    },
  );
}

class _VaultLifecycleTransport extends http.BaseClient {
  String? lastMethod;
  Uri? lastUri;
  Map<String, String> lastHeaders = const {};
  String? lastBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest baseRequest) async {
    final request = baseRequest as http.Request;
    lastMethod = request.method;
    lastUri = request.url;
    lastHeaders = request.headers.map(
      (key, value) => MapEntry(key.toLowerCase(), value),
    );
    lastBody = request.body;
    final payload = switch (request.method) {
      'DELETE' => _deletingResponse,
      'POST' => _activeResponse,
      'GET' => {
        'vaults': [
          {
            ..._deletingResponse,
            'role': 'owner',
            'active_key_epoch': 3,
            'membership_version': 5,
            'name_envelope': {'version': 1},
            'key_envelopes': [
              {
                'recipient_device_id': 'device-id',
                'key_epoch': 3,
                'membership_version': 5,
                'envelope': {'version': 1},
                'signature': 'sig',
                'signer_device_id': 'signer-id',
              },
            ],
          },
        ],
      },
      _ => <String, Object?>{},
    };
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(payload))),
      200,
      request: request,
      headers: const {'content-type': 'application/json'},
    );
  }
}

final Map<String, Object?> _deletingResponse = {
  'vault_id': _vaultId,
  'status': 'deleting',
  'requested_at': _requestedAt,
  'purge_after': _purgeAfter,
  'can_cancel': true,
  'can_write': false,
};

final Map<String, Object?> _activeResponse = {
  'vault_id': _vaultId,
  'status': 'active',
  'requested_at': null,
  'purge_after': null,
  'can_cancel': false,
  'can_write': true,
};
