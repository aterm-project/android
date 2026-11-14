// Fakes for Credential visibility v1 controller/widget tests: a scripted
// `/api/v1/credential-visibility` server and a signed-in AppController.
import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:drift/native.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

import 'credential_visibility_fixtures.dart';

/// Scripted server for `/api/v1/credential-visibility` and deposits.
class FakeCredentialVisibilityServer {
  FakeCredentialVisibilityServer(this.status);

  Map<String, dynamic> status;
  final List<http.Request> requests = [];
  final List<Map<String, dynamic>> deposits = [];
  ({int status, Map<String, Object?> body})? depositFailure;

  /// Handles every other route (admin routes in widget tests).
  Future<http.Response> Function(http.Request request)? onOtherRequest;

  late final ApiClient api = ApiClient(
    baseUrl: 'https://cv-service.example.test',
    client: MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET' &&
          request.url.path == '/api/v1/credential-visibility') {
        return json(status);
      }
      if (request.method == 'PUT' &&
          request.url.path.startsWith(
            '/api/v1/credential-visibility/escrow/',
          )) {
        final failure = depositFailure;
        if (failure != null) return json(failure.body, failure.status);
        final segments = request.url.pathSegments;
        deposits.add({
          'vault_id': segments[4],
          'key_epoch': int.parse(segments[5]),
          ...jsonDecode(request.body) as Map<String, dynamic>,
        });
        // The server now has the item: drop it from `missing`.
        final remaining = [
          for (final item in status['missing'] as List)
            if (!(item['vault_id'] == segments[4] &&
                item['key_epoch'] == int.parse(segments[5])))
              item,
        ];
        status = {
          ...status,
          'missing': remaining,
          'escrow_status': remaining.isEmpty ? 'complete' : 'pending',
        };
        return json({'status': 'stored'}, 201);
      }
      final fallback = onOtherRequest;
      if (fallback != null) return fallback(request);
      throw StateError('unexpected ${request.method} ${request.url}');
    }),
  )..accessToken = 'token';

  static http.Response json(Object body, [int code = 200]) => http.Response(
    jsonEncode(body),
    code,
    headers: {'content-type': 'application/json'},
  );
}

Map<String, dynamic> cvStatus({
  required String mode,
  String? escrowStatus,
  Map<String, dynamic>? key,
  List<Map<String, Object>> missing = const [],
  String? changedAt,
  List<Map<String, Object?>> views = const [],
}) => {
  'mode': mode,
  'changed_at': changedAt,
  'escrow_status':
      escrowStatus ?? (mode == 'private' ? 'not_required' : 'complete'),
  'escrow_key': key,
  'missing': missing,
  'admin_views': views,
};

/// A signed-in controller whose Vault list tests can replace, so the
/// credential-visibility service's own triggers (new Vault, accepted share,
/// key rotation) can be exercised without a sync server.
class CvTestAppController extends AppController {
  CvTestAppController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  /// Replaces [vaults] while non-null.
  List<VaultDescriptor>? testVaults;

  @override
  List<VaultDescriptor> get vaults => testVaults ?? super.vaults;

  /// Notifies listeners as the controller does after any state change.
  void emitChange() => notifyListeners();
}

CvTestAppController cvApp(
  SodiumSumo sodium,
  ApiClient api, {
  required String pinnedKey,
  Map<String, dynamic>? policy,
  bool capability = true,
  bool admin = false,
  DeviceIdentity? identity,
}) {
  final device = identity ?? DeviceIdentity.create(sodium);
  return CvTestAppController(
      sodium: sodium,
      database: ClientDatabase.forTesting(NativeDatabase.memory()),
      secureStore: ClientSecureStore(),
    )
    ..api = api
    ..instance = InstanceInfo(
      instanceId: escrowInstanceId,
      serverSpaceId: escrowServerSpaceId,
      generation: '1',
      protocolVersion: 1,
      setupRequired: false,
      capabilities: [if (capability) 'credential_visibility'],
      signingPublicKey: pinnedKey,
    )
    ..account = AccountProfile(
      accountId: escrowUserId,
      deviceId: device.deviceId,
      accountKeyEnvelopeVersion: 1,
      accountKeyEnvelope: const {},
      policy: {'instance_admin': admin, ...?policy},
    )
    ..identity = device
    ..session = AuthSession(
      accountId: escrowUserId,
      accessToken: 'token',
      expiresIn: 900,
      refreshToken: 'refresh',
      deviceId: device.deviceId,
      vaults: const [],
    );
}
