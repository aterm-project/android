// User-side Credential visibility v1: status, automatic escrow deposits and
// the one-time mode acknowledgement.
//
// The service observes the AppController instead of being called from its
// internals: any change of the signed-in scope, of the Vault descriptor list
// (new Vault, accepted share, key rotation) or of the /me policy schedules a
// status refresh; a completed sync retries while escrow is pending or the
// last attempt failed. When the status reports a different number of
// administrator-visible Vaults than the cached descriptors show, the Vault
// flags are refreshed from `GET /vaults`, so badges follow mode and membership
// changes made elsewhere. Every network step is best effort and never blocks
// normal use. Nothing happens unless the server advertises the
// `credential_visibility` capability.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../app_controller.dart';
import 'credential_escrow_crypto.dart';
import 'credential_visibility_ack_store.dart';
import 'credential_visibility_api.dart';
import 'credential_visibility_models.dart';

final _services = Expando<CredentialVisibilityService>(
  'credentialVisibilityService',
);

/// The single service observing [app]. Created on first use.
CredentialVisibilityService credentialVisibilityFor(AppController app) =>
    _services[app] ??= CredentialVisibilityService(app);

/// Replaces the service bound to [app] (tests inject fakes and stores).
@visibleForTesting
void debugInstallCredentialVisibilityService(
  AppController app,
  CredentialVisibilityService service,
) => _services[app] = service;

/// True when the connected server supports credential visibility.
bool credentialVisibilitySupported(AppController app) =>
    app.instance?.capabilities.contains(credentialVisibilityCapability) ??
    false;

/// Which one-time notice the user has not acknowledged on this device yet.
enum CredentialVisibilityNotice {
  /// First sign-in on this device while the account is admin-visible.
  adminVisible,

  /// The mode changed to admin-visible since the last acknowledgement.
  switchedToAdminVisible,

  /// First sign-in on this device, account was always private.
  private,

  /// The account is private again after an admin-visible period.
  switchedToPrivate,
}

class CredentialVisibilityService extends ChangeNotifier {
  CredentialVisibilityService(
    this.app, {
    CredentialVisibilityAckStore? ackStore,
    this.statusMaxAge = const Duration(minutes: 5),
    @visibleForTesting DateTime Function()? clock,
    @visibleForTesting this.vaultKeyLookup,
  }) : ackStore = ackStore ?? CredentialVisibilityAckStore.device(),
       _clock = clock ?? DateTime.now {
    app.addListener(_onAppChanged);
    _onAppChanged();
  }

  final AppController app;
  final CredentialVisibilityAckStore ackStore;

  /// A completed sync refreshes an otherwise healthy status after this age.
  final Duration statusMaxAge;
  final DateTime Function() _clock;

  /// Test seam replacing [AppController.copyVaultKeyForCredentialEscrow].
  @visibleForTesting
  final Uint8List? Function(String vaultId, int keyEpoch)? vaultKeyLookup;

  String? _scope;
  CredentialVisibilityStatus? _status;
  Object? _lastError;
  DateTime? _lastRefreshAt;
  bool _escrowKeyRejected = false;
  int _depositedThisScope = 0;
  CredentialVisibilityAck? _ack;
  bool _ackLoaded = false;
  Object? _lastVaults;
  Object? _lastAccount;
  bool _lastLocked = false;
  String? _vaultSignature;
  String? _policySignature;
  DateTime? _lastSync;
  bool _refreshRequested = false;
  Future<void>? _refreshFuture;
  bool _disposed = false;

  bool get available => _scope != null;
  CredentialVisibilityStatus? get status => _status;
  Object? get lastError => _lastError;
  bool get refreshing => _refreshFuture != null;

  /// The server returned an escrow key whose instance signature or binding
  /// did not verify against the pinned instance key. Nothing is deposited.
  bool get escrowKeyRejected => _escrowKeyRejected;

  /// Deposits stored by this device since the current sign-in.
  int get depositedThisScope => _depositedThisScope;

  CredentialVisibilityPolicy? get _policy {
    final policy = app.account?.policy;
    if (policy == null) return null;
    try {
      return CredentialVisibilityPolicy.fromAccountPolicy(policy);
    } on FormatException {
      return null;
    }
  }

  /// Current mode, from the last status response or the /me policy.
  CredentialVisibilityMode? get mode {
    if (!available) return null;
    return _status?.mode ?? _policy?.mode;
  }

  String? get changedAt {
    if (!available) return null;
    final status = _status;
    return status != null ? status.changedAt : _policy?.changedAt;
  }

  bool get adminVisible => mode == CredentialVisibilityMode.adminVisible;

  /// The account is `private`, but administrators can read some of its
  /// shared Vaults through another member. Conservative: true when either
  /// the last status or the cached Vault flags say so.
  bool get privateWithAdminVisibleVaults {
    if (mode != CredentialVisibilityMode.private) return false;
    final count = _status?.adminVisibleVaults ?? 0;
    return count > 0 || app.vaults.any((vault) => vault.adminVisible);
  }

  CredentialVisibilityNotice? get pendingNotice {
    final mode = this.mode;
    if (mode == null || !_ackLoaded) return null;
    final changedAt = this.changedAt;
    final ack = _ack;
    if (ack != null && ack.mode == mode && ack.changedAt == changedAt) {
      return null;
    }
    return switch (mode) {
      CredentialVisibilityMode.adminVisible =>
        ack == null
            ? CredentialVisibilityNotice.adminVisible
            : CredentialVisibilityNotice.switchedToAdminVisible,
      CredentialVisibilityMode.private =>
        changedAt != null || ack?.mode == CredentialVisibilityMode.adminVisible
            ? CredentialVisibilityNotice.switchedToPrivate
            : CredentialVisibilityNotice.private,
    };
  }

  /// Records that the user saw the notice for the current mode/changed_at.
  Future<void> acknowledge() async {
    final mode = this.mode;
    final scope = _scope;
    final serverUrl = app.api?.baseUrl;
    final accountId = app.account?.accountId;
    if (mode == null ||
        scope == null ||
        serverUrl == null ||
        accountId == null) {
      return;
    }
    final ack = CredentialVisibilityAck(mode: mode, changedAt: changedAt);
    _ack = ack;
    _notify();
    await ackStore.write(serverUrl: serverUrl, accountId: accountId, ack: ack);
  }

  String? _currentScope() {
    final client = app.api;
    final instance = app.instance;
    final account = app.account;
    final session = app.session;
    if (client == null ||
        instance == null ||
        account == null ||
        session == null ||
        session.accountId != account.accountId ||
        !credentialVisibilitySupported(app)) {
      return null;
    }
    return jsonEncode([
      client.baseUrl,
      instance.instanceId,
      account.accountId,
      session.deviceId,
    ]);
  }

  static String _vaultSignatureOf(List<VaultDescriptor> vaults) => [
    for (final vault in vaults)
      '${vault.id}:${vault.activeKeyEpoch}:${vault.membershipVersion}:'
          '${vault.status}',
  ].join(',');

  void _onAppChanged() {
    if (_disposed) return;
    final scope = _currentScope();
    if (scope != _scope) {
      _scope = scope;
      _status = null;
      _lastError = null;
      _lastRefreshAt = null;
      _escrowKeyRejected = false;
      _depositedThisScope = 0;
      _ack = null;
      _ackLoaded = false;
      _lastVaults = app.vaults;
      _vaultSignature = _vaultSignatureOf(app.vaults);
      _lastAccount = app.account;
      _policySignature = jsonEncode(
        app.account?.policy['credential_visibility'],
      );
      _lastSync = app.lastSuccessfulSyncAt;
      _lastLocked = app.workspaceLocked;
      if (scope != null) {
        unawaited(_loadAck(scope));
        _schedule();
      }
      _notifyLater();
      return;
    }
    if (scope == null) return;
    var trigger = false;
    if (!identical(app.vaults, _lastVaults)) {
      _lastVaults = app.vaults;
      final signature = _vaultSignatureOf(app.vaults);
      if (signature != _vaultSignature) {
        _vaultSignature = signature;
        trigger = true;
      }
    }
    if (!identical(app.account, _lastAccount)) {
      _lastAccount = app.account;
      final signature = jsonEncode(
        app.account?.policy['credential_visibility'],
      );
      if (signature != _policySignature) {
        _policySignature = signature;
        trigger = true;
        _notifyLater();
      }
    }
    if (app.workspaceLocked != _lastLocked) {
      _lastLocked = app.workspaceLocked;
      // Unlocking makes this device's Vault keys available again.
      if (!_lastLocked) trigger = true;
    }
    final sync = app.lastSuccessfulSyncAt;
    if (sync != _lastSync) {
      _lastSync = sync;
      if (sync != null && _needsRetry) trigger = true;
    }
    if (trigger) _schedule();
  }

  bool get _needsRetry {
    final status = _status;
    if (status == null || _lastError != null) return true;
    if (status.escrowStatus == CredentialEscrowStatus.pending) return true;
    final last = _lastRefreshAt;
    return last == null || _clock().difference(last) >= statusMaxAge;
  }

  Future<void> _loadAck(String scope) async {
    final serverUrl = app.api?.baseUrl;
    final accountId = app.account?.accountId;
    if (serverUrl == null || accountId == null) return;
    final ack = await ackStore.read(serverUrl: serverUrl, accountId: accountId);
    if (_disposed || _scope != scope) return;
    _ack = ack;
    _ackLoaded = true;
    _notify();
  }

  void _schedule() {
    scheduleMicrotask(() {
      if (!_disposed && _scope != null) unawaited(refresh());
    });
  }

  /// Fetches the status and deposits every missing item this device holds a
  /// Vault key for. Coalesces concurrent calls; never throws.
  Future<void> refresh() {
    if (_disposed || _currentScope() == null) return Future<void>.value();
    _refreshRequested = true;
    final running = _refreshFuture;
    if (running != null) return running;
    late final Future<void> future;
    future = _drain().whenComplete(() {
      if (identical(_refreshFuture, future)) _refreshFuture = null;
      _notify();
    });
    _refreshFuture = future;
    _notifyLater();
    return future;
  }

  Future<void> _drain() async {
    while (_refreshRequested && !_disposed) {
      _refreshRequested = false;
      await _refreshOnce();
    }
  }

  Future<void> _refreshOnce() async {
    final scope = _currentScope();
    final client = app.api;
    final instance = app.instance;
    final identity = app.identity;
    if (scope == null || client == null || instance == null) return;
    bool current() =>
        !_disposed &&
        _currentScope() == scope &&
        identical(app.api, client) &&
        identical(app.identity, identity);
    final api = CredentialVisibilityApi(client);
    try {
      final status = await api.status();
      if (!current()) return;
      _status = status;
      _lastError = null;
      _lastRefreshAt = _clock();
      _notify();
      await _refreshVaultFlags(status, client, current);
      if (!current()) return;
      if (status.mode != CredentialVisibilityMode.adminVisible ||
          status.escrowStatus != CredentialEscrowStatus.pending ||
          status.escrowKey == null ||
          status.missing.isEmpty ||
          identity == null ||
          identity.deviceId != app.session?.deviceId) {
        return;
      }
      final VerifiedEscrowKey key;
      try {
        // Never deposit to a key the pinned instance key did not sign.
        key = verifyEscrowKeyDescriptor(
          app.sodium,
          descriptor: status.escrowKey!.toJson(),
          instanceId: instance.instanceId,
          pinnedInstanceSigningKey: instance.signingPublicKey,
        );
      } on FormatException {
        _escrowKeyRejected = true;
        _notify();
        return;
      }
      _escrowKeyRejected = false;
      var stored = 0;
      Object? depositError;
      for (final item in status.missing) {
        if (!current()) return;
        final vaultKey =
            (vaultKeyLookup ?? app.copyVaultKeyForCredentialEscrow)(
              item.vaultId,
              item.keyEpoch,
            );
        if (vaultKey == null) continue;
        final Map<String, Object?> body;
        try {
          body = buildEscrowDeposit(
            app.sodium,
            key: key,
            identity: identity,
            instanceId: instance.instanceId,
            vaultId: item.vaultId,
            keyEpoch: item.keyEpoch,
            vaultKey: vaultKey,
          );
        } finally {
          vaultKey.fillRange(0, vaultKey.length, 0);
        }
        try {
          final result = await api.deposit(
            vaultId: item.vaultId,
            keyEpoch: item.keyEpoch,
            body: body,
          );
          if (result == CredentialEscrowDepositResult.stored) stored++;
        } on ApiException catch (error) {
          depositError = error;
          // The key or mode changed under us: stop and let the next trigger
          // start again from a fresh status.
          if (error.code == 'CREDENTIAL_ESCROW_KEY_MISMATCH' ||
              error.code == 'CREDENTIAL_ESCROW_NOT_REQUIRED') {
            break;
          }
        } on Object catch (error) {
          depositError = error;
        }
      }
      if (!current()) return;
      _depositedThisScope += stored;
      if (stored > 0 || depositError != null) {
        final refreshed = await api.status();
        if (!current()) return;
        _status = refreshed;
        _lastRefreshAt = _clock();
      }
      _lastError = depositError;
      _notify();
    } on Object catch (error) {
      if (!current()) return;
      // Background work: record for the settings section, retry later.
      _lastError = error;
      _notify();
    }
  }

  /// Refreshes the cached Vault `adminVisible` flags when [status] counts a
  /// different number of administrator-visible Vaults than they show. Never
  /// throws; a failure is retried by the next status refresh.
  Future<void> _refreshVaultFlags(
    CredentialVisibilityStatus status,
    ApiClient client,
    bool Function() current,
  ) async {
    final expected = status.adminVisibleVaults;
    if (expected == null) return;
    if (app.vaults.where((vault) => vault.adminVisible).length == expected) {
      return;
    }
    try {
      final vaults = await client.vaults();
      if (!current()) return;
      app.applyCredentialVisibilityVaultFlags({
        for (final vault in vaults) vault.id: vault.adminVisible,
      });
    } on Object {
      // Best effort: badges keep their cached value until the next refresh.
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Defers notifications triggered from inside the controller's own
  /// notification so listeners never rebuild during that dispatch.
  void _notifyLater() {
    scheduleMicrotask(_notify);
  }

  @override
  void dispose() {
    _disposed = true;
    try {
      app.removeListener(_onAppChanged);
    } on Object {
      // The controller may already be disposed.
    }
    super.dispose();
  }
}
