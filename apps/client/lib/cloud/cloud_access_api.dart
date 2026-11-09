// HTTP bindings for cloud access. Owner/member calls reuse the existing
// Bearer ApiClient. Guest calls use a separate cookie-domain client and never
// send account credentials.
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api/api_client.dart';

class CloudAccessApi {
  CloudAccessApi(this._api);
  final ApiClient _api;

  // Gateway, capsules, links -------------------------------------------------
  Future<Map<String, dynamic>> gatewayKeys() =>
      _api.get('/api/v1/share-gateway/keys', authenticated: false);
  Future<Map<String, dynamic>> capsules(String vaultId) =>
      _api.get('/api/v1/vaults/$vaultId/share-capsules');
  Future<Map<String, dynamic>> putCapsule(
    String vaultId,
    String hostId,
    Map<String, Object?> body,
  ) => _api.put('/api/v1/vaults/$vaultId/hosts/$hostId/gateway-capsule', body);
  Future<Map<String, dynamic>> deleteCapsule(String vaultId, String hostId) =>
      _api.delete('/api/v1/vaults/$vaultId/hosts/$hostId/gateway-capsule');
  Future<Map<String, dynamic>> links(String vaultId) =>
      _api.get('/api/v1/vaults/$vaultId/share-links');
  Future<Map<String, dynamic>> createLink(
    String vaultId,
    Map<String, Object?> body,
  ) => _api.post('/api/v1/vaults/$vaultId/share-links', body);
  Future<Map<String, dynamic>> updateLink(
    String vaultId,
    String linkId,
    Map<String, Object?> body,
  ) => _api.put('/api/v1/vaults/$vaultId/share-links/$linkId', body);
  Future<Map<String, dynamic>> revokeLink(String vaultId, String linkId) =>
      _api.post('/api/v1/vaults/$vaultId/share-links/$linkId/revoke', const {});
  Future<Map<String, dynamic>> rotateLink(
    String vaultId,
    String linkId,
    Map<String, Object?> body,
  ) => _api.post(
    '/api/v1/vaults/$vaultId/share-links/$linkId/rotate-secret',
    body,
  );
  Future<Map<String, dynamic>> activity(String vaultId, String linkId) =>
      _api.get('/api/v1/vaults/$vaultId/share-links/$linkId/activity');
  Future<Map<String, dynamic>> terminate(
    String vaultId,
    String linkId,
    String guestSessionId,
  ) => _api.post(
    '/api/v1/vaults/$vaultId/share-links/$linkId/guest-sessions/$guestSessionId/terminate',
    const {},
  );
  Future<Map<String, dynamic>> slugAvailability(String slug) =>
      _api.get('/api/v1/share-slugs/${Uri.encodeComponent(slug)}/availability');
  Future<Map<String, dynamic>> vaultAudit(String vaultId) =>
      _api.get('/api/v1/vaults/$vaultId/cloud-audit');

  // Organizations -------------------------------------------------------------
  Future<Map<String, dynamic>> orgs() => _api.get('/api/v1/orgs');
  Future<Map<String, dynamic>> createOrg(String name) =>
      _api.post('/api/v1/orgs', {'name': name});
  Future<Map<String, dynamic>> org(String orgId) =>
      _api.get('/api/v1/orgs/$orgId');
  Future<Map<String, dynamic>> setMemberRole(
    String orgId,
    String userId,
    String role,
  ) => _api.put('/api/v1/orgs/$orgId/members/$userId', {'role': role});
  Future<Map<String, dynamic>> removeMember(String orgId, String userId) =>
      _api.delete('/api/v1/orgs/$orgId/members/$userId');
  Future<Map<String, dynamic>> invitations(String orgId) =>
      _api.get('/api/v1/orgs/$orgId/invitations');
  Future<Map<String, dynamic>> createInvitation(
    String orgId, {
    required String role,
    String? username,
    String? teamId,
    int? expiresInSeconds,
  }) => _api.post('/api/v1/orgs/$orgId/invitations', {
    'role': role,
    'intended_username': ?username,
    'team_id': ?teamId,
    'expires_in_seconds': ?expiresInSeconds,
  });
  Future<Map<String, dynamic>> revokeInvitation(String orgId, String id) =>
      _api.post('/api/v1/orgs/$orgId/invitations/$id/revoke', const {});
  Future<Map<String, dynamic>> inspectInvitation(String token) =>
      _api.post('/api/v1/org-invitations/inspect', {'token': token});
  Future<Map<String, dynamic>> acceptInvitation(String token) =>
      _api.post('/api/v1/org-invitations/accept', {'token': token});
  Future<Map<String, dynamic>> createTeam(String orgId, String name) =>
      _api.post('/api/v1/orgs/$orgId/teams', {'name': name});
  Future<Map<String, dynamic>> deleteTeam(String orgId, String teamId) =>
      _api.delete('/api/v1/orgs/$orgId/teams/$teamId');
  Future<Map<String, dynamic>> setTeamMembers(
    String orgId,
    String teamId,
    List<String> userIds,
    int expectedRevision,
  ) => _api.put('/api/v1/orgs/$orgId/teams/$teamId/members', {
    'user_ids': userIds,
    'expected_revision': expectedRevision,
  });

  // Vault grants & key distribution ------------------------------------------
  Future<Map<String, dynamic>> attachVault(String vaultId, String orgId) =>
      _api.put('/api/v1/vaults/$vaultId/organization', {'org_id': orgId});
  Future<Map<String, dynamic>> detachVault(String vaultId) =>
      _api.delete('/api/v1/vaults/$vaultId/organization');
  Future<Map<String, dynamic>> grants(String vaultId) =>
      _api.get('/api/v1/vaults/$vaultId/grants');
  Future<Map<String, dynamic>> setGrant(
    String vaultId,
    String principalType,
    String principalId,
    String role,
    int expectedRevision,
  ) => _api.put('/api/v1/vaults/$vaultId/grants/$principalType/$principalId', {
    'role': role,
    'expected_grants_revision': expectedRevision,
  });
  Future<Map<String, dynamic>> removeGrant(
    String vaultId,
    String principalType,
    String principalId,
    int expectedRevision,
  ) => _api.delete(
    '/api/v1/vaults/$vaultId/grants/$principalType/$principalId',
    body: {'expected_grants_revision': expectedRevision},
  );
  Future<Map<String, dynamic>> keyDistribution(String vaultId) =>
      _api.get('/api/v1/vaults/$vaultId/key-distribution');
  Future<Map<String, dynamic>> createDelivery(
    String vaultId, {
    required String invitationId,
    required String recipientDeviceId,
    required String sealedToken,
  }) => _api.post('/api/v1/vaults/$vaultId/key-deliveries', {
    'invitation_id': invitationId,
    'recipient_device_id': recipientDeviceId,
    'sealed_token': sealedToken,
  });
  Future<Map<String, dynamic>> makeDirect(String vaultId, String userId) =>
      _api.post(
        '/api/v1/vaults/$vaultId/member-sources/$userId/make-direct',
        const {},
      );
  Future<Map<String, dynamic>> publishDeviceCard(Map<String, Object?> card) =>
      _api.put('/api/v1/cloud/device-card', {'card': card});
  Future<Map<String, dynamic>> myDeliveries() =>
      _api.get('/api/v1/cloud/key-deliveries');
  Future<Map<String, dynamic>> markDeliveryOpened(String id) =>
      _api.post('/api/v1/cloud/key-deliveries/$id/opened', const {});
}

/// Guest-domain client: same-origin requests that rely on the HttpOnly guest
/// cookie set by redemption. Never sends an Authorization header.
class GuestApi {
  GuestApi({required Uri origin, http.Client? client})
    : _origin = origin,
      _client = client ?? http.Client();

  final Uri _origin;
  final http.Client _client;

  static const _headers = {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    'X-Atermius-Guest': 'v1',
  };

  Uri _uri(String path, [Map<String, String>? query]) =>
      _origin.replace(path: path, queryParameters: query, fragment: null);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, [
    Map<String, Object?>? body,
    Map<String, String>? query,
  ]) async {
    final request = http.Request(method, _uri(path, query))
      ..followRedirects = false
      ..headers.addAll(_headers);
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 30)),
    );
    final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = decoded is Map ? decoded['error'] : null;
      throw ApiException(
        statusCode: response.statusCode,
        code: error is Map && error['code'] is String
            ? error['code'] as String
            : 'HTTP_${response.statusCode}',
        message: error is Map && error['message'] is String
            ? error['message'] as String
            : 'request failed',
        details: error is Map && error['details'] is Map
            ? Map<String, dynamic>.from(error['details'] as Map)
            : const {},
      );
    }
    return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
  }

  Future<Map<String, dynamic>> redeem(String slug, String redeemToken) => _send(
    'POST',
    '/api/v1/guest/redeem',
    {'slug': slug, 'redeem_token': redeemToken},
  );

  /// Resumes the guest session only for the link address the page shows.
  Future<Map<String, dynamic>> session(String slug) =>
      _send('GET', '/api/v1/guest/session', null, {'slug': slug});
  Future<Map<String, dynamic>> logout() =>
      _send('POST', '/api/v1/guest/logout', const {});
  Future<Map<String, dynamic>> connection(String slug, String targetId) =>
      _send('POST', '/api/v1/guest/connections', {
        'slug': slug,
        'target_id': targetId,
      });

  Uri gatewaySocketUri(String connectPath) => _origin.replace(
    scheme: _origin.scheme == 'https' ? 'wss' : 'ws',
    path: connectPath,
    query: null,
    fragment: null,
  );
}
