import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _secret = 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP';
const _recoveryCodes = <String>[
  'ABCD-EFGH-JKLM-NPQR',
  'BCDE-FGHJ-KLMN-PQRS',
  'CDEF-GHJK-LMNP-QRST',
  'DEFG-HJKM-NPQR-STUV',
  'EFGH-JKMN-PQRS-TUVW',
  'FGHJ-KMNP-QRST-UVWX',
  'GHJK-MNPQ-RSTU-VWXY',
  'HJKM-NPQR-STUV-WXYZ',
  'JKLM-PQRS-TUVW-XYZ2',
  'KLMN-QRST-UVWX-YZ23',
];

void main() {
  test('parses 202 challenge without installing session credentials', () async {
    final requests = <http.Request>[];
    final api = ApiClient(
      baseUrl: 'https://sync.example.test/tenant',
      client: MockClient((request) async {
        requests.add(request);
        expect(request.url.path, '/tenant/api/v1/auth/login');
        return http.Response(
          jsonEncode({
            'mfa_required': true,
            'challenge_id': '8c0f8e22-4b50-4a74-bce1-60431ef00711',
            'expires_at': '2026-10-02T14:10:00Z',
            'methods': ['totp', 'recovery_code'],
          }),
          202,
        );
      }),
    )..accessToken = 'stale-access-token';
    addTearDown(api.close);

    final result = await api.login(
      username: 'alice@example.test',
      loginVerifier: 'derived-login-verifier',
      deviceId: 'device-1',
    );

    expect(result, isA<MfaLoginChallenge>());
    final challenge = result as MfaLoginChallenge;
    expect(challenge.challengeId, '8c0f8e22-4b50-4a74-bce1-60431ef00711');
    expect(challenge.methods, {'totp', 'recovery_code'});
    expect(challenge.expiresAt, DateTime.utc(2026, 10, 2, 14, 10));
    expect(requests.single.headers['authorization'], isNull);
    expect(api.accessToken, isNull);
    expect(requests, hasLength(1));
  });

  test(
    'keeps password-only login response compatible and completes TOTP login',
    () async {
      final requests = <http.Request>[];
      final api = ApiClient(
        baseUrl: 'https://sync.example.test',
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/api/v1/auth/login') {
            return http.Response(
              jsonEncode(_sessionJson('access-password')),
              200,
            );
          }
          expect(request.url.path, '/api/v1/auth/login/mfa');
          expect(request.headers['authorization'], isNull);
          expect(jsonDecode(request.body), {
            'challenge_id': 'challenge-1',
            'totp_code': '123456',
          });
          return http.Response(jsonEncode(_sessionJson('access-mfa')), 200);
        }),
      );
      addTearDown(api.close);

      final first = await api.login(
        username: 'alice',
        loginVerifier: 'derived',
        deviceId: 'device-1',
      );
      expect(first, isA<AuthenticatedLogin>());
      expect(api.accessToken, 'access-password');

      final mfaSession = await api.completeMfaLogin(
        challengeId: 'challenge-1',
        totpCode: '123456',
      );
      expect(mfaSession.accessToken, 'access-mfa');
      expect(api.accessToken, 'access-mfa');
      expect(requests, hasLength(2));
    },
  );

  test(
    'MFA API uses fixed routes and returns one-time values only to caller',
    () async {
      final requests = <http.Request>[];
      final api = ApiClient(
        baseUrl: 'https://sync.example.test',
        client: MockClient((request) async {
          requests.add(request);
          switch (request.url.path) {
            case '/api/v1/auth/mfa':
              return http.Response(
                jsonEncode({'enabled': true, 'recovery_codes_remaining': 8}),
                200,
              );
            case '/api/v1/auth/mfa/totp/setup':
              expect(jsonDecode(request.body), {
                'current_login_verifier': 'verifier-1',
              });
              return http.Response(
                jsonEncode({
                  'secret': _secret,
                  'provisioning_uri':
                      'otpauth://totp/Atermius:alice?secret=$_secret&issuer=Atermius',
                  'expires_at': '2026-10-02T14:10:00Z',
                }),
                200,
              );
            case '/api/v1/auth/mfa/totp/confirm':
              expect(jsonDecode(request.body), {
                'current_login_verifier': 'verifier-2',
                'totp_code': '654321',
              });
              return http.Response(
                jsonEncode({'recovery_codes': _recoveryCodes}),
                200,
              );
            case '/api/v1/auth/mfa/recovery-codes':
              expect(jsonDecode(request.body), {
                'current_login_verifier': 'verifier-3',
                'totp_code': '111222',
              });
              return http.Response(
                jsonEncode({'recovery_codes': _recoveryCodes}),
                200,
              );
            case '/api/v1/auth/mfa/totp':
              expect(request.method, 'DELETE');
              expect(jsonDecode(request.body), {
                'current_login_verifier': 'verifier-4',
                'totp_code': '333444',
              });
              return http.Response(
                jsonEncode({'enabled': false, 'recovery_codes_remaining': 0}),
                200,
              );
            default:
              fail('Unexpected MFA API path ${request.url.path}');
          }
        }),
      )..accessToken = 'active-access-token';
      addTearDown(api.close);

      final status = await api.accountMfaStatus();
      expect(status.enabled, isTrue);
      expect(status.recoveryCodesRemaining, 8);

      final setup = await api.setupMfaTotp('verifier-1');
      expect(setup.secret, _secret);
      expect(setup.provisioningUri, contains(_secret));
      setup.clear();
      expect(setup.secret, isNull);
      expect(setup.provisioningUri, isNull);

      final codes = await api.confirmMfaTotp(
        currentLoginVerifier: 'verifier-2',
        totpCode: '654321',
      );
      expect(codes.codes, _recoveryCodes);
      codes.clear();
      expect(codes.codes, isEmpty);

      final rotated = await api.rotateMfaRecoveryCodes(
        currentLoginVerifier: 'verifier-3',
        totpCode: '111222',
      );
      expect(rotated.codes, _recoveryCodes);
      rotated.clear();

      final disabled = await api.disableMfaTotp(
        currentLoginVerifier: 'verifier-4',
        totpCode: '333444',
      );
      expect(disabled.enabled, isFalse);
      expect(disabled.recoveryCodesRemaining, 0);
      expect(requests.map((request) => request.url.path), [
        '/api/v1/auth/mfa',
        '/api/v1/auth/mfa/totp/setup',
        '/api/v1/auth/mfa/totp/confirm',
        '/api/v1/auth/mfa/recovery-codes',
        '/api/v1/auth/mfa/totp',
      ]);
      expect(
        requests.first.headers['authorization'],
        'Bearer active-access-token',
      );
    },
  );

  test('rejects malformed challenge and provisioning payloads', () {
    expect(
      () => AuthLoginResult.fromJson({
        'mfa_required': true,
        'challenge_id': 'challenge',
        'expires_at': 'not-a-date',
        'methods': ['totp'],
      }),
      throwsFormatException,
    );
    expect(
      () => MfaTotpSetup.fromJson({
        'secret': _secret,
        'provisioning_uri': 'https://example.test/?secret=$_secret',
        'expires_at': '2026-10-02T14:10:00Z',
      }),
      throwsFormatException,
    );
    expect(
      () => MfaRecoveryCodes.fromJson({
        'recovery_codes': ['not-a-code'],
      }),
      throwsFormatException,
    );
  });

  test('requires exactly the two MFA login methods in the contract', () {
    Map<String, Object?> challenge(List<String> methods) => {
      'mfa_required': true,
      'challenge_id': '8c0f8e22-4b50-4a74-bce1-60431ef00711',
      'expires_at': '2026-10-02T14:10:00Z',
      'methods': methods,
    };

    expect(
      AuthLoginResult.fromJson(challenge(['totp', 'recovery_code'])),
      isA<MfaLoginChallenge>(),
    );
    expect(
      AuthLoginResult.fromJson(challenge(['recovery_code', 'totp'])),
      isA<MfaLoginChallenge>(),
    );
    for (final methods in [
      ['totp'],
      ['recovery_code'],
      ['totp', 'totp'],
      ['totp', 'recovery_code', 'other'],
    ]) {
      expect(
        () => AuthLoginResult.fromJson(challenge(methods)),
        throwsFormatException,
        reason: 'methods=$methods',
      );
    }
  });
}

Map<String, Object?> _sessionJson(String accessToken) => {
  'account_id': 'account-1',
  'device_id': 'device-1',
  'access_token': accessToken,
  'expires_in': 900,
  'refresh_token': 'refresh-$accessToken',
};
