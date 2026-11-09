import 'dart:convert';

import 'package:aterm_client/cloud/cloud_access_api.dart';
import 'package:aterm_client/cloud/cloud_access_crypto.dart';
import 'package:aterm_client/cloud/host_share_plan.dart';
import 'package:aterm_client/domain/known_host.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/cloud_access/guest_app.dart';
import 'package:aterm_client/ui/cloud_access/organizations_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

const _u = [
  '10000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000002',
  '10000000-0000-4000-8000-000000000003',
  '10000000-0000-4000-8000-000000000004',
  '10000000-0000-4000-8000-000000000005',
];

HostRecord _host(String id, String name, {String? jump, String? credential, String? group, String? password}) => HostRecord(
  id: id,
  name: name,
  address: '$name.internal',
  username: 'u',
  jumpHostId: jump,
  credentialId: credential,
  groupId: group,
  login: password == null ? null : HostLogin(kind: AuthKind.password, password: password),
);

KnownHostRecord _known(String host) => KnownHostRecord.fromJson({
  'id': _u[4],
  'type': 'knownHost',
  'host': host,
  'port': 22,
  'algorithm': 'ssh-ed25519',
  'fingerprint': 'SHA256:${base64.encode(List.filled(32, 1)).replaceAll('=', '')}',
  'state': 'trusted',
  'approval_source': 'interactive_confirmation',
  'approved_by_device_id': _u[3],
  'approved_at': '2026-11-08T00:00:00.000Z',
  'revoked_by_device_id': null,
  'revoked_at': null,
});

void main() {
  group('selected-Host sharing plan (H1/H2 isolation)', () {
    final h1 = _host(_u[0], 'h1', password: 'SENTINEL-H1');
    final h2 = _host(_u[1], 'h2', password: 'SENTINEL-H2', credential: _u[2]);
    final credential = CredentialRecord(id: _u[2], name: 'ops-key', username: 'ops', secret: 'SENTINEL-CRED');

    test('sharing H1 copies only H1 — never H2 or unrelated credentials', () {
      final plan = planHostShare(
        selected: [h1],
        vaultHosts: [h1, h2],
        vaultCredentials: [credential],
        vaultKnownHosts: const [],
        vaultGroups: const [],
      );
      expect(plan.canProceed, isTrue);
      final copies = remapForSharingVault(plan, () => _u[3]);
      expect(copies.hosts.map((h) => h.name), ['h1']);
      expect(copies.credentials, isEmpty);
      final serialized = jsonEncode(copies.hosts.map((h) => h.toJson()).toList());
      expect(serialized, isNot(contains('SENTINEL-H2')));
      expect(serialized, isNot(contains('SENTINEL-CRED')));
      expect(serialized, contains('SENTINEL-H1'), reason: 'inline login stays with the Host');
      expect(copies.hosts.single.id, isNot(h1.id), reason: 'copies are re-identified');
    });

    test('dependencies are listed for consent and remapped; groups are dropped', () {
      final jump = _host(_u[3], 'bastion');
      final target = _host(_u[0], 'db', jump: _u[3], credential: _u[2], group: 'g1');
      final plan = planHostShare(
        selected: [target],
        vaultHosts: [target, jump, h2],
        vaultCredentials: [credential],
        vaultKnownHosts: [_known('db.internal'), _known('h2.internal')],
        vaultGroups: [const GroupRecord(id: 'g1', name: 'Production')],
      );
      expect(plan.canProceed, isTrue);
      final kinds = plan.dependencies.map((d) => d.kind).toList();
      expect(kinds, containsAll([HostShareDependencyKind.jumpHost, HostShareDependencyKind.credential, HostShareDependencyKind.knownHost, HostShareDependencyKind.group]));
      expect(plan.knownHosts.map((k) => k.host), ['db.internal'], reason: 'unrelated host keys stay');
      var n = 0;
      final copies = remapForSharingVault(plan, () => 'f0000000-0000-4000-8000-00000000000${n++}');
      final db = copies.hosts.firstWhere((h) => h.name == 'db');
      final bastion = copies.hosts.firstWhere((h) => h.name == 'bastion');
      expect(db.jumpHostId, bastion.id);
      expect(db.credentialId, copies.credentials.single.id);
      expect(db.groupId, isNull);
      expect(copies.hosts.map((h) => h.name), isNot(contains('h2')));
    });

    test('unresolvable references block instead of leaving dangling references', () {
      final orphan = _host(_u[0], 'orphan', jump: _u[4]);
      final plan = planHostShare(selected: [orphan], vaultHosts: [orphan], vaultCredentials: const [], vaultKnownHosts: const [], vaultGroups: const []);
      expect(plan.canProceed, isFalse);
      expect(plan.blockers.single.kind, HostShareBlockerKind.missingJumpHost);
      final missingCredential = _host(_u[0], 'm', credential: _u[2]);
      expect(
        planHostShare(selected: [missingCredential], vaultHosts: [missingCredential], vaultCredentials: const [], vaultKnownHosts: const [], vaultGroups: const []).blockers.single.kind,
        HostShareBlockerKind.missingCredential,
      );
    });
  });

  test('route and join helpers', () {
    expect(guestSlugFromPath('/s/demo-room'), 'demo-room');
    expect(guestSlugFromPath('/s/demo-room/'), 'demo-room');
    for (final bad in ['/s/', '/s/a', '/s/Demo', '/x/demo-room', '/s/demo/room', '/s/-ab']) {
      expect(guestSlugFromPath(bad), isNull, reason: bad);
    }
    final token = 'A' * 43;
    expect(parseOrgJoinToken('https://x.example/join#o1.$token'), token);
    expect(parseOrgJoinToken('o1.$token'), token);
    expect(parseOrgJoinToken(token), token);
    expect(parseOrgJoinToken('https://x.example/join#s1.$token'), isNull);
    expect(parseOrgJoinToken('short'), isNull);
  });

  group('guest page', () {
    late SodiumSumo sodium;
    setUpAll(() async => sodium = await SodiumSumoInit.init());

    Widget app(GuestApi api, ShareLinkSecret? secret) => MaterialApp(
      localizationsDelegates: AppLocalizationSetup.delegates,
      supportedLocales: AppLocalizationSetup.locales,
      theme: buildAppTheme(),
      home: GuestPage(slug: 'demo-room', secret: secret, api: api, sodium: () async => sodium),
    );

    testWidgets('shows nothing about the link and sends nothing until Continue', (tester) async {
      final secret = ShareLinkSecret.random(sodium);
      final redeemToken = await secret.redeemToken();
      final linkId = '20000000-0000-4000-8000-000000000001';
      final displayKey = await ShareLinkSecret.fromFragment(secret.fragment)!.displayKey(linkId, 1);
      final envelope = sealShareDisplay(sodium, displayKey, linkId, 1, const ShareDisplay(title: 'Rescue DB', targets: {'t1': 'Primary DB'}));
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/api/v1/guest/redeem') {
          return http.Response(
            jsonEncode({
              'slug': 'demo-room',
              'link_id': linkId,
              'secret_version': 1,
              'display_envelope': envelope,
              'valid_from': '2026-11-08T00:00:00Z',
              'expires_at': '2026-11-09T00:00:00Z',
              'session_expires_at': '2026-11-08T02:00:00Z',
              'idle_timeout_seconds': 900,
              'permissions': {'clipboard_to_remote': false, 'clipboard_from_remote': false, 'view_only': true},
              'max_concurrent': 1,
              'targets': [{'target_id': 't1', 'protocol': 'ssh', 'available': true}],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      });
      final api = GuestApi(origin: Uri.parse('https://share.example.test/s/demo-room'), client: client);
      await tester.pumpWidget(app(api, secret));
      await tester.pumpAndSettle();
      expect(requests, isEmpty, reason: 'no automatic redemption on page load');
      expect(find.text('Rescue DB'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('cloud-access-guest-continue')));
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
      final sent = requests.single;
      expect(sent.method, 'POST');
      expect(sent.headers['X-Atermius-Guest'], 'v1');
      expect(sent.headers.containsKey('Authorization'), isFalse);
      final body = jsonDecode(sent.body) as Map<String, dynamic>;
      expect(body, {'slug': 'demo-room', 'redeem_token': redeemToken});
      expect(sent.body, isNot(contains(secret.fragment.substring(3))), reason: 'the fragment secret never leaves the browser');
      expect(find.text('Rescue DB'), findsOneWidget);
      expect(find.text('Primary DB'), findsOneWidget);
      expect(requests.where((r) => r.url.path == '/api/v1/guest/connections'), isEmpty, reason: 'no automatic connection');
    });

    Map<String, Object?> guestView(String slug, String linkId, String envelope) => {
      'slug': slug,
      'link_id': linkId,
      'secret_version': 1,
      'display_envelope': envelope,
      'valid_from': '2026-11-08T00:00:00Z',
      'expires_at': '2026-11-09T00:00:00Z',
      'session_expires_at': '2026-11-08T02:00:00Z',
      'idle_timeout_seconds': 900,
      'permissions': {'clipboard_to_remote': false, 'clipboard_from_remote': false, 'view_only': true},
      'max_concurrent': 1,
      'targets': [{'target_id': 't1', 'protocol': 'ssh', 'available': true}],
    };

    testWidgets('resume asks only for this address and refuses a session of another link', (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      for (final (served, expectUnavailable) in [('other-room', true), ('demo-room', false)]) {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          return http.Response(jsonEncode(guestView(served, '20000000-0000-4000-8000-000000000002', 'x')), 200);
        });
        final api = GuestApi(origin: Uri.parse('https://share.example.test/s/demo-room'), client: client);
        await tester.pumpWidget(app(api, null));
        await tester.pumpAndSettle();
        expect(requests, hasLength(1));
        expect(requests.single.method, 'GET');
        expect(requests.single.url.path, '/api/v1/guest/session');
        expect(requests.single.url.queryParameters, {'slug': 'demo-room'});
        expect(find.text(l10n.cloudAccessGuestUnavailable), expectUnavailable ? findsOneWidget : findsNothing, reason: 'served $served');
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a redemption answered for another address is never shown', (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final secret = ShareLinkSecret.random(sodium);
      const linkId = '20000000-0000-4000-8000-000000000003';
      final displayKey = await ShareLinkSecret.fromFragment(secret.fragment)!.displayKey(linkId, 1);
      final envelope = sealShareDisplay(sodium, displayKey, linkId, 1, const ShareDisplay(title: 'Other link', targets: {'t1': 'Other DB'}));
      final client = MockClient((request) async => http.Response(jsonEncode(guestView('other-room', linkId, envelope)), 200));
      final api = GuestApi(origin: Uri.parse('https://share.example.test/s/demo-room'), client: client);
      await tester.pumpWidget(app(api, secret));
      await tester.tap(find.byKey(const ValueKey('cloud-access-guest-continue')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.cloudAccessGuestUnavailable), findsOneWidget);
      expect(find.text('Other link'), findsNothing);
      expect(find.text('Other DB'), findsNothing);
    });

    testWidgets('a used-up link shows the honest reason', (tester) async {
      final client = MockClient((request) async => http.Response(
        jsonEncode({'error': {'code': 'SHARE_LINK_EXHAUSTED', 'message': 'x'}}),
        410,
      ));
      final api = GuestApi(origin: Uri.parse('https://share.example.test'), client: client);
      await tester.pumpWidget(app(api, ShareLinkSecret.random(sodium)));
      await tester.tap(find.byKey(const ValueKey('cloud-access-guest-continue')));
      await tester.pumpAndSettle();
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l10n.cloudAccessGuestExhausted), findsOneWidget);
    });
  });
}
