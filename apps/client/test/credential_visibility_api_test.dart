import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/credential_visibility/credential_visibility_api.dart';
import 'package:aterm_client/credential_visibility/credential_visibility_models.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/credential_visibility_fixtures.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _accountWrap() => {
  'version': 1,
  'nonce': encodeBase64Url(List.filled(24, 1)),
  'ciphertext': encodeBase64Url(List.filled(48, 2)),
};

Map<String, dynamic> _recoveryWrap() => {
  'version': 1,
  'kdf': {
    'id': 'argon2id13',
    'salt': encodeBase64Url(List.filled(16, 3)),
    'mem_kib': 65536,
    'iterations': 3,
    'parallelism': 1,
  },
  'nonce': encodeBase64Url(List.filled(24, 4)),
  'ciphertext': encodeBase64Url(List.filled(48, 5)),
};

void main() {
  late SodiumSumo sodium;
  late EscrowTestInstance instance;
  late Map<String, dynamic> descriptor;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    instance = EscrowTestInstance(sodium);
    final escrow = sodium.crypto.box.keyPair();
    descriptor = instance.descriptor(
      keyId: escrowKeyId,
      publicKey: escrow.publicKey,
    );
    escrow.dispose();
  });

  Map<String, dynamic> status({
    String mode = 'admin_visible',
    String escrowStatus = 'pending',
    Object? key = const _UseDescriptor(),
    List<Object?> missing = const [],
    List<Object?> views = const [],
  }) => {
    'mode': mode,
    'changed_at': '2026-11-13T09:00:00Z',
    'escrow_status': escrowStatus,
    'escrow_key': key is _UseDescriptor ? descriptor : key,
    'missing': missing,
    'admin_views': views,
  };

  group('user status model', () {
    test('parses mode, escrow, missing items and admin views', () {
      final parsed = CredentialVisibilityStatus.fromJson(
        status(
          missing: [
            {'vault_id': escrowVaultId, 'key_epoch': 2},
          ],
          views: [
            {
              'viewed_at': '2026-11-13T11:00:00Z',
              'admin_username': 'root@example.test',
              'vault_id': escrowVaultId,
            },
            {
              'viewed_at': '2026-11-12T11:00:00Z',
              'admin_username': null,
              'vault_id': null,
            },
          ],
        ),
      );
      expect(parsed.mode, CredentialVisibilityMode.adminVisible);
      expect(parsed.escrowStatus, CredentialEscrowStatus.pending);
      expect(parsed.changedAt, '2026-11-13T09:00:00Z');
      expect(parsed.escrowKey!.keyId, escrowKeyId);
      expect(parsed.missing.single.keyEpoch, 2);
      expect(parsed.adminViews.first.adminUsername, 'root@example.test');
      expect(parsed.adminViews.last.adminUsername, isNull);
      expect(parsed.adminViews.last.vaultId, isNull);
    });

    test('rejects unknown fields, bad values and inconsistent states', () {
      for (final bad in <Map<String, dynamic>>[
        {...status(), 'extra': true},
        status(mode: 'admins'),
        status(escrowStatus: 'done'),
        // private must be not_required and vice versa
        status(mode: 'private', escrowStatus: 'pending'),
        status(mode: 'admin_visible', escrowStatus: 'not_required'),
        status(escrowStatus: 'no_key'),
        status(
          missing: [
            {'vault_id': escrowVaultId, 'key_epoch': 0},
          ],
        ),
        status(
          missing: [
            {'vault_id': 'not-a-uuid', 'key_epoch': 1},
          ],
        ),
        status(
          missing: [
            {'vault_id': escrowVaultId, 'key_epoch': 1},
            {'vault_id': escrowVaultId, 'key_epoch': 1},
          ],
        ),
        status(
          views: [
            {'viewed_at': 'yesterday', 'admin_username': 'a', 'vault_id': null},
          ],
        ),
        status(key: {...descriptor, 'extra': 1}),
        {...status(), 'changed_at': 'now'},
      ]) {
        expect(
          () => CredentialVisibilityStatus.fromJson(bad),
          throwsFormatException,
          reason: jsonEncode(bad),
        );
      }
      // no_key without a key is fine; private with a key is fine.
      expect(
        CredentialVisibilityStatus.fromJson(
          status(escrowStatus: 'no_key', key: null),
        ).escrowStatus,
        CredentialEscrowStatus.noKey,
      );
      expect(
        CredentialVisibilityStatus.fromJson(
          status(mode: 'private', escrowStatus: 'not_required'),
        ).mode,
        CredentialVisibilityMode.private,
      );
    });

    test('/me policy summary parses or reports unsupported', () {
      expect(CredentialVisibilityPolicy.fromAccountPolicy(const {}), isNull);
      expect(
        CredentialVisibilityPolicy.fromAccountPolicy(const {
          'credential_visibility': null,
        }),
        isNull,
      );
      final policy = CredentialVisibilityPolicy.fromAccountPolicy(const {
        'credential_visibility': {'mode': 'admin_visible', 'changed_at': null},
      })!;
      expect(policy.mode, CredentialVisibilityMode.adminVisible);
      expect(policy.changedAt, isNull);
      expect(
        () => CredentialVisibilityPolicy.fromAccountPolicy(const {
          'credential_visibility': {'mode': 'x', 'changed_at': null},
        }),
        throwsFormatException,
      );
    });
  });

  test('user routes use the exact paths, bodies and results', () async {
    final requests = <http.Request>[];
    final api = ApiClient(
      baseUrl: 'https://cv.example.test/root',
      client: MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return _json(status(mode: 'private', escrowStatus: 'not_required'));
        }
        return request.url.path.endsWith('/2')
            ? _json({'status': 'stored'}, 201)
            : _json({'status': 'already_present'});
      }),
    )..accessToken = 'token';
    final cv = CredentialVisibilityApi(api);
    expect((await cv.status()).mode, CredentialVisibilityMode.private);
    expect(requests.last.url.path, '/root/api/v1/credential-visibility');
    expect(requests.last.headers['authorization'], 'Bearer token');
    final body = {'key_id': escrowKeyId, 'sealed': 'AA', 'signature': 'BB'};
    expect(
      await cv.deposit(vaultId: escrowVaultId, keyEpoch: 2, body: body),
      CredentialEscrowDepositResult.stored,
    );
    expect(requests.last.method, 'PUT');
    expect(
      requests.last.url.path,
      '/root/api/v1/credential-visibility/escrow/$escrowVaultId/2',
    );
    expect(jsonDecode(requests.last.body), body);
    expect(
      await cv.deposit(vaultId: escrowVaultId, keyEpoch: 3, body: body),
      CredentialEscrowDepositResult.alreadyPresent,
    );
    expect(
      () => cv.deposit(vaultId: 'x', keyEpoch: 1, body: body),
      throwsArgumentError,
    );
    api.close();
  });

  test('status carries the admin-visible Vault count when reported', () {
    expect(
      CredentialVisibilityStatus.fromJson(status()).adminVisibleVaults,
      isNull,
    );
    expect(
      CredentialVisibilityStatus.fromJson({
        ...status(mode: 'private', escrowStatus: 'not_required', key: null),
        'admin_visible_vaults': 2,
      }).adminVisibleVaults,
      2,
    );
    for (final value in [-1, '1', 1.5, true]) {
      expect(
        () => CredentialVisibilityStatus.fromJson({
          ...status(),
          'admin_visible_vaults': value,
        }),
        throwsFormatException,
        reason: '$value',
      );
    }
    // Still strict about every other key.
    expect(
      () => CredentialVisibilityStatus.fromJson({
        ...status(),
        'admin_visible_vaults': 0,
        'unexpected': 1,
      }),
      throwsFormatException,
    );
  });

  test(
    'share recipient check uses the owner route and parses strictly',
    () async {
      final requests = <http.Request>[];
      Object answer = {
        'recipient_admin_visible': true,
        'vault_admin_visible': false,
      };
      final api = ApiClient(
        baseUrl: 'https://cv.example.test/root',
        client: MockClient((request) async {
          requests.add(request);
          return _json(answer);
        }),
      )..accessToken = 'token';
      final cv = CredentialVisibilityApi(api);
      final parsed = await cv.shareRecipient(
        vaultId: escrowVaultId,
        deviceId: escrowDeviceId,
      );
      expect(parsed.recipientAdminVisible, isTrue);
      expect(parsed.vaultAdminVisible, isFalse);
      expect(requests.single.method, 'GET');
      expect(
        requests.single.url.path,
        '/root/api/v1/credential-visibility/vaults/$escrowVaultId/recipients/'
        '$escrowDeviceId',
      );
      for (final bad in [
        {'recipient_admin_visible': true},
        {'recipient_admin_visible': 'yes', 'vault_admin_visible': false},
        {
          'recipient_admin_visible': false,
          'vault_admin_visible': false,
          'mode': 'private',
        },
      ]) {
        answer = bad;
        await expectLater(
          cv.shareRecipient(vaultId: escrowVaultId, deviceId: escrowDeviceId),
          throwsFormatException,
        );
      }
      expect(
        () => cv.shareRecipient(vaultId: 'x', deviceId: escrowDeviceId),
        throwsArgumentError,
      );
      expect(
        () => cv.shareRecipient(vaultId: escrowVaultId, deviceId: 'DEVICE'),
        throwsArgumentError,
      );
      api.close();
    },
  );

  test('error envelope surfaces stable codes', () async {
    final api = ApiClient(
      baseUrl: 'https://cv.example.test',
      client: MockClient(
        (_) async => _json({
          'error': {
            'code': 'CREDENTIAL_ESCROW_KEY_MISMATCH',
            'message': 'The escrow key changed.',
            'request_id': 'req',
          },
        }, 409),
      ),
    )..accessToken = 'token';
    await expectLater(
      CredentialVisibilityApi(api)
          .deposit(vaultId: escrowVaultId, keyEpoch: 1, body: const {}),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'status', 409)
            .having((e) => e.code, 'code', 'CREDENTIAL_ESCROW_KEY_MISMATCH'),
      ),
    );
    api.close();
  });

  group('admin routes', () {
    Map<String, dynamic> overview({
      Object? key = const _UseDescriptor(),
      Object? callerWrap = const _UseDescriptor(),
      Object? recoveryWrap = const _UseDescriptor(),
    }) => {
      'default_mode': 'private',
      'escrow_key': key is _UseDescriptor ? descriptor : key,
      'caller_wrap': callerWrap is _UseDescriptor ? _accountWrap() : callerWrap,
      'recovery_wrap': recoveryWrap is _UseDescriptor
          ? _recoveryWrap()
          : recoveryWrap,
      'counts': {'admin_visible': 2, 'private': 5, 'pending': 1},
    };

    test('overview parsing is strict', () {
      final parsed = AdminCredentialVisibilityOverview.fromJson(overview());
      expect(parsed.defaultMode, CredentialVisibilityMode.private);
      expect(parsed.counts.adminVisible, 2);
      expect(parsed.counts.private, 5);
      expect(parsed.counts.pending, 1);
      expect(parsed.callerWrap, isNotNull);
      final noKey = AdminCredentialVisibilityOverview.fromJson(
        overview(key: null, callerWrap: null, recoveryWrap: null),
      );
      expect(noKey.escrowKey, isNull);
      for (final bad in [
        {...overview(), 'extra': 1},
        overview(callerWrap: {..._accountWrap(), 'version': 2}),
        overview(
          recoveryWrap: {
            ..._recoveryWrap(),
            'kdf': {...(_recoveryWrap()['kdf'] as Map), 'mem_kib': 1024},
          },
        ),
        overview(key: null), // wraps without a key
        overview(recoveryWrap: null), // key without the recovery wrap
        {
          ...overview(),
          'counts': {'admin_visible': -1, 'private': 0, 'pending': 0},
        },
      ]) {
        expect(
          () => AdminCredentialVisibilityOverview.fromJson(bad),
          throwsFormatException,
        );
      }
    });

    test('every admin route has the documented path and body', () async {
      final requests = <http.Request>[];
      final api = ApiClient(
        baseUrl: 'https://cv.example.test',
        client: MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          if (path == '/api/v1/admin/credential-visibility') {
            return _json(overview());
          }
          if (path.endsWith('/credential-visibility') &&
              request.method == 'PUT') {
            return _json({
              'user_id': escrowUserId,
              'mode': 'admin_visible',
              'changed_at': '2026-11-13T12:00:00Z',
              'escrow_status': 'pending',
            });
          }
          if (path == '/api/v1/admin/account-invitations') {
            return _json({
              'invitation': {
                'invitation_id': '55555555-5555-4555-8555-555555555555',
                'username': 'alice@example.test',
                'created_at': '2026-11-13T12:00:00Z',
                'expires_at': '2026-11-20T12:00:00Z',
                'token': encodeBase64Url(List.filled(32, 9)),
                'credential_visibility': 'admin_visible',
              },
            }, 201);
          }
          if (path == '/api/v1/admin/credential-escrow/key') {
            return request.method == 'POST'
                ? _json({'escrow_key': descriptor}, 201)
                : _json({'status': 'reset'});
          }
          if (path == '/api/v1/admin/credential-escrow/key/wrap') {
            return _json({'status': 'stored'});
          }
          if (path.endsWith('/vaults') && path.contains('credential-escrow')) {
            return _json({
              'account': {
                'user_id': escrowUserId,
                'username': 'alice@example.test',
                'mode': 'admin_visible',
              },
              'vaults': [
                {
                  'vault_id': escrowVaultId,
                  'role': 'owner',
                  'owner_user_id': escrowUserId,
                  'name_envelope': null,
                  'active_epoch': 2,
                  'escrow': [
                    {
                      'key_epoch': 2,
                      'sealed': 'AAAA',
                      'signature': 'BBBB',
                      'depositor_device_id': escrowDeviceId,
                      'depositor_signing_public_key': 'CCCC',
                    },
                  ],
                },
              ],
            });
          }
          if (path.endsWith('/records')) {
            return _json({
              'records': [
                {
                  'record_id': 'a',
                  'revision_id': 'r1',
                  'envelope': {'header': {}},
                  'author_device_id': escrowDeviceId,
                  'author_signing_public_key': 'DDDD',
                },
                {
                  'record_id': 'b',
                  'revision_id': 'r2',
                  'envelope': {'header': {}},
                  'author_device_id': null,
                  'author_signing_public_key': 'EEEE',
                },
              ],
              'next_after': 'b',
            });
          }
          throw StateError('unexpected $path');
        }),
      )..accessToken = 'token';
      final cv = CredentialVisibilityApi(api);

      await cv.adminOverview();
      expect(requests.last.method, 'GET');
      await cv.setDefaultMode(CredentialVisibilityMode.adminVisible);
      expect(requests.last.method, 'PUT');
      expect(jsonDecode(requests.last.body), {'default_mode': 'admin_visible'});

      final receipt = await cv.setAccountMode(
        userId: escrowUserId,
        mode: CredentialVisibilityMode.adminVisible,
      );
      expect(receipt.escrowStatus, CredentialEscrowStatus.pending);
      expect(
        requests.last.url.path,
        '/api/v1/admin/accounts/$escrowUserId/credential-visibility',
      );
      expect(jsonDecode(requests.last.body), {'mode': 'admin_visible'});

      final invitation = await cv.createAccountInvitation(
        username: ' Alice@Example.test ',
        expiresInSeconds: 604800,
        mode: CredentialVisibilityMode.adminVisible,
      );
      expect(invitation.credentialVisibility, 'admin_visible');
      expect(jsonDecode(requests.last.body), {
        'username': 'alice@example.test',
        'expires_in_seconds': 604800,
        'credential_visibility': 'admin_visible',
      });

      final created = await cv.createEscrowKey(
        keyId: escrowKeyId,
        publicKey: descriptor['public_key'] as String,
        creatorSignature: 'sig',
        accountWrap: _accountWrap(),
        recoveryWrap: _recoveryWrap(),
      );
      expect(created.keyId, escrowKeyId);
      expect(requests.last.method, 'POST');
      expect((jsonDecode(requests.last.body) as Map).keys.toSet(), {
        'key_id',
        'public_key',
        'creator_signature',
        'account_wrap',
        'recovery_wrap',
      });

      await cv.storeOwnWrap(keyId: escrowKeyId, accountWrap: _accountWrap());
      expect(requests.last.method, 'PUT');
      expect(jsonDecode(requests.last.body)['key_id'], escrowKeyId);

      await cv.resetEscrowKey(keyId: escrowKeyId);
      expect(requests.last.method, 'DELETE');
      expect(jsonDecode(requests.last.body), {
        'key_id': escrowKeyId,
        'confirm': 'reset',
      });

      final vaults = await cv.escrowAccountVaults(escrowUserId);
      expect(vaults.username, 'alice@example.test');
      expect(vaults.vaults.single.escrow.single.keyEpoch, 2);
      expect(
        requests.last.url.path,
        '/api/v1/admin/credential-escrow/accounts/$escrowUserId/vaults',
      );

      final page = await cv.escrowRecords(
        vaultId: escrowVaultId,
        userId: escrowUserId,
        after: 'x',
        limit: 2,
      );
      expect(page.records.map((r) => r.recordId), ['a', 'b']);
      expect(page.nextAfter, 'b');
      expect(
        requests.last.url.path,
        '/api/v1/admin/credential-escrow/vaults/$escrowVaultId/records',
      );
      expect(requests.last.url.queryParameters, {
        'user_id': escrowUserId,
        'after': 'x',
        'limit': '2',
      });
      // A page larger than the requested limit fails closed.
      await expectLater(
        cv.escrowRecords(
          vaultId: escrowVaultId,
          userId: escrowUserId,
          limit: 1,
        ),
        throwsFormatException,
      );
      expect(
        () => cv.escrowRecords(
          vaultId: escrowVaultId,
          userId: escrowUserId,
          limit: 501,
        ),
        throwsArgumentError,
      );
      api.close();
    });

    test('account receipt must name the requested account', () {
      expect(
        () => AdminCredentialVisibilityAccountReceipt.fromJson({
          'user_id': escrowAdminId,
          'mode': 'private',
          'changed_at': null,
          'escrow_status': 'not_required',
        }, expectedUserId: escrowUserId),
        throwsFormatException,
      );
    });

    // The server returns null signing keys when neither the device row nor
    // the Vault device archive exists (openapi: `[string, 'null']`). One
    // such row must not fail the whole listing or records page.
    test('null depositor / author signing keys parse per item', () {
      Map<String, dynamic> envelope(int epoch, Object? key) => {
        'key_epoch': epoch,
        'sealed': 'c2VhbGVk',
        'signature': 'c2ln',
        'depositor_device_id': null,
        'depositor_signing_public_key': key,
      };
      final vaults = AdminEscrowAccountVaults.fromJson({
        'account': {
          'user_id': escrowUserId,
          'username': 'alice@example.test',
          'mode': 'admin_visible',
        },
        'vaults': [
          {
            'vault_id': escrowVaultId,
            'role': 'owner',
            'owner_user_id': escrowUserId,
            'name_envelope': null,
            'active_epoch': 2,
            'escrow': [envelope(1, null), envelope(2, 'a2V5')],
          },
        ],
      }, expectedUserId: escrowUserId);
      final escrow = vaults.vaults.single.escrow;
      expect(escrow.map((e) => e.depositorSigningPublicKey), [null, 'a2V5']);

      Map<String, dynamic> record(String id, Object? key) => {
        'record_id': id,
        'revision_id': 'r-$id',
        'envelope': const {'header': {}},
        'author_device_id': null,
        'author_signing_public_key': key,
      };
      final page = AdminEscrowRecordsPage.fromJson({
        'records': [record('a', null), record('b', 'a2V5')],
        'next_after': null,
      }, limit: 10);
      expect(page.records.map((r) => r.authorSigningPublicKey), [null, 'a2V5']);

      // Present-but-null is allowed; missing, empty or non-string is not.
      expect(
        () => AdminEscrowEnvelope.fromJson(
          envelope(1, null)..remove('depositor_signing_public_key'),
        ),
        throwsFormatException,
      );
      expect(
        () => AdminEscrowEnvelope.fromJson(envelope(1, '')),
        throwsFormatException,
      );
      expect(
        () => AdminEscrowRecord.fromJson(
          record('a', null)..remove('author_signing_public_key'),
        ),
        throwsFormatException,
      );
      expect(
        () => AdminEscrowRecord.fromJson(record('a', 7)),
        throwsFormatException,
      );
    });
  });

  group('extended existing models', () {
    test('instance info exposes the default mode and validates it', () {
      final base = {
        'instance_id': escrowInstanceId,
        'server_space_id': escrowServerSpaceId,
        'generation': '1',
        'protocol_version': 1,
        'capabilities': ['credential_visibility'],
      };
      expect(InstanceInfo.fromJson(base).credentialVisibilityDefault, isNull);
      expect(
        InstanceInfo.fromJson({
          ...base,
          'credential_visibility_default': 'admin_visible',
        }).credentialVisibilityDefault,
        'admin_visible',
      );
      expect(
        () => InstanceInfo.fromJson({
          ...base,
          'credential_visibility_default': 'everyone',
        }),
        throwsFormatException,
      );
    });

    test('vault descriptors carry admin_visible through lifecycle refresh', () {
      final local = VaultDescriptor.fromJson({
        'vault_id': escrowVaultId,
        'role': 'owner',
      });
      expect(local.adminVisible, isFalse);
      final remote = VaultDescriptor.fromJson({
        'vault_id': escrowVaultId,
        'role': 'owner',
        'admin_visible': true,
      });
      expect(remote.adminVisible, isTrue);
      expect(local.withLifecycleFrom(remote).adminVisible, isTrue);
      final refreshed = remote.withAdminVisible(false);
      expect(refreshed.adminVisible, isFalse);
      expect(refreshed.id, remote.id);
      expect(refreshed.role, remote.role);
      expect(
        remote.withLifecycleResponse({
          'vault_id': escrowVaultId,
          'status': 'active',
          'can_cancel': false,
          'can_write': true,
        }).adminVisible,
        isTrue,
      );
    });

    test('admin account rows accept credential visibility columns', () {
      final row = {
        'user_id': escrowUserId,
        'username': 'alice@example.test',
        'status': 'active',
        'created_at': '2026-11-01T00:00:00Z',
        'active_device_count': 1,
        'active_session_count': 1,
      };
      final legacy = AdminAccountMetadata.fromJson(row);
      expect(legacy.credentialVisibility, isNull);
      expect(legacy.escrowStatus, isNull);
      final current = AdminAccountMetadata.fromJson({
        ...row,
        'credential_visibility': 'admin_visible',
        'escrow_status': 'complete',
      });
      expect(current.credentialVisibility, 'admin_visible');
      expect(current.escrowStatus, 'complete');
      expect(
        () => AdminAccountMetadata.fromJson({
          ...row,
          'credential_visibility': 'public',
        }),
        throwsFormatException,
      );
      expect(
        () => AdminAccountMetadata.fromJson({...row, 'escrow_status': 'ok'}),
        throwsFormatException,
      );
    });

    test('invitation rows accept an optional credential_visibility', () {
      final row = {
        'invitation_id': '55555555-5555-4555-8555-555555555555',
        'username': 'alice@example.test',
        'created_at': '2026-11-13T12:00:00Z',
        'expires_at': '2026-11-20T12:00:00Z',
        'status': 'pending',
      };
      expect(
        AdminAccountInvitationMetadata.fromJson(row).credentialVisibility,
        isNull,
      );
      expect(
        AdminAccountInvitationMetadata.fromJson({
          ...row,
          'credential_visibility': null,
        }).credentialVisibility,
        isNull,
      );
      expect(
        AdminAccountInvitationMetadata.fromJson({
          ...row,
          'credential_visibility': 'private',
        }).credentialVisibility,
        'private',
      );
      expect(
        () => AdminAccountInvitationMetadata.fromJson({
          ...row,
          'credential_visibility': 'nobody',
        }),
        throwsFormatException,
      );
      // Other unknown keys still fail closed.
      expect(
        () => AdminAccountInvitationMetadata.fromJson({...row, 'extra': 1}),
        throwsFormatException,
      );
    });
  });
}

class _UseDescriptor {
  const _UseDescriptor();
}
