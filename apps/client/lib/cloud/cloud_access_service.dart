// Owner/member workflows for cloud access, composed from the existing
// AppController (Vault keys, signed membership invitations, KnownHosts) and
// the cloud access HTTP API.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:uuid/uuid.dart';

import '../api/api_client.dart';

import '../app_controller.dart';
import '../crypto/vault_crypto.dart';
import '../desktop/rdp_settings.dart';
import '../domain/known_host.dart';
import '../domain/models.dart';
import 'cloud_access_api.dart';
import 'cloud_access_crypto.dart';
import 'host_share_plan.dart';

/// Thrown for owner-actionable preconditions; [code] is stable for l10n.
class CloudAccessException implements Exception {
  const CloudAccessException(this.code);
  final String code;
  @override
  String toString() => 'CloudAccessException($code)';
}

/// Link options chosen in the owner UI. Defaults match the server defaults
/// (24 h, one redemption, one concurrent connection, clipboard and
/// view-only off).
class ShareLinkOptions {
  const ShareLinkOptions({
    this.validFrom,
    this.expiresAt,
    this.maxRedemptions = 1,
    this.maxConnections,
    this.maxConcurrent = 1,
    this.clipboardToRemote = false,
    this.clipboardFromRemote = false,
    this.viewOnly = false,
    this.slug,
    this.title = '',
  });
  final DateTime? validFrom;
  final DateTime? expiresAt;

  /// null = unlimited (chosen explicitly in the UI).
  final int? maxRedemptions;
  final int? maxConnections;
  final int maxConcurrent;
  final bool clipboardToRemote;
  final bool clipboardFromRemote;
  final bool viewOnly;
  final String? slug;
  final String title;
}

/// A freshly created or rotated link; [url] contains the fragment secret and
/// exists only in memory (it cannot be shown again later).
class CreatedShareLink {
  const CreatedShareLink({required this.link, required this.url});
  final Map<String, dynamic> link;
  final String url;
}

String _rfc3339(DateTime value) =>
    '${value.toUtc().toIso8601String().split('.').first}Z';

/// The account, device, server and Vault an owner operation was started for.
/// Every write and network dispatch re-validates it; a sign-out, account or
/// server switch, device change or a newer Vault selection aborts the
/// operation with `scope_changed` / `selection_superseded` instead of
/// writing into, or requesting for, a different scope.
///
/// Identity is tracked with the controller's generation tokens, not only
/// IDs: [authToken] changes on any sign-in/sign-out/server activation, and
/// [selection] is the selection token of the operation's own selection of
/// [vaultId], so a user who selects away and back (A→B→A) supersedes it.
class OwnerScope {
  OwnerScope._({
    required this.accountId,
    required this.deviceId,
    required this.instanceId,
    required this.client,
    required this.vaultId,
    required this.authToken,
    this.selection,
  });
  final String accountId;
  final String deviceId;
  final String instanceId;
  final ApiClient client;
  final String vaultId;
  final Object authToken;
  Object? selection;
}

class CloudAccessService {
  CloudAccessService(this.app);
  final AppController app;
  static const _uuid = Uuid();

  /// Test hook invoked at named points between awaits so tests can change
  /// selection or sign out at the worst moment.
  @visibleForTesting
  Future<void> Function(String stage)? checkpointForTesting;

  Future<void> _checkpoint(String stage) async {
    final hook = checkpointForTesting;
    if (hook != null) await hook(stage);
  }

  CloudAccessApi get api {
    final client = app.api;
    if (client == null) throw const CloudAccessException('signed_out');
    return CloudAccessApi(client);
  }

  List<String> get _capabilities => app.instance?.capabilities ?? const [];
  bool get linksAvailable => _capabilities.contains('share_links');
  bool get organizationsAvailable => _capabilities.contains('organizations');
  bool protocolAvailable(HostProtocol protocol) => switch (protocol) {
    HostProtocol.ssh => _capabilities.contains('share_gateway_ssh'),
    HostProtocol.rdp => _capabilities.contains('share_gateway_rdp'),
    HostProtocol.vnc => _capabilities.contains('share_gateway_vnc'),
    _ => false,
  };

  /// Captures the current scope for [vaultId] (default: the active Vault).
  OwnerScope captureScope({String? vaultId}) {
    final account = app.account;
    final identity = app.identity;
    final instance = app.instance;
    final client = app.api;
    if (account == null ||
        identity == null ||
        instance == null ||
        client == null ||
        client.accessToken == null) {
      throw const CloudAccessException('signed_out');
    }
    final target = vaultId ?? app.activeVault?.id;
    if (target == null) throw const CloudAccessException('no_vault');
    return OwnerScope._(
      accountId: account.accountId,
      deviceId: identity.deviceId,
      instanceId: instance.instanceId,
      client: client,
      vaultId: target,
      authToken: app.authScopeToken,
      // Bound to the current selection only when scoped to the active Vault;
      // an explicit Vault is bound once this operation selects it.
      selection: vaultId == null ? app.vaultSelectionToken : null,
    );
  }

  /// Throws unless the session is still exactly [scope]'s account, device,
  /// server and client; with [active], [scope]'s Vault must also be the
  /// selected, writable, owner Vault.
  void verifyScope(OwnerScope scope, {bool active = false}) {
    if (app.authScopeToken != scope.authToken ||
        app.account?.accountId != scope.accountId ||
        app.identity?.deviceId != scope.deviceId ||
        app.instance?.instanceId != scope.instanceId ||
        !identical(app.api, scope.client) ||
        scope.client.accessToken == null) {
      throw const CloudAccessException('scope_changed');
    }
    if (active) {
      final vault = app.activeVault;
      if (scope.selection == null ||
          app.vaultSelectionToken != scope.selection ||
          vault?.id != scope.vaultId)
        throw const CloudAccessException('selection_superseded');
      if (vault?.role != 'owner')
        throw const CloudAccessException('owner_required');
    }
  }

  CloudAccessApi _api(OwnerScope scope) => CloudAccessApi(scope.client);

  /// Selects [vaultId] for a Vault-bound controller operation and binds the
  /// scope to that selection (a no-op or superseded selection fails).
  Future<String?> _enterVault(OwnerScope scope) async {
    verifyScope(scope);
    final previous = app.activeVault?.id;
    final selection = await app.selectVaultForOperation(scope.vaultId);
    if (selection == null)
      throw const CloudAccessException('selection_superseded');
    scope.selection = selection;
    verifyScope(scope, active: true);
    return previous;
  }

  /// Returns to [previous] only if no selection was requested since this
  /// operation's own selection (select-away-and-back included) in the same
  /// session; never overrides a newer user choice.
  Future<void> _leaveVault(OwnerScope scope, String? previous) async {
    if (previous == null || previous == scope.vaultId) return;
    try {
      verifyScope(scope, active: true);
    } on CloudAccessException {
      return;
    }
    await app.selectVault(previous);
  }

  /// Runs a controller step whose server effect may already be committed when
  /// the scope ends; reports that honestly instead of implying nothing was sent.
  Future<T> _controllerStep<T>(Future<T> Function() step) async {
    try {
      return await step();
    } on OperationScopeEndedException catch (e) {
      throw CloudAccessException(
        e.serverCommitted ? 'scope_ended_committed' : 'scope_changed',
      );
    }
  }

  /// After a server-committed step, a lost scope must not read as "nothing
  /// was sent": scope errors, and any failure raised once [inScope] no longer
  /// holds (e.g. the controller refusing a replaced repository), are reported
  /// as `scope_ended_committed`.
  Future<T> _afterCommit<T>(
    Future<T> Function() rest, {
    required void Function() inScope,
  }) async {
    try {
      return await rest();
    } on CloudAccessException catch (e) {
      if (e.code == 'scope_changed' || e.code == 'selection_superseded') {
        throw const CloudAccessException('scope_ended_committed');
      }
      rethrow;
    } catch (_) {
      try {
        inScope();
      } on CloudAccessException {
        throw const CloudAccessException('scope_ended_committed');
      }
      rethrow;
    }
  }

  Future<VerifiedGatewayKey> _verifiedGatewayKey(OwnerScope scope) async {
    final response = await _api(scope).gatewayKeys();
    verifyScope(scope);
    final keys = response['keys'];
    if (keys is! List || keys.isEmpty || keys.first is! Map) {
      throw const CloudAccessException('gateway_unavailable');
    }
    return verifyGatewayKey(
      app.sodium,
      key: Map<String, dynamic>.from(keys.first as Map),
      instanceId: scope.instanceId,
      pinnedInstanceSigningKey: app.instance!.signingPublicKey,
    );
  }

  /// Why a Host cannot be shared through the gateway, or null.
  String? shareBlocker(HostRecord host) {
    if (!linksAvailable) return 'links_unavailable';
    if (!protocolAvailable(host.protocol)) return 'protocol_unavailable';
    if (app.activeVault?.role != 'owner') return 'owner_required';
    if (host.jumpHostId != null) return 'jump_host';
    if (host.portForwardProfiles.isNotEmpty) return 'port_forward';
    if (host.protocol == HostProtocol.ssh && _trustedKnownHost(host) == null) {
      return 'host_key_required';
    }
    if (host.protocol == HostProtocol.rdp &&
        host.rdpCertificateSha256 == null) {
      return 'certificate_required';
    }
    if (_login(host) == null) return 'login_required';
    return null;
  }

  KnownHostRecord? _trustedKnownHost(HostRecord host) {
    final matches =
        app.knownHosts
            .where(
              (k) =>
                  k.state == KnownHostState.trusted &&
                  k.host == host.address &&
                  k.port == host.port,
            )
            .toList()
          ..sort((a, b) => b.approvedAt.compareTo(a.approvedAt));
    return matches.firstOrNull;
  }

  CapsuleLogin? _login(HostRecord host) {
    final inline = host.login;
    if (inline != null) {
      return CapsuleLogin(
        username: host.username,
        password: inline.kind == AuthKind.password ? inline.password : null,
        privateKey: inline.kind == AuthKind.privateKey
            ? inline.privateKey
            : null,
        passphrase: inline.kind == AuthKind.privateKey
            ? inline.passphrase
            : null,
      );
    }
    final credentialId = host.credentialId;
    if (credentialId == null) {
      return host.protocol == HostProtocol.vnc
          ? CapsuleLogin(username: host.username)
          : null;
    }
    final credential = app.credentials
        .where((c) => c.id == credentialId)
        .firstOrNull;
    if (credential == null) return null;
    return CapsuleLogin(
      username: credential.username.isEmpty
          ? host.username
          : credential.username,
      password: credential.kind == AuthKind.password ? credential.secret : null,
      privateKey: credential.kind == AuthKind.privateKey
          ? credential.privateKey
          : null,
      passphrase: credential.kind == AuthKind.privateKey
          ? credential.passphrase
          : null,
    );
  }

  /// Seals the current Host revision to the verified gateway key and stores
  /// the capsule. The Host, its revision and login are read from the scoped
  /// Vault after synchronizing, and the scope is re-validated before the
  /// capsule is built and again before it is sent.
  Future<void> sealHost(HostRecord host, {OwnerScope? scope}) async {
    final s = scope ?? captureScope();
    verifyScope(s, active: true);
    final blocker = shareBlocker(host);
    if (blocker != null) throw CloudAccessException(blocker);
    await app.synchronize();
    await _checkpoint('host_synced');
    verifyScope(s, active: true);
    final current = app.hosts.where((h) => h.id == host.id).firstOrNull;
    final revision = current?.revisionId;
    if (current == null || revision == null)
      throw const CloudAccessException('host_not_synced');
    final gateway = await _verifiedGatewayKey(s);
    await _checkpoint('gateway_key_verified');
    verifyScope(s, active: true);
    // Re-read after the network await: the Host must still be this revision.
    final latest = app.hosts.where((h) => h.id == host.id).firstOrNull;
    if (latest == null || latest.revisionId != revision)
      throw const CloudAccessException('host_not_synced');
    final blockerNow = shareBlocker(latest);
    if (blockerNow != null) throw CloudAccessException(blockerNow);
    final known = _trustedKnownHost(latest);
    final rdp = latest.protocol == HostProtocol.rdp
        ? RdpSettings.of(latest)
        : null;
    final body = buildSealedCapsule(
      app.sodium,
      gateway: gateway,
      identity: app.identity!,
      accountId: s.accountId,
      vaultId: s.vaultId,
      hostRecordId: latest.id,
      hostRevisionId: revision,
      protocol: latest.protocol.name,
      targetHost: latest.address,
      targetPort: latest.port,
      hostIdentity: switch (latest.protocol) {
        HostProtocol.ssh => known?.fingerprint,
        HostProtocol.rdp => latest.rdpCertificateSha256,
        _ => null,
      },
      sshHostKeyAlgorithm: latest.protocol == HostProtocol.ssh
          ? known?.algorithm
          : null,
      rdpSecurity: latest.protocol == HostProtocol.rdp ? 'nla' : null,
      displayMode: rdp == null
          ? null
          : (rdp.resolution == RdpResolutionMode.fixed
                ? 'fixed'
                : 'fit_window'),
      displayWidth: rdp?.resolution == RdpResolutionMode.fixed
          ? rdp!.width
          : null,
      displayHeight: rdp?.resolution == RdpResolutionMode.fixed
          ? rdp!.height
          : null,
      login: _login(latest)!,
    );
    verifyScope(s, active: true);
    await _api(s).putCapsule(s.vaultId, latest.id, body);
  }

  String linkUrl(OwnerScope scope, String path, ShareLinkSecret secret) {
    final base = Uri.parse(scope.client.baseUrl);
    final origin = Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
    );
    return '${origin.toString().replaceAll(RegExp(r'/$'), '')}$path#${secret.fragment}';
  }

  Future<CreatedShareLink> createLink(
    List<HostRecord> hosts,
    ShareLinkOptions options,
  ) async {
    if (hosts.isEmpty || hosts.length > 8)
      throw const CloudAccessException('targets');
    final s = captureScope();
    for (final host in hosts) {
      await sealHost(host, scope: s);
    }
    final linkId = _uuid.v4();
    final secret = ShareLinkSecret.random(app.sodium);
    try {
      final targets = {for (final host in hosts) _uuid.v4(): host};
      final displayKey = await secret.displayKey(linkId, 1);
      final envelope = sealShareDisplay(
        app.sodium,
        displayKey,
        linkId,
        1,
        ShareDisplay(
          title: options.title.isEmpty ? hosts.first.name : options.title,
          targets: {for (final e in targets.entries) e.key: e.value.name},
        ),
      );
      displayKey.fillRange(0, displayKey.length, 0);
      final body = <String, Object?>{
        'link_id': linkId,
        'redeem_token': await secret.redeemToken(),
        'display_envelope': envelope,
        if (options.slug != null && options.slug!.trim().isNotEmpty)
          'slug': options.slug!.trim(),
        if (options.validFrom != null)
          'valid_from': _rfc3339(options.validFrom!),
        if (options.expiresAt != null)
          'expires_at': _rfc3339(options.expiresAt!),
        'max_redemptions': options.maxRedemptions,
        'max_connections': options.maxConnections,
        'max_concurrent': options.maxConcurrent,
        'clipboard_to_remote': options.clipboardToRemote,
        'clipboard_from_remote': options.clipboardFromRemote,
        'view_only': options.viewOnly,
        'targets': [
          for (final e in targets.entries)
            {'target_id': e.key, 'host_record_id': e.value.id},
        ],
      };
      verifyScope(s, active: true);
      final link = await _api(s).createLink(s.vaultId, body);
      return CreatedShareLink(
        link: link,
        url: linkUrl(s, link['path'] as String, secret),
      );
    } finally {
      secret.wipe();
    }
  }

  /// Issues a new secret; the old URL stops working and its guests end.
  Future<CreatedShareLink> rotateLink(
    Map<String, dynamic> link,
    Map<String, String> labels,
  ) async {
    final s = captureScope(vaultId: link['vault_id'] as String);
    final secret = ShareLinkSecret.random(app.sodium);
    try {
      final linkId = link['link_id'] as String;
      final version = (link['secret_version'] as int) + 1;
      final key = await secret.displayKey(linkId, version);
      final envelope = sealShareDisplay(
        app.sodium,
        key,
        linkId,
        version,
        ShareDisplay(
          title: labels['title'] ?? '',
          targets: Map.of(labels)..remove('title'),
        ),
      );
      key.fillRange(0, key.length, 0);
      final token = await secret.redeemToken();
      verifyScope(s);
      final rotated = await _api(s).rotateLink(s.vaultId, linkId, {
        'expected_revision': link['revision'],
        'redeem_token': token,
        'display_envelope': envelope,
      });
      return CreatedShareLink(
        link: rotated,
        url: linkUrl(s, rotated['path'] as String, secret),
      );
    } finally {
      secret.wipe();
    }
  }

  // Selected-Host sharing through a dedicated Vault ---------------------------

  HostSharePlan planShare(List<HostRecord> hosts) => planHostShare(
    selected: hosts,
    vaultHosts: app.hosts,
    vaultCredentials: app.credentials,
    vaultKnownHosts: app.knownHosts,
    vaultGroups: app.groups,
    sourceVaultId: app.activeVault?.id,
  );

  /// Creates a new Vault that contains only the planned records.
  ///
  /// Copies are written only through scoped controller operations bound to
  /// the verified *new* Vault; a failed, no-op or superseded selection aborts
  /// before any copy (never into the source or a foreign Vault). The result
  /// is returned only after the copies are confirmed synchronized. The
  /// source Vault is re-selected only if the user did not choose another.
  Future<String> createSharingVault(HostSharePlan plan, String name) async {
    if (!plan.canProceed)
      throw const CloudAccessException('share_plan_blocked');
    final source = captureScope();
    if (plan.sourceVaultId != null && plan.sourceVaultId != source.vaultId) {
      throw const CloudAccessException('selection_superseded');
    }
    verifyScope(source, active: true);
    final copies = remapForSharingVault(plan, _uuid.v4);
    final known = List.of(plan.knownHosts);
    // The controller guards its own dispatch and state commit against the
    // session ending; it selects the new Vault only if the user did not
    // request another selection meanwhile.
    final created = await _controllerStep(() => app.createVaultInScope(name));
    final targetId = created.vaultId;
    // From here on the Vault exists on the server; losing the scope is
    // reported as such (it is not deleted behind the user's back).
    final target = await _afterCommit(() async {
      final target = captureScope(vaultId: targetId);
      target.selection = created.selection;
      verifyScope(source);
      verifyScope(target, active: true);
      return target;
    }, inScope: () => verifyScope(source));
    try {
      return await _afterCommit(() async {
        await _checkpoint('sharing_vault_created');
        if (targetId == source.vaultId)
          throw const CloudAccessException('selection_superseded');
        verifyScope(source);
        verifyScope(target, active: true);
        // A membership refresh (e.g. the realtime hint about the new Vault)
        // may be running; edits are refused meanwhile and it rebuilds the
        // repository of the same Vault without a new selection request. Wait
        // it out, then re-verify the same session and this operation's own
        // selection of the new Vault before binding the next write to the
        // repository that is open now. Any other change aborts.
        Future<Object> settled() async {
          await app.waitForMembershipRefresh();
          verifyScope(source);
          verifyScope(target, active: true);
          final current = app.recordWriteScope;
          if (current == null)
            throw const CloudAccessException('selection_superseded');
          return current;
        }

        for (final credential in copies.credentials) {
          await app.createCredentialInScope(
            credential,
            scope: await settled(),
          );
        }
        for (final host in copies.hosts) {
          await app.createHostInScope(host, scope: await settled());
        }
        for (final key in known) {
          await settled();
          await app.approveKnownHost(
            host: key.host,
            port: key.port,
            algorithm: key.algorithm,
            fingerprint: key.fingerprint,
            approvalSource: KnownHostApprovalSource.outOfBandFingerprint,
          );
        }
        await _checkpoint('sharing_copies_written');
        verifyScope(target, active: true);
        await app.synchronize();
        await app.refreshSyncStatus();
        await settled();
        if (app.pendingCount != 0)
          throw const CloudAccessException('sharing_vault_not_synced');
        return targetId;
      }, inScope: () => verifyScope(target, active: true));
    } finally {
      await _leaveVault(target, source.vaultId);
    }
  }

  // Key distribution and member changes (owner consent) -----------------------

  /// Publishes this device's signed share card so Vault owners can deliver
  /// keys after an organization grant.
  Future<void> publishDeviceCard() async {
    final s = captureScope(vaultId: '');
    final card =
        jsonDecode(app.exportVaultShareRequest()) as Map<String, dynamic>;
    verifyScope(s);
    await _api(s).publishDeviceCard(card);
  }

  /// The owner confirmed [card] (fingerprint shown in the UI): create the
  /// regular signed Vault invitation in [vaultId] and seal its token to that
  /// device. Fails safely if the Vault cannot be (or stops being) selected.
  Future<void> deliverKey({
    required String vaultId,
    required Map<String, dynamic> card,
    required String role,
  }) async {
    final s = captureScope(vaultId: vaultId);
    final previous = await _enterVault(s);
    try {
      final verified = app.verifyVaultShareRequest(jsonEncode(card));
      verifyScope(s, active: true);
      final invitation = await _controllerStep(
        () => app.createVaultInvitation(recipient: verified, role: role),
      );
      // The signed invitation exists on the server now. If the session or
      // this operation's selection ends before delivery, say so honestly; the
      // undelivered invitation stays pending until it expires or is revoked.
      await _afterCommit(() async {
        await _checkpoint('delivery_invited');
        verifyScope(s, active: true);
        final sealed = sealTokenForDevice(
          app.sodium,
          invitation['token'] as String,
          Uint8List.fromList(verified.encryptionPublicKey),
        );
        verifyScope(s, active: true);
        await _api(s).createDelivery(
          s.vaultId,
          invitationId: invitation['invitation_id'] as String,
          recipientDeviceId: verified.deviceId,
          sealedToken: sealed,
        );
      }, inScope: () => verifyScope(s, active: true));
    } finally {
      await _leaveVault(s, previous);
    }
  }

  /// Owner-confirmed role change of an accepted member through the existing
  /// signed membership rotation in [vaultId].
  Future<void> changeMemberRole({
    required String vaultId,
    required String userId,
    required String role,
  }) async {
    final s = captureScope(vaultId: vaultId);
    final previous = await _enterVault(s);
    try {
      verifyScope(s, active: true);
      await app.changeVaultMemberRole(userId: userId, role: role);
    } finally {
      await _leaveVault(s, previous);
    }
  }

  /// Owner-confirmed cryptographic removal (signed rotation) in [vaultId].
  Future<void> removeMember({
    required String vaultId,
    required String userId,
  }) async {
    final s = captureScope(vaultId: vaultId);
    final previous = await _enterVault(s);
    try {
      verifyScope(s, active: true);
      await app.revokeVaultMember(userId);
    } finally {
      await _leaveVault(s, previous);
    }
  }

  String cardFingerprint(Map<String, dynamic> card) {
    final device = card['device'];
    if (device is! Map || device['encryption_public_key'] is! String)
      return '—';
    return deviceKeyFingerprint(
      decodeBase64Url(device['encryption_public_key'] as String),
    );
  }

  /// Opens deliveries addressed to this device and accepts them through the
  /// existing Vault invitation endpoint, for the account that asked.
  Future<int> acceptDeliveries() async {
    final s = captureScope(vaultId: '');
    final deliveries =
        (await _api(s).myDeliveries())['deliveries'] as List? ?? const [];
    var accepted = 0;
    for (final raw in deliveries) {
      final delivery = Map<String, dynamic>.from(raw as Map);
      verifyScope(s);
      final token = openSealedToken(
        app.sodium,
        delivery['sealed_token'] as String,
        app.identity!,
      );
      await app.acceptVaultInvitation(token);
      verifyScope(s);
      await _api(s).markDeliveryOpened(delivery['delivery_id'] as String);
      accepted++;
    }
    return accepted;
  }
}
