import 'package:flutter/foundation.dart' show kIsWeb;

import '../domain/models.dart';
import '../storage/local_host_repository.dart';
import 'ssh_service.dart';

typedef LocalKnownHostApprovalPrompt =
    Future<bool> Function(LocalKnownHostApprovalRequest request);

/// Tracks one LocalVault SSH handshake's deferred host-key decision.
///
/// Unknown keys are never accepted during key exchange. A caller must review
/// the request, persist an explicit approval, then start a fresh handshake.
final class LocalKnownHostTrustController {
  LocalKnownHostTrustController(
    this.repository, {
    this.decisionLockAlreadyHeld = false,
  });

  final LocalHostRepository repository;
  final bool decisionLockAlreadyHeld;
  LocalKnownHostApprovalRequest? pendingRequest;
  LocalKnownHostTrustStatus? pendingStatus;

  Future<bool> verifyHostKey({
    required String host,
    required int port,
    required String algorithm,
    required String fingerprint,
  }) async {
    pendingRequest = null;
    pendingStatus = null;
    final status = decisionLockAlreadyHeld
        ? await repository.knownHostTrustStatusWhileDecisionLockHeld(
            host: host,
            port: port,
            algorithm: algorithm,
            fingerprint: fingerprint,
          )
        : await repository.knownHostTrustStatus(
            host: host,
            port: port,
            algorithm: algorithm,
            fingerprint: fingerprint,
          );
    if (status == LocalKnownHostTrustStatus.trusted) return true;
    pendingStatus = status;
    pendingRequest = LocalKnownHostApprovalRequest(
      host: host,
      port: port,
      algorithm: algorithm,
      fingerprint: fingerprint,
      previouslyRevoked: status == LocalKnownHostTrustStatus.revoked,
    );
    return false;
  }

  Future<void> approvePending({required bool explicitlyConfirmed}) async {
    final request = pendingRequest;
    final status = pendingStatus;
    if (request == null ||
        (status != LocalKnownHostTrustStatus.unknown &&
            status != LocalKnownHostTrustStatus.revoked)) {
      throw StateError('No reviewable local SSH host-key approval is pending.');
    }
    if (!explicitlyConfirmed) {
      throw StateError('Local SSH host-key approval was not confirmed.');
    }
    await repository.approveKnownHost(
      host: request.host,
      port: request.port,
      algorithm: request.algorithm,
      fingerprint: request.fingerprint,
      explicitlyConfirmed: true,
    );
    final confirmedStatus = await repository.knownHostTrustStatus(
      host: request.host,
      port: request.port,
      algorithm: request.algorithm,
      fingerprint: request.fingerprint,
    );
    if (confirmedStatus != LocalKnownHostTrustStatus.trusted) {
      throw StateError(
        'Local SSH host-key approval did not verify as trusted.',
      );
    }
    pendingRequest = null;
    pendingStatus = null;
  }
}

/// SSH connect path for standalone LocalVault profiles.
///
/// It uses direct native SSH only. Web must use the server Relay and therefore
/// cannot use this API-free LocalVault path. The SSH verifier runs before user
/// authentication, and a newly reviewed key always starts a fresh handshake.
final class LocalProfileSshController {
  LocalProfileSshController({
    required this.repository,
    SshService? serviceForTesting,
  }) : _service =
           serviceForTesting ??
           SshService(
             api: null,
             deviceId: repository.localDeviceId,
             useRelay: false,
             knownHostDecisionLock: repository.knownHostDecisionLock,
           );

  final LocalHostRepository repository;
  final SshService _service;

  Future<SshConnection> connect({
    required HostRecord host,
    required CredentialRecord credential,
    required LocalKnownHostApprovalPrompt askApproval,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError(
        'Local profiles cannot open SSH in a browser without the server Relay.',
      );
    }
    final jumpRoute = await _resolveJumpHostRoute(host);
    final trustControllers = <String, LocalKnownHostTrustController>{};
    LocalKnownHostTrustController trustFor(HostRecord routeHost) =>
        trustControllers.putIfAbsent(
          routeHost.id,
          () => LocalKnownHostTrustController(
            repository,
            decisionLockAlreadyHeld: true,
          ),
        );
    LocalKnownHostTrustController? pendingTrust;

    Future<bool> verify(
      HostRecord routeHost,
      String algorithm,
      String fingerprint,
    ) async {
      final trust = trustFor(routeHost);
      final accepted = await trust.verifyHostKey(
        host: routeHost.address,
        port: routeHost.port,
        algorithm: algorithm,
        fingerprint: fingerprint,
      );
      if (!accepted) pendingTrust = trust;
      return accepted;
    }

    final sshJumpHops = jumpRoute
        .map(
          (hop) => SshJumpHop(
            host: hop.host,
            credential: hop.credential,
            verifyHostKey: (algorithm, fingerprint) =>
                verify(hop.host, algorithm, fingerprint),
          ),
        )
        .toList(growable: false);

    // SshService holds the same shared decision lock through each hop's user
    // authentication. Avoid recursively acquiring it in each host-key callback.
    final maxTrustRestarts = (jumpRoute.length + 1) * 2;
    for (var attempt = 0; attempt < maxTrustRestarts; attempt++) {
      pendingTrust = null;
      try {
        return await _service.connect(
          host: host,
          credential: credential,
          jumpHops: sshJumpHops,
          knownHostDecisionScope: repository.knownHostDecisionScope,
          verifyHostKey: (algorithm, fingerprint) =>
              verify(host, algorithm, fingerprint),
        );
      } on Object {
        final trust = pendingTrust;
        final request = trust?.pendingRequest;
        final status = trust?.pendingStatus;
        if (request == null || status == null) rethrow;
        if (status == LocalKnownHostTrustStatus.changed ||
            status == LocalKnownHostTrustStatus.conflict) {
          throw const SshHostKeyVerificationException(
            SshHostKeyFailure.changed,
          );
        }
        if (status != LocalKnownHostTrustStatus.unknown &&
            status != LocalKnownHostTrustStatus.revoked) {
          rethrow;
        }
        if (!await askApproval(request)) {
          throw const SshHostKeyVerificationException(
            SshHostKeyFailure.rejected,
          );
        }
        await trust!.approvePending(explicitlyConfirmed: true);
      }
    }
    throw StateError('Local SSH host-key review exceeded the retry limit.');
  }

  Future<List<_ResolvedLocalJumpHop>> _resolveJumpHostRoute(
    HostRecord target,
  ) async {
    final reverseRoute = <_ResolvedLocalJumpHop>[];
    final seenHostIds = <String>{target.id};
    var nextHostId = target.jumpHostId;
    while (nextHostId != null) {
      if (!seenHostIds.add(nextHostId)) {
        throw StateError('Local SSH Jump Host route contains a cycle.');
      }
      if (reverseRoute.length >= maxJumpHostHops) {
        throw StateError('Local SSH Jump Host route exceeds the hop limit.');
      }
      final jumpHost = await repository.getHost(nextHostId);
      if (jumpHost == null) {
        throw StateError('Local SSH Jump Host reference is unavailable.');
      }
      final credential = await repository.resolveCredentialForHost(jumpHost);
      if (credential == null) {
        throw StateError(
          'Local SSH Jump Host has no Credential or Group default.',
        );
      }
      reverseRoute.add(
        _ResolvedLocalJumpHop(host: jumpHost, credential: credential),
      );
      nextHostId = jumpHost.jumpHostId;
    }
    return reverseRoute.reversed.toList(growable: false);
  }
}

final class _ResolvedLocalJumpHop {
  const _ResolvedLocalJumpHop({required this.host, required this.credential});

  final HostRecord host;
  final CredentialRecord credential;
}
