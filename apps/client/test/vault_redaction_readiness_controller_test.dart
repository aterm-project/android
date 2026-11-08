// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/domain/device_redaction_capability.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:drift/native.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const vaultId = '55555555-5555-4555-8555-555555555555';
  const accountId = '33333333-3333-4333-8333-333333333333';
  const instanceId = '11111111-1111-4111-8111-111111111111';
  const serverSpaceId = '22222222-2222-4222-8222-222222222222';

  test(
    'explicit readiness refresh advances an invalidated current-device report and refetches the Vault roster',
    () async {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final secureStore = ClientSecureStore(const FlutterSecureStorage());
      final identity = DeviceIdentity.create(sodium);
      const serverRevisionFloor = 4;
      final submittedRevisions = <int>[];
      var rosterReads = 0;
      Map<String, dynamic>? acceptedReport;

      Map<String, dynamic> signedReport({
        required int revision,
        String? invalidatedAt,
      }) {
        final unsigned = <String, Object?>{
          'format': deviceRedactionCapabilityFormat,
          'account_id': accountId,
          'device_id': identity.deviceId,
          'revision': revision,
          'sync_redaction_version': 1,
        };
        final signature = sodium.crypto.sign.detached(
          message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
          secretKey: identity.signing.secretKey,
        );
        return {
          ...unsigned,
          'signature': encodeBase64Url(signature),
          'invalidated_at': invalidatedAt,
        };
      }

      final invalidatedReport = signedReport(
        revision: serverRevisionFloor,
        invalidatedAt: '2026-10-12T09:00:00Z',
      );
      final api = ApiClient(
        baseUrl: 'https://readiness.example.test',
        client: MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path == '/api/v1/vaults/$vaultId/devices') {
            rosterReads++;
            final report = rosterReads == 1
                ? invalidatedReport
                : acceptedReport;
            return http.Response(
              jsonEncode({
                'devices': [
                  {
                    'device_id': identity.deviceId,
                    'user_id': accountId,
                    'name': 'This browser',
                    'signing_public_key': identity.signingPublicKey,
                    'status': 'active',
                    'membership_status': 'active',
                    'redaction_capability_report': report,
                  },
                ],
              }),
              200,
            );
          }
          if (request.method == 'PUT' &&
              request.url.path == '/api/v1/devices/redaction-capabilities') {
            expect(request.headers['x-atermius-redaction-marker'], 'v1');
            final report = Map<String, dynamic>.from(
              jsonDecode(request.body) as Map,
            );
            final revision = report['revision']! as int;
            submittedRevisions.add(revision);
            if (revision <= serverRevisionFloor) {
              return http.Response(
                jsonEncode({
                  'error': {
                    'code': 'DEVICE_REDACTION_CAPABILITY_REVISION_CONFLICT',
                    'message': 'The report revision must increase.',
                  },
                }),
                409,
              );
            }
            acceptedReport = {...report, 'invalidated_at': null};
            return http.Response(
              jsonEncode({
                'status': 'stored',
                'already_applied': false,
                'redaction_capability_report': acceptedReport,
              }),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      )..accessToken = 'test-token';

      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: secureStore,
            )
            ..stage = ClientStage.workspace
            ..api = api
            ..account = AccountProfile(
              accountId: accountId,
              deviceId: identity.deviceId,
              accountKeyEnvelopeVersion: 1,
              accountKeyEnvelope: {},
            )
            ..identity = identity
            ..instance = const InstanceInfo(
              instanceId: instanceId,
              serverSpaceId: serverSpaceId,
              generation: '1',
              protocolVersion: 1,
              setupRequired: false,
              capabilities: ['device_redaction_capability_reports'],
            )
            ..activeVault = const VaultDescriptor(
              id: vaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            );

      try {
        await app.refreshVaultDeviceRows(recoverCurrentDevice: true);

        expect(rosterReads, 2);
        expect(submittedRevisions, [1, 2, 3, 4, 5]);
        expect(acceptedReport?['revision'], 5);
        expect(app.activeVaultDeviceRows, hasLength(1));
        expect(
          DeviceRedactionReadiness.fromVaultDeviceRow(
            app.activeVaultDeviceRows.single,
            crypto: app.crypto,
          ).status,
          DeviceRedactionReadinessStatus.ready,
        );
      } finally {
        app.dispose();
        identity.dispose();
        await database.close();
      }
    },
  );
}
