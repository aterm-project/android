import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/account_recovery_crypto.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart' show DeviceIdentity;
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

const _accountId = '11111111-1111-4111-8111-111111111111';
const _instanceId = '22222222-2222-4222-8222-222222222222';
const _serverSpaceId = '33333333-3333-4333-8333-333333333333';
const _vaultId = '44444444-4444-4444-8444-444444444444';
const _uploaderId = '55555555-5555-4555-8555-555555555555';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'full recovery verifies, reseals, confirms, and commits without a session',
    () async {
      final sodium = await SodiumSumoInit.init();
      final recoveryCrypto = AccountRecoveryCrypto(sodium);
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final secureStore = _RecoverySecureStore();
      final oldIdentity = recoveryCrypto.createIdentity(
        accountId: _accountId,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
        generation: 2,
      );
      final recoveryCode = recoveryCrypto.createRecoveryCode();
      final recoveryEnvelope = await recoveryCrypto
          .sealIdentityWithRecoveryCode(
            identity: oldIdentity,
            recoveryCode: recoveryCode,
          );
      final vaultKey = recoveryCrypto.randomBytes(32);
      final oldKeybox = await recoveryCrypto.buildKeyEnvelope(
        identity: oldIdentity,
        uploaderDeviceId: _uploaderId,
        vaultId: _vaultId,
        keyEpoch: 3,
        vaultKey: vaultKey,
      );
      final descriptorHash = await recoveryCrypto.recoveryDescriptorHash(
        accountId: _accountId,
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
        generation: 2,
        signingPublicKey: oldIdentity.signingPublicKey,
        encryptionPublicKey: oldIdentity.encryptionPublicKey,
      );
      const challengeId = '66666666-6666-4666-8666-666666666666';
      final challenge = encodeBase64Url(Uint8List(32));
      Map<String, dynamic>? inspectRequest;
      final completeRequests = <Map<String, dynamic>>[];
      var completionAttempts = 0;

      ApiClient createApi() => ApiClient(
        baseUrl: 'https://recovery.example.test',
        client: MockClient((request) async {
          final body = request.body.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path.endsWith('/recovery/start')) {
            expect(request.headers['authorization'], isNull);
            return _jsonResponse({
              'account_id': _accountId,
              'instance_id': _instanceId,
              'server_space_id': _serverSpaceId,
              'recovery_generation': 2,
              'challenge_id': challengeId,
              'challenge': challenge,
              'expires_at': DateTime.now()
                  .toUtc()
                  .add(const Duration(minutes: 5))
                  .toIso8601String(),
              'recovery_public_signing_key': oldIdentity.signingPublicKey,
              'recovery_public_encryption_key': oldIdentity.encryptionPublicKey,
              'recovery_envelope': recoveryEnvelope,
            });
          }
          if (request.url.path.endsWith('/recovery/inspect')) {
            inspectRequest = body;
            return _jsonResponse({
              'account_id': _accountId,
              'recovery_generation': 2,
              'recovery_descriptor_hash': descriptorHash,
              'required_contexts': [
                {'vault_id': _vaultId, 'key_epoch': 3, 'membership_version': 4},
              ],
              'present_contexts': [oldKeybox],
              'recovery_status': 'current',
            });
          }
          if (request.url.path.endsWith('/recovery/complete')) {
            completeRequests.add(body);
            completionAttempts++;
            if (completionAttempts == 1) {
              return _jsonResponse({
                'code': 'TEMPORARY',
                'message': 'temporary failure',
              }, statusCode: 503);
            }
            final device = body['device'] as Map<String, dynamic>;
            return _jsonResponse({
              'status': 'recovered',
              'device_id': device['device_id'],
            });
          }
          return http.Response('not found', 404);
        }),
      );
      final api = createApi();
      final controller =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: secureStore,
            )
            ..api = api
            ..stage = ClientStage.login
            ..instance = const InstanceInfo(
              instanceId: _instanceId,
              serverSpaceId: _serverSpaceId,
              generation: '1',
              protocolVersion: 1,
              setupRequired: false,
              capabilities: [],
            );
      var controllerDisposed = false;

      try {
        secureStore.pendingRecovery = PendingAccountRecoveryStorageData(
          request: const {},
          device: const {},
          challengeExpiresAt: DateTime.now().toUtc(),
          completionAttempted: false,
        );
        await controller.restorePendingFullAccountRecovery();
        expect(secureStore.pendingRecovery, isNull);
        expect(controller.hasPreparedFullAccountRecovery, isFalse);

        final prepared = await controller.prepareFullAccountRecovery(
          username: 'User@Example.test',
          recoveryCode: recoveryCode,
          newPassword: 'a different long password',
          confirmationPassword: 'a different long password',
          deviceName: 'Recovery laptop',
        );
        expect(prepared.recoveredContexts, 1);
        expect(prepared.recoveryCode, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        expect(controller.session, isNull);
        expect(secureStore.savedDevice, isNull);
        expect(secureStore.pendingRecovery?.completionAttempted, isFalse);
        expect(
          jsonEncode(
            secureStore.pendingRecovery?.request,
          ).contains(prepared.recoveryCode),
          isFalse,
        );

        final inspected = inspectRequest!;
        final inspectSignature = decodeBase64Url(
          inspected['recovery_signature'] as String,
        );
        expect(
          recoveryCrypto.verifyDetached(
            signature: inspectSignature,
            publicKey: oldIdentity.signing.publicKey,
            payload: {
              'protocol': 'atermius-account-recovery-inspect-v1',
              'account_id': _accountId,
              'instance_id': _instanceId,
              'server_space_id': _serverSpaceId,
              'recovery_generation': 2,
              'challenge_id': challengeId,
              'challenge': challenge,
              'recovery_descriptor_hash': descriptorHash,
            },
          ),
          isTrue,
        );
        inspectSignature.fillRange(0, inspectSignature.length, 0);

        await expectLater(
          controller.completePreparedAccountRecovery(),
          throwsA(anything),
        );
        expect(controller.hasPreparedFullAccountRecovery, isTrue);
        expect(secureStore.pendingRecovery?.completionAttempted, isTrue);
        expect(secureStore.savedDevice, isNull);
        expect(completeRequests, hasLength(1));

        controller.dispose();
        controllerDisposed = true;
        api.close();
        final resumedApi = createApi();
        final resumedController =
            AppController(
                sodium: sodium,
                database: database,
                secureStore: secureStore,
              )
              ..api = resumedApi
              ..stage = ClientStage.login
              ..instance = const InstanceInfo(
                instanceId: _instanceId,
                serverSpaceId: _serverSpaceId,
                generation: '1',
                protocolVersion: 1,
                setupRequired: false,
                capabilities: [],
              );
        try {
          await resumedController.restorePendingFullAccountRecovery();
          expect(resumedController.hasPreparedFullAccountRecovery, isTrue);
          await resumedController.completePreparedAccountRecovery();
          expect(resumedController.session, isNull);
          expect(resumedController.stage, ClientStage.login);
        } finally {
          resumedController.dispose();
          resumedApi.close();
        }
        expect(completeRequests, hasLength(2));
        expect(
          jsonEncode(completeRequests[1]),
          jsonEncode(completeRequests[0]),
        );
        expect(secureStore.pendingRecovery, isNull);
        final complete = completeRequests[1];
        final completionDevice = complete['device'] as Map<String, dynamic>;
        expect(completionDevice.keys.toSet(), <String>{
          'device_id',
          'name',
          'signing_public_key',
          'encryption_public_key',
          'signature',
        });
        final deviceSignature = decodeBase64Url(
          completionDevice['signature'] as String,
        );
        final deviceSigningPublicKey = decodeBase64Url(
          completionDevice['signing_public_key'] as String,
        );
        try {
          expect(
            recoveryCrypto.verifyDetached(
              signature: deviceSignature,
              publicKey: deviceSigningPublicKey,
              payload: {
                'account_id': _accountId,
                'device_id': completionDevice['device_id'],
                'encryption_public_key':
                    completionDevice['encryption_public_key'],
                'signing_public_key': completionDevice['signing_public_key'],
              },
            ),
            isTrue,
          );
        } finally {
          deviceSignature.fillRange(0, deviceSignature.length, 0);
          deviceSigningPublicKey.fillRange(0, deviceSigningPublicKey.length, 0);
        }
        final completeSignature = decodeBase64Url(
          complete['recovery_signature'] as String,
        );
        final unsignedComplete = Map<String, dynamic>.from(complete)
          ..remove('recovery_signature');
        expect(
          recoveryCrypto.verifyDetached(
            signature: completeSignature,
            publicKey: oldIdentity.signing.publicKey,
            payload: {
              'protocol': 'atermius-account-recovery-complete-v1',
              'request': unsignedComplete,
            },
          ),
          isTrue,
        );
        completeSignature.fillRange(0, completeSignature.length, 0);
        expect(jsonEncode(complete).contains(prepared.recoveryCode), isFalse);
        expect(
          secureStore.savedDevice?['device_id'],
          (complete['device'] as Map<String, dynamic>)['device_id'],
        );
        expect(secureStore.events.sublist(secureStore.events.length - 2), [
          'save_device',
          'clear_pending',
        ]);

        final nextRecovery = complete['next_recovery'] as Map<String, dynamic>;
        final nextIdentity = await recoveryCrypto.openIdentityWithRecoveryCode(
          envelope: Map<String, dynamic>.from(
            nextRecovery['recovery_envelope'] as Map,
          ),
          recoveryCode: prepared.recoveryCode,
          accountId: _accountId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
          generation: 3,
        );
        try {
          expect(
            nextIdentity.signingPublicKey,
            nextRecovery['recovery_public_signing_key'],
          );
          final nextDescriptorHash = await recoveryCrypto
              .recoveryDescriptorHash(
                accountId: _accountId,
                instanceId: _instanceId,
                serverSpaceId: _serverSpaceId,
                generation: 3,
                signingPublicKey: nextIdentity.signingPublicKey,
                encryptionPublicKey: nextIdentity.encryptionPublicKey,
              );
          final codeEnvelopeHash = await recoveryCrypto.sha256Hex(
            Uint8List.fromList(
              utf8.encode(
                canonicalJson(nextRecovery['recovery_envelope'] as Map),
              ),
            ),
          );
          final accountKeyEnvelopeHash = await recoveryCrypto.sha256Hex(
            Uint8List.fromList(
              utf8.encode(
                canonicalJson(
                  nextRecovery['recovery_identity_envelope'] as Map,
                ),
              ),
            ),
          );
          final identityProof = decodeBase64Url(
            nextRecovery['recovery_identity_proof_signature'] as String,
          );
          expect(
            recoveryCrypto.verifyDetached(
              signature: identityProof,
              publicKey: nextIdentity.signing.publicKey,
              payload: {
                'protocol': 'atermius-account-recovery-identity-v1',
                'account_id': _accountId,
                'instance_id': _instanceId,
                'server_space_id': _serverSpaceId,
                'recovery_generation': 3,
                'recovery_descriptor_hash': nextDescriptorHash,
                'recovery_envelope_sha256': codeEnvelopeHash,
                'recovery_identity_envelope_sha256': accountKeyEnvelopeHash,
              },
            ),
            isTrue,
          );
          identityProof.fillRange(0, identityProof.length, 0);
        } finally {
          nextIdentity.dispose();
        }
      } finally {
        if (!controllerDisposed) controller.dispose();
        api.close();
        oldIdentity.dispose();
        vaultKey.fillRange(0, vaultKey.length, 0);
        await database.close();
      }
    },
  );
}

http.Response _jsonResponse(
  Map<String, Object?> value, {
  int statusCode = 200,
}) => http.Response(
  jsonEncode(value),
  statusCode,
  headers: {'content-type': 'application/json'},
);

class _RecoverySecureStore extends ClientSecureStore {
  Map<String, dynamic>? savedDevice;
  PendingAccountRecoveryStorageData? pendingRecovery;
  final List<String> events = [];

  @override
  Future<void> saveDevice(String baseUrl, DeviceIdentity identity) async {
    savedDevice = Map<String, dynamic>.from(identity.toStorageJson());
    events.add('save_device');
  }

  @override
  Future<void> savePendingFullAccountRecovery({
    required String baseUrl,
    required Map<String, Object?> request,
    required DeviceIdentity device,
    required DateTime challengeExpiresAt,
    required bool completionAttempted,
  }) async {
    pendingRecovery = PendingAccountRecoveryStorageData(
      request: Map<String, dynamic>.from(
        jsonDecode(jsonEncode(request)) as Map,
      ),
      device: Map<String, dynamic>.from(
        jsonDecode(jsonEncode(device.toStorageJson())) as Map,
      ),
      challengeExpiresAt: challengeExpiresAt,
      completionAttempted: completionAttempted,
    );
  }

  @override
  Future<PendingAccountRecoveryStorageData?> loadPendingFullAccountRecovery(
    String baseUrl,
  ) async => pendingRecovery;

  @override
  Future<void> clearPendingFullAccountRecovery(String baseUrl) async {
    pendingRecovery = null;
    events.add('clear_pending');
  }
}
