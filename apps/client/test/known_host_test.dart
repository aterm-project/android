import 'dart:convert';

import 'package:aterm_client/domain/known_host.dart';
import 'package:flutter_test/flutter_test.dart';

const _deviceId = '11111111-1111-4111-8111-111111111111';
const _revokerDeviceId = '22222222-2222-4222-8222-222222222222';
const _recordId = '33333333-3333-4333-8333-333333333333';
const _fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
final _approvedAt = DateTime.utc(2026, 9, 27, 12, 34, 56, 789);

Map<String, dynamic> _json({
  String host = 'ssh.example.test',
  int port = 22,
  String algorithm = 'ssh-ed25519',
  String fingerprint = _fingerprint,
  String state = 'trusted',
  String approvalSource = 'interactive_confirmation',
  String approvedByDeviceId = _deviceId,
  String approvedAt = '2026-09-27T12:34:56.789Z',
  String? revokedByDeviceId,
  String? revokedAt,
}) => {
  'id': _recordId,
  'type': 'knownHost',
  'host': host,
  'port': port,
  'algorithm': algorithm,
  'fingerprint': fingerprint,
  'state': state,
  'approval_source': approvalSource,
  'approved_by_device_id': approvedByDeviceId,
  'approved_at': approvedAt,
  'revoked_by_device_id': revokedByDeviceId,
  'revoked_at': revokedAt,
};

void main() {
  group('KnownHost endpoint canonicalization', () {
    test('lowercases DNS names and removes one trailing root dot', () {
      expect(canonicalizeKnownHost('SSH.Example.Test.'), 'ssh.example.test');
      expect(
        endpointKey(host: 'SSH.Example.Test.', port: 22),
        'ssh.example.test:22',
      );
    });

    test('accepts strict canonical IPv4 dotted decimal', () {
      expect(canonicalizeKnownHost('192.0.2.15'), '192.0.2.15');
      expect(endpointKey(host: '192.0.2.15', port: 2200), '192.0.2.15:2200');
    });

    test(
      'normalizes compressed and expanded IPv6, with URI-safe endpoint form',
      () {
        expect(canonicalizeKnownHost('[2001:0DB8:0:0:0:0:0:1]'), '2001:db8::1');
        expect(endpointKey(host: '2001:db8::1', port: 22), '[2001:db8::1]:22');
        expect(canonicalizeKnownHost('::ffff:192.0.2.1'), '::ffff:c000:201');
      },
    );

    test('compresses the longest zero run and breaks ties toward the left', () {
      expect(canonicalizeKnownHost('2001:0:0:1:0:0:0:1'), '2001:0:0:1::1');
      expect(canonicalizeKnownHost('0:0:0:0:0:0:0:0'), '::');
    });

    test(
      'rejects whitespace, URI syntax, ambiguous IPv4, and non-ASCII DNS',
      () {
        for (final input in [
          '',
          ' ssh.example.test',
          'ssh.example.test ',
          'ssh host.example.test',
          'ssh.example.test/path',
          'user@ssh.example.test',
          'ssh.example.test:22',
          'ssh.example.test..',
          'bad_label.example.test',
          'ümlaut.example.test',
          '192.000.2.1',
          '256.0.2.1',
          '192.0.2',
        ]) {
          expect(
            () => canonicalizeKnownHost(input),
            throwsA(isA<FormatException>()),
            reason: 'should reject $input',
          );
        }
      },
    );

    test('accepts bracketed IPv6 only as a complete IPv6 literal', () {
      for (final input in [
        '[ssh.example.test]',
        '[2001:db8::1',
        '2001:db8::1]',
        '2001:db8:::1',
        '2001::db8::1',
        '1:2:3',
        'fe80::1%en0',
      ]) {
        expect(
          () => canonicalizeKnownHost(input),
          throwsA(isA<FormatException>()),
          reason: 'should reject $input',
        );
      }
    });
  });

  group('KnownHost record validation', () {
    test('creates independent random UUIDv4 records without endpoint slots', () {
      final first = KnownHostRecord.approve(
        host: 'SSH.EXAMPLE.TEST.',
        port: 22,
        algorithm: 'ssh-ed25519',
        fingerprint: _fingerprint,
        approvalSource: KnownHostApprovalSource.interactiveConfirmation,
        approvedByDeviceId: _deviceId,
        approvedAt: _approvedAt,
      );
      final second = KnownHostRecord.approve(
        host: 'ssh.example.test',
        port: 22,
        algorithm: 'ssh-ed25519',
        fingerprint: _fingerprint,
        approvalSource: KnownHostApprovalSource.interactiveConfirmation,
        approvedByDeviceId: _deviceId,
        approvedAt: _approvedAt,
      );

      expect(
        first.id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(first.id, isNot(second.id));
      expect(first.endpoint, 'ssh.example.test:22');
      expect(first.state, KnownHostState.trusted);
    });

    test(
      'round-trips exact algorithm, OpenSSH SHA256 fingerprint and approval',
      () {
        final record = KnownHostRecord.fromJson(_json());
        final decoded = KnownHostRecord.fromJson(record.toJson());

        expect(decoded.id, _recordId);
        expect(decoded.host, 'ssh.example.test');
        expect(decoded.algorithm, 'ssh-ed25519');
        expect(decoded.fingerprint, _fingerprint);
        expect(
          decoded.approvalSource,
          KnownHostApprovalSource.interactiveConfirmation,
        );
        expect(decoded.approvedByDeviceId, _deviceId);
        expect(decoded.approvedAt, _approvedAt);
        expect(
          decoded.matchesKey(
            algorithm: 'ssh-ed25519',
            fingerprint: _fingerprint,
          ),
          isTrue,
        );
        expect(
          decoded.matchesKey(algorithm: 'ssh-rsa', fingerprint: _fingerprint),
          isFalse,
        );
        expect(
          decoded.matchesKey(
            algorithm: 'ssh-ed25519',
            fingerprint: 'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
          ),
          isFalse,
        );
      },
    );

    test('version 2 renewal pins sorted exact revocation heads', () {
      const first = KnownHostRevocationReference(
        recordId: '55555555-5555-4555-8555-555555555555',
        revisionId: '77777777-7777-4777-8777-777777777777',
      );
      const second = KnownHostRevocationReference(
        recordId: '66666666-6666-4666-8666-666666666666',
        revisionId: '88888888-8888-4888-8888-888888888888',
      );
      final renewed = KnownHostRecord.approve(
        host: 'ssh.example.test',
        port: 22,
        algorithm: 'ssh-ed25519',
        fingerprint: _fingerprint,
        approvalSource: KnownHostApprovalSource.interactiveConfirmation,
        approvedByDeviceId: _deviceId,
        approvedAt: _approvedAt,
        observedRevocations: const [second, first],
      );
      final decoded = KnownHostRecord.fromJson(renewed.toJson());

      expect(renewed.schemaVersion, 2);
      expect(
        renewed.observedRevocations.map((reference) => reference.recordId),
        [first.recordId, second.recordId],
      );
      expect(decoded.observedRevocations, renewed.observedRevocations);
      expect(
        (decoded.revoke(
          revokedByDeviceId: _revokerDeviceId,
          revokedAt: DateTime.utc(2026, 9, 27, 13),
        )).observedRevocations,
        renewed.observedRevocations,
      );
    });

    test(
      'rejects unsupported or noncanonical observed-revocation metadata',
      () {
        const first = {
          'record_id': '55555555-5555-4555-8555-555555555555',
          'revision_id': '77777777-7777-4777-8777-777777777777',
        };
        const second = {
          'record_id': '66666666-6666-4666-8666-666666666666',
          'revision_id': '88888888-8888-4888-8888-888888888888',
        };
        for (final value in [
          {..._json(), 'schema_version': 2},
          {..._json(), 'schema_version': 2, 'observed_revocations': []},
          {
            ..._json(),
            'schema_version': 2,
            'observed_revocations': [second, first],
          },
          {
            ..._json(),
            'schema_version': 2,
            'observed_revocations': [first, first],
          },
          {
            ..._json(),
            'schema_version': 2,
            'observed_revocations': [
              {...first, 'unknown': true},
            ],
          },
          {
            ..._json(),
            'schema_version': 2.0,
            'observed_revocations': [first],
          },
          {
            ..._json(),
            'schema_version': 1,
            'observed_revocations': [first],
          },
          {..._json(), 'schema_version': 3},
        ]) {
          expect(
            () => KnownHostRecord.fromJson(value),
            throwsA(isA<FormatException>()),
            reason: 'should reject $value',
          );
        }
      },
    );

    test('requires port to be an integer from 1 through 65535', () {
      expect(KnownHostRecord.fromJson(_json(port: 1)).port, 1);
      expect(KnownHostRecord.fromJson(_json(port: 65535)).port, 65535);
      for (final port in [0, 65536, -1]) {
        expect(
          () => KnownHostRecord.fromJson(_json(port: port)),
          throwsA(isA<FormatException>()),
        );
      }
      expect(
        () => KnownHostRecord.fromJson({..._json(), 'port': 22.0}),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'validates SSH algorithm token and canonical 32-byte SHA256 fingerprint',
      () {
        expect(
          KnownHostRecord.fromJson(
            _json(algorithm: 'ecdsa-sha2-nistp256'),
          ).algorithm,
          'ecdsa-sha2-nistp256',
        );
        for (final algorithm in [
          '',
          'ssh ed25519',
          'ssh/ed25519',
          'ssh-ed25519\n',
        ]) {
          expect(
            () => KnownHostRecord.fromJson(_json(algorithm: algorithm)),
            throwsA(isA<FormatException>()),
          );
        }
        for (final fingerprint in [
          'SHA1:AAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          'sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
          'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
          'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA-',
        ]) {
          expect(
            () => KnownHostRecord.fromJson(_json(fingerprint: fingerprint)),
            throwsA(isA<FormatException>()),
            reason: 'should reject $fingerprint',
          );
        }
        expect(base64Decode('${_fingerprint.substring(7)}='), hasLength(32));
      },
    );

    test('requires complete, valid approval metadata', () {
      for (final field in [
        'approval_source',
        'approved_by_device_id',
        'approved_at',
      ]) {
        final value = _json()..remove(field);
        expect(
          () => KnownHostRecord.fromJson(value),
          throwsA(isA<FormatException>()),
          reason: 'missing $field must be rejected',
        );
      }
      for (final value in [
        _json(approvalSource: 'sync'),
        _json(approvedByDeviceId: 'not-a-uuid'),
        _json(approvedAt: '2026-09-27T12:34:56.789+00:00'),
        _json(approvedAt: '2026-02-30T12:34:56.789Z'),
      ]) {
        expect(
          () => KnownHostRecord.fromJson(value),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('trusted and revoked states have distinct required metadata', () {
      final trusted = KnownHostRecord.fromJson(_json());
      final revoked = trusted.revoke(
        revokedByDeviceId: _revokerDeviceId,
        revokedAt: DateTime.utc(2026, 9, 27, 13),
      );
      final decoded = KnownHostRecord.fromJson(revoked.toJson());

      expect(decoded.state, KnownHostState.revoked);
      expect(decoded.revokedByDeviceId, _revokerDeviceId);
      expect(decoded.revokedAt, DateTime.utc(2026, 9, 27, 13));
      expect(decoded.approvedByDeviceId, _deviceId);
      expect(
        () => trusted.revoke(
          revokedByDeviceId: _revokerDeviceId,
          revokedAt: DateTime(2026, 9, 27),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => KnownHostRecord.fromJson(
          _json(state: 'revoked', revokedByDeviceId: _revokerDeviceId),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => KnownHostRecord.fromJson(
          _json(
            state: 'trusted',
            revokedByDeviceId: _revokerDeviceId,
            revokedAt: '2026-09-27T13:00:00.000Z',
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'rejects noncanonical payloads, mismatched repository IDs, and unknown fields',
      () {
        expect(
          () => KnownHostRecord.fromJson(_json(host: 'SSH.EXAMPLE.TEST.')),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => KnownHostRecord.fromJson({
            ..._json(),
            '_record_id': '44444444-4444-4444-8444-444444444444',
          }),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => KnownHostRecord.fromJson({..._json(), 'unexpected': true}),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => KnownHostRecord.fromJson({..._json(), 'id': 'host-1'}),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'preserves repository revision and manifest metadata without serializing revision ID',
      () {
        const revision = '44444444-4444-4444-8444-444444444444';
        const manifest = {'extension_version': 1};
        final record = KnownHostRecord.fromJson({
          ..._json(),
          '_record_id': _recordId,
          '_revision_id': revision,
          '_manifest': manifest,
        });

        expect(record.revisionId, revision);
        expect(record.manifest, manifest);
        expect(record.toJson()['_manifest'], manifest);
        expect(record.toJson().containsKey('_revision_id'), isFalse);
      },
    );
  });
}
