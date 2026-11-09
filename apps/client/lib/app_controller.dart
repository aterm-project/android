import 'domain/window_combination.dart';
import 'console/local_console.dart';
import 'console/local_shell_l10n.dart';
import 'desktop/desktop_session.dart';
import 'desktop/rdp_certificate_persistence.dart';
import 'desktop/window/desktop_tab_windows.dart';
import 'auth/session_startup.dart';

import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:xterm/xterm.dart';

import 'auth/session_credentials.dart';
import 'auth/session_refresh_lock.dart';
import 'auth/session_update_notifier.dart';
import 'api/api_client.dart';
import 'attachments/attachment_file_saver.dart';
import 'attachments/attachment_upload_source.dart';
import 'attachments/host_attachment_service.dart';
import 'archive/portable_vault_archive.dart';
import 'crypto/jcs.dart';
import 'crypto/account_recovery_crypto.dart'
    hide decodeBase64Url, encodeBase64Url;
import 'crypto/host_attachment_crypto.dart';
import 'crypto/vault_crypto.dart';
import 'domain/credential_conflict_merge.dart';
import 'domain/conflict_feed.dart';
import 'domain/device_redaction_capability.dart';
import 'domain/host_security_conflict_merge.dart';
import 'domain/known_host.dart';
import 'domain/models.dart';
import 'ssh/port_forward_rule_change.dart';
import 'domain/record_redaction.dart';
import 'domain/shell_history_record.dart';
import 'domain/vault_preference.dart';
import 'domain/sftp_entries.dart';
import 'domain/sftp_transfer.dart';
import 'domain/snippet_invocation.dart';
import 'domain/workspace_layout.dart';
import 'sftp/sftp_file_picker.dart';
import 'sftp/dart_sftp_text_file_system.dart';
import 'sftp/sftp_text_editor_service.dart';
import 'ssh/ssh_service.dart';
import 'ssh/tmux_service.dart';
import 'terminal/terminal_collaboration_service.dart';
import 'terminal/mirrored_terminal.dart';
import 'terminal/session_log.dart';
import 'telnet/telnet_errors.dart';
import 'telnet/telnet_session.dart';
import 'telnet/telnet_transport.dart';
import 'platform/application_windows.dart';
import 'terminal/encrypted_shell_history_repository.dart';
import 'terminal/shell_integration_protocol.dart';
import 'terminal/shell_integration_session.dart';
import 'terminal/shell_history_completion.dart';
import 'storage/client_database.dart';
import 'storage/database_quarantine.dart';
import 'storage/secure_store.dart';
import 'storage/sync_preference_store.dart';
import 'sync/auto_sync.dart';
import 'mobile_push/mobile_push_registration.dart';
import 'sync/sync_hint_client.dart';
import 'sync/locked_sync_receiver.dart';
import 'sync/known_host_decision_lock.dart';
import 'sync/device_redaction_capability_publisher.dart';
import 'sync/sync_repository.dart';
import 'sync/sync_repository_e2e_hook.dart';
import 'l10n/l10n.dart';

const _uuid = Uuid();
const _emitSafeTeamLifecycleTrace = bool.fromEnvironment(
  'ATERMIUS_SAFE_TEAM_LIFECYCLE_TRACE',
  defaultValue: false,
);
String get _instanceIdentityRecoveryMessage =>
    currentL10n.theServerSigningKeyDoesntMatch2;
void _traceSafeTeamLifecycle(String phase, [Object? error]) {
  if (!_emitSafeTeamLifecycleTrace) return;
  debugPrint(
    'ATERMIUS_TEAM_TRACE:$phase${error == null ? '' : ':${error.runtimeType}'}',
  );
}

bool _isSafeTerminalSuggestion(String command) {
  if (command.trim().isEmpty) return false;
  for (final rune in command.runes) {
    if (rune < 0x20 || (rune >= 0x7f && rune <= 0x9f)) return false;
  }
  return true;
}

int get _clientDeviceCapabilityRevision =>
    supportsStreamingAttachmentSave ? 2 : 1;
int get _clientMaxRecordSchema => supportsStreamingAttachmentSave ? 2 : 1;
List<int> get _clientAttachmentManifestVersions =>
    supportsStreamingAttachmentSave ? const [1, 2] : const [1];
int get _clientMaxAttachmentBytes => maxAttachmentBytesForPlatform;
final _canonicalUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

bool _isCanonicalUuid(String value) => _canonicalUuid.hasMatch(value);

typedef SshConnectorForTesting = Future<SshConnection> Function({
  required HostRecord host,
  required CredentialRecord credential,
  required Future<bool> Function(String type, String fingerprint) verifyHostKey,
});

/// Jump-aware counterpart to the legacy direct-only SSH test hook.
@visibleForTesting
typedef SshConnectorWithJumpForTesting = Future<SshConnection> Function({
  required HostRecord host,
  required CredentialRecord credential,
  required Future<bool> Function(String type, String fingerprint) verifyHostKey,
  required HostRecord? jumpHost,
  required CredentialRecord? jumpCredential,
  required Future<bool> Function(String type, String fingerprint)?
  verifyJumpHostKey,
});

@visibleForTesting
typedef SshConnectorWithRouteForTesting = Future<SshConnection> Function({
  required HostRecord host,
  required CredentialRecord credential,
  required Future<bool> Function(String type, String fingerprint) verifyHostKey,
  required List<SshJumpHop> jumpHops,
});

/// Test connector that can drive keyboard-interactive authentication through
/// the same AppController callback used by [SshService].
@visibleForTesting
typedef SshConnectorWithUserInfoForTesting = Future<SshConnection> Function({
  required HostRecord host,
  required CredentialRecord credential,
  required Future<bool> Function(String type, String fingerprint) verifyHostKey,
  required List<SshJumpHop> jumpHops,
  required Future<List<String>?> Function(
    HostRecord host,
    SSHUserInfoRequest request,
  )
  onUserInfoRequest,
});

@visibleForTesting
typedef SshConnectorWithCancellationForTesting =
    Future<SshConnection> Function({
      required HostRecord host,
      required CredentialRecord credential,
      required Future<bool> Function(String type, String fingerprint)
      verifyHostKey,
      required List<SshJumpHop> jumpHops,
      required SshConnectCancellation cancellation,
      required Future<List<String>?> Function(
        HostRecord host,
        SSHUserInfoRequest request,
      )
      onUserInfoRequest,
    });

@visibleForTesting
typedef TerminalShareObserverJoinerForTesting =
    Future<TerminalShareObserverSession> Function({required String sessionId});

typedef _ResolvedJumpHop = ({HostRecord host, CredentialRecord credential});

@visibleForTesting
typedef KnownHostTrustStatusForTesting = Future<KnownHostTrustStatus> Function({
  required String host,
  required int port,
  required String algorithm,
  required String fingerprint,
});

class _KnownHostTrustDecision {
  const _KnownHostTrustDecision({
    required this.status,
    required this.repository,
    required this.generation,
    this.offlineTransportUnavailable = false,
  });

  final KnownHostTrustStatus status;
  final SyncRepository? repository;
  final int generation;
  final bool offlineTransportUnavailable;
}

/// A controller operation whose captured account/server session or Vault
/// selection ended while it was awaiting. Nothing from it was applied to the
/// newer scope; key material it generated was wiped. [serverCommitted]
/// honestly reports that the server had already accepted the request (no
/// rollback is attempted or claimed).
class OperationScopeEndedException implements Exception {
  const OperationScopeEndedException({required this.serverCommitted});
  final bool serverCommitted;

  @override
  String toString() => serverCommitted
      ? currentL10n.cloudAccessErrorScopeEndedCommitted
      : currentL10n.theWorkspaceWasSwitchedTryAgain;
}

class KnownHostApprovalQueuedException implements Exception {
  const KnownHostApprovalQueuedException();

  @override
  String toString() => currentL10n.sshStoppedTheFirstHostKey;
}

class _ActiveSessionRefresh {
  const _ActiveSessionRefresh({
    required this.client,
    required this.base,
    required this.username,
    required this.session,
    required this.future,
  });

  final ApiClient client;
  final String base;
  final String username;
  final AuthSession session;
  final Future<bool> future;

  bool matches({
    required ApiClient candidateClient,
    required String candidateBase,
    required String candidateUsername,
    required AuthSession candidateSession,
  }) =>
      identical(client, candidateClient) &&
      base == candidateBase &&
      username == candidateUsername &&
      identical(session, candidateSession);
}

const _knownHostDecisionBudget = Duration(seconds: 45);
const _maxTerminalShareQueuedBytes = 256 * 1024;
const _terminalShareOutputBatchWindow = Duration(milliseconds: 50);
const _maxShellIntegrationHistoryCommands = 500;
final TmuxService _defaultTmuxService = SshTmuxService();

/// Runtime-only state for one interactive SSH terminal tab.
///
/// The Terminal model stays with the connection so output received while the
/// Terminal page is not mounted remains in that tab's scrollback.
class TerminalTabSession {
  TerminalTabSession({
    required this.id,
    required this.host,
    this.shellHistoryVaultId,
    this.onShellHistoryChanged,
  }) : terminal = MirroredTerminal(maxLines: 10000);

  final String id;
  final String? shellHistoryVaultId;
  HostRecord? host;
  final MirroredTerminal terminal;
  SshConnection? connection;
  LocalConsole? console;
  String? consoleSerialPort;
  int? consoleBaudRate;

  /// Non-secret launch metadata of an embedded local shell (null for serial
  /// consoles and every non-Console tab). Used by duplicate/split/window sets.
  LocalShellLaunch? consoleShell;
  DesktopSession? desktop;

  /// Plaintext Telnet session for a [HostProtocol.telnet] tab. Never set for
  /// SSH or Console tabs; SSH-only features check [connection] instead.
  TelnetSession? telnet;
  TelnetConnectCancellation? telnetCancellation;

  /// The live interactive transport (SSH, Telnet or Console), used for
  /// terminal focus/keyboard decisions. SSH-only features use [connection].
  Object? get liveTerminalTransport => connection ?? telnet ?? console;
  SshConnectCancellation? connectionCancellation = SshConnectCancellation();
  StreamSubscription<String>? outputSubscription;
  void Function(String text)? outputListener;
  final Map<Object, void Function(String text)> _outputFanout = {};
  SftpClient? sftp;
  Future<SftpClient>? sftpOpening;
  List<SftpName> sftpEntries = [];
  String sftpPath = '/';
  bool detached = false;
  String state = 'connecting';
  String? errorMessage;
  bool closed = false;

  /// Session-log lifecycle row for this SSH tab (sanitized; transcript only
  /// when the user enabled recording before the tab opened).
  SessionLogRecorder? log;
  final Completer<void> sshAuthenticationCancelled = Completer<void>();
  final Map<String, String> connectionCredentialFingerprints = {};
  final Map<String, String> connectionHostSnapshots = {};
  final Map<String, VerifiedTerminalHostKey> verifiedHostKeys = {};
  ShellIntegrationSession? shellIntegration;
  final List<ShellIntegrationCompletedCommand> _shellIntegrationHistory = [];
  void Function()? onShellHistoryChanged;
  void Function(List<ShellIntegrationCompletedCommand> commands)?
  onShellCommandsCompleted;
  EncryptedShellHistoryRepository? shellHistoryRepository;
  Future<void> shellHistoryPersistenceQueue = Future<void>.value();
  Future<void> shellHistoryRestoration = Future<void>.value();
  int shellHistoryRestorationGeneration = 0;

  List<ShellIntegrationCompletedCommand> get shellIntegrationHistory =>
      List.unmodifiable(_shellIntegrationHistory);

  void appendShellIntegrationHistory(
    Iterable<ShellIntegrationCompletedCommand> commands,
  ) {
    final added = List<ShellIntegrationCompletedCommand>.unmodifiable(commands);
    if (added.isEmpty) return;
    _shellIntegrationHistory.addAll(added);
    final overflow =
        _shellIntegrationHistory.length - _maxShellIntegrationHistoryCommands;
    if (overflow > 0) _shellIntegrationHistory.removeRange(0, overflow);
    onShellCommandsCompleted?.call(added);
    onShellHistoryChanged?.call();
  }

  void replaceShellIntegrationHistory(
    Iterable<ShellIntegrationCompletedCommand> commands,
  ) {
    _shellIntegrationHistory
      ..clear()
      ..addAll(commands);
    final overflow =
        _shellIntegrationHistory.length - _maxShellIntegrationHistoryCommands;
    if (overflow > 0) _shellIntegrationHistory.removeRange(0, overflow);
    onShellHistoryChanged?.call();
  }

  void clearShellIntegrationHistory() {
    _shellIntegrationHistory.clear();
    onShellHistoryChanged?.call();
  }

  String enableShellIntegration() {
    final existing = shellIntegration;
    if (existing != null && existing.isActive) {
      return existing.bootstrapCommand;
    }
    existing?.close();
    final integration = ShellIntegrationSession(terminalId: id);
    shellIntegration = integration;
    terminal.onPrivateOSC = (code, args) {
      if (closed || !identical(shellIntegration, integration)) return;
      final completed = integration.accept(code, args);
      if (completed.isNotEmpty) appendShellIntegrationHistory(completed);
      if (!integration.isActive) {
        shellIntegration = null;
        terminal.onPrivateOSC = null;
        onShellHistoryChanged?.call();
      }
    };
    onShellHistoryChanged?.call();
    return integration.bootstrapCommand;
  }

  void disableShellIntegration({bool clearHistory = false}) {
    shellIntegration?.close();
    shellIntegration = null;
    terminal.onPrivateOSC = null;
    if (clearHistory) clearShellIntegrationHistory();
    onShellHistoryChanged?.call();
  }

  Object addOutputFanout(void Function(String text) listener) {
    final token = Object();
    _outputFanout[token] = listener;
    return token;
  }

  void removeOutputFanout(Object token) => _outputFanout.remove(token);

  void publishOutputToFanout(String text) {
    for (final listener in _outputFanout.values.toList(growable: false)) {
      try {
        listener(text);
      } catch (_) {
        // An optional observer must never interrupt the SSH output stream.
      }
    }
  }

  void cancelPendingSshAuthentication() {
    if (!sshAuthenticationCancelled.isCompleted) {
      sshAuthenticationCancelled.complete();
    }
  }
}

/// Runtime-only view of the host-side sharing state for one SSH tab.
class TerminalShareHostStatus {
  const TerminalShareHostStatus({
    required this.sessionId,
    required this.expiresAt,
    required this.observerCount,
    required this.phase,
    this.inputControlEnabled = false,
    this.controllerDeviceId,
    this.controllerLabel,
    this.controllerExpiresAt,
    this.controllerRevoking = false,
    this.errorMessage,
  });

  final String sessionId;
  final DateTime expiresAt;
  final int observerCount;
  final String phase;
  final bool inputControlEnabled;
  final String? controllerDeviceId;
  final String? controllerLabel;
  final DateTime? controllerExpiresAt;
  final bool controllerRevoking;
  final String? errorMessage;
}

class TerminalShareStartSelection {
  const TerminalShareStartSelection({
    required this.devices,
    required this.allowInputControl,
  });

  final List<TerminalShareDeviceChoice> devices;
  final bool allowInputControl;
}

class TerminalShareDeviceChoice {
  const TerminalShareDeviceChoice({
    required this.recipient,
    required this.deviceName,
    required this.memberName,
    required this.vaultId,
    required this.membershipVersion,
    required this.hostAccountId,
    required this.hostDeviceId,
    required this.hostIdentity,
  });

  final TerminalShareRecipient recipient;
  final String deviceName;
  final String memberName;
  final String vaultId;
  final String membershipVersion;
  final String hostAccountId;
  final String hostDeviceId;
  final DeviceIdentity hostIdentity;

  String get label => '$memberName · $deviceName';
}

class _TerminalShareHostRuntime {
  _TerminalShareHostRuntime({
    required this.handle,
    required this.tab,
    required this.outputFanoutToken,
    required this.status,
    required this.approvedObservers,
  });

  final TerminalShareHostSession handle;
  final TerminalTabSession tab;
  final Object outputFanoutToken;
  final List<TerminalShareDeviceChoice> approvedObservers;
  TerminalShareHostStatus status;
  StreamSubscription<TerminalCollaborationHostEvent>? eventSubscription;
  TerminalControllerLease? controllerLease;
  TerminalShareDeviceChoice? controllerChoice;
  bool controllerRevoking = false;
  Future<void> publishQueue = Future<void>.value();
  final StringBuffer pendingOutput = StringBuffer();
  Timer? outputFlushTimer;
  int pendingOutputBytes = 0;
  int queuedBytes = 0;
  bool stopping = false;
}

/// Runtime-only observer terminal. It has no input or resize path.
class TerminalObserverTabSession {
  TerminalObserverTabSession({required this.id, required this.handle})
    : terminal = Terminal(maxLines: 10000);

  final String id;
  Terminal terminal;
  TerminalShareObserverSession handle;
  StreamSubscription<TerminalCollaborationEvent>? subscription;
  int connectionGeneration = 0;
  TerminalShareControllerSession? controller;
  String? grantedLeaseId;
  int? grantedControlEpoch;
  DateTime? grantedControlExpiresAt;
  String? controlErrorMessage;
  bool joiningController = false;
  Timer? controlExpiryTimer;
  String state = 'connecting';
  String? errorMessage;
  bool reconnecting = false;
  bool closed = false;
}

class AccountRecoverySetupResult {
  const AccountRecoverySetupResult({
    required this.recoveryCode,
    required this.status,
    required this.coveredContexts,
    required this.requiredContexts,
  });

  final String recoveryCode;
  final String status;
  final int coveredContexts;
  final int requiredContexts;
}

class AccountRecoveryPreparation {
  const AccountRecoveryPreparation({
    required this.recoveryCode,
    required this.recoveredContexts,
  });

  final String recoveryCode;
  final int recoveredContexts;
}

class PendingInstanceIdentityRecovery {
  const PendingInstanceIdentityRecovery({
    required this.baseUrl,
    required this.pinnedIdentity,
    required this.candidate,
    required this.pinnedFingerprint,
    required this.candidateFingerprint,
  });

  final String baseUrl;
  final ServerIdentityPin pinnedIdentity;
  final InstanceInfo candidate;
  final String pinnedFingerprint;
  final String candidateFingerprint;
}

class InstanceIdentityRecoveryRequiredException implements Exception {
  const InstanceIdentityRecoveryRequiredException();

  @override
  String toString() => currentL10n.theServerSigningKeyDoesntMatch;
}

class _PendingFullAccountRecovery {
  _PendingFullAccountRecovery({
    required this.request,
    required this.device,
    required this.baseUrl,
    required this.challengeExpiresAt,
  });

  final Map<String, Object?> request;
  final DeviceIdentity device;
  final String baseUrl;
  final DateTime challengeExpiresAt;

  void dispose() {
    device.dispose();
    request.clear();
  }
}

class VerifiedTerminalHostKey {
  const VerifiedTerminalHostKey({
    required this.host,
    required this.port,
    required this.algorithm,
    required this.fingerprint,
  });

  final String host;
  final int port;
  final String algorithm;
  final String fingerprint;

  String get endpoint => endpointKey(host: host, port: port);
  String get key => '$endpoint|$algorithm';

  /// Includes the presented fingerprint so a changed key cannot consume a
  /// proof for another key at the same endpoint and algorithm.
  String get proofKey => jsonEncode([host, port, algorithm, fingerprint]);
}

class _VerifiedTerminalHostKeyProof {
  const _VerifiedTerminalHostKeyProof({
    required this.hostKey,
    required this.repository,
    required this.generation,
    required this.accountId,
    required this.deviceId,
    required this.vaultId,
  });

  final VerifiedTerminalHostKey hostKey;
  final SyncRepository? repository;
  final int generation;
  final String? accountId;
  final String? deviceId;
  final String? vaultId;
}

class SnippetBatchTargetOutcome {
  const SnippetBatchTargetOutcome({
    required this.hostId,
    required this.hostName,
    required this.endpoint,
    this.result,
    this.error,
    this.skipped = false,
    this.completionUnknown = false,
  });

  final String hostId;
  final String hostName;
  final String endpoint;
  final SshExecResult? result;
  final String? error;
  final bool skipped;
  final bool completionUnknown;
}

class SnippetExecCompletionUnknownException implements Exception {
  const SnippetExecCompletionUnknownException();

  @override
  String toString() => currentL10n.sshExecFailedAfterDispatchRemote;
}

class _SnippetBatchPreflightCancelled implements Exception {
  const _SnippetBatchPreflightCancelled();
}

enum HostCredentialSource { hostOverride, groupDefault, none }

/// Safe, secret-free resolution details used by the Host editor and SSH path.
class HostCredentialResolution {
  const HostCredentialResolution({
    required this.source,
    this.credentialId,
    this.credential,
    this.sourceGroupId,
    this.sourceGroupName,
    this.missingGroupId,
  });

  final HostCredentialSource source;
  final String? credentialId;
  final CredentialRecord? credential;
  final String? sourceGroupId;
  final String? sourceGroupName;
  final String? missingGroupId;

  bool get isResolved => credential != null;
  bool get hasCredentialReference => credentialId != null;
  bool get hasStaleReference =>
      missingGroupId != null || (credentialId != null && credential == null);

  String get displayText {
    if (credential != null) {
      final identity = '${credential!.name} · ${credential!.username}';
      return source == HostCredentialSource.hostOverride
          ? currentL10n.hostOverrideIdentity(identity)
          : currentL10n.inheritedFromValuevalueIdentity(
              sourceGroupName ?? currentL10n.groupDefault,
              identity,
            );
    }
    if (credentialId != null) {
      return source == HostCredentialSource.hostOverride
          ? currentL10n.hostOverrideIsUnavailableChooseInherit
          : currentL10n.groupDefaultIsUnavailableChooseA;
    }
    if (missingGroupId != null) {
      return currentL10n.theGroupInheritanceChainIsUnavailable;
    }
    return currentL10n.noEffectiveSshCredentialIsSet;
  }

  String get connectionError => credentialId != null
      ? currentL10n.theEffectiveSshCredentialIsUnavailable
      : missingGroupId != null
      ? currentL10n.theHostGroupInheritanceChainIs
      : currentL10n.noSshCredentialIsConfiguredChoose;
}

bool _sameArchiveBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

enum ClientStage { server, login, register, workspace }

enum WorkspacePreferenceSaveOutcome {
  savedToActiveVault,
  queuedInOriginalVault,
}

String _preferenceTupleKey(String scope, String key, String platformFamily) =>
    '$scope\u0000$key\u0000$platformFamily';

class _PreferenceTupleConflictState {
  final List<VaultPreferenceRecord> candidates = [];
  final Set<String> observedCandidateIds = {};
  bool repairRequired = false;
  bool repairBusy = false;
  bool verificationBlocked = false;
  bool markerConflictBlocked = false;
  String? retainedRecordId;
  int? observedServerViewRevision;
}

enum AuditScope { account, activeVault }

enum WorkspacePage {
  hosts,
  groups,
  credentials,
  logs,
  forwarding,
  snippets,
  savedWorkspaces,
  terminal,
  sftp,
  sync,
  audit,
  devices,
  settings,
}

class _PendingAccountPasswordChange {
  const _PendingAccountPasswordChange({
    required this.accountId,
    required this.deviceId,
    required this.previousCredentialVersion,
    required this.operationId,
    required this.request,
  });

  final String accountId;
  final String deviceId;
  final int previousCredentialVersion;
  final String operationId;
  final Map<String, Object?> request;
}

/// Full host-key context passed to a UI trust-confirmation dialog.
class KnownHostApprovalRequest {
  const KnownHostApprovalRequest({
    required this.host,
    required this.port,
    required this.algorithm,
    required this.fingerprint,
    required this.previouslyRevoked,
    this.offlineTransportUnavailable = false,
  });

  final String host;
  final int port;
  final String algorithm;
  final String fingerprint;
  final bool previouslyRevoked;
  final bool offlineTransportUnavailable;

  String get endpoint => endpointKey(host: host, port: port);
}

void _validateMembershipOwnerChain({
  required String vaultId,
  required List<VerifiedMembership> chain,
  required Map<String, Map<String, dynamic>> directory,
}) {
  List<Map<String, dynamic>> parseMembers(VerifiedMembership membership) {
    final raw = membership.manifest['members'];
    if (raw is! List || raw.isEmpty) {
      throw FormatException(
        currentL10n.vaultVaultidMembershipHasNoMembers(vaultId),
      );
    }
    final members = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final value in raw) {
      if (value is! Map) {
        throw FormatException(
          currentL10n.vaultVaultidMembershipHasAnInvalid(vaultId),
        );
      }
      final member = Map<String, dynamic>.from(value);
      final userId = member['user_id'];
      final role = member['role'];
      final state = member['state'];
      if (userId is! String ||
          !_isCanonicalUuid(userId) ||
          !seen.add(userId) ||
          role is! String ||
          !const {'owner', 'editor', 'viewer'}.contains(role) ||
          state is! String ||
          !const {'active', 'invited', 'revoked'}.contains(state)) {
        throw FormatException(
          currentL10n.vaultVaultidMembershipHasAnInvalid(vaultId),
        );
      }
      members.add(member);
    }
    return members;
  }

  String soleActiveOwner(List<Map<String, dynamic>> members) {
    final owners = members
        .where(
          (member) => member['role'] == 'owner' && member['state'] == 'active',
        )
        .map((member) => member['user_id']! as String)
        .toList(growable: false);
    if (owners.length != 1) {
      throw FormatException(
        currentL10n.vaultVaultidMembershipMustContainExactly(vaultId),
      );
    }
    return owners.single;
  }

  final parsedMembers = chain.map(parseMembers).toList(growable: false);
  for (var index = 0; index < chain.length; index++) {
    final membership = chain[index];
    final signer = directory[membership.signerDeviceId];
    final signerUserId = signer?['user_id'] as String?;
    final members = parsedMembers[index];
    final nextOwner = soleActiveOwner(members);
    if (signer == null ||
        signerUserId == null ||
        !_isCanonicalUuid(signerUserId) ||
        membership.manifest['signer_device_id'] != membership.signerDeviceId) {
      throw FormatException(
        currentL10n.vaultVaultidMembershipSignerIsAbsent(vaultId),
      );
    }

    final hasTransfer = membership.manifest.containsKey('ownership_transfer');
    final transferValue = membership.manifest['ownership_transfer'];
    if (signerUserId == nextOwner) {
      if (hasTransfer) {
        throw FormatException(
          currentL10n.vaultVaultidHasAnOwnershipTransfer(vaultId),
        );
      }
      if (index > 0 && soleActiveOwner(parsedMembers[index - 1]) != nextOwner) {
        throw FormatException(
          currentL10n.vaultVaultidChangedOwnerWithoutA(vaultId),
        );
      }
      continue;
    }
    if (index == 0 || transferValue is! Map) {
      throw FormatException(
        currentL10n.vaultVaultidMembershipWasNotSigned(vaultId),
      );
    }

    final transfer = Map<String, dynamic>.from(transferValue);
    if (transfer.length != 2 ||
        !transfer.containsKey('from_user_id') ||
        !transfer.containsKey('to_user_id')) {
      throw FormatException(
        currentL10n.vaultVaultidOwnershipTransferMetadataIs(vaultId),
      );
    }
    final previousMembership = chain[index - 1];
    final previousMembers = parsedMembers[index - 1];
    final previousOwner = soleActiveOwner(previousMembers);
    final fromUserId = transfer['from_user_id'];
    final toUserId = transfer['to_user_id'];
    final previousTarget = previousMembers
        .where((member) => member['user_id'] == toUserId)
        .firstOrNull;
    final currentFormerOwner = members
        .where((member) => member['user_id'] == fromUserId)
        .firstOrNull;
    final currentNewOwner = members
        .where((member) => member['user_id'] == toUserId)
        .firstOrNull;
    final previousEpoch = previousMembership.manifest['key_epoch'];
    final currentEpoch = membership.manifest['key_epoch'];
    if (fromUserId != previousOwner ||
        toUserId != nextOwner ||
        signerUserId != previousOwner ||
        previousTarget == null ||
        previousTarget['state'] != 'active' ||
        !const {'editor', 'viewer'}.contains(previousTarget['role']) ||
        currentFormerOwner == null ||
        currentFormerOwner['role'] != 'editor' ||
        currentFormerOwner['state'] != 'active' ||
        currentNewOwner == null ||
        currentNewOwner['role'] != 'owner' ||
        currentNewOwner['state'] != 'active' ||
        previousEpoch is! int ||
        currentEpoch is! int ||
        currentEpoch != previousEpoch + 1) {
      throw FormatException(
        currentL10n.vaultVaultidOwnershipTransferDoesNot(vaultId),
      );
    }

    final previousById = {
      for (final member in previousMembers)
        member['user_id']! as String: member,
    };
    final currentById = {
      for (final member in members) member['user_id']! as String: member,
    };
    if (previousById.keys
            .toSet()
            .difference(currentById.keys.toSet())
            .isNotEmpty ||
        currentById.keys
            .toSet()
            .difference(previousById.keys.toSet())
            .isNotEmpty) {
      throw FormatException(
        currentL10n.vaultVaultidOwnershipTransferUnexpectedlyChanged(vaultId),
      );
    }
    for (final entry in previousById.entries) {
      final nextMember = Map<String, dynamic>.from(currentById[entry.key]!);
      final previousMember = Map<String, dynamic>.from(entry.value);
      if (entry.key == fromUserId) {
        previousMember.remove('role');
        nextMember.remove('role');
      } else if (entry.key == toUserId) {
        previousMember.remove('role');
        nextMember.remove('role');
      }
      if (canonicalJson(previousMember) != canonicalJson(nextMember)) {
        throw FormatException(
          currentL10n.vaultVaultidOwnershipTransferChangedUnrelated(vaultId),
        );
      }
    }
  }
}

class _VaultLoadSuperseded implements Exception {
  const _VaultLoadSuperseded();
}

/// Load state of the device-local "Automatic sync" choice.
enum AutomaticSyncPreferenceState {
  /// Not read yet; automatic transfer stays inactive.
  loading,

  /// Stored choice (or the default when none exists) is in effect.
  ready,

  /// A stored choice exists but could not be read. Automatic transfer stays
  /// inactive so an earlier "off" is never overridden by the default.
  readFailed,
}

enum SyncNowOutcome {
  /// A pass reached the server and nothing is waiting to upload.
  completed,

  /// A pass reached the server but encrypted changes are still queued.
  completedWithPending,

  /// The pass failed or could not run; see [SyncNowResult.error] and the
  /// controller's sync status. Nothing is reported as synced.
  notCompleted,

  /// No signed-in account session; sync needs an account login.
  signInRequired,

  /// The account, device or Vault changed while the action ran; its result
  /// belongs to the previous scope and is not shown.
  superseded,
}

@immutable
class SyncNowResult {
  const SyncNowResult(this.outcome, {this.error});

  final SyncNowOutcome outcome;
  final Object? error;
}

class AppController extends ChangeNotifier {
  /// Cloud session logs: sanitized lifecycle rows (and opt-in output
  /// transcripts) kept in memory only, bound to server/account/device/Vault.
  /// A scope change or retirement (lock, logout, credential cleanup, dispose)
  /// discards the old book; late callbacks of old sessions cannot repopulate
  /// the new scope.
  late final ScopedSessionLogBook _sessionLogScope = ScopedSessionLogBook(
    () => (
      api?.baseUrl,
      session?.accountId,
      identity?.deviceId,
      activeVault?.id,
    ),
  );
  SessionLogBook get sessionLogs => _sessionLogScope.current;

  static const int maxTerminalTabs = 8;
  static const _accountControlPlaneRefreshInterval = Duration(seconds: 45);

  AppController({
    required this.sodium,
    required this.database,
    required this.secureStore,
    @visibleForTesting SyncRepository? repositoryForTesting,
    @visibleForTesting Uint8List? shellHistoryVaultKeyForTesting,
    @visibleForTesting KnownHostDecisionLock? knownHostDecisionLockForTesting,
    @visibleForTesting this.loadRecordsForTesting,
    @visibleForTesting this.beforeHostEditorSaveForTesting,
    @visibleForTesting this.beforeVaultReferenceWriteForTesting,
    @visibleForTesting this.sessionUpdateNotifierForTesting,
    @visibleForTesting SessionRefreshLock? sessionRefreshLockForTesting,
    @visibleForTesting this.sshConnectorForTesting,
    @visibleForTesting this.sshConnectorWithJumpForTesting,
    @visibleForTesting this.sshConnectorWithRouteForTesting,
    @visibleForTesting this.sshConnectorWithUserInfoForTesting,
    @visibleForTesting this.sshConnectorWithCancellationForTesting,
    @visibleForTesting this.knownHostTrustStatusForTesting,
    @visibleForTesting this.tmuxServiceForTesting,
    @visibleForTesting this.terminalShareObserverJoinerForTesting,
    @visibleForTesting this.nowForTesting,
    @visibleForTesting
    this.vaultPresenceHeartbeatIntervalForTesting = const Duration(seconds: 30),
    @visibleForTesting
    this.membersPresenceRefreshIntervalForTesting = const Duration(seconds: 30),
    @visibleForTesting
    this.adminRestorePollIntervalForTesting = const Duration(seconds: 5),
    @visibleForTesting this.adminRestorePollMaxAttemptsForTesting = 120,
    @visibleForTesting this.apiClientFactoryForTesting,
    @visibleForTesting MobilePushRegistration? mobilePushRegistrationForTesting,
    @visibleForTesting this.mobilePushAutoSyncForTesting,
    SyncPreferenceStore? syncPreferenceStore,
  }) : crypto = VaultCrypto(sodium),
       recoveryCrypto = AccountRecoveryCrypto(sodium),
       _knownHostDecisionLock =
           knownHostDecisionLockForTesting ?? createKnownHostDecisionLock(),
       _sessionRefreshLock =
           sessionRefreshLockForTesting ?? createSessionRefreshLock(),
       _mobilePushRegistration =
           mobilePushRegistrationForTesting ??
           createPlatformMobilePushRegistration(),
       _repository = repositoryForTesting,
       _syncPreferenceStore =
           syncPreferenceStore ?? MemorySyncPreferenceStore(),
       // Without a persistent store there is no earlier device choice to
       // honour, so the default applies immediately. A persistent store keeps
       // automatic transfer inactive until its stored choice has loaded.
       automaticSyncPreference = syncPreferenceStore == null
           ? AutomaticSyncPreferenceState.ready
           : AutomaticSyncPreferenceState.loading {
    if (repositoryForTesting != null &&
        shellHistoryVaultKeyForTesting != null) {
      _vaultKeys[repositoryForTesting.vaultId] = shellHistoryVaultKeyForTesting;
    }
    _automaticSync = AutoSyncCoordinator(
      isEnabled: () =>
          authenticated &&
          stage == ClientStage.workspace &&
          !databaseRecoveryRequired &&
          syncStatus != 'snapshot_too_large',
      synchronize: () =>
          mobilePushAutoSyncForTesting?.call() ?? _synchronizeAutomatically(),
      initialUserEnabled: automaticSyncActive,
    );
    _syncHints = SyncHintClient(
      fetchTicket: () async =>
          (await _requireApi().createNotificationTicket()).ticket,
      onHint: _handleSyncHint,
      refreshSession: _refreshSessionForSyncHint,
    );
    databaseQuarantineRegistry.addListener(_onDatabaseQuarantineChanged);
    _onDatabaseQuarantineChanged();
    _sessionCredentialsObserver;
    if (syncPreferenceStore != null) {
      unawaited(_loadAutomaticSyncPreference());
    }
  }

  final SodiumSumo sodium;
  final VaultCrypto crypto;
  final AccountRecoveryCrypto recoveryCrypto;
  final KnownHostDecisionLock _knownHostDecisionLock;
  final ClientDatabase database;
  final ClientSecureStore secureStore;
  @visibleForTesting
  final DateTime Function()? nowForTesting;
  @visibleForTesting
  final Duration vaultPresenceHeartbeatIntervalForTesting;
  @visibleForTesting
  final Duration membersPresenceRefreshIntervalForTesting;
  @visibleForTesting
  final Duration adminRestorePollIntervalForTesting;
  @visibleForTesting
  final int adminRestorePollMaxAttemptsForTesting;
  @visibleForTesting
  final ApiClient Function(String baseUrl)? apiClientFactoryForTesting;
  final MobilePushRegistration _mobilePushRegistration;
  @visibleForTesting
  final Future<void> Function()? mobilePushAutoSyncForTesting;
  @visibleForTesting
  final Future<List<Map<String, dynamic>>> Function(SyncRepository repository)?
  loadRecordsForTesting;
  @visibleForTesting
  final Future<void> Function()? beforeHostEditorSaveForTesting;
  @visibleForTesting
  final Future<void> Function({
    required String recordId,
    required String operation,
  })?
  beforeVaultReferenceWriteForTesting;
  @visibleForTesting
  final SessionUpdateNotifier? sessionUpdateNotifierForTesting;
  @visibleForTesting
  final SshConnectorForTesting? sshConnectorForTesting;

  /// Replaces the Telnet TCP/Relay transport in tests (loopback fixtures).
  @visibleForTesting
  TelnetChannelConnector? telnetConnectorForTesting;
  @visibleForTesting
  final TerminalShareObserverJoinerForTesting?
  terminalShareObserverJoinerForTesting;
  @visibleForTesting
  final SshConnectorWithJumpForTesting? sshConnectorWithJumpForTesting;
  @visibleForTesting
  final SshConnectorWithRouteForTesting? sshConnectorWithRouteForTesting;
  @visibleForTesting
  final SshConnectorWithUserInfoForTesting? sshConnectorWithUserInfoForTesting;
  @visibleForTesting
  final SshConnectorWithCancellationForTesting?
  sshConnectorWithCancellationForTesting;
  @visibleForTesting
  final KnownHostTrustStatusForTesting? knownHostTrustStatusForTesting;
  @visibleForTesting
  final TmuxService? tmuxServiceForTesting;

  ClientStage stage = ClientStage.server;
  WorkspacePage page = WorkspacePage.hosts;
  ApiClient? api;
  InstanceInfo? instance;
  ApiClient? _pendingInstanceIdentityRecoveryApi;
  PendingInstanceIdentityRecovery? pendingInstanceIdentityRecovery;
  bool _confirmingInstanceIdentityRecovery = false;
  AuthSession? _session;
  AuthSession? get session => _session;
  set session(AuthSession? value) {
    _session = value;
    final notifier = _sessionUpdateNotifier;
    if (notifier is ScopedSessionUpdateNotifier) {
      (notifier as ScopedSessionUpdateNotifier).watchScope(
        _currentSessionScope(),
      );
    }
  }

  AccountProfile? account;
  DeviceIdentity? identity;
  Uint8List? _accountKey;
  RecoveryIdentity? _recoveryIdentity;
  String accountRecoveryStatus = 'disabled';
  List<AccountRecoveryContext> accountRecoveryRequiredContexts = const [];
  List<AccountRecoveryContext> accountRecoveryPresentContexts = const [];
  bool accountRecoveryBusy = false;
  bool? accountMfaEnabled;
  int? accountMfaRecoveryCodesRemaining;
  bool accountMfaBusy = false;
  bool mobilePushEnabled = false;
  bool mobilePushBusy = false;
  StreamSubscription<MobilePushToken>? _mobilePushTokenSubscription;
  StreamSubscription<Map<String, dynamic>>? _mobilePushMessageSubscription;
  String? _mobilePushListeningAccountId;
  String? _mobilePushListeningDeviceId;
  int _mobilePushGeneration = 0;
  int? _mobilePushBusyGeneration;
  ApiClient? _mobilePushBusyClient;
  String? _mobilePushBusyAccountId;
  String? _mobilePushBusyDeviceId;
  Future<void> _mobilePushWriteQueue = Future<void>.value();
  VaultDescriptor? activeVault;
  final Map<String, Uint8List> _vaultKeys = {};
  final Map<String, Map<String, Uint8List>> _vaultEpochKeys = {};
  final Map<String, String> _revisionIds = {};
  final Set<String> pendingKnownHostRecordIds = {};
  final Map<String, String> _knownNames = {};
  Future<void>? _recoverySyncFuture;
  bool _recoverySyncRequested = false;
  _PendingFullAccountRecovery? _pendingFullAccountRecovery;
  bool _pendingFullAccountRecoveryCompletionAttempted = false;
  bool get hasPreparedFullAccountRecovery =>
      _pendingFullAccountRecovery != null;
  final List<HostRecord> hosts = [];
  final List<CredentialRecord> credentials = [];
  final List<GroupRecord> groups = [];
  final List<SnippetRecord> snippets = [];
  final List<ShellHistoryRecord> shellHistoryRecords = [];
  final List<WorkspaceRecord> savedWorkspaces = [];
  String? activeSavedWorkspaceId;
  // A saved Workspace contains layout intent only. Runtime SSH tab bindings
  // stay in memory and are cleared with their tab/Vault; they are never synced.
  final Map<String, Map<String, String>> _workspacePaneTerminalTabIds = {};
  final Map<String, TmuxAttachHandle> _tmuxAttachHandles = {};
  final Map<String, SshExecCancellation> _tmuxOperationCancellations = {};
  final Set<String> _workspaceTmuxBusyKeys = {};
  int _stagedWorkspaceSelectionGeneration = 0;
  // Reserve a pane before any asynchronous credential fingerprinting begins.
  // Otherwise rapid duplicate Connect actions can both observe an empty pane
  // binding and open independent SSH tabs for the same pane.
  final Map<({String vaultId, String workspaceId, String paneId}), Future<void>>
  _workspacePaneConnectFlights = {};
  bool _snippetExecutionInProgress = false;
  bool _shellHistorySyncEnabled = false;
  bool _shellHistorySyncEnableInProgress = false;
  int _shellHistorySyncPreferenceGeneration = 0;
  Future<void> _shellHistorySyncWriteQueue = Future<void>.value();
  final List<KnownHostRecord> knownHosts = [];
  final List<VaultPreferenceRecord> preferences = [];
  String? preferenceError;
  final Map<String, _PreferenceTupleConflictState> _preferenceConflicts = {};
  bool _unsupportedVaultPreferencePresent = false;
  bool _preferenceRepairScanFailed = false;
  _PreferenceTupleConflictState _preferenceConflictState(
    String scope,
    String key,
    String platformFamily,
  ) => _preferenceConflicts.putIfAbsent(
    _preferenceTupleKey(scope, key, platformFamily),
    _PreferenceTupleConflictState.new,
  );

  _PreferenceTupleConflictState get _defaultSectionConflictState =>
      _preferenceConflictState(
        VaultPreferenceRecord.workspaceScope,
        VaultPreferenceRecord.defaultSectionKey,
        VaultPreferenceRecord.allPlatforms,
      );

  _PreferenceTupleConflictState get _terminalFontSizeConflictState =>
      _preferenceConflictState(
        VaultPreferenceRecord.workspaceScope,
        VaultPreferenceRecord.terminalFontSizeKey,
        VaultPreferenceRecord.allPlatforms,
      );

  _PreferenceTupleConflictState get _terminalThemeConflictState =>
      _preferenceConflictState(
        VaultPreferenceRecord.workspaceScope,
        VaultPreferenceRecord.terminalThemeKey,
        VaultPreferenceRecord.allPlatforms,
      );

  _PreferenceTupleConflictState get _terminalShortcutsConflictState =>
      _preferenceConflictState(
        VaultPreferenceRecord.workspaceScope,
        VaultPreferenceRecord.terminalShortcutsKey,
        VaultPreferenceRecord.allPlatforms,
      );

  List<VaultPreferenceRecord> get defaultSectionConflictCandidates =>
      List.unmodifiable(_defaultSectionConflictState.candidates);
  List<VaultPreferenceRecord> get terminalFontSizeConflictCandidates =>
      List.unmodifiable(_terminalFontSizeConflictState.candidates);
  List<VaultPreferenceRecord> get terminalThemeConflictCandidates =>
      List.unmodifiable(_terminalThemeConflictState.candidates);
  List<VaultPreferenceRecord> get terminalShortcutsConflictCandidates =>
      List.unmodifiable(_terminalShortcutsConflictState.candidates);
  WorkspaceRecord? get activeSavedWorkspace => activeSavedWorkspaceId == null
      ? null
      : savedWorkspaces
            .where((item) => item.id == activeSavedWorkspaceId)
            .firstOrNull;

  TerminalTabSession? workspacePaneTerminalTab(
    String workspaceId,
    String paneId,
  ) {
    final workspace = savedWorkspaces
        .where((item) => item.id == workspaceId)
        .firstOrNull;
    final pane = workspace?.panes
        .where((item) => item.paneId == paneId)
        .firstOrNull;
    if (pane == null) return null;
    final tabId = _workspacePaneTerminalTabIds[workspaceId]?[paneId];
    final tab = tabId == null ? null : _terminalTabs[tabId];
    if (tab == null || tab.closed || tab.host?.id != pane.hostId) return null;
    return tab;
  }

  WorkspaceSessionDescriptor? workspacePaneSessionDescriptor(
    String workspaceId,
    String paneId,
  ) {
    final workspace = savedWorkspaces
        .where((item) => item.id == workspaceId)
        .firstOrNull;
    final pane = workspace?.panes
        .where((item) => item.paneId == paneId)
        .firstOrNull;
    if (pane == null) return null;
    return workspace!.sessionDescriptors
        .where(
          (descriptor) =>
              descriptor.paneId == paneId && descriptor.hostId == pane.hostId,
        )
        .firstOrNull;
  }

  bool workspacePaneTmuxBusy(String workspaceId, String paneId) =>
      _workspaceTmuxBusyKeys.contains(
        _workspaceTmuxKey(activeVault?.id, workspaceId, paneId),
      );

  bool workspacePaneTmuxAttached(String workspaceId, String paneId) {
    final tab = workspacePaneTerminalTab(workspaceId, paneId);
    return tab != null && _tmuxAttachHandles.containsKey(tab.id);
  }

  bool get hasDefaultSectionPreferenceConflict =>
      _defaultSectionConflictState.repairRequired;
  bool get defaultSectionConflictRepairBusy =>
      _defaultSectionConflictState.repairBusy;
  String? get defaultSectionConflictRetainedRecordId =>
      _defaultSectionConflictState.retainedRecordId;
  bool get hasTerminalFontSizePreferenceConflict =>
      _terminalFontSizeConflictState.repairRequired;
  bool get terminalFontSizeConflictRepairBusy =>
      _terminalFontSizeConflictState.repairBusy;
  String? get terminalFontSizeConflictRetainedRecordId =>
      _terminalFontSizeConflictState.retainedRecordId;
  bool get hasTerminalThemePreferenceConflict =>
      _terminalThemeConflictState.repairRequired;
  bool get terminalThemeConflictRepairBusy =>
      _terminalThemeConflictState.repairBusy;
  String? get terminalThemeConflictRetainedRecordId =>
      _terminalThemeConflictState.retainedRecordId;
  bool get hasTerminalShortcutsPreferenceConflict =>
      _terminalShortcutsConflictState.repairRequired;
  bool get terminalShortcutsConflictRepairBusy =>
      _terminalShortcutsConflictState.repairBusy;
  String? get terminalShortcutsConflictRetainedRecordId =>
      _terminalShortcutsConflictState.retainedRecordId;
  int get terminalFontSize {
    final state = _terminalFontSizeConflictState;
    final matches = preferences
        .where((item) => item.isTerminalFontSize)
        .toList(growable: false);
    if (_preferenceRepairScanFailed ||
        state.repairRequired ||
        matches.length != 1) {
      return VaultPreferenceRecord.defaultTerminalFontSize;
    }
    return matches.single.terminalFontSizeValue;
  }

  VaultTerminalThemeChoice get terminalTheme {
    final state = _terminalThemeConflictState;
    final matches = preferences
        .where((item) => item.isTerminalTheme)
        .toList(growable: false);
    if (_preferenceRepairScanFailed ||
        state.repairRequired ||
        matches.length != 1) {
      return VaultPreferenceRecord.defaultTerminalTheme;
    }
    return matches.single.terminalThemeValue;
  }

  TerminalShortcutBindings get terminalShortcutBindings {
    final state = _terminalShortcutsConflictState;
    final matches = preferences
        .where((item) => item.isTerminalShortcuts)
        .toList(growable: false);
    if (_preferenceRepairScanFailed ||
        state.repairRequired ||
        matches.length != 1) {
      return VaultPreferenceRecord.defaultTerminalShortcuts;
    }
    return matches.single.terminalShortcutBindings;
  }

  bool get databaseRecoveryRequired =>
      databaseQuarantineRegistry.hasQuarantinedDatabase;
  bool _defaultWorkspaceAppliedForVault = false;
  int _recordsLoadGeneration = 0;
  int _vaultSelectionGeneration = 0;
  int _vaultSelectionRequestGeneration = 0;
  int _authContextGeneration = 0;
  int _apiGeneration = 0;
  final VerifiedSignerDirectoryCache _verifiedSignerDirectoryCache =
      VerifiedSignerDirectoryCache();
  int _vaultLoadGeneration = 0;
  bool _vaultLoadsBlocked = false;
  final Set<Future<void>> _vaultLoadCompletions = {};
  final Map<SyncRepository, Future<void>> _retiredRepositoryDrains = {};
  final Map<String, Set<Uint8List>> _pendingVaultKeyBufferWipes = {};
  Future<void> _groupMutationTail = Future<void>.value();
  List<Map<String, dynamic>> devices = [];
  List<Map<String, dynamic>> vaultDeviceRows = [];
  String? vaultDeviceRowsVaultId;
  bool vaultDeviceRowsLoading = false;
  String? vaultDeviceRowsError;
  int _vaultDeviceRowsRequestGeneration = 0;
  List<Map<String, dynamic>> vaultMembers = [];
  List<VaultPresenceDevice> vaultPresenceDevices = [];
  bool vaultPresenceLoading = false;
  String? vaultPresenceError;
  Timer? _vaultPresenceHeartbeatTimer;
  final Map<String, Future<void>> _vaultPresenceRefreshRequests = {};
  int _vaultPresenceRequestGeneration = 0;
  bool vaultMembershipBusy = false;
  bool _vaultMembershipChangeActive = false;
  List<Map<String, dynamic>> openConflicts = [];
  List<ConflictFeedReviewItem> feedConflictItems = [];
  List<ConflictFeedReviewItem> _allFeedConflictItems = [];
  List<AuditEvent> auditPageEvents = [];
  AuditScope auditScope = AuditScope.account;
  String? auditNextCursor;
  bool auditHasMore = false;
  bool auditLoading = false;
  String? auditError;
  int auditPageIndex = 0;
  final List<String?> _auditPageCursors = [null];
  int _auditRequestGeneration = 0;
  InstanceAdminOverview? instanceAdminOverview;
  bool instanceAdminOverviewLoading = false;
  String? instanceAdminOverviewError;
  int _instanceAdminOverviewRequestGeneration = 0;
  InstanceAdminPushHealth? instanceAdminPushHealth;
  bool instanceAdminPushHealthLoading = false;
  String? instanceAdminPushHealthError;
  int _instanceAdminPushHealthRequestGeneration = 0;
  InstanceAdminMetricsCredentialStatus? instanceAdminMetricsCredentialStatus;
  bool instanceAdminMetricsCredentialLoading = false;
  bool instanceAdminMetricsCredentialSaving = false;
  String? instanceAdminMetricsCredentialError;
  String? instanceAdminMetricsCredentialNotice;
  String? _instanceAdminMetricsCredentialOneTimeValue;
  int _instanceAdminMetricsCredentialRequestGeneration = 0;
  InstanceAdminRelayPolicy? instanceAdminRelayPolicy;
  bool instanceAdminRelayPolicyLoading = false;
  bool instanceAdminRelayPolicySaving = false;
  String? instanceAdminRelayPolicyError;
  String? instanceAdminRelayPolicySaveError;
  String? instanceAdminRelayPolicyNotice;
  bool instanceAdminRelayPolicyConflict = false;
  int _instanceAdminRelayPolicyRequestGeneration = 0;
  InstanceAdminBackupStatus? instanceAdminBackupStatus;
  bool instanceAdminBackupStatusLoading = false;
  String? instanceAdminBackupStatusError;
  int _instanceAdminBackupStatusRequestGeneration = 0;
  InstanceAdminBackupReplicationStatus? instanceAdminBackupReplicationStatus;
  bool instanceAdminBackupReplicationLoading = false;
  String? instanceAdminBackupReplicationError;
  int _instanceAdminBackupReplicationRequestGeneration = 0;
  bool instanceAdminBackupBucketAccessCheckLoading = false;
  String? instanceAdminBackupBucketAccessCheckError;
  String? instanceAdminBackupBucketAccessCheckNotice;
  int _instanceAdminBackupBucketAccessCheckRequestGeneration = 0;
  InstanceAdminBackupSchedule? instanceAdminBackupSchedule;
  bool instanceAdminBackupScheduleLoading = false;
  bool instanceAdminBackupScheduleSaving = false;
  String? instanceAdminBackupScheduleError;
  String? instanceAdminBackupScheduleSaveError;
  String? instanceAdminBackupScheduleNotice;
  int _instanceAdminBackupScheduleRequestGeneration = 0;
  static const int adminVaultPageSize = 50;
  AdminVaultPage? adminVaultsPage;
  bool adminVaultsLoading = false;
  String? adminVaultsError;
  bool adminVaultQuotaSaving = false;
  String? adminVaultMutationError;
  String? adminVaultMutationNotice;
  int _adminVaultsRequestGeneration = 0;
  InstanceAdminAuditPage? adminAuditPage;
  bool adminAuditLoading = false;
  String? adminAuditError;
  int adminAuditPageIndex = 0;
  final List<String?> _adminAuditPageCursors = [null];
  int _adminAuditRequestGeneration = 0;
  static const int adminMaintenanceJobsPageSize = 50;
  AdminMaintenanceJobsPage? adminMaintenanceJobsPage;
  bool adminMaintenanceJobsLoading = false;
  bool adminMaintenanceJobSubmitting = false;
  bool adminBackupJobSubmitting = false;
  String? adminMaintenanceJobsError;
  String? adminMaintenanceJobsNotice;
  String? adminBackupJobError;
  String? adminBackupJobNotice;
  String? _adminMaintenanceRetryRequestId;
  String? _adminBackupRetryRequestId;
  int _adminMaintenanceJobsRequestGeneration = 0;
  static const int adminRestoreSourcePageSize = 50;
  InstanceAdminRestoreSourcesPage? adminRestoreSourcesPage;
  bool adminRestoreSourcesLoading = false;
  String? adminRestoreSourcesError;
  AdminMaintenanceJob? adminRestoreJob;
  bool adminRestoreSubmitting = false;
  bool adminRestorePolling = false;
  String? adminRestoreError;
  String? adminRestoreNotice;
  String? adminRestorePollingError;
  String? adminRestoreStageDiscardingJobId;
  String? adminRestoreStageDiscardError;
  String? adminRestoreStageDiscardNotice;
  String? _adminRestoreRetryRequestId;
  String? _adminRestoreRetryArchiveId;
  String? _adminRestoreRetryArchiveSource;
  String? _adminRestoreStageDiscardRetryJobId;
  String? _adminRestoreStageDiscardRetryRequestId;
  int _adminRestoreSourcesRequestGeneration = 0;
  int _adminRestorePollingGeneration = 0;
  int _adminRestorePollAttempts = 0;
  bool _adminRestorePollRequestInFlight = false;
  Timer? _adminRestorePollTimer;
  static const int adminAccountPageSize = 50;
  AdminAccountPage? adminAccountsPage;
  bool adminAccountsLoading = false;
  String? adminAccountsError;
  String? adminAccountActionBusyId;
  String? adminAccountActionError;
  String? adminAccountActionNotice;
  int _adminAccountsRequestGeneration = 0;
  static const int adminAccountInvitationsPageSize = 50;
  AdminAccountInvitationsPage? adminAccountInvitationsPage;
  bool adminAccountInvitationsLoading = false;
  bool adminAccountInvitationSubmitting = false;
  String? adminAccountInvitationsError;
  String? adminAccountInvitationActionError;
  String? adminAccountInvitationNotice;
  String? adminAccountInvitationBusyId;
  String? adminAccountInvitationToken;
  String? adminAccountInvitationTokenUsername;
  DateTime? adminAccountInvitationTokenExpiresAt;
  int _adminAccountInvitationsRequestGeneration = 0;
  String? adminAccountSessionsUserId;
  AdminAccountSessionsPage? adminAccountSessionsPage;
  bool adminAccountSessionsLoading = false;
  String? adminAccountSessionsError;
  String? adminAccountSessionActionBusyId;
  int _adminAccountSessionsRequestGeneration = 0;
  String? adminAccountRelayPolicyUserId;
  InstanceAdminRelayUserPolicy? adminAccountRelayUserPolicy;
  InstanceAdminRelayPolicy? adminAccountRelayInstancePolicy;
  bool adminAccountRelayPolicyLoading = false;
  bool adminAccountRelayPolicySaving = false;
  bool adminAccountRelayPolicyResetting = false;
  bool adminAccountRelayPolicyConflict = false;
  String? adminAccountRelayPolicyError;
  String? adminAccountRelayPolicySaveError;
  String? adminAccountRelayPolicyNotice;
  bool adminAccountRelayPolicyEnabledDraft = false;
  String adminAccountRelayPolicyCidrsDraft = '';
  String adminAccountRelayPolicyPortsDraft = '';
  int _adminAccountRelayPolicyRequestGeneration = 0;
  List<AdminRelayGroupSummary> adminRelayGroups = const [];
  bool adminRelayGroupsLoading = false;
  String? adminRelayGroupsError;
  bool adminRelayGroupSaving = false;
  String? adminRelayGroupActionError;
  String? adminRelayGroupNotice;
  String? adminRelayGroupId;
  AdminRelayGroupDetail? adminRelayGroupDetail;
  InstanceAdminRelayPolicy? adminRelayGroupInstancePolicy;
  bool adminRelayGroupDetailLoading = false;
  bool adminRelayGroupDetailSaving = false;
  bool adminRelayGroupConflict = false;
  String? adminRelayGroupDetailError;
  String? adminRelayGroupDetailSaveError;
  String? adminRelayGroupDetailNotice;
  String adminRelayGroupNameDraft = '';
  List<String> adminRelayGroupMemberIdsDraft = const [];
  String? adminRelayGroupPreviewUserId;
  InstanceAdminRelayUserPolicy? adminRelayGroupMemberEffectivePolicy;
  bool adminRelayGroupMemberEffectivePolicyLoading = false;
  String? adminRelayGroupMemberEffectivePolicyError;
  bool adminRelayGroupPolicyEnabledDraft = false;
  String adminRelayGroupPolicyCidrsDraft = '';
  String adminRelayGroupPolicyPortsDraft = '';
  int _adminRelayGroupsRequestGeneration = 0;
  int _adminRelayGroupDetailRequestGeneration = 0;
  int _adminRelayGroupPreviewRequestGeneration = 0;
  final Map<String, TerminalTabSession> _terminalTabs = {};
  final Map<String, _TerminalShareHostRuntime> _terminalShareHosts = {};
  final Map<String, TerminalShareHostStatus> _terminalShareStatuses = {};
  final Map<String, TerminalObserverTabSession> _terminalShareObservers = {};
  bool _controllerDisposed = false;
  final List<String> _terminalTabOrder = [];
  String? _activeTerminalTabId;
  List<SftpName> _legacySftpEntries = [];
  String _legacySftpPath = '/';
  String? serverUrl;
  String? _authenticatedUsername;
  DateTime? _sessionAccessExpiresAt;
  DateTime? _sessionCredentialsAdoptedAt;
  String? get authenticatedUsername => _authenticatedUsername;
  bool get isInstanceAdmin => account?.policy['instance_admin'] == true;
  bool get canRetryAdminMaintenanceSubmission =>
      _adminMaintenanceRetryRequestId != null;
  bool get canRetryAdminBackupSubmission => _adminBackupRetryRequestId != null;
  String? get currentAccountId => account?.accountId ?? session?.accountId;

  bool isCurrentAdminAccount(String userId) => currentAccountId == userId;

  @visibleForTesting
  set authenticatedUsernameForTesting(String? value) =>
      _authenticatedUsername = value;
  String? errorMessage;
  String? noticeMessage;
  bool busy = false;
  bool vaultLifecycleBusy = false;
  bool accountLifecycleBusy = false;
  bool accountPasswordChangeBusy = false;
  _PendingAccountPasswordChange? _pendingAccountPasswordChange;
  String? accountDeletionPurgeAfter;
  bool archiveBusy = false;
  String? archiveProgress;
  String? archiveFailurePhase;
  Completer<void>? _archiveOperationDrained;
  bool syncing = false;
  bool workspaceLocked = false;
  int lockedInboxReceivedCount = 0;
  bool _lockedReceiveRunning = false;
  bool _lockedReceiveStopping = false;
  int _lockedReceiveStopGeneration = 0;
  bool _lockedUnlockInProgress = false;
  _ActiveSessionRefresh? _activeSessionRefreshForSyncHint;
  Completer<void>? _lockedReceiveCompletion;
  LockedSyncReceiver? _lockedSyncReceiver;
  bool snapshotRecoveryActive = false;
  Future<void>? _snapshotRecoveryFuture;
  Future<void>? _membershipRefreshFuture;
  Completer<void>? _activeSyncCompletion;
  SyncRepository? _activeSyncRepository;
  int? _activeSyncSelectionGeneration;
  bool _syncAgainRequested = false;
  // True while every request coalesced into [_syncAgainRequested] came from
  // an automatic trigger; such a follow-up is dropped once automatic sync is
  // turned off. Only meaningful while [_syncAgainRequested] is set.
  bool _syncAgainAutomaticOnly = false;
  // Set synchronously around an automatic synchronize() call so the pass can
  // tell automatic triggers from explicit callers without changing the public
  // synchronize() signature (subclasses override it).
  bool _nextSyncIsAutomatic = false;
  // Incremented whenever a pass actually produced a server result, so a
  // manual "Sync now" never reports success for a pass that never ran.
  int _syncPassCompletions = 0;
  bool _membershipRefreshActive = false;
  SyncHint? _deferredSyncHintDuringMembershipChange;
  Future<void>? _deferredSyncHintReplayFuture;
  Completer<void>? _vaultInvitationAcceptanceCompletion;
  int _knownHostDecisionGeneration = 0;
  bool _membershipRefreshRetryInProgress = false;
  DateTime? _lastAccountControlPlaneRefreshAt;
  String syncStatus = 'idle';
  int pendingCount = 0;
  int receivedCount = 0;
  int conflictCount = 0;
  int unavailableRecordCount = 0;
  final Map<String, String> _jumpHostRouteIssues = {};
  final Map<String, String> _hostGroupReferenceIssues = {};
  final Set<String> _unavailableGroupRecordIds = {};

  /// Hosts whose decrypted Jump Host chain cannot be followed safely.
  ///
  /// The diagnostic is derived from the current in-memory Vault snapshot. It
  /// never changes the encrypted records, so each device can display and repair
  /// the same malformed route independently.
  Map<String, String> get jumpHostRouteIssues {
    _rebuildJumpHostRouteIssues();
    return Map.unmodifiable(_jumpHostRouteIssues);
  }

  String? jumpHostRouteIssueForHost(String hostId) =>
      jumpHostRouteIssues[hostId];

  int get jumpHostRouteIssueCount => jumpHostRouteIssues.length;

  /// Hosts whose saved Group reference does not resolve in the latest
  /// complete, decrypted Vault projection. This is a diagnostic only: it
  /// never rewrites the encrypted Host record or its sync outbox entry.
  Map<String, String> get hostGroupReferenceIssues =>
      Map.unmodifiable(_hostGroupReferenceIssues);

  String? hostGroupReferenceIssueForHost(String hostId) =>
      _hostGroupReferenceIssues[hostId];

  int get hostGroupReferenceIssueCount => _hostGroupReferenceIssues.length;

  List<HostRecord> get hostsNeedingGroupRepair => List.unmodifiable(
    hosts.where((host) => _hostGroupReferenceIssues.containsKey(host.id)),
  );
  DateTime? lastSuccessfulSyncAt;
  String? syncCheckpointServerGeneration;
  HostRecord? selectedHost;

  /// Host snapshot associated with the active live SSH session.
  /// `selectedHost` is a UI selection and can change without reconnecting.
  HostRecord? get connectedHost => activeTerminalTab?.host;
  set connectedHost(HostRecord? value) {
    final tab = _compatibilityTerminalTab(create: value != null);
    if (tab == null) return;
    tab.host = value;
  }

  /// Backward-compatible alias for the active tab's connection.
  SshConnection? get terminalConnection => activeTerminalTab?.connection;
  set terminalConnection(SshConnection? value) {
    final tab = _compatibilityTerminalTab(create: value != null);
    if (tab == null) return;
    tab.host ??= selectedHost;
    tab.connection = value;
    tab.state = value == null ? 'disconnected' : 'connected';
  }

  List<TerminalTabSession> get terminalTabs => List.unmodifiable(
    _terminalTabOrder
        .map((id) => _terminalTabs[id])
        .whereType<TerminalTabSession>(),
  );
  String? get activeTerminalTabId => _activeTerminalTabId;
  TerminalTabSession? get activeTerminalTab =>
      _activeTerminalTabId == null ? null : _terminalTabs[_activeTerminalTabId];
  TerminalTabSession? terminalTabFor(String? id) =>
      id == null ? null : _terminalTabs[id];

  /// Starts an opt-in Bash shell-integration binding for [tabId]. The returned
  /// command is for the user to inspect and paste into the interactive shell;
  /// it is never sent over SSH by this method. Completed events are stored in
  /// the account/device's encrypted local history when that scope is present.
  String enableShellIntegrationFor(String tabId) {
    final tab = _terminalTabs[tabId];
    if (tab == null || !_isTerminalTabOpen(tab) || tab.connection == null) {
      throw StateError(currentL10n.connectThisTerminalBeforeEnablingShell);
    }
    return tab.enableShellIntegration();
  }

  void disableShellIntegrationFor(String tabId) {
    final tab = _terminalTabs[tabId];
    if (tab == null) return;
    tab.disableShellIntegration();
  }

  bool shellIntegrationActiveFor(String tabId) =>
      _terminalTabs[tabId]?.shellIntegration?.isActive ?? false;

  List<ShellIntegrationCompletedCommand> shellIntegrationHistoryFor(
    String tabId,
  ) {
    final tab = _terminalTabs[tabId];
    if (tab == null) return const <ShellIntegrationCompletedCommand>[];
    final combined = <String, ShellIntegrationCompletedCommand>{};
    for (final command in tab.shellIntegrationHistory) {
      combined[_shellHistoryEventKey(command)] = command;
    }
    final vaultId = tab.shellHistoryVaultId;
    if (vaultId != null && activeVault?.id == vaultId) {
      for (final record in shellHistoryRecords.where(
        (item) => item.hostRecordId == tab.host?.id,
      )) {
        final command = ShellIntegrationCompletedCommand(
          commandId: 0,
          command: record.command,
          exitStatus: record.exitStatus,
          startedAt: DateTime.fromMillisecondsSinceEpoch(
            record.startedAtMs,
            isUtc: true,
          ),
          completedAt: DateTime.fromMillisecondsSinceEpoch(
            record.completedAtMs,
            isUtc: true,
          ),
        );
        combined[_shellHistoryEventKey(command)] = command;
      }
    }
    final ordered = combined.values.toList()
      ..sort((left, right) {
        final time = left.completedAt.compareTo(right.completedAt);
        return time == 0 ? left.command.compareTo(right.command) : time;
      });
    if (ordered.length > _maxShellIntegrationHistoryCommands) {
      return List.unmodifiable(
        ordered.skip(ordered.length - _maxShellIntegrationHistoryCommands),
      );
    }
    return List.unmodifiable(ordered);
  }

  /// Returns bounded, single-line suggestions for one connected terminal.
  /// History is scoped to that tab's Host; only plain, one-line Bash Snippets
  /// are included so selection cannot submit a multi-line script or expand a
  /// Credential parameter.
  List<String> terminalCommandSuggestionsFor(String tabId, String query) {
    final tab = _terminalTabs[tabId];
    if (tab == null ||
        tab.closed ||
        tab.connection == null ||
        tab.host == null) {
      return const <String>[];
    }
    final history = shellIntegrationHistoryFor(tabId)
        .where((command) => _isSafeTerminalSuggestion(command.command))
        .map(
          (command) => ShellHistoryCompletionEntry(
            id: 'history:${command.commandId}:${command.completedAt.toUtc().microsecondsSinceEpoch}',
            command: command.command,
            completedAt: command.completedAt,
          ),
        );
    final snippetPreviews = snippets
        .where(
          (snippet) =>
              snippet.shell == 'bash' &&
              snippet.executionMode == SnippetExecutionMode.script &&
              snippet.parameters.isEmpty &&
              _isSafeTerminalSuggestion(snippet.body),
        )
        .map(
          (snippet) =>
              ShellHistorySnippetPreview(id: snippet.id, command: snippet.body),
        );
    return const ShellHistoryCompletionProvider().suggest(
      history: history,
      snippets: snippetPreviews,
      query: query,
      limit: 10,
    );
  }

  /// Inserts a still-valid suggestion into the active connected terminal.
  /// The input contains no line terminator; the user must explicitly press
  /// Enter to execute it.
  bool insertTerminalCommandSuggestionFor(String tabId, String command) {
    final tab = _terminalTabs[tabId];
    if (tab == null ||
        tab.closed ||
        tab.connection == null ||
        tab.host == null ||
        _activeTerminalTabId != tabId ||
        !_isSafeTerminalSuggestion(command) ||
        !terminalCommandSuggestionsFor(
          tabId,
          command,
        ).contains(command.trim())) {
      return false;
    }
    sendTerminalInputFor(tabId, command.trim());
    return true;
  }

  bool get shellHistorySyncEnabled => _shellHistorySyncEnabled;

  Future<void> loadShellHistorySyncPreference({
    bool Function()? isCurrent,
  }) async {
    if (isCurrent != null && !isCurrent()) return;
    final generation = ++_shellHistorySyncPreferenceGeneration;
    final vaultId = activeVault?.id;
    final currentSession = session;
    final currentIdentity = identity;
    final baseUrl = api?.baseUrl ?? serverUrl;
    if (vaultId == null ||
        currentSession == null ||
        currentIdentity == null ||
        baseUrl == null) {
      _shellHistorySyncEnabled = false;
      _shellHistorySyncEnableInProgress = false;
      return;
    }
    var enabled = false;
    try {
      enabled = await secureStore.terminalHistorySyncEnabled(
        baseUrl: baseUrl,
        accountId: currentSession.accountId,
        deviceId: currentIdentity.deviceId,
        vaultId: vaultId,
      );
    } on Object {
      // A secure-store read failure must fail closed without blocking unlock.
    }
    if (activeVault?.id != vaultId ||
        session?.accountId != currentSession.accountId ||
        identity?.deviceId != currentIdentity.deviceId ||
        (api?.baseUrl ?? serverUrl) != baseUrl ||
        generation != _shellHistorySyncPreferenceGeneration ||
        (isCurrent != null && !isCurrent())) {
      return;
    }
    _shellHistorySyncEnabled = enabled;
    _shellHistorySyncEnableInProgress = false;
    notifyListeners();
  }

  Future<void> setShellHistorySyncEnabled(bool enabled) async {
    ++_shellHistorySyncPreferenceGeneration;
    final vault = activeVault;
    final currentSession = session;
    final currentIdentity = identity;
    final baseUrl = api?.baseUrl ?? serverUrl;
    if (vault == null ||
        currentSession == null ||
        currentIdentity == null ||
        baseUrl == null) {
      throw StateError(currentL10n.chooseAndUnlockAVaultFirst);
    }
    if (enabled &&
        (!vault.canWrite ||
            vault.status != 'active' ||
            _repository?.vaultId != vault.id ||
            _repository?.canWrite != true ||
            _repository?.deletionPending == true)) {
      throw StateError(currentL10n.theCurrentVaultIsReadOnly6);
    }
    if (!enabled) {
      _shellHistorySyncEnabled = false;
      _shellHistorySyncEnableInProgress = false;
      notifyListeners();
      Object? preferenceError;
      StackTrace? preferenceStack;
      try {
        await secureStore.setTerminalHistorySyncEnabled(
          baseUrl: baseUrl,
          accountId: currentSession.accountId,
          deviceId: currentIdentity.deviceId,
          vaultId: vault.id,
          enabled: false,
        );
      } on Object catch (error, stackTrace) {
        preferenceError = error;
        preferenceStack = stackTrace;
      }
      bool sameDeviceScope() =>
          identical(identity, currentIdentity) &&
          session?.accountId == currentSession.accountId &&
          (api?.baseUrl ?? serverUrl) == baseUrl;
      if (sameDeviceScope()) {
        await _shellHistorySyncWriteQueue;
      }
      final vaultKey = _vaultKeys[vault.id];
      if (sameDeviceScope() && vaultKey != null) {
        final currentRepository = _repository;
        final pendingOperations = await database.allPendingOperations(
          vault.id,
          instanceId: currentRepository?.vaultId == vault.id
              ? currentRepository!.instanceId
              : null,
          serverSpaceId: currentRepository?.vaultId == vault.id
              ? currentRepository!.serverSpaceId
              : null,
        );
        for (final operation in pendingOperations) {
          if (!sameDeviceScope() ||
              !identical(_vaultKeys[vault.id], vaultKey)) {
            break;
          }
          if (operation.status != 'queued') continue;
          final dynamic envelope;
          try {
            envelope = jsonDecode(operation.envelopeJson);
          } on Object {
            continue;
          }
          if (envelope is! Map || envelope['header'] is! Map) continue;
          final header = envelope['header'] as Map;
          if (header['device_id'] != currentIdentity.deviceId ||
              header['operation'] != 'create' ||
              header['vault_id'] != vault.id ||
              header['record_id'] != operation.recordId) {
            continue;
          }
          final Map<String, dynamic> plaintext;
          try {
            plaintext = await crypto.decryptRecord(
              vaultKey: vaultKey,
              envelope: Map<String, dynamic>.from(envelope),
              authorPublicKey: currentIdentity.signing.publicKey,
            );
          } on Object catch (_, stackTrace) {
            preferenceError = StateError(
              currentL10n.thePendingVaultRecordsCouldntBe,
            );
            preferenceStack = stackTrace;
            break;
          }
          if (!sameDeviceScope() ||
              !identical(_vaultKeys[vault.id], vaultKey) ||
              plaintext['type'] != 'shellHistory') {
            continue;
          }
          await database.discardQueuedCreateOperationIfUncommitted(
            vaultId: vault.id,
            recordId: operation.recordId,
            instanceId: currentRepository?.vaultId == vault.id
                ? currentRepository!.instanceId
                : null,
            serverSpaceId: currentRepository?.vaultId == vault.id
                ? currentRepository!.serverSpaceId
                : null,
          );
        }
      } else if (sameDeviceScope() && preferenceError == null) {
        preferenceError = StateError(
          currentL10n.thePendingCommandHistoryCouldntBe,
        );
        preferenceStack = StackTrace.current;
      }
      if (preferenceError != null) {
        Error.throwWithStackTrace(preferenceError, preferenceStack!);
      }
      return;
    }

    final repository = _repository;
    if (repository == null || repository.vaultId != vault.id) {
      throw StateError(currentL10n.theCurrentVaultSyncRepositoryIsnt);
    }
    final localHistory = _newShellHistoryRepository();
    if (localHistory == null) {
      throw StateError(currentL10n.thisDevicesEncryptedHistoryRepositoryIsnt);
    }
    _shellHistorySyncEnableInProgress = true;
    try {
      final eligibleHostIds = hosts.map((host) => host.id).toSet();
      final entries = await localHistory.load();
      if (activeVault?.id != vault.id || !identical(_repository, repository)) {
        throw StateError(currentL10n.theVaultWasSwitchedCommandHistory);
      }
      for (final entry in entries) {
        if (!eligibleHostIds.contains(entry.hostId)) continue;
        await _enqueueShellHistoryVaultRecord(
          repository: repository,
          vaultId: vault.id,
          record: ShellHistoryRecord(
            id: entry.entryId,
            hostRecordId: entry.hostId,
            command: entry.command,
            exitStatus: entry.exitStatus,
            startedAtMs: entry.startedAt.toUtc().millisecondsSinceEpoch,
            completedAtMs: entry.completedAt.toUtc().millisecondsSinceEpoch,
            sourceDeviceId: currentIdentity.deviceId,
          ),
        );
      }
      await _shellHistorySyncWriteQueue;
      if (activeVault?.id != vault.id || !identical(_repository, repository)) {
        throw StateError(currentL10n.theVaultWasSwitchedCommandHistory);
      }
      await secureStore.setTerminalHistorySyncEnabled(
        baseUrl: baseUrl,
        accountId: currentSession.accountId,
        deviceId: currentIdentity.deviceId,
        vaultId: vault.id,
        enabled: true,
      );
      _shellHistorySyncEnabled = true;
      _shellHistorySyncEnableInProgress = false;
      await reloadRecords();
      _automaticSync.scheduleEdit();
      notifyListeners();
    } catch (_) {
      if (!_shellHistorySyncEnabled) {
        _shellHistorySyncEnableInProgress = false;
      }
      rethrow;
    } finally {
      localHistory.close();
    }
  }

  Future<void> clearTerminalShellHistoryFor(String tabId) async {
    final tab = _terminalTabs[tabId];
    if (tab == null) return;
    tab.shellHistoryRestorationGeneration++;
    final repository = tab.shellHistoryRepository;
    final hostId = tab.host?.id;
    if (repository != null && hostId != null) {
      await tab.shellHistoryPersistenceQueue;
      await repository.clear(hostId: hostId);
    }
    if (_isTerminalTabOpen(tab)) tab.clearShellIntegrationHistory();
  }

  void _clearShellIntegrationFor(
    TerminalTabSession tab, {
    bool clearHistory = false,
  }) {
    tab.disableShellIntegration(clearHistory: clearHistory);
  }

  List<TerminalObserverTabSession> get terminalShareObservers =>
      List.unmodifiable(_terminalShareObservers.values);

  TerminalObserverTabSession? terminalShareObserverFor(String? sessionId) =>
      sessionId == null ? null : _terminalShareObservers[sessionId];

  TerminalShareHostStatus? terminalShareStatusFor(String? tabId) =>
      tabId == null ? null : _terminalShareStatuses[tabId];

  bool isTerminalShareHost(String? tabId) =>
      tabId != null && _terminalShareHosts.containsKey(tabId);

  List<TerminalShareDeviceChoice> terminalShareApprovedObserversFor(
    String? tabId,
  ) => List.unmodifiable(
    _terminalShareHosts[tabId]?.approvedObservers ??
        const <TerminalShareDeviceChoice>[],
  );

  void _notifyListenersIfAlive() {
    if (!_controllerDisposed) notifyListeners();
  }

  Future<List<TerminalShareDeviceChoice>> terminalShareEligibleDevices() async {
    final vault = activeVault;
    final currentIdentity = identity;
    final currentSession = session;
    if (vault == null || currentIdentity == null || currentSession == null) {
      throw StateError(currentL10n.unlockAVaultBeforeSharingA);
    }
    if (vault.status != 'active') {
      throw StateError(currentL10n.thisVaultCantBeUsedTo);
    }
    final client = _requireApi();
    final directory = await client.vaultDevices(vault.id);
    final members = await client.vaultMembers(vault.id);
    if (activeVault?.id != vault.id ||
        activeVault?.membershipVersion != vault.membershipVersion ||
        !identical(identity, currentIdentity) ||
        session?.accountId != currentSession.accountId) {
      throw StateError(currentL10n.theVaultOrDeviceStateChanged);
    }
    final memberNames = <String, String>{
      for (final member in members)
        if (member['user_id'] is String && member['username'] is String)
          member['user_id'] as String: member['username'] as String,
    };
    final choices = <TerminalShareDeviceChoice>[];
    for (final row in directory) {
      if (row['status'] != 'active' ||
          row['membership_status'] != 'active' ||
          row['device_id'] == currentIdentity.deviceId) {
        continue;
      }
      try {
        final recipient = TerminalShareRecipient.fromVaultDevice(row);
        final deviceName =
            row['name'] is String && (row['name'] as String).trim().isNotEmpty
            ? (row['name'] as String).trim()
            : 'Device ${recipient.deviceId.substring(0, 8)}';
        final userId = recipient.userId;
        choices.add(
          TerminalShareDeviceChoice(
            recipient: recipient,
            deviceName: deviceName,
            memberName:
                memberNames[userId] ?? 'Member ${userId.substring(0, 8)}',
            vaultId: vault.id,
            membershipVersion: vault.membershipVersion,
            hostAccountId: currentSession.accountId,
            hostDeviceId: currentIdentity.deviceId,
            hostIdentity: currentIdentity,
          ),
        );
      } on FormatException {
        // An unusable key or malformed public-directory row is not shareable.
      }
    }
    return List.unmodifiable(choices);
  }

  Future<String> startTerminalShareFor(
    String tabId,
    List<TerminalShareDeviceChoice> selectedDevices, {
    bool allowInputControl = false,
  }) async {
    final tab = _terminalTabs[tabId];
    if (tab == null ||
        tab.closed ||
        tab.connection == null ||
        tab.state != 'connected') {
      throw StateError(currentL10n.connectSshBeforeStartingTerminalSharing);
    }
    if (_terminalShareHosts.containsKey(tabId)) {
      throw StateError(currentL10n.thisTerminalIsAlreadyBeingShared);
    }
    if (selectedDevices.isEmpty || selectedDevices.length > 8) {
      throw StateError(currentL10n.choose1To8ActiveVault);
    }
    final vault = activeVault;
    final currentIdentity = identity;
    final currentSession = session;
    if (vault == null ||
        currentIdentity == null ||
        currentSession == null ||
        vault.status != 'active') {
      throw StateError(currentL10n.theCurrentVaultOrSignedIn);
    }
    final membershipVersion = int.tryParse(vault.membershipVersion);
    if (membershipVersion == null || membershipVersion < 1) {
      throw StateError(currentL10n.invalidVaultMembershipVersionSyncAnd);
    }
    if (selectedDevices.any(
      (choice) =>
          choice.vaultId != vault.id ||
          choice.membershipVersion != vault.membershipVersion ||
          choice.hostAccountId != currentSession.accountId ||
          choice.hostDeviceId != currentIdentity.deviceId ||
          !identical(choice.hostIdentity, currentIdentity),
    )) {
      throw StateError(currentL10n.vaultMembersOrTheSignedIn);
    }
    final sessionId = _uuid.v4();
    final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 15));
    _terminalShareStatuses[tabId] = TerminalShareHostStatus(
      sessionId: sessionId,
      expiresAt: expiresAt,
      observerCount: selectedDevices.length,
      phase: 'starting',
      inputControlEnabled: allowInputControl,
    );
    _notifyListenersIfAlive();
    try {
      final service = TerminalCollaborationService(
        api: _requireApi(),
        crypto: crypto,
        identity: currentIdentity,
        accountId: currentSession.accountId,
        vaultId: vault.id,
        membershipVersion: membershipVersion,
      );
      final handle = await service.startHost(
        sessionId: sessionId,
        expiresAt: expiresAt,
        observers: selectedDevices.map((choice) => choice.recipient).toList(),
        allowInput: allowInputControl,
      );
      if (!_isTerminalTabOpen(tab) ||
          !identical(identity, currentIdentity) ||
          session?.accountId != currentSession.accountId ||
          activeVault?.id != vault.id ||
          activeVault?.membershipVersion != vault.membershipVersion) {
        await handle.close();
        throw StateError(currentL10n.theTerminalVaultOrSignedIn);
      }
      final initialColumns = tab.terminal.viewWidth;
      final initialRows = tab.terminal.viewHeight;
      if (initialColumns > 0 && initialRows > 0) {
        try {
          await handle.publishResize(initialColumns, initialRows);
        } catch (_) {
          await handle.close();
          rethrow;
        }
      }
      if (!_isTerminalTabOpen(tab) ||
          !identical(identity, currentIdentity) ||
          session?.accountId != currentSession.accountId ||
          activeVault?.id != vault.id ||
          activeVault?.membershipVersion != vault.membershipVersion) {
        await handle.close();
        throw StateError(currentL10n.theTerminalVaultOrSignedIn);
      }
      final outputFanoutToken = tab.addOutputFanout(
        (text) => _enqueueTerminalShareOutput(tabId, handle, text),
      );
      final status = TerminalShareHostStatus(
        sessionId: sessionId,
        expiresAt: expiresAt,
        observerCount: selectedDevices.length,
        phase: 'connecting',
        inputControlEnabled: allowInputControl,
      );
      final runtime = _TerminalShareHostRuntime(
        handle: handle,
        tab: tab,
        outputFanoutToken: outputFanoutToken,
        status: status,
        approvedObservers: List.unmodifiable(selectedDevices),
      );
      _terminalShareHosts[tabId] = runtime;
      runtime.eventSubscription = handle.events.listen(
        (event) {
          unawaited(
            _onTerminalShareHostEvent(tabId, runtime, event).catchError((
              Object _,
            ) {
              // A closed SSH/tmux sink must not turn into an unhandled
              // error on the collaboration stream. SSH remains usable.
            }),
          );
        },
        onError: (_) => _finishTerminalShareHost(
          tabId,
          handle,
          errorMessage: currentL10n.theTerminalControlChannelDisconnectedThe,
        ),
      );
      _terminalShareStatuses[tabId] = status;
      unawaited(_watchTerminalShareHost(tabId, handle));
      _notifyListenersIfAlive();
      return sessionId;
    } catch (_) {
      if (_isTerminalTabOpen(tab) &&
          identical(identity, currentIdentity) &&
          activeVault?.id == vault.id &&
          activeVault?.membershipVersion == vault.membershipVersion) {
        _terminalShareStatuses[tabId] = TerminalShareHostStatus(
          sessionId: sessionId,
          expiresAt: expiresAt,
          observerCount: selectedDevices.length,
          phase: 'failed',
          inputControlEnabled: allowInputControl,
          errorMessage: currentL10n.couldntStartTerminalSharingCheckThe,
        );
      } else {
        _terminalShareStatuses.remove(tabId);
      }
      _notifyListenersIfAlive();
      rethrow;
    }
  }

  Future<void> _watchTerminalShareHost(
    String tabId,
    TerminalShareHostSession handle,
  ) async {
    try {
      await handle.connected;
      final current = _terminalShareHosts[tabId];
      if (current == null || !identical(current.handle, handle)) return;
      final status = TerminalShareHostStatus(
        sessionId: current.status.sessionId,
        expiresAt: current.status.expiresAt,
        observerCount: current.status.observerCount,
        phase: 'active',
        inputControlEnabled: current.status.inputControlEnabled,
        controllerDeviceId: current.status.controllerDeviceId,
        controllerLabel: current.status.controllerLabel,
        controllerExpiresAt: current.status.controllerExpiresAt,
        controllerRevoking: current.status.controllerRevoking,
      );
      current.status = status;
      _terminalShareStatuses[tabId] = status;
      _notifyListenersIfAlive();
      await handle.done;
      _finishTerminalShareHost(tabId, handle);
    } catch (_) {
      _finishTerminalShareHost(
        tabId,
        handle,
        errorMessage: currentL10n.terminalSharingDisconnectedTheSshConnection,
      );
    }
  }

  Future<void> _onTerminalShareHostEvent(
    String tabId,
    _TerminalShareHostRuntime runtime,
    TerminalCollaborationHostEvent event,
  ) async {
    if (event.kind == 'input') {
      final bytes = event.bytes;
      if (bytes == null) return;
      try {
        if (!identical(_terminalShareHosts[tabId], runtime) ||
            runtime.stopping) {
          return;
        }
        // The service-owned lease is authoritative during grant commit: it can
        // expose a pending replacement before the HTTP call returns, while the
        // runtime may still hold the previous (expired) lease metadata.
        final lease = runtime.handle.controllerLease ?? runtime.controllerLease;
        if (runtime.controllerRevoking ||
            lease == null ||
            !runtime.status.inputControlEnabled ||
            !runtime.approvedObservers.any(
              (choice) =>
                  choice.recipient.userId == lease.controllerUserId &&
                  choice.recipient.deviceId == lease.controllerDeviceId,
            ) ||
            event.leaseId != lease.leaseId ||
            event.controlEpoch != lease.controlEpoch ||
            event.controllerDeviceId != lease.controllerDeviceId ||
            event.controllerUserId != lease.controllerUserId ||
            !lease.expiresAt.isAfter(DateTime.now().toUtc()) ||
            !_isTerminalTabOpen(runtime.tab) ||
            runtime.tab.connection == null) {
          return;
        }
        if (runtime.controllerLease == null) {
          runtime.controllerLease = lease;
          runtime.controllerChoice = runtime.approvedObservers
              .where(
                (choice) =>
                    choice.recipient.userId == lease.controllerUserId &&
                    choice.recipient.deviceId == lease.controllerDeviceId,
              )
              .firstOrNull;
          _setTerminalShareControllerStatus(tabId, runtime);
        }
        await _sendTerminalInputBytesToTab(runtime.tab, bytes);
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
      return;
    }
    if (!identical(_terminalShareHosts[tabId], runtime) || runtime.stopping) {
      return;
    }
    if (event.kind == 'controller_ended' &&
        event.leaseId ==
            (runtime.controllerLease?.leaseId ??
                runtime.handle.controllerLease?.leaseId)) {
      runtime.controllerLease = null;
      runtime.controllerChoice = null;
      runtime.controllerRevoking = false;
      _setTerminalShareControllerStatus(tabId, runtime);
    }
  }

  Future<void> _sendTerminalInputBytesToTab(
    TerminalTabSession tab,
    Uint8List bytes,
  ) {
    return deliverVerifiedTerminalInputBytesFor(tab.id, bytes);
  }

  /// Routes already-authenticated collaboration bytes into the existing SSH
  /// or tmux input sink for this exact terminal tab.
  Future<void> deliverVerifiedTerminalInputBytesFor(
    String? id,
    Uint8List bytes,
  ) async {
    try {
      final tab = _terminalTabs[id];
      if (tab == null ||
          !_isTerminalTabOpen(tab) ||
          tab.connection == null ||
          bytes.isEmpty) {
        return;
      }
      final tmux = _tmuxAttachHandles[tab.id];
      if (tmux != null) {
        // SshTmuxAttachHandle synchronously takes an owned copy and resolves
        // after the SSH channel flushes it. Keep the authenticated event alive
        // until then; both buffers are cleared by their owners after delivery.
        await tmux.input(bytes);
        return;
      }
      // The existing SSH sink accepts text and performs UTF-8 encoding. Terminal
      // input is UTF-8; malformed byte sequences fail closed before they reach
      // the live SSH connection.
      tab.connection!.input(utf8.decode(bytes, allowMalformed: false));
    } on FormatException {
      // Input which is not valid terminal UTF-8 cannot be represented by the
      // host's established String-based SSH input sink.
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  void _setTerminalShareControllerStatus(
    String tabId,
    _TerminalShareHostRuntime runtime,
  ) {
    final lease = runtime.controllerLease;
    final choice = runtime.controllerChoice;
    final status = TerminalShareHostStatus(
      sessionId: runtime.status.sessionId,
      expiresAt: runtime.status.expiresAt,
      observerCount: runtime.status.observerCount,
      phase: runtime.status.phase,
      inputControlEnabled: runtime.status.inputControlEnabled,
      controllerDeviceId: lease?.controllerDeviceId,
      controllerLabel: choice?.label,
      controllerExpiresAt: lease?.expiresAt,
      controllerRevoking: runtime.controllerRevoking,
      errorMessage: runtime.status.errorMessage,
    );
    runtime.status = status;
    _terminalShareStatuses[tabId] = status;
    _notifyListenersIfAlive();
  }

  Future<TerminalControllerLease> grantTerminalShareControl({
    required String tabId,
    required String deviceId,
  }) async {
    final runtime = _terminalShareHosts[tabId];
    if (runtime == null || !runtime.status.inputControlEnabled) {
      throw StateError(currentL10n.thisSharedSessionDoesntHaveHost);
    }
    if (runtime.controllerRevoking) {
      throw StateError(currentL10n.confirmingTheInputControlRevocationTry);
    }
    final existingLease = runtime.controllerLease;
    if (existingLease != null &&
        existingLease.expiresAt.isAfter(DateTime.now().toUtc())) {
      throw StateError(currentL10n.anInputControlLeaseIsAlready);
    }
    final choice = runtime.approvedObservers
        .where((candidate) => candidate.recipient.deviceId == deviceId)
        .firstOrNull;
    if (choice == null) {
      throw StateError(currentL10n.inputControlCanOnlyBeGranted);
    }
    if (!_isTerminalTabOpen(runtime.tab) || runtime.tab.connection == null) {
      throw StateError(currentL10n.theSshTerminalIsClosedSo);
    }
    final now = DateTime.now().toUtc();
    final requestedExpiry = now.add(const Duration(minutes: 5));
    final expiresAt = requestedExpiry.isBefore(runtime.status.expiresAt)
        ? requestedExpiry
        : runtime.status.expiresAt;
    final lease = await runtime.handle.grantController(
      controller: choice.recipient,
      expiresAt: expiresAt,
    );
    if (!identical(_terminalShareHosts[tabId], runtime) ||
        runtime.stopping ||
        !_isTerminalTabOpen(runtime.tab)) {
      await runtime.handle.revokeController();
      throw StateError(currentL10n.theSharedSessionEndedAndThe);
    }
    runtime.controllerLease = lease;
    runtime.controllerChoice = choice;
    runtime.controllerRevoking = false;
    _setTerminalShareControllerStatus(tabId, runtime);
    return lease;
  }

  Future<void> revokeTerminalShareControl(String tabId) async {
    final runtime = _terminalShareHosts[tabId];
    if (runtime == null || runtime.controllerLease == null) return;
    // Block any already-buffered host events before waiting for the server's
    // room-lock serialized revocation acknowledgement.
    final leaseId = runtime.controllerLease!.leaseId;
    runtime.controllerRevoking = true;
    _setTerminalShareControllerStatus(tabId, runtime);
    try {
      await runtime.handle.revokeController();
      if (identical(_terminalShareHosts[tabId], runtime) &&
          runtime.controllerLease?.leaseId == leaseId) {
        runtime.controllerLease = null;
        runtime.controllerChoice = null;
        runtime.controllerRevoking = false;
        _setTerminalShareControllerStatus(tabId, runtime);
      }
    } catch (_) {
      // Keep local input blocked and the revoke action visible for an explicit
      // retry until the server confirms or emits the lease-ended event.
      _setTerminalShareControllerStatus(tabId, runtime);
      rethrow;
    }
  }

  void _enqueueTerminalShareOutput(
    String tabId,
    TerminalShareHostSession handle,
    String output,
  ) {
    final runtime = _terminalShareHosts[tabId];
    if (runtime == null ||
        !identical(runtime.handle, handle) ||
        runtime.stopping) {
      return;
    }
    final byteCount = _utf8ByteLength(output);
    if (byteCount <= 0 ||
        byteCount >
            _maxTerminalShareQueuedBytes -
                runtime.queuedBytes -
                runtime.pendingOutputBytes) {
      runtime.stopping = true;
      _finishTerminalShareHost(
        tabId,
        handle,
        errorMessage: currentL10n.terminalSharingStoppedBecauseAnObservers,
      );
      unawaited(handle.close().catchError((_) {}));
      return;
    }
    runtime.pendingOutput.write(output);
    runtime.pendingOutputBytes += byteCount;
    runtime.outputFlushTimer ??= Timer(
      _terminalShareOutputBatchWindow,
      () => _flushTerminalShareOutput(tabId, runtime),
    );
  }

  void _flushTerminalShareOutput(
    String tabId,
    _TerminalShareHostRuntime runtime,
  ) {
    runtime.outputFlushTimer?.cancel();
    runtime.outputFlushTimer = null;
    final byteCount = runtime.pendingOutputBytes;
    if (byteCount <= 0) return;
    final output = runtime.pendingOutput.toString();
    runtime.pendingOutput.clear();
    runtime.pendingOutputBytes = 0;
    if (!identical(_terminalShareHosts[tabId], runtime) || runtime.stopping) {
      return;
    }
    _enqueueTerminalSharePublish(
      tabId,
      runtime,
      payloadBytes: byteCount,
      publish: () => runtime.handle.publishOutput(output),
    );
  }

  void _enqueueTerminalShareResize(
    String tabId,
    _TerminalShareHostRuntime runtime,
    int columns,
    int rows,
  ) {
    _flushTerminalShareOutput(tabId, runtime);
    _enqueueTerminalSharePublish(
      tabId,
      runtime,
      payloadBytes: 32,
      publish: () => runtime.handle.publishResize(columns, rows),
    );
  }

  void _enqueueTerminalSharePublish(
    String tabId,
    _TerminalShareHostRuntime runtime, {
    required int payloadBytes,
    required Future<void> Function() publish,
  }) {
    if (payloadBytes <= 0 ||
        payloadBytes > _maxTerminalShareQueuedBytes ||
        runtime.queuedBytes + payloadBytes > _maxTerminalShareQueuedBytes) {
      runtime.stopping = true;
      _finishTerminalShareHost(
        tabId,
        runtime.handle,
        errorMessage: currentL10n.terminalSharingStoppedBecauseAnObservers,
      );
      unawaited(runtime.handle.close().catchError((_) {}));
      return;
    }
    runtime.queuedBytes += payloadBytes;
    runtime.publishQueue = runtime.publishQueue
        .then((_) async {
          if (runtime.stopping ||
              !identical(_terminalShareHosts[tabId], runtime)) {
            return;
          }
          await publish();
        })
        .catchError((Object _) {
          runtime.stopping = true;
          _finishTerminalShareHost(
            tabId,
            runtime.handle,
            errorMessage:
                currentL10n.terminalSharingDisconnectedTheSshConnection2,
          );
          unawaited(runtime.handle.close().catchError((_) {}));
        })
        .whenComplete(() {
          runtime.queuedBytes -= payloadBytes;
        });
  }

  int _utf8ByteLength(String value) {
    var length = 0;
    for (final rune in value.runes) {
      if (rune <= 0x7f) {
        length++;
      } else if (rune <= 0x7ff) {
        length += 2;
      } else if (rune <= 0xffff) {
        length += 3;
      } else {
        length += 4;
      }
    }
    return length;
  }

  void _finishTerminalShareHost(
    String tabId,
    TerminalShareHostSession handle, {
    String? errorMessage,
  }) {
    final current = _terminalShareHosts[tabId];
    if (current == null || !identical(current.handle, handle)) return;
    current.stopping = true;
    current.outputFlushTimer?.cancel();
    current.outputFlushTimer = null;
    current.pendingOutput.clear();
    current.pendingOutputBytes = 0;
    unawaited(current.eventSubscription?.cancel());
    current.controllerLease = null;
    current.controllerChoice = null;
    current.controllerRevoking = false;
    current.tab.removeOutputFanout(current.outputFanoutToken);
    _terminalShareHosts.remove(tabId);
    _terminalShareStatuses[tabId] = TerminalShareHostStatus(
      sessionId: current.status.sessionId,
      expiresAt: current.status.expiresAt,
      observerCount: current.status.observerCount,
      phase: errorMessage == null ? 'ended' : 'failed',
      inputControlEnabled: current.status.inputControlEnabled,
      controllerRevoking: false,
      errorMessage: errorMessage,
    );
    _notifyListenersIfAlive();
  }

  Future<void> stopTerminalShareFor(String tabId) async {
    final runtime = _terminalShareHosts.remove(tabId);
    final status = _terminalShareStatuses[tabId];
    if (runtime != null) {
      runtime.stopping = true;
      runtime.outputFlushTimer?.cancel();
      runtime.outputFlushTimer = null;
      runtime.pendingOutput.clear();
      runtime.pendingOutputBytes = 0;
      await runtime.eventSubscription?.cancel();
      runtime.controllerLease = null;
      runtime.controllerChoice = null;
      runtime.controllerRevoking = false;
      runtime.tab.removeOutputFanout(runtime.outputFanoutToken);
    }
    if (status != null) {
      _terminalShareStatuses[tabId] = TerminalShareHostStatus(
        sessionId: status.sessionId,
        expiresAt: status.expiresAt,
        observerCount: status.observerCount,
        phase: 'stopping',
        inputControlEnabled: status.inputControlEnabled,
        controllerRevoking: false,
      );
      _notifyListenersIfAlive();
    }
    try {
      await runtime?.handle.close();
    } catch (_) {
      // Server-side session expiry and host disconnect are cleanup fallbacks.
    }
    _terminalShareStatuses.remove(tabId);
    _notifyListenersIfAlive();
  }

  Future<TerminalObserverTabSession> joinTerminalShare(String sessionId) async {
    final normalizedId = sessionId.trim().toLowerCase();
    if (!_isCanonicalUuid(normalizedId)) {
      throw FormatException(currentL10n.enterAValidTerminalSharingSession);
    }
    if (_terminalShareObservers.containsKey(normalizedId)) {
      return _terminalShareObservers[normalizedId]!;
    }
    final vault = activeVault;
    final currentIdentity = identity;
    final currentSession = session;
    if (vault == null ||
        currentIdentity == null ||
        currentSession == null ||
        vault.status != 'active') {
      throw StateError(currentL10n.unlockTheVaultThatOwnsThis);
    }
    final handle = await _createTerminalShareObserverHandle(
      sessionId: normalizedId,
      identity: currentIdentity,
      session: currentSession,
      vault: vault,
    );
    if (!_terminalShareObserverContextIsCurrent(
      identity: currentIdentity,
      session: currentSession,
      vault: vault,
    )) {
      await handle.close();
      throw StateError(currentL10n.theVaultOrSignedInDevice);
    }
    final observer = TerminalObserverTabSession(
      id: normalizedId,
      handle: handle,
    );
    _terminalShareObservers[normalizedId] = observer;
    _attachTerminalShareObserver(observer, handle);
    _notifyListenersIfAlive();
    return observer;
  }

  Future<void> reconnectTerminalShare(String sessionId) async {
    final normalizedId = sessionId.trim().toLowerCase();
    final observer = _terminalShareObservers[normalizedId];
    if (!_isCanonicalUuid(normalizedId) ||
        observer == null ||
        observer.closed) {
      throw StateError(currentL10n.youLeftThisTerminalShareEnter);
    }
    if (observer.reconnecting) return;
    if (observer.state != 'ended' && observer.state != 'failed') {
      throw StateError(currentL10n.terminalSharingHasntDisconnectedYet);
    }

    final vault = activeVault;
    final currentIdentity = identity;
    final currentSession = session;
    if (vault == null ||
        currentIdentity == null ||
        currentSession == null ||
        vault.status != 'active') {
      throw StateError(currentL10n.unlockTheVaultThatOwnsThis);
    }

    observer.reconnecting = true;
    observer.state = 'reconnecting';
    observer.errorMessage = null;
    // Invalidate every callback and watcher from the old socket before
    // disposing it. A stale completion must never overwrite the new state.
    observer.connectionGeneration++;
    final oldHandle = observer.handle;
    final oldSubscription = observer.subscription;
    observer.subscription = null;
    observer.terminal.onOutput = null;
    _clearTerminalShareGrant(observer, errorMessage: null);
    // A new Terminal starts with an empty screen and scrollback. This prevents
    // old output from looking current and gives the new observer no replay.
    observer.terminal = Terminal(maxLines: 10000);
    _notifyListenersIfAlive();

    TerminalShareObserverSession? newHandle;
    try {
      await oldSubscription?.cancel();
      await oldHandle.close();
      newHandle = await _createTerminalShareObserverHandle(
        sessionId: normalizedId,
        identity: currentIdentity,
        session: currentSession,
        vault: vault,
      );
      if (!_terminalShareObserverContextIsCurrent(
            identity: currentIdentity,
            session: currentSession,
            vault: vault,
          ) ||
          observer.closed ||
          !identical(_terminalShareObservers[normalizedId], observer)) {
        await newHandle.close();
        throw StateError(currentL10n.theVaultOrSignedInDevice2);
      }
      observer.handle = newHandle;
      observer.reconnecting = false;
      observer.state = 'connecting';
      observer.errorMessage = null;
      _attachTerminalShareObserver(observer, newHandle);
      _notifyListenersIfAlive();
    } catch (_) {
      if (newHandle != null && !identical(observer.handle, newHandle)) {
        await newHandle.close();
      }
      if (!observer.closed &&
          identical(_terminalShareObservers[normalizedId], observer)) {
        observer.reconnecting = false;
        observer.state = 'failed';
        observer.errorMessage = currentL10n.couldntRejoinTheShareMayHave;
        _notifyListenersIfAlive();
      }
      rethrow;
    }
  }

  Future<TerminalShareObserverSession> _createTerminalShareObserverHandle({
    required String sessionId,
    required DeviceIdentity identity,
    required AuthSession session,
    required VaultDescriptor vault,
  }) async {
    final membershipVersion = int.tryParse(vault.membershipVersion);
    if (membershipVersion == null || membershipVersion < 1) {
      throw StateError(currentL10n.invalidVaultMembershipVersionSyncAnd);
    }
    return terminalShareObserverJoinerForTesting != null
        ? terminalShareObserverJoinerForTesting!(sessionId: sessionId)
        : TerminalCollaborationService(
            api: _requireApi(),
            crypto: crypto,
            identity: identity,
            accountId: session.accountId,
            vaultId: vault.id,
            membershipVersion: membershipVersion,
          ).joinObserver(sessionId: sessionId);
  }

  bool _terminalShareObserverContextIsCurrent({
    required DeviceIdentity identity,
    required AuthSession session,
    required VaultDescriptor vault,
  }) =>
      identical(this.identity, identity) &&
      this.session?.accountId == session.accountId &&
      activeVault?.id == vault.id &&
      activeVault?.membershipVersion == vault.membershipVersion &&
      activeVault?.status == 'active';

  void _attachTerminalShareObserver(
    TerminalObserverTabSession observer,
    TerminalShareObserverSession handle,
  ) {
    final generation = ++observer.connectionGeneration;
    bool isCurrent() =>
        !observer.closed &&
        observer.connectionGeneration == generation &&
        identical(observer.handle, handle);

    observer.subscription = handle.events.listen(
      (event) {
        if (!isCurrent()) return;
        if (event.kind == 'controller_granted') {
          if (event.leaseId != null &&
              event.controlEpoch != null &&
              event.expiresAt != null &&
              event.expiresAt!.isAfter(DateTime.now().toUtc())) {
            _setTerminalShareObserverGrant(
              observer,
              leaseId: event.leaseId!,
              controlEpoch: event.controlEpoch!,
              expiresAt: event.expiresAt!,
            );
          }
          return;
        }
        if ((event.kind == 'controller_ended' ||
                event.kind == 'controller_lease_ended') &&
            event.leaseId == observer.grantedLeaseId) {
          _clearTerminalShareGrant(
            observer,
            errorMessage: currentL10n.theHostRevokedOrEndedInput,
          );
          return;
        }
        if (event.kind == 'output' && event.output != null) {
          observer.terminal.write(event.output!);
        } else if (event.kind == 'resize' &&
            event.cols != null &&
            event.rows != null) {
          observer.terminal.resize(event.cols!, event.rows!);
        }
      },
      onError: (_) {
        if (!isCurrent()) return;
        _clearTerminalShareGrant(observer, errorMessage: null);
        observer.state = 'failed';
        observer.errorMessage =
            currentL10n.theTerminalSharingConnectionWasDisconnected;
        _notifyListenersIfAlive();
      },
      onDone: () {
        if (!isCurrent()) return;
        _clearTerminalShareGrant(observer, errorMessage: null);
        observer.state = 'ended';
        _notifyListenersIfAlive();
      },
    );
    // The room can announce an existing grant during the handshake, before
    // this broadcast subscription exists. Seed the validated handle snapshot.
    _seedTerminalShareGrantFromHandle(observer);
    unawaited(
      _watchTerminalShareObserver(
        observer,
        handle: handle,
        generation: generation,
      ),
    );
  }

  /// Seeds UI state from the validated current grant after event subscription.
  /// This also covers grants received during the observer handshake, before
  /// this controller could subscribe to the session's broadcast event stream.
  void _seedTerminalShareGrantFromHandle(TerminalObserverTabSession observer) {
    final initialGrant = observer.handle.controllerGrant;
    if (initialGrant == null) return;
    _setTerminalShareObserverGrant(
      observer,
      leaseId: initialGrant.leaseId,
      controlEpoch: initialGrant.controlEpoch,
      expiresAt: initialGrant.expiresAt,
    );
  }

  void _setTerminalShareObserverGrant(
    TerminalObserverTabSession observer, {
    required String leaseId,
    required int controlEpoch,
    required DateTime expiresAt,
  }) {
    final now = DateTime.now().toUtc();
    if (observer.closed || !expiresAt.isAfter(now)) return;
    observer.grantedLeaseId = leaseId;
    observer.grantedControlEpoch = controlEpoch;
    observer.grantedControlExpiresAt = expiresAt;
    observer.controlErrorMessage = null;
    observer.controlExpiryTimer?.cancel();
    observer.controlExpiryTimer = Timer(
      expiresAt.difference(now),
      () => _expireTerminalShareGrant(observer, leaseId),
    );
    _notifyListenersIfAlive();
  }

  void _expireTerminalShareGrant(
    TerminalObserverTabSession observer,
    String leaseId,
  ) {
    if (observer.closed || observer.grantedLeaseId != leaseId) return;
    _clearTerminalShareGrant(
      observer,
      errorMessage: currentL10n.hostInputControlAuthorizationExpired,
    );
  }

  void _clearTerminalShareGrant(
    TerminalObserverTabSession observer, {
    required String? errorMessage,
  }) {
    observer.controlExpiryTimer?.cancel();
    observer.controlExpiryTimer = null;
    observer.grantedLeaseId = null;
    observer.grantedControlEpoch = null;
    observer.grantedControlExpiresAt = null;
    observer.controlErrorMessage = errorMessage;
    final controller = observer.controller;
    observer.controller = null;
    observer.terminal.onOutput = null;
    if (controller != null) unawaited(controller.close().catchError((_) {}));
    _notifyListenersIfAlive();
  }

  Future<TerminalShareControllerSession> joinTerminalShareController(
    String sessionId,
  ) async {
    final normalizedId = sessionId.trim().toLowerCase();
    final observer = _terminalShareObservers[normalizedId];
    if (observer == null || observer.closed) {
      throw StateError(currentL10n.joinTheHostsTerminalShareFirst);
    }
    final leaseId = observer.grantedLeaseId;
    final controlEpoch = observer.grantedControlEpoch;
    final expiresAt = observer.grantedControlExpiresAt;
    if (leaseId == null ||
        controlEpoch == null ||
        expiresAt == null ||
        !expiresAt.isAfter(DateTime.now().toUtc())) {
      throw StateError(currentL10n.theHostHasntGrantedThisDevice);
    }
    if (observer.controller != null) return observer.controller!;
    if (observer.joiningController) {
      throw StateError(currentL10n.connectingHostApprovedInputControl);
    }
    final vault = activeVault;
    final currentIdentity = identity;
    final currentSession = session;
    if (vault == null ||
        currentIdentity == null ||
        currentSession == null ||
        vault.status != 'active') {
      throw StateError(currentL10n.unlockTheVaultThatOwnsThis);
    }
    final membershipVersion = int.tryParse(vault.membershipVersion);
    if (membershipVersion == null || membershipVersion < 1) {
      throw StateError(currentL10n.invalidVaultMembershipVersionSyncAnd);
    }
    observer.joiningController = true;
    observer.controlErrorMessage = null;
    _notifyListenersIfAlive();
    TerminalShareControllerSession? controller;
    try {
      controller = await observer.handle.joinController();
      if (!identical(identity, currentIdentity) ||
          session?.accountId != currentSession.accountId ||
          activeVault?.id != vault.id ||
          activeVault?.membershipVersion != vault.membershipVersion ||
          observer.closed ||
          observer.grantedLeaseId != leaseId ||
          observer.grantedControlEpoch != controlEpoch ||
          controller.leaseId != leaseId ||
          controller.controlEpoch != controlEpoch ||
          !controller.isConnected ||
          !expiresAt.isAfter(DateTime.now().toUtc())) {
        await controller.close();
        throw StateError(currentL10n.theInputControlAuthorizationOrVault);
      }
      observer.controller = controller;
      observer.grantedControlExpiresAt = controller.expiresAt;
      observer.terminal.onOutput = (text) {
        if (observer.closed ||
            !identical(observer.controller, controller) ||
            !controller!.expiresAt.isAfter(DateTime.now().toUtc()) ||
            !controller.isConnected) {
          return;
        }
        try {
          unawaited(
            controller.sendInputText(text).catchError((_) {
              observer.controlErrorMessage =
                  currentL10n.theInputControlConnectionWasDisconnected;
              _notifyListenersIfAlive();
            }),
          );
        } on Object {
          observer.controlErrorMessage =
              currentL10n.theInputControlConnectionWasDisconnected;
          _notifyListenersIfAlive();
        }
      };
      unawaited(_watchTerminalShareController(observer, controller));
      return controller;
    } catch (_) {
      if (controller != null && !identical(observer.controller, controller)) {
        await controller.close().catchError((_) {});
      }
      _clearTerminalShareGrant(
        observer,
        errorMessage: currentL10n.couldntJoinInputControlMakeSure,
      );
      rethrow;
    } finally {
      observer.joiningController = false;
      _notifyListenersIfAlive();
    }
  }

  Future<void> _watchTerminalShareController(
    TerminalObserverTabSession observer,
    TerminalShareControllerSession controller,
  ) async {
    try {
      await controller.connected;
      if (observer.closed || !identical(observer.controller, controller)) {
        return;
      }
      observer.controlErrorMessage = null;
      _notifyListenersIfAlive();
      await controller.done;
      if (observer.closed || !identical(observer.controller, controller)) {
        return;
      }
      _clearTerminalShareGrant(
        observer,
        errorMessage: currentL10n.hostInputControlEnded,
      );
    } catch (_) {
      if (observer.closed || !identical(observer.controller, controller)) {
        return;
      }
      _clearTerminalShareGrant(
        observer,
        errorMessage: currentL10n.hostInputControlEnded,
      );
    }
  }

  Future<void> _watchTerminalShareObserver(
    TerminalObserverTabSession observer, {
    required TerminalShareObserverSession handle,
    required int generation,
  }) async {
    bool isCurrent() =>
        !observer.closed &&
        observer.connectionGeneration == generation &&
        identical(observer.handle, handle);
    try {
      await handle.connected;
      if (!isCurrent()) return;
      observer.state = 'connected';
      _notifyListenersIfAlive();
      await handle.done;
      if (isCurrent()) {
        _clearTerminalShareGrant(observer, errorMessage: null);
        observer.state = 'ended';
        _notifyListenersIfAlive();
      }
    } catch (_) {
      if (isCurrent()) {
        _clearTerminalShareGrant(observer, errorMessage: null);
        observer.state = 'failed';
        observer.errorMessage = currentL10n.couldntReadThisTerminalShare;
        _notifyListenersIfAlive();
      }
    }
  }

  Future<void> leaveTerminalShare(String sessionId) async {
    final observer = _terminalShareObservers.remove(sessionId);
    if (observer == null) return;
    observer.closed = true;
    observer.state = 'closed';
    observer.controlExpiryTimer?.cancel();
    observer.controlExpiryTimer = null;
    observer.terminal.onOutput = null;
    final controller = observer.controller;
    observer.controller = null;
    try {
      await controller?.close();
    } catch (_) {
      // Controller lease cleanup is enforced by socket close and expiry.
    }
    try {
      await observer.subscription?.cancel();
    } catch (_) {
      // The stream may already have ended.
    }
    try {
      await observer.handle.close();
    } catch (_) {
      // No observer application messages are sent by the client.
    }
    _notifyListenersIfAlive();
  }

  Future<void> _stopAllTerminalCollaboration() async {
    for (final tabId in _terminalShareHosts.keys.toList(growable: false)) {
      await stopTerminalShareFor(tabId);
    }
    for (final tabId in _terminalShareStatuses.keys.toList(growable: false)) {
      _terminalShareStatuses.remove(tabId);
    }
    for (final sessionId in _terminalShareObservers.keys.toList(
      growable: false,
    )) {
      await leaveTerminalShare(sessionId);
    }
  }

  List<SftpName> get sftpEntries =>
      activeTerminalTab?.sftpEntries ?? _legacySftpEntries;
  set sftpEntries(List<SftpName> value) {
    final tab = activeTerminalTab;
    if (tab == null) {
      _legacySftpEntries = value;
    } else {
      tab.sftpEntries = value;
    }
  }

  String get sftpPath => activeTerminalTab?.sftpPath ?? _legacySftpPath;
  set sftpPath(String value) {
    final tab = activeTerminalTab;
    if (tab == null) {
      _legacySftpPath = value;
    } else {
      tab.sftpPath = value;
    }
  }

  Future<bool> Function(String endpoint, String fingerprint)? askTrustHost;
  Future<bool> Function(KnownHostApprovalRequest request)? askTrustHostApproval;
  Future<List<String>?> Function(
    HostRecord host,
    SSHUserInfoRequest request,
    Future<void> cancelled,
  )?
  askSshUserInfo;
  late final AutoSyncCoordinator _automaticSync;
  late final SyncHintClient _syncHints;
  final SessionRefreshLock _sessionRefreshLock;
  late final SessionUpdateNotifier _sessionUpdateNotifier =
      sessionUpdateNotifierForTesting ?? createSessionUpdateNotifier();
  late final SessionCredentialsObserver _sessionCredentialsObserver =
      SessionCredentialsObserver(
        updates: _sessionUpdateNotifier.updates,
        readLatest: _readSharedSessionCredentials,
        currentScope: _currentSessionScope,
        currentCredentials: () {
          final current = session;
          return current == null ? null : _sessionCredentialsFor(current);
        },
        apply: _applySharedSessionCredentials,
        onExpiredSnapshot: () => unawaited(_refreshSessionForSyncHint()),
        onSessionRemoved: (expectedCredentials) => _handleRemoteSessionEnd(
          removed: true,
          expectedCredentials: expectedCredentials,
        ),
        onRefreshUnrecoverable: (expectedCredentials) =>
            _handleRemoteSessionEnd(
              removed: false,
              expectedCredentials: expectedCredentials,
            ),
      );

  // An authenticated account can temporarily have no accessible Vault (for
  // example after membership revocation or while an owner has not created a
  // replacement). Keep the account workspace available for device management
  // and Vault creation; Vault-scoped operations still require a repository.
  bool get authenticated => session != null && stage == ClientStage.workspace;
  bool get mobilePushSupported => _mobilePushRegistration.supported;
  bool get mobilePushConfigured => _mobilePushRegistration.configured;
  bool get accountPasswordChangePending =>
      _pendingAccountPasswordChange != null;
  List<VaultDescriptor> get vaults => _vaultDescriptors;
  @visibleForTesting
  SyncRepository? get repositoryForTesting => _repository;
  @visibleForTesting
  void invalidateKnownHostDecisionProofsForTesting() {
    _knownHostDecisionGeneration++;
  }

  List<VaultDescriptor> _vaultDescriptors = [];
  String get currentVaultId => activeVault?.id ?? '';
  int get vaultSelectionGeneration => _vaultSelectionGeneration;
  String get currentVaultName =>
      _knownNames[currentVaultId] ?? currentL10n.personalVault;
  String vaultNameFor(String vaultId) =>
      _knownNames[vaultId] ??
      currentL10n.vaultSubstring(vaultId.substring(0, 8));
  List<ConflictFeedReviewItem> get openFeedConflictItems => feedConflictItems
      .where(
        (item) =>
            !item.isTerminal &&
            !openConflicts.any(
              (conflict) =>
                  conflict['conflict_id'] == item.conflictId &&
                  conflict['record_id'] == item.recordId,
            ),
      )
      .toList(growable: false);
  ConflictFeedReviewItem? feedConflictItemForLocalConflict(
    String conflictId,
    String recordId,
  ) {
    for (final item in _allFeedConflictItems) {
      if (item.conflictId == conflictId && item.recordId == recordId) {
        return item;
      }
    }
    for (final item in feedConflictItems) {
      if (item.conflictId == conflictId && item.recordId == recordId) {
        return item;
      }
    }
    return null;
  }

  List<ConflictFeedReviewItem> get resolvedFeedConflictItems =>
      feedConflictItems
          .where((item) => item.isTerminal)
          .toList(growable: false);
  int get unresolvedConflictCount {
    final feedRecordsByConflictId = {
      for (final item in openFeedConflictItems) item.conflictId: item.recordId,
    };
    final unresolvedIdentities = <(String, String)>{};
    for (final conflict in openConflicts) {
      final conflictId = conflict['conflict_id'] as String;
      final recordId = conflict['record_id'];
      unresolvedIdentities.add((
        conflictId,
        recordId is String
            ? recordId
            : feedRecordsByConflictId[conflictId] ?? '',
      ));
    }
    unresolvedIdentities.addAll(
      openFeedConflictItems.map((item) => (item.conflictId, item.recordId)),
    );
    return unresolvedIdentities.length;
  }

  bool get auditHasPrevious => auditPageIndex > 0;
  bool get canReadActiveVaultAudit =>
      activeVault != null &&
      const {'owner', 'editor'}.contains(activeVault!.role);
  List<AuditEvent> get visibleAuditEvents => auditPageEvents
      .where(
        (event) => switch (auditScope) {
          AuditScope.account => event.scope == 'account',
          AuditScope.activeVault =>
            canReadActiveVaultAudit &&
                event.scope == 'vault' &&
                event.vaultId == activeVault?.id,
        },
      )
      .toList(growable: false);

  bool restoringStoredSession = false;

  Future<void> restoreLastServer() async {
    if (restoringStoredSession) return;
    restoringStoredSession = true;
    notifyListeners();
    try {
      serverUrl = await secureStore.lastServer();
      if (serverUrl != null) {
        await configureServer(serverUrl!, showBusy: false);
        await _restoreStoredSessionLocked();
      } else {
        notifyListeners();
      }
    } on Object {
      if (pendingInstanceIdentityRecovery != null) {
        errorMessage = _instanceIdentityRecoveryMessage;
        notifyListeners();
        return;
      }
      // Keep implementation or platform details out of user-visible startup
      // errors. A storage failure should leave the server onboarding screen
      // available so the user can retry after adjusting browser settings.
      errorMessage = currentL10n.couldntReadLocalSecuritySettingsCheck;
      notifyListeners();
    } finally {
      restoringStoredSession = false;
      if (!_controllerDisposed) notifyListeners();
    }
  }

  Future<void> _restoreStoredSessionLocked() async {
    final client = api;
    if (_controllerDisposed ||
        client == null ||
        stage != ClientStage.login ||
        pendingInstanceIdentityRecovery != null ||
        session != null) {
      return;
    }
    final apiGeneration = _apiGeneration;
    final authGeneration = _authContextGeneration;
    bool isCurrent() =>
        !_controllerDisposed &&
        identical(api, client) &&
        _apiGeneration == apiGeneration &&
        _authContextGeneration == authGeneration &&
        stage == ClientStage.login &&
        session == null;
    final hint = await secureStore.sessionResumeHint(client.baseUrl);
    if (hint == null || !isCurrent()) return;
    final scope = SessionScope(
      serverNamespace: secureStorageNamespace(client.baseUrl),
      accountId: hint.accountId,
      deviceId: hint.deviceId,
    );
    Future<SessionSnapshotRead> read() async {
      if (!isCurrent()) throw const SessionRecoveryRequiredException();
      return secureStore.readSessionSnapshot(
        client.baseUrl,
        hint.username,
        hint.deviceId,
      );
    }

    final coordinator = SessionRefreshCoordinator(
      lock: _sessionRefreshLock,
      scope: scope,
      readLatest: read,
      markRotationPending: () => secureStore.markSessionRotationPending(
        client.baseUrl,
        hint.username,
        scope,
      ),
      writeLatest: (value) => secureStore.saveSessionCredentials(
        client.baseUrl,
        hint.username,
        value,
      ),
      refresh: (token) async {
        if (!isCurrent()) throw const SessionRecoveryRequiredException();
        final refreshed = _sessionCredentialsFor(await client.refresh(token));
        if (!scope.matches(refreshed))
          throw const SessionRecoveryRequiredException();
        return refreshed;
      },
      signalOtherTabs: (kind) => _sessionUpdateNotifier.signal(
        SessionUpdateEvent(scope: scope, kind: kind),
      ),
    );
    AccountProfile? verifiedProfile;
    try {
      final credentials = await resumeStoredSession(
        hint: hint,
        coordinator: coordinator,
        readSnapshot: read,
        verify: (credentials) async {
          if (!isCurrent()) throw const SessionRecoveryRequiredException();
          client.accessToken = credentials.accessToken;
          final profile = await client.accountProfile();
          if (!isCurrent() ||
              profile.accountId != hint.accountId ||
              profile.deviceId != hint.deviceId) {
            throw const SessionRecoveryRequiredException();
          }
          verifiedProfile = profile;
        },
      );
      if (!isCurrent()) return;
      // A logout in another window can remove the snapshot during the HTTP
      // account check. Re-read it under the same credential lock before publish.
      await _sessionRefreshLock.run(() async {
        final latest = await read();
        if (!isCurrent() ||
            latest.status != SessionSnapshotStatus.ready ||
            latest.credentials?.accessToken != credentials.accessToken ||
            latest.credentials?.refreshToken != credentials.refreshToken) {
          throw const SessionRecoveryRequiredException();
        }
        _authenticatedUsername = hint.username.trim().toLowerCase();
        session = AuthSession(
          accountId: credentials.accountId,
          deviceId: credentials.deviceId,
          accessToken: credentials.accessToken,
          refreshToken: credentials.refreshToken,
          expiresIn: credentials.accessExpiresAt
              .difference(DateTime.now().toUtc())
              .inSeconds
              .clamp(0, 86400),
          vaults: const [],
        );
        _sessionAccessExpiresAt = credentials.accessExpiresAt;
        _sessionCredentialsAdoptedAt = null;
        client.accessToken = credentials.accessToken;
        workspaceLocked = true;
        _vaultLoadsBlocked = true;
        stage = ClientStage.workspace;
        errorMessage = null;
        noticeMessage = currentL10n.theSignInSessionWasRestored;
        notifyListeners();
      });
      if (verifiedProfile != null) {
        await _restoreRememberedWorkspace(
          client,
          verifiedProfile!,
          authGeneration,
        );
      }
    } catch (_) {
      if (isCurrent()) {
        client.accessToken = null;
        noticeMessage = currentL10n.couldntSafelyRestoreTheSignIn;
        notifyListeners();
      } else {
        _restoreCurrentApiAccessToken(client);
      }
    }
  }

  Future<Map<String, Object>?> _rememberedKeyBinding(
    AccountProfile profile,
  ) async {
    final info = instance;
    if (info == null || profile.accountId.isEmpty || profile.deviceId.isEmpty) {
      return null;
    }
    final digest = await cryptography.Sha256().hash(
      utf8.encode(canonicalJson(profile.accountKeyEnvelope)),
    );
    return {
      'instance_id': info.instanceId,
      'server_space_id': info.serverSpaceId,
      'account_id': profile.accountId,
      'device_id': profile.deviceId,
      'envelope_version': profile.accountKeyEnvelopeVersion,
      'envelope_sha256': base64Encode(digest.bytes),
    };
  }

  Future<void> _rememberAccountKey() async {
    final client = api;
    final profile = account;
    final key = _accountKey;
    final auth = session;
    if (client == null ||
        profile == null ||
        key == null ||
        auth == null ||
        profile.accountId != auth.accountId ||
        profile.deviceId != auth.deviceId ||
        identity?.deviceId != auth.deviceId ||
        workspaceLocked) {
      return;
    }
    final generation = _authContextGeneration;
    final binding = await _rememberedKeyBinding(profile);
    if (binding == null) return;
    try {
      await _sessionRefreshLock.run(() async {
        if (_controllerDisposed ||
            !identical(api, client) ||
            !identical(session, auth) ||
            _authContextGeneration != generation ||
            workspaceLocked ||
            !identical(_accountKey, key)) {
          return;
        }
        final latest = await secureStore.readSessionCredentials(
          client.baseUrl,
          _authenticatedUsername ?? '',
          auth.deviceId,
        );
        if (latest?.refreshToken != auth.refreshToken) return;
        await secureStore.saveRememberedAccountKey(
          client.baseUrl,
          binding: binding,
          accountKey: key,
        );
      });
    } catch (_) {
      // OS keychain availability must not prevent a successful manual unlock.
    }
  }

  Future<void> _restoreRememberedWorkspace(
    ApiClient client,
    AccountProfile profile,
    int generation,
  ) async {
    final auth = session;
    if (auth == null) return;
    bool current() =>
        !_controllerDisposed &&
        identical(api, client) &&
        identical(session, auth) &&
        _authContextGeneration == generation &&
        workspaceLocked;
    var installedKey = false;
    var completed = false;
    DeviceIdentity? installedIdentity;
    Uint8List? key;
    DeviceIdentity? device;
    try {
      final binding = await _rememberedKeyBinding(profile);
      if (binding == null || !current()) return;
      key = await secureStore.rememberedAccountKey(
        client.baseUrl,
        binding: binding,
      );
      if (key == null || !current()) return;
      device = await secureStore.loadDevice(client.baseUrl, crypto);
      if (device == null || device.deviceId != auth.deviceId || !current()) {
        return;
      }
      // Recheck after keychain I/O under the same lock as logout and rotation.
      await _sessionRefreshLock.run(() async {
        final latest = await secureStore.readSessionCredentials(
          client.baseUrl,
          _authenticatedUsername ?? '',
          auth.deviceId,
        );
        if (!current() ||
            latest?.refreshToken != auth.refreshToken ||
            latest?.accessToken != auth.accessToken) {
          throw const SessionRecoveryRequiredException();
        }
        account = profile;
        identity?.dispose();
        identity = device;
        installedIdentity = device;
        device = null;
        _replaceAccountKey(key!);
        installedKey = true;
        key = null;
      });
      if (!current()) return;
      _vaultLoadsBlocked = false;
      await _loadVaults(auth);
      if (!current()) return;
      accountRecoveryStatus = profile.recoveryStatus;
      await _finishUnlockedWorkspace();
      completed = true;
      noticeMessage = null;
    } catch (_) {
      // A missing or stale native record leaves manual unlock available.
    } finally {
      if (installedKey &&
          !completed &&
          !_controllerDisposed &&
          identical(api, client) &&
          identical(identity, installedIdentity) &&
          _authContextGeneration == generation) {
        // Drain a partially hydrated repository before retiring its keys, but
        // never revoke credentials that another window may have just rotated.
        workspaceLocked = false;
        await _lockWorkspace(forgetRememberedKey: false);
      }
      key?.fillRange(0, key!.length, 0);
      device?.dispose();
    }
  }

  Future<void> _rememberAuthenticatedSession(
    String username,
    AuthSession auth,
    ApiClient client,
  ) async {
    bool isCurrent() =>
        !_controllerDisposed &&
        identical(api, client) &&
        session?.accountId == auth.accountId &&
        session?.deviceId == auth.deviceId;
    if (!isCurrent()) return;
    try {
      await _sessionRefreshLock.run(() async {
        if (!isCurrent()) return;
        await secureStore.saveSessionResumeHint(
          client.baseUrl,
          SessionResumeHint(
            username: username,
            accountId: auth.accountId,
            deviceId: auth.deviceId,
          ),
        );
      });
    } catch (_) {
      if (isCurrent()) noticeMessage = currentL10n.thisSignInCanContinueBut;
    }
    if (isCurrent()) await _rememberAccountKey();
  }

  Future<void> configureServer(String value, {bool showBusy = true}) async {
    if (_confirmingInstanceIdentityRecovery) {
      throw StateError(currentL10n.serverIdentityConfirmationIsInProgress3);
    }
    final normalized = value.trim().replaceFirst(RegExp(r'/+$'), '');
    if (normalized.isEmpty) {
      throw FormatException(currentL10n.enterTheServerAddress);
    }
    _discardPendingInstanceIdentityRecovery();
    _setBusy(showBusy);
    ApiClient? candidate;
    try {
      _syncHints.stop();
      candidate =
          apiClientFactoryForTesting?.call(normalized) ??
          ApiClient(baseUrl: normalized);
      final candidateInfo = await candidate.fetchInstance();
      final previousPin = await _verifyInstanceIdentity(
        candidate.baseUrl,
        candidateInfo,
      );
      if (previousPin != null) {
        await _retainPendingInstanceIdentityRecovery(
          baseUrl: candidate.baseUrl,
          api: candidate,
          info: candidateInfo,
          pin: previousPin,
        );
        candidate = null;
        errorMessage = _instanceIdentityRecoveryMessage;
        notifyListeners();
        throw const InstanceIdentityRecoveryRequiredException();
      }
      final activatingCandidate = candidate;
      candidate = null;
      await _activateConfiguredServer(activatingCandidate, candidateInfo);
    } catch (error) {
      // Before activation starts, this method still owns the temporary client.
      // After that point _activateConfiguredServer owns its lifecycle.
      if (candidate != null && !identical(api, candidate)) candidate.close();
      errorMessage = error is InstanceIdentityRecoveryRequiredException
          ? _instanceIdentityRecoveryMessage
          : friendlyError(error);
      rethrow;
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _activateConfiguredServer(
    ApiClient candidate,
    InstanceInfo candidateInfo,
  ) async {
    final previousApi = api;
    final previousBase = previousApi?.baseUrl;
    final previousSession = session;
    final previousUsername = _authenticatedUsername;
    final generation = ++_apiGeneration;
    var clearStarted = false;
    var clearFinished = false;
    var candidatePublished = false;

    // An ApiClient instance owns its authenticated transport state and may be
    // captured by an in-flight Vault load or repository. Fence those users
    // before awaiting anything, including when the replacement has the same
    // base URL.
    _vaultLoadsBlocked = true;
    ++_vaultLoadGeneration;
    bool activationIsCurrent() =>
        !_controllerDisposed && generation == _apiGeneration;

    try {
      await cancelPreparedAccountRecovery(
        force: true,
        clearStoredPending: false,
      );
      await _waitForVaultLoadCompletions();
      if (!activationIsCurrent() || !identical(api, previousApi)) {
        throw StateError(currentL10n.serverActivationWasSuperseded);
      }

      clearStarted = true;
      final cleared = await _clearLocalAuthenticatedState(
        expectedSession: previousSession,
        expectedApi: previousApi,
        expectedBase: previousBase,
        expectedUsername: previousUsername,
        expectedNoSession: previousSession == null,
        removeMobilePushEndpoint: false,
      );
      clearFinished = true;
      if (!cleared || !activationIsCurrent() || !identical(api, previousApi)) {
        throw StateError(currentL10n.serverActivationWasSuperseded);
      }

      // _clearLocalAuthenticatedState releases its own load fence. Keep loads
      // fenced until the candidate is installed so there is no interval where
      // an old session can start a new request against the old API.
      _vaultLoadsBlocked = true;
      await secureStore.saveLastServer(candidate.baseUrl);
      if (!activationIsCurrent() || !identical(api, previousApi)) {
        throw StateError(currentL10n.serverActivationWasSuperseded);
      }

      if (!identical(previousApi, candidate)) previousApi?.close();
      api = candidate;
      candidatePublished = true;
      instance = candidateInfo;
      _resetAuditState();
      serverUrl = candidate.baseUrl;
      stage = candidateInfo.setupRequired
          ? ClientStage.register
          : ClientStage.login;
      errorMessage = null;
      noticeMessage = candidateInfo.setupRequired
          ? currentL10n.thisInstanceIsntInitializedYetCreate
          : null;
      _vaultLoadsBlocked = false;
      if (!candidateInfo.setupRequired) {
        await restorePendingFullAccountRecovery();
      }
      if (!activationIsCurrent() || !identical(api, candidate)) {
        throw StateError(currentL10n.serverActivationWasSuperseded);
      }
      notifyListeners();
    } catch (_) {
      // If cleanup failed before it began, the old authenticated context is
      // still intact and may resume. Once cleanup began, fail closed instead
      // of permitting a partially retired repository or key map to be used.
      if (activationIsCurrent() &&
          !candidatePublished &&
          (!clearStarted || clearFinished)) {
        _vaultLoadsBlocked = false;
      }
      if (candidatePublished && identical(api, candidate)) {
        if (activationIsCurrent()) {
          // The old authenticated scope was already completely cleared before
          // publication. If post-publication recovery restoration fails, drop
          // this candidate instead of leaving a closed client installed.
          _vaultLoadsBlocked = true;
          ++_apiGeneration;
          ++_vaultLoadGeneration;
          await cancelPreparedAccountRecovery(
            force: true,
            clearStoredPending: false,
          );
          api = null;
          instance = null;
          serverUrl = null;
          stage = ClientStage.server;
          _vaultLoadsBlocked = false;
          candidate.close();
        }
      } else if (!candidatePublished &&
          !identical(api, candidate) &&
          !identical(previousApi, candidate)) {
        // Activation owns an unpublished candidate even if a newer request
        // superseded this one while it waited for outstanding work.
        candidate.close();
      }
      rethrow;
    }
  }

  Future<ServerIdentityPin?> _verifyInstanceIdentity(
    String baseUrl,
    InstanceInfo info,
  ) async {
    final key = info.signingPublicKey;
    if (key.isEmpty ||
        !_isCanonicalUuid(info.instanceId) ||
        !_isCanonicalUuid(info.serverSpaceId) ||
        !crypto.verifyInstanceKeyTransitions(
          instanceId: info.instanceId,
          pinnedPublicKey: key,
          currentPublicKey: key,
          transitions: const [],
        )) {
      throw FormatException(currentL10n.theServerDidntProvideAValid);
    }
    final pin = await secureStore.readServerIdentityPin(baseUrl);
    if (pin == null) {
      // Trust on first use is scoped to this normalized server URL. Later key
      // changes require a complete transition chain signed by the pinned key.
      await secureStore.saveServerIdentityPin(
        baseUrl,
        ServerIdentityPin(
          instanceId: info.instanceId,
          serverSpaceId: info.serverSpaceId,
          signingPublicKey: key,
        ),
      );
      return null;
    }
    if (pin.instanceId != info.instanceId ||
        pin.serverSpaceId != info.serverSpaceId) {
      throw FormatException(currentL10n.theServerInstanceIdentityChangedTo);
    }
    if (!crypto.verifyInstanceKeyTransitions(
      instanceId: info.instanceId,
      pinnedPublicKey: pin.signingPublicKey,
      currentPublicKey: key,
      transitions: info.signingKeyTransitions,
    )) {
      return pin;
    }
    if (pin.signingPublicKey != key) {
      await secureStore.saveServerIdentityPin(
        baseUrl,
        ServerIdentityPin(
          instanceId: info.instanceId,
          serverSpaceId: info.serverSpaceId,
          signingPublicKey: key,
        ),
      );
    }
    return null;
  }

  Future<void> _retainPendingInstanceIdentityRecovery({
    required String baseUrl,
    required ApiClient api,
    required InstanceInfo info,
    required ServerIdentityPin pin,
  }) async {
    final pinnedFingerprint = await publicKeyFingerprint(pin.signingPublicKey);
    final candidateFingerprint = await publicKeyFingerprint(
      info.signingPublicKey,
    );
    _discardPendingInstanceIdentityRecovery();
    _pendingInstanceIdentityRecoveryApi = api;
    pendingInstanceIdentityRecovery = PendingInstanceIdentityRecovery(
      baseUrl: baseUrl,
      pinnedIdentity: pin,
      candidate: info,
      pinnedFingerprint: pinnedFingerprint,
      candidateFingerprint: candidateFingerprint,
    );
  }

  void _discardPendingInstanceIdentityRecovery() {
    _pendingInstanceIdentityRecoveryApi?.close();
    _pendingInstanceIdentityRecoveryApi = null;
    pendingInstanceIdentityRecovery = null;
  }

  Future<void> cancelPendingInstanceIdentityRecovery() async {
    if (_confirmingInstanceIdentityRecovery) {
      throw StateError(currentL10n.serverIdentityConfirmationIsInProgress2);
    }
    _discardPendingInstanceIdentityRecovery();
    if (errorMessage == _instanceIdentityRecoveryMessage) errorMessage = null;
    notifyListeners();
  }

  Future<void> confirmPendingInstanceIdentityRecovery({
    required String candidateFingerprint,
  }) async {
    if (_confirmingInstanceIdentityRecovery) {
      throw StateError(currentL10n.serverIdentityConfirmationIsInProgress);
    }
    final pending = pendingInstanceIdentityRecovery;
    final candidateApi = _pendingInstanceIdentityRecoveryApi;
    if (pending == null || candidateApi == null) {
      throw StateError(currentL10n.theresNoServerIdentityRecoveryWaiting);
    }
    if (candidateFingerprint != pending.candidateFingerprint) {
      throw FormatException(currentL10n.theFingerprintYouEnteredDoesntMatch);
    }
    if (pending.pinnedIdentity.instanceId != pending.candidate.instanceId ||
        pending.pinnedIdentity.serverSpaceId !=
            pending.candidate.serverSpaceId) {
      throw FormatException(currentL10n.theServerInstanceIdChangedAnd);
    }
    _confirmingInstanceIdentityRecovery = true;
    _setBusy(true);
    try {
      // Refetch the public identity immediately before changing the pin. This
      // remains unauthenticated and prevents a stale review card from pinning a
      // different key that appeared while the user compared fingerprints.
      final liveCandidate = await candidateApi.fetchInstance();
      if (pendingInstanceIdentityRecovery != pending ||
          _pendingInstanceIdentityRecoveryApi != candidateApi) {
        throw StateError(currentL10n.theServerIdentityAwaitingConfirmationWas);
      }
      if (liveCandidate.instanceId != pending.candidate.instanceId ||
          liveCandidate.serverSpaceId != pending.candidate.serverSpaceId ||
          liveCandidate.signingPublicKey !=
              pending.candidate.signingPublicKey ||
          !crypto.verifyInstanceKeyTransitions(
            instanceId: liveCandidate.instanceId,
            pinnedPublicKey: liveCandidate.signingPublicKey,
            currentPublicKey: liveCandidate.signingPublicKey,
            transitions: const [],
          )) {
        throw StateError(
          currentL10n.theServerIdentityChangedDuringConfirmation,
        );
      }

      final storedPin = await secureStore.readServerIdentityPin(
        pending.baseUrl,
      );
      if (storedPin == null ||
          storedPin.instanceId != pending.pinnedIdentity.instanceId ||
          storedPin.serverSpaceId != pending.pinnedIdentity.serverSpaceId ||
          storedPin.signingPublicKey !=
              pending.pinnedIdentity.signingPublicKey) {
        throw StateError(currentL10n.thePinnedServerIdentityChangedDuring);
      }

      await secureStore.saveServerIdentityPin(
        pending.baseUrl,
        ServerIdentityPin(
          instanceId: liveCandidate.instanceId,
          serverSpaceId: liveCandidate.serverSpaceId,
          signingPublicKey: liveCandidate.signingPublicKey,
        ),
      );
      pendingInstanceIdentityRecovery = null;
      _pendingInstanceIdentityRecoveryApi = null;
      await _activateConfiguredServer(candidateApi, liveCandidate);
    } finally {
      _confirmingInstanceIdentityRecovery = false;
      if (_controllerDisposed) {
        busy = false;
      } else {
        _setBusy(false);
      }
    }
  }

  Future<void> register({
    required String username,
    required String password,
    String? bootstrapToken,
    String? instanceInvitationToken,
    String deviceName = 'Atermius Web',
    String vaultName = 'Personal vault',
  }) async {
    final client = _requireApi();
    final instanceInfo = instance ?? await client.fetchInstance();
    if (password.length < 12) {
      throw FormatException(currentL10n.theMasterPasswordMustBeAt2);
    }
    if (instanceInfo.setupRequired &&
        (bootstrapToken?.trim().isEmpty ?? true)) {
      throw FormatException(currentL10n.enterTheBootstrapToken);
    }
    if (!instanceInfo.setupRequired &&
        (instanceInvitationToken?.trim().isEmpty ?? true)) {
      throw FormatException(currentL10n.enterTheAccountInvitationTokenIssued);
    }
    _setBusy(true);
    DeviceIdentity? newIdentity;
    InitialVaultMaterial? initialVault;
    Uint8List? loginVerifier;
    Uint8List? accountKey;
    try {
      final params = KdfParameters.defaults(sodium);
      final accountId = _uuid.v4();
      newIdentity = DeviceIdentity.create(sodium);
      loginVerifier = await crypto.deriveLoginVerifier(password, params);
      accountKey = crypto.randomBytes(32);
      final accountEnvelope = await crypto.wrapAccountKey(
        password: password,
        params: params,
        accountKey: accountKey,
      );
      final createdVault = await crypto.createInitialVault(
        accountId: accountId,
        name: vaultName.trim().isEmpty
            ? currentL10n.personalVault
            : vaultName.trim(),
        identity: newIdentity,
      );
      initialVault = createdVault;
      final registered = await client.register(
        accountId: accountId,
        username: username.trim(),
        bootstrapToken: instanceInfo.setupRequired
            ? bootstrapToken!.trim()
            : null,
        instanceInvitationToken: instanceInfo.setupRequired
            ? null
            : instanceInvitationToken!.trim(),
        kdf: params.toJson(),
        loginVerifier: encodeBase64Url(loginVerifier),
        accountKeyEnvelope: accountEnvelope,
        device: newIdentity.registrationProof(
          sodium,
          accountId: accountId,
          name: deviceName,
        ),
        initialVault: createdVault.payload,
      );
      loginVerifier.fillRange(0, loginVerifier.length, 0);
      loginVerifier = null;
      await secureStore.saveDevice(client.baseUrl, newIdentity);
      await _saveSessionCredentials(client.baseUrl, username, registered);
      _vaultLoadsBlocked = true;
      _verifiedSignerDirectoryCache.invalidate();
      ++_authContextGeneration;
      ++_vaultLoadGeneration;
      await _waitForVaultLoadCompletions();
      identity?.dispose();
      identity = newIdentity;
      newIdentity = null;
      _vaultLoadsBlocked = false;
      _resumeLockedReceiveForAuthenticatedSession();
      session = registered;
      _sessionAccessExpiresAt = _sessionCredentialsFor(registered)
          .accessExpiresAt;
      _sessionCredentialsAdoptedAt = null;
      _resetInstanceAdminOverview();
      account = await client.accountProfile();
      // Registration intentionally returns only vault identifiers and roles.
      // Load the canonical signed membership and device-addressed envelopes
      // from the authenticated Vault endpoints before treating this device as
      // able to unlock or approve access to any Vault.
      await _loadVaults(registered);
      _replaceAccountKey(accountKey);
      accountKey = null;
      accountRecoveryStatus = account?.recoveryStatus ?? 'disabled';
      unawaited(_refreshRecoveryContextsAndUpload());
      _authenticatedUsername = username.trim().toLowerCase();
      _signalSessionUpdate(
        client.baseUrl,
        _sessionCredentialsFor(registered),
        SessionUpdateKind.updated,
      );
      await _afterUnlock(
        password,
        params,
        registered,
        tryUnwrapAccountKey: false,
      );
      await _rememberAuthenticatedSession(username, registered, client);
      _setNotice(currentL10n.thePersonalVaultWasGeneratedAnd);
    } catch (error) {
      errorMessage = friendlyError(error);
      rethrow;
    } finally {
      loginVerifier?.fillRange(0, loginVerifier.length, 0);
      accountKey?.fillRange(0, accountKey.length, 0);
      final createdVault = initialVault;
      if (createdVault != null) {
        createdVault.vaultKey.fillRange(0, createdVault.vaultKey.length, 0);
      }
      newIdentity?.dispose();
      _setBusy(false);
    }
  }

  Future<MfaLoginChallenge?> login({
    required String username,
    required String password,
  }) async {
    if (_pendingFullAccountRecovery != null) {
      throw StateError(currentL10n.retryThePendingAccountRecoveryCompletion);
    }
    final client = _requireApi();
    _setBusy(true);
    DeviceIdentity? loadedIdentity;
    var mustVerifyImportedApproval = false;
    Uint8List? verifier;
    Uint8List? accountKey;
    KdfParameters? params;
    try {
      final prelogin = await client.prelogin(username.trim());
      params = KdfParameters.fromJson(
        Map<String, dynamic>.from(prelogin['kdf'] as Map),
      );
      verifier = await crypto.deriveLoginVerifier(password, params);
      loadedIdentity = await secureStore.loadDevice(client.baseUrl, crypto);
      if (loadedIdentity == null) {
        verifier.fillRange(0, verifier.length, 0);
        verifier = null;
        throw StateError(currentL10n.thisBrowserHasNoRegisteredDevice2);
      }
      final loginResult = await client.login(
        username: username.trim(),
        loginVerifier: encodeBase64Url(verifier),
        deviceId: loadedIdentity.deviceId,
      );
      verifier.fillRange(0, verifier.length, 0);
      verifier = null;
      if (loginResult is MfaLoginChallenge) {
        client.accessToken = null;
        errorMessage = null;
        notifyListeners();
        return loginResult;
      }
      final loggedIn = (loginResult as AuthenticatedLogin).session;
      if (loggedIn.accountId != prelogin['account_id'] ||
          loggedIn.deviceId != loadedIdentity.deviceId) {
        client.accessToken = null;
        throw FormatException(currentL10n.theSignInResponseDoesntMatch);
      }
      await _saveSessionCredentials(client.baseUrl, username, loggedIn);
      _vaultLoadsBlocked = true;
      _verifiedSignerDirectoryCache.invalidate();
      ++_authContextGeneration;
      ++_vaultLoadGeneration;
      await _waitForVaultLoadCompletions();
      identity?.dispose();
      identity = loadedIdentity;
      loadedIdentity = null;
      _vaultLoadsBlocked = false;
      _resumeLockedReceiveForAuthenticatedSession();
      session = loggedIn;
      _sessionAccessExpiresAt = _sessionCredentialsFor(loggedIn)
          .accessExpiresAt;
      _sessionCredentialsAdoptedAt = null;
      _resetInstanceAdminOverview();
      await _finishAuthenticatedLogin(
        client: client,
        username: username,
        password: password,
        params: params,
        loggedIn: loggedIn,
        pendingApprovalCallback: (pending) {
          mustVerifyImportedApproval = pending;
        },
        accountKeyCallback: (key) => accountKey = key,
      );
      _setNotice(currentL10n.unlockedLocallyTheServerStillStores);
      loadedIdentity = null;
      return null;
    } catch (error) {
      if (mustVerifyImportedApproval && session != null) {
        try {
          await logout();
        } catch (_) {
          // The validation error remains the user-visible failure. logout
          // clears all in-memory keys even if the server is unreachable.
        }
      }
      errorMessage = friendlyError(error);
      rethrow;
    } finally {
      verifier?.fillRange(0, verifier.length, 0);
      final remainingAccountKey = accountKey;
      if (remainingAccountKey != null) {
        remainingAccountKey.fillRange(0, remainingAccountKey.length, 0);
      }
      loadedIdentity?.dispose();
      params?.salt.fillRange(0, params.salt.length, 0);
      _setBusy(false);
    }
  }

  Future<void> completeMfaLogin({
    required String username,
    required String password,
    required MfaLoginChallenge challenge,
    required String code,
    required bool useRecoveryCode,
  }) async {
    if (accountLifecycleBusy) {
      throw StateError(currentL10n.anAccountStateActionIsIn);
    }
    if (code.trim().isEmpty ||
        (useRecoveryCode && !challenge.methods.contains('recovery_code')) ||
        (!useRecoveryCode && !challenge.methods.contains('totp'))) {
      throw FormatException(currentL10n.enterAnMfaCodeValidFor);
    }
    final client = _requireApi();
    _setBusy(true);
    DeviceIdentity? loadedIdentity;
    KdfParameters? params;
    Uint8List? accountKey;
    var mustVerifyImportedApproval = false;
    var mfaChallengeRejected = false;
    try {
      final prelogin = await client.prelogin(username.trim());
      params = KdfParameters.fromJson(
        Map<String, dynamic>.from(prelogin['kdf'] as Map),
      );
      loadedIdentity = await secureStore.loadDevice(client.baseUrl, crypto);
      if (loadedIdentity == null) {
        throw StateError(currentL10n.thisBrowserHasNoRegisteredDevice);
      }
      late final AuthSession loggedIn;
      try {
        loggedIn = await client.completeMfaLogin(
          challengeId: challenge.challengeId,
          totpCode: useRecoveryCode ? null : code,
          recoveryCode: useRecoveryCode ? code : null,
        );
      } on ApiException catch (error) {
        mfaChallengeRejected = error.code == 'AUTH_REQUIRED';
        rethrow;
      }
      if (loggedIn.deviceId != loadedIdentity.deviceId ||
          loggedIn.accountId != prelogin['account_id']) {
        client.accessToken = null;
        throw FormatException(currentL10n.theMfaSignInResponseDoesnt);
      }
      await _saveSessionCredentials(client.baseUrl, username, loggedIn);
      _vaultLoadsBlocked = true;
      _verifiedSignerDirectoryCache.invalidate();
      ++_authContextGeneration;
      ++_vaultLoadGeneration;
      await _waitForVaultLoadCompletions();
      identity?.dispose();
      identity = loadedIdentity;
      loadedIdentity = null;
      _vaultLoadsBlocked = false;
      _resumeLockedReceiveForAuthenticatedSession();
      session = loggedIn;
      _sessionAccessExpiresAt = _sessionCredentialsFor(loggedIn)
          .accessExpiresAt;
      _sessionCredentialsAdoptedAt = null;
      _resetInstanceAdminOverview();
      await _finishAuthenticatedLogin(
        client: client,
        username: username,
        password: password,
        params: params,
        loggedIn: loggedIn,
        pendingApprovalCallback: (pending) {
          mustVerifyImportedApproval = pending;
        },
        accountKeyCallback: (key) => accountKey = key,
      );
      _setNotice(currentL10n.mfaVerifiedAndUnlockedLocallyThe);
      errorMessage = null;
    } catch (error) {
      if (mustVerifyImportedApproval && session != null) {
        try {
          await logout();
        } catch (_) {
          // Cleanup in logout clears local credentials even if the network
          // request fails; keep the original validation error for the user.
        }
      }
      errorMessage = mfaChallengeRejected
          ? friendlyMfaLoginError(error)
          : friendlyError(error);
      rethrow;
    } finally {
      final remainingAccountKey = accountKey;
      if (remainingAccountKey != null) {
        remainingAccountKey.fillRange(0, remainingAccountKey.length, 0);
      }
      params?.salt.fillRange(0, params.salt.length, 0);
      loadedIdentity?.dispose();
      _setBusy(false);
    }
  }

  Future<void> _finishAuthenticatedLogin({
    required ApiClient client,
    required String username,
    required String password,
    required KdfParameters params,
    required AuthSession loggedIn,
    required void Function(bool pending) pendingApprovalCallback,
    required void Function(Uint8List? key) accountKeyCallback,
  }) async {
    var mustVerifyImportedApproval = false;
    Uint8List? accountKey;
    try {
      account = await client.accountProfile();
      accountKey = await crypto.unwrapAccountKey(
        password: password,
        params: params,
        envelope: account!.accountKeyEnvelope,
      );
      if (accountKey.length != 32) {
        throw FormatException(currentL10n.invalidAccountKeyLength);
      }
      final pendingApproval = await secureStore.pendingDeviceApproval(
        client.baseUrl,
      );
      mustVerifyImportedApproval = pendingApproval != null;
      pendingApprovalCallback(mustVerifyImportedApproval);
      await _loadVaults(loggedIn);
      _replaceAccountKey(accountKey);
      accountKeyCallback(null);
      accountKey = null;
      accountRecoveryStatus = account?.recoveryStatus ?? 'disabled';
      accountMfaEnabled = null;
      accountMfaRecoveryCodesRemaining = null;
      unawaited(_refreshRecoveryContextsAndUpload());
      if (pendingApproval != null) {
        await _verifyImportedDeviceApproval(pendingApproval);
        mustVerifyImportedApproval = false;
        pendingApprovalCallback(false);
      }
      _authenticatedUsername = username.trim().toLowerCase();
      _signalSessionUpdate(
        client.baseUrl,
        _sessionCredentialsFor(loggedIn),
        SessionUpdateKind.updated,
      );
      await _afterUnlock(
        password,
        params,
        loggedIn,
        tryUnwrapAccountKey: false,
      );
      await _rememberAuthenticatedSession(username, loggedIn, client);
    } catch (_) {
      accountKeyCallback(accountKey);
      rethrow;
    } finally {
      accountKey?.fillRange(0, accountKey.length, 0);
    }
  }

  Future<void> _afterUnlock(
    String password,
    KdfParameters params,
    AuthSession auth, {
    required bool tryUnwrapAccountKey,
  }) async {
    if (tryUnwrapAccountKey && account != null) {
      final key = await crypto.unwrapAccountKey(
        password: password,
        params: params,
        envelope: account!.accountKeyEnvelope,
      );
      key.fillRange(0, key.length, 0);
    }
    await _finishUnlockedWorkspace();
    await _rememberAccountKey();
  }

  Future<void> _finishUnlockedWorkspace() async {
    workspaceLocked = false;
    _lockedSyncReceiver = null;
    _vaultLoadsBlocked = false;
    stage = ClientStage.workspace;
    page = WorkspacePage.hosts;
    _defaultWorkspaceAppliedForVault = false;
    await _buildRepository();
    if (activeVault == null) {
      _clearVaultWorkspaceProjection();
    } else {
      await reloadRecords();
      await refreshSyncStatus();
    }
    _automaticSync.start();
    _startSyncHints();
    _startVaultPresenceHeartbeats();
    unawaited(_restoreMobilePushRegistration());
    notifyListeners();
  }

  // Clears only the active in-memory view. Durable encrypted rows, outbox
  // operations, and conflict history stay keyed to their original Vault IDs.
  void _clearVaultWorkspaceProjection({bool preserveSyncStatus = false}) {
    final priorSyncStatus = syncStatus;
    _shellHistorySyncEnabled = false;
    _shellHistorySyncEnableInProgress = false;
    hosts.clear();
    _jumpHostRouteIssues.clear();
    _hostGroupReferenceIssues.clear();
    _unavailableGroupRecordIds.clear();
    credentials.clear();
    groups.clear();
    snippets.clear();
    shellHistoryRecords.clear();
    savedWorkspaces.clear();
    activeSavedWorkspaceId = null;
    _workspacePaneTerminalTabIds.clear();
    knownHosts.clear();
    pendingKnownHostRecordIds.clear();
    preferences.clear();
    preferenceError = null;
    _resetDefaultSectionConflictRepair();
    _clearVaultDeviceRows();
    selectedHost = null;
    feedConflictItems = const [];
    _allFeedConflictItems = const [];
    openConflicts = [];
    pendingCount = 0;
    receivedCount = 0;
    conflictCount = 0;
    unavailableRecordCount = 0;
    _jumpHostRouteIssues.clear();
    lastSuccessfulSyncAt = null;
    syncCheckpointServerGeneration = null;
    syncStatus = preserveSyncStatus ? priorSyncStatus : 'idle';
    _resetAuditState();
  }

  void _resetDefaultSectionConflictRepair() {
    _preferenceConflicts.clear();
    _unsupportedVaultPreferencePresent = false;
    _preferenceRepairScanFailed = false;
  }

  Future<void> _verifyImportedDeviceApproval(String approvalJson) async {
    final client = _requireApi();
    final currentIdentity = identity;
    final currentAccount = account;
    final currentInstance = instance;
    if (currentIdentity == null ||
        currentAccount == null ||
        currentInstance == null) {
      throw StateError(currentL10n.couldntVerifyTheCurrentDeviceApproval);
    }
    final decoded = jsonDecode(approvalJson);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'atermius-device-approval-v1' ||
        decoded['account_id'] != currentAccount.accountId ||
        decoded['device'] is! Map ||
        decoded['vault_key_envelopes'] is! List) {
      throw FormatException(currentL10n.theDeviceApprovalFilesAccountOr);
    }
    final rawDevice = Map<String, dynamic>.from(decoded['device'] as Map);
    final card = crypto.verifyDeviceProof(
      accountId: currentAccount.accountId,
      instanceId: currentInstance.instanceId,
      device: rawDevice,
    );
    if (card.deviceId != currentIdentity.deviceId ||
        !listEquals(card.signingPublicKey, currentIdentity.signing.publicKey) ||
        !listEquals(
          card.encryptionPublicKey,
          currentIdentity.encryption.publicKey,
        )) {
      throw FormatException(currentL10n.theDeviceSelfProofInThe);
    }

    final approverId = decoded['approver_device_id'];
    final certificateText = decoded['certificate_signature'];
    if (approverId is! String || certificateText is! String) {
      throw FormatException(currentL10n.theDeviceApprovalCertificateFieldsAre);
    }
    final devices = await client.devices();
    Map<String, dynamic>? approver;
    Map<String, dynamic>? enrolledTarget;
    for (final device in devices) {
      if (device['device_id'] == approverId) approver = device;
      if (device['device_id'] == currentIdentity.deviceId) {
        enrolledTarget = device;
      }
    }
    if (approver == null || enrolledTarget == null) {
      throw FormatException(currentL10n.theApproverOrCurrentDeviceIsnt);
    }
    if (approver['user_id'] != currentAccount.accountId ||
        enrolledTarget['user_id'] != currentAccount.accountId ||
        enrolledTarget['status'] != 'active' ||
        enrolledTarget['signing_public_key'] !=
            card.device['signing_public_key'] ||
        enrolledTarget['encryption_public_key'] !=
            card.device['encryption_public_key']) {
      throw FormatException(currentL10n.theServerDeviceDirectoryDoesntMatch);
    }
    final approvedCapabilityReport = decoded['capability_report'];
    if (approvedCapabilityReport != null) {
      if (approvedCapabilityReport is! Map) {
        throw FormatException(currentL10n.theDeviceCapabilityReportInThe);
      }
      _verifyDeviceCapabilityReport(
        Map<String, dynamic>.from(approvedCapabilityReport),
        expectedAccountId: currentAccount.accountId,
        expectedDeviceId: currentIdentity.deviceId,
        signingPublicKey: card.signingPublicKey,
      );
      if (currentInstance.capabilities.contains('device_capability_reports') &&
          (enrolledTarget['capability_report'] is! Map ||
              canonicalJson(approvedCapabilityReport) !=
                  canonicalJson(enrolledTarget['capability_report']))) {
        throw FormatException(
          currentL10n.theServersDeviceCapabilityReportDoesnt,
        );
      }
    }
    final approverSigningKey = decodeBase64Url(
      approver['signing_public_key'] as String,
    );
    if (!crypto.verifyDeviceApprovalCertificate(
      accountId: currentAccount.accountId,
      approverDeviceId: approverId,
      device: rawDevice,
      signature: certificateText,
      approverSigningPublicKey: approverSigningKey,
    )) {
      throw FormatException(
        currentL10n.theApproverCertificateSignatureIsInvalid,
      );
    }

    final actualEnvelopes = <String, Map<String, dynamic>>{};
    for (final vault in _vaultDescriptors) {
      for (final envelope in vault.keyEnvelopes) {
        if (envelope['recipient_device_id'] != currentIdentity.deviceId) {
          continue;
        }
        final epoch = envelope['key_epoch']?.toString();
        final version = envelope['membership_version']?.toString();
        if (epoch == null || version == null) continue;
        actualEnvelopes['${vault.id}:$epoch:$version'] = envelope;
      }
    }
    // An account may have no active Vaults. In that case a trusted device
    // approval correctly carries an empty envelope list; the account/device
    // certificate still authenticates the new device.
    final approvalEnvelopes = decoded['vault_key_envelopes'] as List;
    final seen = <String>{};
    for (final rawEnvelope in approvalEnvelopes) {
      if (rawEnvelope is! Map) {
        throw FormatException(currentL10n.theVaultKeyEnvelopeInThe);
      }
      final envelope = Map<String, dynamic>.from(rawEnvelope);
      final vaultId = envelope['vault_id'];
      final recipientId = envelope['recipient_device_id'];
      final epoch = envelope['key_epoch'];
      final version = envelope['membership_version'];
      final signatureText = envelope['signature'];
      if (vaultId is! String ||
          recipientId != currentIdentity.deviceId ||
          epoch is! int ||
          version is! int ||
          signatureText is! String ||
          envelope['envelope'] is! Map) {
        throw FormatException(currentL10n.theKeyEnvelopeContextInThe);
      }
      final tuple = '$vaultId:$epoch:$version';
      if (!seen.add(tuple)) {
        throw FormatException(
          currentL10n.theDeviceApprovalContainsDuplicateVault,
        );
      }
      final signedPayload = <String, Object?>{
        'vault_id': vaultId,
        'recipient_device_id': recipientId,
        'key_epoch': epoch,
        'membership_version': version,
        'envelope': envelope['envelope'],
      };
      final signature = decodeBase64Url(signatureText);
      if (signature.length != 64 ||
          !sodium.crypto.sign.verifyDetached(
            message: Uint8List.fromList(
              utf8.encode(canonicalJson(signedPayload)),
            ),
            signature: signature,
            publicKey: approverSigningKey,
          )) {
        throw FormatException(
          currentL10n.theApprovalKeyEnvelopeSignatureFor(vaultId),
        );
      }
      final stored = actualEnvelopes[tuple];
      if (stored != null &&
          (stored['signer_device_id'] != approverId ||
              stored['signature'] != signatureText ||
              canonicalJson(stored['envelope']) !=
                  canonicalJson(envelope['envelope']))) {
        throw FormatException(
          currentL10n.theServerKeyEnvelopeForVault(vaultId),
        );
      }
      // The approval file captures the envelopes available at enrollment
      // time. While the new device is offline, the server may legitimately
      // add rotation envelopes or stop listing a Vault whose membership was
      // revoked. `_loadVaults` authenticates every currently available
      // envelope against the signed membership chain; compare the original
      // envelope only when its Vault and version are still visible.
      if (stored != null) {
        final opened = await crypto.openVaultKeyEnvelope(
          vaultId: vaultId,
          deviceId: currentIdentity.deviceId,
          identity: currentIdentity,
          keyEnvelope: envelope,
          signerPublicKey: approverSigningKey,
        );
        final expectedKey =
            _vaultEpochKeys[vaultId]?[_vaultVersionKey('$epoch', '$version')];
        final valid = expectedKey != null && listEquals(opened, expectedKey);
        opened.fillRange(0, opened.length, 0);
        if (!valid) {
          throw FormatException(
            currentL10n.theApprovedKeyForVaultVaultid(vaultId),
          );
        }
      }
    }
    await secureStore.clearPendingDeviceApproval(client.baseUrl);
    await secureStore.clearPendingDevice(client.baseUrl);
  }

  void _verifyDeviceCapabilityReport(
    Map<String, dynamic> report, {
    required String expectedAccountId,
    required String expectedDeviceId,
    required Uint8List signingPublicKey,
  }) => crypto.verifyDeviceCapabilityReport(
    report: report,
    expectedAccountId: expectedAccountId,
    expectedDeviceId: expectedDeviceId,
    signingPublicKey: signingPublicKey,
  );

  Future<void> _loadVaults(AuthSession auth, {String? preferredVaultId}) {
    if (_controllerDisposed || _vaultLoadsBlocked) {
      return Future<void>.error(
        StateError(currentL10n.vaultKeysAreBeingCleared),
      );
    }
    final loadGeneration = ++_vaultLoadGeneration;
    final authContextGeneration = _authContextGeneration;
    final apiGeneration = _apiGeneration;
    final selectionGeneration = _vaultSelectionGeneration;
    final previousKeyBuffers = _snapshotVaultKeyBuffers();
    late final Future<void> completion;
    completion =
        _loadVaultsAndReplaceKeys(
          auth,
          preferredVaultId: preferredVaultId,
          loadGeneration: loadGeneration,
          authContextGeneration: authContextGeneration,
          apiGeneration: apiGeneration,
          selectionGeneration: selectionGeneration,
        ).whenComplete(() {
          // Register the snapshot even when descriptor verification or a later
          // selectVault step fails. If a still-published repository references an
          // old buffer, its retirement callback will retry the wipe after drain.
          _scheduleVaultKeyBufferWipeAfterDrains(previousKeyBuffers);
          _vaultLoadCompletions.remove(completion);
        });
    _vaultLoadCompletions.add(completion);
    return completion;
  }

  Future<void> _loadVaultsAndReplaceKeys(
    AuthSession auth, {
    String? preferredVaultId,
    required int loadGeneration,
    required int authContextGeneration,
    required int apiGeneration,
    required int selectionGeneration,
  }) async {
    final client = _requireApi();
    final currentIdentity = identity;
    if (currentIdentity == null) throw const _VaultLoadSuperseded();
    bool loadIsCurrent() =>
        !_controllerDisposed &&
        !_vaultLoadsBlocked &&
        loadGeneration == _vaultLoadGeneration &&
        authContextGeneration == _authContextGeneration &&
        apiGeneration == _apiGeneration &&
        selectionGeneration == _vaultSelectionGeneration &&
        session?.accountId == auth.accountId &&
        session?.deviceId == auth.deviceId &&
        identical(identity, currentIdentity) &&
        identical(api, client);
    void requireCurrentLoad() {
      if (!loadIsCurrent()) throw const _VaultLoadSuperseded();
    }

    final loadedVaultKeys = <String, Uint8List>{};
    final loadedEpochKeys = <String, Map<String, Uint8List>>{};
    final loadedNames = <String, String>{};
    final loadedSignerDirectories = <String, Map<String, Uint8List>>{};
    final loadedSignerDirectoryTickets = <String, int?>{};
    final signerCacheGeneration = _verifiedSignerDirectoryCache.generation;
    final signerCacheInstance = instance;
    final openedKeyBuffers = <Uint8List>{};
    var keysTransferred = false;
    try {
      requireCurrentLoad();
      final listed = await _withVaultHydrationAuthRetry(
        () => client.vaults(),
        duringUnlock: _lockedUnlockInProgress,
        requireCurrentLoad: requireCurrentLoad,
      );
      requireCurrentLoad();
      for (final vault in listed) {
        final signerCacheScope = signerCacheInstance == null
            ? null
            : SignerDirectoryCacheScope(
                serverBaseUrl: client.baseUrl,
                serverSpaceId: signerCacheInstance.serverSpaceId,
                instanceId: signerCacheInstance.instanceId,
                accountId: auth.accountId,
                vaultId: vault.id,
              );
        if (signerCacheScope != null) {
          loadedSignerDirectoryTickets[vault.id] = _verifiedSignerDirectoryCache
              .beginRefresh(
                signerCacheScope,
                generation: signerCacheGeneration,
              );
        }
      }

      final allDevices = await _withVaultHydrationAuthRetry(
        () => client.devices(),
        duringUnlock: _lockedUnlockInProgress,
        requireCurrentLoad: requireCurrentLoad,
      );
      requireCurrentLoad();
      final signerKeys = <String, Uint8List>{};
      for (final device in allDevices) {
        final id = device['device_id'] as String?;
        final key = device['signing_public_key'] as String?;
        if (id != null && key != null) signerKeys[id] = decodeBase64Url(key);
      }
      signerKeys[currentIdentity.deviceId] = currentIdentity.signing.publicKey;

      final opened = <VaultDescriptor>[];
      for (final vault in listed) {
        requireCurrentLoad();
        final vaultDevices = await _withVaultHydrationAuthRetry(
          () => client.vaultDevices(vault.id),
          duringUnlock: _lockedUnlockInProgress,
          requireCurrentLoad: requireCurrentLoad,
        );
        requireCurrentLoad();
        final vaultDirectoryRows = [...allDevices, ...vaultDevices];
        final directory = <String, Map<String, dynamic>>{};
        for (final device in vaultDirectoryRows) {
          final id = device['device_id'] as String?;
          final key = device['signing_public_key'] as String?;
          if (id == null || key == null) continue;
          directory[id] = device;
          signerKeys[id] = decodeBase64Url(key);
        }
        final membershipResponse = await _withVaultHydrationAuthRetry(
          () => client.membership(vault.id),
          duringUnlock: _lockedUnlockInProgress,
          requireCurrentLoad: requireCurrentLoad,
        );
        requireCurrentLoad();
        final rawMemberships =
            (membershipResponse['manifests'] ??
                    membershipResponse['memberships'] ??
                    membershipResponse['entries'] ??
                    membershipResponse['chain'])
                as List<dynamic>? ??
            const [];
        final memberships = rawMemberships
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList(growable: false);
        final verifiedMemberships = await crypto.verifyMembershipChain(
          vaultId: vault.id,
          entries: memberships,
          signerPublicKeys: signerKeys,
          expectedLatestVersion: int.parse(vault.membershipVersion),
        );
        requireCurrentLoad();
        _validateMembershipOwnerChain(
          vaultId: vault.id,
          chain: verifiedMemberships,
          directory: directory,
        );
        try {
          loadedSignerDirectories[vault.id] = validatedSignerDirectory(
            identity: currentIdentity,
            devices: vaultDirectoryRows,
          );
        } on FormatException {
          // A malformed directory entry that was irrelevant to membership
          // verification must not become an offline decryption authority.
          // The repository can still retry an online refresh later.
        }
        final latestMembership = verifiedMemberships.last;
        if ((latestMembership.manifest['key_epoch'] as num?)?.toInt() !=
            int.tryParse(vault.activeKeyEpoch)) {
          throw FormatException(
            currentL10n.vaultIdLatestSignedMembershipEpoch(vault.id),
          );
        }
        final currentAccountId = account?.accountId ?? auth.accountId;
        final currentMember = (latestMembership.manifest['members'] as List)
            .any(
              (member) =>
                  member is Map &&
                  member['user_id'] == currentAccountId &&
                  member['state'] == 'active',
            );
        if (!currentMember) {
          throw FormatException(
            currentL10n.vaultIdMembershipDoesNotInclude(vault.id),
          );
        }
        final addressed = vault.keyEnvelopes.where(
          (item) => item['recipient_device_id'] == currentIdentity.deviceId,
        );
        if (addressed.isEmpty) {
          throw FormatException(currentL10n.vaultIdHasNoKeyEnvelope2(vault.id));
        }
        final epochKeys = <String, Uint8List>{};
        final keysByEpoch = <int, Uint8List>{};
        for (final envelope in addressed) {
          final membershipVersion =
              (envelope['membership_version'] as num?)?.toInt() ??
              int.parse(vault.membershipVersion);
          final membership = verifiedMemberships
              .where((item) => item.version == membershipVersion)
              .firstOrNull;
          if (membership == null) {
            throw FormatException(
              currentL10n.vaultIdKeyEnvelopeRefersTo(vault.id),
            );
          }
          final signerId =
              envelope['signer_device_id'] as String? ??
              membership.signerDeviceId;
          final signerDevice = directory[signerId];
          final signerUserId = signerDevice?['user_id'] as String?;
          final signerWasMember = (membership.manifest['members'] as List).any(
            (member) =>
                member is Map &&
                member['user_id'] == signerUserId &&
                member['state'] == 'active' &&
                const {'owner', 'editor', 'viewer'}.contains(member['role']),
          );
          if (signerDevice == null ||
              signerUserId == null ||
              !signerWasMember) {
            throw FormatException(
              currentL10n.vaultIdKeyEnvelopeSignerIs(vault.id),
            );
          }
          final epoch =
              (envelope['key_epoch'] as num?)?.toInt() ??
              int.parse(vault.activeKeyEpoch);
          if ((membership.manifest['key_epoch'] as num?)?.toInt() != epoch) {
            throw FormatException(
              currentL10n.vaultIdKeyEnvelopeEpochDoes(vault.id),
            );
          }
          final signerPublicKey = signerKeys[signerId];
          if (signerPublicKey == null) {
            throw FormatException(
              currentL10n.theSigningDeviceForVaultId(vault.id),
            );
          }
          final key = await crypto.openVaultKeyEnvelope(
            vaultId: vault.id,
            deviceId: currentIdentity.deviceId,
            identity: currentIdentity,
            keyEnvelope: envelope,
            signerPublicKey: signerPublicKey,
          );
          openedKeyBuffers.add(key);
          requireCurrentLoad();
          final previousEpochKey = keysByEpoch[epoch];
          if (previousEpochKey != null &&
              !_constantTimeBytesEqual(previousEpochKey, key)) {
            throw FormatException(
              currentL10n.vaultIdHasConflictingDeviceKeys(vault.id),
            );
          }
          keysByEpoch[epoch] = key;
          epochKeys[_vaultVersionKey('$epoch', '$membershipVersion')] = key;
        }
        if (epochKeys.isEmpty) continue;
        // The data key is stable for an epoch even when signed membership
        // manifests advance without rekeying. Records written under a later
        // membership version still use that epoch's existing key envelope.
        // Alias the verified epoch key for every manifest in the same epoch so
        // local records remain decryptable after a later key rotation.
        for (final membership in verifiedMemberships) {
          final epoch = (membership.manifest['key_epoch'] as num?)?.toInt();
          final key = epoch == null ? null : keysByEpoch[epoch];
          if (epoch != null && key != null) {
            epochKeys[_vaultVersionKey('$epoch', '${membership.version}')] =
                key;
          }
        }
        loadedEpochKeys[vault.id] = epochKeys;
        final exactActiveKey =
            epochKeys[_vaultVersionKey(
              vault.activeKeyEpoch,
              vault.membershipVersion,
            )];
        final activeKey =
            exactActiveKey ??
            epochKeys.entries
                .where(
                  (entry) => entry.key.startsWith('${vault.activeKeyEpoch}:'),
                )
                .map((entry) => entry.value)
                .firstOrNull;
        if (activeKey == null) {
          throw FormatException(currentL10n.vaultIdHasNoKeyEnvelope(vault.id));
        }
        loadedVaultKeys[vault.id] = activeKey;
        final signedNameEnvelope =
            latestMembership.manifest['display_name_envelope'];
        final Map<String, dynamic>? nameEnvelope;
        if (signedNameEnvelope != null) {
          if (signedNameEnvelope is! Map) {
            throw FormatException(
              currentL10n.vaultIdSignedDisplayNameEnvelope(vault.id),
            );
          }
          nameEnvelope = Map<String, dynamic>.from(signedNameEnvelope);
          loadedNames[vault.id] = await crypto.decryptVaultName(
            vaultId: vault.id,
            vaultKey: activeKey,
            envelope: nameEnvelope,
          );
          requireCurrentLoad();
        } else {
          nameEnvelope = vault.encryptedDisplayNameEnvelope;
          if (nameEnvelope != null) {
            Object? lastNameError;
            final candidates = <Uint8List>[
              activeKey,
              ...epochKeys.values.where((key) => !identical(key, activeKey)),
            ];
            for (final candidate in candidates) {
              try {
                loadedNames[vault.id] = await crypto.decryptVaultName(
                  vaultId: vault.id,
                  vaultKey: candidate,
                  envelope: nameEnvelope,
                );
                requireCurrentLoad();
                lastNameError = null;
                break;
              } catch (error) {
                requireCurrentLoad();
                lastNameError = error;
              }
            }
            if (lastNameError != null) {
              throw FormatException(
                currentL10n.vaultIdLegacyDisplayNameEnvelope(vault.id),
              );
            }
          }
        }
        opened.add(
          VaultDescriptor(
            id: vault.id,
            role: vault.role,
            activeKeyEpoch: vault.activeKeyEpoch,
            membershipVersion: vault.membershipVersion,
            encryptedDisplayNameEnvelope: nameEnvelope,
            keyEnvelopes: vault.keyEnvelopes,
            status: vault.status,
            requestedAt: vault.requestedAt,
            purgeAfter: vault.purgeAfter,
            canCancel: vault.canCancel,
            canWrite: vault.canWrite,
          ),
        );
      }
      final loadedIds = opened.map((item) => item.id).toSet();
      final nextActiveVault =
          opened.where((vault) => vault.id == preferredVaultId).firstOrNull ??
          opened.firstOrNull;
      final previousActiveVault = activeVault;
      if ((previousActiveVault?.id != nextActiveVault?.id ||
              previousActiveVault?.membershipVersion !=
                  nextActiveVault?.membershipVersion) &&
          (_terminalShareHosts.isNotEmpty ||
              _terminalShareStatuses.isNotEmpty ||
              _terminalShareObservers.isNotEmpty)) {
        await _stopAllTerminalCollaboration();
        requireCurrentLoad();
      }

      // Stage every decrypted key until all Vaults and descriptors pass
      // verification. A later malformed envelope must not leave earlier Vault
      // keys visible in the shared maps.
      requireCurrentLoad();
      final nextKnownNames = Map<String, String>.from(_knownNames)
        ..removeWhere((vaultId, _) => !loadedIds.contains(vaultId))
        ..addAll(loadedNames);
      // Drop in-memory access to Vaults that the server no longer lists. Keep
      // encrypted Drift rows and outbox data untouched; they remain scoped to
      // their original vault_id and cannot be uploaded without a repository.
      final infoForSignerScope = signerCacheInstance;
      if (infoForSignerScope != null) {
        for (final entry in loadedSignerDirectories.entries) {
          _verifiedSignerDirectoryCache.publishHydrated(
            SignerDirectoryCacheScope(
              serverBaseUrl: client.baseUrl,
              serverSpaceId: infoForSignerScope.serverSpaceId,
              instanceId: infoForSignerScope.instanceId,
              accountId: auth.accountId,
              vaultId: entry.key,
            ),
            generation: signerCacheGeneration,
            ticket: loadedSignerDirectoryTickets[entry.key],
            signers: entry.value,
          );
        }
      }
      _vaultKeys
        ..clear()
        ..addAll(loadedVaultKeys);
      _vaultEpochKeys
        ..clear()
        ..addAll(loadedEpochKeys);
      _knownNames
        ..clear()
        ..addAll(nextKnownNames);
      _vaultDescriptors = opened;
      activeVault = nextActiveVault;
      final committedKeyBuffers = <Uint8List>{
        ...loadedVaultKeys.values,
        for (final versions in loadedEpochKeys.values) ...versions.values,
      };
      for (final key in openedKeyBuffers) {
        if (!committedKeyBuffers.contains(key)) {
          key.fillRange(0, key.length, 0);
        }
      }
      keysTransferred = true;
      await loadShellHistorySyncPreference(isCurrent: loadIsCurrent);
      requireCurrentLoad();
      _lastAccountControlPlaneRefreshAt = _currentControlPlaneTime();
      unawaited(_refreshRecoveryContextsAndUpload());
    } finally {
      if (!keysTransferred) {
        for (final key in openedKeyBuffers) {
          key.fillRange(0, key.length, 0);
        }
      }
    }
  }

  Future<T> _withVaultHydrationAuthRetry<T>(
    Future<T> Function() request, {
    required bool duringUnlock,
    required void Function() requireCurrentLoad,
  }) async {
    try {
      return await request();
    } on ApiException catch (error) {
      if (error.statusCode != 401 || error.code != 'AUTH_REQUIRED') rethrow;
      // Refresh rotation replaces the server's active access-token hash at
      // once. A GET that was sent with the previous bearer can therefore fail
      // even though this tab (or another tab) already has the new session.
      // Reconcile the encrypted snapshot under SessionRefreshLock and retry
      // this idempotent hydration read once with the current bearer.
      requireCurrentLoad();
      final recovered = await _refreshSessionForSyncHint(
        duringUnlock: duringUnlock,
        force: false,
      );
      if (!recovered) rethrow;
      requireCurrentLoad();
      return request();
    }
  }

  void _replaceAccountKey(Uint8List next) {
    final previous = _accountKey;
    if (previous != null) previous.fillRange(0, previous.length, 0);
    _accountKey = next;
  }

  void _clearRecoveryIdentity() {
    _recoveryIdentity?.dispose();
    _recoveryIdentity = null;
    accountRecoveryRequiredContexts = const [];
    accountRecoveryPresentContexts = const [];
    accountRecoveryStatus = 'disabled';
  }

  Future<void> _refreshRecoveryContextsAndUpload() {
    if (_controllerDisposed) {
      _recoverySyncRequested = false;
      return Future<void>.value();
    }
    _recoverySyncRequested = true;
    final running = _recoverySyncFuture;
    if (running != null) return running;
    late final Future<void> future;
    future = _drainRecoveryContextRefreshes().whenComplete(() {
      if (identical(_recoverySyncFuture, future)) _recoverySyncFuture = null;
      if (_recoverySyncRequested && !_controllerDisposed) {
        unawaited(_refreshRecoveryContextsAndUpload());
      } else if (_controllerDisposed) {
        _recoverySyncRequested = false;
      }
    });
    _recoverySyncFuture = future;
    return future;
  }

  Future<void> _waitForRecoveryContextRefreshes() async {
    while (true) {
      final pending = _recoverySyncFuture;
      if (pending == null) return;
      try {
        await pending;
      } catch (_) {
        // A failed best-effort refresh has still released its key references.
      }
    }
  }

  Map<String, Set<Uint8List>> _snapshotVaultKeyBuffers() {
    final snapshot = <String, Set<Uint8List>>{};
    for (final entry in _vaultKeys.entries) {
      snapshot.putIfAbsent(entry.key, () => <Uint8List>{}).add(entry.value);
    }
    for (final vaultEntry in _vaultEpochKeys.entries) {
      snapshot
          .putIfAbsent(vaultEntry.key, () => <Uint8List>{})
          .addAll(vaultEntry.value.values);
    }
    final currentRepository = _repository;
    if (currentRepository != null) {
      final repositoryBuffers = snapshot.putIfAbsent(
        currentRepository.vaultId,
        () => <Uint8List>{},
      );
      final vaultKey = currentRepository.vaultKey;
      if (vaultKey is Uint8List) repositoryBuffers.add(vaultKey);
      for (final key in currentRepository.vaultKeysByVersion.values) {
        if (key is Uint8List) repositoryBuffers.add(key);
      }
    }
    for (final pendingEntry in _pendingVaultKeyBufferWipes.entries) {
      snapshot
          .putIfAbsent(pendingEntry.key, () => <Uint8List>{})
          .addAll(pendingEntry.value);
    }
    return snapshot;
  }

  Future<void> _waitForVaultLoadCompletions() async {
    while (_vaultLoadCompletions.isNotEmpty) {
      final pending = _vaultLoadCompletions.toList(growable: false);
      await Future.wait<void>(
        pending.map((future) => future.then<void>((_) {}, onError: (_, _) {})),
      );
    }
  }

  void _scheduleVaultKeyBufferWipeAfterDrains(
    Map<String, Set<Uint8List>> buffersByVault,
  ) {
    if (buffersByVault.isEmpty) return;
    for (final entry in buffersByVault.entries) {
      _pendingVaultKeyBufferWipes
          .putIfAbsent(entry.key, () => <Uint8List>{})
          .addAll(entry.value);
      _schedulePendingVaultKeyBufferWipe(entry.key);
    }
  }

  void _schedulePendingVaultKeyBufferWipe(String vaultId) {
    if (_pendingVaultKeyBufferWipes[vaultId]?.isEmpty ?? true) return;
    unawaited(
      _wipePendingVaultKeyBuffersAfterDrains(vaultId).catchError((Object _) {
        // If any lease cannot prove it drained, retain the buffers.
      }),
    );
  }

  Future<void> _wipePendingVaultKeyBuffersAfterDrains(String vaultId) async {
    await _waitForArchiveOperations();
    await _waitForRecoveryContextRefreshes();
    await _waitForRetiredRepositoryDrains(vaultId: vaultId);
    final pendingBuffers = _pendingVaultKeyBufferWipes[vaultId];
    if (pendingBuffers == null || pendingBuffers.isEmpty) return;
    final stillReferenced = <Uint8List>{
      ..._vaultKeys.values,
      for (final versions in _vaultEpochKeys.values) ...versions.values,
    };
    final currentRepository = _repository;
    final currentVaultKey = currentRepository?.vaultKey;
    if (currentVaultKey is Uint8List) stillReferenced.add(currentVaultKey);
    for (final key
        in currentRepository?.vaultKeysByVersion.values ?? const []) {
      if (key is Uint8List) stillReferenced.add(key);
    }
    for (final key in pendingBuffers.toList(growable: false)) {
      if (stillReferenced.contains(key)) continue;
      key.fillRange(0, key.length, 0);
      pendingBuffers.remove(key);
    }
    if (pendingBuffers.isEmpty) _pendingVaultKeyBufferWipes.remove(vaultId);
  }

  Future<void> _drainRecoveryContextRefreshes() async {
    while (_recoverySyncRequested) {
      _recoverySyncRequested = false;
      await _refreshRecoveryContextsAndUploadOnce();
    }
  }

  Future<void> _refreshRecoveryContextsAndUploadOnce() async {
    final auth = session;
    final currentApi = api;
    final currentAccount = account;
    final currentIdentity = identity;
    final currentAccountKey = _accountKey;
    if (auth == null ||
        currentApi == null ||
        currentAccount == null ||
        currentIdentity == null ||
        currentAccountKey == null ||
        auth.accountId != currentAccount.accountId ||
        auth.deviceId != currentIdentity.deviceId) {
      return;
    }
    try {
      final snapshot = await currentApi.accountRecoveryContexts();
      if (!identical(session, auth) || !identical(api, currentApi)) return;
      accountRecoveryRequiredContexts = snapshot.required;
      accountRecoveryPresentContexts = snapshot.present;
      accountRecoveryStatus = snapshot.status;
      if (snapshot.status == 'disabled') {
        _clearRecoveryIdentity();
        accountRecoveryStatus = 'disabled';
        notifyListeners();
        return;
      }
      final envelope = snapshot.identityEnvelope;
      if (snapshot.generation < 1 || envelope == null) {
        throw FormatException(currentL10n.recoveryIdentityEnvelopeIsMissing);
      }
      RecoveryIdentity? opened;
      try {
        opened = await recoveryCrypto.openIdentityWithAccountKey(
          envelope: envelope,
          accountKey: currentAccountKey,
          accountId: auth.accountId,
          instanceId: instance?.instanceId ?? '',
          serverSpaceId: instance?.serverSpaceId ?? '',
          generation: snapshot.generation,
        );
        if (snapshot.recoveryPublicSigningKey != opened.signingPublicKey ||
            snapshot.recoveryPublicEncryptionKey !=
                opened.encryptionPublicKey) {
          throw FormatException(currentL10n.recoveryDescriptorPublicKeysDoNot);
        }
        final expectedDescriptorHash = await recoveryCrypto
            .recoveryDescriptorHash(
              accountId: auth.accountId,
              instanceId: instance?.instanceId ?? '',
              serverSpaceId: instance?.serverSpaceId ?? '',
              generation: snapshot.generation,
              signingPublicKey: opened.signingPublicKey,
              encryptionPublicKey: opened.encryptionPublicKey,
            );
        if (snapshot.descriptorHash != expectedDescriptorHash) {
          throw FormatException(currentL10n.recoveryDescriptorHashIsInvalid);
        }
        final old = _recoveryIdentity;
        _recoveryIdentity = opened;
        opened = null;
        old?.dispose();
      } finally {
        opened?.dispose();
      }
      final recoveryIdentity = _recoveryIdentity!;
      final presentKeys = snapshot.present
          .map((item) => item.logicalKey)
          .toSet();
      final keyEnvelopes = <Map<String, Object?>>[];
      for (final required in snapshot.required) {
        if (presentKeys.contains(required.logicalKey)) continue;
        final versions = _vaultEpochKeys[required.vaultId];
        if (versions == null) continue;
        final candidates = versions.entries
            .where((entry) => entry.key.startsWith('${required.keyEpoch}:'))
            .map((entry) => entry.value)
            .toList(growable: false);
        if (candidates.isEmpty) continue;
        final vaultKey = candidates.first;
        if (candidates
            .skip(1)
            .any(
              (candidate) => !_constantTimeBytesEqual(vaultKey, candidate),
            )) {
          continue;
        }
        keyEnvelopes.add(
          await recoveryCrypto.buildKeyEnvelope(
            identity: recoveryIdentity,
            uploaderDeviceId: currentIdentity.deviceId,
            vaultId: required.vaultId,
            keyEpoch: required.keyEpoch,
            vaultKey: vaultKey,
          ),
        );
      }
      if (keyEnvelopes.isNotEmpty &&
          identical(session, auth) &&
          identical(_recoveryIdentity, recoveryIdentity)) {
        final descriptorHash = await recoveryCrypto.recoveryDescriptorHash(
          accountId: recoveryIdentity.accountId,
          instanceId: recoveryIdentity.instanceId,
          serverSpaceId: recoveryIdentity.serverSpaceId,
          generation: recoveryIdentity.generation,
          signingPublicKey: recoveryIdentity.signingPublicKey,
          encryptionPublicKey: recoveryIdentity.encryptionPublicKey,
        );
        final result = await currentApi.uploadAccountRecoveryKeyEnvelopes({
          'operation_id': _uuid.v4().toLowerCase(),
          'recovery_generation': recoveryIdentity.generation,
          'recovery_descriptor_hash': descriptorHash,
          'key_envelopes': keyEnvelopes,
        });
        final status = result['recovery_status'];
        if (status is String &&
            const {'current', 'stale', 'incomplete'}.contains(status)) {
          accountRecoveryStatus = status;
        }
        final newlyPresent = keyEnvelopes
            .map((item) => '${item['vault_id']}:${item['key_epoch']}')
            .toSet();
        final covered = presentKeys.union(newlyPresent);
        if (snapshot.required.every(
          (item) => covered.contains(item.logicalKey),
        )) {
          accountRecoveryStatus = 'current';
        } else {
          accountRecoveryStatus = 'stale';
        }
        accountRecoveryPresentContexts = [
          ...snapshot.present,
          ...keyEnvelopes.map(
            (item) => AccountRecoveryContext(
              vaultId: item['vault_id']! as String,
              keyEpoch: item['key_epoch']! as int,
            ),
          ),
        ];
      }
      notifyListeners();
    } catch (_) {
      // Recovery metadata and keybox uploads are best-effort background work.
      // They must never turn a successful login, hydration, or Vault mutation
      // into an apparent failure. A later hydration retries missing boxes.
    }
  }

  bool _constantTimeBytesEqual(Uint8List left, Uint8List right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }

  Future<void> _buildRepository({
    bool waitForPreviousRepositoryDrain = true,
    int? expectedVaultSelectionGeneration,
  }) async {
    final buildGeneration = ++_repositoryBuildGeneration;
    final buildSelectionGeneration = _vaultSelectionGeneration;
    final previousRepository = _repository;
    final auth = session;
    final currentIdentity = identity;
    final buildApi = api;
    final buildAuthContextGeneration = _authContextGeneration;
    final buildApiGeneration = _apiGeneration;
    if (auth == null || currentIdentity == null) {
      throw StateError(currentL10n.signInAndUnlockTheAccount2);
    }
    if (buildApi == null) throw StateError(currentL10n.connectToTheServerFirst);
    if (auth.deviceId != currentIdentity.deviceId) {
      throw StateError(currentL10n.theSignInSessionDeviceId);
    }
    bool buildIsCurrent() =>
        !_controllerDisposed &&
        buildGeneration == _repositoryBuildGeneration &&
        buildSelectionGeneration == _vaultSelectionGeneration &&
        buildAuthContextGeneration == _authContextGeneration &&
        buildApiGeneration == _apiGeneration &&
        identical(api, buildApi) &&
        session?.accountId == auth.accountId &&
        session?.deviceId == auth.deviceId &&
        identical(identity, currentIdentity) &&
        (expectedVaultSelectionGeneration == null ||
            expectedVaultSelectionGeneration == _vaultSelectionGeneration);

    final vault = activeVault;
    if (vault == null) {
      _repository = null;
      _knownHostDecisionGeneration++;
      await _retireRepositoryAndTrack(previousRepository);
      return;
    }

    // Retire the currently published repository before considering its
    // replacement. Rebuilding the same Vault must wait before creating a new
    // repository so its per-repository serial queue cannot overlap the old
    // one. A different-Vault selection may publish immediately while the old
    // repository drains in the background.
    final mustWaitForPrevious =
        waitForPreviousRepositoryDrain ||
        previousRepository?.vaultId == vault.id;
    if (previousRepository?.vaultId == vault.id) {
      _repository = null;
    }
    final previousRepositoryDrained = _retireRepositoryAndTrack(
      previousRepository,
    );
    if (identical(_repository, previousRepository)) _repository = null;
    if (mustWaitForPrevious) await previousRepositoryDrained;
    if (!buildIsCurrent()) return;

    // A Vault can be selected again while its previous repository is still
    // draining a request. Never install a second repository for that Vault
    // until every retired instance has stopped using its shared key buffers.
    await _waitForRetiredRepositoryDrains(vaultId: vault.id);
    if (!buildIsCurrent()) return;
    final info = instance ?? await buildApi.fetchInstance();
    if (!buildIsCurrent()) return;
    instance ??= info;
    final nextRepository = SyncRepository(
      api: buildApi,
      database: database,
      crypto: crypto,
      identity: currentIdentity,
      serverSpaceId: info.serverSpaceId,
      instanceId: info.instanceId,
      trustedInstanceSigningPublicKey: info.signingPublicKey,
      accountId: auth.accountId,
      vaultId: vault.id,
      keyEpoch: vault.activeKeyEpoch,
      membershipVersion: vault.membershipVersion,
      serverGeneration: info.generation,
      vaultKey: _vaultKeys[vault.id]!,
      vaultKeysByVersion: _vaultEpochKeys[vault.id] ?? const {},
      knownHostDecisionLock: _knownHostDecisionLock,
      canWrite: vault.canWrite,
      deletionPending: vault.status == 'deleting',
      publishDeviceCapabilities: _publishClientDeviceCapabilities,
      beforeReplaceMergedOperationForTesting:
          beforeReplaceMergedOperationForE2eTesting,
      signerDirectoryCache: _verifiedSignerDirectoryCache,
      signerDirectoryScope: SignerDirectoryCacheScope(
        serverBaseUrl: buildApi.baseUrl,
        serverSpaceId: info.serverSpaceId,
        instanceId: info.instanceId,
        accountId: auth.accountId,
        vaultId: vault.id,
      ),
    );
    _repository = nextRepository;
    _knownHostDecisionGeneration++;
    await nextRepository.updateVaultAccess(
      canWrite: vault.canWrite,
      deletionPending: vault.status == 'deleting',
    );
  }

  Future<void> _retireRepositoryAndTrack(SyncRepository? repository) {
    if (repository == null) return Future<void>.value();
    final existing = _retiredRepositoryDrains[repository];
    if (existing != null) return existing;

    final drain = repository.retireAndWaitForKeyOperations();
    _retiredRepositoryDrains[repository] = drain;
    // Consume an unawaited drain's error while retaining its failed Future in
    // the registry. Cleanup barriers then fail closed instead of wiping keys
    // before a failed drain can prove that its operations are finished.
    unawaited(
      drain.then<void>((_) {
        if (identical(_retiredRepositoryDrains[repository], drain)) {
          _retiredRepositoryDrains.remove(repository);
        }
        _schedulePendingVaultKeyBufferWipe(repository.vaultId);
      }, onError: (_, _) {}),
    );
    return drain;
  }

  Future<void> _waitForRetiredRepositoryDrains({String? vaultId}) async {
    while (true) {
      final pending = _retiredRepositoryDrains.entries
          .where((entry) => vaultId == null || entry.key.vaultId == vaultId)
          .map((entry) => entry.value)
          .toList(growable: false);
      if (pending.isEmpty) return;
      await Future.wait<void>(pending);
    }
  }

  SyncRepository? _repository;
  int _repositoryBuildGeneration = 0;
  String? _publishedDeviceCapabilitiesFor;
  DateTime? _deviceCapabilityRetryAfter;
  String? _publishedRedactionCapabilitiesFor;
  DateTime? _redactionCapabilityRetryAfter;
  Future<void>? _redactionCapabilityPublishInFlight;

  String? get currentSyncInstanceId {
    final repository = _repository;
    return repository?.vaultId == currentVaultId
        ? repository!.instanceId
        : null;
  }

  String? get currentSyncServerSpaceId {
    final repository = _repository;
    return repository?.vaultId == currentVaultId
        ? repository!.serverSpaceId
        : null;
  }

  Future<void> selectVault(String vaultId) async {
    final requestGeneration = ++_vaultSelectionRequestGeneration;
    bool requestIsCurrent() =>
        requestGeneration == _vaultSelectionRequestGeneration;
    if (vaultMembershipBusy || _vaultMembershipChangeActive) {
      throw StateError(currentL10n.youCantSwitchVaultsWhileThe);
    }
    if (snapshotRecoveryActive) {
      throw StateError(currentL10n.youCantSwitchVaultsDuringSnapshot);
    }
    while (_membershipRefreshActive || _membershipRefreshFuture != null) {
      final refresh = _membershipRefreshFuture;
      if (refresh != null) {
        await refresh;
      } else {
        // The active flag is set immediately before its Future is published.
        // Join the refresh once that short publication window closes.
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      if (!requestIsCurrent()) return;
    }
    if (_vaultMembershipChangeActive) {
      throw StateError(currentL10n.youCantSwitchVaultsWhileThe);
    }
    if (snapshotRecoveryActive) {
      throw StateError(currentL10n.youCantSwitchVaultsDuringSnapshot);
    }
    final next = _vaultDescriptors
        .where((item) => item.id == vaultId)
        .firstOrNull;
    if (next == null || !_vaultKeys.containsKey(vaultId)) return;
    if (activeVault?.id == vaultId && _repository?.vaultId == vaultId) return;

    // If this Vault was recently retired, keep the current projection active
    // until its outstanding operations have drained. This is the same-Vault
    // reselect fence: a fresh repository must never overlap its predecessor's
    // serial queue for the same encrypted store.
    await _waitForRetiredRepositoryDrains(vaultId: vaultId);
    if (!requestIsCurrent()) return;
    await _stopAllTerminalCollaboration();
    if (!requestIsCurrent()) return;
    _vaultSelectionGeneration++;
    final selectionGeneration = _vaultSelectionGeneration;
    activeVault = next;
    lastSuccessfulSyncAt = null;
    syncCheckpointServerGeneration = null;
    // The selected sync gate belongs to one repository. Let a new Vault sync
    // immediately while a retired repository finishes its own request; its
    // completion will only complete its local waiter and cannot clear this
    // new pass's state.
    syncing = false;
    _syncAgainRequested = false;
    _activeSyncCompletion = null;
    _activeSyncRepository = null;
    _activeSyncSelectionGeneration = null;
    syncStatus = 'idle';
    errorMessage = null;
    noticeMessage = null;
    pendingCount = 0;
    receivedCount = 0;
    conflictCount = 0;
    unavailableRecordCount = 0;
    hosts.clear();
    _jumpHostRouteIssues.clear();
    _hostGroupReferenceIssues.clear();
    _unavailableGroupRecordIds.clear();
    credentials.clear();
    groups.clear();
    snippets.clear();
    shellHistoryRecords.clear();
    savedWorkspaces.clear();
    activeSavedWorkspaceId = null;
    _workspacePaneTerminalTabIds.clear();
    knownHosts.clear();
    pendingKnownHostRecordIds.clear();
    preferences.clear();
    preferenceError = null;
    _resetDefaultSectionConflictRepair();
    _resetAuditState();
    _stopVaultPresenceHeartbeats(clearState: true);
    _defaultWorkspaceAppliedForVault = false;
    notifyListeners();
    final repositoryBuild = _buildRepository(
      waitForPreviousRepositoryDrain: false,
      expectedVaultSelectionGeneration: selectionGeneration,
    );
    await loadShellHistorySyncPreference();
    if (!requestIsCurrent() ||
        selectionGeneration != _vaultSelectionGeneration) {
      return;
    }
    await repositoryBuild;
    if (!requestIsCurrent() ||
        selectionGeneration != _vaultSelectionGeneration) {
      return;
    }
    await reloadRecords();
    if (!requestIsCurrent() ||
        selectionGeneration != _vaultSelectionGeneration) {
      return;
    }
    await refreshSyncStatus();
    if (!requestIsCurrent() ||
        selectionGeneration != _vaultSelectionGeneration) {
      return;
    }
    _startSyncHints();
    _startVaultPresenceHeartbeats();
    if (page == WorkspacePage.audit) unawaited(loadAudit());
    notifyListeners();
  }

  Future<void> reloadRecords() async {
    final repository = _repository;
    if (repository == null) return;
    final loadedVaultId = activeVault?.id;
    final selectionGeneration = _vaultSelectionGeneration;
    final loadGeneration = ++_recordsLoadGeneration;
    _traceSafeTeamLifecycle('records.load.start');
    final rows =
        await (loadRecordsForTesting?.call(repository) ??
            repository.loadRecords());
    _traceSafeTeamLifecycle('records.load.done');
    if (!identical(_repository, repository) ||
        activeVault?.id != loadedVaultId ||
        selectionGeneration != _vaultSelectionGeneration ||
        loadGeneration != _recordsLoadGeneration) {
      return;
    }
    List<PendingDefaultPreferenceRepair> pendingPreferenceRepairs = const [];
    var preferenceRepairScanFailed = false;
    try {
      _traceSafeTeamLifecycle('records.preference_repairs.start');
      pendingPreferenceRepairs = await repository
          .unconfirmedPreferenceRepairs();
      _traceSafeTeamLifecycle('records.preference_repairs.done');
    } catch (_) {
      // An unreadable repair marker cannot certify that optimistic local
      // tombstones reached the server. Keep preference changes locked.
      preferenceRepairScanFailed = true;
    }
    if (!identical(_repository, repository) ||
        activeVault?.id != loadedVaultId ||
        selectionGeneration != _vaultSelectionGeneration ||
        loadGeneration != _recordsLoadGeneration) {
      return;
    }
    _traceSafeTeamLifecycle('records.pending_operations.start');
    final pendingRecordIds = (await repository.database.allPendingOperations(
      repository.vaultId,
      instanceId: repository.instanceId,
      serverSpaceId: repository.serverSpaceId,
    )).map((operation) => operation.recordId).toSet();
    _traceSafeTeamLifecycle('records.pending_operations.done');
    if (!identical(_repository, repository) ||
        activeVault?.id != loadedVaultId ||
        selectionGeneration != _vaultSelectionGeneration ||
        loadGeneration != _recordsLoadGeneration) {
      return;
    }
    unavailableRecordCount = repository.unavailableRecordIds.length;
    final unavailableGroupRecordIds = <String>{};
    pendingKnownHostRecordIds
      ..clear()
      ..addAll(
        rows
            .where((row) => row['type'] == 'knownHost')
            .map((row) => row['_record_id'] ?? row['id'])
            .whereType<String>()
            .where(pendingRecordIds.contains),
      );
    hosts.clear();
    _jumpHostRouteIssues.clear();
    credentials.clear();
    groups.clear();
    snippets.clear();
    shellHistoryRecords.clear();
    savedWorkspaces.clear();
    knownHosts.clear();
    preferences.clear();
    preferenceError = null;
    _unsupportedVaultPreferencePresent = false;
    String? unsupportedPreferenceError;
    _revisionIds.clear();
    for (final row in rows) {
      final type = row['type'];
      final id = row['_record_id'] ?? row['id'];
      final revision = row['_revision_id'];
      try {
        switch (type) {
          case 'host':
            final record = HostRecord.fromJson({
              ...row,
              if (id is String) 'id': id,
              'revision_id': revision,
            });
            hosts.add(record);
            if (revision is String) _revisionIds[record.id] = revision;
          case 'credential':
            final record = CredentialRecord.fromJson({
              ...row,
              if (id is String) 'id': id,
              'revision_id': revision,
            });
            credentials.add(record);
            if (revision is String) _revisionIds[record.id] = revision;
          case 'group':
            final group = GroupRecord.fromJson(row);
            groups.add(group);
            if (revision is String) _revisionIds[group.id] = revision;
          case 'snippet':
            final record = SnippetRecord.fromJson({
              ...row,
              if (id is String) 'id': id,
              'revision_id': revision,
            });
            snippets.add(record);
            if (revision is String) _revisionIds[record.id] = revision;
          case 'knownHost':
            final record = KnownHostRecord.fromJson(row);
            knownHosts.add(record);
            if (revision is String) _revisionIds[record.id] = revision;
          case 'preference':
            final record = VaultPreferenceRecord.fromJson(row);
            preferences.add(record);
            if (revision is String) _revisionIds[record.id] = revision;
          case 'workspace':
            final record = WorkspaceRecord.fromJson(row);
            savedWorkspaces.add(record);
            if (revision is String) _revisionIds[record.id] = revision;
          case 'shellHistory':
            shellHistoryRecords.add(
              ShellHistoryRecord.fromJson({...row, if (id is String) 'id': id}),
            );
          default:
            // Unknown/future types remain encrypted in the repository. Make
            // their omission visible and never expose a revision for editing.
            unavailableRecordCount++;
        }
      } on FormatException {
        if (type == 'group' && id is String) {
          unavailableGroupRecordIds.add(id);
        }
        if (type == 'preference') {
          unsupportedPreferenceError ??=
              currentL10n.thisVaultContainsPreferencesThatThis;
        }
        unavailableRecordCount++;
      } on TypeError {
        if (type == 'group' && id is String) {
          unavailableGroupRecordIds.add(id);
        }
        if (type == 'preference') {
          unsupportedPreferenceError ??=
              currentL10n.thisVaultContainsPreferencesThatThis;
        }
        unavailableRecordCount++;
      }
    }
    if (activeSavedWorkspaceId != null &&
        !savedWorkspaces.any((item) => item.id == activeSavedWorkspaceId)) {
      _workspacePaneTerminalTabIds.remove(activeSavedWorkspaceId);
      activeSavedWorkspaceId = null;
    }
    final workspacePreferences = preferences
        .where((item) => item.isDefaultWorkspaceSection)
        .toList(growable: false);
    _unsupportedVaultPreferencePresent = unsupportedPreferenceError != null;
    _preferenceRepairScanFailed = preferenceRepairScanFailed;
    const supportedPreferenceTuples =
        <({String scope, String key, String platformFamily})>[
          (
            scope: VaultPreferenceRecord.workspaceScope,
            key: VaultPreferenceRecord.defaultSectionKey,
            platformFamily: VaultPreferenceRecord.allPlatforms,
          ),
          (
            scope: VaultPreferenceRecord.workspaceScope,
            key: VaultPreferenceRecord.terminalFontSizeKey,
            platformFamily: VaultPreferenceRecord.allPlatforms,
          ),
          (
            scope: VaultPreferenceRecord.workspaceScope,
            key: VaultPreferenceRecord.terminalThemeKey,
            platformFamily: VaultPreferenceRecord.allPlatforms,
          ),
          (
            scope: VaultPreferenceRecord.workspaceScope,
            key: VaultPreferenceRecord.terminalShortcutsKey,
            platformFamily: VaultPreferenceRecord.allPlatforms,
          ),
        ];
    var databasePendingCount = -1;
    for (final tuple in supportedPreferenceTuples) {
      final tupleKey = _preferenceTupleKey(
        tuple.scope,
        tuple.key,
        tuple.platformFamily,
      );
      final state = _preferenceConflicts.putIfAbsent(
        tupleKey,
        _PreferenceTupleConflictState.new,
      );
      final candidates = preferences
          .where(
            (item) =>
                item.scope == tuple.scope &&
                item.key == tuple.key &&
                item.platformFamily == tuple.platformFamily,
          )
          .toList(growable: false);
      final pendingMarkers = pendingPreferenceRepairs
          .where(
            (marker) =>
                marker.scope == tuple.scope &&
                marker.key == tuple.key &&
                marker.platformFamily == tuple.platformFamily,
          )
          .toList(growable: false);
      state.candidates
        ..clear()
        ..addAll(candidates);

      if (candidates.length > 1) {
        state.observedServerViewRevision ??=
            repository.verifiedServerViewRevision;
        state.repairRequired = true;
        state.observedCandidateIds.addAll(candidates.map((item) => item.id));
      }
      if (pendingMarkers.isNotEmpty) {
        state.observedServerViewRevision ??=
            repository.verifiedServerViewRevision;
        state.repairRequired = true;
        final retainedIds = pendingMarkers
            .map((repair) => repair.retainedRecordId)
            .toSet();
        state.retainedRecordId = retainedIds.length == 1
            ? retainedIds.single
            : null;
        if (retainedIds.length > 1) {
          // Conflicting durable repair markers need deliberate recovery. A
          // later singleton pull cannot choose the intended record.
          state.markerConflictBlocked = true;
        }
      }
      if (preferenceRepairScanFailed &&
          (state.repairRequired ||
              candidates.length > 1 ||
              pendingMarkers.isNotEmpty)) {
        state.observedServerViewRevision ??=
            repository.verifiedServerViewRevision;
        state.repairRequired = true;
        state.verificationBlocked = true;
        // A failed marker scan invalidates prior candidate observations as
        // evidence for automatic singleton recovery. Once scanning succeeds,
        // the user must explicitly choose the retained ID and complete a
        // full readback before the latch can clear.
        state.observedCandidateIds.clear();
      } else {
        state.verificationBlocked = state.markerConflictBlocked;
      }

      if (state.repairRequired &&
          !state.repairBusy &&
          !state.verificationBlocked &&
          !preferenceRepairScanFailed &&
          unsupportedPreferenceError == null &&
          pendingMarkers.isEmpty &&
          candidates.length == 1 &&
          (state.observedServerViewRevision == null ||
              repository.verifiedServerViewRevision >
                  state.observedServerViewRevision!) &&
          syncStatus == 'idle') {
        databasePendingCount = databasePendingCount < 0
            ? await database.countPending(
                loadedVaultId ?? repository.vaultId,
                instanceId: repository.instanceId,
                serverSpaceId: repository.serverSpaceId,
              )
            : databasePendingCount;
        if (databasePendingCount == 0 &&
            (state.observedCandidateIds.contains(candidates.single.id) ||
                state.retainedRecordId == candidates.single.id)) {
          // A new full pull proved this tuple has exactly one candidate and no
          // repair outbox remains. Clear only this tuple's latch.
          _preferenceConflicts.remove(tupleKey);
        }
      }
    }
    _traceSafeTeamLifecycle('records.preference_projection.done');
    final defaultConflict =
        _preferenceConflicts[_preferenceTupleKey(
          VaultPreferenceRecord.workspaceScope,
          VaultPreferenceRecord.defaultSectionKey,
          VaultPreferenceRecord.allPlatforms,
        )];
    final fontConflict =
        _preferenceConflicts[_preferenceTupleKey(
          VaultPreferenceRecord.workspaceScope,
          VaultPreferenceRecord.terminalFontSizeKey,
          VaultPreferenceRecord.allPlatforms,
        )];
    final themeConflict =
        _preferenceConflicts[_preferenceTupleKey(
          VaultPreferenceRecord.workspaceScope,
          VaultPreferenceRecord.terminalThemeKey,
          VaultPreferenceRecord.allPlatforms,
        )];
    if (unsupportedPreferenceError != null) {
      preferenceError = unsupportedPreferenceError;
    } else if (preferenceRepairScanFailed) {
      preferenceError = currentL10n.thePreferenceRepairStateCantBe;
    } else if (defaultConflict?.repairRequired == true) {
      preferenceError = currentL10n.theDefaultWorkspacePreferenceInThis;
    } else if (fontConflict?.repairRequired == true) {
      preferenceError = currentL10n.theTerminalFontSizePreferenceIn;
    } else if (themeConflict?.repairRequired == true) {
      preferenceError = currentL10n.theTerminalColorPreferenceInThis;
    } else if (_terminalShortcutsConflictState.repairRequired) {
      preferenceError = currentL10n.theTerminalShortcutPreferenceInThis;
    } else {
      preferenceError = null;
    }
    if (!_defaultWorkspaceAppliedForVault &&
        stage == ClientStage.workspace &&
        workspacePreferences.length == 1 &&
        !preferenceRepairScanFailed &&
        defaultConflict?.repairRequired != true) {
      // A newly authorized device may receive this record in its first sync,
      // after the initial unlock reload. Leave the flag clear while there is
      // no preference so that reload can apply it once it arrives. Explicit
      // navigation marks the choice as handled below.
      _defaultWorkspaceAppliedForVault = true;
      page = _workspacePageForPreference(workspacePreferences.single.value);
    }
    hosts.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _rebuildJumpHostRouteIssues();
    _unavailableGroupRecordIds
      ..clear()
      ..addAll(unavailableGroupRecordIds);
    _rebuildHostGroupReferenceIssues();
    credentials.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    snippets.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    savedWorkspaces.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    knownHosts.sort((a, b) {
      final endpoint = a.endpoint.compareTo(b.endpoint);
      return endpoint != 0 ? endpoint : a.id.compareTo(b.id);
    });
    shellHistoryRecords.sort((a, b) {
      final time = a.completedAtMs.compareTo(b.completedAtMs);
      return time == 0 ? a.id.compareTo(b.id) : time;
    });
    _traceSafeTeamLifecycle('records.notify.start');
    notifyListeners();
    _traceSafeTeamLifecycle('records.notify.done');
  }

  String get defaultWorkspaceSection {
    final matches = preferences
        .where((item) => item.isDefaultWorkspaceSection)
        .toList(growable: false);
    if (matches.length != 1) return 'hosts';
    return matches.single.value;
  }

  WorkspacePage _workspacePageForPreference(String section) =>
      switch (section) {
        'hosts' => WorkspacePage.hosts,
        'groups' => WorkspacePage.groups,
        'credentials' => WorkspacePage.credentials,
        'snippets' => WorkspacePage.snippets,
        _ => WorkspacePage.hosts,
      };

  Future<WorkspacePreferenceSaveOutcome> saveWorkspaceDefaultSection(
    String section,
  ) async {
    _assertEditsAllowed(requireWritableVault: true);
    if (hasDefaultSectionPreferenceConflict || preferenceError != null) {
      throw StateError(currentL10n.theDefaultWorkspacePreferenceNeedsAn);
    }
    if (activeVault?.canWrite != true || activeVault?.status != 'active') {
      throw StateError(currentL10n.theCurrentVaultIsReadOnly);
    }
    final targetVaultId = activeVault?.id;
    if (targetVaultId == null) throw StateError(currentL10n.chooseAVaultFirst);
    final repository = _requireRepository();
    final existing = _workspacePreferenceRecord();
    final record = VaultPreferenceRecord.defaultWorkspaceSection(
      value: section,
      id: existing?.id,
    );
    final baseRevisionId = existing == null
        ? null
        : _revisionIds[existing.id] ?? existing.revisionId;
    final envelope = await repository.saveRecord(
      recordId: record.id,
      plaintext: record.toJson(),
      baseRevisionId: baseRevisionId,
      operation: existing == null ? 'create' : 'update',
    );
    // Vault selection and logout may run while encryption/database I/O is in
    // flight. The operation remains safely queued for its captured Vault, but
    // its result must not leak into a different Vault's in-memory view.
    if (activeVault?.id != targetVaultId ||
        !identical(_repository, repository)) {
      return WorkspacePreferenceSaveOutcome.queuedInOriginalVault;
    }
    final revisionId =
        (envelope['header'] as Map<String, dynamic>)['revision_id'] as String;
    _revisionIds[record.id] = revisionId;
    final saved = record.copyWith(revisionId: revisionId);
    preferences
      ..removeWhere((item) => item.isDefaultWorkspaceSection)
      ..add(saved);
    preferenceError = null;
    _setNotice(currentL10n.defaultWorkspacePreferenceSavedEncryptedIt);
    await refreshSyncStatus();
    if (activeVault?.id != targetVaultId ||
        !identical(_repository, repository)) {
      return WorkspacePreferenceSaveOutcome.queuedInOriginalVault;
    }
    _automaticSync.scheduleEdit();
    notifyListeners();
    return WorkspacePreferenceSaveOutcome.savedToActiveVault;
  }

  Future<WorkspacePreferenceSaveOutcome> saveTerminalFontSizePreference(
    int fontSize,
  ) async {
    _assertEditsAllowed(requireWritableVault: true);
    if (hasTerminalFontSizePreferenceConflict || preferenceError != null) {
      throw StateError(currentL10n.theTerminalFontSizePreferenceNeeds);
    }
    if (activeVault?.canWrite != true || activeVault?.status != 'active') {
      throw StateError(currentL10n.theCurrentVaultIsReadOnly);
    }
    final targetVaultId = activeVault?.id;
    if (targetVaultId == null) throw StateError(currentL10n.chooseAVaultFirst);
    final repository = _requireRepository();
    final existing = _terminalFontSizePreferenceRecord();
    final record = VaultPreferenceRecord.terminalFontSize(
      fontSize: fontSize,
      id: existing?.id,
    );
    final baseRevisionId = existing == null
        ? null
        : _revisionIds[existing.id] ?? existing.revisionId;
    final envelope = await repository.saveRecord(
      recordId: record.id,
      plaintext: record.toJson(),
      baseRevisionId: baseRevisionId,
      operation: existing == null ? 'create' : 'update',
    );
    if (activeVault?.id != targetVaultId ||
        !identical(_repository, repository)) {
      return WorkspacePreferenceSaveOutcome.queuedInOriginalVault;
    }
    final revisionId =
        (envelope['header'] as Map<String, dynamic>)['revision_id'] as String;
    _revisionIds[record.id] = revisionId;
    final saved = record.copyWith(revisionId: revisionId);
    preferences
      ..removeWhere((item) => item.isTerminalFontSize)
      ..add(saved);
    preferenceError = null;
    _setNotice(currentL10n.terminalFontSizePreferenceSavedEncrypted);
    await refreshSyncStatus();
    if (activeVault?.id != targetVaultId ||
        !identical(_repository, repository)) {
      return WorkspacePreferenceSaveOutcome.queuedInOriginalVault;
    }
    _automaticSync.scheduleEdit();
    notifyListeners();
    return WorkspacePreferenceSaveOutcome.savedToActiveVault;
  }

  Future<WorkspacePreferenceSaveOutcome> saveTerminalThemePreference(
    VaultTerminalThemeChoice theme,
  ) async {
    _assertEditsAllowed(requireWritableVault: true);
    if (hasTerminalThemePreferenceConflict || preferenceError != null) {
      throw StateError(currentL10n.theTerminalColorPreferenceNeedsAn);
    }
    if (activeVault?.canWrite != true || activeVault?.status != 'active') {
      throw StateError(currentL10n.theCurrentVaultIsReadOnly);
    }
    final targetVaultId = activeVault?.id;
    if (targetVaultId == null) throw StateError(currentL10n.chooseAVaultFirst);
    final repository = _requireRepository();
    final existing = _terminalThemePreferenceRecord();
    final record = VaultPreferenceRecord.terminalTheme(
      theme: theme,
      id: existing?.id,
    );
    final baseRevisionId = existing == null
        ? null
        : _revisionIds[existing.id] ?? existing.revisionId;
    final envelope = await repository.saveRecord(
      recordId: record.id,
      plaintext: record.toJson(),
      baseRevisionId: baseRevisionId,
      operation: existing == null ? 'create' : 'update',
    );
    if (activeVault?.id != targetVaultId ||
        !identical(_repository, repository)) {
      return WorkspacePreferenceSaveOutcome.queuedInOriginalVault;
    }
    final revisionId =
        (envelope['header'] as Map<String, dynamic>)['revision_id'] as String;
    _revisionIds[record.id] = revisionId;
    final saved = record.copyWith(revisionId: revisionId);
    preferences
      ..removeWhere((item) => item.isTerminalTheme)
      ..add(saved);
    preferenceError = null;
    _setNotice(currentL10n.terminalColorPreferenceSavedEncryptedIt);
    await refreshSyncStatus();
    if (activeVault?.id != targetVaultId ||
        !identical(_repository, repository)) {
      return WorkspacePreferenceSaveOutcome.queuedInOriginalVault;
    }
    _automaticSync.scheduleEdit();
    notifyListeners();
    return WorkspacePreferenceSaveOutcome.savedToActiveVault;
  }

  List<WindowCombination> get windowCombinations {
    final matches = preferences
        .where(
          (p) =>
              p.scope == 'workspace' &&
              p.key == VaultPreferenceRecord.windowCombinationsKey &&
              p.platformFamily == 'all',
        )
        .toList();
    if (matches.length > 1) throw StateError(currentL10n.theWindowSetHasASync);
    return matches.isEmpty
        ? []
        : WindowCombination.decode(matches.single.value);
  }

  bool _savingWindowCombinations = false;
  Future<void> saveWindowCombinations(List<WindowCombination> values) async {
    if (_savingWindowCombinations) {
      throw StateError(currentL10n.theWindowSetIsBeingSaved);
    }
    _savingWindowCombinations = true;
    try {
      _assertEditsAllowed(requireWritableVault: true);
      if (preferenceError != null) {
        throw StateError(currentL10n.resolveThePreferenceReadErrorFirst);
      }
      final target = activeVault?.id;
      if (target == null ||
          activeVault?.canWrite != true ||
          activeVault?.status != 'active') {
        throw StateError(currentL10n.theCurrentVaultIsntWritable);
      }
      windowCombinations; // Refuse ambiguous duplicate tuples.
      final existing = preferences
          .where((p) => p.key == VaultPreferenceRecord.windowCombinationsKey)
          .firstOrNull;
      final record = VaultPreferenceRecord.windowCombinations(
        value: WindowCombination.encode(values),
        id: existing?.id,
      );
      final repository = _requireRepository();
      final envelope = await repository.saveRecord(
        recordId: record.id,
        plaintext: record.toJson(),
        baseRevisionId: existing == null
            ? null
            : _revisionIds[existing.id] ?? existing.revisionId,
        operation: existing == null ? 'create' : 'update',
      );
      if (activeVault?.id != target || !identical(_repository, repository))
        return;
      final revision =
          (envelope['header'] as Map<String, dynamic>)['revision_id'] as String;
      _revisionIds[record.id] = revision;
      preferences
        ..removeWhere(
          (p) => p.key == VaultPreferenceRecord.windowCombinationsKey,
        )
        ..add(record.copyWith(revisionId: revision));
      _automaticSync.scheduleEdit();
      notifyListeners();
    } finally {
      _savingWindowCombinations = false;
    }
  }

  Future<WorkspacePreferenceSaveOutcome> saveTerminalShortcutsPreference(
    TerminalShortcutBindings bindings,
  ) async {
    _assertEditsAllowed(requireWritableVault: true);
    if (hasTerminalShortcutsPreferenceConflict || preferenceError != null) {
      throw StateError(currentL10n.theTerminalShortcutPreferenceNeedsAn);
    }
    if (activeVault?.canWrite != true || activeVault?.status != 'active') {
      throw StateError(currentL10n.theCurrentVaultIsReadOnly);
    }
    final targetVaultId = activeVault?.id;
    if (targetVaultId == null) throw StateError(currentL10n.chooseAVaultFirst);
    final repository = _requireRepository();
    final existing = _terminalShortcutsPreferenceRecord();
    final record = VaultPreferenceRecord.terminalShortcuts(
      bindings: bindings,
      id: existing?.id,
    );
    final baseRevisionId = existing == null
        ? null
        : _revisionIds[existing.id] ?? existing.revisionId;
    final envelope = await repository.saveRecord(
      recordId: record.id,
      plaintext: record.toJson(),
      baseRevisionId: baseRevisionId,
      operation: existing == null ? 'create' : 'update',
    );
    if (activeVault?.id != targetVaultId ||
        !identical(_repository, repository)) {
      return WorkspacePreferenceSaveOutcome.queuedInOriginalVault;
    }
    final revisionId =
        (envelope['header'] as Map<String, dynamic>)['revision_id'] as String;
    _revisionIds[record.id] = revisionId;
    final saved = record.copyWith(revisionId: revisionId);
    preferences
      ..removeWhere((item) => item.isTerminalShortcuts)
      ..add(saved);
    preferenceError = null;
    _setNotice(currentL10n.terminalShortcutPreferenceSavedEncryptedIt);
    await refreshSyncStatus();
    if (activeVault?.id != targetVaultId ||
        !identical(_repository, repository)) {
      return WorkspacePreferenceSaveOutcome.queuedInOriginalVault;
    }
    _automaticSync.scheduleEdit();
    notifyListeners();
    return WorkspacePreferenceSaveOutcome.savedToActiveVault;
  }

  /// Resolves duplicate synced default-section records after the user chooses
  /// the record ID to keep.
  Future<void> repairDefaultWorkspaceSectionConflict({
    required String retainedRecordId,
  }) => _repairPreferenceTupleConflict(
    scope: VaultPreferenceRecord.workspaceScope,
    key: VaultPreferenceRecord.defaultSectionKey,
    platformFamily: VaultPreferenceRecord.allPlatforms,
    retainedRecordId: retainedRecordId,
  );

  /// Resolves duplicate synced terminal-font-size records by the record ID
  /// explicitly chosen by the user.
  Future<void> repairTerminalFontSizePreferenceConflict({
    required String retainedRecordId,
  }) => _repairPreferenceTupleConflict(
    scope: VaultPreferenceRecord.workspaceScope,
    key: VaultPreferenceRecord.terminalFontSizeKey,
    platformFamily: VaultPreferenceRecord.allPlatforms,
    retainedRecordId: retainedRecordId,
  );

  /// Resolves duplicate synced terminal-theme records by the record ID
  /// explicitly chosen by the user.
  Future<void> repairTerminalThemePreferenceConflict({
    required String retainedRecordId,
  }) => _repairPreferenceTupleConflict(
    scope: VaultPreferenceRecord.workspaceScope,
    key: VaultPreferenceRecord.terminalThemeKey,
    platformFamily: VaultPreferenceRecord.allPlatforms,
    retainedRecordId: retainedRecordId,
  );

  /// Resolves duplicate terminal-shortcut records by retaining the record ID
  /// chosen explicitly by the user and syncing encrypted tombstones for the
  /// other branches.
  Future<void> repairTerminalShortcutsPreferenceConflict({
    required String retainedRecordId,
  }) => _repairPreferenceTupleConflict(
    scope: VaultPreferenceRecord.workspaceScope,
    key: VaultPreferenceRecord.terminalShortcutsKey,
    platformFamily: VaultPreferenceRecord.allPlatforms,
    retainedRecordId: retainedRecordId,
  );

  Future<void> _repairPreferenceTupleConflict({
    required String scope,
    required String key,
    required String platformFamily,
    required String retainedRecordId,
  }) async {
    final tupleState = _preferenceConflictState(scope, key, platformFamily);
    final label = switch (key) {
      VaultPreferenceRecord.defaultSectionKey => currentL10n.defaultWorkspace,
      VaultPreferenceRecord.terminalThemeKey => currentL10n.terminalColors,
      VaultPreferenceRecord.terminalShortcutsKey =>
        currentL10n.terminalShortcuts,
      _ => currentL10n.terminalFontSize,
    };
    if (_preferenceConflicts.values.any((state) => state.repairBusy)) {
      throw StateError(currentL10n.aPreferenceRepairIsInProgress);
    }
    _assertEditsAllowed(requireWritableVault: true);
    final selectedVault = activeVault;
    final repository = _repository;
    final vaultId = selectedVault?.id;
    if (selectedVault == null ||
        vaultId == null ||
        selectedVault.canWrite != true ||
        selectedVault.status != 'active' ||
        repository == null ||
        repository.vaultId != vaultId ||
        !repository.canWrite ||
        repository.deletionPending) {
      throw StateError(currentL10n.theCurrentVaultIsntWritableSo(label));
    }
    if (!tupleState.repairRequired) {
      throw StateError(currentL10n.thereAreNoPendingLabelPreference(label));
    }
    if (_unsupportedVaultPreferencePresent) {
      throw StateError(
        currentL10n.thisVaultContainsUnsupportedPreferenceRecords,
      );
    }
    if (_preferenceRepairScanFailed || tupleState.verificationBlocked) {
      throw StateError(currentL10n.thePreferenceRepairStateCantBe2);
    }
    final selected = tupleState.candidates
        .where((candidate) => candidate.id == retainedRecordId)
        .firstOrNull;
    if (selected == null) {
      throw StateError(currentL10n.chooseALabelPreferenceFromThe(label));
    }
    final pinnedRetainedId = tupleState.retainedRecordId;
    if (pinnedRetainedId != null && pinnedRetainedId != retainedRecordId) {
      throw StateError(currentL10n.anExistingRepairTombstoneAlreadySpecifies);
    }
    final selectionGeneration = _vaultSelectionGeneration;
    final displayedCandidates = _preferenceCandidateState(
      tupleState.candidates,
    );
    final selectedValue = selected.value;
    tupleState.repairBusy = true;
    tupleState.retainedRecordId = retainedRecordId;
    notifyListeners();
    try {
      final markersBeforeSync = await repository.unconfirmedPreferenceRepairs();
      _ensurePreferenceRepairContext(
        repository: repository,
        vaultId: vaultId,
        selectionGeneration: selectionGeneration,
      );
      if (markersBeforeSync.any(
        (marker) =>
            _repairMarkerMatchesTuple(
              marker,
              scope: scope,
              key: key,
              platformFamily: platformFamily,
            ) &&
            marker.retainedRecordId != retainedRecordId,
      )) {
        throw StateError(currentL10n.theRecordRetainedByAnExisting);
      }

      await _verifiedPreferenceRepairSync(
        repository: repository,
        vaultId: vaultId,
        selectionGeneration: selectionGeneration,
      );
      var pendingMarkers = _matchingPreferenceRepairMarkers(
        await repository.unconfirmedPreferenceRepairs(),
        scope: scope,
        key: key,
        platformFamily: platformFamily,
      );
      if (pendingMarkers.isNotEmpty) {
        // A push happens after that pass's pull. A second complete pass must
        // observe the acknowledged tombstone through the current cursor.
        await _verifiedPreferenceRepairSync(
          repository: repository,
          vaultId: vaultId,
          selectionGeneration: selectionGeneration,
        );
        pendingMarkers = _matchingPreferenceRepairMarkers(
          await repository.unconfirmedPreferenceRepairs(),
          scope: scope,
          key: key,
          platformFamily: platformFamily,
        );
      }
      if (pendingMarkers.isNotEmpty) {
        throw StateError(currentL10n.theRepairTombstoneHasntBeenConfirmed);
      }

      final currentCandidates = _currentPreferenceRecords(
        scope: scope,
        key: key,
        platformFamily: platformFamily,
      );
      final currentState = _preferenceCandidateState(currentCandidates);
      if (!_samePreferenceCandidateState(displayedCandidates, currentState)) {
        // New rows or changed values/revisions require a fresh explicit user
        // choice. No tombstones have been written in this pass.
        throw StateError(currentL10n.theConflictCandidatesOrVersionsChanged);
      }
      if (currentCandidates.isEmpty ||
          !currentCandidates.any(
            (candidate) =>
                candidate.id == retainedRecordId &&
                candidate.value == selectedValue,
          )) {
        throw StateError(currentL10n.theSelectedRetainedRecordChangedCheck);
      }
      for (final candidate in currentCandidates) {
        final currentRevision = _revisionIds[candidate.id];
        if (candidate.revisionId == null ||
            currentRevision == null ||
            candidate.revisionId != currentRevision) {
          throw StateError(currentL10n.theCandidateRecordIsMissingA);
        }
      }

      if (currentCandidates.length == 1 &&
          currentCandidates.single.id == retainedRecordId) {
        _preferenceConflicts.remove(
          _preferenceTupleKey(scope, key, platformFamily),
        );
        _refreshPreferenceError();
        _setNotice(currentL10n.theLabelPreferenceConflictWasConfirmed(label));
        notifyListeners();
        return;
      }

      for (final candidate in currentCandidates) {
        if (candidate.id == retainedRecordId) continue;
        _ensurePreferenceRepairContext(
          repository: repository,
          vaultId: vaultId,
          selectionGeneration: selectionGeneration,
        );
        await repository.saveRecord(
          recordId: candidate.id,
          baseRevisionId: candidate.revisionId,
          operation: 'delete',
          plaintext: {
            'id': candidate.id,
            'type': 'preference',
            'deleted': true,
            'preference_conflict_repair': {
              'version': 1,
              'kind': 'duplicate_preference_tuple',
              'scope': scope,
              'key': key,
              'platform_family': platformFamily,
              'retained_record_id': retainedRecordId,
            },
          },
        );
      }

      await _verifiedPreferenceRepairSync(
        repository: repository,
        vaultId: vaultId,
        selectionGeneration: selectionGeneration,
      );
      pendingMarkers = _matchingPreferenceRepairMarkers(
        await repository.unconfirmedPreferenceRepairs(),
        scope: scope,
        key: key,
        platformFamily: platformFamily,
      );
      if (pendingMarkers.isNotEmpty) {
        await _verifiedPreferenceRepairSync(
          repository: repository,
          vaultId: vaultId,
          selectionGeneration: selectionGeneration,
        );
        pendingMarkers = _matchingPreferenceRepairMarkers(
          await repository.unconfirmedPreferenceRepairs(),
          scope: scope,
          key: key,
          platformFamily: platformFamily,
        );
      }
      if (pendingMarkers.isNotEmpty) {
        throw StateError(currentL10n.theDeletionTombstoneIsStillWaiting);
      }
      final finalCandidates = _currentPreferenceRecords(
        scope: scope,
        key: key,
        platformFamily: platformFamily,
      );
      if (finalCandidates.length != 1 ||
          finalCandidates.single.id != retainedRecordId ||
          finalCandidates.single.value != selectedValue ||
          finalCandidates.single.revisionId == null ||
          _revisionIds[retainedRecordId] != finalCandidates.single.revisionId ||
          await repository.database.countPending(
                vaultId,
                instanceId: repository.instanceId,
                serverSpaceId: repository.serverSpaceId,
              ) !=
              0 ||
          syncStatus != 'idle') {
        throw StateError(currentL10n.theServerHasntConfirmedThatOnly(label));
      }

      _preferenceConflicts.remove(
        _preferenceTupleKey(scope, key, platformFamily),
      );
      _refreshPreferenceError();
      _setNotice(currentL10n.theLabelPreferenceConflictWasRepaired(label));
      notifyListeners();
    } catch (_) {
      if (identical(_repository, repository) &&
          activeVault?.id == vaultId &&
          _vaultSelectionGeneration == selectionGeneration) {
        tupleState.observedServerViewRevision ??=
            repository.verifiedServerViewRevision;
        tupleState.repairRequired = true;
        _refreshPreferenceError();
      }
      rethrow;
    } finally {
      if (identical(_repository, repository) &&
          activeVault?.id == vaultId &&
          _vaultSelectionGeneration == selectionGeneration) {
        tupleState.repairBusy = false;
        notifyListeners();
      }
    }
  }

  List<VaultPreferenceRecord> _currentPreferenceRecords({
    required String scope,
    required String key,
    required String platformFamily,
  }) => preferences
      .where(
        (item) =>
            item.scope == scope &&
            item.key == key &&
            item.platformFamily == platformFamily,
      )
      .toList(growable: false);

  List<PendingDefaultPreferenceRepair> _matchingPreferenceRepairMarkers(
    Iterable<PendingDefaultPreferenceRepair> markers, {
    required String scope,
    required String key,
    required String platformFamily,
  }) => markers
      .where(
        (marker) => _repairMarkerMatchesTuple(
          marker,
          scope: scope,
          key: key,
          platformFamily: platformFamily,
        ),
      )
      .toList(growable: false);

  bool _repairMarkerMatchesTuple(
    PendingDefaultPreferenceRepair marker, {
    required String scope,
    required String key,
    required String platformFamily,
  }) =>
      marker.scope == scope &&
      marker.key == key &&
      marker.platformFamily == platformFamily;

  void _refreshPreferenceError() {
    if (_unsupportedVaultPreferencePresent) {
      preferenceError = currentL10n.thisVaultContainsPreferencesThatThis;
      return;
    }
    if (_preferenceRepairScanFailed) {
      preferenceError = currentL10n.thePreferenceRepairStateCantBe;
      return;
    }
    final conflict = _preferenceConflicts.entries
        .where((entry) => entry.value.repairRequired)
        .firstOrNull;
    if (conflict == null) {
      preferenceError = null;
      return;
    }
    final tuple = conflict.key.split('\u0000');
    final key = tuple.length > 1 ? tuple[1] : '';
    preferenceError = switch (key) {
      VaultPreferenceRecord.defaultSectionKey =>
        currentL10n.theDefaultWorkspacePreferenceInThis,
      VaultPreferenceRecord.terminalThemeKey =>
        currentL10n.theTerminalColorPreferenceInThis,
      VaultPreferenceRecord.terminalShortcutsKey =>
        currentL10n.theTerminalShortcutPreferenceInThis,
      _ => currentL10n.theTerminalFontSizePreferenceIn,
    };
  }

  Map<String, String> _preferenceCandidateState(
    Iterable<VaultPreferenceRecord> candidates,
  ) => {
    for (final candidate in candidates)
      candidate.id:
          '${candidate.value}\u0000${_revisionIds[candidate.id] ?? candidate.revisionId ?? ''}',
  };

  bool _samePreferenceCandidateState(
    Map<String, String> left,
    Map<String, String> right,
  ) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (right[entry.key] != entry.value) return false;
    }
    return true;
  }

  void _ensurePreferenceRepairContext({
    required SyncRepository repository,
    required String vaultId,
    required int selectionGeneration,
  }) {
    if (!identical(_repository, repository) ||
        _repository?.vaultId != vaultId ||
        activeVault?.id != vaultId ||
        _vaultSelectionGeneration != selectionGeneration) {
      throw StateError(currentL10n.theVaultWasSwitchedThePreference);
    }
  }

  Future<void> _verifiedPreferenceRepairSync({
    required SyncRepository repository,
    required String vaultId,
    required int selectionGeneration,
  }) async {
    if (syncing) {
      final active = _activeSyncCompletion;
      if (active == null) {
        throw StateError(currentL10n.aSyncIsStillRunningRetry);
      }
      await active.future.timeout(const Duration(seconds: 30));
    }
    if (syncing) {
      throw StateError(currentL10n.anotherSyncTaskIsStillRunning);
    }
    _ensurePreferenceRepairContext(
      repository: repository,
      vaultId: vaultId,
      selectionGeneration: selectionGeneration,
    );
    final before = repository.verifiedServerViewRevision;
    try {
      // Route repair syncs through the controller queue. An automatic pass
      // can start after the check above while the repository acquires its
      // key-operation lease; the queue coalesces that pass and waits for its
      // follow-up before returning a verified result.
      await synchronize(suppressSuccessNotice: true);
    } catch (_) {
      if (identical(_repository, repository) &&
          activeVault?.id == vaultId &&
          _vaultSelectionGeneration == selectionGeneration) {
        syncStatus = 'retry_wait';
        try {
          await reloadRecords();
          await refreshSyncStatus(keepStatus: true);
        } catch (_) {
          // Keep the conflict locked even if failure-state projection reloads
          // also fail. The encrypted outbox remains the recovery source.
        }
      }
      rethrow;
    }
    _ensurePreferenceRepairContext(
      repository: repository,
      vaultId: vaultId,
      selectionGeneration: selectionGeneration,
    );
    await reloadRecords();
    await refreshSyncStatus(keepStatus: true);
    _ensurePreferenceRepairContext(
      repository: repository,
      vaultId: vaultId,
      selectionGeneration: selectionGeneration,
    );
    notifyListeners();
    if (repository.verifiedServerViewRevision <= before ||
        syncStatus != 'idle' ||
        await repository.database.countPending(
              vaultId,
              instanceId: repository.instanceId,
              serverSpaceId: repository.serverSpaceId,
            ) !=
            0) {
      throw StateError(currentL10n.theVaultHasntFinishedFullySyncing);
    }
  }

  VaultPreferenceRecord? _workspacePreferenceRecord() {
    final matches = _currentPreferenceRecords(
      scope: VaultPreferenceRecord.workspaceScope,
      key: VaultPreferenceRecord.defaultSectionKey,
      platformFamily: VaultPreferenceRecord.allPlatforms,
    );
    return matches.length == 1 ? matches.single : null;
  }

  VaultPreferenceRecord? _terminalFontSizePreferenceRecord() {
    final matches = _currentPreferenceRecords(
      scope: VaultPreferenceRecord.workspaceScope,
      key: VaultPreferenceRecord.terminalFontSizeKey,
      platformFamily: VaultPreferenceRecord.allPlatforms,
    );
    return matches.length == 1 ? matches.single : null;
  }

  VaultPreferenceRecord? _terminalThemePreferenceRecord() {
    final matches = _currentPreferenceRecords(
      scope: VaultPreferenceRecord.workspaceScope,
      key: VaultPreferenceRecord.terminalThemeKey,
      platformFamily: VaultPreferenceRecord.allPlatforms,
    );
    return matches.length == 1 ? matches.single : null;
  }

  VaultPreferenceRecord? _terminalShortcutsPreferenceRecord() {
    final matches = _currentPreferenceRecords(
      scope: VaultPreferenceRecord.workspaceScope,
      key: VaultPreferenceRecord.terminalShortcutsKey,
      platformFamily: VaultPreferenceRecord.allPlatforms,
    );
    return matches.length == 1 ? matches.single : null;
  }

  /// Compares a presented host key against encrypted KnownHost records in the
  /// active Vault. Legacy secure-store pins are intentionally not consulted.
  Future<KnownHostTrustStatus> knownHostTrustStatus({
    required String host,
    required int port,
    required String algorithm,
    required String fingerprint,
  }) async => (await _knownHostTrustDecision(
    host: host,
    port: port,
    algorithm: algorithm,
    fingerprint: fingerprint,
  )).status;

  Future<_KnownHostTrustDecision> _knownHostTrustDecision({
    required String host,
    required int port,
    required String algorithm,
    required String fingerprint,
  }) async {
    final testing = knownHostTrustStatusForTesting;
    if (testing != null) {
      final status = await testing(
        host: host,
        port: port,
        algorithm: algorithm,
        fingerprint: fingerprint,
      );
      return _KnownHostTrustDecision(
        status: status,
        repository: _repository,
        generation: _knownHostDecisionGeneration,
      );
    }
    final deadline = Stopwatch()..start();
    final initialSession = session;
    final initialAccountId = initialSession?.accountId;
    final initialDeviceId = initialSession?.deviceId;
    final initialVaultId = activeVault?.id;

    while (deadline.elapsed < _knownHostDecisionBudget) {
      final generationBeforePreflight = _knownHostDecisionGeneration;
      try {
        await _pullVaultBeforeKnownHostDecision(deadline: deadline);
      } on SyncReadTransportUnavailableException {
        // Only a typed read-only sync GET that failed before receiving an
        // HTTP response may reach this branch. Timeouts, HTTP responses,
        // response parsing, signer verification and storage errors propagate.
        if (generationBeforePreflight != _knownHostDecisionGeneration ||
            _knownHostStateTransitionPending) {
          continue;
        }
        _ensureKnownHostDecisionCurrent();
        _ensureKnownHostDecisionScopeCurrent(
          accountId: initialAccountId,
          deviceId: initialDeviceId,
          vaultId: initialVaultId,
        );
        final repository = _requireRepository();
        final generation = _knownHostDecisionGeneration;
        final cached = await repository
            .cachedKnownHostTrustSnapshot(
              host: host,
              port: port,
              algorithm: algorithm,
              fingerprint: fingerprint,
            )
            .timeout(_remainingKnownHostDecisionTime(deadline));
        final waitedForStateTransition =
            await _waitForKnownHostStateTransitions(deadline);
        if (waitedForStateTransition ||
            _knownHostStateTransitionPending ||
            generation != _knownHostDecisionGeneration ||
            !identical(_repository, repository)) {
          continue;
        }
        _ensureKnownHostDecisionCurrent();
        _ensureKnownHostDecisionScopeCurrent(
          accountId: initialAccountId,
          deviceId: initialDeviceId,
          vaultId: initialVaultId,
        );
        // Existing trusted, changed, revoked or conflicted history cannot
        // certify the current server state while the Vault is offline. Only
        // a first-seen endpoint can be offered a queue-only confirmation.
        if (cached.status != KnownHostTrustStatus.unknown ||
            cached.hasEndpointHistory) {
          throw StateError(currentL10n.vaultSyncIsUnavailableExistingSsh);
        }
        return _KnownHostTrustDecision(
          status: KnownHostTrustStatus.unknown,
          repository: repository,
          generation: generation,
          offlineTransportUnavailable: true,
        );
      }
      if (generationBeforePreflight != _knownHostDecisionGeneration ||
          _knownHostStateTransitionPending) {
        continue;
      }
      _ensureKnownHostDecisionCurrent();
      _ensureKnownHostDecisionScopeCurrent(
        accountId: initialAccountId,
        deviceId: initialDeviceId,
        vaultId: initialVaultId,
      );
      final repository = _requireRepository();
      final generation = _knownHostDecisionGeneration;
      final trust = await repository
          .knownHostTrustStatus(
            host: host,
            port: port,
            algorithm: algorithm,
            fingerprint: fingerprint,
          )
          .timeout(_remainingKnownHostDecisionTime(deadline));
      final waitedForStateTransition = await _waitForKnownHostStateTransitions(
        deadline,
      );
      if (waitedForStateTransition || _knownHostStateTransitionPending) {
        continue;
      }
      if (generation != _knownHostDecisionGeneration) continue;
      _ensureKnownHostDecisionCurrent();
      _ensureKnownHostDecisionScopeCurrent(
        accountId: initialAccountId,
        deviceId: initialDeviceId,
        vaultId: initialVaultId,
      );
      if (!identical(_repository, repository)) continue;

      return _KnownHostTrustDecision(
        status: trust,
        repository: repository,
        generation: generation,
      );
    }
    throw TimeoutException(currentL10n.theCurrentVaultSyncTimedOut);
  }

  /// Persists an explicitly approved key as a new random-ID encrypted record.
  Future<KnownHostRecord> approveKnownHost({
    required String host,
    required int port,
    required String algorithm,
    required String fingerprint,
    KnownHostApprovalSource approvalSource =
        KnownHostApprovalSource.interactiveConfirmation,
    bool offlineFirstApprovalWasConfirmed = false,
    void Function()? onOfflineApprovalQueued,
  }) async {
    _assertEditsAllowed(requireWritableVault: true);
    final initialSession = session;
    final initialAccountId = initialSession?.accountId;
    final initialDeviceId = initialSession?.deviceId;
    final initialVaultId = activeVault?.id;
    final reviewedRepository = _requireRepository();
    var offlineQueue = false;
    // Pull again after the user has reviewed the prompt. A key trusted by
    // another device while the dialog was open must be seen before this local
    // create is queued. The sole offline exception is this confirmation path,
    // whose dialog explicitly says that SSH will stop until sync verification.
    try {
      await _pullVaultBeforeKnownHostDecision(deadline: Stopwatch()..start());
    } on SyncReadTransportUnavailableException {
      if (!offlineFirstApprovalWasConfirmed ||
          approvalSource != KnownHostApprovalSource.interactiveConfirmation) {
        rethrow;
      }
      _ensureKnownHostDecisionCurrent();
      _ensureKnownHostDecisionScopeCurrent(
        accountId: initialAccountId,
        deviceId: initialDeviceId,
        vaultId: initialVaultId,
      );
      if (!identical(_repository, reviewedRepository)) {
        throw StateError(currentL10n.vaultChangedWhileSshHostKey);
      }
      final cached = await reviewedRepository.cachedKnownHostTrustSnapshot(
        host: host,
        port: port,
        algorithm: algorithm,
        fingerprint: fingerprint,
      );
      if (cached.status != KnownHostTrustStatus.unknown ||
          cached.hasEndpointHistory) {
        throw StateError(currentL10n.offlineKnownhostApprovalIsLimitedTo);
      }
      offlineQueue = true;
    }
    _ensureKnownHostDecisionCurrent();
    _ensureKnownHostDecisionScopeCurrent(
      accountId: initialAccountId,
      deviceId: initialDeviceId,
      vaultId: initialVaultId,
    );
    // The stable pre-write pull may complete a signed roster refresh that
    // replaces the Repository object while retaining this account/device/Vault
    // scope. Continue with that refreshed repository; rejecting it here would
    // make an explicit approval fail periodically when account refresh and SSH
    // review overlap. A scope change still fails closed above, and any further
    // replacement during the local write is rejected below.
    final repository = _requireRepository();
    if (repository.vaultId != initialVaultId) {
      throw StateError(currentL10n.vaultChangedWhileSshHostKey2);
    }
    final record = await repository.approveKnownHost(
      host: host,
      port: port,
      algorithm: algorithm,
      fingerprint: fingerprint,
      approvalSource: approvalSource,
      allowOfflineFirstApproval: offlineQueue,
    );
    _ensureKnownHostDecisionCurrent();
    _ensureKnownHostDecisionScopeCurrent(
      accountId: initialAccountId,
      deviceId: initialDeviceId,
      vaultId: initialVaultId,
    );
    if (!identical(_repository, repository)) {
      throw StateError(currentL10n.vaultChangedWhileSshHostKey2);
    }
    if (offlineQueue) {
      if (record.state != KnownHostState.trusted ||
          record.host != canonicalizeKnownHost(host) ||
          record.port != port ||
          record.algorithm != algorithm ||
          record.fingerprint != fingerprint ||
          record.approvalSource !=
              KnownHostApprovalSource.interactiveConfirmation) {
        throw StateError(currentL10n.offlineKnownhostQueueDidNotMatch);
      }
      final pending = (await repository.database.allPendingOperations(
        repository.vaultId,
        instanceId: repository.instanceId,
        serverSpaceId: repository.serverSpaceId,
      )).where((operation) => operation.recordId == record.id).toList();
      if (pending.length != 1 || pending.single.baseRevisionId != null) {
        throw StateError(currentL10n.theEncryptedSshHostKeyApproval);
      }
      _upsertKnownHost(record);
      pendingKnownHostRecordIds.add(record.id);
      onOfflineApprovalQueued?.call();
      _setNotice(currentL10n.theSshHostKeyApprovalWas);
      await refreshSyncStatus();
      _automaticSync.scheduleEdit();
      notifyListeners();
      return record;
    }

    // Do not continue the SSH handshake based on a local-only approval. Push
    // the signed record, pull the committed Vault state, and confirm this exact
    // approval still wins over any concurrent revocation or approval.
    await _pullVaultBeforeKnownHostDecision(deadline: Stopwatch()..start());
    _ensureKnownHostDecisionCurrent();
    _ensureKnownHostDecisionScopeCurrent(
      accountId: initialAccountId,
      deviceId: initialDeviceId,
      vaultId: initialVaultId,
    );
    // A due signed control-plane refresh can rebuild the repository during
    // this final sync. Bind readback to the current repository after the
    // stable pull, while retaining the account, device, and Vault scope from
    // before the user approved the key.
    final confirmedRepository = _requireRepository();
    final confirmedGeneration = _knownHostDecisionGeneration;
    final pendingApproval =
        (await confirmedRepository.database.allPendingOperations(
          confirmedRepository.vaultId,
          instanceId: confirmedRepository.instanceId,
          serverSpaceId: confirmedRepository.serverSpaceId,
        )).any((operation) => operation.recordId == record.id);
    final confirmedEnvelope = await confirmedRepository.database.cachedEnvelope(
      confirmedRepository.vaultId,
      record.id,
      instanceId: confirmedRepository.instanceId,
      serverSpaceId: confirmedRepository.serverSpaceId,
    );
    final confirmedStatus = await confirmedRepository.knownHostTrustStatus(
      host: host,
      port: port,
      algorithm: algorithm,
      fingerprint: fingerprint,
    );
    final confirmedRecord = (await confirmedRepository.loadKnownHosts())
        .where(
          (candidate) =>
              candidate.id == record.id &&
              candidate.state == KnownHostState.trusted &&
              candidate.host == canonicalizeKnownHost(host) &&
              candidate.port == port &&
              candidate.algorithm == algorithm &&
              candidate.fingerprint == fingerprint &&
              candidate.approvalSource == approvalSource,
        )
        .firstOrNull;
    _ensureKnownHostDecisionCurrent();
    _ensureKnownHostDecisionScopeCurrent(
      accountId: initialAccountId,
      deviceId: initialDeviceId,
      vaultId: initialVaultId,
    );
    if (!identical(_repository, confirmedRepository) ||
        confirmedGeneration != _knownHostDecisionGeneration) {
      throw StateError(currentL10n.vaultChangedWhileSshHostKey3);
    }
    if (pendingApproval ||
        confirmedEnvelope?.commitSeq == null ||
        confirmedStatus != KnownHostTrustStatus.trusted ||
        confirmedRecord == null) {
      throw StateError(currentL10n.vaultSyncDidNotConfirmThis);
    }

    _upsertKnownHost(confirmedRecord);
    _setNotice(currentL10n.sshHostKeyTrustWasConfirmed);
    await refreshSyncStatus();
    if (pendingCount > 0) _automaticSync.scheduleEdit();
    notifyListeners();
    return confirmedRecord;
  }

  /// Revokes one trust record with a signed encrypted revision. The historical
  /// record remains and a later approval receives a different record ID.
  Future<KnownHostRecord> revokeKnownHost(String recordId) async {
    _assertEditsAllowed(requireWritableVault: true);
    await _pullVaultBeforeKnownHostDecision(deadline: Stopwatch()..start());
    _ensureKnownHostDecisionCurrent();
    final repository = _requireRepository();
    final record = await repository.revokeKnownHost(recordId: recordId);
    _ensureKnownHostDecisionCurrent();
    if (!identical(_repository, repository)) {
      throw StateError(currentL10n.vaultChangedWhileSshHostKey4);
    }
    _upsertKnownHost(record);
    _setNotice(currentL10n.sshHostKeyTrustWasRevoked);
    await refreshSyncStatus();
    _automaticSync.scheduleEdit();
    notifyListeners();
    return record;
  }

  Future<void> _pullVaultBeforeKnownHostDecision({
    required Stopwatch deadline,
  }) async {
    while (deadline.elapsed < _knownHostDecisionBudget) {
      final generationBeforeTransitionWait = _knownHostDecisionGeneration;
      await _waitForKnownHostStateTransitions(deadline);
      if (generationBeforeTransitionWait != _knownHostDecisionGeneration ||
          _knownHostStateTransitionPending) {
        continue;
      }
      if (_repository == null || !authenticated) {
        throw StateError(currentL10n.unlockTheCurrentVaultBeforeVerifying);
      }
      _ensureKnownHostDecisionCurrent();
      if (syncing) {
        final active = _activeSyncCompletion;
        if (active == null) {
          throw StateError(currentL10n.theVaultSyncStateIsAbnormal);
        }
        await active.future.timeout(_remainingKnownHostDecisionTime(deadline));
        continue;
      }

      final repositoryBeforeSync = _repository;
      final generationBeforeSync = _knownHostDecisionGeneration;

      await synchronize().timeout(_remainingKnownHostDecisionTime(deadline));

      final waitedForStateTransition = await _waitForKnownHostStateTransitions(
        deadline,
      );
      if (waitedForStateTransition ||
          generationBeforeSync != _knownHostDecisionGeneration ||
          _knownHostStateTransitionPending ||
          syncing ||
          !identical(repositoryBeforeSync, _repository)) {
        continue;
      }
      _ensureKnownHostDecisionCurrent();
      if (!const {
        'idle',
        'pending',
        'read_only',
        'deletion_pending',
      }.contains(syncStatus)) {
        throw StateError(
          currentL10n.couldntFinishSyncingTheCurrentVault(syncStatus),
        );
      }
      return;
    }
    throw TimeoutException(currentL10n.theCurrentVaultSyncTimedOut);
  }

  Duration _remainingKnownHostDecisionTime(Stopwatch deadline) {
    final remaining = _knownHostDecisionBudget - deadline.elapsed;
    if (remaining <= Duration.zero) {
      throw TimeoutException(currentL10n.theCurrentVaultSyncTimedOut);
    }
    return remaining;
  }

  /// Waits for an already-running membership or snapshot refresh, then lets
  /// callers repeat their read against the state that refresh published.
  /// Failures propagate so an uncertain membership chain can never turn into
  /// an `unknown` host-key result.
  bool get _knownHostStateTransitionPending =>
      snapshotRecoveryActive ||
      _snapshotRecoveryFuture != null ||
      _membershipRefreshActive ||
      _membershipRefreshFuture != null;

  Future<bool> _waitForKnownHostStateTransitions(Stopwatch deadline) async {
    var waited = false;
    while (deadline.elapsed < _knownHostDecisionBudget) {
      final recovery = _snapshotRecoveryFuture;
      final membershipRefresh = _membershipRefreshFuture;
      final pending = recovery ?? membershipRefresh;
      if (pending != null) {
        waited = true;

        await pending.timeout(_remainingKnownHostDecisionTime(deadline));
        continue;
      }
      if (snapshotRecoveryActive || _membershipRefreshActive) {
        // An active flag can become visible just before its Future is
        // published. Poll briefly under the same decision deadline.
        waited = true;
        await Future<void>.delayed(const Duration(milliseconds: 5))
            .timeout(_remainingKnownHostDecisionTime(deadline));
        continue;
      }
      return waited;
    }
    throw TimeoutException(currentL10n.refreshingTheCurrentVaultStateTimed);
  }

  void _ensureKnownHostDecisionScopeCurrent({
    required String? accountId,
    required String? deviceId,
    required String? vaultId,
  }) {
    final currentSession = session;
    if (accountId == null ||
        deviceId == null ||
        vaultId == null ||
        currentSession?.accountId != accountId ||
        currentSession?.deviceId != deviceId ||
        activeVault?.id != vaultId) {
      throw StateError(currentL10n.theCurrentAccountOrVaultChanged);
    }
  }

  void _ensureKnownHostDecisionCurrent() {
    if (!authenticated ||
        stage != ClientStage.workspace ||
        _repository == null) {
      throw StateError(currentL10n.theCurrentVaultIsLockedSo);
    }
    if (snapshotRecoveryActive) {
      throw StateError(currentL10n.theVaultIsRestoringOrChanging);
    }
    if (_vaultMembershipChangeActive) {
      throw StateError(currentL10n.theVaultIsRestoringOrChanging);
    }
    if (_membershipRefreshActive) {
      throw StateError(currentL10n.theVaultIsRestoringOrChanging);
    }
  }

  void _upsertKnownHost(KnownHostRecord record) {
    final index = knownHosts.indexWhere((item) => item.id == record.id);
    if (index < 0) {
      knownHosts.add(record);
    } else {
      knownHosts[index] = record;
    }
    knownHosts.sort((a, b) {
      final endpoint = a.endpoint.compareTo(b.endpoint);
      return endpoint != 0 ? endpoint : a.id.compareTo(b.id);
    });
  }

  Future<void> saveHost(HostRecord host) =>
      _serializeGroupMutation(() => _saveHost(host));

  /// Replays only the fields changed from the caller's Host snapshot onto the
  /// latest authenticated local cache head. This also protects card actions
  /// such as Favorite from overwriting unrelated edits made in another tab.
  Future<void> saveHostFromEditor({
    required HostRecord original,
    required HostRecord edited,
  }) => _serializeGroupMutation(
    () => _saveHostFromEditor(original: original, edited: edited),
  );

  static const _hostEditorRebaseAttempts = 4;

  Future<void> _saveHostFromEditor({
    required HostRecord original,
    required HostRecord edited,
  }) async {
    _assertEditsAllowed(requireWritableVault: true);
    if (original.id != edited.id) {
      throw FormatException(currentL10n.hostIdentityChangedWhileTheEditor);
    }
    final targetVaultId = activeVault?.id;
    if (targetVaultId == null) throw StateError(currentL10n.chooseAVaultFirst);
    final repository = _requireRepository();

    for (var attempt = 0; attempt < _hostEditorRebaseAttempts; attempt++) {
      final latestRow = await repository.loadRecord(original.id);
      if (activeVault?.id != targetVaultId ||
          !identical(_repository, repository)) {
        throw StateError(currentL10n.theVaultWasSwitchedReopenThe);
      }
      if (repository.unavailableRecordIds.contains(original.id)) {
        throw FormatException(currentL10n.thisHostsLocalEncryptedRecordCouldnt);
      }
      if (latestRow == null) {
        throw FormatException(currentL10n.thisHostNoLongerExistsOr);
      }
      if (latestRow['type'] != 'host' ||
          (latestRow['_record_id'] ?? latestRow['id']) != original.id ||
          (latestRow['id'] is String && latestRow['id'] != original.id)) {
        throw FormatException(currentL10n.thisRecordsHostIdentityCantBe);
      }
      final latestRevisionId = latestRow['_revision_id'];
      if (latestRevisionId is! String || latestRevisionId.isEmpty) {
        throw FormatException(currentL10n.thisHostIsMissingAVerifiable);
      }
      final latest = HostRecord.fromJson({
        ...latestRow,
        'id': original.id,
        'revision_id': latestRevisionId,
      });
      final rebased = _rebaseHostEditorFields(
        original: original,
        edited: edited,
        latest: latest,
      );
      final jumpHostTopologyChanged = rebased.jumpHostId != latest.jumpHostId;
      final hostRelationshipChanged =
          jumpHostTopologyChanged ||
          rebased.groupId != latest.groupId ||
          rebased.credentialId != latest.credentialId;
      Map<String, String>? expectedVaultHeadRevisionIds;
      late final ({
        List<HostRecord> hosts,
        List<GroupRecord> groups,
        List<CredentialRecord> credentials,
      })
      catalog;
      if (hostRelationshipChanged) {
        // Relationship edits must validate against the current authenticated
        // catalog, not a possibly stale in-memory projection. Capture those
        // exact heads and compare the whole set inside the write transaction
        // so a concurrent target deletion cannot leave a dangling reference.
        final referenceSnapshot = await repository
            .loadRecordsWithHeadRevisionSnapshot();
        if (repository.unavailableRecordIds.isNotEmpty) {
          throw FormatException(currentL10n.someLocalRecordsCouldntBeVerified3);
        }
        catalog = _hostReferenceCatalogFromRows(referenceSnapshot.records);
        expectedVaultHeadRevisionIds = referenceSnapshot.headRevisionIds;
        if (expectedVaultHeadRevisionIds[original.id] != latestRevisionId) {
          if (attempt + 1 == _hostEditorRebaseAttempts) {
            throw LocalRecordHeadChangedException(original.id);
          }
          continue;
        }
      } else {
        // Ordinary field edits cannot introduce a relationship edge. Keep
        // this common path bounded to the in-memory catalog and Host head CAS
        // instead of decrypting every Vault record.
        catalog = (
          hosts: [
            ...hosts.where((candidate) => candidate.id != latest.id),
            latest,
          ],
          groups: List<GroupRecord>.of(groups),
          credentials: List<CredentialRecord>.of(credentials),
        );
      }
      if (activeVault?.id != targetVaultId ||
          !identical(_repository, repository)) {
        throw StateError(currentL10n.theVaultWasSwitchedReopenThe);
      }
      final referenceIssue = _validateHostReferencesAgainst(
        rebased,
        hosts: catalog.hosts,
        groups: catalog.groups,
        credentials: catalog.credentials,
      );
      if (referenceIssue != null) throw FormatException(referenceIssue);

      try {
        await beforeHostEditorSaveForTesting?.call();
        if (jumpHostTopologyChanged) {
          await beforeHostJumpGraphCommitForE2eTesting(
            recordId: rebased.id,
            jumpHostId: rebased.jumpHostId,
            attempt: attempt + 1,
          );
        }
        await _saveHost(
          rebased,
          baseRevisionIdOverride: latestRevisionId,
          expectedCachedHeadRevisionId: latestRevisionId,
          expectedVaultHeadRevisionIds: expectedVaultHeadRevisionIds,
          preserveOutboxChain: true,
          referenceValidator: (host) => _validateHostReferencesAgainst(
            host,
            hosts: catalog.hosts,
            groups: catalog.groups,
            credentials: catalog.credentials,
          ),
        );
        return;
      } on LocalRecordHeadChangedException {
        // A sibling tab committed after the read. Reload and replay the user's
        // field-level intent, with same-field collisions checked each time.
        if (attempt + 1 == _hostEditorRebaseAttempts) rethrow;
      }
    }
    throw StateError(currentL10n.hostChangedRepeatedlyWhileSavingReopen);
  }

  HostRecord _rebaseHostEditorFields({
    required HostRecord original,
    required HostRecord edited,
    required HostRecord latest,
  }) {
    T choose<T>(String label, T originalValue, T editedValue, T latestValue) {
      final userChanged = editedValue != originalValue;
      final siblingChanged = latestValue != originalValue;
      if (userChanged && siblingChanged && editedValue != latestValue) {
        throw FormatException(currentL10n.theHostsLabelFieldWasAlso(label));
      }
      return userChanged ? editedValue : latestValue;
    }

    bool sameTags(List<String> left, List<String> right) =>
        left.length == right.length &&
        List<bool>.generate(
          left.length,
          (index) => left[index] == right[index],
        ).every((same) => same);

    List<String> chooseTags() {
      final userChanged = !sameTags(edited.tags, original.tags);
      final siblingChanged = !sameTags(latest.tags, original.tags);
      if (userChanged &&
          siblingChanged &&
          !sameTags(edited.tags, latest.tags)) {
        throw FormatException(currentL10n.theHostsTagsFieldWasAlso);
      }
      return userChanged ? edited.tags : latest.tags;
    }

    return HostRecord(
      id: latest.id,
      name: choose(currentL10n.name, original.name, edited.name, latest.name),
      address: choose(
        currentL10n.address,
        original.address,
        edited.address,
        latest.address,
      ),
      port: choose(currentL10n.port2, original.port, edited.port, latest.port),
      protocol: choose(
        currentL10n.protocol2,
        original.protocol,
        edited.protocol,
        latest.protocol,
      ),
      rdpCertificateSha256: choose(
        currentL10n.rdpCertificate,
        original.rdpCertificateSha256,
        edited.rdpCertificateSha256,
        latest.rdpCertificateSha256,
      ),
      username: choose(
        currentL10n.userName,
        original.username,
        edited.username,
        latest.username,
      ),
      groupId: choose(
        currentL10n.groups,
        original.groupId,
        edited.groupId,
        latest.groupId,
      ),
      credentialId: choose(
        currentL10n.sshCredentials2,
        original.credentialId,
        edited.credentialId,
        latest.credentialId,
      ),
      login: choose(
        currentL10n.sshSignInDetails,
        original.login,
        edited.login,
        latest.login,
      ),
      jumpHostId: choose(
        currentL10n.jumpHost,
        original.jumpHostId,
        edited.jumpHostId,
        latest.jumpHostId,
      ),
      tags: chooseTags(),
      authKind: choose(
        currentL10n.authenticationMethod,
        original.authKind,
        edited.authKind,
        latest.authKind,
      ),
      color: latest.color,
      portForwardProfiles: latest.portForwardProfiles,
      isFavorite: choose(
        'Favorite',
        original.isFavorite,
        edited.isFavorite,
        latest.isFavorite,
      ),
      lastConnected: latest.lastConnected,
      revisionId: latest.revisionId,
      baseRevisionId: latest.baseRevisionId,
      online: latest.online,
      manifest: latest.manifest,
    );
  }

  ({
    List<HostRecord> hosts,
    List<GroupRecord> groups,
    List<CredentialRecord> credentials,
  })
  _hostReferenceCatalogFromRows(List<Map<String, dynamic>> rows) {
    final hosts = <HostRecord>[];
    final groups = <GroupRecord>[];
    final credentials = <CredentialRecord>[];
    for (final row in rows) {
      final id = row['_record_id'] ?? row['id'];
      if (id is! String) continue;
      switch (row['type']) {
        case 'host':
          hosts.add(
            HostRecord.fromJson({
              ...row,
              'id': id,
              'revision_id': row['_revision_id'],
            }),
          );
        case 'group':
          groups.add(GroupRecord.fromJson({...row, 'id': id}));
        case 'credential':
          credentials.add(CredentialRecord.fromJson({...row, 'id': id}));
      }
    }
    return (hosts: hosts, groups: groups, credentials: credentials);
  }

  ({
    Map<String, CredentialRecord> credentialsById,
    List<HostRecord> hosts,
    List<GroupRecord> groups,
    List<SnippetRecord> snippets,
  })
  _serverVaultCredentialReferenceCatalogFromRows(
    List<Map<String, dynamic>> rows,
  ) {
    final credentialsById = <String, CredentialRecord>{};
    final hosts = <HostRecord>[];
    final groups = <GroupRecord>[];
    final snippets = <SnippetRecord>[];
    for (final row in rows) {
      final id = row['_record_id'] ?? row['id'];
      if (id is! String || id.isEmpty || row['id'] != id) {
        throw FormatException(
          currentL10n.vaultReferenceRecordIdentityIsMalformed,
        );
      }
      switch (row['type']) {
        case 'credential':
          if (credentialsById.containsKey(id)) {
            throw FormatException(
              currentL10n.vaultContainsDuplicateCredentialIdentities,
            );
          }
          credentialsById[id] = CredentialRecord.fromJson({...row, 'id': id});
        case 'host':
          hosts.add(HostRecord.fromJson({...row, 'id': id}));
        case 'group':
          groups.add(GroupRecord.fromJson({...row, 'id': id}));
        case 'snippet':
          snippets.add(SnippetRecord.fromJson({...row, 'id': id}));
        case 'knownHost':
        case 'preference':
        case 'workspace':
        case 'shellHistory':
          break;
        default:
          throw FormatException(
            currentL10n.vaultContainsAnUnsupportedReferenceRecord,
          );
      }
    }
    return (
      credentialsById: credentialsById,
      hosts: hosts,
      groups: groups,
      snippets: snippets,
    );
  }

  /// Saves an edited Host only if its encrypted revision still matches the
  /// revision the caller reviewed. Bulk import and refresh previews use this
  /// to avoid applying stale decisions after another device or editor changed
  /// the Host.
  Future<void> saveHostAtRevision(
    HostRecord host, {
    required String expectedRevisionId,
    bool Function()? isCurrentContext,
  }) => _serializeGroupMutation(() {
    if (isCurrentContext != null && !isCurrentContext()) {
      throw StateError(currentL10n.theWorkspaceWasSwitchedTryAgain);
    }
    return _saveHost(host, expectedRevisionId: expectedRevisionId);
  });

  /// Equal values mean the same signed-in context: no sign-in, sign-out,
  /// account change or server activation happened in between.
  Object get authScopeToken => (_authContextGeneration, _apiGeneration);

  /// Equal values mean no Vault selection was requested or applied in
  /// between (select-away-and-back included). Same-Vault membership refreshes
  /// keep it.
  Object get vaultSelectionToken =>
      (_vaultSelectionRequestGeneration, _vaultSelectionGeneration);

  /// Selects [vaultId] for an operation scoped to it. Returns the resulting
  /// [vaultSelectionToken] only if the Vault is selected by this request (or
  /// already was) and no newer selection request superseded it; else null.
  Future<Object?> selectVaultForOperation(String vaultId) async {
    final auth = authScopeToken;
    if (activeVault?.id == vaultId && _repository?.vaultId == vaultId) {
      return vaultSelectionToken;
    }
    final selecting = selectVault(vaultId);
    // selectVault claims its request generation synchronously.
    final request = _vaultSelectionRequestGeneration;
    await selecting;
    if (authScopeToken != auth ||
        request != _vaultSelectionRequestGeneration ||
        activeVault?.id != vaultId ||
        _repository?.vaultId != vaultId) {
      return null;
    }
    return vaultSelectionToken;
  }

  /// Completes once no Vault membership refresh is running (a realtime
  /// membership hint may start one at any time, during which local edits are
  /// refused). Refresh failures propagate. Callers must re-verify their own
  /// scope afterwards.
  Future<void> waitForMembershipRefresh() async {
    while (_membershipRefreshActive || _membershipRefreshFuture != null) {
      final refresh = _membershipRefreshFuture;
      if (refresh != null) {
        await refresh;
      } else {
        // The active flag is set immediately before its Future is published.
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
  }

  /// Opaque identity of the open Vault repository. Equal (identical) values
  /// mean the same account, Vault and repository lifetime; a Vault switch,
  /// lock, sign-out or repository rebuild produces a different value.
  Object? get recordWriteScope => _repository;

  void _requireRecordWriteScope(Object scope) {
    if (!identical(_repository, scope) ||
        activeVault?.canWrite != true ||
        activeVault?.status != 'active') {
      throw StateError(currentL10n.theWorkspaceWasSwitchedTryAgain);
    }
  }

  /// Creates a NEW Host only while [scope] is still the open repository. The
  /// scope is checked inside the mutation queue (after earlier queued writes
  /// finish) and again after the write; returns the created revision.
  Future<String> createHostInScope(HostRecord host, {required Object scope}) =>
      _serializeGroupMutation(() async {
        _requireRecordWriteScope(scope);
        if (_revisionIds.containsKey(host.id) ||
            hosts.any((candidate) => candidate.id == host.id)) {
          throw FormatException(currentL10n.thisHostChangedAfterThePreview);
        }
        await _saveHost(host, expectedWriteScope: scope);
        _requireRecordWriteScope(scope);
        final revision = _revisionIds[host.id];
        if (revision == null) {
          throw StateError(currentL10n.theWorkspaceWasSwitchedTryAgain);
        }
        return revision;
      });

  /// Creates a NEW Credential only while [scope] is still the open repository
  /// (checked inside the mutation queue and after the write).
  Future<String> createCredentialInScope(
    CredentialRecord credential, {
    required Object scope,
  }) => _serializeGroupMutation(() async {
    _requireRecordWriteScope(scope);
    if (_revisionIds.containsKey(credential.id) ||
        credentials.any((candidate) => candidate.id == credential.id)) {
      throw FormatException(currentL10n.thisHostChangedAfterThePreview);
    }
    await saveCredential(credential);
    _requireRecordWriteScope(scope);
    final revision = _revisionIds[credential.id];
    if (revision == null) {
      throw StateError(currentL10n.theWorkspaceWasSwitchedTryAgain);
    }
    return revision;
  });

  /// Whether [recordId] has an active authenticated head in [scope]; used to
  /// prove whether a failed create reached storage. Runs inside the queue.
  Future<bool> recordExistsInScope(String recordId, {required Object scope}) =>
      _serializeGroupMutation(() async {
        _requireRecordWriteScope(scope);
        final row = await _requireRepository().loadRecord(recordId);
        _requireRecordWriteScope(scope);
        return row != null;
      });

  /// Compensating delete for a Host, Group or Credential this client just
  /// created. It runs
  /// inside the mutation queue, only in [scope], and only while the record's
  /// authenticated head is still exactly [revisionId] and nothing references
  /// it. Otherwise it throws and leaves the record untouched.
  Future<void> deleteCreatedRecordAtRevision({
    required String recordId,
    required RecordKind kind,
    required String revisionId,
    required Object scope,
  }) => _serializeGroupMutation(() async {
    if (kind != RecordKind.host &&
        kind != RecordKind.group &&
        kind != RecordKind.credential) {
      throw ArgumentError.value(kind, 'kind');
    }
    _requireRecordWriteScope(scope);
    final repository = _requireRepository();
    final snapshot = await repository.loadRecordsWithHeadRevisionSnapshot();
    _requireRecordWriteScope(scope);
    if (repository.unavailableRecordIds.isNotEmpty) {
      throw FormatException(currentL10n.someLocalRecordsCouldntBeVerified);
    }
    if (snapshot.headRevisionIds[recordId] != revisionId ||
        _revisionIds[recordId] != revisionId) {
      throw LocalRecordHeadChangedException(recordId);
    }
    final catalog = _serverVaultCredentialReferenceCatalogFromRows(
      snapshot.records,
    );
    final referenced = switch (kind) {
      RecordKind.host => catalog.hosts.any(
        (host) => host.id != recordId && host.jumpHostId == recordId,
      ),
      RecordKind.group =>
        catalog.hosts.any((host) => host.groupId == recordId) ||
            catalog.groups.any(
              (group) => group.id != recordId && group.parentId == recordId,
            ),
      _ =>
        catalog.hosts.any((host) => host.credentialId == recordId) ||
            catalog.groups.any(
              (group) => group.defaultCredentialId == recordId,
            ) ||
            catalog.snippets
                .expand((snippet) => snippet.parameters)
                .any((parameter) => parameter.credentialId == recordId),
    };
    if (referenced) throw LocalRecordHeadChangedException(recordId);
    await _deleteRecord(
      recordId,
      kind.name,
      cleanupAttachmentJobs: kind == RecordKind.host,
      baseRevisionIdOverride: revisionId,
      expectedCachedHeadRevisionId: revisionId,
      expectedVaultHeadRevisionIds: snapshot.headRevisionIds,
    );
  });

  /// Simulates a Vault/repository switch in controller tests.
  @visibleForTesting
  void replaceRecordScopeForTesting({
    required SyncRepository? repository,
    required VaultDescriptor? vault,
  }) {
    _repository = repository;
    activeVault = vault;
  }

  void _requirePortForwardScope(Object scope) {
    if (!identical(_repository, scope) || activeVault?.canWrite != true) {
      throw StateError(currentL10n.theVaultChangedReopenPortForwarding);
    }
  }

  /// Applies ONE forwarding rule change (see [applySshPortForwardRuleChange])
  /// to the Host as it is inside the mutation queue: the [scope] (a captured
  /// [recordWriteScope]) is checked there, after earlier queued writes, the
  /// rule is compared with [expected], and the write is a CAS on the Host
  /// revision read at that moment. Unrelated rules and Host fields stay as
  /// currently saved; a stale edit throws [SshPortForwardRuleConflict].
  Future<void> updateHostPortForwardRuleInScope({
    required String hostId,
    SshPortForwardProfile? expected,
    SshPortForwardProfile? replacement,
    required Object scope,
  }) async {
    await _serializeGroupMutation(() async {
      _requirePortForwardScope(scope);
      final host = hosts
          .where((candidate) => candidate.id == hostId)
          .firstOrNull;
      if (host == null) {
        throw StateError(currentL10n.theHostNoLongerExistsResync);
      }
      final next = applySshPortForwardRuleChange(
        host.portForwardProfiles,
        expected: expected,
        replacement: replacement,
      );
      await _saveHost(
        host.copyWith(portForwardProfiles: next),
        expectedRevisionId: _revisionIds[host.id],
        expectedWriteScope: scope,
      );
    });
    // A scope switch can finish while the encrypted write is in flight.
    // Never project that old result into another workspace's live tabs.
    _requirePortForwardScope(scope);
    _refreshTabsForHost(hostId);
  }

  Future<void> saveHostPortForwardProfiles({
    required String hostId,
    required List<SshPortForwardProfile> profiles,
  }) async {
    final host = hosts.where((candidate) => candidate.id == hostId).firstOrNull;
    if (host == null) throw StateError(currentL10n.theHostNoLongerExistsResync);
    await saveHost(host.copyWith(portForwardProfiles: profiles));
    _refreshTabsForHost(hostId);
  }

  void _refreshTabsForHost(String hostId) {
    final stored = hosts
        .where((candidate) => candidate.id == hostId)
        .firstOrNull;
    if (stored == null) throw StateError(currentL10n.theHostCouldntBeReadBack);
    for (final tab in terminalTabs) {
      if (tab.host?.id == hostId) tab.host = stored;
    }
    notifyListeners();
  }

  Future<void> _saveHost(
    HostRecord host, {
    String? expectedRevisionId,
    Object? expectedWriteScope,
    String? baseRevisionIdOverride,
    String? expectedCachedHeadRevisionId,
    Map<String, String>? expectedVaultHeadRevisionIds,
    bool preserveOutboxChain = false,
    String? Function(HostRecord host)? referenceValidator,
  }) async {
    _assertEditsAllowed(requireWritableVault: true);
    void ensureWriteScope() {
      if (expectedWriteScope != null &&
          (!identical(_repository, expectedWriteScope) ||
              activeVault?.canWrite != true)) {
        throw StateError(currentL10n.theWorkspaceWasSwitchedTryAgain);
      }
    }
    ensureWriteScope();
    if (expectedRevisionId != null &&
        (_revisionIds[host.id] != expectedRevisionId ||
            !hosts.any((candidate) => candidate.id == host.id))) {
      throw FormatException(currentL10n.thisHostChangedAfterThePreview);
    }
    final issue = host.validate();
    if (issue != null) throw FormatException(issue);
    final repository = _requireRepository();
    var expectedHeadSnapshot = expectedVaultHeadRevisionIds;
    var validatedReference = referenceValidator;
    if (validatedReference == null) {
      final snapshot = await repository.loadRecordsWithHeadRevisionSnapshot();
      ensureWriteScope();
      if (repository.unavailableRecordIds.isNotEmpty) {
        throw FormatException(currentL10n.someLocalRecordsCouldntBeVerified3);
      }
      expectedHeadSnapshot ??= snapshot.headRevisionIds;
      final catalog = _hostReferenceCatalogFromRows(snapshot.records);
      validatedReference ??= (candidate) => _validateHostReferencesAgainst(
        candidate,
        hosts: catalog.hosts,
        groups: catalog.groups,
        credentials: catalog.credentials,
      );
    }
    final referenceIssue = validatedReference(host);
    if (referenceIssue != null) throw FormatException(referenceIssue);
    final targetVaultId = activeVault?.id;
    if (targetVaultId == null) throw StateError(currentL10n.chooseAVaultFirst);
    final envelope = await repository.saveRecord(
      recordId: host.id,
      plaintext: host.toJson(),
      baseRevisionId:
          baseRevisionIdOverride ?? expectedRevisionId ?? _revisionIds[host.id],
      expectedCachedHeadRevisionId:
          expectedCachedHeadRevisionId ?? expectedRevisionId,
      expectedVaultHeadRevisionIds: expectedHeadSnapshot,
      preserveOutboxChain: preserveOutboxChain,
      operation:
          (baseRevisionIdOverride ??
                  expectedRevisionId ??
                  _revisionIds[host.id]) !=
              null
          ? 'update'
          : 'create',
    );
    ensureWriteScope();
    if (activeVault?.id != targetVaultId) return;
    if (!identical(_repository, repository)) {
      await reloadRecords();
      return;
    }
    // Discard any record snapshot that started before this encrypted write;
    // its late result must not erase the newly saved Host from the UI.
    _recordsLoadGeneration++;
    _revisionIds[host.id] =
        (envelope['header'] as Map<String, dynamic>)['revision_id'] as String;
    final index = hosts.indexWhere((item) => item.id == host.id);
    final stored = host.copyWith(revisionId: _revisionIds[host.id]);
    if (index < 0) {
      hosts.add(stored);
    } else {
      hosts[index] = stored;
    }
    hosts.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _rebuildJumpHostRouteIssues();
    _rebuildHostGroupReferenceIssues();
    _setNotice(currentL10n.theHostWasSavedEncryptedLocally);
    _automaticSync.scheduleEdit();
    try {
      await refreshSyncStatus();
    } catch (_) {
      // The encrypted record and outbox entry are already durable. A derived
      // status refresh must not hide the saved Host or suppress its sync.
      _setNotice(currentL10n.theHostWasSavedEncryptedAnd);
    }
    if (activeVault?.id == targetVaultId &&
        identical(_repository, repository)) {
      notifyListeners();
    }
  }

  String? validateHostReferences(HostRecord host) {
    return _validateHostReferencesAgainst(
      host,
      hosts: hosts,
      groups: groups,
      credentials: credentials,
    );
  }

  String? _validateHostReferencesAgainst(
    HostRecord host, {
    required List<HostRecord> hosts,
    required List<GroupRecord> groups,
    required List<CredentialRecord> credentials,
  }) {
    if (host.groupId != null &&
        !groups.any((group) => group.id == host.groupId)) {
      return currentL10n.theSelectedGroupNoLongerExists;
    }
    if (host.credentialId != null &&
        !credentials.any((credential) => credential.id == host.credentialId)) {
      return currentL10n.theSelectedSshCredentialNoLonger;
    }
    final projectedHosts = <String, HostRecord>{
      for (final candidate in hosts)
        if (candidate.id != host.id) candidate.id: candidate,
      host.id: host,
    };
    for (final source in projectedHosts.values) {
      var current = source;
      var routeTouchesEditedHost = source.id == host.id;
      var depth = 0;
      final seen = <String>{source.id};
      while (current.jumpHostId != null) {
        final nextId = current.jumpHostId!;
        if (nextId == host.id) routeTouchesEditedHost = true;
        if (nextId == current.id && routeTouchesEditedHost) {
          return currentL10n.aHostCantUseItselfAs;
        }
        if (++depth > maxJumpHostHops) {
          if (routeTouchesEditedHost) {
            return currentL10n.theJumpHostChainSupportsUp(maxJumpHostHops);
          }
          break;
        }
        if (!seen.add(nextId)) {
          if (routeTouchesEditedHost) {
            return currentL10n.theJumpHostChainCantForm;
          }
          break;
        }
        final next = projectedHosts[nextId];
        if (next == null) {
          if (routeTouchesEditedHost) {
            return currentL10n.theSelectedJumpHostNoLonger;
          }
          break;
        }
        current = next;
      }
    }
    return null;
  }

  void _rebuildJumpHostRouteIssues() {
    final hostsById = <String, HostRecord>{
      for (final host in hosts) host.id: host,
    };
    final nextIssues = <String, String>{};
    for (final source in hosts) {
      final issue = _jumpHostRouteIssueFor(source, hostsById);
      if (issue != null) nextIssues[source.id] = issue;
    }
    _jumpHostRouteIssues
      ..clear()
      ..addAll(nextIssues);
  }

  void _rebuildHostGroupReferenceIssues() {
    final activeGroupIds = groups.map((group) => group.id).toSet();
    final nextIssues = <String, String>{};
    for (final host in hosts) {
      final groupId = host.groupId;
      if (groupId != null &&
          !activeGroupIds.contains(groupId) &&
          !_unavailableGroupRecordIds.contains(groupId)) {
        nextIssues[host.id] =
            'Host references unavailable Group $groupId. Choose No group or a current Group to repair it.';
      }
    }
    _hostGroupReferenceIssues
      ..clear()
      ..addAll(nextIssues);
  }

  String? _jumpHostRouteIssueFor(
    HostRecord source,
    Map<String, HostRecord> hostsById,
  ) {
    var current = source;
    var depth = 0;
    final seen = <String>{source.id};
    while (current.jumpHostId != null) {
      final nextId = current.jumpHostId!;
      if (nextId == current.id && current.id == source.id && depth == 0) {
        return currentL10n.aHostCantUseItselfAs;
      }
      if (++depth > maxJumpHostHops) {
        return currentL10n.theJumpHostChainSupportsUp(maxJumpHostHops);
      }
      if (!seen.add(nextId)) return currentL10n.theJumpHostChainCantForm;
      final next = hostsById[nextId];
      if (next == null) {
        return currentL10n.theJumpHostChainContainsA;
      }
      if (next.protocol != HostProtocol.ssh) {
        return currentL10n.theJumpHostMustUseThe;
      }
      current = next;
    }
    return null;
  }

  List<HostAttachmentSummary> hostAttachments(String hostId) {
    final host = hosts.where((item) => item.id == hostId).firstOrNull;
    if (host == null) throw StateError(currentL10n.thisHostCouldntBeFound);
    return _hostAttachmentService().list(host);
  }

  Future<void> addHostAttachment({
    required String hostId,
    required String fileName,
    required String mediaType,
    required List<int> plaintext,
  }) async {
    _assertEditsAllowed(requireWritableVault: true);
    final vaultId = activeVault?.id;
    final host = hosts.where((item) => item.id == hostId).firstOrNull;
    if (vaultId == null || host == null) {
      throw StateError(currentL10n.theCurrentHostOrVaultIs);
    }
    await _hostAttachmentService().add(
      vaultId: vaultId,
      host: host,
      fileName: fileName,
      mediaType: mediaType,
      plaintext: plaintext,
      commit: saveHost,
    );
    // saveHost's first sync attempt may have found this record gated by its
    // durable transfer job. Recheck after the job is removed on success.
    _automaticSync.scheduleEdit();
  }

  Future<void> addHostAttachmentFromSource({
    required String hostId,
    required String fileName,
    required String mediaType,
    required AttachmentUploadSource source,
  }) async {
    _assertEditsAllowed(requireWritableVault: true);
    final vaultId = activeVault?.id;
    final host = hosts.where((item) => item.id == hostId).firstOrNull;
    if (vaultId == null || host == null) {
      throw StateError(currentL10n.theCurrentHostOrVaultIs);
    }
    await _hostAttachmentService().addFromSource(
      vaultId: vaultId,
      host: host,
      fileName: fileName,
      mediaType: mediaType,
      source: source,
      commit: saveHost,
    );
    _automaticSync.scheduleEdit();
  }

  Future<List<HostAttachmentTransferSummary>> hostAttachmentTransfers(
    String hostId,
  ) async {
    final vaultId = activeVault?.id;
    final host = hosts.where((item) => item.id == hostId).firstOrNull;
    if (vaultId == null || host == null) return const [];
    return _hostAttachmentService().transfers(vaultId, host);
  }

  Future<void> resumeHostAttachmentUpload({
    required String hostId,
    required String blobId,
  }) async {
    _assertEditsAllowed(requireWritableVault: true);
    final vaultId = activeVault?.id;
    final host = hosts.where((item) => item.id == hostId).firstOrNull;
    if (vaultId == null || host == null) {
      throw StateError(currentL10n.theCurrentHostOrVaultIs);
    }
    await _hostAttachmentService().resumeUpload(
      vaultId: vaultId,
      host: host,
      blobId: blobId,
    );
    _automaticSync.scheduleEdit();
    await refreshSyncStatus();
    notifyListeners();
  }

  Future<void> discardHostAttachmentUpload({
    required String hostId,
    required String blobId,
  }) async {
    final vaultId = activeVault?.id;
    final host = hosts.where((item) => item.id == hostId).firstOrNull;
    if (vaultId == null || host == null) {
      throw StateError(currentL10n.theCurrentHostOrVaultIs);
    }
    await _hostAttachmentService().discardOrphanUpload(
      vaultId: vaultId,
      host: host,
      blobId: blobId,
    );
    notifyListeners();
  }

  Future<Uint8List> downloadHostAttachment({
    required String hostId,
    required String blobId,
  }) async {
    final vaultId = activeVault?.id;
    final host = hosts.where((item) => item.id == hostId).firstOrNull;
    if (vaultId == null || host == null) {
      throw StateError(currentL10n.theCurrentHostOrVaultIs);
    }
    return _hostAttachmentService().download(
      vaultId: vaultId,
      host: host,
      blobId: blobId,
    );
  }

  Future<void> downloadHostAttachmentToSink({
    required String hostId,
    required String blobId,
    required Future<void> Function(Uint8List plaintextChunk) onPlaintextChunk,
  }) async {
    final vaultId = activeVault?.id;
    final host = hosts.where((item) => item.id == hostId).firstOrNull;
    if (vaultId == null || host == null) {
      throw StateError(currentL10n.theCurrentHostOrVaultIs);
    }
    await _hostAttachmentService().downloadToSink(
      vaultId: vaultId,
      host: host,
      blobId: blobId,
      onPlaintextChunk: onPlaintextChunk,
    );
  }

  Future<void> removeHostAttachment({
    required String hostId,
    required String blobId,
  }) async {
    _assertEditsAllowed(requireWritableVault: true);
    final host = hosts.where((item) => item.id == hostId).firstOrNull;
    if (host == null) throw StateError(currentL10n.thisHostCouldntBeFound);
    await _hostAttachmentService().remove(
      vaultId: activeVault!.id,
      host: host,
      blobId: blobId,
      commit: saveHost,
    );
    _automaticSync.scheduleEdit();
  }

  Future<void> completeHostAttachmentDownload({
    required String hostId,
    required String blobId,
  }) async {
    final vaultId = activeVault?.id;
    if (vaultId == null) return;
    await _hostAttachmentService().completeDownload(
      vaultId: vaultId,
      recordId: hostId,
      blobId: blobId,
    );
  }

  Future<void> discardHostAttachmentDownload({
    required String hostId,
    required String blobId,
  }) async {
    final vaultId = activeVault?.id;
    if (vaultId == null) return;
    await _hostAttachmentService().completeDownload(
      vaultId: vaultId,
      recordId: hostId,
      blobId: blobId,
    );
    notifyListeners();
  }

  HostAttachmentService _hostAttachmentService() => HostAttachmentService(
    api: _requireApi(),
    crypto: HostAttachmentCrypto(randomBytes: crypto.randomBytes),
    database: database,
    instanceId: _requireRepository().instanceId,
    serverSpaceId: _requireRepository().serverSpaceId,
    ensureDeviceCapabilityReported: _publishClientDeviceCapabilities,
    verifyV2ReaderCapability: (device) {
      try {
        final report = device['capability_report'];
        final userId = device['user_id'];
        final deviceId = device['device_id'];
        final signingText = device['signing_public_key'];
        if (report is! Map ||
            userId is! String ||
            deviceId is! String ||
            signingText is! String) {
          return false;
        }
        final signingKey = decodeBase64Url(signingText);
        if (signingKey.length != 32 ||
            encodeBase64Url(signingKey) != signingText) {
          return false;
        }
        crypto.verifyDeviceCapabilityReport(
          report: Map<String, dynamic>.from(report),
          expectedAccountId: userId,
          expectedDeviceId: deviceId,
          signingPublicKey: signingKey,
        );
        return true;
      } on Object {
        return false;
      }
    },
  );

  /// Publishes a device-signed capability statement when the server supports
  /// negotiation. Only platforms with a bounded temporary-file writer report
  /// schema 2, attachment v2, and the 1 GiB ceiling.
  Future<void> _publishClientDeviceCapabilities() async {
    final currentIdentity = identity;
    final currentAccount = account;
    final currentInstance = instance;
    final client = api;
    if (currentIdentity == null ||
        currentAccount == null ||
        currentInstance == null ||
        client == null) {
      return;
    }
    Object? publicationError;
    final genericCacheKey =
        '${client.baseUrl}:${currentInstance.serverSpaceId}:${currentInstance.generation}:${currentIdentity.deviceId}';
    if (currentInstance.capabilities.contains('device_capability_reports') &&
        _publishedDeviceCapabilitiesFor != genericCacheKey) {
      final retryAfter = _deviceCapabilityRetryAfter;
      if (retryAfter == null || !DateTime.now().isBefore(retryAfter)) {
        final unsigned = <String, Object?>{
          'account_id': currentAccount.accountId,
          'device_id': currentIdentity.deviceId,
          'revision': _clientDeviceCapabilityRevision,
          'max_record_schema': _clientMaxRecordSchema,
          'host_attachment_manifest_versions':
              _clientAttachmentManifestVersions,
          'max_attachment_bytes': _clientMaxAttachmentBytes,
        };
        try {
          await client.updateDeviceCapabilities(
            _signDeviceCapabilityReport(unsigned, currentIdentity),
          );
          _publishedDeviceCapabilitiesFor = genericCacheKey;
          _deviceCapabilityRetryAfter = null;
        } on Object catch (error) {
          _deviceCapabilityRetryAfter = DateTime.now().add(
            const Duration(minutes: 2),
          );
          publicationError = error;
        }
      }
    }

    if (currentInstance.capabilities.contains(
      'device_redaction_capability_reports',
    )) {
      try {
        await _publishClientRedactionCapability(
          client: client,
          currentInstance: currentInstance,
          currentAccountId: currentAccount.accountId,
          currentIdentity: currentIdentity,
        );
      } on Object catch (error) {
        publicationError ??= error;
      }
    }
    if (publicationError != null) throw publicationError;
  }

  Future<void> _publishClientRedactionCapability({
    required ApiClient client,
    required InstanceInfo currentInstance,
    required String currentAccountId,
    required DeviceIdentity currentIdentity,
    bool force = false,
  }) async {
    final scopeKey =
        '${client.baseUrl}:${currentInstance.instanceId}:${currentInstance.serverSpaceId}:${currentInstance.generation}:$currentAccountId:${currentIdentity.deviceId}';
    if (!force && _publishedRedactionCapabilitiesFor == scopeKey) return;
    final retryAfter = _redactionCapabilityRetryAfter;
    if (!force && retryAfter != null && DateTime.now().isBefore(retryAfter)) {
      return;
    }
    final active = _redactionCapabilityPublishInFlight;
    if (active != null) return active;

    late final Future<void> publishing;
    publishing = () async {
      final publisher = DeviceRedactionCapabilityPublisher(
        secureStore: secureStore,
        baseUrl: client.baseUrl,
        instanceId: currentInstance.instanceId,
        serverSpaceId: currentInstance.serverSpaceId,
        accountId: currentAccountId,
        deviceId: currentIdentity.deviceId,
        buildReport:
            ({required int revision, required int syncRedactionVersion}) {
              final unsigned = <String, Object?>{
                'format': 'atermius-sync-redaction-capability-v1',
                'account_id': currentAccountId,
                'device_id': currentIdentity.deviceId,
                'revision': revision,
                'sync_redaction_version': syncRedactionVersion,
              };
              return _signDeviceCapabilityReport(unsigned, currentIdentity);
            },
        sendReport: client.updateDeviceRedactionCapabilities,
      );
      try {
        await publisher.publish();
        _publishedRedactionCapabilitiesFor = scopeKey;
        _redactionCapabilityRetryAfter = null;
      } on Object {
        _redactionCapabilityRetryAfter = DateTime.now().add(
          const Duration(minutes: 2),
        );
        rethrow;
      }
    }();
    _redactionCapabilityPublishInFlight = publishing;
    try {
      await publishing;
    } finally {
      if (identical(_redactionCapabilityPublishInFlight, publishing)) {
        _redactionCapabilityPublishInFlight = null;
      }
    }
  }

  Map<String, Object?> _signDeviceCapabilityReport(
    Map<String, Object?> unsigned,
    DeviceIdentity signer,
  ) {
    final signature = sodium.crypto.sign.detached(
      message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
      secretKey: signer.signing.secretKey,
    );
    return {...unsigned, 'signature': encodeBase64Url(signature)};
  }

  Future<void> saveCredential(CredentialRecord credential) async {
    _assertEditsAllowed(requireWritableVault: true);
    if (credential.name.trim().isEmpty) {
      throw FormatException(currentL10n.theCredentialNameCantBeEmpty);
    }
    if (credential.username.trim().isEmpty) {
      throw FormatException(currentL10n.theCredentialUserNameCantBe);
    }
    if (credential.kind == AuthKind.password &&
        (credential.secret ?? '').isEmpty) {
      throw FormatException(currentL10n.thePasswordCantBeEmpty);
    }
    if (credential.kind == AuthKind.privateKey &&
        (credential.privateKey ?? '').isEmpty) {
      throw FormatException(currentL10n.thePrivateKeyCantBeEmpty);
    }
    final targetVaultId = activeVault?.id;
    if (targetVaultId == null) throw StateError(currentL10n.chooseAVaultFirst);
    final repository = _requireRepository();
    final envelope = await repository.saveRecord(
      recordId: credential.id,
      plaintext: credential.toJson(),
      baseRevisionId: _revisionIds[credential.id],
      operation: _revisionIds.containsKey(credential.id) ? 'update' : 'create',
    );
    if (activeVault?.id != targetVaultId) return;
    if (!identical(_repository, repository)) {
      await reloadRecords();
      return;
    }
    // A stale async Vault load must not clear this newly saved Credential.
    _recordsLoadGeneration++;
    _revisionIds[credential.id] =
        (envelope['header'] as Map<String, dynamic>)['revision_id'] as String;
    final index = credentials.indexWhere((item) => item.id == credential.id);
    if (index < 0) {
      credentials.add(credential);
    } else {
      credentials[index] = credential;
    }
    _setNotice(currentL10n.sshCredentialSavedEncryptedPlaintextIs);
    _automaticSync.scheduleEdit();
    try {
      await refreshSyncStatus();
    } catch (_) {
      // A status projection failure cannot roll back this encrypted write.
      _setNotice(currentL10n.theSshCredentialWasSavedEncrypted);
    }
    if (activeVault?.id == targetVaultId &&
        identical(_repository, repository)) {
      notifyListeners();
    }
  }

  Future<void> saveGroup(
    GroupRecord group, {
    bool Function()? isCurrentContext,
  }) => _serializeGroupMutation(
    () => _saveGroupLocked(group, isCurrentContext: isCurrentContext),
  );

  /// Creates a NEW Group only while [scope] is still the open repository
  /// (checked inside the mutation queue and after the write); returns the
  /// created revision, read inside the queue.
  Future<String> createGroupInScope(GroupRecord group, {required Object scope}) =>
      _serializeGroupMutation(() async {
        _requireRecordWriteScope(scope);
        if (_revisionIds.containsKey(group.id) ||
            groups.any((candidate) => candidate.id == group.id)) {
          throw FormatException(currentL10n.thisHostChangedAfterThePreview);
        }
        await _saveGroupLocked(
          group,
          isCurrentContext: () => identical(_repository, scope),
        );
        _requireRecordWriteScope(scope);
        final revision = _revisionIds[group.id];
        if (revision == null) {
          throw StateError(currentL10n.theWorkspaceWasSwitchedTryAgain);
        }
        return revision;
      });

  /// Body of [saveGroup]; callers must already hold the mutation queue.
  Future<void> _saveGroupLocked(
    GroupRecord group, {
    bool Function()? isCurrentContext,
  }) async {
    if (isCurrentContext != null && !isCurrentContext()) {
      throw StateError(currentL10n.theWorkspaceWasSwitchedTryAgain);
    }
    _assertEditsAllowed(requireWritableVault: true);
    if (activeVault?.canWrite != true || activeVault?.status != 'active') {
      throw StateError(currentL10n.theCurrentVaultIsReadOnly2);
    }
    final targetVaultId = activeVault?.id;
    if (targetVaultId == null) throw StateError(currentL10n.chooseAVaultFirst);
    final repository = _requireRepository();
    final referenceSnapshot = await repository
        .loadRecordsWithHeadRevisionSnapshot();
    if (activeVault?.id != targetVaultId ||
        !identical(_repository, repository)) {
      throw StateError(currentL10n.theVaultWasSwitchedReopenThe4);
    }
    if (repository.unavailableRecordIds.isNotEmpty) {
      throw FormatException(currentL10n.someLocalRecordsCouldntBeVerified);
    }
    final currentRevisionId = referenceSnapshot.headRevisionIds[group.id];
    if (currentRevisionId != _revisionIds[group.id]) {
      throw LocalRecordHeadChangedException(group.id);
    }
    final normalized = GroupRecord(
      id: group.id,
      name: group.name.trim(),
      color: group.color,
      parentId: group.parentId,
      defaultCredentialId: group.defaultCredentialId,
      manifest: group.manifest,
    );
    final catalog = _serverVaultCredentialReferenceCatalogFromRows(
      referenceSnapshot.records,
    );
    final validationError = _validateGroupAgainst(
      normalized,
      groups: catalog.groups,
      credentialIds: catalog.credentialsById.keys.toSet(),
    );
    if (validationError != null) throw FormatException(validationError);
    await beforeVaultReferenceWriteForTesting?.call(
      recordId: group.id,
      operation: currentRevisionId == null ? 'create' : 'update',
    );
    if (activeVault?.id != targetVaultId ||
        !identical(_repository, repository)) {
      throw StateError(currentL10n.theVaultWasSwitchedReopenThe4);
    }
    final envelope = await repository.saveRecord(
      recordId: group.id,
      plaintext: normalized.toJson(),
      baseRevisionId: currentRevisionId,
      expectedCachedHeadRevisionId: currentRevisionId,
      expectedVaultHeadRevisionIds: referenceSnapshot.headRevisionIds,
      operation: currentRevisionId == null ? 'create' : 'update',
    );
    // A Vault switch can race the local encrypted write. Keep its durable
    // outbox operation in the original repository, but never apply that
    // result to a different Vault's in-memory records.
    if (activeVault?.id != targetVaultId ||
        !identical(_repository, repository)) {
      return;
    }
    _revisionIds[group.id] =
        (envelope['header'] as Map<String, dynamic>)['revision_id'] as String;
    final index = groups.indexWhere((item) => item.id == group.id);
    if (index < 0) {
      groups.add(normalized);
    } else {
      groups[index] = normalized;
    }
    _rebuildHostGroupReferenceIssues();
    _setNotice(currentL10n.groupSavedEncryptedWaitingToSync);
    _automaticSync.scheduleEdit();
    try {
      await refreshSyncStatus();
    } catch (_) {
      // saveRecord has already committed the encrypted envelope and outbox
      // operation. A derived status refresh must not turn that durable write
      // into an apparent failure that invites a duplicate retry.
      _setNotice(currentL10n.theGroupWasSavedEncryptedAnd);
    }
    if (activeVault?.id != targetVaultId ||
        !identical(_repository, repository)) {
      return;
    }
    notifyListeners();
  }

  /// Validates a Server Vault Group against the decrypted records currently
  /// loaded for this Vault. The opaque server cannot enforce graph rules.
  String? validateGroup(GroupRecord group) => _validateGroupAgainst(
    group,
    groups: groups,
    credentialIds: credentials.map((credential) => credential.id).toSet(),
  );

  String? _validateGroupAgainst(
    GroupRecord group, {
    required List<GroupRecord> groups,
    required Set<String> credentialIds,
  }) {
    final name = group.name.trim();
    if (name.isEmpty) return currentL10n.enterAGroupName;
    if (utf8.encode(name).length > 256) {
      return currentL10n.theGroupNameCantExceed256;
    }
    if (RegExp(r'[\u0000-\u001f\u007f]').hasMatch(name)) {
      return currentL10n.theGroupNameContainsUnsupportedControl;
    }
    if (group.color < 0 || group.color > 0x7fffffff) {
      return currentL10n.invalidGroupColor;
    }
    if (group.defaultCredentialId != null &&
        !credentialIds.contains(group.defaultCredentialId)) {
      return currentL10n.theDefaultSshCredentialNoLonger;
    }

    final duplicate = groups.any(
      (existing) =>
          existing.id != group.id &&
          existing.parentId == group.parentId &&
          normalizeGroupName(existing.name) == normalizeGroupName(name),
    );
    if (duplicate) return currentL10n.aGroupWithThisNameAlready;

    if (group.parentId != null) {
      final parentError = _groupParentValidationErrorAgainst(
        groupId: group.id,
        parentId: group.parentId,
        groups: groups,
      );
      if (parentError != null) return parentError;
    }
    return null;
  }

  /// Identifies parent links that became invalid after independently synced
  /// Group revisions were combined from multiple devices.
  List<GroupRecord> get groupsNeedingParentRepair => List.unmodifiable(
    groups.where((group) {
      final parentId = group.parentId;
      return parentId != null &&
          _groupParentValidationError(groupId: group.id, parentId: parentId) !=
              null;
    }),
  );

  /// Resolves an explicit Host override first, then the nearest Group default.
  /// Missing IDs and broken parent chains remain visible for repair; they do
  /// not silently fall through to a more distant credential.
  HostCredentialResolution resolveHostCredential({
    required String? groupId,
    required String? hostCredentialId,
    HostRecord? host,
  }) {
    if (host?.login != null) {
      if (_controllerDisposed ||
          workspaceLocked ||
          _vaultLoadsBlocked ||
          stage != ClientStage.workspace ||
          activeVault == null ||
          !hosts.any(
            (current) => current.id == host!.id && current.login == host.login,
          )) {
        throw StateError(currentL10n.unlockTheWorkspaceThatContainsThe);
      }
      final issue = host!.validate();
      if (issue != null) throw FormatException(issue);
      return HostCredentialResolution(
        source: HostCredentialSource.hostOverride,
        credentialId: host.id,
        credential: host.login!.forHost(host),
      );
    }
    CredentialRecord? findCredential(String id) =>
        credentials.where((credential) => credential.id == id).firstOrNull;

    if (hostCredentialId != null) {
      return HostCredentialResolution(
        source: HostCredentialSource.hostOverride,
        credentialId: hostCredentialId,
        credential: findCredential(hostCredentialId),
      );
    }

    final byId = {for (final group in groups) group.id: group};
    final visited = <String>{};
    var currentId = groupId;
    while (currentId != null) {
      if (!visited.add(currentId)) {
        return HostCredentialResolution(
          source: HostCredentialSource.none,
          missingGroupId: currentId,
        );
      }
      final group = byId[currentId];
      if (group == null) {
        return HostCredentialResolution(
          source: HostCredentialSource.none,
          missingGroupId: currentId,
        );
      }
      final defaultCredentialId = group.defaultCredentialId;
      if (defaultCredentialId != null) {
        return HostCredentialResolution(
          source: HostCredentialSource.groupDefault,
          credentialId: defaultCredentialId,
          credential: findCredential(defaultCredentialId),
          sourceGroupId: group.id,
          sourceGroupName: group.name,
        );
      }
      currentId = group.parentId;
    }
    return const HostCredentialResolution(source: HostCredentialSource.none);
  }

  /// Whether [parentId] can be selected without creating an invalid chain.
  bool canUseGroupAsParent({
    required String groupId,
    required String parentId,
  }) =>
      _groupParentValidationError(groupId: groupId, parentId: parentId) == null;

  String? _groupParentValidationError({
    required String groupId,
    required String? parentId,
  }) => _groupParentValidationErrorAgainst(
    groupId: groupId,
    parentId: parentId,
    groups: groups,
  );

  String? _groupParentValidationErrorAgainst({
    required String groupId,
    required String? parentId,
    required List<GroupRecord> groups,
  }) {
    if (parentId == null) return null;
    if (parentId.isEmpty) return currentL10n.invalidParentGroupChooseAValid;

    final byId = {for (final group in groups) group.id: group};
    final visited = <String>{groupId};
    var cursor = parentId;
    while (true) {
      if (!visited.add(cursor)) {
        return currentL10n.aGroupCantBeMovedInto;
      }
      final parent = byId[cursor];
      if (parent == null) {
        return currentL10n.theParentGroupNoLongerExists2;
      }
      final nextParentId = parent.parentId;
      if (nextParentId == null) return null;
      cursor = nextParentId;
    }
  }

  Future<void> saveSnippet(SnippetRecord snippet) async {
    _assertEditsAllowed(requireWritableVault: true);
    if (snippet.title.trim().isEmpty) {
      throw FormatException(currentL10n.theSnippetTitleCantBeEmpty);
    }
    validateSnippetDefinition(snippet);
    if (snippet.executionMode == SnippetExecutionMode.script &&
        snippet.body.trim().isEmpty) {
      throw FormatException(currentL10n.theSnippetCommandCantBeEmpty);
    }
    final targetVaultId = activeVault?.id;
    if (targetVaultId == null) throw StateError(currentL10n.chooseAVaultFirst);
    final repository = _requireRepository();
    final referenceSnapshot = await repository
        .loadRecordsWithHeadRevisionSnapshot();
    if (activeVault?.id != targetVaultId ||
        !identical(_repository, repository)) {
      throw StateError(currentL10n.theVaultWasSwitchedReopenThe5);
    }
    if (repository.unavailableRecordIds.isNotEmpty) {
      throw FormatException(currentL10n.someLocalRecordsCouldntBeVerified2);
    }
    final currentRevisionId = referenceSnapshot.headRevisionIds[snippet.id];
    if (currentRevisionId != _revisionIds[snippet.id]) {
      throw LocalRecordHeadChangedException(snippet.id);
    }
    final catalog = _serverVaultCredentialReferenceCatalogFromRows(
      referenceSnapshot.records,
    );
    for (final parameter in snippet.parameters) {
      if (parameter.type != SnippetParameterType.credentialSecret) continue;
      final credentialId = parameter.credentialId;
      final credential = credentialId == null
          ? null
          : catalog.credentialsById[credentialId];
      if (credential == null ||
          credential.kind != AuthKind.password ||
          (credential.secret ?? '').isEmpty) {
        throw FormatException(
          currentL10n.thePasswordCredentialReferencedBySnippet(parameter.name),
        );
      }
    }
    await beforeVaultReferenceWriteForTesting?.call(
      recordId: snippet.id,
      operation: currentRevisionId == null ? 'create' : 'update',
    );
    if (activeVault?.id != targetVaultId ||
        !identical(_repository, repository)) {
      throw StateError(currentL10n.theVaultWasSwitchedReopenThe5);
    }
    final envelope = await repository.saveRecord(
      recordId: snippet.id,
      plaintext: snippet.toJson(),
      baseRevisionId: currentRevisionId,
      expectedCachedHeadRevisionId: currentRevisionId,
      expectedVaultHeadRevisionIds: referenceSnapshot.headRevisionIds,
      operation: currentRevisionId == null ? 'create' : 'update',
    );
    if (activeVault?.id != targetVaultId ||
        !identical(_repository, repository)) {
      return;
    }
    _revisionIds[snippet.id] =
        (envelope['header'] as Map<String, dynamic>)['revision_id'] as String;
    final index = snippets.indexWhere((item) => item.id == snippet.id);
    if (index < 0) {
      snippets.add(snippet);
    } else {
      snippets[index] = snippet;
    }
    await refreshSyncStatus();
    _automaticSync.scheduleEdit();
    notifyListeners();
  }

  /// Saves the currently open terminal tab order as an encrypted named
  /// Workspace. Only stable Host IDs and the active pane are serialized.
  Future<void> saveCurrentWorkspace(String name) async {
    final tabs = terminalTabs;
    if (tabs.isEmpty) throw StateError(currentL10n.openAtLeastOneTerminalTab);
    final hostIds = <String>[];
    for (final tab in tabs) {
      final id = tab.host?.id;
      if (id == null || !hosts.any((host) => host.id == id)) {
        throw StateError(currentL10n.aHostReferencedByTheTerminal);
      }
      hostIds.add(id);
    }
    final activeIndex = tabs.indexWhere((tab) => tab.id == activeTerminalTabId);
    final record = WorkspaceRecord.fromHostIds(
      name: name,
      hostIds: hostIds,
      activeIndex: activeIndex < 0 ? 0 : activeIndex,
    );
    await _saveWorkspaceRecord(record);
  }

  /// Saves a disconnected two-pane split as a new encrypted Workspace.
  ///
  /// [hostIds] are ordered from the first pane to the second. The split
  /// direction and bounded divider ratio are layout intent only; this does
  /// not start SSH or Relay work.
  Future<void> saveSplitWorkspace({
    required String name,
    required List<String> hostIds,
    required WorkspaceSplitAxis axis,
    int splitRatioBasisPoints = 5000,
    int activeIndex = 0,
  }) async {
    if (hostIds.length != 2) {
      throw FormatException(currentL10n.splitWorkspacesRequireExactlyTwoHosts);
    }
    final record = WorkspaceRecord.fromSplitHostIds(
      name: name,
      hostIds: hostIds,
      axis: axis,
      splitRatioBasisPoints: splitRatioBasisPoints,
      activeIndex: activeIndex,
    );
    await _saveWorkspaceRecord(record);
  }

  /// Saves a disconnected nested split layout to the active encrypted Vault.
  ///
  /// This records Host references and geometry only. It does not create SSH
  /// sessions or contact the Relay; each terminal pane remains explicit.
  Future<void> saveWorkspaceLayout({
    required String name,
    required WorkspaceLayoutNode layoutTree,
    required String activePaneId,
  }) async {
    final record = WorkspaceRecord.fromSplitTree(
      name: name,
      layoutTree: layoutTree,
      activePaneId: activePaneId,
    );
    for (final hostId in record.hostRefs) {
      if (!hosts.any((host) => host.id == hostId)) {
        throw StateError(currentL10n.nestedWorkspacesCanOnlyReferenceExisting);
      }
    }
    await _saveWorkspaceRecord(record);
  }

  Future<void> renameWorkspace(String workspaceId, String name) async {
    final record = _requireWorkspace(workspaceId);
    await _saveWorkspaceRecord(record.copyWith(name: name));
  }

  Future<void> duplicateWorkspace(String workspaceId, String name) async {
    final source = _requireWorkspace(workspaceId);
    final copy = source.duplicateWithNewIdentity(name: name);
    await _saveWorkspaceRecord(
      copy,
      inheritedHostRefs: source.hostRefs.toSet(),
    );
  }

  Future<void> replaceWorkspaceHost(
    String workspaceId,
    String paneId,
    String replacementHostId,
  ) async {
    final record = _requireWorkspace(workspaceId);
    if (!hosts.any((host) => host.id == replacementHostId)) {
      throw StateError(currentL10n.onlyExistingHostsInTheCurrent);
    }
    final index = record.panes.indexWhere((pane) => pane.paneId == paneId);
    if (index < 0) throw StateError(currentL10n.theWorkspacePaneNoLongerExists);
    final hostIds = record.hostIds.toList();
    hostIds[index] = replacementHostId;
    await _saveWorkspaceRecord(
      record.copyWith(hostIds: hostIds, activeIndex: record.activeIndex),
    );
  }

  Future<void> removeWorkspacePane(String workspaceId, String paneId) async {
    final record = _requireWorkspace(workspaceId);
    try {
      await _saveWorkspaceRecord(record.withoutPane(paneId));
    } on FormatException catch (error) {
      throw StateError(error.message);
    }
  }

  /// Stages a saved layout in the Terminal page. It never starts SSH or Relay
  /// work; each pane is connected only by [connectWorkspacePane].
  void stageWorkspace(String workspaceId) {
    _requireWorkspace(workspaceId);
    _stagedWorkspaceSelectionGeneration++;
    activeSavedWorkspaceId = workspaceId;
    showWorkspacePage(WorkspacePage.terminal);
  }

  void clearStagedWorkspace() {
    _stagedWorkspaceSelectionGeneration++;
    activeSavedWorkspaceId = null;
    notifyListeners();
  }

  Future<void> connectWorkspacePane(String workspaceId, String paneId) {
    final expectedVaultId = activeVault?.id;
    if (expectedVaultId == null) {
      return Future<void>.error(StateError(currentL10n.chooseAVaultFirst));
    }
    final key = (
      vaultId: expectedVaultId,
      workspaceId: workspaceId,
      paneId: paneId,
    );
    final existingFlight = _workspacePaneConnectFlights[key];
    if (existingFlight != null) return existingFlight;

    final completer = Completer<void>();
    final flight = completer.future;
    _workspacePaneConnectFlights[key] = flight;
    unawaited(
      _runWorkspacePaneConnect(
        key: key,
        flight: flight,
        completer: completer,
        expectedVaultId: expectedVaultId,
        workspaceId: workspaceId,
        paneId: paneId,
      ),
    );
    return flight;
  }

  Future<void> _runWorkspacePaneConnect({
    required ({String vaultId, String workspaceId, String paneId}) key,
    required Future<void> flight,
    required Completer<void> completer,
    required String expectedVaultId,
    required String workspaceId,
    required String paneId,
  }) async {
    try {
      await _connectWorkspacePane(
        expectedVaultId: expectedVaultId,
        workspaceId: workspaceId,
        paneId: paneId,
      );
      completer.complete();
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    } finally {
      if (identical(_workspacePaneConnectFlights[key], flight)) {
        _workspacePaneConnectFlights.remove(key);
      }
    }
  }

  Future<void> _connectWorkspacePane({
    required String expectedVaultId,
    required String workspaceId,
    required String paneId,
  }) async {
    final record = _requireWorkspace(workspaceId);
    final pane = record.panes
        .where((item) => item.paneId == paneId)
        .firstOrNull;
    if (pane == null) {
      throw StateError(currentL10n.theWorkspacePaneNoLongerExists);
    }
    // Resolve strictly by stable ID in the currently active Vault. Missing
    // hosts never fall back to their label, endpoint, or another Vault.
    final host = hosts.where((item) => item.id == pane.hostId).firstOrNull;
    if (host == null) {
      throw StateError(currentL10n.thisWorkspaceHostNoLongerExists);
    }
    activeSavedWorkspaceId = workspaceId;
    page = WorkspacePage.terminal;
    final existingTab = workspacePaneTerminalTab(workspaceId, paneId);
    if (existingTab != null &&
        (existingTab.connection != null ||
            existingTab.telnet != null ||
            existingTab.state == 'connecting')) {
      activateTerminalTab(existingTab.id);
      return;
    }
    _workspacePaneTerminalTabIds.putIfAbsent(workspaceId, () => {})
      ..remove(paneId);
    await _openTerminalTab(
      host,
      expectedVaultId: expectedVaultId,
      onTabOpened: (tabId) {
        _workspacePaneTerminalTabIds.putIfAbsent(
          workspaceId,
          () => {},
        )[paneId] = tabId;
      },
    );
  }

  /// Starts a user-requested tmux session on one already-connected Workspace
  /// pane, then saves only its fixed-format name in the encrypted Workspace.
  /// Workspace loading and ordinary Connect never call this method.
  Future<void> startWorkspacePaneTmux(String workspaceId, String paneId) =>
      _runWorkspacePaneTmux(
        workspaceId: workspaceId,
        paneId: paneId,
        resume: false,
      );

  /// Resumes the exact encrypted tmux reference for one pane. This never
  /// creates a missing session and reuses the pane's current SSH transport.
  Future<void> resumeWorkspacePaneTmux(String workspaceId, String paneId) =>
      _runWorkspacePaneTmux(
        workspaceId: workspaceId,
        paneId: paneId,
        resume: true,
      );

  /// Removes the local encrypted reference without killing or otherwise
  /// changing the remote tmux session.
  Future<void> clearWorkspacePaneTmuxReference(
    String workspaceId,
    String paneId,
  ) async {
    final workspace = _requireWorkspace(workspaceId);
    if (workspacePaneSessionDescriptor(workspaceId, paneId) == null) return;
    try {
      await _saveWorkspaceRecord(workspace.withoutSessionDescriptor(paneId));
    } on Object {
      throw StateError(currentL10n.couldntSaveChangesToTheTmux);
    }
  }

  Future<void> _runWorkspacePaneTmux({
    required String workspaceId,
    required String paneId,
    required bool resume,
  }) async {
    final context = await _resolveWorkspaceTmuxContext(workspaceId, paneId);
    final descriptor = workspacePaneSessionDescriptor(workspaceId, paneId);
    if (resume && descriptor == null) {
      throw StateError(currentL10n.thisWorkspacePaneHasNoSaved);
    }
    if (!resume && descriptor != null) {
      throw StateError(currentL10n.thisWorkspacePaneAlreadyHasA);
    }
    if (_tmuxAttachHandles.containsKey(context.tab.id)) {
      throw StateError(currentL10n.thisWorkspacePaneIsAlreadyAttached);
    }
    final busyKey = _workspaceTmuxKey(context.vaultId, workspaceId, paneId);
    if (_workspaceTmuxBusyKeys.contains(busyKey) ||
        _tmuxOperationCancellations.containsKey(context.tab.id)) {
      throw StateError(currentL10n.thisWorkspacePaneIsRunningA);
    }
    _workspaceTmuxBusyKeys.add(busyKey);
    final cancellation = SshExecCancellation();
    _tmuxOperationCancellations[context.tab.id] = cancellation;
    notifyListeners();

    var createdByThisOperation = false;
    var createOutcomeUnknown = false;
    var descriptorCommittedToOutbox = false;
    WorkspaceSessionDescriptor? startedDescriptor;
    try {
      final service = tmuxServiceForTesting ?? _defaultTmuxService;
      final probe = await service.probe(
        context.connection,
        cancellation: cancellation,
      );
      await _verifyWorkspaceTmuxContext(
        workspaceId: workspaceId,
        paneId: paneId,
        context: context,
        expectedDescriptor: descriptor,
      );
      if (probe != TmuxProbeStatus.available) {
        throw StateError(currentL10n.tmuxIsntAvailableOnTheCurrent);
      }

      final sessionName = resume
          ? descriptor!.tmuxSessionName
          : WorkspaceSessionDescriptor.createForPane(
              paneId: paneId,
              hostId: context.pane.hostId,
            ).tmuxSessionName;
      final sessionStatus = await service.hasSession(
        context.connection,
        sessionName,
        cancellation: cancellation,
      );
      await _verifyWorkspaceTmuxContext(
        workspaceId: workspaceId,
        paneId: paneId,
        context: context,
        expectedDescriptor: descriptor,
      );
      if (sessionStatus == TmuxSessionStatus.unavailable) {
        throw StateError(currentL10n.tmuxIsntAvailableOnTheCurrent);
      }

      if (resume) {
        if (sessionStatus != TmuxSessionStatus.exists) {
          throw StateError(currentL10n.theSavedTmuxSessionNoLonger);
        }
      } else {
        // A generated name must be unused. An existing name is never attached
        // or overwritten as part of Start.
        if (sessionStatus != TmuxSessionStatus.absent) {
          throw StateError(currentL10n.couldntCreateANewTmuxSession);
        }
        startedDescriptor = WorkspaceSessionDescriptor(
          paneId: paneId,
          hostId: context.pane.hostId,
          tmuxSessionName: sessionName,
        );
        try {
          await service.createSession(
            context.connection,
            sessionName,
            cancellation: cancellation,
          );
          createdByThisOperation = true;
        } on TmuxServiceException catch (error) {
          createOutcomeUnknown = switch (error.reason) {
            TmuxServiceFailureReason.timeout ||
            TmuxServiceFailureReason.cancelled ||
            TmuxServiceFailureReason.transportFailure => true,
            TmuxServiceFailureReason.invalidSessionName ||
            TmuxServiceFailureReason.invalidTerminalSize ||
            TmuxServiceFailureReason.commandFailure => false,
          };
          rethrow;
        } on Object {
          // Injectable adapters and unexpected transport wrappers can fail
          // after the remote server has accepted the create command.
          createOutcomeUnknown = true;
          rethrow;
        }
        await _verifyWorkspaceTmuxContext(
          workspaceId: workspaceId,
          paneId: paneId,
          context: context,
          expectedDescriptor: descriptor,
        );
        final createdStatus = await service.hasSession(
          context.connection,
          sessionName,
          cancellation: cancellation,
        );
        if (createdStatus != TmuxSessionStatus.exists) {
          throw StateError(currentL10n.couldntConfirmTheTmuxSessionStarted);
        }

        final updated = context.workspace.withSessionDescriptor(
          startedDescriptor,
        );
        await _saveWorkspaceRecord(
          updated,
          onLocalCommit: () => descriptorCommittedToOutbox = true,
        );
        await _verifyWorkspaceTmuxContext(
          workspaceId: workspaceId,
          paneId: paneId,
          context: context,
          expectedDescriptor: startedDescriptor,
        );
      }

      final handle = await service.openAttach(
        context.connection,
        sessionName,
        columns: context.tab.terminal.viewWidth,
        rows: context.tab.terminal.viewHeight,
        cancellation: cancellation,
      );
      if (cancellation.isCancelled) {
        handle.close();
        throw StateError(currentL10n.theSshConnectionClosedReconnectThe);
      }
      await _verifyWorkspaceTmuxContext(
        workspaceId: workspaceId,
        paneId: paneId,
        context: context,
        expectedDescriptor: resume ? descriptor : startedDescriptor,
      );
      await _installTmuxAttach(context.tab, context.connection, handle);
      _setNotice(
        resume
            ? currentL10n.attachedToTheSavedTmuxSession
            : currentL10n.theTmuxSessionStartedAndWas,
      );
    } on Object catch (error) {
      // If the create acknowledgement was lost, reconcile the exact random
      // name before leaving an orphaned remote session. A committed reference
      // must never be left pointing at a session we killed as compensation.
      if ((createdByThisOperation || createOutcomeUnknown) &&
          !descriptorCommittedToOutbox &&
          startedDescriptor != null) {
        try {
          final cleanupService = tmuxServiceForTesting ?? _defaultTmuxService;
          final cleanupStatus = await cleanupService.hasSession(
            context.connection,
            startedDescriptor.tmuxSessionName,
          );
          if (cleanupStatus == TmuxSessionStatus.exists) {
            await cleanupService.killSession(
              context.connection,
              startedDescriptor.tmuxSessionName,
            );
          }
        } on Object {
          // The fixed, random session name is safe to leave for manual cleanup
          // if the transport or server no longer accepts the compensating kill.
        }
      }
      final message = _workspaceTmuxErrorMessage(error);
      _setError(message);
      throw StateError(message);
    } finally {
      if (identical(
        _tmuxOperationCancellations[context.tab.id],
        cancellation,
      )) {
        _tmuxOperationCancellations.remove(context.tab.id);
      }
      _workspaceTmuxBusyKeys.remove(busyKey);
      notifyListeners();
    }
  }

  Future<
    ({
      String vaultId,
      WorkspaceRecord workspace,
      WorkspacePane pane,
      TerminalTabSession tab,
      SshConnection connection,
    })
  >
  _resolveWorkspaceTmuxContext(String workspaceId, String paneId) async {
    final vaultId = activeVault?.id;
    if (vaultId == null) throw StateError(currentL10n.chooseAVaultFirst);
    final workspace = _requireWorkspace(workspaceId);
    final pane = workspace.panes
        .where((item) => item.paneId == paneId)
        .firstOrNull;
    if (pane == null) {
      throw StateError(currentL10n.theWorkspacePaneNoLongerExists);
    }
    final host = hosts.where((item) => item.id == pane.hostId).firstOrNull;
    if (host == null) {
      throw StateError(currentL10n.thisWorkspaceHostNoLongerExists);
    }
    final tab = workspacePaneTerminalTab(workspaceId, paneId);
    final connection = tab?.connection;
    if (tab == null ||
        connection == null ||
        tab.state != 'connected' ||
        tab.host?.id != pane.hostId ||
        canonicalJson(host.toJson()) != canonicalJson(tab.host?.toJson())) {
      throw StateError(currentL10n.connectTheHostForThisWorkspace);
    }
    await _validateTerminalTabSshBinding(tab, host);
    if (activeVault?.id != vaultId ||
        !_isTerminalTabOpen(tab) ||
        !identical(tab.connection, connection) ||
        !identical(workspacePaneTerminalTab(workspaceId, paneId), tab)) {
      throw StateError(currentL10n.theVaultOrSshConnectionChanged);
    }
    return (
      vaultId: vaultId,
      workspace: workspace,
      pane: pane,
      tab: tab,
      connection: connection,
    );
  }

  Future<void> _validateTerminalTabSshBinding(
    TerminalTabSession tab,
    HostRecord targetHost,
  ) async {
    final expectedHostIds = <String>{targetHost.id};
    late final List<_ResolvedJumpHop> route;
    try {
      route = _resolveJumpHostConnection(targetHost);
    } on Object {
      throw StateError(currentL10n.theSshHostOrJumpHost);
    }
    expectedHostIds.addAll(route.map((hop) => hop.host.id));
    if (expectedHostIds.length != tab.connectionCredentialFingerprints.length ||
        !expectedHostIds.containsAll(
          tab.connectionCredentialFingerprints.keys,
        ) ||
        !tab.connectionCredentialFingerprints.keys.toSet().containsAll(
          expectedHostIds,
        )) {
      throw StateError(currentL10n.theSshHostOrJumpHost);
    }

    for (final hostId in expectedHostIds) {
      final currentHost = hosts.where((item) => item.id == hostId).firstOrNull;
      final snapshot = tab.connectionHostSnapshots[hostId];
      if (currentHost == null ||
          snapshot == null ||
          canonicalJson(currentHost.toJson()) != snapshot) {
        throw StateError(currentL10n.theSshHostOrJumpHost);
      }
      final credential = resolveHostCredential(
        host: currentHost,
        groupId: currentHost.groupId,
        hostCredentialId: currentHost.credentialId,
      ).credential;
      if (credential == null) {
        throw StateError(currentL10n.theSshCredentialChangedReconnectThe);
      }
      final credentialSnapshot = canonicalJson(credential.toJson());
      final fingerprint = await _fingerprintConnectionCredential(credential);
      final latestHost = hosts.where((item) => item.id == hostId).firstOrNull;
      final latestCredential = latestHost == null
          ? null
          : resolveHostCredential(
              host: latestHost,
              groupId: latestHost.groupId,
              hostCredentialId: latestHost.credentialId,
            ).credential;
      if (latestHost == null ||
          canonicalJson(latestHost.toJson()) != snapshot ||
          latestCredential == null ||
          canonicalJson(latestCredential.toJson()) != credentialSnapshot ||
          tab.connectionCredentialFingerprints[hostId] != fingerprint) {
        throw StateError(currentL10n.theSshCredentialOrHostSettings);
      }
    }
  }

  Future<void> _verifyWorkspaceTmuxContext({
    required String workspaceId,
    required String paneId,
    required ({
      String vaultId,
      WorkspaceRecord workspace,
      WorkspacePane pane,
      TerminalTabSession tab,
      SshConnection connection,
    })
    context,
    required WorkspaceSessionDescriptor? expectedDescriptor,
  }) async {
    if (activeVault?.id != context.vaultId ||
        !_isTerminalTabOpen(context.tab) ||
        !identical(context.tab.connection, context.connection)) {
      throw StateError(currentL10n.theVaultOrSshConnectionChanged);
    }
    final workspace = savedWorkspaces
        .where((item) => item.id == workspaceId)
        .firstOrNull;
    final pane = workspace?.panes
        .where((item) => item.paneId == paneId)
        .firstOrNull;
    if (pane == null ||
        pane.hostId != context.pane.hostId ||
        !identical(
          workspacePaneTerminalTab(workspaceId, paneId),
          context.tab,
        )) {
      throw StateError(currentL10n.theWorkspacePaneOrHostReference);
    }
    final host = hosts.where((item) => item.id == pane.hostId).firstOrNull;
    if (host == null ||
        canonicalJson(host.toJson()) !=
            canonicalJson(context.tab.host?.toJson())) {
      throw StateError(currentL10n.theSshHostSettingsChangedReconnect);
    }
    await _validateTerminalTabSshBinding(context.tab, host);
    if (activeVault?.id != context.vaultId ||
        !_isTerminalTabOpen(context.tab) ||
        !identical(context.tab.connection, context.connection)) {
      throw StateError(currentL10n.theVaultOrSshConnectionChanged);
    }
    final currentDescriptor = workspacePaneSessionDescriptor(
      workspaceId,
      paneId,
    );
    if (expectedDescriptor == null
        ? currentDescriptor != null
        : currentDescriptor?.tmuxSessionName !=
                  expectedDescriptor.tmuxSessionName ||
              currentDescriptor?.hostId != expectedDescriptor.hostId) {
      throw StateError(currentL10n.theWorkspaceTmuxReferenceChangedReload);
    }
  }

  Future<void> _installTmuxAttach(
    TerminalTabSession tab,
    SshConnection connection,
    TmuxAttachHandle handle,
  ) async {
    final previousSubscription = tab.outputSubscription;
    await previousSubscription?.cancel();
    if (!_isTerminalTabOpen(tab) || !identical(tab.connection, connection)) {
      handle.close();
      throw StateError(currentL10n.theSshConnectionClosedReconnectThe);
    }
    _tmuxAttachHandles[tab.id] = handle;
    tab.outputSubscription = utf8.decoder
        .bind(handle.stdout)
        .listen(
          (text) {
            if (!_isTerminalTabOpen(tab) ||
                !identical(tab.connection, connection) ||
                !identical(_tmuxAttachHandles[tab.id], handle)) {
              return;
            }
            tab.terminal.write(text);
            tab.outputListener?.call(text);
            tab.publishOutputToFanout(text);
            if (_activeTerminalTabId == tab.id) {
              _legacyTerminalOutputListener?.call(text);
            }
          },
          onError: (Object error) {
            _handleTerminalConnectionEnded(tab, connection, error: error);
          },
          onDone: () => _handleTerminalConnectionEnded(tab, connection),
        );
    // The first shell is no longer interactive. Closing only its SSH channel
    // keeps this authenticated SSHClient (and Relay transport) available for
    // the tmux PTY, SFTP, and port forwarding.
    try {
      connection.session.close();
    } on Object {
      // Lightweight test connectors may not expose a concrete shell channel.
    }
  }

  String _workspaceTmuxErrorMessage(Object error) {
    if (error is TmuxServiceException) {
      return switch (error.reason) {
        TmuxServiceFailureReason.cancelled =>
          currentL10n.theSshConnectionClosedReconnectThe,
        TmuxServiceFailureReason.timeout =>
          currentL10n.theTmuxActionTimedOutCheck,
        TmuxServiceFailureReason.invalidSessionName ||
        TmuxServiceFailureReason.invalidTerminalSize ||
        TmuxServiceFailureReason.commandFailure ||
        TmuxServiceFailureReason.transportFailure =>
          currentL10n.couldntCompleteTheTmuxSessionAction,
      };
    }
    if (error is StateError) {
      return error.message;
    }
    return currentL10n.couldntCompleteTheTmuxSessionAction;
  }

  String _workspaceTmuxKey(
    String? vaultId,
    String workspaceId,
    String paneId,
  ) => '$vaultId|$workspaceId|$paneId';

  Future<void> deleteWorkspace(String workspaceId) async {
    _assertEditsAllowed(requireWritableVault: true);
    final workspace = _requireWorkspace(workspaceId);
    final targetVaultId = activeVault?.id;
    if (targetVaultId == null) throw StateError(currentL10n.chooseAVaultFirst);
    final repository = _requireRepository();
    await repository.saveRecord(
      recordId: workspaceId,
      plaintext: {'id': workspaceId, 'type': 'workspace', 'deleted': true},
      baseRevisionId: _revisionIds[workspaceId] ?? workspace.revisionId,
      operation: 'delete',
    );
    if (activeVault?.id != targetVaultId) return;
    if (!identical(_repository, repository)) {
      // A membership/control-plane refresh can rebuild the Repository while
      // this local encrypted write is in flight. The write still belongs to
      // this Vault, so reload through the replacement Repository instead of
      // leaving the committed Workspace out of the current UI projection.
      await reloadRecords();
      return;
    }
    _revisionIds.remove(workspaceId);
    savedWorkspaces.removeWhere((item) => item.id == workspaceId);
    _workspacePaneTerminalTabIds.remove(workspaceId);
    if (activeSavedWorkspaceId == workspaceId) activeSavedWorkspaceId = null;
    _setNotice(currentL10n.theWorkspaceDeletionWasSavedEncrypted);
    _automaticSync.scheduleEdit();
    try {
      await refreshSyncStatus();
    } catch (_) {
      _setNotice(currentL10n.theWorkspaceDeletionWasAddedTo);
    }
    notifyListeners();
  }

  WorkspaceRecord _requireWorkspace(String workspaceId) =>
      savedWorkspaces.where((item) => item.id == workspaceId).firstOrNull ??
      (throw StateError(currentL10n.theWorkspaceNoLongerExistsIn));

  Future<void> _saveWorkspaceRecord(
    WorkspaceRecord workspace, {
    Set<String> inheritedHostRefs = const {},
    void Function()? onLocalCommit,
  }) async {
    _assertEditsAllowed(requireWritableVault: true);
    final targetVaultId = activeVault?.id;
    if (targetVaultId == null) throw StateError(currentL10n.chooseAVaultFirst);
    final repository = _requireRepository();
    final existing = savedWorkspaces
        .where((item) => item.id == workspace.id)
        .firstOrNull;
    final allowedMissing = <String>{
      ...?existing?.hostRefs,
      ...inheritedHostRefs,
    };
    for (final hostId in workspace.hostRefs) {
      if (!hosts.any((host) => host.id == hostId) &&
          !allowedMissing.contains(hostId)) {
        throw StateError(currentL10n.workspacesCanOnlyAddReferencesTo);
      }
    }
    final envelope = await repository.saveRecord(
      recordId: workspace.id,
      plaintext: workspace.toJson(),
      baseRevisionId: _revisionIds[workspace.id] ?? workspace.revisionId,
      operation: existing == null ? 'create' : 'update',
    );
    // SyncRepository.saveRecord returns after the encrypted record and its
    // operation are committed locally. Track this before profile-switch early
    // returns so tmux compensation cannot invalidate a descriptor in the old
    // Vault's outbox.
    onLocalCommit?.call();
    if (activeVault?.id != targetVaultId) return;
    if (!identical(_repository, repository)) {
      // A membership/control-plane refresh can rebuild the Repository while
      // this local encrypted write is in flight. The write still belongs to
      // this Vault, so reload through the replacement Repository instead of
      // leaving the committed Workspace out of the current UI projection.
      await reloadRecords();
      return;
    }
    // Invalidate any earlier record snapshot that is still loading. Otherwise
    // an old reload could clear this newly saved Workspace after it is added
    // to the local projection.
    _recordsLoadGeneration++;
    final revisionId =
        (envelope['header'] as Map<String, dynamic>)['revision_id'] as String;
    _revisionIds[workspace.id] = revisionId;
    final saved = workspace.copyWith(revisionId: revisionId);
    final index = savedWorkspaces.indexWhere((item) => item.id == workspace.id);
    if (index < 0) {
      savedWorkspaces.add(saved);
    } else {
      savedWorkspaces[index] = saved;
    }
    _setNotice(currentL10n.workspaceSavedEncryptedWaitingToSync);
    _automaticSync.scheduleEdit();
    try {
      await refreshSyncStatus();
    } catch (_) {
      _setNotice(currentL10n.theWorkspaceWasSavedEncryptedAnd);
    }
    if (activeVault?.id == targetVaultId &&
        identical(_repository, repository)) {
      notifyListeners();
    }
  }

  Future<void> deleteHost(HostRecord host) => _serializeGroupMutation(() async {
    _assertEditsAllowed(requireWritableVault: true);
    final dependants = hosts
        .where(
          (candidate) =>
              candidate.id != host.id && candidate.jumpHostId == host.id,
        )
        .length;
    if (dependants > 0) {
      throw FormatException(currentL10n.thisHostIsStillUsedAs(dependants));
    }
    await _deleteRecord(host.id, 'host', cleanupAttachmentJobs: true);
  });
  Future<void> deleteCredential(CredentialRecord item) =>
      _serializeGroupMutation(() async {
        _assertEditsAllowed(requireWritableVault: true);
        final targetVaultId = activeVault?.id;
        if (targetVaultId == null) {
          throw StateError(currentL10n.chooseAVaultFirst);
        }
        final repository = _requireRepository();
        final referenceSnapshot = await repository
            .loadRecordsWithHeadRevisionSnapshot();
        if (activeVault?.id != targetVaultId ||
            !identical(_repository, repository)) {
          throw StateError(currentL10n.theVaultWasSwitchedReopenThe2);
        }
        if (repository.unavailableRecordIds.isNotEmpty) {
          throw FormatException(currentL10n.someLocalRecordsCouldntBeVerified4);
        }
        final catalog = _serverVaultCredentialReferenceCatalogFromRows(
          referenceSnapshot.records,
        );
        final targetRevisionId = referenceSnapshot.headRevisionIds[item.id];
        if (!catalog.credentialsById.containsKey(item.id) ||
            targetRevisionId == null) {
          throw FormatException(currentL10n.thisSshCredentialNoLongerExists);
        }
        if (_revisionIds[item.id] != targetRevisionId) {
          throw LocalRecordHeadChangedException(item.id);
        }
        final groupCount = catalog.groups
            .where((group) => group.defaultCredentialId == item.id)
            .length;
        final hostCount = catalog.hosts
            .where((host) => host.credentialId == item.id)
            .length;
        final snippetParameterCount = catalog.snippets
            .expand((snippet) => snippet.parameters)
            .where(
              (parameter) =>
                  parameter.type == SnippetParameterType.credentialSecret &&
                  parameter.credentialId == item.id,
            )
            .length;
        if (groupCount > 0 || hostCount > 0 || snippetParameterCount > 0) {
          throw FormatException(
            currentL10n.thisSshCredentialIsStillReferenced(
              groupCount,
              hostCount,
              snippetParameterCount,
            ),
          );
        }
        await beforeVaultReferenceWriteForTesting?.call(
          recordId: item.id,
          operation: 'delete',
        );
        if (activeVault?.id != targetVaultId ||
            !identical(_repository, repository)) {
          throw StateError(currentL10n.theVaultWasSwitchedReopenThe2);
        }
        await _deleteRecord(
          item.id,
          'credential',
          baseRevisionIdOverride: targetRevisionId,
          expectedCachedHeadRevisionId: targetRevisionId,
          expectedVaultHeadRevisionIds: referenceSnapshot.headRevisionIds,
        );
      });
  Future<void> deleteSnippet(SnippetRecord item) =>
      _deleteRecord(item.id, 'snippet');
  Future<void> deleteGroup(GroupRecord item) =>
      _serializeGroupMutation(() async {
        _assertEditsAllowed(requireWritableVault: true);
        if (activeVault?.canWrite != true || activeVault?.status != 'active') {
          throw StateError(currentL10n.theCurrentVaultIsReadOnly3);
        }
        final targetVaultId = activeVault?.id;
        if (targetVaultId == null) {
          throw StateError(currentL10n.chooseAVaultFirst);
        }
        final repository = _requireRepository();
        final referenceSnapshot = await repository
            .loadRecordsWithHeadRevisionSnapshot();
        if (activeVault?.id != targetVaultId ||
            !identical(_repository, repository)) {
          throw StateError(currentL10n.theVaultWasSwitchedReopenThe4);
        }
        if (repository.unavailableRecordIds.isNotEmpty) {
          throw FormatException(currentL10n.someLocalRecordsCouldntBeVerified);
        }
        final currentRevisionId = referenceSnapshot.headRevisionIds[item.id];
        if (currentRevisionId == null ||
            _revisionIds[item.id] != currentRevisionId) {
          throw LocalRecordHeadChangedException(item.id);
        }
        final catalog = _serverVaultCredentialReferenceCatalogFromRows(
          referenceSnapshot.records,
        );
        if (!catalog.groups.any((group) => group.id == item.id)) {
          throw FormatException(currentL10n.thisGroupNoLongerExistsOr);
        }
        final hostCount = catalog.hosts
            .where((host) => host.groupId == item.id)
            .length;
        final childCount = catalog.groups
            .where((group) => group.id != item.id && group.parentId == item.id)
            .length;
        if (hostCount > 0 || childCount > 0) {
          throw FormatException(
            currentL10n.thisGroupIsStillReferencedBy(hostCount, childCount),
          );
        }
        await beforeVaultReferenceWriteForTesting?.call(
          recordId: item.id,
          operation: 'delete',
        );
        if (activeVault?.id != targetVaultId ||
            !identical(_repository, repository)) {
          throw StateError(currentL10n.theVaultWasSwitchedReopenThe4);
        }
        await repository.saveRecord(
          recordId: item.id,
          plaintext: {'id': item.id, 'type': 'group', 'deleted': true},
          baseRevisionId: currentRevisionId,
          expectedCachedHeadRevisionId: currentRevisionId,
          expectedVaultHeadRevisionIds: referenceSnapshot.headRevisionIds,
          operation: 'delete',
        );
        if (activeVault?.id != targetVaultId ||
            !identical(_repository, repository)) {
          return;
        }
        _revisionIds.remove(item.id);
        groups.removeWhere((group) => group.id == item.id);
        _rebuildHostGroupReferenceIssues();
        _setNotice(currentL10n.theGroupDeletionWasSavedEncrypted2);
        _automaticSync.scheduleEdit();
        try {
          await refreshSyncStatus();
        } catch (_) {
          _setNotice(currentL10n.theGroupDeletionWasSavedEncrypted);
        }
        if (activeVault?.id != targetVaultId ||
            !identical(_repository, repository)) {
          return;
        }
        notifyListeners();
      });

  /// Runs relationship-changing writes in order within this controller.
  /// The opaque server still cannot enforce these graph rules across devices.
  Future<T> _serializeGroupMutation<T>(Future<T> Function() action) {
    final previous = _groupMutationTail;
    final completion = Completer<void>();
    _groupMutationTail = completion.future;
    return () async {
      try {
        await previous;
        return await action();
      } finally {
        completion.complete();
      }
    }();
  }

  Future<void> _deleteRecord(
    String id,
    String type, {
    bool cleanupAttachmentJobs = false,
    String? baseRevisionIdOverride,
    String? expectedCachedHeadRevisionId,
    Map<String, String>? expectedVaultHeadRevisionIds,
  }) async {
    _assertEditsAllowed(requireWritableVault: true);
    final targetVaultId = activeVault?.id;
    if (targetVaultId == null) throw StateError(currentL10n.chooseAVaultFirst);
    final repository = _requireRepository();
    final base = _revisionIds[id];
    await repository.saveRecord(
      recordId: id,
      plaintext: {'id': id, 'type': type, 'deleted': true},
      baseRevisionId: baseRevisionIdOverride ?? base,
      expectedCachedHeadRevisionId: expectedCachedHeadRevisionId,
      expectedVaultHeadRevisionIds: expectedVaultHeadRevisionIds,
      operation: 'delete',
      cleanupAttachmentJobsOnDelete: cleanupAttachmentJobs,
    );
    if (activeVault?.id != targetVaultId) return;
    if (!identical(_repository, repository)) {
      await reloadRecords();
      return;
    }
    // Prevent an in-flight pre-delete snapshot from restoring the removed row.
    _recordsLoadGeneration++;
    _revisionIds.remove(id);
    hosts.removeWhere((item) => item.id == id);
    _rebuildJumpHostRouteIssues();
    credentials.removeWhere((item) => item.id == id);
    groups.removeWhere((item) => item.id == id);
    _rebuildHostGroupReferenceIssues();
    snippets.removeWhere((item) => item.id == id);
    savedWorkspaces.removeWhere((item) => item.id == id);
    _workspacePaneTerminalTabIds.remove(id);
    if (activeSavedWorkspaceId == id) activeSavedWorkspaceId = null;
    _setNotice(currentL10n.theDeletionWasSavedAsAn);
    _automaticSync.scheduleEdit();
    try {
      await refreshSyncStatus();
    } catch (_) {
      _setNotice(currentL10n.theDeletionTombstoneWasSavedEncrypted);
    }
    if (activeVault?.id == targetVaultId &&
        identical(_repository, repository)) {
      notifyListeners();
    }
  }

  Future<List<RecycleBinRecord>> loadRecycleBin() async {
    final targetVaultId = activeVault?.id;
    if (targetVaultId == null) throw StateError(currentL10n.chooseAVaultFirst);
    final repository = _requireRepository();
    if (repository.vaultId != targetVaultId) {
      throw StateError(currentL10n.theVaultWasSwitchedReopenThe3);
    }
    return repository.loadRecycleBin();
  }

  /// Changes future-purge consent for exactly the selected tombstone.
  /// Vault owners can opt in; bounded Maintenance may purge an opted-in
  /// tombstone after its restore deadline and required checks.
  Future<void> setRecycleBinRecordAutomaticPurge(
    RecycleBinRecord entry, {
    required bool enabled,
  }) => _serializeGroupMutation(() async {
    _assertEditsAllowed(requireWritableVault: true);
    final targetVault = activeVault;
    if (targetVault == null) throw StateError(currentL10n.chooseAVaultFirst);
    if (targetVault.role != 'owner') {
      throw StateError(currentL10n.onlyTheCurrentVaultOwnerCan);
    }
    if (targetVault.status != 'active' || !targetVault.canWrite) {
      throw StateError(currentL10n.theCurrentVaultIsReadOnly4);
    }

    final repository = _requireRepository();
    if (repository.vaultId != targetVault.id) {
      throw StateError(currentL10n.theVaultWasSwitchedReopenThe3);
    }
    final currentIdentity = identity;
    final currentAccount = account;
    final currentInstance = instance;
    final currentClient = api;
    if (currentIdentity == null ||
        currentAccount == null ||
        currentInstance == null ||
        currentClient == null) {
      throw StateError(currentL10n.signInAndUnlockTheTarget);
    }

    await repository.setRecycleBinRecordAutomaticPurge(entry, enabled: enabled);
    if (activeVault?.id != targetVault.id ||
        !identical(_repository, repository) ||
        !identical(api, currentClient) ||
        !identical(identity, currentIdentity) ||
        account?.accountId != currentAccount.accountId ||
        !identical(instance, currentInstance)) {
      throw StateError(currentL10n.theVaultOrSignInSession);
    }
    notifyListeners();
  });

  Future<RecordRedactionProof> purgeRecycleBinRecord(
    RecycleBinRecord entry,
  ) => _serializeGroupMutation(() async {
    _assertEditsAllowed(requireWritableVault: true);
    final targetVault = activeVault;
    if (targetVault == null) throw StateError(currentL10n.chooseAVaultFirst);
    if (targetVault.role != 'owner') {
      throw StateError(currentL10n.onlyTheCurrentVaultOwnerCan2);
    }
    if (targetVault.status != 'active' || !targetVault.canWrite) {
      throw StateError(currentL10n.theCurrentVaultIsReadOnly5);
    }
    final restoreUntil = entry.restoreUntil;
    if (restoreUntil == null) {
      throw StateError(currentL10n.theServerDidntProvideAVerifiable);
    }
    if (DateTime.now().toUtc().isBefore(restoreUntil.toUtc())) {
      throw ApiException(
        statusCode: 409,
        code: 'RECORD_PURGE_NOT_DUE',
        message: currentL10n.theServerRestorePeriodHasNot,
        details: {'restore_until': restoreUntil.toUtc().toIso8601String()},
      );
    }

    final repository = _requireRepository();
    if (repository.vaultId != targetVault.id) {
      throw StateError(currentL10n.theVaultWasSwitchedReopenThe3);
    }
    final currentIdentity = identity;
    final currentAccount = account;
    final currentInstance = instance;
    final currentClient = api;
    if (currentIdentity == null ||
        currentAccount == null ||
        currentInstance == null ||
        currentClient == null) {
      throw StateError(currentL10n.signInAndUnlockTheTarget);
    }
    if (currentInstance.capabilities.contains(
      'device_redaction_capability_reports',
    )) {
      // Purge compatibility is a hard precondition. Unlike best-effort sync
      // discovery, a failed signed report publication must stop this request.
      await _publishClientRedactionCapability(
        client: currentClient,
        currentInstance: currentInstance,
        currentAccountId: currentAccount.accountId,
        currentIdentity: currentIdentity,
      );
    }
    if (activeVault?.id != targetVault.id ||
        !identical(_repository, repository) ||
        !identical(api, currentClient) ||
        !identical(identity, currentIdentity)) {
      throw StateError(currentL10n.theVaultOrSignInSession);
    }

    final proof = await repository.purgeRecycleBinRecord(entry);
    if (activeVault?.id != targetVault.id ||
        !identical(_repository, repository)) {
      return proof;
    }
    await reloadRecords();
    if (activeVault?.id != targetVault.id ||
        !identical(_repository, repository)) {
      return proof;
    }

    // The repository has already verified and atomically applied the proof.
    // A normal sync pulls the redaction marker and commits its cursor before
    // attempting any remaining outbox push. If catch-up is unavailable, the
    // queued sync retries under the same pull-before-push rule.
    _automaticSync.scheduleEdit();
    try {
      await synchronize(suppressSuccessNotice: true);
    } catch (_) {
      _setNotice(currentL10n.theRecordWasClearedFromThis);
    }
    if (activeVault?.id == targetVault.id &&
        identical(_repository, repository)) {
      notifyListeners();
    }
    return proof;
  });

  Future<void> restoreRecycleBinRecord(RecycleBinRecord entry) =>
      _serializeGroupMutation(() async {
        _assertEditsAllowed(requireWritableVault: true);
        final targetVaultId = activeVault?.id;
        if (targetVaultId == null) {
          throw StateError(currentL10n.chooseAVaultFirst);
        }
        final repository = _requireRepository();
        if (repository.vaultId != targetVaultId) {
          throw StateError(currentL10n.theVaultWasSwitchedReopenThe3);
        }
        await repository.restoreRecycleBinRecord(
          recordId: entry.recordId,
          expectedTombstoneRevisionId: entry.tombstoneRevisionId,
          expectedPreviousRevisionId:
              entry.previousRevisionId ??
              (throw StateError(currentL10n.thisRecordHasNoHistoricalVersion)),
          validateReferences: _validateRecycleBinRestoreReferences,
        );
        if (activeVault?.id != targetVaultId ||
            !identical(_repository, repository)) {
          return;
        }
        await reloadRecords();
        if (activeVault?.id != targetVaultId ||
            !identical(_repository, repository)) {
          return;
        }
        _setNotice(currentL10n.restoreIsEncryptedLocallyAndWaiting);
        _automaticSync.scheduleEdit();
        try {
          await synchronize(suppressSuccessNotice: true);
        } on ApiException catch (error) {
          if (error.code == 'RECORD_RESTORE_EXPIRED') {
            await reloadRecords();
            rethrow;
          }
          _setNotice(currentL10n.restoreIsSafelyQueuedOnThis);
        } catch (_) {
          _setNotice(currentL10n.restoreIsSafelyQueuedOnThis);
        }
        try {
          await refreshSyncStatus();
        } catch (_) {
          _setNotice(currentL10n.restoreIsEncryptedAndQueuedOn);
        }
        if (activeVault?.id == targetVaultId &&
            identical(_repository, repository)) {
          notifyListeners();
        }
      });

  String? _validateRecycleBinRestoreReferences(
    Map<String, Object?> candidate,
    List<Map<String, dynamic>> currentRecords,
  ) {
    final type = candidate['type'];
    final hosts = currentRecords
        .where((record) => record['type'] == RecordKind.host.name)
        .map((record) => HostRecord.fromJson(record))
        .toList(growable: false);
    final groups = currentRecords
        .where((record) => record['type'] == RecordKind.group.name)
        .map((record) => GroupRecord.fromJson(record))
        .toList(growable: false);
    final credentials = currentRecords
        .where((record) => record['type'] == RecordKind.credential.name)
        .map((record) => CredentialRecord.fromJson(record))
        .toList(growable: false);
    switch (type) {
      case 'host':
        final host = HostRecord.fromJson(Map<String, dynamic>.from(candidate));
        return host.validate() ??
            _validateHostReferencesAgainst(
              host,
              hosts: hosts,
              groups: groups,
              credentials: credentials,
            );
      case 'group':
        final group = GroupRecord.fromJson(
          Map<String, dynamic>.from(candidate),
        );
        return _validateGroupAgainst(
          group,
          groups: groups,
          credentialIds: credentials.map((item) => item.id).toSet(),
        );
      case 'snippet':
        final snippet = SnippetRecord.fromJson(
          Map<String, dynamic>.from(candidate),
        );
        final credentialIds = credentials.map((item) => item.id).toSet();
        if (snippet.parameters.any(
          (parameter) =>
              parameter.credentialId != null &&
              !credentialIds.contains(parameter.credentialId),
        )) {
          return currentL10n.thisSnippetReferencesACredentialThat;
        }
        return null;
      case 'workspace':
        final workspace = WorkspaceRecord.fromJson(
          Map<String, dynamic>.from(candidate),
        );
        final hostIds = hosts.map((host) => host.id).toSet();
        if (workspace.hostRefs.any((hostId) => !hostIds.contains(hostId))) {
          return currentL10n.thisWorkspaceReferencesAHostThat;
        }
        return null;
      case 'credential':
        CredentialRecord.fromJson(Map<String, dynamic>.from(candidate));
        return null;
      case 'knownHost':
        KnownHostRecord.fromJson(Map<String, dynamic>.from(candidate));
        return null;
      case 'preference':
        VaultPreferenceRecord.fromJson(Map<String, dynamic>.from(candidate));
        return null;
      case 'shellHistory':
        ShellHistoryRecord.fromJson(Map<String, dynamic>.from(candidate));
        return null;
      default:
        return currentL10n.thisRecordTypeCannotBeRestored;
    }
  }

  DateTime _currentControlPlaneTime() =>
      nowForTesting?.call() ?? DateTime.now();

  bool get _accountControlPlaneRefreshIsDue {
    final last = _lastAccountControlPlaneRefreshAt;
    if (last == null) return false;
    final now = _currentControlPlaneTime();
    return now.isBefore(last) ||
        now.difference(last) >= _accountControlPlaneRefreshInterval;
  }

  LockedSyncReceiver? get lockedSyncReceiverForTesting => _lockedSyncReceiver;

  @visibleForTesting
  Future<void> receiveWhileLockedForTesting() =>
      _receiveWhileLocked(background: true);

  void _resumeLockedReceiveForAuthenticatedSession() {
    ++_lockedReceiveStopGeneration;
    _lockedReceiveStopping = false;
  }

  Future<void> _receiveWhileLocked({required bool background}) async {
    if (!workspaceLocked ||
        !authenticated ||
        _lockedReceiveRunning ||
        _lockedReceiveStopping ||
        _lockedUnlockInProgress) {
      return;
    }
    final vault = activeVault;
    final info = instance;
    final client = api;
    if (vault == null || info == null || client == null) {
      syncStatus = 'locked_no_vault';
      notifyListeners();
      return;
    }
    final receiver = _lockedSyncReceiver ??= LockedSyncReceiver(
      api: client,
      database: database,
      crypto: crypto,
      instanceId: info.instanceId,
      serverSpaceId: info.serverSpaceId,
      vaultId: vault.id,
      serverGeneration: info.generation,
      trustedInstanceSigningPublicKey: info.signingPublicKey,
    );
    if (receiver.vaultId != vault.id ||
        receiver.serverGeneration != info.generation ||
        !identical(receiver.api, client)) {
      _lockedSyncReceiver = LockedSyncReceiver(
        api: client,
        database: database,
        crypto: crypto,
        instanceId: info.instanceId,
        serverSpaceId: info.serverSpaceId,
        vaultId: vault.id,
        serverGeneration: info.generation,
        trustedInstanceSigningPublicKey: info.signingPublicKey,
      );
    }
    final activeReceiver = _lockedSyncReceiver!;
    _lockedReceiveRunning = true;
    final receiveCompletion = Completer<void>();
    _lockedReceiveCompletion = receiveCompletion;
    syncing = true;
    syncStatus = 'locked_receiving';
    errorMessage = null;
    notifyListeners();
    try {
      lockedInboxReceivedCount = await activeReceiver.receive();
      if (workspaceLocked && identical(_lockedSyncReceiver, activeReceiver)) {
        syncStatus = 'locked_ready';
        _syncPassCompletions++;
      }
    } on LockedSyncGenerationChangedException {
      if (workspaceLocked && identical(_lockedSyncReceiver, activeReceiver)) {
        syncStatus = 'unlock_required';
        errorMessage = currentL10n.theServerSyncGenerationChangedUnlock;
        _automaticSync.stop();
      }
      if (!background) rethrow;
    } on ApiException catch (error) {
      if (workspaceLocked && identical(_lockedSyncReceiver, activeReceiver)) {
        syncStatus = switch (error.code) {
          'CURSOR_EXPIRED' || 'SERVER_GENERATION_CHANGED' => 'unlock_required',
          'DEVICE_REVOKED' || 'VAULT_ACCESS_REVOKED' => 'revoked',
          'AUTH_REQUIRED' => 'auth_required',
          _ => error.isRetryable ? 'retry_wait' : error.code.toLowerCase(),
        };
        if (syncStatus == 'unlock_required') _automaticSync.stop();
        errorMessage = background ? null : friendlyError(error);
      }
      if (!background) rethrow;
    } catch (error) {
      if (workspaceLocked && identical(_lockedSyncReceiver, activeReceiver)) {
        syncStatus = 'retry_wait';
        errorMessage = background ? null : friendlyError(error);
      }
      if (!background) rethrow;
    } finally {
      _lockedReceiveRunning = false;
      syncing = false;
      if (identical(_lockedReceiveCompletion, receiveCompletion)) {
        _lockedReceiveCompletion = null;
      }
      receiveCompletion.complete();
      if (workspaceLocked) notifyListeners();
    }
  }

  Future<void> _waitForLockedReceiveCompletion() async {
    while (true) {
      final completion = _lockedReceiveCompletion;
      if (completion == null) return;
      await completion.future;
    }
  }

  Future<void> synchronize({
    bool background = false,
    bool suppressSuccessNotice = false,
  }) async {
    final automatic = _nextSyncIsAutomatic;
    _nextSyncIsAutomatic = false;
    final initialSelectionGeneration = _vaultSelectionGeneration;
    if (databaseRecoveryRequired) {
      _syncAgainRequested = false;
      errorMessage = const DatabaseRecoveryRequiredException().toString();
      notifyListeners();
      return;
    }
    if (syncStatus == 'snapshot_too_large') {
      if (!background) {
        errorMessage = SnapshotBootstrapLimitException.message;
        notifyListeners();
      }
      return;
    }
    if (snapshotRecoveryActive) return;
    if (workspaceLocked) {
      await _receiveWhileLocked(background: background);
      return;
    }
    if (_membershipRefreshActive) {
      // A sync wake-up can arrive while the signed account/Vault refresh is
      // still rebuilding the repository. Wait for that state transition and
      // retry against the refreshed repository instead of treating the stale
      // Idle label as a completed sync.
      while (_membershipRefreshActive) {
        final membershipRefresh = _membershipRefreshFuture;
        try {
          if (membershipRefresh != null) {
            await membershipRefresh;
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        } catch (error) {
          if (initialSelectionGeneration != _vaultSelectionGeneration) return;
          if (!background) rethrow;
          if (authenticated && stage == ClientStage.workspace) {
            syncStatus = error is ApiException
                ? error.code.toLowerCase()
                : 'retry_wait';
            notifyListeners();
          }
          return;
        }
      }
      if (initialSelectionGeneration != _vaultSelectionGeneration) return;
      if (!authenticated ||
          stage != ClientStage.workspace ||
          snapshotRecoveryActive ||
          _vaultMembershipChangeActive) {
        return;
      }
      // Automatic sync may have been turned off while this trigger waited.
      if (automatic && !automaticSyncActive) return;
      await _synchronizeMarked(automatic: automatic, background: background);
      return;
    }
    if (_vaultMembershipChangeActive) return;
    // During a Vault transition the old repository may remain in the field
    // until its replacement is built. Never start a new pass against that old
    // repository under the newly selected Vault identity.
    if (_repository == null || _repository!.vaultId != activeVault?.id) return;
    if (syncing) {
      if (!identical(_activeSyncRepository, _repository) ||
          _activeSyncSelectionGeneration != _vaultSelectionGeneration) {
        // A selection transition invalidates the previous controller gate;
        // its repository continues draining independently.
        syncing = false;
        _syncAgainRequested = false;
        _activeSyncCompletion = null;
        _activeSyncRepository = null;
        _activeSyncSelectionGeneration = null;
      }
    }
    if (syncing) {
      _syncAgainAutomaticOnly =
          automatic && (!_syncAgainRequested || _syncAgainAutomaticOnly);
      _syncAgainRequested = true;
      // The active pass will start one serialized follow-up. Await both so an
      // explicit caller does not report completion while its queued request
      // is still pending or only the pre-refresh pass has finished.
      var activeSync = _activeSyncCompletion;
      while (activeSync != null) {
        await activeSync.future;
        final nextSync = _activeSyncCompletion;
        if (nextSync == null || identical(nextSync, activeSync)) break;
        activeSync = nextSync;
      }
      return;
    }
    if (authenticated &&
        stage == ClientStage.workspace &&
        _accountControlPlaneRefreshIsDue) {
      // The signed account refresh is part of this explicit sync request.
      // Publish a non-idle state before its first await so observers cannot
      // mistake the still-visible Idle status for completed synchronization.
      final statusBeforeControlPlaneRefresh = syncStatus;
      syncStatus = 'syncing';
      errorMessage = null;
      notifyListeners();
      try {
        // This is deliberately before setting `syncing`: the membership
        // refresh waits for any active sync to finish, then rebuilds the
        // repository from the newly verified device/Vault control plane.
        await _reloadVaultsForMembershipHint();
      } catch (error) {
        if (initialSelectionGeneration != _vaultSelectionGeneration) return;
        if (authenticated && stage == ClientStage.workspace) {
          syncStatus = error is ApiException
              ? error.code.toLowerCase()
              : 'retry_wait';
          errorMessage = background ? null : friendlyError(error);
          notifyListeners();
        }
        if (!background) rethrow;
        return;
      }
      if (initialSelectionGeneration != _vaultSelectionGeneration) return;
      if (!authenticated ||
          stage != ClientStage.workspace ||
          snapshotRecoveryActive) {
        return;
      }
      // The signed refresh is control plane only. Do not start the content
      // pass for an automatic trigger that was turned off meanwhile, and do
      // not leave the provisional Syncing label behind.
      if (automatic && !automaticSyncActive) {
        if (!syncing && syncStatus == 'syncing') {
          syncStatus = statusBeforeControlPlaneRefresh;
          notifyListeners();
        }
        return;
      }
    }
    final repository = _repository;
    if (repository == null) return;
    final runSelectionGeneration = _vaultSelectionGeneration;
    final runSelectionRequestGeneration = _vaultSelectionRequestGeneration;
    final syncCompletion = Completer<void>();
    bool syncIsCurrent() =>
        runSelectionGeneration == _vaultSelectionGeneration &&
        identical(_repository, repository) &&
        repository.vaultId == activeVault?.id;
    bool syncSelectionRequestIsCurrent() =>
        runSelectionRequestGeneration == _vaultSelectionRequestGeneration;
    bool syncOwnsGate() =>
        identical(_activeSyncCompletion, syncCompletion) &&
        identical(_activeSyncRepository, repository) &&
        _activeSyncSelectionGeneration == runSelectionGeneration;
    void releaseOwnedSyncGate() {
      if (!syncOwnsGate()) return;
      syncing = false;
      _syncAgainRequested = false;
      _activeSyncCompletion = null;
      _activeSyncRepository = null;
      _activeSyncSelectionGeneration = null;
    }

    syncing = true;
    _activeSyncCompletion = syncCompletion;
    _activeSyncRepository = repository;
    _activeSyncSelectionGeneration = runSelectionGeneration;
    syncStatus = 'syncing';
    errorMessage = null;
    var reloadMembershipAndRetry = false;
    notifyListeners();
    try {
      final result = await repository.synchronize();
      if (!syncIsCurrent()) return;
      syncStatus = result.status;
      _syncPassCompletions++;
      pendingCount = result.pendingCount;
      receivedCount = result.receivedCount;
      conflictCount = result.conflictCount;
      await reloadRecords();
      if (!syncIsCurrent()) return;
      await _loadConflictSummaries();
      if (!syncIsCurrent()) return;
      if (result.status == 'deletion_pending') {
        try {
          await refreshVaultLifecycle();
        } catch (_) {
          // Preserve the non-retry deletion state even if the status refresh
          // itself is temporarily unavailable.
        }
        if (!syncIsCurrent()) return;
      }
      if (result.status == 'idle' && !background && !suppressSuccessNotice) {
        _setNotice(
          currentL10n.syncCompleteReceivedcountChangesReceived(
            result.receivedCount,
          ),
        );
      }
    } catch (error) {
      if (!syncIsCurrent()) {
        // A different Vault has taken over the controller while this
        // repository's network operation was in flight. Ignore its result and
        // error; the old pass still drains its own key-operation lease.
      } else {
        final staleVersion =
            error is ApiException &&
            error.statusCode == 409 &&
            const {
              'KEY_EPOCH_OUTDATED',
              'MEMBERSHIP_VERSION_CONFLICT',
            }.contains(error.code);
        final missingControlPlaneEntry =
            error is SyncControlPlaneRefreshRequiredException;
        // A revoked Vault is intentionally indistinguishable from an absent one
        // on read routes. Refresh signed membership once so an offline client
        // drops access before it can retry the old Vault's encrypted outbox.
        final missingVaultAccess =
            error is ApiException &&
            error.statusCode == 404 &&
            error.code == 'NOT_FOUND';
        if ((staleVersion || missingControlPlaneEntry || missingVaultAccess) &&
            !_membershipRefreshRetryInProgress) {
          // A missed membership-change hint (for example while this device was
          // offline) or a structurally valid change from a not-yet-known signer
          // can be repaired from the signed control plane before retrying. For a
          // known signer, the repository verifies the envelope before declaring
          // its key absent. Outbox rewrites still require a separate, exact
          // stale-version rejection under this refreshed current key state.
          reloadMembershipAndRetry = true;
          syncStatus = 'epoch_update_required';
          errorMessage = null;
        } else if (missingControlPlaneEntry) {
          // One verified control-plane refresh and page replay are allowed per
          // call. If the server still cannot provide this signer's key or the
          // relevant Vault epoch, stop without checkpointing or touching the
          // pending outbox and wait for the next explicit/periodic retry.
          syncStatus = 'epoch_update_required';
          errorMessage = background
              ? null
              : currentL10n.theVaultKeyStateStillCant;
        } else {
          syncStatus = error is ApiException
              ? error.code.toLowerCase()
              : 'retry_wait';
          if (background) {
            errorMessage = null;
          } else {
            errorMessage = friendlyError(error);
            rethrow;
          }
        }
      }
    } finally {
      if (!syncOwnsGate()) {
        // Only complete this invocation's waiter. Selection has already
        // reset the shared sync gate for the new repository.
        if (!syncCompletion.isCompleted) syncCompletion.complete();
      } else if (!syncIsCurrent()) {
        // A repository can be rebuilt for the same selected Vault while this
        // pass drains. It still owns its old gate, so release that gate but
        // never publish the retired repository's result or status.
        releaseOwnedSyncGate();
        if (!syncCompletion.isCompleted) syncCompletion.complete();
      } else {
        try {
          await refreshSyncStatus(keepStatus: true);
        } catch (_) {
          if (!background && syncOwnsGate()) rethrow;
        } finally {
          if (!syncOwnsGate()) {
            if (!syncCompletion.isCompleted) syncCompletion.complete();
          } else if (!syncIsCurrent()) {
            releaseOwnedSyncGate();
            if (!syncCompletion.isCompleted) syncCompletion.complete();
          } else {
            // A follow-up requested only by automatic triggers is dropped when
            // automatic sync was turned off meanwhile; explicit requests run.
            final automaticFollowUp = _syncAgainAutomaticOnly;
            final runAgain =
                _syncAgainRequested &&
                (!automaticFollowUp || automaticSyncActive);
            releaseOwnedSyncGate();
            if (runAgain &&
                syncSelectionRequestIsCurrent() &&
                authenticated &&
                stage == ClientStage.workspace) {
              // A hint/manual request that arrived during a sync is coalesced
              // into exactly one serialized follow-up after the current state
              // refresh. Keep this pass's completion pending until that
              // follow-up finishes.
              try {
                await _synchronizeMarked(
                  automatic: automaticFollowUp,
                  background: true,
                );
              } catch (_) {
                // Background synchronization reports retry state through the
                // controller and must not strand callers on this pass.
              }
            }
            if (!syncCompletion.isCompleted) syncCompletion.complete();
            if (syncIsCurrent()) notifyListeners();
          }
        }
      }
    }
    if (reloadMembershipAndRetry &&
        syncIsCurrent() &&
        syncSelectionRequestIsCurrent()) {
      _membershipRefreshRetryInProgress = true;
      try {
        await _reloadVaultsForMembershipHint();
        if (!syncSelectionRequestIsCurrent()) return;
        // A revoked member may no longer have this Vault in the list. Keep its
        // encrypted outbox untouched and do not silently sync a different
        // selected Vault as the retry for the rejected one.
        if (activeVault?.id != repository.vaultId) {
          // If the signed roster removed the repository's Vault, mark that
          // rejected scope revoked only when the user has not requested a
          // different selection while the refresh was in flight. Never let an
          // old Vault result overwrite the status for a newly selected Vault.
          if (activeVault == null && syncSelectionRequestIsCurrent()) {
            syncStatus = 'revoked';
            errorMessage = null;
            notifyListeners();
          }
          return;
        }
        if (_repository?.vaultId != repository.vaultId) {
          syncStatus = 'revoked';
          notifyListeners();
          return;
        }
        // The retry is a new pass. An automatic pass whose trigger was turned
        // off while the membership refresh ran stops here (its outbox stays
        // queued); explicit callers keep their retry.
        if (automatic && !automaticSyncActive) return;
        await _synchronizeMarked(
          automatic: automatic,
          background: background,
          suppressSuccessNotice: suppressSuccessNotice,
        );
      } catch (error) {
        if (!syncSelectionRequestIsCurrent() ||
            activeVault?.id != repository.vaultId) {
          return;
        }
        if (!background) rethrow;
        errorMessage = null;
      } finally {
        _membershipRefreshRetryInProgress = false;
        if (syncSelectionRequestIsCurrent() &&
            (activeVault?.id == repository.vaultId ||
                _repository?.vaultId == repository.vaultId)) {
          notifyListeners();
        }
      }
    }
  }

  /// Waits for an existing background pass, then performs and waits for a sync
  /// pass on the exact migration target. Unrelated pending operations,
  /// conflicts, and retryable sync failures do not decide migration success:
  /// the migration flow verifies each staged record and its exact commit state
  /// independently before it releases the LocalVault write freeze. A fresh,
  /// generation-checked server pull is still required so stale cached commit
  /// receipts cannot certify a target after cursor expiry or generation drift.
  Future<void> synchronizeMigrationTarget(String targetVaultId) async {
    if (activeVault?.id != targetVaultId ||
        _repository?.vaultId != targetVaultId) {
      throw StateError(currentL10n.theSyncVaultWasSwitchedMigration);
    }
    final startingRepository = _repository!;
    final startingServerViewRevision =
        startingRepository.verifiedServerViewRevision;
    final active = _activeSyncCompletion;
    if (syncing && active != null) {
      await active.future.timeout(const Duration(seconds: 30));
    }
    if (activeVault?.id != targetVaultId ||
        _repository?.vaultId != targetVaultId) {
      throw StateError(currentL10n.theSyncVaultWasSwitchedMigration);
    }
    // Keep unrelated target work from blocking source migration. The exact
    // staged operation receipts/cache are checked by the migration validator;
    // if a staged operation is still pending, the source remains frozen and
    // the migration can safely retry.
    await synchronize(background: true);
    final foreground = _activeSyncCompletion;
    if (syncing && foreground != null) {
      await foreground.future.timeout(const Duration(seconds: 30));
    }
    if (activeVault?.id != targetVaultId ||
        _repository?.vaultId != targetVaultId) {
      throw StateError(currentL10n.theSyncVaultWasSwitchedMigration);
    }
    final currentRepository = _repository;
    final verifiedFreshView =
        currentRepository != null &&
        currentRepository.vaultId == targetVaultId &&
        (identical(currentRepository, startingRepository)
            ? currentRepository.verifiedServerViewRevision >
                  startingServerViewRevision
            : currentRepository.verifiedServerViewRevision > 0);
    if (snapshotRecoveryActive ||
        syncStatus == 'resnapshot_required' ||
        syncStatus == 'snapshot_too_large' ||
        !verifiedFreshView) {
      throw StateError(currentL10n.theDestinationVaultsCurrentServerState);
    }
  }

  Future<void> onForegroundResumed() async {
    await _automaticSync.foregroundResumed();
    await _restoreMobilePushRegistration();
  }

  Future<void> selectAuditScope(AuditScope value) async {
    if (auditScope == value) return;
    auditScope = value;
    _resetAuditState();
    await loadAudit();
  }

  Future<void> loadAudit({bool reset = false}) async {
    if (reset) _resetAuditState();
    if (auditLoading) return;
    final client = api;
    if (client == null) {
      auditError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    final requestGeneration = ++_auditRequestGeneration;
    final cursor = _auditPageCursors[auditPageIndex];
    auditLoading = true;
    auditError = null;
    auditPageEvents = [];
    notifyListeners();
    try {
      final pageData = await client.audit(cursor: cursor, limit: 100);
      if (requestGeneration != _auditRequestGeneration) return;
      auditPageEvents = pageData.events;
      auditNextCursor = pageData.nextCursor;
      auditHasMore = pageData.hasMore;
    } catch (error) {
      if (requestGeneration != _auditRequestGeneration) return;
      auditError = error is ApiException && error.code == 'AUDIT_CURSOR_EXPIRED'
          ? currentL10n.theAuditCursorExpiredTheServer
          : friendlyError(error);
      auditHasMore = false;
    } finally {
      if (requestGeneration == _auditRequestGeneration) {
        auditLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadInstanceAdminOverview() async {
    if (!isInstanceAdmin) {
      _resetInstanceAdminOverview();
      instanceAdminOverviewError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return;
    }
    final client = api;
    if (client == null) {
      instanceAdminOverviewError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    final requestGeneration = ++_instanceAdminOverviewRequestGeneration;
    instanceAdminOverviewLoading = true;
    instanceAdminOverviewError = null;
    notifyListeners();
    try {
      final overview = await client.instanceAdminOverview();
      if (requestGeneration != _instanceAdminOverviewRequestGeneration ||
          !isInstanceAdmin) {
        return;
      }
      instanceAdminOverview = overview;
    } catch (error) {
      if (requestGeneration != _instanceAdminOverviewRequestGeneration) return;
      instanceAdminOverviewError = friendlyError(error);
    } finally {
      if (requestGeneration == _instanceAdminOverviewRequestGeneration) {
        instanceAdminOverviewLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadInstanceAdminPushHealth() async {
    if (!isInstanceAdmin) {
      _resetInstanceAdminPushHealth();
      instanceAdminPushHealthError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return;
    }
    final client = api;
    if (client == null) {
      instanceAdminPushHealthError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    final requestGeneration = ++_instanceAdminPushHealthRequestGeneration;
    instanceAdminPushHealthLoading = true;
    instanceAdminPushHealthError = null;
    notifyListeners();
    try {
      final health = await client.instanceAdminPushHealth();
      if (requestGeneration != _instanceAdminPushHealthRequestGeneration ||
          !isInstanceAdmin) {
        return;
      }
      instanceAdminPushHealth = health;
    } catch (error) {
      if (requestGeneration != _instanceAdminPushHealthRequestGeneration) {
        return;
      }
      if (error is ApiException &&
          (error.statusCode == 401 || error.statusCode == 403)) {
        // Do not leave an old administrator snapshot visible after this
        // session loses authentication or the instance-admin allowlist role.
        instanceAdminPushHealth = null;
      }
      instanceAdminPushHealthError = friendlyError(error);
    } finally {
      if (requestGeneration == _instanceAdminPushHealthRequestGeneration) {
        instanceAdminPushHealthLoading = false;
        notifyListeners();
      }
    }
  }

  String? get instanceAdminMetricsCredentialOneTimeValue =>
      _instanceAdminMetricsCredentialOneTimeValue;

  Future<void> loadInstanceAdminMetricsCredential() async {
    if (!isInstanceAdmin) {
      _resetInstanceAdminMetricsCredential();
      instanceAdminMetricsCredentialError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return;
    }
    final client = api;
    if (client == null) {
      instanceAdminMetricsCredentialError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    final requestGeneration =
        ++_instanceAdminMetricsCredentialRequestGeneration;
    instanceAdminMetricsCredentialLoading = true;
    instanceAdminMetricsCredentialError = null;
    notifyListeners();
    try {
      final status = await client.instanceAdminMetricsCredentialStatus();
      if (requestGeneration !=
              _instanceAdminMetricsCredentialRequestGeneration ||
          !isInstanceAdmin) {
        return;
      }
      instanceAdminMetricsCredentialStatus = status;
    } catch (error) {
      if (requestGeneration !=
          _instanceAdminMetricsCredentialRequestGeneration) {
        return;
      }
      instanceAdminMetricsCredentialError = friendlyError(error);
    } finally {
      if (requestGeneration ==
          _instanceAdminMetricsCredentialRequestGeneration) {
        instanceAdminMetricsCredentialLoading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> rotateInstanceAdminMetricsCredential() async {
    if (!isInstanceAdmin) {
      _resetInstanceAdminMetricsCredential();
      instanceAdminMetricsCredentialError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return false;
    }
    final client = api;
    if (client == null) {
      instanceAdminMetricsCredentialError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return false;
    }
    final requestGeneration =
        ++_instanceAdminMetricsCredentialRequestGeneration;
    _instanceAdminMetricsCredentialOneTimeValue = null;
    instanceAdminMetricsCredentialSaving = true;
    instanceAdminMetricsCredentialError = null;
    instanceAdminMetricsCredentialNotice = null;
    notifyListeners();
    try {
      final rotation = await client.rotateInstanceAdminMetricsCredential();
      if (requestGeneration !=
              _instanceAdminMetricsCredentialRequestGeneration ||
          !isInstanceAdmin) {
        return false;
      }
      instanceAdminMetricsCredentialStatus =
          InstanceAdminMetricsCredentialStatus(
            active: true,
            updatedAt: rotation.createdAt,
          );
      _instanceAdminMetricsCredentialOneTimeValue = rotation.credential;
      instanceAdminMetricsCredentialNotice =
          currentL10n.theScrapeCredentialWasRotatedThe;
      return true;
    } catch (error) {
      if (requestGeneration !=
          _instanceAdminMetricsCredentialRequestGeneration) {
        return false;
      }
      instanceAdminMetricsCredentialError = friendlyError(error);
      return false;
    } finally {
      if (requestGeneration ==
          _instanceAdminMetricsCredentialRequestGeneration) {
        instanceAdminMetricsCredentialSaving = false;
        notifyListeners();
      }
    }
  }

  Future<bool> revokeInstanceAdminMetricsCredential() async {
    if (!isInstanceAdmin) {
      _resetInstanceAdminMetricsCredential();
      instanceAdminMetricsCredentialError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return false;
    }
    final client = api;
    if (client == null) {
      instanceAdminMetricsCredentialError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return false;
    }
    final requestGeneration =
        ++_instanceAdminMetricsCredentialRequestGeneration;
    _instanceAdminMetricsCredentialOneTimeValue = null;
    instanceAdminMetricsCredentialSaving = true;
    instanceAdminMetricsCredentialError = null;
    instanceAdminMetricsCredentialNotice = null;
    notifyListeners();
    try {
      final result = await client.revokeInstanceAdminMetricsCredential();
      if (requestGeneration !=
              _instanceAdminMetricsCredentialRequestGeneration ||
          !isInstanceAdmin) {
        return false;
      }
      if (!result.revoked) {
        instanceAdminMetricsCredentialError =
            currentL10n.theresNoActivePrometheusScrapeCredential;
        return false;
      }
      instanceAdminMetricsCredentialStatus =
          const InstanceAdminMetricsCredentialStatus(
            active: false,
            updatedAt: null,
          );
      instanceAdminMetricsCredentialNotice =
          currentL10n.prometheusScrapeCredentialRevoked;
      return true;
    } catch (error) {
      if (requestGeneration !=
          _instanceAdminMetricsCredentialRequestGeneration) {
        return false;
      }
      instanceAdminMetricsCredentialError = friendlyError(error);
      return false;
    } finally {
      if (requestGeneration ==
          _instanceAdminMetricsCredentialRequestGeneration) {
        instanceAdminMetricsCredentialSaving = false;
        notifyListeners();
      }
    }
  }

  void clearInstanceAdminMetricsCredentialOneTimeValue() {
    if (_instanceAdminMetricsCredentialOneTimeValue == null) return;
    _instanceAdminMetricsCredentialOneTimeValue = null;
    notifyListeners();
  }

  Future<void> loadInstanceAdminRelayPolicy() async {
    if (!isInstanceAdmin) {
      _resetInstanceAdminRelayPolicy();
      instanceAdminRelayPolicyError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return;
    }
    if (instanceAdminRelayPolicySaving) return;
    final client = api;
    if (client == null) {
      instanceAdminRelayPolicyError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    final requestGeneration = ++_instanceAdminRelayPolicyRequestGeneration;
    instanceAdminRelayPolicyLoading = true;
    instanceAdminRelayPolicyError = null;
    instanceAdminRelayPolicyNotice = null;
    notifyListeners();
    try {
      final policy = await client.instanceAdminRelayPolicy();
      if (requestGeneration != _instanceAdminRelayPolicyRequestGeneration ||
          !isInstanceAdmin) {
        return;
      }
      instanceAdminRelayPolicy = policy;
      instanceAdminRelayPolicyConflict = false;
      instanceAdminRelayPolicySaveError = null;
    } catch (_) {
      if (requestGeneration != _instanceAdminRelayPolicyRequestGeneration) {
        return;
      }
      instanceAdminRelayPolicyError = currentL10n.unableToLoadTheSshRelay;
    } finally {
      if (requestGeneration == _instanceAdminRelayPolicyRequestGeneration) {
        instanceAdminRelayPolicyLoading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> saveInstanceAdminRelayPolicy({
    required bool enabled,
    required String allowCidrsText,
    required String allowPortsText,
  }) async {
    if (!isInstanceAdmin) {
      _resetInstanceAdminRelayPolicy();
      instanceAdminRelayPolicySaveError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return false;
    }
    final current = instanceAdminRelayPolicy;
    if (current == null) {
      instanceAdminRelayPolicySaveError =
          currentL10n.loadTheLatestSshRelayPolicy;
      notifyListeners();
      return false;
    }
    if (instanceAdminRelayPolicyConflict) {
      instanceAdminRelayPolicySaveError =
          currentL10n.reloadTheLatestPolicyAfterThe;
      notifyListeners();
      return false;
    }
    if (instanceAdminRelayPolicyLoading || instanceAdminRelayPolicySaving) {
      return false;
    }
    late final AdminRelayPolicyDraft draft;
    try {
      draft = AdminRelayPolicyDraft.parseAndValidate(
        enabled: enabled,
        allowCidrsText: allowCidrsText,
        allowPortsText: allowPortsText,
        deploymentLimits: current.deploymentLimits,
      );
    } on FormatException catch (error) {
      instanceAdminRelayPolicySaveError = error.message;
      instanceAdminRelayPolicyNotice = null;
      notifyListeners();
      return false;
    }
    final client = api;
    if (client == null) {
      instanceAdminRelayPolicySaveError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return false;
    }
    final requestGeneration = ++_instanceAdminRelayPolicyRequestGeneration;
    instanceAdminRelayPolicySaving = true;
    instanceAdminRelayPolicySaveError = null;
    instanceAdminRelayPolicyNotice = null;
    instanceAdminRelayPolicyError = null;
    notifyListeners();
    try {
      final updated = await client.updateInstanceAdminRelayPolicy(
        expectedRevision: current.revision,
        draft: draft,
        deploymentLimits: current.deploymentLimits,
      );
      if (requestGeneration != _instanceAdminRelayPolicyRequestGeneration ||
          !isInstanceAdmin) {
        return false;
      }
      instanceAdminRelayPolicy = updated;
      instanceAdminRelayPolicyConflict = false;
      instanceAdminRelayPolicyNotice = currentL10n.sshRelayPolicySaved;
      return true;
    } catch (error) {
      if (requestGeneration != _instanceAdminRelayPolicyRequestGeneration) {
        return false;
      }
      if (error is ApiException && error.code == 'RELAY_POLICY_CONFLICT') {
        instanceAdminRelayPolicyConflict = true;
        instanceAdminRelayPolicySaveError =
            currentL10n.theRelayPolicyChangedElsewhereReload;
      } else if (error is ApiException &&
          const {
            'RELAY_POLICY_LIMIT_EXCEEDED',
            'RELAY_POLICY_DEPLOYMENT_DISABLED',
            'RELAY_POLICY_OUTSIDE_LIMITS',
            'RELAY_POLICY_UNAVAILABLE',
          }.contains(error.code)) {
        instanceAdminRelayPolicySaveError =
            currentL10n.theServerDeploymentDoesNotCurrently;
      } else {
        instanceAdminRelayPolicySaveError = currentL10n.unableToSaveTheSshRelay;
      }
      return false;
    } finally {
      if (requestGeneration == _instanceAdminRelayPolicyRequestGeneration) {
        instanceAdminRelayPolicySaving = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadInstanceAdminBackupStatus() async {
    if (!isInstanceAdmin) {
      _resetInstanceAdminBackupStatus();
      instanceAdminBackupStatusError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return;
    }
    final client = api;
    if (client == null) {
      instanceAdminBackupStatusError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    final requestGeneration = ++_instanceAdminBackupStatusRequestGeneration;
    instanceAdminBackupStatusLoading = true;
    instanceAdminBackupStatusError = null;
    notifyListeners();
    try {
      final status = await client.instanceAdminBackupStatus();
      if (requestGeneration != _instanceAdminBackupStatusRequestGeneration ||
          !isInstanceAdmin) {
        return;
      }
      instanceAdminBackupStatus = status;
    } catch (error) {
      if (requestGeneration != _instanceAdminBackupStatusRequestGeneration) {
        return;
      }
      instanceAdminBackupStatusError = friendlyError(error);
    } finally {
      if (requestGeneration == _instanceAdminBackupStatusRequestGeneration) {
        instanceAdminBackupStatusLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadInstanceAdminBackupReplicationStatus() async {
    if (!isInstanceAdmin) {
      _resetInstanceAdminBackupReplication();
      instanceAdminBackupReplicationError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return;
    }
    final client = api;
    if (client == null) {
      instanceAdminBackupReplicationError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    final generation = ++_instanceAdminBackupReplicationRequestGeneration;
    instanceAdminBackupReplicationLoading = true;
    instanceAdminBackupReplicationError = null;
    notifyListeners();
    try {
      final status = await client.instanceAdminBackupReplicationStatus();
      if (generation != _instanceAdminBackupReplicationRequestGeneration ||
          !isInstanceAdmin) {
        return;
      }
      instanceAdminBackupReplicationStatus = status;
    } catch (error) {
      if (generation != _instanceAdminBackupReplicationRequestGeneration) {
        return;
      }
      instanceAdminBackupReplicationError = friendlyError(error);
    } finally {
      if (generation == _instanceAdminBackupReplicationRequestGeneration) {
        instanceAdminBackupReplicationLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> checkInstanceAdminBackupBucketAccess() async {
    if (!isInstanceAdmin) {
      _resetInstanceAdminBackupBucketAccessCheck();
      instanceAdminBackupBucketAccessCheckError =
          currentL10n.instanceAdminAccessIsRequiredTo;
      notifyListeners();
      return;
    }
    if (instanceAdminBackupBucketAccessCheckLoading) return;
    final client = api;
    if (client == null) {
      instanceAdminBackupBucketAccessCheckError =
          currentL10n.connectToTheServerBeforeChecking;
      instanceAdminBackupBucketAccessCheckNotice = null;
      notifyListeners();
      return;
    }
    final generation = ++_instanceAdminBackupBucketAccessCheckRequestGeneration;
    instanceAdminBackupBucketAccessCheckLoading = true;
    instanceAdminBackupBucketAccessCheckError = null;
    instanceAdminBackupBucketAccessCheckNotice = null;
    notifyListeners();
    try {
      await client.instanceAdminBackupBucketAccessCheck();
      if (generation !=
              _instanceAdminBackupBucketAccessCheckRequestGeneration ||
          !isInstanceAdmin) {
        return;
      }
      instanceAdminBackupBucketAccessCheckNotice =
          currentL10n.bucketAccessVerifiedWithHeadbucketThis;
    } catch (error) {
      if (generation !=
          _instanceAdminBackupBucketAccessCheckRequestGeneration) {
        return;
      }
      instanceAdminBackupBucketAccessCheckError = _backupBucketAccessCheckError(
        error,
      );
    } finally {
      if (generation ==
          _instanceAdminBackupBucketAccessCheckRequestGeneration) {
        instanceAdminBackupBucketAccessCheckLoading = false;
        notifyListeners();
      }
    }
  }

  String _backupBucketAccessCheckError(Object error) {
    if (error is ApiException) {
      switch (error.code) {
        case 'BACKUP_REPLICATION_NOT_CONFIGURED':
          return currentL10n.noS3BackupBucketIsConfigured;
        case 'BACKUP_REPLICATION_CHECK_FAILED':
          return currentL10n.theServerCouldNotVerifyAccess;
        case 'INSTANCE_ADMIN_REQUIRED':
          return currentL10n.instanceAdminAccessIsRequiredTo;
      }
    }
    return currentL10n.theServerCouldNotVerifyAccess;
  }

  Future<void> loadInstanceAdminBackupSchedule() async {
    if (!isInstanceAdmin) {
      _resetInstanceAdminBackupSchedule();
      instanceAdminBackupScheduleError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return;
    }
    if (instanceAdminBackupScheduleSaving) return;
    final client = api;
    if (client == null) {
      instanceAdminBackupScheduleError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    final requestGeneration = ++_instanceAdminBackupScheduleRequestGeneration;
    instanceAdminBackupScheduleLoading = true;
    instanceAdminBackupScheduleError = null;
    instanceAdminBackupScheduleSaveError = null;
    instanceAdminBackupScheduleNotice = null;
    notifyListeners();
    try {
      final schedule = await client.instanceAdminBackupSchedule();
      if (requestGeneration != _instanceAdminBackupScheduleRequestGeneration ||
          !isInstanceAdmin) {
        return;
      }
      instanceAdminBackupSchedule = schedule;
    } catch (error) {
      if (requestGeneration != _instanceAdminBackupScheduleRequestGeneration) {
        return;
      }
      instanceAdminBackupScheduleError = _backupScheduleError(
        error,
        saving: false,
      );
    } finally {
      if (requestGeneration == _instanceAdminBackupScheduleRequestGeneration) {
        instanceAdminBackupScheduleLoading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> saveInstanceAdminBackupSchedule(int? intervalHours) async {
    if (!isInstanceAdmin) {
      _resetInstanceAdminBackupSchedule();
      instanceAdminBackupScheduleSaveError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return false;
    }
    if (intervalHours != null && (intervalHours < 1 || intervalHours > 720)) {
      instanceAdminBackupScheduleSaveError =
          currentL10n.theBackupIntervalMustBe1;
      instanceAdminBackupScheduleNotice = null;
      notifyListeners();
      return false;
    }
    if (instanceAdminBackupScheduleLoading ||
        instanceAdminBackupScheduleSaving) {
      return false;
    }
    final client = api;
    if (client == null) {
      instanceAdminBackupScheduleSaveError =
          currentL10n.connectToTheServerFirst;
      notifyListeners();
      return false;
    }
    final requestGeneration = ++_instanceAdminBackupScheduleRequestGeneration;
    instanceAdminBackupScheduleSaving = true;
    instanceAdminBackupScheduleError = null;
    instanceAdminBackupScheduleSaveError = null;
    instanceAdminBackupScheduleNotice = null;
    notifyListeners();
    try {
      final schedule = await client.updateInstanceAdminBackupSchedule(
        intervalHours,
      );
      if (requestGeneration != _instanceAdminBackupScheduleRequestGeneration ||
          !isInstanceAdmin) {
        return false;
      }
      instanceAdminBackupSchedule = schedule;
      instanceAdminBackupScheduleNotice = intervalHours == null
          ? currentL10n.scheduledBackupsTurnedOff
          : currentL10n.scheduledBackupSettingsSaved;
      return true;
    } catch (error) {
      if (requestGeneration != _instanceAdminBackupScheduleRequestGeneration) {
        return false;
      }
      instanceAdminBackupScheduleSaveError = _backupScheduleError(
        error,
        saving: true,
      );
      return false;
    } finally {
      if (requestGeneration == _instanceAdminBackupScheduleRequestGeneration) {
        instanceAdminBackupScheduleSaving = false;
        notifyListeners();
      }
    }
  }

  String _backupScheduleError(Object error, {required bool saving}) {
    if (error is ApiException) {
      switch (error.code) {
        case 'BACKUP_NOT_CONFIGURED':
          return currentL10n.theServerHasntConfiguredAUsable;
        case 'INVALID_BACKUP_INTERVAL':
          return currentL10n.theBackupIntervalMustBe1;
        case 'INVALID_BACKUP_SCHEDULE_REQUEST':
          return currentL10n.theServerRejectedThisBackupSchedule;
        case 'INSTANCE_ADMIN_REQUIRED':
          return currentL10n.theCurrentAccountDoesntHaveInstance;
        case 'AUTH_REQUIRED':
          return currentL10n.theSignInStateExpiredSign;
      }
    }
    return saving
        ? currentL10n.couldntSaveTheScheduledBackupSettings
        : currentL10n.couldntReadTheScheduledBackupSettings;
  }

  Future<void> loadAdminVaults({int? offset}) async {
    if (!isInstanceAdmin) {
      _resetInstanceAdminOverview();
      adminVaultsError = currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return;
    }
    if (offset != null && offset < 0) {
      throw ArgumentError.value(
        offset,
        'offset',
        currentL10n.mustNotBeNegative,
      );
    }
    final client = api;
    if (client == null) {
      adminVaultsError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    final requestedOffset = offset ?? adminVaultsPage?.offset ?? 0;
    final requestGeneration = ++_adminVaultsRequestGeneration;
    adminVaultsLoading = true;
    adminVaultsError = null;
    adminVaultMutationError = null;
    adminVaultMutationNotice = null;
    notifyListeners();
    try {
      final page = await client.adminVaults(
        limit: adminVaultPageSize,
        offset: requestedOffset,
      );
      if (requestGeneration != _adminVaultsRequestGeneration ||
          !isInstanceAdmin) {
        return;
      }
      if (page.limit != adminVaultPageSize || page.offset != requestedOffset) {
        throw FormatException(currentL10n.invalidAdminVaultPaginationResponse);
      }
      adminVaultsPage = page;
    } catch (error) {
      if (requestGeneration != _adminVaultsRequestGeneration) return;
      adminVaultsError = friendlyError(error);
    } finally {
      if (requestGeneration == _adminVaultsRequestGeneration) {
        adminVaultsLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> nextAdminVaultsPage() async {
    final page = adminVaultsPage;
    if (adminVaultsLoading || page == null || !page.hasNext) return;
    await loadAdminVaults(offset: page.offset + page.limit);
  }

  Future<void> previousAdminVaultsPage() async {
    final page = adminVaultsPage;
    if (adminVaultsLoading || page == null || !page.hasPrevious) return;
    final previousOffset = page.offset - page.limit;
    await loadAdminVaults(offset: previousOffset < 0 ? 0 : previousOffset);
  }

  Future<bool> updateAdminVaultQuota({
    required String vaultId,
    required int quotaBytes,
  }) async {
    if (!isInstanceAdmin) {
      adminVaultMutationError = currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return false;
    }
    if (adminVaultQuotaSaving) return false;
    if (quotaBytes < 1 || quotaBytes > maxAdminVaultQuotaBytes) {
      adminVaultMutationError = currentL10n.theQuotaMustBeBetween1;
      notifyListeners();
      return false;
    }
    final client = api;
    if (client == null) {
      adminVaultMutationError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return false;
    }
    final refreshOffset = adminVaultsPage?.offset ?? 0;
    adminVaultQuotaSaving = true;
    adminVaultMutationError = null;
    adminVaultMutationNotice = null;
    notifyListeners();
    try {
      final receipt = await client.updateAdminVaultQuota(
        vaultId: vaultId,
        quotaBytes: quotaBytes,
      );
      if (!isInstanceAdmin) return false;
      await loadAdminVaults(offset: refreshOffset);
      if (!isInstanceAdmin) return false;
      adminVaultMutationNotice = currentL10n.vaultQuotaUpdatedToQuotabytesBytes(
        receipt.quotaBytes,
      );
      return true;
    } catch (error) {
      adminVaultMutationError = friendlyError(error);
      return false;
    } finally {
      adminVaultQuotaSaving = false;
      notifyListeners();
    }
  }

  Future<void> loadInstanceAdminAudit({bool reset = false}) async {
    if (reset) _resetInstanceAdminAuditState();
    if (!isInstanceAdmin) {
      _resetInstanceAdminAuditState();
      adminAuditError = currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return;
    }
    if (adminAuditLoading) return;
    final client = api;
    if (client == null) {
      adminAuditError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    final requestGeneration = ++_adminAuditRequestGeneration;
    final cursor = _adminAuditPageCursors[adminAuditPageIndex];
    adminAuditLoading = true;
    adminAuditError = null;
    notifyListeners();
    try {
      final page = await client.adminAudit(cursor: cursor, limit: 100);
      if (requestGeneration != _adminAuditRequestGeneration ||
          !isInstanceAdmin) {
        return;
      }
      adminAuditPage = page;
    } catch (error) {
      if (requestGeneration != _adminAuditRequestGeneration) return;
      adminAuditError =
          error is ApiException && error.code == 'AUDIT_CURSOR_EXPIRED'
          ? currentL10n.theAdminAuditCursorExpiredThe
          : error is ApiException && error.code == 'INVALID_AUDIT_CURSOR'
          ? currentL10n.theAdminAuditCursorIsInvalid
          : friendlyError(error);
    } finally {
      if (requestGeneration == _adminAuditRequestGeneration) {
        adminAuditLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refreshInstanceAdminAudit() =>
      loadInstanceAdminAudit(reset: true);

  Future<void> nextInstanceAdminAuditPage() async {
    final page = adminAuditPage;
    if (adminAuditLoading || page == null || !page.hasMore) return;
    final cursor = page.nextCursor;
    if (cursor == null) return;
    _adminAuditPageCursors.removeRange(
      adminAuditPageIndex + 1,
      _adminAuditPageCursors.length,
    );
    _adminAuditPageCursors.add(cursor);
    adminAuditPageIndex++;
    await loadInstanceAdminAudit();
  }

  Future<void> previousInstanceAdminAuditPage() async {
    if (adminAuditLoading || adminAuditPageIndex < 1) return;
    adminAuditPageIndex--;
    await loadInstanceAdminAudit();
  }

  Future<void> loadAdminMaintenanceJobs({int? offset}) async {
    if (!isInstanceAdmin) {
      _resetAdminMaintenanceJobs();
      adminMaintenanceJobsError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return;
    }
    if (offset != null && offset < 0) {
      throw ArgumentError.value(
        offset,
        'offset',
        currentL10n.mustNotBeNegative,
      );
    }
    final client = api;
    if (client == null) {
      adminMaintenanceJobsError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    final requestedOffset = offset ?? adminMaintenanceJobsPage?.offset ?? 0;
    final requestGeneration = ++_adminMaintenanceJobsRequestGeneration;
    adminMaintenanceJobsLoading = true;
    adminMaintenanceJobsError = null;
    notifyListeners();
    try {
      var page = await client.adminMaintenanceJobs(
        limit: adminMaintenanceJobsPageSize,
        offset: requestedOffset,
      );
      if (requestGeneration != _adminMaintenanceJobsRequestGeneration ||
          !isInstanceAdmin) {
        return;
      }
      if (page.limit != adminMaintenanceJobsPageSize ||
          page.offset != requestedOffset) {
        throw FormatException(
          currentL10n.invalidAdminMaintenancePaginationResponse,
        );
      }
      if (requestedOffset == 0) {
        final latestRestoreJob = page.jobs
            .where((item) => item.isRestore)
            .firstOrNull;
        if (latestRestoreJob != null) {
          final restoreJob = _mergeRestoreJobState(
            adminRestoreJob,
            latestRestoreJob,
          );
          adminRestoreJob = restoreJob;
          if (restoreJob.jobId != latestRestoreJob.jobId ||
              restoreJob != latestRestoreJob) {
            page = _replaceAdminRestoreJob(page, restoreJob);
          }
          if (restoreJob.isActive) {
            if (!adminRestorePolling) await _beginAdminRestorePolling();
          } else {
            _stopAdminRestorePolling();
            adminRestoreNotice = _adminRestoreTerminalNotice(restoreJob);
          }
        }
      }
      adminMaintenanceJobsPage = page;
    } catch (error) {
      if (requestGeneration != _adminMaintenanceJobsRequestGeneration) return;
      adminMaintenanceJobsError = friendlyError(error);
    } finally {
      if (requestGeneration == _adminMaintenanceJobsRequestGeneration) {
        adminMaintenanceJobsLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refreshAdminMaintenanceJobs() =>
      loadAdminMaintenanceJobs(offset: 0);

  Future<void> nextAdminMaintenanceJobsPage() async {
    final page = adminMaintenanceJobsPage;
    if (adminMaintenanceJobsLoading || page == null || !page.hasNext) return;
    await loadAdminMaintenanceJobs(offset: page.offset + page.limit);
  }

  Future<void> previousAdminMaintenanceJobsPage() async {
    final page = adminMaintenanceJobsPage;
    if (adminMaintenanceJobsLoading || page == null || !page.hasPrevious) {
      return;
    }
    final previousOffset = page.offset - page.limit;
    await loadAdminMaintenanceJobs(
      offset: previousOffset < 0 ? 0 : previousOffset,
    );
  }

  Future<bool> runAdminMaintenance() async {
    if (!isInstanceAdmin) {
      adminMaintenanceJobsError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return false;
    }
    final client = api;
    if (client == null) {
      adminMaintenanceJobsError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return false;
    }
    if (adminMaintenanceJobSubmitting || adminBackupJobSubmitting) return false;
    final requestId = _adminMaintenanceRetryRequestId ?? _uuid.v4();
    _adminMaintenanceRetryRequestId = requestId;
    adminMaintenanceJobSubmitting = true;
    adminMaintenanceJobsError = null;
    adminMaintenanceJobsNotice = null;
    notifyListeners();
    try {
      await client.startAdminMaintenanceJob(requestId: requestId);
      if (!isInstanceAdmin) return false;
      _adminMaintenanceRetryRequestId = null;
      adminMaintenanceJobsNotice =
          currentL10n.maintenanceJobSubmittedRefreshTheJob;
      await loadAdminMaintenanceJobs(offset: 0);
      return true;
    } catch (error) {
      adminMaintenanceJobsError = friendlyError(error);
      return false;
    } finally {
      adminMaintenanceJobSubmitting = false;
      notifyListeners();
    }
  }

  Future<bool> runAdminBackup() async {
    if (!isInstanceAdmin) {
      adminBackupJobError = currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return false;
    }
    final client = api;
    if (client == null) {
      adminBackupJobError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return false;
    }
    if (adminMaintenanceJobSubmitting || adminBackupJobSubmitting) {
      return false;
    }
    final requestId = _adminBackupRetryRequestId ?? _uuid.v4();
    _adminBackupRetryRequestId = requestId;
    adminBackupJobSubmitting = true;
    adminBackupJobError = null;
    adminBackupJobNotice = null;
    notifyListeners();
    try {
      await client.startAdminBackupJob(requestId: requestId);
      if (!isInstanceAdmin) return false;
      _adminBackupRetryRequestId = null;
      adminBackupJobNotice = currentL10n.encryptedBackupJobSubmittedItsStatus;
      await loadAdminMaintenanceJobs(offset: 0);
      return true;
    } catch (error) {
      adminBackupJobError =
          error is ApiException && error.code == 'BACKUP_NOT_CONFIGURED'
          ? currentL10n.theServerHasntConfiguredEncryptedBackups
          : friendlyError(error);
      return false;
    } finally {
      adminBackupJobSubmitting = false;
      notifyListeners();
    }
  }

  bool get canRetryAdminRestoreSubmission =>
      _adminRestoreRetryRequestId != null &&
      _adminRestoreRetryArchiveId != null &&
      _adminRestoreRetryArchiveSource != null;

  bool canRetryAdminRestoreFor(String archiveId, String archiveSource) =>
      _adminRestoreRetryRequestId != null &&
      _adminRestoreRetryArchiveId == archiveId &&
      _adminRestoreRetryArchiveSource == archiveSource;

  Future<void> loadAdminRestoreSources({int offset = 0}) async {
    if (!isInstanceAdmin) {
      _resetAdminRestoreStage();
      adminRestoreSourcesError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return;
    }
    if (offset < 0 || offset > 1000000) {
      throw ArgumentError.value(
        offset,
        'offset',
        currentL10n.mustBeBetween0And1000000,
      );
    }
    final client = api;
    if (client == null) {
      adminRestoreSourcesError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    final generation = ++_adminRestoreSourcesRequestGeneration;
    adminRestoreSourcesLoading = true;
    adminRestoreSourcesError = null;
    notifyListeners();
    try {
      final page = await client.instanceAdminRestoreSources(
        limit: adminRestoreSourcePageSize,
        offset: offset,
      );
      if (generation != _adminRestoreSourcesRequestGeneration ||
          !isInstanceAdmin) {
        return;
      }
      if (page.limit != adminRestoreSourcePageSize || page.offset != offset) {
        throw FormatException(currentL10n.invalidRestoreSourcePageResponse);
      }
      adminRestoreSourcesPage = page;
      if (offset == 0 && adminMaintenanceJobsPage == null) {
        await loadAdminMaintenanceJobs(offset: 0);
      }
    } catch (error) {
      if (generation != _adminRestoreSourcesRequestGeneration) return;
      adminRestoreSourcesError = _adminRestoreError(error, loading: true);
    } finally {
      if (generation == _adminRestoreSourcesRequestGeneration) {
        adminRestoreSourcesLoading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> startAdminRestoreStage({
    required String archiveId,
    String archiveSource = 'local',
  }) async {
    if (!isInstanceAdmin) {
      adminRestoreError = currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return false;
    }
    if (!_isCanonicalUuid(archiveId)) {
      adminRestoreError = currentL10n.theSelectedArchiveIsInvalidRefresh;
      notifyListeners();
      return false;
    }
    if (!const {'local', 'replica'}.contains(archiveSource)) {
      adminRestoreError = currentL10n.theSelectedArchiveSourceIsInvalid;
      notifyListeners();
      return false;
    }
    final client = api;
    if (client == null) {
      adminRestoreError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return false;
    }
    if (adminRestoreSubmitting || adminRestoreJob?.isActive == true) {
      return false;
    }
    final requestId =
        _adminRestoreRetryArchiveId == archiveId &&
            _adminRestoreRetryArchiveSource == archiveSource
        ? _adminRestoreRetryRequestId ?? _uuid.v4()
        : _uuid.v4();
    _adminRestoreRetryRequestId = requestId;
    _adminRestoreRetryArchiveId = archiveId;
    _adminRestoreRetryArchiveSource = archiveSource;
    adminRestoreSubmitting = true;
    adminRestoreError = null;
    adminRestorePollingError = null;
    adminRestoreNotice = null;
    notifyListeners();
    try {
      final job = await client.startAdminRestoreJob(
        requestId: requestId,
        archiveId: archiveId,
        archiveSource: archiveSource,
      );
      if (!isInstanceAdmin) return false;
      if (!job.isRestore ||
          job.archiveId != archiveId ||
          job.archiveSource != archiveSource) {
        throw FormatException(currentL10n.invalidRestoreJobReceipt);
      }
      _adminRestoreRetryRequestId = null;
      _adminRestoreRetryArchiveId = null;
      _adminRestoreRetryArchiveSource = null;
      adminRestoreJob = job;
      adminRestoreNotice = job.isActive
          ? currentL10n.theIsolatedRestoreCopyPreparationJob
          : _adminRestoreTerminalNotice(job);
      if (job.isActive) await _beginAdminRestorePolling();
      return true;
    } catch (error) {
      adminRestoreError = _adminRestoreError(error, submitting: true);
      return false;
    } finally {
      adminRestoreSubmitting = false;
      notifyListeners();
    }
  }

  Future<void> refreshAdminRestoreStage() async {
    final job = adminRestoreJob;
    if (!isInstanceAdmin || job == null || !job.isRestore) return;
    await _fetchAdminRestoreStage(
      job.jobId,
      _adminRestorePollingGeneration,
      manual: true,
    );
  }

  bool canRetryAdminRestoreStageDiscardFor(String restoreJobId) =>
      _adminRestoreStageDiscardRetryJobId == restoreJobId &&
      _adminRestoreStageDiscardRetryRequestId != null;

  String? get adminRestoreStageDiscardRetryJobId =>
      _adminRestoreStageDiscardRetryJobId;

  Future<bool> discardAdminRestoreStage(String restoreJobId) async {
    if (!isInstanceAdmin) {
      adminRestoreStageDiscardError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return false;
    }
    if (adminMaintenanceJobsPage?.supportedActions.contains(
          'restore_stage_discard',
        ) !=
        true) {
      adminRestoreStageDiscardError =
          currentL10n.theCurrentServerDoesntDeclareSupport;
      notifyListeners();
      return false;
    }
    if (!_isCanonicalUuid(restoreJobId)) {
      adminRestoreStageDiscardError =
          currentL10n.theIsolatedRestoreCopyIsInvalid;
      notifyListeners();
      return false;
    }
    if (adminRestoreStageDiscardingJobId != null) return false;
    final job =
        adminMaintenanceJobsPage?.jobs
            .where((item) => item.jobId == restoreJobId)
            .firstOrNull ??
        (adminRestoreJob?.jobId == restoreJobId ? adminRestoreJob : null);
    if (job == null ||
        !job.isRestore ||
        !(job.status == 'succeeded' || job.status == 'interrupted') ||
        !const {
          'ready',
          'discarding',
          'unverified',
        }.contains(job.restoreStageStatus)) {
      adminRestoreStageDiscardError =
          currentL10n.onlyIsolatedRestoreCopiesInThe;
      notifyListeners();
      return false;
    }
    final client = api;
    if (client == null) {
      adminRestoreStageDiscardError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return false;
    }
    final requestId = _adminRestoreStageDiscardRetryJobId == restoreJobId
        ? _adminRestoreStageDiscardRetryRequestId ?? _uuid.v4()
        : _uuid.v4();
    _adminRestoreStageDiscardRetryJobId = restoreJobId;
    _adminRestoreStageDiscardRetryRequestId = requestId;
    adminRestoreStageDiscardingJobId = restoreJobId;
    adminRestoreStageDiscardError = null;
    adminRestoreStageDiscardNotice = null;
    notifyListeners();
    try {
      final result = await client.discardAdminRestoreStage(
        restoreJobId: restoreJobId,
        requestId: requestId,
      );
      if (!isInstanceAdmin) return false;
      if (result.restoreJobId != restoreJobId) {
        throw FormatException(currentL10n.restoreStageResponseDidNotMatch);
      }
      _adminRestoreStageDiscardRetryJobId = null;
      _adminRestoreStageDiscardRetryRequestId = null;
      _setAdminRestoreStageStatus(restoreJobId, 'discarded');
      adminRestoreStageDiscardNotice =
          currentL10n.theIsolatedRestoreCopyWasDiscarded;
      await loadAdminMaintenanceJobs(offset: 0);
      return true;
    } catch (error) {
      adminRestoreStageDiscardError = _adminRestoreStageDiscardErrorText(error);
      return false;
    } finally {
      adminRestoreStageDiscardingJobId = null;
      notifyListeners();
    }
  }

  void _setAdminRestoreStageStatus(String restoreJobId, String status) {
    if (adminRestoreJob?.jobId == restoreJobId) {
      adminRestoreJob = adminRestoreJob!.withRestoreStageStatus(status);
    }
    final page = adminMaintenanceJobsPage;
    if (page != null && page.jobs.any((job) => job.jobId == restoreJobId)) {
      adminMaintenanceJobsPage = AdminMaintenanceJobsPage(
        jobs: [
          for (final item in page.jobs)
            item.jobId == restoreJobId
                ? item.withRestoreStageStatus(status)
                : item,
        ],
        total: page.total,
        limit: page.limit,
        offset: page.offset,
        supportedActions: page.supportedActions,
      );
    }
  }

  String _adminRestoreStageDiscardErrorText(Object error) {
    if (error is ApiException) {
      switch (error.code) {
        case 'INSTANCE_ADMIN_REQUIRED':
          return currentL10n.theCurrentAccountDoesntHaveInstance;
        case 'AUTH_REQUIRED':
          return currentL10n.theSignInStateExpiredSign;
        case 'RESTORE_STAGE_NOT_FOUND':
        case 'RESTORE_JOB_NOT_FOUND':
        case 'NOT_FOUND':
          return currentL10n.noIsolatedRestoreCopyToDiscard;
        case 'RESTORE_STAGE_NOT_READY':
          return currentL10n.theIsolatedRestoreCopyStateChanged;
        case 'RESTORE_STAGE_UNAVAILABLE':
          return currentL10n.theIsolatedRestoreCopyFailedVerification;
        case 'RESTORE_STAGE_DISCARD_FAILED':
          return currentL10n.isolatedCopyCleanupDidntFinishYou;
        case 'MAINTENANCE_ALREADY_RUNNING':
          return currentL10n.anotherInstanceAdminJobIsRunning;
        case 'BACKUP_NOT_CONFIGURED':
          return currentL10n.theServerHasntConfiguredIsolatedRestore;
      }
    }
    return currentL10n.couldntDiscardTheIsolatedRestoreCopy;
  }

  Future<void> _beginAdminRestorePolling() async {
    _stopAdminRestorePolling();
    final generation = ++_adminRestorePollingGeneration;
    _adminRestorePollAttempts = 0;
    _adminRestorePollRequestInFlight = false;
    adminRestorePolling = true;
    _adminRestorePollTimer = Timer.periodic(
      adminRestorePollIntervalForTesting,
      (_) {
        if (_adminRestorePollAttempts >=
            adminRestorePollMaxAttemptsForTesting) {
          _stopAdminRestorePolling();
          adminRestoreNotice = currentL10n.theJobIsStillRunningAnd;
          notifyListeners();
          return;
        }
        final job = adminRestoreJob;
        if (job == null || !job.isActive || !isInstanceAdmin) {
          _stopAdminRestorePolling();
          notifyListeners();
          return;
        }
        unawaited(_fetchAdminRestoreStage(job.jobId, generation));
      },
    );
    final job = adminRestoreJob;
    if (job != null) await _fetchAdminRestoreStage(job.jobId, generation);
  }

  Future<void> _fetchAdminRestoreStage(
    String jobId,
    int generation, {
    bool manual = false,
  }) async {
    if (!isInstanceAdmin ||
        generation != _adminRestorePollingGeneration ||
        _adminRestorePollRequestInFlight) {
      return;
    }
    final client = api;
    if (client == null) {
      adminRestorePollingError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    _adminRestorePollRequestInFlight = true;
    _adminRestorePollAttempts++;
    try {
      final page = await client.adminMaintenanceJobs(
        limit: adminMaintenanceJobsPageSize,
        offset: 0,
      );
      if (!isInstanceAdmin || generation != _adminRestorePollingGeneration) {
        return;
      }
      final updated = page.jobs
          .where((item) => item.jobId == jobId)
          .firstOrNull;
      if (updated != null && updated.isRestore) {
        adminRestoreJob = updated;
        adminRestorePollingError = null;
        adminRestoreJobsPageUpdate(page);
        if (!updated.isActive) {
          _stopAdminRestorePolling();
          adminRestoreNotice = _adminRestoreTerminalNotice(updated);
        } else if (_adminRestorePollAttempts >=
            adminRestorePollMaxAttemptsForTesting) {
          _stopAdminRestorePolling();
          adminRestoreNotice = currentL10n.theJobIsStillRunningAnd;
        }
        notifyListeners();
      } else if (_adminRestorePollAttempts >=
          adminRestorePollMaxAttemptsForTesting) {
        _stopAdminRestorePolling();
        adminRestoreNotice = currentL10n.theJobStatusIsTemporarilyUnavailable;
      }
    } catch (_) {
      if (!isInstanceAdmin || generation != _adminRestorePollingGeneration) {
        return;
      }
      adminRestorePollingError = manual && !adminRestorePolling
          ? currentL10n.couldntReadTheRestoreJobStatus
          : currentL10n.couldntReadTheRestoreJobStatus3;
      if (_adminRestorePollAttempts >= adminRestorePollMaxAttemptsForTesting) {
        _stopAdminRestorePolling();
        adminRestoreNotice = currentL10n.automaticStatusChecksArePausedYou;
      }
    } finally {
      if (generation == _adminRestorePollingGeneration) {
        _adminRestorePollRequestInFlight = false;
        notifyListeners();
      }
    }
  }

  void adminRestoreJobsPageUpdate(AdminMaintenanceJobsPage page) {
    if (page.limit == adminMaintenanceJobsPageSize && page.offset == 0) {
      adminMaintenanceJobsPage = page;
      adminMaintenanceJobsError = null;
    }
  }

  AdminMaintenanceJob _mergeRestoreJobState(
    AdminMaintenanceJob? current,
    AdminMaintenanceJob incoming,
  ) {
    if (current == null ||
        !current.isRestore ||
        current.jobId != incoming.jobId) {
      return incoming;
    }
    final currentIsTerminal = !current.isActive;
    if (currentIsTerminal && incoming.isActive) return current;
    if (current.status == 'succeeded' && incoming.status == 'succeeded') {
      final stageRank = {
        null: 0,
        'ready': 1,
        'unverified': 2,
        'discarding': 3,
        'discarded': 4,
      };
      if ((stageRank[current.restoreStageStatus] ?? 0) >
          (stageRank[incoming.restoreStageStatus] ?? 0)) {
        return current;
      }
    }
    return incoming;
  }

  AdminMaintenanceJobsPage _replaceAdminRestoreJob(
    AdminMaintenanceJobsPage page,
    AdminMaintenanceJob restoreJob,
  ) {
    if (!page.jobs.any((job) => job.jobId == restoreJob.jobId)) return page;
    return AdminMaintenanceJobsPage(
      jobs: [
        for (final job in page.jobs)
          job.jobId == restoreJob.jobId ? restoreJob : job,
      ],
      total: page.total,
      limit: page.limit,
      offset: page.offset,
      supportedActions: page.supportedActions,
    );
  }

  String _adminRestoreTerminalNotice(AdminMaintenanceJob job) =>
      switch ((job.status, job.resultCode)) {
        ('succeeded', 'completed') when job.restoreStageStatus == 'discarded' =>
          currentL10n.theIsolatedCopyWasDiscardedYou,
        ('succeeded', 'completed') when job.restoreStageStatus == 'ready' =>
          currentL10n.theIsolatedRestoreCopyIsReady,
        ('succeeded', 'completed')
            when job.restoreStageStatus == 'discarding' =>
          currentL10n.isolatedCopyCleanupHasntFinishedYou,
        ('succeeded', 'completed')
            when job.restoreStageStatus == 'unverified' =>
          currentL10n.theIsolatedCopyIsntVerifiedYet,
        ('succeeded', 'completed') => currentL10n.theRestoreJobFinishedButThe,
        ('failed', 'restore_failed') =>
          currentL10n.couldntPrepareTheIsolatedRestoreCopy,
        ('interrupted', 'interrupted') when job.restoreStageStatus == 'ready' =>
          currentL10n.theIsolatedRestoreCopyIsReady2,
        ('interrupted', 'interrupted')
            when job.restoreStageStatus == 'discarding' =>
          currentL10n.isolatedCopyCleanupHasntFinishedYou,
        ('interrupted', 'interrupted') =>
          currentL10n.theIsolatedRestoreCopyPreparationJob3,
        _ => currentL10n.theIsolatedRestoreCopyPreparationJob2,
      };

  String _adminRestoreError(
    Object error, {
    bool loading = false,
    bool submitting = false,
  }) {
    if (error is ApiException) {
      switch (error.code) {
        case 'INSTANCE_ADMIN_REQUIRED':
          return currentL10n.theCurrentAccountDoesntHaveInstance;
        case 'AUTH_REQUIRED':
          return currentL10n.theSignInStateExpiredSign;
        case 'BACKUP_NOT_CONFIGURED':
          return currentL10n.theServersEncryptedArchiveConfigurationIs;
        case 'RESTORE_SOURCE_UNAVAILABLE':
        case 'RESTORE_SOURCE_NOT_FOUND':
          return currentL10n.theSelectedEncryptedArchiveIsUnavailable;
        case 'MAINTENANCE_ALREADY_RUNNING':
          return currentL10n.anotherInstanceAdminJobIsRunning;
        case 'INVALID_JOB_REQUEST':
          return currentL10n.theServerRejectedThisIsolatedRestore;
      }
    }
    if (loading) return currentL10n.couldntReadEncryptedArchiveSourcesTry;
    if (submitting) return currentL10n.couldntPrepareTheIsolatedRestoreCopy;
    return currentL10n.couldntReadTheRestoreJobStatus2;
  }

  void _stopAdminRestorePolling() {
    _adminRestorePollTimer?.cancel();
    _adminRestorePollTimer = null;
    adminRestorePolling = false;
    _adminRestorePollRequestInFlight = false;
    _adminRestorePollingGeneration++;
  }

  void _resetAdminRestoreStage() {
    _adminRestoreSourcesRequestGeneration++;
    _stopAdminRestorePolling();
    adminRestoreSourcesPage = null;
    adminRestoreSourcesLoading = false;
    adminRestoreSourcesError = null;
    adminRestoreJob = null;
    adminRestoreSubmitting = false;
    adminRestoreError = null;
    adminRestoreNotice = null;
    adminRestorePollingError = null;
    _adminRestoreRetryRequestId = null;
    _adminRestoreRetryArchiveId = null;
    _adminRestoreRetryArchiveSource = null;
    adminRestoreStageDiscardingJobId = null;
    adminRestoreStageDiscardError = null;
    adminRestoreStageDiscardNotice = null;
    _adminRestoreStageDiscardRetryJobId = null;
    _adminRestoreStageDiscardRetryRequestId = null;
    _adminRestorePollAttempts = 0;
    _adminRestorePollRequestInFlight = false;
  }

  Future<void> loadAdminAccounts({int? offset}) async {
    if (!isInstanceAdmin) {
      _resetInstanceAdminOverview();
      adminAccountsError = currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return;
    }
    if (offset != null && (offset < 0 || offset > 1000000)) {
      throw ArgumentError.value(
        offset,
        'offset',
        currentL10n.mustBeBetween0And1000000,
      );
    }
    final client = api;
    if (client == null) {
      adminAccountsError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    final requestedOffset = offset ?? adminAccountsPage?.offset ?? 0;
    final requestGeneration = ++_adminAccountsRequestGeneration;
    adminAccountsLoading = true;
    adminAccountsError = null;
    adminAccountActionError = null;
    adminAccountActionNotice = null;
    notifyListeners();
    try {
      final page = await client.adminAccounts(
        limit: adminAccountPageSize,
        offset: requestedOffset,
      );
      if (requestGeneration != _adminAccountsRequestGeneration ||
          !isInstanceAdmin) {
        return;
      }
      if (page.limit != adminAccountPageSize ||
          page.offset != requestedOffset) {
        throw FormatException(
          currentL10n.invalidAdminAccountPaginationResponse,
        );
      }
      adminAccountsPage = page;
      final expandedUserId = adminAccountSessionsUserId;
      final expandedAccount = expandedUserId == null
          ? null
          : page.accounts
                .where((item) => item.userId == expandedUserId)
                .firstOrNull;
      if (expandedUserId != null &&
          (expandedAccount == null || expandedAccount.status == 'deleting')) {
        _resetAdminAccountSessions();
      }
      final relayPolicyUserId = adminAccountRelayPolicyUserId;
      final relayPolicyAccount = relayPolicyUserId == null
          ? null
          : page.accounts
                .where((item) => item.userId == relayPolicyUserId)
                .firstOrNull;
      if (relayPolicyUserId != null &&
          (relayPolicyAccount == null ||
              relayPolicyAccount.status == 'deleting' ||
              isCurrentAdminAccount(relayPolicyUserId))) {
        _resetAdminAccountRelayPolicy();
      }
    } catch (error) {
      if (requestGeneration != _adminAccountsRequestGeneration) return;
      adminAccountsError = friendlyError(error);
    } finally {
      if (requestGeneration == _adminAccountsRequestGeneration) {
        adminAccountsLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> nextAdminAccountsPage() async {
    final page = adminAccountsPage;
    if (adminAccountsLoading || page == null || !page.hasNext) return;
    await loadAdminAccounts(offset: page.offset + page.limit);
  }

  Future<void> previousAdminAccountsPage() async {
    final page = adminAccountsPage;
    if (adminAccountsLoading || page == null || !page.hasPrevious) return;
    final previousOffset = page.offset - page.limit;
    await loadAdminAccounts(offset: previousOffset < 0 ? 0 : previousOffset);
  }

  Future<void> loadAdminAccountInvitations({int? offset}) async {
    if (!isInstanceAdmin) {
      _resetAdminAccountInvitations();
      adminAccountInvitationsError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return;
    }
    if (offset != null && (offset < 0 || offset > 1000000)) {
      throw ArgumentError.value(
        offset,
        'offset',
        currentL10n.mustBeBetween0And1000000,
      );
    }
    final client = api;
    if (client == null) {
      adminAccountInvitationsError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    final requestedOffset = offset ?? adminAccountInvitationsPage?.offset ?? 0;
    final requestGeneration = ++_adminAccountInvitationsRequestGeneration;
    adminAccountInvitationsLoading = true;
    adminAccountInvitationsError = null;
    adminAccountInvitationActionError = null;
    adminAccountInvitationNotice = null;
    notifyListeners();
    try {
      final page = await client.adminAccountInvitations(
        limit: adminAccountInvitationsPageSize,
        offset: requestedOffset,
      );
      if (requestGeneration != _adminAccountInvitationsRequestGeneration ||
          !isInstanceAdmin) {
        return;
      }
      if (page.limit != adminAccountInvitationsPageSize ||
          page.offset != requestedOffset) {
        throw FormatException(
          currentL10n.invalidAdminAccountInvitationPaginationResponse,
        );
      }
      adminAccountInvitationsPage = page;
    } catch (error) {
      if (requestGeneration != _adminAccountInvitationsRequestGeneration) {
        return;
      }
      adminAccountInvitationsError = friendlyError(error);
    } finally {
      if (requestGeneration == _adminAccountInvitationsRequestGeneration) {
        adminAccountInvitationsLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> nextAdminAccountInvitationsPage() async {
    final page = adminAccountInvitationsPage;
    if (adminAccountInvitationsLoading || page == null || !page.hasNext) {
      return;
    }
    await loadAdminAccountInvitations(offset: page.offset + page.limit);
  }

  Future<void> previousAdminAccountInvitationsPage() async {
    final page = adminAccountInvitationsPage;
    if (adminAccountInvitationsLoading || page == null || !page.hasPrevious) {
      return;
    }
    final previousOffset = page.offset - page.limit;
    await loadAdminAccountInvitations(
      offset: previousOffset < 0 ? 0 : previousOffset,
    );
  }

  Future<bool> issueAdminAccountInvitation({
    required String username,
    required int expiresInDays,
  }) async {
    if (!isInstanceAdmin) {
      adminAccountInvitationActionError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return false;
    }
    final normalizedUsername = username.trim().toLowerCase();
    if (normalizedUsername.isEmpty || expiresInDays < 1 || expiresInDays > 30) {
      adminAccountInvitationActionError = currentL10n.enterAValidAccountNameAnd;
      notifyListeners();
      return false;
    }
    final client = api;
    if (client == null) {
      adminAccountInvitationActionError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return false;
    }
    if (adminAccountInvitationSubmitting ||
        adminAccountInvitationBusyId != null) {
      return false;
    }
    adminAccountInvitationSubmitting = true;
    adminAccountInvitationActionError = null;
    adminAccountInvitationNotice = null;
    adminAccountInvitationToken = null;
    adminAccountInvitationTokenUsername = null;
    adminAccountInvitationTokenExpiresAt = null;
    notifyListeners();
    try {
      final receipt = await client.createAdminAccountInvitation(
        username: normalizedUsername,
        expiresInSeconds: Duration(days: expiresInDays).inSeconds,
      );
      if (!isInstanceAdmin) return false;
      adminAccountInvitationToken = receipt.token;
      adminAccountInvitationTokenUsername = receipt.username;
      adminAccountInvitationTokenExpiresAt = receipt.expiresAt;
      adminAccountInvitationNotice = currentL10n.invitationCreatedForUsername(
        receipt.username,
      );
      await Future.wait([
        loadAdminAccountInvitations(offset: 0),
        loadAdminAccounts(offset: adminAccountsPage?.offset ?? 0),
      ]);
      return isInstanceAdmin && adminAccountInvitationToken != null;
    } catch (error) {
      adminAccountInvitationActionError = friendlyError(error);
      return false;
    } finally {
      adminAccountInvitationSubmitting = false;
      notifyListeners();
    }
  }

  Future<bool> revokeAdminAccountInvitation({
    required String invitationId,
  }) async {
    if (!isInstanceAdmin) {
      adminAccountInvitationActionError =
          currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return false;
    }
    final invitation = adminAccountInvitationsPage?.invitations
        .where((item) => item.invitationId == invitationId)
        .firstOrNull;
    if (invitation == null || invitation.status != 'pending') {
      adminAccountInvitationActionError =
          currentL10n.thisInvitationIsNoLongerWaiting;
      notifyListeners();
      return false;
    }
    final client = api;
    if (client == null) {
      adminAccountInvitationActionError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return false;
    }
    if (adminAccountInvitationSubmitting ||
        adminAccountInvitationBusyId != null) {
      return false;
    }
    final refreshOffset = adminAccountInvitationsPage?.offset ?? 0;
    adminAccountInvitationBusyId = invitationId;
    adminAccountInvitationActionError = null;
    adminAccountInvitationNotice = null;
    notifyListeners();
    try {
      final receipt = await client.revokeAdminAccountInvitation(
        invitationId: invitationId,
      );
      if (!isInstanceAdmin || receipt.status != 'revoked') return false;
      await Future.wait([
        loadAdminAccountInvitations(offset: refreshOffset),
        loadAdminAccounts(offset: adminAccountsPage?.offset ?? 0),
      ]);
      adminAccountInvitationNotice = currentL10n.invitationRevoked;
      return true;
    } catch (error) {
      adminAccountInvitationActionError = friendlyError(error);
      return false;
    } finally {
      adminAccountInvitationBusyId = null;
      notifyListeners();
    }
  }

  void clearAdminAccountInvitationToken() {
    if (adminAccountInvitationToken == null &&
        adminAccountInvitationTokenUsername == null &&
        adminAccountInvitationTokenExpiresAt == null) {
      return;
    }
    adminAccountInvitationToken = null;
    adminAccountInvitationTokenUsername = null;
    adminAccountInvitationTokenExpiresAt = null;
    notifyListeners();
  }

  Future<bool> setAdminAccountStatus({
    required String userId,
    required String status,
  }) async {
    final target = _findAdminAccount(userId);
    if (!_canManageAdminAccount(target)) return false;
    if (status != 'active' && status != 'disabled' ||
        target!.status == 'deleting' ||
        status == target.status) {
      adminAccountActionError = currentL10n.thisChangeCantBeMadeIn;
      notifyListeners();
      return false;
    }
    final client = api;
    if (client == null) {
      adminAccountActionError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return false;
    }
    if (adminAccountActionBusyId != null) return false;
    final refreshOffset = adminAccountsPage?.offset ?? 0;
    final refreshSessionsOffset = adminAccountSessionsUserId == userId
        ? adminAccountSessionsPage?.offset ?? 0
        : null;
    adminAccountActionBusyId = userId;
    adminAccountActionError = null;
    adminAccountActionNotice = null;
    notifyListeners();
    try {
      final receipt = await client.setAdminAccountStatus(
        userId: userId,
        status: status,
      );
      if (!isInstanceAdmin || isCurrentAdminAccount(userId)) return false;
      if (refreshSessionsOffset != null) {
        await loadAdminAccountSessions(
          userId: userId,
          offset: refreshSessionsOffset,
        );
      }
      await loadAdminAccounts(offset: refreshOffset);
      if (!isInstanceAdmin || isCurrentAdminAccount(userId)) return false;
      adminAccountActionNotice = currentL10n
          .accountStatusUpdatedToStatusRevokedsessions(
            receipt.status,
            receipt.revokedSessions,
          );
      return true;
    } catch (error) {
      if (error is ApiException &&
          error.code == 'ACCOUNT_DELETING' &&
          isInstanceAdmin &&
          !isCurrentAdminAccount(userId)) {
        if (refreshSessionsOffset != null) {
          await loadAdminAccountSessions(
            userId: userId,
            offset: refreshSessionsOffset,
          );
        }
        _markAdminAccountDeleting(userId);
        await loadAdminAccounts(offset: refreshOffset);
      }
      adminAccountActionError = friendlyError(error);
      return false;
    } finally {
      adminAccountActionBusyId = null;
      notifyListeners();
    }
  }

  Future<bool> revokeAdminAccountSessions({required String userId}) async {
    final target = _findAdminAccount(userId);
    if (!_canManageAdminAccount(target)) return false;
    if (target!.status == 'deleting') {
      adminAccountActionError = currentL10n.anAccountBeingDeletedCantRevoke;
      notifyListeners();
      return false;
    }
    final client = api;
    if (client == null) {
      adminAccountActionError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return false;
    }
    if (adminAccountActionBusyId != null) return false;
    final refreshOffset = adminAccountsPage?.offset ?? 0;
    final refreshSessionsOffset = adminAccountSessionsUserId == userId
        ? adminAccountSessionsPage?.offset ?? 0
        : null;
    adminAccountActionBusyId = userId;
    adminAccountActionError = null;
    adminAccountActionNotice = null;
    notifyListeners();
    try {
      final receipt = await client.revokeAdminAccountSessions(userId: userId);
      if (!isInstanceAdmin || isCurrentAdminAccount(userId)) return false;
      if (refreshSessionsOffset != null) {
        await loadAdminAccountSessions(
          userId: userId,
          offset: refreshSessionsOffset,
        );
      }
      await loadAdminAccounts(offset: refreshOffset);
      if (!isInstanceAdmin || isCurrentAdminAccount(userId)) return false;
      adminAccountActionNotice =
          currentL10n.sessionsRevokedForSelectedAccount(receipt.revokedSessions);
      return true;
    } catch (error) {
      adminAccountActionError = friendlyError(error);
      return false;
    } finally {
      adminAccountActionBusyId = null;
      notifyListeners();
    }
  }

  Future<void> toggleAdminAccountSessions({required String userId}) async {
    if (adminAccountSessionsUserId == userId) {
      _resetAdminAccountSessions();
      notifyListeners();
      return;
    }
    final target = _findAdminAccount(userId);
    if (!_canManageAdminAccount(target)) return;
    _resetAdminAccountSessions();
    adminAccountSessionsUserId = userId;
    notifyListeners();
    await loadAdminAccountSessions(userId: userId, offset: 0);
  }

  Future<void> toggleAdminAccountRelayPolicy({required String userId}) async {
    if (adminAccountRelayPolicyUserId == userId) {
      _resetAdminAccountRelayPolicy();
      notifyListeners();
      return;
    }
    final target = _findAdminAccount(userId);
    if (!_canManageAdminAccount(target)) return;
    _resetAdminAccountRelayPolicy();
    adminAccountRelayPolicyUserId = userId;
    notifyListeners();
    await loadAdminAccountRelayPolicy(userId: userId);
  }

  /// Loads the selected account and instance policy together. A user response
  /// is accepted only when it was evaluated against the same instance policy
  /// revision fetched in this request. One bounded retry handles an update
  /// racing the pair of reads without displaying a mixed snapshot.
  Future<void> loadAdminAccountRelayPolicy({
    required String userId,
    bool preserveDraft = false,
  }) async {
    if (adminAccountRelayPolicyUserId != userId) return;
    final target = _findAdminAccount(userId);
    if (!_canManageAdminAccount(target)) {
      _resetAdminAccountRelayPolicy();
      notifyListeners();
      return;
    }
    if (adminAccountRelayPolicyLoading ||
        adminAccountRelayPolicySaving ||
        adminAccountRelayPolicyResetting) {
      return;
    }
    final client = api;
    if (client == null) {
      adminAccountRelayPolicyError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }

    final requestGeneration = ++_adminAccountRelayPolicyRequestGeneration;
    adminAccountRelayPolicyLoading = true;
    adminAccountRelayPolicyError = null;
    adminAccountRelayPolicySaveError = null;
    adminAccountRelayPolicyNotice = null;
    adminAccountRelayPolicyConflict = preserveDraft;
    if (!preserveDraft) {
      adminAccountRelayUserPolicy = null;
      adminAccountRelayInstancePolicy = null;
    }
    notifyListeners();
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        final responses = await Future.wait<Object>([
          client.instanceAdminRelayPolicy(),
          client.instanceAdminRelayUserPolicy(userId),
        ]);
        if (!_isCurrentAdminAccountRelayPolicyRequest(
          requestGeneration,
          userId,
          client,
        )) {
          return;
        }
        final instancePolicy = responses[0] as InstanceAdminRelayPolicy;
        final userPolicy = responses[1] as InstanceAdminRelayUserPolicy;
        if (userPolicy.instancePolicyRevision != instancePolicy.revision) {
          continue;
        }
        adminAccountRelayInstancePolicy = instancePolicy;
        adminAccountRelayUserPolicy = userPolicy;
        adminAccountRelayPolicyConflict = false;
        if (!preserveDraft) _seedAdminAccountRelayPolicyDraft(userPolicy);
        return;
      }
      if (_isCurrentAdminAccountRelayPolicyRequest(
        requestGeneration,
        userId,
        client,
      )) {
        adminAccountRelayInstancePolicy = null;
        adminAccountRelayUserPolicy = null;
        adminAccountRelayPolicyConflict = true;
        adminAccountRelayPolicyError =
            currentL10n.theInstanceRelayPolicyChangedWhile2;
      }
    } catch (error) {
      if (requestGeneration != _adminAccountRelayPolicyRequestGeneration) {
        return;
      }
      if (!isInstanceAdmin || _isAdminRelayPolicySessionLoss(error)) {
        _resetInstanceAdminOverview();
        notifyListeners();
        return;
      }
      if (_isCurrentAdminAccountRelayPolicyRequest(
        requestGeneration,
        userId,
        client,
      )) {
        adminAccountRelayPolicyError = friendlyError(error);
      }
    } finally {
      if (requestGeneration == _adminAccountRelayPolicyRequestGeneration) {
        adminAccountRelayPolicyLoading = false;
        notifyListeners();
      }
    }
  }

  void editAdminAccountRelayPolicyDraft({
    required String userId,
    bool? enabled,
    String? allowCidrsText,
    String? allowPortsText,
  }) {
    if (adminAccountRelayPolicyUserId != userId ||
        adminAccountRelayPolicySaving ||
        adminAccountRelayPolicyResetting) {
      return;
    }
    if (enabled != null) adminAccountRelayPolicyEnabledDraft = enabled;
    if (allowCidrsText != null) {
      adminAccountRelayPolicyCidrsDraft = allowCidrsText;
    }
    if (allowPortsText != null) {
      adminAccountRelayPolicyPortsDraft = allowPortsText;
    }
    adminAccountRelayPolicySaveError = null;
    adminAccountRelayPolicyNotice = null;
    notifyListeners();
  }

  Future<bool> saveAdminAccountRelayPolicyDraft({
    required String userId,
  }) async {
    final target = _findAdminAccount(userId);
    if (!_canManageAdminAccount(target) ||
        adminAccountRelayPolicyUserId != userId) {
      return false;
    }
    final current = adminAccountRelayUserPolicy;
    final instancePolicy = adminAccountRelayInstancePolicy;
    if (current == null || instancePolicy == null) {
      adminAccountRelayPolicySaveError =
          currentL10n.loadAConsistentAccountAndInstance2;
      notifyListeners();
      return false;
    }
    if (current.instancePolicyRevision != instancePolicy.revision ||
        adminAccountRelayPolicyConflict) {
      adminAccountRelayPolicySaveError =
          currentL10n.reloadTheLatestAccountAndInstance2;
      notifyListeners();
      return false;
    }
    if (adminAccountRelayPolicyLoading ||
        adminAccountRelayPolicySaving ||
        adminAccountRelayPolicyResetting) {
      return false;
    }

    final selected = current.policy;
    final unchangedSelection =
        adminAccountRelayPolicyEnabledDraft == selected.enabled &&
        adminAccountRelayPolicyCidrsDraft == selected.allowCidrs.join('\n') &&
        adminAccountRelayPolicyPortsDraft == selected.allowPorts.join(', ');
    late final bool enabled;
    late final List<String> allowCidrs;
    late final List<int> allowPorts;
    if (unchangedSelection) {
      // The selected instance/account policy may exceed a newly narrowed
      // deployment ceiling. An exact no-op must still reach the server so it
      // can preserve inheritance instead of materializing an override from
      // the currently effective intersection.
      enabled = selected.enabled;
      allowCidrs = selected.allowCidrs;
      allowPorts = selected.allowPorts;
    } else {
      late final AdminRelayPolicyDraft draft;
      try {
        draft = AdminRelayPolicyDraft.parseAndValidate(
          enabled: adminAccountRelayPolicyEnabledDraft,
          allowCidrsText: adminAccountRelayPolicyCidrsDraft,
          allowPortsText: adminAccountRelayPolicyPortsDraft,
          deploymentLimits: instancePolicy.effectiveUserRelayPolicyLimits,
        );
      } on FormatException catch (error) {
        adminAccountRelayPolicySaveError = error.message;
        adminAccountRelayPolicyNotice = null;
        notifyListeners();
        return false;
      }
      enabled = draft.enabled;
      allowCidrs = draft.allowCidrs;
      allowPorts = draft.allowPorts;
    }
    final client = api;
    if (client == null) {
      adminAccountRelayPolicySaveError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return false;
    }
    final requestGeneration = ++_adminAccountRelayPolicyRequestGeneration;
    adminAccountRelayPolicySaving = true;
    adminAccountRelayPolicySaveError = null;
    adminAccountRelayPolicyNotice = null;
    notifyListeners();
    try {
      final updated = await client.updateInstanceAdminRelayUserPolicy(
        userId: userId,
        expectedRevision: current.revision,
        expectedInstancePolicyRevision: instancePolicy.revision,
        enabled: enabled,
        allowCidrs: [...allowCidrs]..sort(),
        allowPorts: [...allowPorts]..sort(),
      );
      if (!_isCurrentAdminAccountRelayPolicyRequest(
        requestGeneration,
        userId,
        client,
      )) {
        return false;
      }
      if (updated.instancePolicyRevision != instancePolicy.revision) {
        adminAccountRelayUserPolicy = null;
        adminAccountRelayInstancePolicy = null;
        adminAccountRelayPolicyConflict = true;
        adminAccountRelayPolicySaveError =
            currentL10n.theInstancePolicyChangedWhileSaving;
        return false;
      }
      adminAccountRelayUserPolicy = updated;
      _seedAdminAccountRelayPolicyDraft(updated);
      adminAccountRelayPolicyConflict = false;
      adminAccountRelayPolicyNotice = updated.inherited
          ? currentL10n.theAccountNowInheritsTheInstance
          : currentL10n.accountRelayPolicySaved;
      return true;
    } catch (error) {
      if (requestGeneration == _adminAccountRelayPolicyRequestGeneration &&
          (!isInstanceAdmin || _isAdminRelayPolicySessionLoss(error))) {
        _resetInstanceAdminOverview();
        notifyListeners();
        return false;
      }
      if (!_isCurrentAdminAccountRelayPolicyRequest(
        requestGeneration,
        userId,
        client,
      )) {
        return false;
      }
      adminAccountRelayPolicySaveError = friendlyError(error);
      if (error is ApiException &&
          (error.statusCode == 409 || error.statusCode == 422)) {
        adminAccountRelayPolicyConflict = true;
      }
      return false;
    } finally {
      if (requestGeneration == _adminAccountRelayPolicyRequestGeneration) {
        adminAccountRelayPolicySaving = false;
        notifyListeners();
      }
    }
  }

  Future<bool> resetAdminAccountRelayPolicyToInherit({
    required String userId,
  }) async {
    final target = _findAdminAccount(userId);
    if (!_canManageAdminAccount(target) ||
        adminAccountRelayPolicyUserId != userId) {
      return false;
    }
    final current = adminAccountRelayUserPolicy;
    final instancePolicy = adminAccountRelayInstancePolicy;
    if (current == null || instancePolicy == null) {
      adminAccountRelayPolicySaveError =
          currentL10n.loadAConsistentAccountAndInstance;
      notifyListeners();
      return false;
    }
    if (current.instancePolicyRevision != instancePolicy.revision ||
        adminAccountRelayPolicyConflict) {
      adminAccountRelayPolicySaveError =
          currentL10n.reloadTheLatestAccountAndInstance;
      notifyListeners();
      return false;
    }
    if (adminAccountRelayPolicyLoading ||
        adminAccountRelayPolicySaving ||
        adminAccountRelayPolicyResetting) {
      return false;
    }
    final client = api;
    if (client == null) {
      adminAccountRelayPolicySaveError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return false;
    }
    final requestGeneration = ++_adminAccountRelayPolicyRequestGeneration;
    adminAccountRelayPolicyResetting = true;
    adminAccountRelayPolicySaveError = null;
    adminAccountRelayPolicyNotice = null;
    notifyListeners();
    try {
      final reset = await client.resetInstanceAdminRelayUserPolicy(
        userId: userId,
        expectedRevision: current.revision,
      );
      if (!_isCurrentAdminAccountRelayPolicyRequest(
        requestGeneration,
        userId,
        client,
      )) {
        return false;
      }
      if (reset.instancePolicyRevision != instancePolicy.revision) {
        adminAccountRelayUserPolicy = null;
        adminAccountRelayInstancePolicy = null;
        adminAccountRelayPolicyConflict = true;
        adminAccountRelayPolicySaveError =
            currentL10n.theInstancePolicyChangedWhileResetting;
        return false;
      }
      adminAccountRelayUserPolicy = reset;
      _seedAdminAccountRelayPolicyDraft(reset);
      adminAccountRelayPolicyConflict = false;
      adminAccountRelayPolicyNotice =
          currentL10n.accountRelayPolicyResetToInherit;
      return true;
    } catch (error) {
      if (requestGeneration == _adminAccountRelayPolicyRequestGeneration &&
          (!isInstanceAdmin || _isAdminRelayPolicySessionLoss(error))) {
        _resetInstanceAdminOverview();
        notifyListeners();
        return false;
      }
      if (!_isCurrentAdminAccountRelayPolicyRequest(
        requestGeneration,
        userId,
        client,
      )) {
        return false;
      }
      adminAccountRelayPolicySaveError = friendlyError(error);
      if (error is ApiException &&
          (error.statusCode == 409 || error.statusCode == 422)) {
        adminAccountRelayPolicyConflict = true;
      }
      return false;
    } finally {
      if (requestGeneration == _adminAccountRelayPolicyRequestGeneration) {
        adminAccountRelayPolicyResetting = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadAdminRelayGroups() async {
    if (!isInstanceAdmin) {
      adminRelayGroupsError = currentL10n.theCurrentAccountDoesntHaveInstance;
      notifyListeners();
      return;
    }
    final client = api;
    if (client == null) {
      adminRelayGroupsError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    final generation = ++_adminRelayGroupsRequestGeneration;
    adminRelayGroupsLoading = true;
    adminRelayGroupsError = null;
    notifyListeners();
    try {
      final groups = await client.adminRelayGroups();
      if (generation != _adminRelayGroupsRequestGeneration ||
          !_isCurrentAdminRelayGroupClient(client)) {
        return;
      }
      adminRelayGroups = groups;
      final selectedId = adminRelayGroupId;
      if (selectedId != null &&
          !groups.any((group) => group.groupId == selectedId)) {
        _resetAdminRelayGroupDetail();
      }
    } catch (error) {
      if (generation != _adminRelayGroupsRequestGeneration) return;
      if (!isInstanceAdmin || _isAdminRelayPolicySessionLoss(error)) {
        _resetInstanceAdminOverview();
        notifyListeners();
        return;
      }
      adminRelayGroupsError = friendlyError(error);
    } finally {
      if (generation == _adminRelayGroupsRequestGeneration) {
        adminRelayGroupsLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> selectAdminRelayGroup({required String? groupId}) async {
    if (groupId == adminRelayGroupId) {
      _resetAdminRelayGroupDetail();
      notifyListeners();
      return;
    }
    if (groupId != null &&
        !adminRelayGroups.any((group) => group.groupId == groupId)) {
      adminRelayGroupActionError = currentL10n.theSelectedServerAccessGroupNo;
      notifyListeners();
      return;
    }
    _resetAdminRelayGroupDetail();
    adminRelayGroupId = groupId;
    notifyListeners();
    if (groupId != null) await loadAdminRelayGroupDetail(groupId: groupId);
  }

  Future<void> loadAdminRelayGroupDetail({
    required String groupId,
    bool preserveDraft = false,
  }) async {
    if (adminRelayGroupId != groupId || !isInstanceAdmin) return;
    final client = api;
    if (client == null) {
      adminRelayGroupDetailError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    if (adminRelayGroupDetailLoading || adminRelayGroupDetailSaving) return;
    final generation = ++_adminRelayGroupDetailRequestGeneration;
    adminRelayGroupDetailLoading = true;
    adminRelayGroupDetailError = null;
    adminRelayGroupDetailSaveError = null;
    adminRelayGroupDetailNotice = null;
    adminRelayGroupConflict = preserveDraft;
    _resetAdminRelayGroupPreview();
    if (!preserveDraft) {
      adminRelayGroupDetail = null;
      adminRelayGroupInstancePolicy = null;
    }
    notifyListeners();
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        final responses = await Future.wait<Object>([
          client.adminRelayGroup(groupId),
          client.instanceAdminRelayPolicy(),
        ]);
        if (!_isCurrentAdminRelayGroupDetailRequest(
          generation,
          groupId,
          client,
        )) {
          return;
        }
        final detail = responses[0] as AdminRelayGroupDetail;
        final instancePolicy = responses[1] as InstanceAdminRelayPolicy;
        if (detail.policy.instancePolicyRevision != instancePolicy.revision) {
          continue;
        }
        adminRelayGroupDetail = detail;
        adminRelayGroupInstancePolicy = instancePolicy;
        adminRelayGroupConflict = false;
        if (!preserveDraft) _seedAdminRelayGroupDrafts(detail);
        return;
      }
      if (_isCurrentAdminRelayGroupDetailRequest(generation, groupId, client)) {
        adminRelayGroupDetail = null;
        adminRelayGroupInstancePolicy = null;
        adminRelayGroupConflict = true;
        adminRelayGroupDetailError =
            currentL10n.theInstanceRelayPolicyChangedWhile;
      }
    } catch (error) {
      if (generation != _adminRelayGroupDetailRequestGeneration) return;
      if (!isInstanceAdmin || _isAdminRelayPolicySessionLoss(error)) {
        _resetInstanceAdminOverview();
        notifyListeners();
        return;
      }
      if (_isCurrentAdminRelayGroupDetailRequest(generation, groupId, client)) {
        adminRelayGroupDetailError = friendlyError(error);
      }
    } finally {
      if (generation == _adminRelayGroupDetailRequestGeneration) {
        adminRelayGroupDetailLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadAdminRelayGroupMemberEffectivePolicy({
    required String? userId,
  }) async {
    final detail = adminRelayGroupDetail;
    if (userId == null) {
      _resetAdminRelayGroupPreview();
      notifyListeners();
      return;
    }
    if (detail == null ||
        !detail.members.any((member) => member.userId == userId) ||
        !isInstanceAdmin) {
      adminRelayGroupMemberEffectivePolicyError =
          currentL10n.selectAnActiveMemberOfThis;
      notifyListeners();
      return;
    }
    final client = api;
    if (client == null) {
      adminRelayGroupMemberEffectivePolicyError =
          currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    final generation = ++_adminRelayGroupPreviewRequestGeneration;
    adminRelayGroupPreviewUserId = userId;
    adminRelayGroupMemberEffectivePolicy = null;
    adminRelayGroupMemberEffectivePolicyLoading = true;
    adminRelayGroupMemberEffectivePolicyError = null;
    notifyListeners();
    try {
      final policy = await client.instanceAdminRelayUserPolicy(userId);
      if (!_isCurrentAdminRelayGroupPreviewRequest(
        generation,
        userId,
        detail.groupId,
        client,
      )) {
        return;
      }
      final instancePolicy = adminRelayGroupInstancePolicy;
      if (instancePolicy == null ||
          policy.instancePolicyRevision != instancePolicy.revision) {
        adminRelayGroupConflict = true;
        adminRelayGroupMemberEffectivePolicyError =
            currentL10n.theInstanceRelayPolicyChangedReload;
        return;
      }
      adminRelayGroupMemberEffectivePolicy = policy;
    } catch (error) {
      if (!_isCurrentAdminRelayGroupPreviewRequest(
        generation,
        userId,
        detail.groupId,
        client,
      )) {
        return;
      }
      if (!isInstanceAdmin || _isAdminRelayPolicySessionLoss(error)) {
        _resetInstanceAdminOverview();
        notifyListeners();
        return;
      }
      adminRelayGroupMemberEffectivePolicyError = friendlyError(error);
    } finally {
      if (generation == _adminRelayGroupPreviewRequestGeneration) {
        adminRelayGroupMemberEffectivePolicyLoading = false;
        notifyListeners();
      }
    }
  }

  bool _isCurrentAdminRelayGroupPreviewRequest(
    int generation,
    String userId,
    String groupId,
    ApiClient client,
  ) =>
      !_controllerDisposed &&
      generation == _adminRelayGroupPreviewRequestGeneration &&
      adminRelayGroupId == groupId &&
      adminRelayGroupPreviewUserId == userId &&
      adminRelayGroupDetail?.members.any((member) => member.userId == userId) ==
          true &&
      _isCurrentAdminRelayGroupClient(client);

  void _resetAdminRelayGroupPreview() {
    _adminRelayGroupPreviewRequestGeneration++;
    adminRelayGroupPreviewUserId = null;
    adminRelayGroupMemberEffectivePolicy = null;
    adminRelayGroupMemberEffectivePolicyLoading = false;
    adminRelayGroupMemberEffectivePolicyError = null;
  }

  Future<bool> createAdminRelayGroup({required String name}) async {
    if (!isInstanceAdmin || adminRelayGroupSaving) return false;
    final client = api;
    if (client == null) {
      adminRelayGroupActionError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return false;
    }
    adminRelayGroupSaving = true;
    adminRelayGroupActionError = null;
    adminRelayGroupNotice = null;
    notifyListeners();
    try {
      final created = await client.createAdminRelayGroup(name: name.trim());
      if (!_isCurrentAdminRelayGroupClient(client)) return false;
      _resetAdminRelayGroupDetail();
      adminRelayGroupId = created.groupId;
      adminRelayGroupNotice = 'Server-managed access group created.';
      await loadAdminRelayGroups();
      await loadAdminRelayGroupDetail(groupId: created.groupId);
      return adminRelayGroupDetail?.groupId == created.groupId;
    } catch (error) {
      if (!isInstanceAdmin || _isAdminRelayPolicySessionLoss(error)) {
        _resetInstanceAdminOverview();
        notifyListeners();
        return false;
      }
      adminRelayGroupActionError = friendlyError(error);
      return false;
    } finally {
      adminRelayGroupSaving = false;
      notifyListeners();
    }
  }

  void editAdminRelayGroupNameDraft(String value) {
    if (adminRelayGroupSaving || adminRelayGroupDetailSaving) return;
    adminRelayGroupNameDraft = value;
    adminRelayGroupDetailSaveError = null;
    adminRelayGroupDetailNotice = null;
    notifyListeners();
  }

  Future<bool> saveAdminRelayGroupName() async {
    final detail = adminRelayGroupDetail;
    final client = api;
    if (!isInstanceAdmin ||
        detail == null ||
        client == null ||
        adminRelayGroupSaving ||
        adminRelayGroupDetailLoading ||
        adminRelayGroupDetailSaving ||
        adminRelayGroupConflict) {
      return false;
    }
    if (adminRelayGroupNameDraft.trim() == detail.name) return true;
    final generation = ++_adminRelayGroupDetailRequestGeneration;
    adminRelayGroupDetailSaving = true;
    adminRelayGroupDetailSaveError = null;
    adminRelayGroupDetailNotice = null;
    notifyListeners();
    try {
      final updated = await client.updateAdminRelayGroup(
        groupId: detail.groupId,
        expectedRevision: detail.revision,
        name: adminRelayGroupNameDraft,
      );
      if (!_isCurrentAdminRelayGroupDetailRequest(
        generation,
        detail.groupId,
        client,
      )) {
        return false;
      }
      _resetAdminRelayGroupPreview();
      adminRelayGroupDetail = updated;
      adminRelayGroupNameDraft = updated.name;
      adminRelayGroupDetailNotice = 'Server-managed access group renamed.';
      await loadAdminRelayGroups();
      return true;
    } catch (error) {
      if (!_isCurrentAdminRelayGroupDetailRequest(
        generation,
        detail.groupId,
        client,
      )) {
        return false;
      }
      adminRelayGroupDetailSaveError = friendlyError(error);
      if (error is ApiException && error.statusCode == 409) {
        adminRelayGroupConflict = true;
      }
      return false;
    } finally {
      if (generation == _adminRelayGroupDetailRequestGeneration) {
        adminRelayGroupDetailSaving = false;
        notifyListeners();
      }
    }
  }

  Future<bool> deleteAdminRelayGroup() async {
    final detail = adminRelayGroupDetail;
    final client = api;
    if (!isInstanceAdmin ||
        detail == null ||
        client == null ||
        adminRelayGroupSaving ||
        adminRelayGroupDetailLoading ||
        adminRelayGroupDetailSaving ||
        adminRelayGroupConflict) {
      return false;
    }
    final generation = ++_adminRelayGroupDetailRequestGeneration;
    adminRelayGroupSaving = true;
    adminRelayGroupDetailSaveError = null;
    adminRelayGroupDetailNotice = null;
    notifyListeners();
    try {
      await client.deleteAdminRelayGroup(
        groupId: detail.groupId,
        expectedRevision: detail.revision,
        expectedMembershipRevision: detail.membershipRevision,
        expectedPolicyRevision: detail.policy.revision,
      );
      if (!_isCurrentAdminRelayGroupClient(client) ||
          generation != _adminRelayGroupDetailRequestGeneration) {
        return false;
      }
      _resetAdminRelayGroupDetail();
      adminRelayGroupNotice = 'Server-managed access group deleted.';
      await loadAdminRelayGroups();
      return true;
    } catch (error) {
      if (generation != _adminRelayGroupDetailRequestGeneration) return false;
      adminRelayGroupDetailSaveError = friendlyError(error);
      if (error is ApiException && error.statusCode == 409) {
        adminRelayGroupConflict = true;
      }
      return false;
    } finally {
      adminRelayGroupSaving = false;
      notifyListeners();
    }
  }

  void editAdminRelayGroupMemberIdsDraft(List<String> userIds) {
    if (adminRelayGroupDetailSaving || adminRelayGroupSaving) return;
    adminRelayGroupMemberIdsDraft = List.unmodifiable(
      userIds.toSet().toList()..sort(),
    );
    adminRelayGroupDetailSaveError = null;
    adminRelayGroupDetailNotice = null;
    notifyListeners();
  }

  Future<bool> saveAdminRelayGroupMembers() async {
    final detail = adminRelayGroupDetail;
    final client = api;
    if (!isInstanceAdmin ||
        detail == null ||
        client == null ||
        adminRelayGroupSaving ||
        adminRelayGroupDetailLoading ||
        adminRelayGroupDetailSaving ||
        adminRelayGroupConflict) {
      return false;
    }
    final currentIds = detail.members.map((member) => member.userId).toSet();
    if (currentIds.length == adminRelayGroupMemberIdsDraft.length &&
        currentIds.containsAll(adminRelayGroupMemberIdsDraft)) {
      return true;
    }
    final generation = ++_adminRelayGroupDetailRequestGeneration;
    adminRelayGroupDetailSaving = true;
    adminRelayGroupDetailSaveError = null;
    adminRelayGroupDetailNotice = null;
    notifyListeners();
    try {
      final updated = await client.updateAdminRelayGroupMembers(
        groupId: detail.groupId,
        expectedRevision: detail.membershipRevision,
        userIds: adminRelayGroupMemberIdsDraft,
      );
      if (!_isCurrentAdminRelayGroupDetailRequest(
        generation,
        detail.groupId,
        client,
      )) {
        return false;
      }
      _resetAdminRelayGroupPreview();
      adminRelayGroupDetail = updated;
      _seedAdminRelayGroupDrafts(updated);
      adminRelayGroupConflict = false;
      adminRelayGroupDetailNotice = currentL10n.groupMembershipSaved;
      await loadAdminRelayGroups();
      return true;
    } catch (error) {
      if (!_isCurrentAdminRelayGroupDetailRequest(
        generation,
        detail.groupId,
        client,
      )) {
        return false;
      }
      adminRelayGroupDetailSaveError = friendlyError(error);
      if (error is ApiException && error.statusCode == 409) {
        adminRelayGroupConflict = true;
      }
      return false;
    } finally {
      if (generation == _adminRelayGroupDetailRequestGeneration) {
        adminRelayGroupDetailSaving = false;
        notifyListeners();
      }
    }
  }

  void editAdminRelayGroupPolicyDraft({
    bool? enabled,
    String? allowCidrsText,
    String? allowPortsText,
  }) {
    if (adminRelayGroupSaving || adminRelayGroupDetailSaving) return;
    if (enabled != null) adminRelayGroupPolicyEnabledDraft = enabled;
    if (allowCidrsText != null)
      adminRelayGroupPolicyCidrsDraft = allowCidrsText;
    if (allowPortsText != null)
      adminRelayGroupPolicyPortsDraft = allowPortsText;
    adminRelayGroupDetailSaveError = null;
    adminRelayGroupDetailNotice = null;
    notifyListeners();
  }

  Future<bool> saveAdminRelayGroupPolicy() async {
    final detail = adminRelayGroupDetail;
    final instancePolicy = adminRelayGroupInstancePolicy;
    final client = api;
    if (!isInstanceAdmin ||
        detail == null ||
        instancePolicy == null ||
        client == null ||
        adminRelayGroupSaving ||
        adminRelayGroupDetailLoading ||
        adminRelayGroupDetailSaving ||
        adminRelayGroupConflict) {
      return false;
    }
    if (detail.policy.instancePolicyRevision != instancePolicy.revision) {
      adminRelayGroupConflict = true;
      adminRelayGroupDetailSaveError =
          currentL10n.reloadTheLatestGroupAndInstance2;
      notifyListeners();
      return false;
    }
    final selected = detail.policy.policy;
    final unchanged =
        adminRelayGroupPolicyEnabledDraft == selected.enabled &&
        adminRelayGroupPolicyCidrsDraft == selected.allowCidrs.join('\n') &&
        adminRelayGroupPolicyPortsDraft == selected.allowPorts.join(', ');
    late final AdminRelayPolicyDraft draft;
    if (unchanged) {
      draft = AdminRelayPolicyDraft(
        enabled: selected.enabled,
        allowCidrs: selected.allowCidrs,
        allowPorts: selected.allowPorts,
      );
    } else {
      try {
        draft = AdminRelayPolicyDraft.parseAndValidate(
          enabled: adminRelayGroupPolicyEnabledDraft,
          allowCidrsText: adminRelayGroupPolicyCidrsDraft,
          allowPortsText: adminRelayGroupPolicyPortsDraft,
          deploymentLimits: instancePolicy.effectiveUserRelayPolicyLimits,
        );
      } on FormatException catch (error) {
        adminRelayGroupDetailSaveError = error.message;
        adminRelayGroupDetailNotice = null;
        notifyListeners();
        return false;
      }
    }
    final generation = ++_adminRelayGroupDetailRequestGeneration;
    adminRelayGroupDetailSaving = true;
    adminRelayGroupDetailSaveError = null;
    adminRelayGroupDetailNotice = null;
    notifyListeners();
    try {
      final updated = await client.updateAdminRelayGroupPolicy(
        groupId: detail.groupId,
        expectedRevision: detail.policy.revision,
        expectedInstancePolicyRevision: instancePolicy.revision,
        enabled: draft.enabled,
        allowCidrs: draft.allowCidrs,
        allowPorts: draft.allowPorts,
      );
      if (!_isCurrentAdminRelayGroupDetailRequest(
        generation,
        detail.groupId,
        client,
      )) {
        return false;
      }
      if (updated.policy.instancePolicyRevision != instancePolicy.revision) {
        adminRelayGroupConflict = true;
        adminRelayGroupDetailSaveError =
            currentL10n.theInstancePolicyChangedWhileSaving;
        return false;
      }
      _resetAdminRelayGroupPreview();
      adminRelayGroupDetail = updated;
      _seedAdminRelayGroupDrafts(updated);
      adminRelayGroupConflict = false;
      adminRelayGroupDetailNotice = updated.policy.inherited
          ? currentL10n.theGroupNowInheritsTheInstance
          : currentL10n.groupRelayPolicySaved;
      await loadAdminRelayGroups();
      return true;
    } catch (error) {
      if (!_isCurrentAdminRelayGroupDetailRequest(
        generation,
        detail.groupId,
        client,
      )) {
        return false;
      }
      adminRelayGroupDetailSaveError = friendlyError(error);
      if (error is ApiException && error.statusCode == 409) {
        adminRelayGroupConflict = true;
      }
      return false;
    } finally {
      if (generation == _adminRelayGroupDetailRequestGeneration) {
        adminRelayGroupDetailSaving = false;
        notifyListeners();
      }
    }
  }

  Future<bool> resetAdminRelayGroupPolicyToInherit() async {
    final detail = adminRelayGroupDetail;
    final instancePolicy = adminRelayGroupInstancePolicy;
    final client = api;
    if (!isInstanceAdmin ||
        detail == null ||
        instancePolicy == null ||
        client == null ||
        detail.policy.inherited ||
        adminRelayGroupSaving ||
        adminRelayGroupDetailLoading ||
        adminRelayGroupDetailSaving ||
        adminRelayGroupConflict) {
      return false;
    }
    if (detail.policy.instancePolicyRevision != instancePolicy.revision) {
      adminRelayGroupConflict = true;
      adminRelayGroupDetailSaveError =
          currentL10n.reloadTheLatestGroupAndInstance;
      notifyListeners();
      return false;
    }
    final generation = ++_adminRelayGroupDetailRequestGeneration;
    adminRelayGroupDetailSaving = true;
    adminRelayGroupDetailSaveError = null;
    adminRelayGroupDetailNotice = null;
    notifyListeners();
    try {
      final updated = await client.resetAdminRelayGroupPolicy(
        groupId: detail.groupId,
        expectedRevision: detail.policy.revision,
      );
      if (!_isCurrentAdminRelayGroupDetailRequest(
        generation,
        detail.groupId,
        client,
      )) {
        return false;
      }
      if (updated.policy.instancePolicyRevision != instancePolicy.revision) {
        adminRelayGroupConflict = true;
        adminRelayGroupDetailSaveError =
            currentL10n.theInstancePolicyChangedWhileResetting;
        return false;
      }
      _resetAdminRelayGroupPreview();
      adminRelayGroupDetail = updated;
      _seedAdminRelayGroupDrafts(updated);
      adminRelayGroupConflict = false;
      adminRelayGroupDetailNotice = currentL10n.groupRelayPolicyResetToInherit;
      await loadAdminRelayGroups();
      return true;
    } catch (error) {
      if (!_isCurrentAdminRelayGroupDetailRequest(
        generation,
        detail.groupId,
        client,
      )) {
        return false;
      }
      adminRelayGroupDetailSaveError = friendlyError(error);
      if (error is ApiException && error.statusCode == 409) {
        adminRelayGroupConflict = true;
      }
      return false;
    } finally {
      if (generation == _adminRelayGroupDetailRequestGeneration) {
        adminRelayGroupDetailSaving = false;
        notifyListeners();
      }
    }
  }

  void _seedAdminRelayGroupDrafts(AdminRelayGroupDetail detail) {
    adminRelayGroupNameDraft = detail.name;
    adminRelayGroupMemberIdsDraft = List.unmodifiable(
      detail.members.map((member) => member.userId).toList()..sort(),
    );
    adminRelayGroupPolicyEnabledDraft = detail.policy.policy.enabled;
    adminRelayGroupPolicyCidrsDraft = detail.policy.policy.allowCidrs.join(
      '\n',
    );
    adminRelayGroupPolicyPortsDraft = detail.policy.policy.allowPorts.join(
      ', ',
    );
  }

  bool _isCurrentAdminRelayGroupClient(ApiClient client) =>
      !_controllerDisposed && isInstanceAdmin && identical(api, client);

  bool _isCurrentAdminRelayGroupDetailRequest(
    int generation,
    String groupId,
    ApiClient client,
  ) =>
      generation == _adminRelayGroupDetailRequestGeneration &&
      adminRelayGroupId == groupId &&
      _isCurrentAdminRelayGroupClient(client);

  void _resetAdminRelayGroupDetail() {
    _adminRelayGroupDetailRequestGeneration++;
    _resetAdminRelayGroupPreview();
    adminRelayGroupId = null;
    adminRelayGroupDetail = null;
    adminRelayGroupInstancePolicy = null;
    adminRelayGroupDetailLoading = false;
    adminRelayGroupDetailSaving = false;
    adminRelayGroupConflict = false;
    adminRelayGroupDetailError = null;
    adminRelayGroupDetailSaveError = null;
    adminRelayGroupDetailNotice = null;
    adminRelayGroupNameDraft = '';
    adminRelayGroupMemberIdsDraft = const [];
    adminRelayGroupPolicyEnabledDraft = false;
    adminRelayGroupPolicyCidrsDraft = '';
    adminRelayGroupPolicyPortsDraft = '';
  }

  void _resetAdminRelayGroups() {
    _adminRelayGroupsRequestGeneration++;
    adminRelayGroups = const [];
    adminRelayGroupsLoading = false;
    adminRelayGroupsError = null;
    adminRelayGroupSaving = false;
    adminRelayGroupActionError = null;
    adminRelayGroupNotice = null;
    _resetAdminRelayGroupDetail();
  }

  void _seedAdminAccountRelayPolicyDraft(InstanceAdminRelayUserPolicy policy) {
    final selected = policy.policy;
    adminAccountRelayPolicyEnabledDraft = selected.enabled;
    adminAccountRelayPolicyCidrsDraft = selected.allowCidrs.join('\n');
    adminAccountRelayPolicyPortsDraft = selected.allowPorts.join(', ');
  }

  bool _isCurrentAdminAccountRelayPolicyRequest(
    int requestGeneration,
    String userId,
    ApiClient client,
  ) =>
      !_controllerDisposed &&
      requestGeneration == _adminAccountRelayPolicyRequestGeneration &&
      adminAccountRelayPolicyUserId == userId &&
      isInstanceAdmin &&
      identical(api, client) &&
      _isEligibleAdminRelayPolicyTarget(userId);

  bool _isEligibleAdminRelayPolicyTarget(String userId) {
    final target = _findAdminAccount(userId);
    return isInstanceAdmin &&
        target != null &&
        target.status != 'deleting' &&
        !isCurrentAdminAccount(userId);
  }

  bool _isAdminRelayPolicySessionLoss(Object error) =>
      error is ApiException &&
      const {
        'AUTH_REQUIRED',
        'DEVICE_REVOKED',
        'INSTANCE_ADMIN_REQUIRED',
      }.contains(error.code);

  void _resetAdminAccountRelayPolicy() {
    _adminAccountRelayPolicyRequestGeneration++;
    adminAccountRelayPolicyUserId = null;
    adminAccountRelayUserPolicy = null;
    adminAccountRelayInstancePolicy = null;
    adminAccountRelayPolicyLoading = false;
    adminAccountRelayPolicySaving = false;
    adminAccountRelayPolicyResetting = false;
    adminAccountRelayPolicyConflict = false;
    adminAccountRelayPolicyError = null;
    adminAccountRelayPolicySaveError = null;
    adminAccountRelayPolicyNotice = null;
    adminAccountRelayPolicyEnabledDraft = false;
    adminAccountRelayPolicyCidrsDraft = '';
    adminAccountRelayPolicyPortsDraft = '';
  }

  Future<void> loadAdminAccountSessions({
    required String userId,
    int? offset,
  }) async {
    final target = _findAdminAccount(userId);
    if (!_canManageAdminAccount(target)) return;
    if (adminAccountSessionsUserId != userId) {
      adminAccountSessionsUserId = userId;
      adminAccountSessionsPage = null;
      adminAccountSessionsError = null;
      adminAccountSessionsPageOffset = 0;
    }
    if (offset != null && (offset < 0 || offset > 1000000)) {
      throw ArgumentError.value(
        offset,
        'offset',
        currentL10n.mustBeBetween0And1000000,
      );
    }
    final client = api;
    if (client == null) {
      adminAccountSessionsError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return;
    }
    final requestedOffset = offset ?? adminAccountSessionsPageOffset;
    final requestGeneration = ++_adminAccountSessionsRequestGeneration;
    adminAccountSessionsLoading = true;
    adminAccountSessionsError = null;
    notifyListeners();
    try {
      final page = await client.adminAccountSessions(
        userId: userId,
        limit: adminAccountPageSize,
        offset: requestedOffset,
      );
      if (requestGeneration != _adminAccountSessionsRequestGeneration ||
          !isInstanceAdmin ||
          isCurrentAdminAccount(userId) ||
          adminAccountSessionsUserId != userId) {
        return;
      }
      if (page.limit != adminAccountPageSize ||
          page.offset != requestedOffset) {
        throw FormatException(
          currentL10n.invalidAdminAccountSessionsPaginationResponse,
        );
      }
      adminAccountSessionsPage = page;
      adminAccountSessionsPageOffset = page.offset;
    } catch (error) {
      if (requestGeneration != _adminAccountSessionsRequestGeneration) return;
      adminAccountSessionsError = friendlyError(error);
    } finally {
      if (requestGeneration == _adminAccountSessionsRequestGeneration) {
        adminAccountSessionsLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> nextAdminAccountSessionsPage({required String userId}) async {
    final page = adminAccountSessionsPage;
    if (adminAccountSessionsLoading || page == null || !page.hasNext) return;
    await loadAdminAccountSessions(
      userId: userId,
      offset: page.offset + page.limit,
    );
  }

  Future<void> previousAdminAccountSessionsPage({
    required String userId,
  }) async {
    final page = adminAccountSessionsPage;
    if (adminAccountSessionsLoading || page == null || !page.hasPrevious) {
      return;
    }
    final previousOffset = page.offset - page.limit;
    await loadAdminAccountSessions(
      userId: userId,
      offset: previousOffset < 0 ? 0 : previousOffset,
    );
  }

  Future<bool> revokeAdminAccountSession({
    required String userId,
    required String sessionId,
  }) async {
    final target = _findAdminAccount(userId);
    if (!_canManageAdminAccount(target)) return false;
    if (adminAccountSessionsUserId != userId) {
      adminAccountActionError = currentL10n.openThisAccountsSessionListFirst;
      notifyListeners();
      return false;
    }
    final session = adminAccountSessionsPage?.sessions
        .where((item) => item.sessionId == sessionId)
        .firstOrNull;
    if (session == null || session.revokedAt != null) {
      adminAccountActionError = currentL10n.theSelectedSessionNoLongerExists;
      notifyListeners();
      return false;
    }
    if (adminAccountSessionActionBusyId != null ||
        adminAccountActionBusyId != null) {
      return false;
    }
    final client = api;
    if (client == null) {
      adminAccountActionError = currentL10n.connectToTheServerFirst;
      notifyListeners();
      return false;
    }
    final refreshAccountsOffset = adminAccountsPage?.offset ?? 0;
    final refreshSessionsOffset = adminAccountSessionsPage?.offset ?? 0;
    adminAccountSessionActionBusyId = sessionId;
    adminAccountActionError = null;
    adminAccountActionNotice = null;
    notifyListeners();
    try {
      final receipt = await client.revokeAdminAccountSession(
        userId: userId,
        sessionId: sessionId,
      );
      if (!isInstanceAdmin || isCurrentAdminAccount(userId)) return false;
      await loadAdminAccountSessions(
        userId: userId,
        offset: refreshSessionsOffset,
      );
      await loadAdminAccounts(offset: refreshAccountsOffset);
      if (!isInstanceAdmin || isCurrentAdminAccount(userId)) return false;
      adminAccountActionNotice = receipt.revoked
          ? currentL10n.selectedSessionRevoked
          : currentL10n.selectedSessionWasAlreadyRevoked;
      return true;
    } catch (error) {
      adminAccountActionError = friendlyError(error);
      return false;
    } finally {
      adminAccountSessionActionBusyId = null;
      notifyListeners();
    }
  }

  AdminAccountMetadata? _findAdminAccount(String userId) => adminAccountsPage
      ?.accounts
      .where((item) => item.userId == userId)
      .firstOrNull;

  void _markAdminAccountDeleting(String userId) {
    final page = adminAccountsPage;
    if (page != null) {
      adminAccountsPage = AdminAccountPage(
        accounts: [
          for (final account in page.accounts)
            if (account.userId == userId)
              AdminAccountMetadata(
                userId: account.userId,
                username: account.username,
                status: 'deleting',
                createdAt: account.createdAt,
                activeDeviceCount: account.activeDeviceCount,
                activeSessionCount: account.activeSessionCount,
              )
            else
              account,
        ],
        total: page.total,
        limit: page.limit,
        offset: page.offset,
      );
    }
    if (adminAccountSessionsUserId == userId) {
      _resetAdminAccountSessions();
    }
    if (adminAccountRelayPolicyUserId == userId) {
      _resetAdminAccountRelayPolicy();
    }
    notifyListeners();
  }

  bool _canManageAdminAccount(AdminAccountMetadata? target) {
    if (!isInstanceAdmin) {
      adminAccountActionError = currentL10n.theCurrentAccountDoesntHaveInstance;
    } else if (target == null) {
      adminAccountActionError = currentL10n.theTargetAccountIsNoLonger;
    } else if (isCurrentAdminAccount(target.userId)) {
      adminAccountActionError = currentL10n.theCurrentlySignedInAdminAccount;
    } else if (target.status == 'deleting') {
      adminAccountActionError = currentL10n.anAccountBeingDeletedCantPerform;
    } else {
      return true;
    }
    notifyListeners();
    return false;
  }

  void _resetInstanceAdminOverview() {
    _instanceAdminOverviewRequestGeneration++;
    instanceAdminOverview = null;
    instanceAdminOverviewLoading = false;
    instanceAdminOverviewError = null;
    _resetInstanceAdminPushHealth();
    _resetInstanceAdminMetricsCredential();
    _resetInstanceAdminRelayPolicy();
    _resetInstanceAdminBackupStatus();
    _resetInstanceAdminBackupReplication();
    _resetInstanceAdminBackupSchedule();
    _resetAdminRestoreStage();
    _adminVaultsRequestGeneration++;
    adminVaultsPage = null;
    adminVaultsLoading = false;
    adminVaultsError = null;
    adminVaultQuotaSaving = false;
    adminVaultMutationError = null;
    adminVaultMutationNotice = null;
    _resetInstanceAdminAuditState();
    _resetAdminMaintenanceJobs();
    _adminAccountsRequestGeneration++;
    adminAccountsPage = null;
    adminAccountsLoading = false;
    adminAccountsError = null;
    adminAccountActionBusyId = null;
    adminAccountActionError = null;
    adminAccountActionNotice = null;
    _resetAdminAccountInvitations();
    _resetAdminAccountSessions();
    _resetAdminAccountRelayPolicy();
    _resetAdminRelayGroups();
  }

  void _resetInstanceAdminPushHealth() {
    _instanceAdminPushHealthRequestGeneration++;
    instanceAdminPushHealth = null;
    instanceAdminPushHealthLoading = false;
    instanceAdminPushHealthError = null;
  }

  void _resetInstanceAdminMetricsCredential() {
    _instanceAdminMetricsCredentialRequestGeneration++;
    instanceAdminMetricsCredentialStatus = null;
    instanceAdminMetricsCredentialLoading = false;
    instanceAdminMetricsCredentialSaving = false;
    instanceAdminMetricsCredentialError = null;
    instanceAdminMetricsCredentialNotice = null;
    _instanceAdminMetricsCredentialOneTimeValue = null;
  }

  void _resetInstanceAdminRelayPolicy() {
    _instanceAdminRelayPolicyRequestGeneration++;
    instanceAdminRelayPolicy = null;
    instanceAdminRelayPolicyLoading = false;
    instanceAdminRelayPolicySaving = false;
    instanceAdminRelayPolicyError = null;
    instanceAdminRelayPolicySaveError = null;
    instanceAdminRelayPolicyNotice = null;
    instanceAdminRelayPolicyConflict = false;
  }

  void _resetInstanceAdminBackupStatus() {
    _instanceAdminBackupStatusRequestGeneration++;
    instanceAdminBackupStatus = null;
    instanceAdminBackupStatusLoading = false;
    instanceAdminBackupStatusError = null;
  }

  void _resetInstanceAdminBackupReplication() {
    _instanceAdminBackupReplicationRequestGeneration++;
    instanceAdminBackupReplicationStatus = null;
    instanceAdminBackupReplicationLoading = false;
    instanceAdminBackupReplicationError = null;
    _resetInstanceAdminBackupBucketAccessCheck();
  }

  void _resetInstanceAdminBackupBucketAccessCheck() {
    _instanceAdminBackupBucketAccessCheckRequestGeneration++;
    instanceAdminBackupBucketAccessCheckLoading = false;
    instanceAdminBackupBucketAccessCheckError = null;
    instanceAdminBackupBucketAccessCheckNotice = null;
  }

  void _resetInstanceAdminBackupSchedule() {
    _instanceAdminBackupScheduleRequestGeneration++;
    instanceAdminBackupSchedule = null;
    instanceAdminBackupScheduleLoading = false;
    instanceAdminBackupScheduleSaving = false;
    instanceAdminBackupScheduleError = null;
    instanceAdminBackupScheduleSaveError = null;
    instanceAdminBackupScheduleNotice = null;
  }

  int adminAccountSessionsPageOffset = 0;

  void _resetAdminAccountInvitations() {
    _adminAccountInvitationsRequestGeneration++;
    adminAccountInvitationsPage = null;
    adminAccountInvitationsLoading = false;
    adminAccountInvitationSubmitting = false;
    adminAccountInvitationsError = null;
    adminAccountInvitationActionError = null;
    adminAccountInvitationNotice = null;
    adminAccountInvitationBusyId = null;
    adminAccountInvitationToken = null;
    adminAccountInvitationTokenUsername = null;
    adminAccountInvitationTokenExpiresAt = null;
  }

  void _resetAdminAccountSessions() {
    _adminAccountSessionsRequestGeneration++;
    adminAccountSessionsUserId = null;
    adminAccountSessionsPage = null;
    adminAccountSessionsLoading = false;
    adminAccountSessionsError = null;
    adminAccountSessionsPageOffset = 0;
    adminAccountSessionActionBusyId = null;
  }

  void _resetInstanceAdminAuditState() {
    _adminAuditRequestGeneration++;
    adminAuditPage = null;
    adminAuditLoading = false;
    adminAuditError = null;
    adminAuditPageIndex = 0;
    _adminAuditPageCursors
      ..clear()
      ..add(null);
  }

  void _resetAdminMaintenanceJobs() {
    _adminMaintenanceJobsRequestGeneration++;
    adminMaintenanceJobsPage = null;
    adminMaintenanceJobsLoading = false;
    adminMaintenanceJobSubmitting = false;
    adminBackupJobSubmitting = false;
    adminMaintenanceJobsError = null;
    adminMaintenanceJobsNotice = null;
    adminBackupJobError = null;
    adminBackupJobNotice = null;
    _adminMaintenanceRetryRequestId = null;
    _adminBackupRetryRequestId = null;
    adminRestoreStageDiscardingJobId = null;
    adminRestoreStageDiscardError = null;
    adminRestoreStageDiscardNotice = null;
    _adminRestoreStageDiscardRetryJobId = null;
    _adminRestoreStageDiscardRetryRequestId = null;
  }

  Future<void> refreshAudit() => loadAudit(reset: true);

  Future<void> nextAuditPage() async {
    if (auditLoading || !auditHasMore || auditNextCursor == null) return;
    _auditPageCursors.removeRange(auditPageIndex + 1, _auditPageCursors.length);
    _auditPageCursors.add(auditNextCursor);
    auditPageIndex++;
    await loadAudit();
  }

  Future<void> previousAuditPage() async {
    if (auditLoading || !auditHasPrevious) return;
    auditPageIndex--;
    await loadAudit();
  }

  void _resetAuditState() {
    _auditRequestGeneration++;
    auditPageEvents = [];
    auditNextCursor = null;
    auditHasMore = false;
    auditLoading = false;
    auditError = null;
    auditPageIndex = 0;
    _auditPageCursors
      ..clear()
      ..add(null);
  }

  void _startSyncHints() {
    _reconcileMobilePushListeningScope();
    if (_controllerDisposed || _lockedUnlockInProgress) {
      _syncHints.stop();
      return;
    }
    final client = api;
    final info = instance;
    final auth = session;
    final currentIdentity = identity;
    final vault = activeVault;
    if (client == null ||
        info == null ||
        auth == null ||
        (currentIdentity == null && !workspaceLocked) ||
        vault == null ||
        stage != ClientStage.workspace ||
        !info.capabilities.contains('notifications')) {
      _syncHints.stop();
      return;
    }
    _syncHints.start(
      SyncHintScope(
        serverSpaceId: info.serverSpaceId,
        accountId: auth.accountId,
        deviceId: auth.deviceId,
        vaultId: vault.id,
        websocketUri: client.notificationsWebSocketUri(),
        origin: client.notificationsOrigin,
      ),
    );
  }

  void _reconcileMobilePushListeningScope() {
    final accountId = session?.accountId;
    final deviceId = session?.deviceId;
    final busyScopeIsCurrent =
        _mobilePushBusyGeneration == null ||
        (authenticated &&
            identical(api, _mobilePushBusyClient) &&
            accountId == _mobilePushBusyAccountId &&
            deviceId == _mobilePushBusyDeviceId &&
            identity?.deviceId == _mobilePushBusyDeviceId);
    final hasListeners =
        _mobilePushMessageSubscription != null ||
        _mobilePushTokenSubscription != null;
    if (!hasListeners && busyScopeIsCurrent) {
      return;
    }
    if (busyScopeIsCurrent &&
        authenticated &&
        accountId == _mobilePushListeningAccountId &&
        deviceId == _mobilePushListeningDeviceId &&
        identity?.deviceId == _mobilePushListeningDeviceId &&
        hasListeners) {
      return;
    }
    ++_mobilePushGeneration;
    mobilePushEnabled = false;
    mobilePushBusy = false;
    _mobilePushBusyGeneration = null;
    _mobilePushBusyClient = null;
    _mobilePushBusyAccountId = null;
    _mobilePushBusyDeviceId = null;
    unawaited(_cancelMobilePushListeners());
  }

  Future<void> _cancelMobilePushListeners() async {
    final tokenSubscription = _mobilePushTokenSubscription;
    final messageSubscription = _mobilePushMessageSubscription;
    _mobilePushTokenSubscription = null;
    _mobilePushMessageSubscription = null;
    _mobilePushListeningAccountId = null;
    _mobilePushListeningDeviceId = null;
    await Future.wait<void>([
      if (tokenSubscription != null) tokenSubscription.cancel(),
      if (messageSubscription != null) messageSubscription.cancel(),
    ]);
  }

  bool _mobilePushScopeIsCurrent({
    required int generation,
    required ApiClient client,
    required String accountId,
    required String deviceId,
  }) =>
      !_controllerDisposed &&
      generation == _mobilePushGeneration &&
      authenticated &&
      identical(api, client) &&
      session?.accountId == accountId &&
      session?.deviceId == deviceId &&
      identity?.deviceId == deviceId;

  Future<void> _registerMobilePushToken({
    required MobilePushToken endpoint,
    required int generation,
    required ApiClient client,
    required String accountId,
    required String deviceId,
  }) {
    if (endpoint.value.length < 16 ||
        endpoint.value.length > 4096 ||
        endpoint.value.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e) ||
        (endpoint.provider != MobilePushToken.fcmProvider &&
            endpoint.provider != MobilePushToken.apnsProvider)) {
      return Future.error(FormatException(currentL10n.invalidMobilePushToken));
    }
    final operation = _mobilePushWriteQueue.then((_) async {
      if (!_mobilePushScopeIsCurrent(
        generation: generation,
        client: client,
        accountId: accountId,
        deviceId: deviceId,
      )) {
        return;
      }
      var provider = endpoint.provider;
      try {
        await client.registerMobilePushEndpoint(
          deviceId: deviceId,
          provider: provider,
          token: endpoint.value,
        );
      } on ApiException catch (error) {
        if (provider != MobilePushToken.apnsProvider ||
            error.code != 'PUSH_DELIVERY_DISABLED') {
          rethrow;
        }
        final fallback = await _mobilePushRegistration.getFcmFallbackToken();
        if (!_mobilePushScopeIsCurrent(
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        )) {
          return;
        }
        if (fallback == null) rethrow;
        provider = MobilePushToken.fcmProvider;
        await client.registerMobilePushEndpoint(
          deviceId: deviceId,
          provider: provider,
          token: fallback,
        );
      }
      if (!_mobilePushScopeIsCurrent(
        generation: generation,
        client: client,
        accountId: accountId,
        deviceId: deviceId,
      )) {
        return;
      }
      for (final previousProvider in const [
        MobilePushToken.apnsProvider,
        MobilePushToken.fcmProvider,
      ]) {
        if (previousProvider == provider) continue;
        if (!_mobilePushScopeIsCurrent(
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        )) {
          return;
        }
        try {
          await client.removeMobilePushEndpoint(
            deviceId: deviceId,
            provider: previousProvider,
          );
        } catch (_) {
          if (!_mobilePushScopeIsCurrent(
            generation: generation,
            client: client,
            accountId: accountId,
            deviceId: deviceId,
          )) {
            return;
          }
          try {
            await client.removeMobilePushEndpoint(
              deviceId: deviceId,
              provider: provider,
            );
          } catch (_) {}
          rethrow;
        }
      }
    });
    _mobilePushWriteQueue = operation.catchError((Object _) {});
    return operation;
  }

  Future<MobilePushAuthorizationStatus>
  _readMobilePushAuthorizationStatus() async {
    try {
      return await _mobilePushRegistration.notificationAuthorizationStatus();
    } catch (_) {
      return MobilePushAuthorizationStatus.unknown;
    }
  }

  Future<void> _handleMobilePushTokenRefresh({
    required MobilePushToken endpoint,
    required int generation,
    required ApiClient client,
    required String accountId,
    required String deviceId,
  }) async {
    if (!mobilePushEnabled ||
        !_mobilePushScopeIsCurrent(
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        )) {
      return;
    }
    final authorization = await _readMobilePushAuthorizationStatus();
    if (!mobilePushEnabled ||
        !_mobilePushScopeIsCurrent(
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        )) {
      return;
    }
    if (authorization == MobilePushAuthorizationStatus.denied) {
      await _disableMobilePushForDeniedAuthorization(
        generation: generation,
        client: client,
        accountId: accountId,
        deviceId: deviceId,
      );
      return;
    }
    if (authorization != MobilePushAuthorizationStatus.authorized) return;
    await _registerMobilePushToken(
      endpoint: endpoint,
      generation: generation,
      client: client,
      accountId: accountId,
      deviceId: deviceId,
    );
  }

  Future<void> _listenForMobilePushTokenRefreshes({
    required int generation,
    required ApiClient client,
    required String accountId,
    required String deviceId,
  }) async {
    await _cancelMobilePushListeners();
    if (!_mobilePushScopeIsCurrent(
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        ) ||
        !mobilePushEnabled) {
      return;
    }
    final refreshes = await _mobilePushRegistration.tokenRefreshes();
    final messages = await _mobilePushRegistration.incomingMessages();
    if (!_mobilePushScopeIsCurrent(
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        ) ||
        !mobilePushEnabled) {
      return;
    }
    _mobilePushListeningAccountId = accountId;
    _mobilePushListeningDeviceId = deviceId;
    _mobilePushTokenSubscription = refreshes.listen(
      (endpoint) => unawaited(
        _handleMobilePushTokenRefresh(
          endpoint: endpoint,
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        ).catchError((Object _) {}),
      ),
      onError: (Object _, StackTrace _) {},
    );
    _mobilePushMessageSubscription = messages.listen(
      (data) => _onMobilePushMessage(
        data: data,
        generation: generation,
        client: client,
        accountId: accountId,
        deviceId: deviceId,
      ),
      onError: (Object _, StackTrace _) {},
    );
  }

  void _onMobilePushMessage({
    required Map<String, dynamic> data,
    required int generation,
    required ApiClient client,
    required String accountId,
    required String deviceId,
  }) {
    if (_controllerDisposed) return;
    if (data.length != 1 || data['type'] != 'sync_available') return;
    // A prior subscription may still deliver while a newer opt-in attempt is
    // awaiting permission/token/API work. Its callback must not invalidate the
    // newer generation or cancel listeners that belong to the new lifecycle.
    if (generation != _mobilePushGeneration) return;
    if (!mobilePushEnabled ||
        !_mobilePushScopeIsCurrent(
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        )) {
      mobilePushEnabled = false;
      ++_mobilePushGeneration;
      mobilePushBusy = false;
      _mobilePushBusyGeneration = null;
      _mobilePushBusyClient = null;
      _mobilePushBusyAccountId = null;
      _mobilePushBusyDeviceId = null;
      unawaited(_cancelMobilePushListeners());
      if (!_controllerDisposed) notifyListeners();
      return;
    }
    // AutoSyncCoordinator coalesces concurrent hints into at most one extra
    // authoritative pull after the active sync finishes. No payload fields or
    // message IDs are retained beyond this exact check.
    unawaited(
      _handleSyncHint(SyncHint(vaultId: activeVault?.id))
          .catchError((Object _) {}),
    );
  }

  Future<void> _restoreMobilePushRegistration() async {
    final client = api;
    final auth = session;
    final currentIdentity = identity;
    if (!mobilePushSupported ||
        client == null ||
        auth == null ||
        currentIdentity == null ||
        currentIdentity.deviceId != auth.deviceId ||
        !authenticated ||
        mobilePushBusy ||
        _controllerDisposed) {
      return;
    }
    final hasCurrentListeners =
        (_mobilePushMessageSubscription != null ||
            _mobilePushTokenSubscription != null) &&
        _mobilePushListeningAccountId == auth.accountId &&
        _mobilePushListeningDeviceId == auth.deviceId &&
        currentIdentity.deviceId == auth.deviceId;
    final hasListeners =
        _mobilePushMessageSubscription != null ||
        _mobilePushTokenSubscription != null;
    var generation = hasCurrentListeners
        ? _mobilePushGeneration
        : ++_mobilePushGeneration;
    if (hasListeners && !hasCurrentListeners) {
      unawaited(_cancelMobilePushListeners());
    }
    final accountId = auth.accountId;
    final deviceId = auth.deviceId;
    bool wasEnabled;
    bool cleanupPending;
    try {
      wasEnabled = await secureStore.mobilePushEnabled(
        baseUrl: client.baseUrl,
        accountId: accountId,
        deviceId: deviceId,
      );
      cleanupPending = await secureStore.mobilePushCleanupPending(
        baseUrl: client.baseUrl,
        accountId: accountId,
        deviceId: deviceId,
      );
    } catch (_) {
      return;
    }
    if (!_mobilePushScopeIsCurrent(
      generation: generation,
      client: client,
      accountId: accountId,
      deviceId: deviceId,
    )) {
      return;
    }
    if (cleanupPending) {
      if (hasCurrentListeners) generation = ++_mobilePushGeneration;
      mobilePushEnabled = false;
      mobilePushBusy = true;
      _mobilePushBusyGeneration = generation;
      _mobilePushBusyClient = client;
      _mobilePushBusyAccountId = accountId;
      _mobilePushBusyDeviceId = deviceId;
      notifyListeners();
      try {
        await _cancelMobilePushListeners();
        var disabledPersisted = false;
        try {
          await secureStore.setMobilePushEnabled(
            baseUrl: client.baseUrl,
            accountId: accountId,
            deviceId: deviceId,
            enabled: false,
          );
          disabledPersisted = true;
        } catch (_) {}
        await _mobilePushWriteQueue.catchError((Object _) {});
        if (!_mobilePushScopeIsCurrent(
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        )) {
          return;
        }
        final removed = await _removeAllMobilePushEndpoints(
          client,
          deviceId,
          canContinue: () => _mobilePushScopeIsCurrent(
            generation: generation,
            client: client,
            accountId: accountId,
            deviceId: deviceId,
          ),
        );
        if (removed &&
            disabledPersisted &&
            _mobilePushScopeIsCurrent(
              generation: generation,
              client: client,
              accountId: accountId,
              deviceId: deviceId,
            )) {
          try {
            await secureStore.setMobilePushCleanupPending(
              baseUrl: client.baseUrl,
              accountId: accountId,
              deviceId: deviceId,
              pending: false,
            );
          } catch (_) {}
        }
      } finally {
        _finishMobilePushBusy(generation);
      }
      return;
    }
    mobilePushEnabled = wasEnabled;
    if (!wasEnabled) {
      mobilePushEnabled = false;
      if (hasCurrentListeners) {
        ++_mobilePushGeneration;
        await _cancelMobilePushListeners();
      }
      notifyListeners();
      return;
    }
    if (!mobilePushConfigured) {
      notifyListeners();
      return;
    }
    notifyListeners();
    final authorization = await _readMobilePushAuthorizationStatus();
    if (!_mobilePushScopeIsCurrent(
      generation: generation,
      client: client,
      accountId: accountId,
      deviceId: deviceId,
    )) {
      return;
    }
    if (authorization == MobilePushAuthorizationStatus.denied) {
      await _disableMobilePushForDeniedAuthorization(
        generation: generation,
        client: client,
        accountId: accountId,
        deviceId: deviceId,
      );
      return;
    }
    if (authorization != MobilePushAuthorizationStatus.authorized) return;
    try {
      await _listenForMobilePushTokenRefreshes(
        generation: generation,
        client: client,
        accountId: accountId,
        deviceId: deviceId,
      );
      final endpoint = await _mobilePushRegistration.getTokenIfAuthorized();
      if (endpoint != null &&
          _mobilePushScopeIsCurrent(
            generation: generation,
            client: client,
            accountId: accountId,
            deviceId: deviceId,
          )) {
        await _registerMobilePushToken(
          endpoint: endpoint,
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        );
      } else if (endpoint == null &&
          _mobilePushScopeIsCurrent(
            generation: generation,
            client: client,
            accountId: accountId,
            deviceId: deviceId,
          )) {
        final refreshedAuthorization =
            await _readMobilePushAuthorizationStatus();
        if (refreshedAuthorization == MobilePushAuthorizationStatus.denied) {
          await _disableMobilePushForDeniedAuthorization(
            generation: generation,
            client: client,
            accountId: accountId,
            deviceId: deviceId,
          );
        }
      }
    } catch (_) {
      // FCM is a best-effort wake-up path. WebSocket and polling remain the
      // synchronization sources and are not affected by native FCM failures.
    }
  }

  Future<void> setMobilePushEnabled(bool enabled) async {
    if (!authenticated || api == null || session == null || identity == null) {
      throw StateError(currentL10n.signInBeforeManagingThisDevices);
    }
    if (!mobilePushSupported) {
      throw StateError(currentL10n.mobilePushIsntSupportedOnThis);
    }
    if (mobilePushBusy) return;
    final client = api!;
    final auth = session!;
    final currentIdentity = identity!;
    if (currentIdentity.deviceId != auth.deviceId) {
      throw StateError(currentL10n.theCurrentDeviceIdentityDoesntMatch);
    }
    final accountId = auth.accountId;
    final deviceId = auth.deviceId;
    final generation = ++_mobilePushGeneration;
    mobilePushBusy = true;
    _mobilePushBusyGeneration = generation;
    _mobilePushBusyClient = client;
    _mobilePushBusyAccountId = accountId;
    _mobilePushBusyDeviceId = deviceId;
    notifyListeners();
    try {
      if (enabled) {
        if (!mobilePushConfigured) {
          throw StateError(currentL10n.thisAppBuildDoesntHaveFirebase);
        }
        final endpoint = await _mobilePushRegistration
            .requestPermissionAndGetToken();
        if (endpoint == null) {
          throw StateError(
            currentL10n.notificationPermissionWasntGrantedBackgroundSync,
          );
        }
        if (!_mobilePushScopeIsCurrent(
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        )) {
          throw StateError(currentL10n.theSignInStateChangedTry);
        }
        await _registerMobilePushToken(
          endpoint: endpoint,
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        );
        if (!_mobilePushScopeIsCurrent(
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        )) {
          throw StateError(currentL10n.theSignInStateChangedTry);
        }
        await secureStore.setMobilePushEnabled(
          baseUrl: client.baseUrl,
          accountId: accountId,
          deviceId: deviceId,
          enabled: true,
        );
        await secureStore.setMobilePushCleanupPending(
          baseUrl: client.baseUrl,
          accountId: accountId,
          deviceId: deviceId,
          pending: false,
        );
        if (!_mobilePushScopeIsCurrent(
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        )) {
          throw StateError(currentL10n.theSignInStateChangedTry);
        }
        mobilePushEnabled = true;
        await _listenForMobilePushTokenRefreshes(
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        );
        if (_mobilePushScopeIsCurrent(
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        )) {
          _setNotice(currentL10n.backgroundSyncNotificationsAreOnFor);
        }
      } else {
        await _performMobilePushOptOut(
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        );
        if (_mobilePushScopeIsCurrent(
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        )) {
          _setNotice(currentL10n.backgroundSyncNotificationsAreTurnedOff);
        }
      }
    } catch (error) {
      final isCurrent = _mobilePushScopeIsCurrent(
        generation: generation,
        client: client,
        accountId: accountId,
        deviceId: deviceId,
      );
      if (!isCurrent) return;
      if (enabled && isCurrent) {
        mobilePushEnabled = false;
        try {
          await _performMobilePushOptOut(
            generation: generation,
            client: client,
            accountId: accountId,
            deviceId: deviceId,
          );
        } catch (_) {}
      }
      if (error is ApiException ||
          error is StateError ||
          error is FormatException) {
        rethrow;
      }
      throw StateError(
        enabled
            ? currentL10n.couldNotEnableBackgroundSyncNotifications
            : currentL10n.couldNotDisableBackgroundSyncNotifications,
      );
    } finally {
      _finishMobilePushBusy(generation);
    }
  }

  void _finishMobilePushBusy(int generation) {
    if (_mobilePushBusyGeneration != generation) return;
    _mobilePushBusyGeneration = null;
    _mobilePushBusyClient = null;
    _mobilePushBusyAccountId = null;
    _mobilePushBusyDeviceId = null;
    mobilePushBusy = false;
    if (!_controllerDisposed) notifyListeners();
  }

  Future<void> _disableMobilePushForDeniedAuthorization({
    required int generation,
    required ApiClient client,
    required String accountId,
    required String deviceId,
  }) async {
    if (!mobilePushEnabled ||
        !_mobilePushScopeIsCurrent(
          generation: generation,
          client: client,
          accountId: accountId,
          deviceId: deviceId,
        )) {
      return;
    }
    final cleanupGeneration = ++_mobilePushGeneration;
    mobilePushEnabled = false;
    mobilePushBusy = true;
    _mobilePushBusyGeneration = cleanupGeneration;
    _mobilePushBusyClient = client;
    _mobilePushBusyAccountId = accountId;
    _mobilePushBusyDeviceId = deviceId;
    notifyListeners();
    try {
      await _performMobilePushOptOut(
        generation: cleanupGeneration,
        client: client,
        accountId: accountId,
        deviceId: deviceId,
      );
    } catch (_) {
      // Keep the durable cleanup marker so a later authenticated resume can
      // retry both provider removals without reopening the permission prompt.
    } finally {
      _finishMobilePushBusy(cleanupGeneration);
    }
  }

  Future<void> _performMobilePushOptOut({
    required int generation,
    required ApiClient client,
    required String accountId,
    required String deviceId,
  }) async {
    mobilePushEnabled = false;
    await _cancelMobilePushListeners();
    Object? storageError;
    var cleanupPendingPersisted = false;
    var disabledPersisted = false;
    try {
      await secureStore.setMobilePushCleanupPending(
        baseUrl: client.baseUrl,
        accountId: accountId,
        deviceId: deviceId,
        pending: true,
      );
      cleanupPendingPersisted = true;
    } catch (error) {
      storageError = error;
    }
    try {
      await secureStore.setMobilePushEnabled(
        baseUrl: client.baseUrl,
        accountId: accountId,
        deviceId: deviceId,
        enabled: false,
      );
      disabledPersisted = true;
    } catch (error) {
      storageError ??= error;
    }
    await _mobilePushWriteQueue.catchError((Object _) {});
    if (!_mobilePushScopeIsCurrent(
      generation: generation,
      client: client,
      accountId: accountId,
      deviceId: deviceId,
    )) {
      return;
    }
    final removed = await _removeAllMobilePushEndpoints(
      client,
      deviceId,
      canContinue: () => _mobilePushScopeIsCurrent(
        generation: generation,
        client: client,
        accountId: accountId,
        deviceId: deviceId,
      ),
    );
    if (!_mobilePushScopeIsCurrent(
      generation: generation,
      client: client,
      accountId: accountId,
      deviceId: deviceId,
    )) {
      return;
    }
    if (removed && cleanupPendingPersisted && disabledPersisted) {
      try {
        await secureStore.setMobilePushCleanupPending(
          baseUrl: client.baseUrl,
          accountId: accountId,
          deviceId: deviceId,
          pending: false,
        );
      } catch (error) {
        storageError ??= error;
      }
    }
    if (!removed) {
      throw StateError(currentL10n.couldNotRemoveThisDevicesPush);
    }
    if (storageError != null) {
      throw StateError(currentL10n.couldNotPersistTheMobilePush);
    }
  }

  Future<void> _stopMobilePushForSession({
    required ApiClient client,
    required AuthSession auth,
    bool removeServerEndpoint = true,
    bool clearPreference = true,
  }) async {
    bool authScopeIsCurrent() =>
        !_controllerDisposed &&
        identical(api, client) &&
        identical(session, auth) &&
        session?.accountId == auth.accountId &&
        session?.deviceId == auth.deviceId &&
        identity?.deviceId == auth.deviceId;
    if (!authScopeIsCurrent()) return;
    final generation = ++_mobilePushGeneration;
    mobilePushEnabled = false;
    mobilePushBusy = false;
    _mobilePushBusyGeneration = null;
    _mobilePushBusyClient = null;
    _mobilePushBusyAccountId = null;
    _mobilePushBusyDeviceId = null;
    await _cancelMobilePushListeners();
    await _mobilePushWriteQueue.catchError((Object _) {});
    var cleanupPendingPersisted = false;
    var disabledPersisted = false;
    if (clearPreference && identity?.deviceId == auth.deviceId) {
      try {
        await secureStore.setMobilePushCleanupPending(
          baseUrl: client.baseUrl,
          accountId: auth.accountId,
          deviceId: auth.deviceId,
          pending: true,
        );
        cleanupPendingPersisted = true;
      } catch (_) {}
      try {
        await secureStore.setMobilePushEnabled(
          baseUrl: client.baseUrl,
          accountId: auth.accountId,
          deviceId: auth.deviceId,
          enabled: false,
        );
        disabledPersisted = true;
      } catch (_) {}
    }
    bool sessionIsCurrent() =>
        generation == _mobilePushGeneration && authScopeIsCurrent();
    if (removeServerEndpoint && sessionIsCurrent()) {
      final removed = await _removeAllMobilePushEndpoints(
        client,
        auth.deviceId,
        canContinue: sessionIsCurrent,
      );
      if (removed &&
          cleanupPendingPersisted &&
          disabledPersisted &&
          sessionIsCurrent()) {
        try {
          await secureStore.setMobilePushCleanupPending(
            baseUrl: client.baseUrl,
            accountId: auth.accountId,
            deviceId: auth.deviceId,
            pending: false,
          );
        } catch (_) {}
      }
    }
  }

  Future<bool> _removeAllMobilePushEndpoints(
    ApiClient client,
    String deviceId, {
    required bool Function() canContinue,
  }) async {
    var succeeded = true;
    for (final provider in const [
      MobilePushToken.apnsProvider,
      MobilePushToken.fcmProvider,
    ]) {
      if (!canContinue()) return false;
      try {
        await client.removeMobilePushEndpoint(
          deviceId: deviceId,
          provider: provider,
        );
      } catch (_) {
        succeeded = false;
        // Best effort: try to remove the other provider even if one request
        // fails, and never block local opt-out/session cleanup.
      }
    }
    return succeeded && canContinue();
  }

  Future<void> _handleSyncHint(SyncHint hint) async {
    if (!authenticated || stage != ClientStage.workspace) return;
    if (workspaceLocked) {
      if (hint.membershipChanged) {
        syncStatus = 'unlock_required';
        errorMessage = currentL10n.vaultMembershipChangedUnlockToVerify;
        _automaticSync.stop();
        notifyListeners();
        return;
      }
      await _automaticSync.hintReceived();
      return;
    }
    await _waitForVaultInvitationAcceptance();
    if (!authenticated || stage != ClientStage.workspace) return;
    // A membership rotation owns the control-plane transition from its
    // pre-change sync through the verified post-change reload. Preserve any
    // hints that arrive in that window and replay one after the new chain is
    // installed; a parallel reload can combine an old Vault descriptor with
    // a membership chain committed by the rotation.
    if (vaultMembershipBusy || _vaultMembershipChangeActive) {
      final pending = _deferredSyncHintDuringMembershipChange;
      _deferredSyncHintDuringMembershipChange = pending == null
          ? hint
          : _mergeDeferredSyncHints(pending, hint);
      return;
    }
    if (hint.membershipChanged) {
      await _reloadVaultsForMembershipHint();
      if (!authenticated || stage != ClientStage.workspace) return;
      _startSyncHints();
      _startVaultPresenceHeartbeats();
    }
    // A handler may already be refreshing membership when invitation
    // acceptance starts. Do not let its old Vault-scoped hint launch a sync
    // between selecting the accepted Vault and its first pull.
    await _waitForVaultInvitationAcceptance();
    if (!authenticated || stage != ClientStage.workspace) return;
    await _automaticSync.hintReceived();
  }

  SyncHint _mergeDeferredSyncHints(SyncHint previous, SyncHint incoming) {
    final membershipChanged =
        previous.membershipChanged || incoming.membershipChanged;
    return SyncHint(
      // A global membership invalidation must survive later scoped sync hints.
      // Null is also the server's wire shape for membership-set changes.
      vaultId:
          membershipChanged ||
              previous.vaultId == null ||
              incoming.vaultId == null
          ? null
          : incoming.vaultId,
      membershipChanged: membershipChanged,
    );
  }

  Future<void> _replayDeferredSyncHint(SyncHint hint) async {
    try {
      await _handleSyncHint(hint);
    } catch (error) {
      _traceSafeTeamLifecycle('rotation.hint_replay.error', error);
      if (!authenticated || stage != ClientStage.workspace) return;
      syncStatus = error is ApiException
          ? error.code.toLowerCase()
          : 'retry_wait';
      errorMessage = friendlyError(error);
      notifyListeners();
    }
  }

  Future<void> _waitForVaultInvitationAcceptance() async {
    while (true) {
      final acceptance = _vaultInvitationAcceptanceCompletion;
      if (acceptance == null) return;
      await acceptance.future;
    }
  }

  @visibleForTesting
  Future<void> reloadVaultsForTesting() => _reloadVaultsForMembershipHint();

  @visibleForTesting
  Future<void> loadVaultsForTesting() {
    final auth = session;
    if (auth == null) {
      return Future<void>.error(StateError(currentL10n.noAuthenticatedSession));
    }
    return _loadVaults(auth);
  }

  @visibleForTesting
  Future<void> activateConfiguredServerForTesting(
    ApiClient candidate,
    InstanceInfo candidateInfo,
  ) => _activateConfiguredServer(candidate, candidateInfo);

  @visibleForTesting
  Future<void> handleSyncHintForTesting(SyncHint hint) => _handleSyncHint(hint);

  @visibleForTesting
  Future<void> restoreMobilePushRegistrationForTesting() =>
      _restoreMobilePushRegistration();

  @visibleForTesting
  bool get membershipRefreshActiveForTesting => _membershipRefreshActive;

  @visibleForTesting
  Uint8List? vaultKeyForTesting(String vaultId) => _vaultKeys[vaultId];

  @visibleForTesting
  Future<void>? get deferredSyncHintReplayForTesting =>
      _deferredSyncHintReplayFuture;

  Future<void> _reloadVaultsForMembershipHint() async {
    if (_controllerDisposed) return;
    // Member rotation performs its own direct reload after commit. A wrapper
    // refresh during the operation could read one side of the signed control
    // plane before commit and the other side after commit.
    if (vaultMembershipBusy || _vaultMembershipChangeActive) return;
    final pending = _membershipRefreshFuture;
    if (pending != null) return pending;
    final reload = _reloadVaultsForMembershipHintInternal();
    _membershipRefreshFuture = reload;
    _membershipRefreshActive = true;
    _knownHostDecisionGeneration++;
    notifyListeners();
    try {
      await reload;
    } finally {
      if (identical(_membershipRefreshFuture, reload)) {
        _membershipRefreshFuture = null;
      }
      _membershipRefreshActive = false;
      _syncAgainRequested = false;
      if (!_controllerDisposed) notifyListeners();
    }
  }

  Future<void> _reloadVaultsForMembershipHintInternal() async {
    _traceSafeTeamLifecycle('reload.wait.start');
    await _waitForSyncAndRecovery();
    _traceSafeTeamLifecycle('reload.wait.done');
    await _waitForArchiveOperations();
    final auth = session;
    if (auth == null) return;
    final previousIdentity = identity;
    final previousApi = api;
    final previousBase = api?.baseUrl;
    final previousUsername = _authenticatedUsername;
    final previousAuthContextGeneration = _authContextGeneration;
    final expectedLoadGeneration = _vaultLoadGeneration + 1;
    bool loadScopeIsCurrent() =>
        !_controllerDisposed &&
        _vaultLoadGeneration == expectedLoadGeneration &&
        _authContextGeneration == previousAuthContextGeneration &&
        session?.accountId == auth.accountId &&
        session?.deviceId == auth.deviceId &&
        identical(identity, previousIdentity) &&
        identical(api, previousApi);
    final previousActive = activeVault;
    final previousVaultKeys = Map<String, Uint8List>.from(_vaultKeys);
    final previousEpochKeys = <String, Map<String, Uint8List>>{
      for (final entry in _vaultEpochKeys.entries)
        entry.key: Map<String, Uint8List>.from(entry.value),
    };
    try {
      _traceSafeTeamLifecycle('reload.load.start');
      await _loadVaults(auth);
      _traceSafeTeamLifecycle('reload.load.done');
      if (!loadScopeIsCurrent()) return;
    } on _VaultLoadSuperseded {
      _traceSafeTeamLifecycle('reload.load.superseded');
      return;
    } on ApiException {
      _traceSafeTeamLifecycle('reload.load.api_error');
      if (!loadScopeIsCurrent()) return;
      rethrow;
    } on ApiTransportException {
      _traceSafeTeamLifecycle('reload.load.transport_error');
      if (!loadScopeIsCurrent()) return;
      rethrow;
    } on SyncReadTransportUnavailableException {
      _traceSafeTeamLifecycle('reload.load.offline_error');
      if (!loadScopeIsCurrent()) return;
      rethrow;
    } on TimeoutException {
      _traceSafeTeamLifecycle('reload.load.timeout');
      if (!loadScopeIsCurrent()) return;
      rethrow;
    } catch (error) {
      _traceSafeTeamLifecycle('reload.load.trust_error', error);
      if (!loadScopeIsCurrent()) return;
      // A malformed membership chain or no remaining accessible Vault is a
      // trust-boundary failure. Lock this client instead of continuing with
      // stale permissions or stale decryption keys.
      final cleared = await _clearLocalAuthenticatedState(
        expectedSession: auth,
        expectedApi: previousApi,
        expectedBase: previousBase,
        expectedUsername: previousUsername,
      );
      if (!cleared) return;
      rethrow;
    }

    final loadedIds = _vaultDescriptors.map((item) => item.id).toSet();
    if (previousActive != null && loadedIds.contains(previousActive.id)) {
      activeVault = _vaultDescriptors.firstWhere(
        (item) => item.id == previousActive.id,
      );
    }
    _knownNames.removeWhere((vaultId, _) => !loadedIds.contains(vaultId));

    _traceSafeTeamLifecycle('reload.repository.start');
    await _buildRepository();
    _traceSafeTeamLifecycle('reload.repository.done');
    final recoveryRefresh = _recoverySyncFuture;
    if (recoveryRefresh != null) {
      _traceSafeTeamLifecycle('reload.recovery.start');
      await recoveryRefresh;
      _traceSafeTeamLifecycle('reload.recovery.done');
    }
    final heldBuffers = <Uint8List>{
      ..._vaultKeys.values,
      for (final versions in _vaultEpochKeys.values) ...versions.values,
    };
    final oldBuffers = <Uint8List>{
      ...previousVaultKeys.values,
      for (final versions in previousEpochKeys.values) ...versions.values,
    };
    for (final key in oldBuffers) {
      if (!heldBuffers.contains(key)) key.fillRange(0, key.length, 0);
    }
    _repository?.authorizeStaleOutboxRewrapAfterMembershipRefresh();
    final stagedWorkspaceIdBeforeRefresh = activeSavedWorkspaceId;
    final stagedWorkspaceSelectionGeneration =
        _stagedWorkspaceSelectionGeneration;
    final stagedPaneTabIdsBeforeRefresh = stagedWorkspaceIdBeforeRefresh == null
        ? const <String, String>{}
        : Map<String, String>.of(
            _workspacePaneTerminalTabIds[stagedWorkspaceIdBeforeRefresh] ??
                const <String, String>{},
          );
    _clearVaultWorkspaceProjection(preserveSyncStatus: true);
    if (activeVault != null) {
      _traceSafeTeamLifecycle('reload.records.start');
      await reloadRecords();
      _traceSafeTeamLifecycle('reload.records.done');
      _restoreStagedWorkspaceAfterMembershipRefresh(
        workspaceId: stagedWorkspaceIdBeforeRefresh,
        paneTabIds: stagedPaneTabIdsBeforeRefresh,
        selectionGeneration: stagedWorkspaceSelectionGeneration,
        previousVaultId: previousActive?.id,
      );
      _traceSafeTeamLifecycle('reload.status.start');
      await refreshSyncStatus(keepStatus: syncStatus == 'syncing');
      _traceSafeTeamLifecycle('reload.status.done');
    }
    _resetAuditState();
    if (page == WorkspacePage.audit) await loadAudit();
    if (page == WorkspacePage.devices && activeVault != null) {
      // Membership reload replaces the active Vault projection and clears
      // its device roster. Keep the Devices page's Vault-scoped readiness
      // view current after the replacement has finished.
      await refreshVaultDeviceRows(background: true);
    }
  }

  void _restoreStagedWorkspaceAfterMembershipRefresh({
    required String? workspaceId,
    required Map<String, String> paneTabIds,
    required int selectionGeneration,
    required String? previousVaultId,
  }) {
    if (workspaceId == null ||
        previousVaultId == null ||
        activeVault?.id != previousVaultId ||
        _stagedWorkspaceSelectionGeneration != selectionGeneration ||
        (activeSavedWorkspaceId != null &&
            activeSavedWorkspaceId != workspaceId)) {
      return;
    }
    final workspace = savedWorkspaces
        .where((item) => item.id == workspaceId)
        .firstOrNull;
    if (workspace == null) return;

    // Membership refresh replaces the encrypted Vault projection, but it
    // does not close already-authenticated SSH tabs. Rebind only the exact
    // pane IDs and still-open tab IDs from that in-memory runtime mapping;
    // never infer a replacement by Host label or endpoint.
    final paneHostIds = {
      for (final pane in workspace.panes) pane.paneId: pane.hostId,
    };
    final currentBindings =
        _workspacePaneTerminalTabIds[workspaceId] ?? const <String, String>{};
    final candidateBindings = <String, String>{
      ...paneTabIds,
      ...currentBindings,
    };
    final validBindings = <String, String>{};
    for (final entry in candidateBindings.entries) {
      if (paneHostIds[entry.key] == null) continue;
      final tab = _terminalTabs[entry.value];
      if (tab == null || tab.closed || tab.host?.id != paneHostIds[entry.key]) {
        continue;
      }
      validBindings[entry.key] = entry.value;
    }
    activeSavedWorkspaceId = workspaceId;
    if (validBindings.isEmpty) {
      _workspacePaneTerminalTabIds.remove(workspaceId);
    } else {
      _workspacePaneTerminalTabIds[workspaceId] = validBindings;
    }
  }

  Future<void> _waitForSyncAndRecovery() async {
    while (true) {
      final recovery = _snapshotRecoveryFuture;
      if (recovery != null) {
        await recovery;
        continue;
      }
      if (syncing) {
        final currentSync = _activeSyncCompletion?.future;
        if (currentSync != null) {
          await currentSync;
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        continue;
      }
      // A Vault switch releases the controller's selected-sync gate before
      // the old repository's network operation necessarily finishes. Key
      // replacement and account cleanup must also wait for those retired
      // operations, which still hold references to the source key buffers.
      await _waitForRetiredRepositoryDrains();
      if (!syncing && _retiredRepositoryDrains.isEmpty) return;
    }
  }

  void _beginArchiveOperation() {
    archiveBusy = true;
    _archiveOperationDrained = Completer<void>();
  }

  void _endArchiveOperation() {
    archiveBusy = false;
    final drained = _archiveOperationDrained;
    _archiveOperationDrained = null;
    if (drained != null && !drained.isCompleted) drained.complete();
  }

  Future<void> _waitForArchiveOperations() async {
    while (archiveBusy) {
      final pendingArchive = _archiveOperationDrained?.future;
      if (pendingArchive != null) {
        await pendingArchive;
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
  }

  Future<SessionSnapshotRead> _readSharedSessionCredentials() {
    final base = api?.baseUrl;
    final username = _authenticatedUsername;
    final current = session;
    if (base == null || username == null || current == null) {
      return Future<SessionSnapshotRead>.value(
        const SessionSnapshotRead.missing(),
      );
    }
    return secureStore.readSessionSnapshot(base, username, current.deviceId);
  }

  SessionScope? _currentSessionScope() {
    final base = api?.baseUrl;
    final current = session;
    if (base == null || current == null) return null;
    return SessionScope(
      serverNamespace: secureStorageNamespace(base),
      accountId: current.accountId,
      deviceId: current.deviceId,
    );
  }

  void _signalSessionUpdate(
    String baseUrl,
    SessionCredentials credentials,
    SessionUpdateKind kind,
  ) {
    _sessionUpdateNotifier.signal(
      SessionUpdateEvent(
        scope: SessionScope(
          serverNamespace: secureStorageNamespace(baseUrl),
          accountId: credentials.accountId,
          deviceId: credentials.deviceId,
        ),
        kind: kind,
      ),
    );
  }

  void _handleRemoteSessionEnd({
    required bool removed,
    required SessionCredentials expectedCredentials,
  }) {
    final current = session;
    final client = api;
    final base = client?.baseUrl;
    final username = _authenticatedUsername;
    if (current == null ||
        client == null ||
        base == null ||
        username == null ||
        current.accountId != expectedCredentials.accountId ||
        current.deviceId != expectedCredentials.deviceId ||
        current.accessToken != expectedCredentials.accessToken ||
        current.refreshToken != expectedCredentials.refreshToken) {
      return;
    }
    unawaited(() async {
      final cleared = await _clearLocalAuthenticatedState(
        signalRemoved: false,
        expectedSession: current,
        expectedApi: client,
        expectedBase: base,
        expectedUsername: username,
      );
      if (!cleared) return;
      noticeMessage = removed
          ? currentL10n.thisSessionWasSignedOutIn
          : currentL10n.thisSessionsRefreshTokenStateCant;
      notifyListeners();
    }());
  }

  SessionCredentials _sessionCredentialsFor(AuthSession auth) =>
      SessionCredentials(
        accountId: auth.accountId,
        deviceId: auth.deviceId,
        accessToken: auth.accessToken,
        refreshToken: auth.refreshToken,
        accessExpiresAt:
            session?.deviceId == auth.deviceId &&
                session?.refreshToken == auth.refreshToken &&
                session?.accessToken == auth.accessToken
            ? _sessionAccessExpiresAt ??
                  DateTime.now().toUtc().add(Duration(seconds: auth.expiresIn))
            : DateTime.now().toUtc().add(Duration(seconds: auth.expiresIn)),
      );

  AuthSession _authSessionWithCredentials(
    AuthSession existing,
    SessionCredentials credentials,
  ) {
    final remaining = credentials.accessExpiresAt
        .difference(DateTime.now().toUtc())
        .inSeconds
        .clamp(0, 86400)
        .toInt();
    return AuthSession(
      accountId: credentials.accountId,
      accessToken: credentials.accessToken,
      expiresIn: remaining,
      refreshToken: credentials.refreshToken,
      deviceId: credentials.deviceId,
      vaults: existing.vaults,
    );
  }

  void _applySharedSessionCredentials(SessionCredentials credentials) {
    final existing = session;
    final client = api;
    if (existing == null ||
        client == null ||
        existing.accountId != credentials.accountId ||
        existing.deviceId != credentials.deviceId) {
      return;
    }
    session = _authSessionWithCredentials(existing, credentials);
    client.accessToken = credentials.accessToken;
    _sessionAccessExpiresAt = credentials.accessExpiresAt;
    _sessionCredentialsAdoptedAt = DateTime.now().toUtc();
    notifyListeners();
  }

  Future<void> _saveSessionCredentials(
    String baseUrl,
    String username,
    AuthSession auth,
  ) async {
    final credentials = _sessionCredentialsFor(auth);
    try {
      await _sessionRefreshLock.run(
        () =>
            secureStore.saveSessionCredentials(baseUrl, username, credentials),
      );
    } on SessionCoordinationUnavailableException {
      // Login can still proceed in older browsers. Refresh itself remains
      // fail-closed there, because it cannot safely consume a single-use token.
      await secureStore.saveSessionCredentials(baseUrl, username, credentials);
    }
  }

  @visibleForTesting
  Future<bool> refreshSessionForTesting() => _refreshSessionForSyncHint();

  bool _refreshAttemptIsCurrent({
    required ApiClient client,
    required String base,
    required String username,
    required AuthSession capturedSession,
    required String accountId,
    required String deviceId,
    required String refreshToken,
    required String accessToken,
    required String? capturedProfileAccountId,
  }) {
    final liveSession = session;
    return identical(api, client) &&
        client.baseUrl == base &&
        _authenticatedUsername == username &&
        identical(liveSession, capturedSession) &&
        liveSession?.accountId == accountId &&
        liveSession?.deviceId == deviceId &&
        liveSession?.refreshToken == refreshToken &&
        liveSession?.accessToken == accessToken &&
        account?.accountId == capturedProfileAccountId;
  }

  bool _refreshAttemptWasSupersededByCurrentCredentials({
    required ApiClient client,
    required String base,
    required String username,
    required String accountId,
    required String deviceId,
    required String refreshToken,
    required String accessToken,
    required String? capturedProfileAccountId,
  }) {
    final liveSession = session;
    final adoptedAt = _sessionCredentialsAdoptedAt;
    return identical(api, client) &&
        client.baseUrl == base &&
        _authenticatedUsername == username &&
        adoptedAt != null &&
        DateTime.now().toUtc().difference(adoptedAt) <=
            const Duration(seconds: 10) &&
        liveSession != null &&
        liveSession.accountId == accountId &&
        liveSession.deviceId == deviceId &&
        liveSession.refreshToken != refreshToken &&
        liveSession.accessToken != accessToken &&
        account?.accountId == capturedProfileAccountId;
  }

  void _restoreCurrentApiAccessToken(ApiClient capturedClient) {
    if (identical(api, capturedClient)) {
      // ApiClient.refresh assigns its response token before completing its
      // Future. If a logout/login or tab adoption won while it was in flight,
      // restore the access token belonging to the controller's live session.
      capturedClient.accessToken = session?.accessToken;
    }
  }

  Future<bool> _refreshSessionForSyncHint({
    bool duringUnlock = false,
    bool force = true,
  }) {
    if (_lockedUnlockInProgress && !duringUnlock) {
      return Future<bool>.value(false);
    }
    final client = api;
    final base = client?.baseUrl;
    final username = _authenticatedUsername;
    final current = session;
    if (client == null || base == null || username == null || current == null) {
      return Future<bool>.value(false);
    }
    final active = _activeSessionRefreshForSyncHint;
    if (active != null &&
        active.matches(
          candidateClient: client,
          candidateBase: base,
          candidateUsername: username,
          candidateSession: current,
        )) {
      return active.future;
    }
    late final _ActiveSessionRefresh flight;
    late final Future<bool> refresh;
    refresh = _performSessionRefreshForSyncHint(force: force).whenComplete(() {
      if (identical(_activeSessionRefreshForSyncHint, flight)) {
        _activeSessionRefreshForSyncHint = null;
      }
    });
    flight = _ActiveSessionRefresh(
      client: client,
      base: base,
      username: username,
      session: current,
      future: refresh,
    );
    _activeSessionRefreshForSyncHint = flight;
    return refresh;
  }

  Future<bool> _performSessionRefreshForSyncHint({required bool force}) async {
    final client = api;
    final base = client?.baseUrl;
    final username = _authenticatedUsername;
    final current = session;
    if (client == null || base == null || username == null || current == null) {
      return false;
    }
    final accountId = current.accountId;
    final deviceId = current.deviceId;
    final refreshToken = current.refreshToken;
    final accessToken = current.accessToken;
    final capturedProfileAccountId = account?.accountId;
    bool attemptIsCurrent() => _refreshAttemptIsCurrent(
      client: client,
      base: base,
      username: username,
      capturedSession: current,
      accountId: accountId,
      deviceId: deviceId,
      refreshToken: refreshToken,
      accessToken: accessToken,
      capturedProfileAccountId: capturedProfileAccountId,
    );
    final adoptedAt = _sessionCredentialsAdoptedAt;
    if (adoptedAt != null &&
        DateTime.now().toUtc().difference(adoptedAt) <=
            const Duration(seconds: 10)) {
      // A 4001 from a socket carrying the old ticket can arrive after another
      // tab's new access token was already applied. Reconnect once with that
      // current credential before considering another refresh rotation.
      _sessionCredentialsAdoptedAt = null;
      return true;
    }
    try {
      final scope = SessionScope(
        serverNamespace: secureStorageNamespace(base),
        accountId: current.accountId,
        deviceId: current.deviceId,
      );
      final coordinator = SessionRefreshCoordinator(
        lock: _sessionRefreshLock,
        scope: scope,
        readLatest: () =>
            secureStore.readSessionSnapshot(base, username, current.deviceId),
        markRotationPending: () =>
            secureStore.markSessionRotationPending(base, username, scope),
        writeLatest: (credentials) async {
          // Keep older same-origin app tabs from seeing the consumed token:
          // update the legacy key first, then atomically publish this key as
          // ready. If either write fails, the durable pending marker remains.
          await secureStore.saveRefreshToken(
            base,
            username,
            credentials.refreshToken,
          );
          await secureStore.saveSessionSnapshot(base, username, credentials);
        },
        refresh: (refreshToken) async {
          final refreshed = await client.refresh(refreshToken);
          return _sessionCredentialsFor(refreshed);
        },
        signalOtherTabs: (kind) => _sessionUpdateNotifier.signal(
          SessionUpdateEvent(scope: scope, kind: kind),
        ),
      );
      final outcome = await coordinator.refreshIfNeeded(
        _sessionCredentialsFor(current),
        force: force,
      );
      if (!attemptIsCurrent()) {
        _restoreCurrentApiAccessToken(client);
        // Another same-origin tab may have rotated and published the shared
        // session while this attempt waited for the Web Lock. Keep the sync
        // hint transport alive when this controller still has the same
        // authenticated account/device and has adopted newer credentials.
        return _refreshAttemptWasSupersededByCurrentCredentials(
          client: client,
          base: base,
          username: username,
          accountId: accountId,
          deviceId: deviceId,
          refreshToken: refreshToken,
          accessToken: accessToken,
          capturedProfileAccountId: capturedProfileAccountId,
        );
      }
      final currentSession = session;
      if (currentSession == null) {
        _restoreCurrentApiAccessToken(client);
        return false;
      }
      if (outcome.rotated) {
        session = _authSessionWithCredentials(
          currentSession,
          outcome.credentials,
        );
        client.accessToken = outcome.credentials.accessToken;
        _sessionAccessExpiresAt = outcome.credentials.accessExpiresAt;
        _sessionCredentialsAdoptedAt = null;
      } else {
        _applySharedSessionCredentials(outcome.credentials);
      }
      if (!outcome.persisted) {
        noticeMessage = currentL10n.theSessionWasRefreshedButThe;
      }
      notifyListeners();
      return true;
    } on SessionCoordinationUnavailableException {
      if (!attemptIsCurrent()) {
        _restoreCurrentApiAccessToken(client);
        return false;
      }
      noticeMessage = currentL10n.thisBrowserCantSafelyCoordinateSession;
      notifyListeners();
      return false;
    } on SessionRecoveryRequiredException {
      if (!attemptIsCurrent()) {
        _restoreCurrentApiAccessToken(client);
        return false;
      }
      final cleared = await _clearLocalAuthenticatedState(
        expectedSession: current,
        expectedApi: client,
        expectedBase: base,
        expectedUsername: username,
      );
      if (cleared) {
        noticeMessage = currentL10n.thisDeviceHasNoCurrentSession;
        notifyListeners();
      }
      return false;
    } on SessionSnapshotPersistenceException {
      if (!attemptIsCurrent()) {
        _restoreCurrentApiAccessToken(client);
        return false;
      }
      noticeMessage = currentL10n.theRefreshRequestStateCouldntBe;
      notifyListeners();
      return false;
    } on ApiException catch (error) {
      if (!attemptIsCurrent()) {
        _restoreCurrentApiAccessToken(client);
        return false;
      }
      if (error.statusCode == 401 || error.statusCode == 403) {
        await _clearLocalAuthenticatedState(
          expectedSession: current,
          expectedApi: client,
          expectedBase: base,
          expectedUsername: username,
        );
      }
      return false;
    } catch (_) {
      if (!attemptIsCurrent()) {
        _restoreCurrentApiAccessToken(client);
      }
      return false;
    }
  }

  Future<void> recoverFromSnapshot() {
    final existing = _snapshotRecoveryFuture;
    if (existing != null) return existing;
    final membershipRefresh = _membershipRefreshFuture;
    if (membershipRefresh != null) {
      return membershipRefresh.then((_) => recoverFromSnapshot());
    }
    final recovery = _recoverFromSnapshot();
    _snapshotRecoveryFuture = recovery;
    return recovery.whenComplete(() {
      if (identical(_snapshotRecoveryFuture, recovery)) {
        _snapshotRecoveryFuture = null;
      }
    });
  }

  VaultArchiveContext _currentArchiveContext() {
    final vault = activeVault;
    final device = identity;
    final profile = account;
    final info = instance;
    if (vault == null || device == null || profile == null || info == null) {
      throw StateError(currentL10n.signInAndUnlockTheTarget);
    }
    return VaultArchiveContext(
      instanceId: info.instanceId,
      serverSpaceId: info.serverSpaceId,
      accountId: profile.accountId,
      device: device,
      vault: vault,
      epochKeysByVersion:
          _vaultEpochKeys[vault.id] ?? const <String, Uint8List>{},
    );
  }

  PortableVaultArchiveService _portableArchiveService() =>
      PortableVaultArchiveService(
        sodium: sodium,
        api: _requireApi(),
        database: database,
        crypto: crypto,
      );

  Future<bool> exportPortableVaultArchive(String exportPassword) async {
    if (archiveBusy ||
        syncing ||
        snapshotRecoveryActive ||
        _membershipRefreshActive ||
        _vaultMembershipChangeActive) {
      throw StateError(currentL10n.waitForTheCurrentSyncOr);
    }
    _beginArchiveOperation();
    archiveFailurePhase = null;
    archiveProgress = currentL10n.preparingExport;
    notifyListeners();
    Uint8List? bytes;
    try {
      final context = _currentArchiveContext();
      bytes = await _portableArchiveService().exportArchive(
        context: context,
        exportPassword: exportPassword,
        onProgress: (value) {
          archiveProgress = value;
          notifyListeners();
        },
      );
      return await saveAttachmentFile(
        fileName: 'atermius-${context.vault.id}.atvlt',
        mediaType: 'application/octet-stream',
        bytes: bytes,
      );
    } catch (error) {
      errorMessage = friendlyError(error);
      rethrow;
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
      _endArchiveOperation();
      archiveProgress = null;
      notifyListeners();
    }
  }

  Future<StagedVaultArchive> stagePortableVaultArchive({
    required Uint8List container,
    required String exportPassword,
  }) async {
    if (archiveBusy ||
        syncing ||
        snapshotRecoveryActive ||
        _membershipRefreshActive ||
        _vaultMembershipChangeActive) {
      throw StateError(currentL10n.waitForTheCurrentSyncOr);
    }
    _beginArchiveOperation();
    archiveFailurePhase = null;
    archiveProgress = currentL10n.preparingVerification;
    var lastArchivePhase = archiveProgress!;
    notifyListeners();
    try {
      return await _portableArchiveService().stageImport(
        container: container,
        exportPassword: exportPassword,
        target: _currentArchiveContext(),
        onProgress: (value) {
          lastArchivePhase = value;
          archiveProgress = value;
          notifyListeners();
        },
      );
    } catch (error) {
      archiveFailurePhase = lastArchivePhase;
      errorMessage = friendlyError(error);
      rethrow;
    } finally {
      _endArchiveOperation();
      archiveProgress = null;
      notifyListeners();
    }
  }

  Future<void> applyPortableVaultArchive(StagedVaultArchive staged) async {
    final vault = activeVault;
    if (vault == null ||
        staged.vaultId != vault.id ||
        staged.serverSpaceId != instance?.serverSpaceId) {
      staged.dispose();
      throw StateError(currentL10n.theArchiveNoLongerCorrespondsTo);
    }
    if (archiveBusy ||
        syncing ||
        snapshotRecoveryActive ||
        _membershipRefreshActive ||
        _vaultMembershipChangeActive) {
      staged.dispose();
      throw StateError(currentL10n.waitForTheCurrentSyncOr);
    }
    final keys = _vaultEpochKeys.putIfAbsent(vault.id, () => {});
    for (final entry in staged.epochKeysByVersion.entries) {
      final existing = keys[entry.key];
      if (existing != null && !_sameArchiveBytes(existing, entry.value)) {
        staged.dispose();
        throw StateError(currentL10n.theKeyKeyInTheArchive(entry.key));
      }
    }
    _beginArchiveOperation();
    archiveProgress = currentL10n.uploadMissingEncryptedObjectsAndRestore;
    _automaticSync.stop();
    notifyListeners();
    try {
      await _portableArchiveService().applyStage(
        staged,
        instanceId: _requireRepository().instanceId,
      );
      mergeArchiveEpochKeys(current: keys, imported: staged.epochKeysByVersion);
      final activeKeyName =
          '${vault.activeKeyEpoch}:${vault.membershipVersion}';
      final currentKey =
          keys[activeKeyName] ??
          keys.entries
              .where(
                (entry) => entry.key.startsWith('${vault.activeKeyEpoch}:'),
              )
              .map((entry) => entry.value)
              .firstOrNull;
      if (currentKey != null) {
        _vaultKeys.putIfAbsent(vault.id, () => Uint8List.fromList(currentKey));
      }
      await _buildRepository();
      await reloadRecords();
      await refreshSyncStatus();
      _setNotice(currentL10n.theArchiveWasVerifiedAndRestored);
    } catch (error) {
      errorMessage = friendlyError(error);
      rethrow;
    } finally {
      staged.dispose();
      _endArchiveOperation();
      archiveProgress = null;
      _automaticSync.start();
      notifyListeners();
    }
  }

  Future<void> _recoverFromSnapshot() async {
    final repository = _repository;
    if (repository == null) {
      errorMessage = currentL10n.unlockTheVaultFirst2;
      notifyListeners();
      return;
    }
    _automaticSync.stop();
    snapshotRecoveryActive = true;
    _knownHostDecisionGeneration++;
    syncStatus = 'snapshot_recovering';
    errorMessage = null;
    notifyListeners();
    try {
      final result = await repository.recoverFromSnapshot();
      final recoveredGeneration = result.serverGeneration;
      final currentInstance = instance;
      if (recoveredGeneration != null && currentInstance != null) {
        instance = InstanceInfo(
          instanceId: currentInstance.instanceId,
          serverSpaceId: currentInstance.serverSpaceId,
          generation: recoveredGeneration,
          protocolVersion: currentInstance.protocolVersion,
          setupRequired: currentInstance.setupRequired,
          capabilities: currentInstance.capabilities,
          signingPublicKey: currentInstance.signingPublicKey,
          signingKeyTransitions: currentInstance.signingKeyTransitions,
        );
      }
      syncStatus = result.status;
      pendingCount = result.pendingCount;
      receivedCount = result.receivedCount;
      conflictCount = result.conflictCount;
      await reloadRecords();
      await refreshSyncStatus(keepStatus: true);
      _setNotice(
        result.status == 'idle'
            ? currentL10n.snapshotRestoreCompleteReceivedcountRecordsVerified(
                result.receivedCount,
              )
            : currentL10n.theSnapshotWasRestoredSafelySome,
      );
    } catch (error) {
      if (error is SnapshotRedactionResurrectionException) {
        syncStatus = 'redaction_restore_conflict';
        _automaticSync.stop();
      } else if (error is SnapshotBootstrapLimitException) {
        syncStatus = 'snapshot_too_large';
        _automaticSync.stop();
      } else {
        syncStatus = error is ApiException
            ? (error.isRetryable ? 'retry_wait' : error.code.toLowerCase())
            : repository.lastRecoveryCommitted
            ? 'retry_wait'
            : 'resnapshot_required';
      }
      errorMessage = friendlyError(error);
      try {
        await refreshSyncStatus(keepStatus: true);
      } catch (_) {
        // The primary verification/network error remains visible.
      }
    } finally {
      snapshotRecoveryActive = false;
      if (syncStatus == 'snapshot_too_large' ||
          syncStatus == 'redaction_restore_conflict') {
        _automaticSync.stop();
      } else {
        _automaticSync.start();
      }
      notifyListeners();
    }
  }

  /// Refreshes the active UI projection from the local database for one Vault.
  ///
  /// The Web outbox is shared by same-origin tabs through IndexedDB, so a
  /// controller's cached count may be stale even when this instance received
  /// no notification for the other tab's write.
  Future<int> refreshPendingCountForVault(String vaultId) async {
    final repository = _repository;
    final nextPendingCount = repository?.vaultId == vaultId
        ? await database.countPending(
            vaultId,
            instanceId: repository!.instanceId,
            serverSpaceId: repository.serverSpaceId,
          )
        : 0;
    if (activeVault?.id == vaultId && pendingCount != nextPendingCount) {
      pendingCount = nextPendingCount;
      notifyListeners();
    }
    return nextPendingCount;
  }

  Future<void> refreshSyncStatus({bool keepStatus = false}) async {
    final vault = activeVault;
    if (vault == null) return;
    final vaultId = vault.id;
    final repository = _repository;
    final nextPendingCount = repository?.vaultId == vaultId
        ? await database.countPending(
            vaultId,
            instanceId: repository!.instanceId,
            serverSpaceId: repository.serverSpaceId,
          )
        : 0;
    final loadedFeedItems =
        await repository?.loadConflictFeedReviewItems() ??
        const <ConflictFeedReviewItem>[];
    final localRows = repository?.vaultId == vaultId
        ? await database.openConflicts(
            vaultId,
            instanceId: repository!.instanceId,
            serverSpaceId: repository.serverSpaceId,
          )
        : const <ConflictBranche>[];
    final projection = projectConflictReviewItems(
      localOpenConflictRecords: {
        for (final item in localRows) item.conflictId: item.recordId,
      },
      feedItems: loadedFeedItems,
    );
    final nextOpenConflicts = localRows
        .where((item) => projection.localConflictIds.contains(item.conflictId))
        .map(
          (item) => {
            'conflict_id': item.conflictId,
            'record_id': item.recordId,
            'kind': item.kind,
            'created_at': item.createdAt,
            'branch_envelope': jsonDecode(item.branchEnvelopeJson),
            'remote_envelope': jsonDecode(item.remoteEnvelopeJson),
            if (item.redactionProofJson != null)
              'redaction_proof': jsonDecode(item.redactionProofJson!),
          },
        )
        .toList(growable: false);
    final checkpoint = repository?.vaultId == vaultId
        ? await database.checkpoint(
            vaultId,
            instanceId: repository!.instanceId,
            serverSpaceId: repository.serverSpaceId,
          )
        : null;
    if (activeVault?.id != vaultId || !identical(repository, _repository)) {
      return;
    }
    _allFeedConflictItems = loadedFeedItems;
    feedConflictItems = projection.feedItems;
    openConflicts = nextOpenConflicts;
    pendingCount = nextPendingCount;
    conflictCount = openConflicts.length;
    lastSuccessfulSyncAt = checkpoint?.lastSuccessAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            checkpoint!.lastSuccessAt!,
            isUtc: true,
          );
    syncCheckpointServerGeneration = checkpoint?.serverGeneration;
    if (!keepStatus) {
      syncStatus =
          checkpoint?.syncStatus ?? (pendingCount > 0 ? 'pending' : 'idle');
    }
    notifyListeners();
  }

  Future<void> _loadConflictSummaries() async => refreshSyncStatus();

  Future<void> resolveConflict(
    String conflictId, {
    required bool keepLocal,
  }) async {
    _assertEditsAllowed(requireWritableVault: true);
    await _requireRepository().resolveConflictBranch(
      conflictId: conflictId,
      keepLocal: keepLocal,
    );
    await synchronize();
  }

  Future<bool> isPasswordCredentialMergeEligible({
    required String conflictId,
  }) async {
    if (activeVault == null || _repository == null) return false;
    return _repository!.isPasswordCredentialMergeEligible(
      conflictId: conflictId,
    );
  }

  Future<CredentialConflictMergePreview?> loadCredentialConflictMergePreview({
    required String conflictId,
  }) async {
    if (activeVault == null || _repository == null) return null;
    return _repository!.loadCredentialConflictMergePreview(
      conflictId: conflictId,
    );
  }

  Future<CredentialConflictMergeOutcome> mergePasswordCredentialConflict({
    required String conflictId,
    required String expectedHeadRevisionId,
    required Map<CredentialConflictMergeField, CredentialConflictMergeBranch>
    choices,
  }) async {
    _assertEditsAllowed(requireWritableVault: true);
    final targetVaultId = activeVault?.id;
    if (targetVaultId == null) {
      throw StateError(currentL10n.selectAVaultBeforeResolvingThis);
    }
    final repository = _requireRepository();
    final outcome = await repository.mergePasswordCredentialConflict(
      conflictId: conflictId,
      expectedHeadRevisionId: expectedHeadRevisionId,
      choices: choices,
    );
    if (activeVault?.id == targetVaultId &&
        identical(_repository, repository)) {
      await reloadRecords();
      await refreshSyncStatus();
      if (outcome.status == CredentialConflictMergeStatus.staged) {
        _automaticSync.scheduleEdit();
      }
    }
    return outcome;
  }

  Future<HostSecurityConflictMergePreview?>
  loadHostSecurityConflictMergePreview({required String conflictId}) async {
    if (activeVault == null || _repository == null) return null;
    return _repository!.loadHostSecurityConflictMergePreview(
      conflictId: conflictId,
    );
  }

  Future<HostSecurityConflictMergeOutcome> mergeHostSecurityConflict({
    required String conflictId,
    required String expectedHeadRevisionId,
    required HostSecurityMergeBranch choice,
  }) async {
    _assertEditsAllowed(requireWritableVault: true);
    final targetVaultId = activeVault?.id;
    if (targetVaultId == null) {
      throw StateError(currentL10n.selectAVaultBeforeResolvingThis2);
    }
    final repository = _requireRepository();
    final outcome = await repository.mergeHostSecurityConflict(
      conflictId: conflictId,
      expectedHeadRevisionId: expectedHeadRevisionId,
      choice: choice,
      validateReferences: (candidate) {
        try {
          final host = HostRecord.fromJson(
            Map<String, dynamic>.from(candidate),
          );
          return host.validate() ?? validateHostReferences(host);
        } on Object {
          return currentL10n.theMergedHostRecordIsInvalid;
        }
      },
    );
    if (activeVault?.id == targetVaultId &&
        identical(_repository, repository)) {
      await reloadRecords();
      await refreshSyncStatus();
    }
    // A membership/control-plane refresh can replace the repository while
    // this staged write is completing. The ciphertext is already durable in
    // the shared Vault database, so run sync against the current repository
    // whenever the user is still on that Vault. synchronize() coalesces with
    // any in-flight controller pass and retries after its post-sync refresh.
    // With automatic sync off the staged ciphertext stays in the outbox until
    // the user runs Sync now or turns automatic sync back on.
    if (activeVault?.id == targetVaultId &&
        outcome.status == HostSecurityMergeStatus.staged &&
        automaticSyncActive) {
      unawaited(_synchronizeAutomatically());
    }
    return outcome;
  }

  Future<void> adoptRemoteConflict(String conflictId) async {
    _assertEditsAllowed(requireWritableVault: true);
    await _requireRepository().adoptRemoteConflict(conflictId);
    await synchronize();
  }

  Future<void> retainCurrentConflictHead(String conflictId) async {
    _assertEditsAllowed(requireWritableVault: true);
    await _requireRepository().retainCurrentConflictHead(conflictId);
    await synchronize();
  }

  Future<String> saveWorkspaceConflictBranchAsNamedCopy({
    required String conflictId,
    required String copyName,
  }) async {
    _assertEditsAllowed(requireWritableVault: true);
    final targetVaultId = activeVault?.id;
    if (targetVaultId == null) throw StateError(currentL10n.chooseAVaultFirst);
    final repository = _requireRepository();
    final copyId = await repository.saveWorkspaceConflictBranchAsNamedCopy(
      conflictId: conflictId,
      copyName: copyName,
    );
    if (activeVault?.id == targetVaultId &&
        identical(_repository, repository)) {
      await reloadRecords();
      await refreshSyncStatus();
      _automaticSync.scheduleEdit();
    }
    return copyId;
  }

  String labelForRecord(String id) {
    for (final host in hosts) {
      if (host.id == id) return host.name;
    }
    for (final credential in credentials) {
      if (credential.id == id) return credential.name;
    }
    for (final snippet in snippets) {
      if (snippet.id == id) return snippet.title;
    }
    for (final workspace in savedWorkspaces) {
      if (workspace.id == id) return workspace.name;
    }
    return id;
  }

  Future<void> refreshDevices({bool background = false}) async {
    try {
      devices = await _requireApi().devices();
      notifyListeners();
    } catch (error) {
      _setError(friendlyError(error));
      if (!background) rethrow;
    }
  }

  /// Refreshes the device directory for the currently selected Vault. This
  /// includes active devices belonging to every active member, unlike the
  /// account-scoped [devices] list. The server remains authoritative for purge
  /// eligibility; these rows are only a signed, client-verified UI projection.
  Future<void> refreshVaultDeviceRows({
    String? vaultId,
    bool background = false,
    bool recoverCurrentDevice = false,
  }) async {
    final selectedVaultId = vaultId ?? activeVault?.id;
    if (selectedVaultId == null || selectedVaultId.isEmpty) {
      vaultDeviceRows = [];
      vaultDeviceRowsVaultId = null;
      vaultDeviceRowsError = null;
      vaultDeviceRowsLoading = false;
      notifyListeners();
      return;
    }

    final requestGeneration = ++_vaultDeviceRowsRequestGeneration;
    if (activeVault?.id == selectedVaultId) {
      vaultDeviceRowsLoading = true;
      vaultDeviceRowsError = null;
      // Do not present an old snapshot as current readiness if this refresh
      // later fails. The purge endpoint remains authoritative, and the UI
      // should fail closed while it cannot refresh the active Vault roster.
      vaultDeviceRows = [];
      vaultDeviceRowsVaultId = selectedVaultId;
      notifyListeners();
    }
    try {
      final client = _requireApi();
      var rows = await client.vaultDevices(selectedVaultId);
      if (recoverCurrentDevice &&
          activeVault?.id == selectedVaultId &&
          await _republishCurrentDeviceRedactionCapabilityIfNeeded(rows)) {
        // The signed report can change only after publication completes. Read
        // the Vault roster again so the readiness result reflects that update.
        rows = await client.vaultDevices(selectedVaultId);
      }
      if (requestGeneration == _vaultDeviceRowsRequestGeneration &&
          activeVault?.id == selectedVaultId) {
        vaultDeviceRows = rows;
        vaultDeviceRowsVaultId = selectedVaultId;
        vaultDeviceRowsError = null;
      }
    } catch (error) {
      if (requestGeneration == _vaultDeviceRowsRequestGeneration &&
          activeVault?.id == selectedVaultId) {
        vaultDeviceRowsError = friendlyError(error);
      }
      if (!background) rethrow;
    } finally {
      if (requestGeneration == _vaultDeviceRowsRequestGeneration &&
          activeVault?.id == selectedVaultId) {
        vaultDeviceRowsLoading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> _republishCurrentDeviceRedactionCapabilityIfNeeded(
    List<Map<String, dynamic>> rows,
  ) async {
    final currentIdentity = identity;
    final currentInstance = instance;
    final client = api;
    final currentAccount = account;
    final accountId = currentAccountId;
    if (currentIdentity == null ||
        currentInstance == null ||
        client == null ||
        accountId == null ||
        !currentInstance.capabilities.contains(
          'device_redaction_capability_reports',
        )) {
      return false;
    }
    if ((currentAccount != null &&
            (currentAccount.accountId != accountId ||
                currentAccount.deviceId != currentIdentity.deviceId)) ||
        (session != null &&
            (session!.accountId != accountId ||
                session!.deviceId != currentIdentity.deviceId))) {
      return false;
    }

    Map<String, dynamic>? currentRow;
    for (final row in rows) {
      if (row['device_id'] == currentIdentity.deviceId &&
          row['user_id'] == accountId) {
        currentRow = row;
        break;
      }
    }
    if (currentRow == null ||
        currentRow['status'] != 'active' ||
        currentRow['membership_status'] != 'active') {
      return false;
    }

    final readiness = DeviceRedactionReadiness.fromVaultDeviceRow(
      currentRow,
      crypto: crypto,
    );
    final canRecover =
        readiness.status == DeviceRedactionReadinessStatus.invalidated ||
        (readiness.status == DeviceRedactionReadinessStatus.missing &&
            currentRow.containsKey('redaction_capability_report'));
    if (!canRecover) return false;

    // Explicit user refresh may bypass the automatic publication cache and
    // retry cooldown. The publisher retains its durable revision floor and
    // advances only after a server revision-conflict response.
    await _publishClientRedactionCapability(
      client: client,
      currentInstance: currentInstance,
      currentAccountId: accountId,
      currentIdentity: currentIdentity,
      force: true,
    );
    return true;
  }

  List<Map<String, dynamic>> get activeVaultDeviceRows =>
      activeVault?.id != null && vaultDeviceRowsVaultId == activeVault?.id
      ? vaultDeviceRows
      : const <Map<String, dynamic>>[];

  void _clearVaultDeviceRows() {
    _vaultDeviceRowsRequestGeneration++;
    vaultDeviceRows = [];
    vaultDeviceRowsVaultId = null;
    vaultDeviceRowsLoading = false;
    vaultDeviceRowsError = null;
  }

  Future<void> refreshVaultMembers({String? vaultId}) async {
    final selectedVaultId = vaultId ?? activeVault?.id;
    if (selectedVaultId == null || selectedVaultId.isEmpty) {
      throw StateError(currentL10n.chooseAVaultFirst);
    }
    final members = await _requireApi().vaultMembers(selectedVaultId);
    if (activeVault?.id == selectedVaultId) {
      vaultMembers = members;
      notifyListeners();
    }
    await refreshVaultPresence(vaultId: selectedVaultId);
  }

  Future<void> refreshVaultPresence({String? vaultId}) async {
    await _refreshVaultPresence(vaultId: vaultId, renewLease: true);
  }

  /// Refreshes only the minimal online-device snapshot, without touching the
  /// Vault member ACL or extending this profile's lease.
  Future<void> refreshVaultPresenceList({String? vaultId}) async {
    await _refreshVaultPresence(vaultId: vaultId, renewLease: false);
  }

  Future<void> _refreshVaultPresence({
    String? vaultId,
    required bool renewLease,
  }) async {
    final selectedVaultId = vaultId ?? activeVault?.id;
    if (selectedVaultId == null || selectedVaultId.isEmpty) {
      throw StateError(currentL10n.chooseAVaultFirst);
    }

    final existingRequest = _vaultPresenceRefreshRequests[selectedVaultId];
    if (existingRequest != null) {
      await existingRequest;
      return;
    }

    final requestGeneration = ++_vaultPresenceRequestGeneration;
    if (activeVault?.id == selectedVaultId) {
      vaultPresenceLoading = true;
      vaultPresenceError = null;
      notifyListeners();
    }

    final request = _fetchVaultPresence(
      selectedVaultId,
      requestGeneration: requestGeneration,
      renewLease: renewLease,
    );
    _vaultPresenceRefreshRequests[selectedVaultId] = request;
    try {
      await request;
    } finally {
      if (identical(_vaultPresenceRefreshRequests[selectedVaultId], request)) {
        _vaultPresenceRefreshRequests.remove(selectedVaultId);
      }
    }
  }

  Future<void> _fetchVaultPresence(
    String vaultId, {
    required int requestGeneration,
    required bool renewLease,
  }) async {
    try {
      if (renewLease) {
        try {
          // Members refreshes renew this profile before reading. A recent
          // heartbeat is a fixed 429; its existing lease remains visible, so
          // continue with GET instead of suppressing the member snapshot.
          await _requireApi().heartbeatVaultPresence(vaultId);
        } on ApiException catch (error) {
          if (error.statusCode != 429 ||
              error.code != 'PRESENCE_HEARTBEAT_RATE_LIMITED') {
            rethrow;
          }
        }
      }
      final snapshot = await _requireApi().vaultPresence(vaultId);
      if (requestGeneration == _vaultPresenceRequestGeneration &&
          activeVault?.id == vaultId) {
        vaultPresenceDevices = snapshot.devices;
        vaultPresenceError = null;
      }
    } catch (error) {
      if (requestGeneration == _vaultPresenceRequestGeneration &&
          activeVault?.id == vaultId) {
        vaultPresenceError = friendlyError(error);
      }
    } finally {
      if (requestGeneration == _vaultPresenceRequestGeneration &&
          activeVault?.id == vaultId) {
        vaultPresenceLoading = false;
        notifyListeners();
      }
    }
  }

  void _startVaultPresenceHeartbeats() {
    _vaultPresenceHeartbeatTimer?.cancel();
    _vaultPresenceHeartbeatTimer = null;
    final selectedVaultId = activeVault?.id;
    if (selectedVaultId == null ||
        !authenticated ||
        stage != ClientStage.workspace) {
      return;
    }
    unawaited(_sendVaultPresenceHeartbeat(selectedVaultId));
    _vaultPresenceHeartbeatTimer = Timer.periodic(
      vaultPresenceHeartbeatIntervalForTesting,
      (_) {
        final currentVaultId = activeVault?.id;
        if (currentVaultId == null ||
            !authenticated ||
            stage != ClientStage.workspace) {
          return;
        }
        unawaited(_sendVaultPresenceHeartbeat(currentVaultId));
      },
    );
  }

  @visibleForTesting
  void startVaultPresenceHeartbeatsForTesting() =>
      _startVaultPresenceHeartbeats();

  @visibleForTesting
  void stopVaultPresenceHeartbeatsForTesting() =>
      _stopVaultPresenceHeartbeats(clearState: true);

  Future<void> _sendVaultPresenceHeartbeat(String vaultId) async {
    try {
      await _requireApi().heartbeatVaultPresence(vaultId);
    } catch (_) {
      // The lease naturally expires after 90 seconds when a client is offline
      // or cannot reach the server; a later heartbeat reestablishes it.
    }
  }

  void _stopVaultPresenceHeartbeats({bool clearState = false}) {
    _vaultPresenceHeartbeatTimer?.cancel();
    _vaultPresenceHeartbeatTimer = null;
    _vaultPresenceRequestGeneration++;
    // Do not let a request from the previous Vault selection satisfy a later
    // refresh if the user switches away and back before that request returns.
    _vaultPresenceRefreshRequests.clear();
    if (clearState) {
      vaultPresenceDevices = [];
      vaultPresenceLoading = false;
      vaultPresenceError = null;
    }
  }

  String exportVaultShareRequest() {
    final currentIdentity = identity;
    final currentAccount = account;
    final currentInstance = instance;
    if (currentIdentity == null ||
        currentAccount == null ||
        currentInstance == null) {
      throw StateError(currentL10n.unlockTheAccountBeforeExportingA);
    }
    return crypto.createVaultShareRequest(
      accountId: currentAccount.accountId,
      instanceId: currentInstance.instanceId,
      identity: currentIdentity,
      name: 'Atermius Web',
    );
  }

  PublicDeviceCard verifyVaultShareRequest(String json) {
    final currentInstance = instance;
    if (currentInstance == null) {
      throw StateError(currentL10n.noServerInstanceIsConfiguredYet);
    }
    return crypto.verifyVaultShareRequest(
      json,
      expectedInstanceId: currentInstance.instanceId,
    );
  }

  Future<Map<String, dynamic>> createVaultInvitation({
    required PublicDeviceCard recipient,
    required String role,
    int expiresInSeconds = 7 * 24 * 3600,
  }) async {
    _assertEditsAllowed(requireWritableVault: true);
    if (!const {'editor', 'viewer'}.contains(role)) {
      throw FormatException(currentL10n.theInvitationRoleCanOnlyBe);
    }
    final vault = activeVault;
    final currentIdentity = identity;
    final currentAccount = account;
    if (vault == null || currentIdentity == null || currentAccount == null) {
      throw StateError(currentL10n.unlockTheVaultFirst2);
    }
    if (vault.role != 'owner') {
      throw StateError(currentL10n.onlyTheVaultOwnerCanInvite);
    }
    if (recipient.instanceId != instance?.instanceId) {
      throw FormatException(currentL10n.theShareRequestComesFromA);
    }
    // The session and the selection of [vault] this invitation is created
    // for. Checked before the invitation is dispatched and again before its
    // result touches controller state.
    final client = _requireApi();
    final auth = authScopeToken;
    final selection = vaultSelectionToken;
    bool sessionIsCurrent() =>
        !_controllerDisposed &&
        identical(api, client) &&
        authScopeToken == auth &&
        account?.accountId == currentAccount.accountId &&
        identity?.deviceId == currentIdentity.deviceId;
    bool selectionIsCurrent() =>
        sessionIsCurrent() &&
        vaultSelectionToken == selection &&
        activeVault?.id == vault.id;

    // The server requires the active membership version on every new record.
    // Drain local changes before advancing the signed membership chain.
    if (syncing) throw StateError(currentL10n.theCurrentSyncHasntFinishedWait);
    _automaticSync.stop();
    try {
      await synchronize();
      await refreshSyncStatus();
      if (!selectionIsCurrent()) {
        throw const OperationScopeEndedException(serverCommitted: false);
      }
      if (pendingCount != 0) {
        throw StateError(currentL10n.thereAreUncommittedLocalChangesCreate);
      }

      final directory = <String, Map<String, dynamic>>{};
      final signingKeys = <String, Uint8List>{};
      for (final device in [
        ...await client.devices(),
        ...await client.vaultDevices(vault.id),
      ]) {
        final id = device['device_id'] as String?;
        final key = device['signing_public_key'] as String?;
        if (id == null || key == null) continue;
        directory[id] = device;
        signingKeys[id] = decodeBase64Url(key);
      }
      signingKeys[currentIdentity.deviceId] = currentIdentity.signing.publicKey;

      final membershipResponse = await client.membership(vault.id);
      final rawEntries =
          (membershipResponse['manifests'] ??
                  membershipResponse['memberships'] ??
                  membershipResponse['entries'] ??
                  membershipResponse['chain'])
              as List<dynamic>? ??
          const [];
      final entries = rawEntries
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList(growable: false);
      final chain = await crypto.verifyMembershipChain(
        vaultId: vault.id,
        entries: entries,
        signerPublicKeys: signingKeys,
        expectedLatestVersion: int.parse(vault.membershipVersion),
      );
      _validateMembershipOwnerChain(
        vaultId: vault.id,
        chain: chain,
        directory: directory,
      );
      final latest = chain.last;
      final members = (latest.manifest['members'] as List)
          .map((member) => Map<String, Object?>.from(member as Map))
          .toList(growable: true);
      final currentMembers = await client.vaultMembers(vault.id);
      final existingRecipient = currentMembers
          .where((member) => member['user_id'] == recipient.accountId)
          .firstOrNull;
      final targetIndex = members.indexWhere(
        (member) => member['user_id'] == recipient.accountId,
      );
      if (existingRecipient?['state'] == 'active') {
        throw StateError(currentL10n.thisAccountIsAlreadyAnActive);
      }
      final encryptionFingerprint = await cryptography.Sha256().hash(
        recipient.encryptionPublicKey,
      );
      final targetMember = <String, Object?>{
        'user_id': recipient.accountId,
        'role': role,
        'state': 'active',
        'encryption_key_fingerprint': encodeBase64Url(
          encryptionFingerprint.bytes,
        ),
      };
      if (targetIndex >= 0) {
        members[targetIndex] = targetMember;
      } else {
        members.add(targetMember);
      }

      final nextVersion = latest.version + 1;
      final epoch = int.parse(vault.activeKeyEpoch);
      final currentVaultName = _knownNames[vault.id];
      if (currentVaultName == null || currentVaultName.trim().isEmpty) {
        throw StateError(currentL10n.theVaultNameHasntBeenVerified);
      }
      final displayNameEnvelope = await crypto.encryptVaultName(
        vaultId: vault.id,
        vaultKey: _vaultKeys[vault.id]!,
        name: currentVaultName,
      );
      final manifest = <String, Object?>{
        'key_epoch': epoch,
        'display_name_envelope': displayNameEnvelope,
        'members': members,
        'signer_device_id': currentIdentity.deviceId,
      };
      final signedMembership = crypto.createMembershipGrant(
        vaultId: vault.id,
        membershipVersion: nextVersion,
        previousDigest: latest.digest,
        manifest: manifest,
        signer: currentIdentity,
      );
      final keyEnvelope = crypto.createDeviceKeyEnvelope(
        vaultId: vault.id,
        vaultKey: _vaultKeys[vault.id]!,
        keyEpoch: epoch,
        membershipVersion: nextVersion,
        recipientDeviceId: recipient.deviceId,
        recipientEncryptionPublicKey: recipient.encryptionPublicKey,
        signer: currentIdentity,
      )..remove('vault_id');

      if (!selectionIsCurrent()) {
        throw const OperationScopeEndedException(serverCommitted: false);
      }
      final result = await client.invite(vault.id, {
        'role': role,
        'recipient_device_id': recipient.deviceId,
        'recipient_encryption_public_key': encodeBase64Url(
          recipient.encryptionPublicKey,
        ),
        'key_envelope': keyEnvelope,
        'membership': signedMembership,
        'expires_in_seconds': expiresInSeconds,
      });
      if (!selectionIsCurrent()) {
        // The invitation exists on the server, but this session or Vault
        // selection is no longer the one it was created for: do not install
        // its membership state into, or re-select it over, the newer scope.
        // A still-current session reconciles through the regular refresh.
        if (sessionIsCurrent()) unawaited(_reloadVaultsForMembershipHint());
        throw const OperationScopeEndedException(serverCommitted: true);
      }
      final committedVersion =
          (result['membership_version'] as num?)?.toInt() ?? nextVersion;
      if (committedVersion != nextVersion) {
        throw FormatException(currentL10n.theMembershipVersionReturnedByThe);
      }
      final updated = VaultDescriptor(
        id: vault.id,
        role: vault.role,
        activeKeyEpoch: vault.activeKeyEpoch,
        membershipVersion: '$committedVersion',
        encryptedDisplayNameEnvelope: displayNameEnvelope,
        keyEnvelopes: vault.keyEnvelopes,
        status: vault.status,
        requestedAt: vault.requestedAt,
        purgeAfter: vault.purgeAfter,
        canCancel: vault.canCancel,
        canWrite: vault.canWrite,
      );
      _vaultDescriptors = _vaultDescriptors
          .map((item) => item.id == updated.id ? updated : item)
          .toList(growable: false);
      activeVault = updated;
      await _buildRepository();
      await refreshSyncStatus();
      _setNotice(currentL10n.invitationCreatedGiveTheOneTime);
      return result;
    } finally {
      _automaticSync.start();
    }
  }

  Future<void> changeVaultMemberRole({
    required String userId,
    required String role,
  }) async {
    if (!const {'editor', 'viewer'}.contains(role)) {
      throw FormatException(currentL10n.theMemberRoleCanOnlyBe);
    }
    await _rotateVaultMembership(userId: userId, role: role, revoke: false);
  }

  Future<void> revokeVaultMember(String userId) async {
    await _rotateVaultMembership(userId: userId, revoke: true);
  }

  Future<void> transferVaultOwnership({required String newOwnerUserId}) async {
    await _rotateVaultMembership(
      userId: newOwnerUserId,
      revoke: false,
      transferOwnership: true,
    );
  }

  Future<void> _rotateVaultMembership({
    required String userId,
    String? role,
    required bool revoke,
    bool transferOwnership = false,
  }) async {
    _assertEditsAllowed(requireWritableVault: true);
    if (vaultMembershipBusy) {
      throw StateError(currentL10n.aVaultMemberChangeIsIn);
    }
    final vault = activeVault;
    final currentIdentity = identity;
    final currentAccount = account;
    if (vault == null || currentIdentity == null || currentAccount == null) {
      throw StateError(currentL10n.unlockTheVaultFirst2);
    }
    if (vault.role != 'owner') {
      throw StateError(currentL10n.onlyTheVaultOwnerCanManage2);
    }
    if (vault.status != 'active' || !vault.canWrite) {
      throw StateError(currentL10n.thisVaultIsCurrentlyReadOnly);
    }
    if (!_isCanonicalUuid(userId)) {
      throw FormatException(currentL10n.invalidMemberAccountIdFormat);
    }
    if (userId == currentAccount.accountId) {
      throw StateError(currentL10n.theCurrentVaultOwnerCantBe);
    }
    if (syncing) {
      throw StateError(currentL10n.theCurrentSyncHasntFinishedWait2);
    }

    vaultMembershipBusy = true;
    _automaticSync.stop();
    notifyListeners();
    Uint8List? nextVaultKey;
    Map<String, Object?>? nextDisplayNameEnvelope;
    String? expectedTargetRole;
    var requestSubmitted = false;
    var originalError = false;
    try {
      _traceSafeTeamLifecycle('rotation.sync.start');
      await synchronize();
      _traceSafeTeamLifecycle('rotation.sync.done');
      await refreshSyncStatus();
      _traceSafeTeamLifecycle('rotation.status.done');
      if (pendingCount != 0) {
        throw StateError(currentL10n.thereAreUncommittedLocalChangesRotate);
      }
      if (syncing) {
        throw StateError(currentL10n.aSyncIsStillRunningThe);
      }
      _vaultMembershipChangeActive = true;
      _knownHostDecisionGeneration++;

      final client = _requireApi();
      _traceSafeTeamLifecycle('rotation.members.before.start');
      final rawMembers = await client.vaultMembers(vault.id);
      _traceSafeTeamLifecycle('rotation.members.before.done');
      final membersByUser = <String, Map<String, dynamic>>{};
      for (final member in rawMembers) {
        final memberId = member['user_id'];
        final memberRole = member['role'];
        final memberState = member['state'];
        if (memberId is! String ||
            !_isCanonicalUuid(memberId) ||
            memberRole is! String ||
            !const {'owner', 'editor', 'viewer'}.contains(memberRole) ||
            memberState is! String ||
            !const {'active', 'invited', 'revoked'}.contains(memberState) ||
            membersByUser.containsKey(memberId)) {
          throw FormatException(currentL10n.theServersVaultMembershipListHas);
        }
        membersByUser[memberId] = member;
      }
      final target = membersByUser[userId];
      if (target == null) {
        throw StateError(currentL10n.thisAccountIsntAMemberOf);
      }
      final targetRole = target['role']! as String;
      final targetState = target['state']! as String;
      if (targetRole == 'owner') {
        throw StateError(currentL10n.theVaultOwnerCantBeRevoked);
      }
      if (targetState == 'revoked') {
        throw StateError(currentL10n.thisMembersAccessWasRevokedTo);
      }
      if (!revoke && targetState != 'active') {
        throw StateError(currentL10n.theRoleOfAPendingInvitation);
      }
      if (revoke && !const {'editor', 'viewer'}.contains(targetRole)) {
        throw StateError(currentL10n.theCurrentMemberRoleCantBe);
      }
      if (transferOwnership && targetState != 'active') {
        throw StateError(currentL10n.ownershipCanOnlyBeTransferredTo);
      }
      if (!transferOwnership && !revoke && targetRole == role) return;
      expectedTargetRole = transferOwnership
          ? 'owner'
          : revoke
          ? targetRole
          : role!;

      final allDevices = await client.devices();
      final vaultDevices = await client.vaultDevices(vault.id);
      final directory = <String, Map<String, dynamic>>{};
      final signerKeys = <String, Uint8List>{};
      for (final device in [...allDevices, ...vaultDevices]) {
        final deviceId = device['device_id'];
        final ownerId = device['user_id'];
        final signingText = device['signing_public_key'];
        if (deviceId is! String ||
            !_isCanonicalUuid(deviceId) ||
            ownerId is! String ||
            !_isCanonicalUuid(ownerId) ||
            signingText is! String) {
          throw FormatException(currentL10n.theVaultDeviceDirectoryIsMissing);
        }
        final signingKey = decodeBase64Url(signingText);
        if (signingKey.length != 32) {
          throw FormatException(
            currentL10n.theSigningPublicKeyOfDevice(deviceId),
          );
        }
        final existing = directory[deviceId];
        if (existing != null &&
            (existing['user_id'] != ownerId ||
                existing['signing_public_key'] != signingText ||
                existing['encryption_public_key'] !=
                    device['encryption_public_key'])) {
          throw FormatException(
            currentL10n.thePublicKeysForDeviceDeviceid(deviceId),
          );
        }
        directory[deviceId] = device;
        signerKeys[deviceId] = signingKey;
      }
      signerKeys[currentIdentity.deviceId] = currentIdentity.signing.publicKey;

      final membershipResponse = await client.membership(vault.id);
      final rawEntries =
          (membershipResponse['manifests'] ??
                  membershipResponse['memberships'] ??
                  membershipResponse['entries'] ??
                  membershipResponse['chain'])
              as List<dynamic>? ??
          const [];
      final entries = rawEntries
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList(growable: false);
      final currentVersion = int.tryParse(vault.membershipVersion);
      final currentEpoch = int.tryParse(vault.activeKeyEpoch);
      if (currentVersion == null || currentEpoch == null) {
        throw FormatException(currentL10n.theVaultsCurrentEpochOrMembership);
      }
      final chain = await crypto.verifyMembershipChain(
        vaultId: vault.id,
        entries: entries,
        signerPublicKeys: signerKeys,
        expectedLatestVersion: currentVersion,
      );
      _validateMembershipOwnerChain(
        vaultId: vault.id,
        chain: chain,
        directory: directory,
      );
      final latest = chain.last;
      final latestEpoch = latest.manifest['key_epoch'];
      if (latestEpoch != currentEpoch) {
        throw FormatException(currentL10n.theVaultsCurrentKeyEpochDoesnt);
      }
      final signedMembers = latest.manifest['members'];
      if (signedMembers is! List ||
          signedMembers.length != membersByUser.length) {
        throw FormatException(currentL10n.theSignedMembershipListDoesntMatch2);
      }
      final memberEntries = <Map<String, Object?>>[];
      final seenMembers = <String>{};
      for (final raw in signedMembers) {
        if (raw is! Map) {
          throw FormatException(currentL10n.theSignedMembershipEntryHasAn);
        }
        final signedMember = Map<String, Object?>.from(raw);
        final memberId = signedMember['user_id'];
        final memberRole = signedMember['role'];
        final memberState = signedMember['state'];
        if (memberId is! String ||
            memberRole is! String ||
            memberState is! String ||
            !seenMembers.add(memberId)) {
          throw FormatException(
            currentL10n.theSignedMembershipListContainsInvalid,
          );
        }
        final serverMember = membersByUser[memberId];
        if (serverMember == null ||
            serverMember['role'] != memberRole ||
            memberState !=
                (serverMember['state'] == 'revoked' ? 'revoked' : 'active')) {
          throw FormatException(currentL10n.theSignedMembershipListDoesntMatch);
        }
        if (memberId == userId) {
          signedMember['role'] = transferOwnership
              ? 'owner'
              : revoke
              ? targetRole
              : role;
          signedMember['state'] = revoke ? 'revoked' : 'active';
        } else if (transferOwnership && memberId == currentAccount.accountId) {
          signedMember['role'] = 'editor';
          signedMember['state'] = 'active';
        }
        memberEntries.add(signedMember);
      }
      if (!seenMembers.containsAll(membersByUser.keys)) {
        throw FormatException(currentL10n.theSignedMembershipListIsMissing);
      }

      final nextEpoch = currentEpoch + 1;
      final nextVersion = currentVersion + 1;
      nextVaultKey = crypto.randomBytes(32);
      final currentVaultName = _knownNames[vault.id];
      if (currentVaultName == null || currentVaultName.trim().isEmpty) {
        throw StateError(currentL10n.theVaultNameHasntBeenVerified2);
      }
      nextDisplayNameEnvelope = await crypto.encryptVaultName(
        vaultId: vault.id,
        vaultKey: nextVaultKey,
        name: currentVaultName,
      );
      final nextManifest = Map<String, Object?>.from(latest.manifest)
        ..remove('ownership_transfer')
        ..['key_epoch'] = nextEpoch
        ..['display_name_envelope'] = nextDisplayNameEnvelope
        ..['members'] = memberEntries
        ..['signer_device_id'] = currentIdentity.deviceId;
      if (transferOwnership) {
        nextManifest['ownership_transfer'] = {
          'from_user_id': currentAccount.accountId,
          'to_user_id': userId,
        };
      }
      final signedMembership = crypto.createMembershipGrant(
        vaultId: vault.id,
        membershipVersion: nextVersion,
        previousDigest: latest.digest,
        manifest: nextManifest,
        signer: currentIdentity,
      );
      final keyEnvelopes = <Map<String, Object?>>[];
      final recipientIds = <String>{};
      for (final member in memberEntries) {
        if (member['state'] != 'active') continue;
        final memberId = member['user_id']! as String;
        for (final device in directory.values) {
          if (device['user_id'] != memberId || device['status'] != 'active') {
            continue;
          }
          final deviceId = device['device_id']! as String;
          final encryptionText = device['encryption_public_key'];
          if (encryptionText is! String || !recipientIds.add(deviceId)) {
            throw FormatException(
              currentL10n.theKeyEnvelopeTargetForDevice(deviceId),
            );
          }
          final encryptionKey = decodeBase64Url(encryptionText);
          if (encryptionKey.length != 32) {
            throw FormatException(
              currentL10n.theEncryptionPublicKeyOfDevice(deviceId),
            );
          }
          final envelope = crypto.createDeviceKeyEnvelope(
            vaultId: vault.id,
            vaultKey: nextVaultKey,
            keyEpoch: nextEpoch,
            membershipVersion: nextVersion,
            recipientDeviceId: deviceId,
            recipientEncryptionPublicKey: encryptionKey,
            signer: currentIdentity,
          )..remove('vault_id');
          keyEnvelopes.add({
            ...envelope,
            'signer_device_id': currentIdentity.deviceId,
          });
        }
      }
      if (!recipientIds.contains(currentIdentity.deviceId)) {
        throw FormatException(currentL10n.theCurrentOwnerDeviceIsntIn);
      }
      if (transferOwnership &&
          !recipientIds.any(
            (deviceId) => directory[deviceId]?['user_id'] == userId,
          )) {
        throw StateError(currentL10n.theTargetMemberHasNoActive);
      }
      final pendingInvitations = membersByUser.values
          .where(
            (member) =>
                member['state'] == 'invited' &&
                (!revoke || member['user_id'] != userId),
          )
          .length;

      requestSubmitted = true;
      _traceSafeTeamLifecycle('rotation.commit.start');
      final rotationBody = <String, Object?>{
        'new_epoch': nextEpoch,
        'membership': signedMembership,
        'key_envelopes': keyEnvelopes,
      };
      final response = transferOwnership
          ? await client.transferVaultOwnership(vault.id, {
              ...rotationBody,
              'new_owner_user_id': userId,
            })
          : await client.rotateVaultKey(vault.id, rotationBody);
      _traceSafeTeamLifecycle('rotation.commit.done');
      if (response['vault_id'] != vault.id ||
          _membershipCounter(response['active_key_epoch']) != nextEpoch ||
          _membershipCounter(response['membership_version']) != nextVersion ||
          response['owner_user_id'] !=
              (transferOwnership ? userId : currentAccount.accountId)) {
        throw FormatException(currentL10n.theServerRotationResultDoesntMatch);
      }

      _traceSafeTeamLifecycle('rotation.reload.start');
      await _reloadVaultsForMembershipHintInternal();
      _traceSafeTeamLifecycle('rotation.reload.done');
      _traceSafeTeamLifecycle('rotation.members.after.start');
      await refreshVaultMembers(vaultId: vault.id);
      _traceSafeTeamLifecycle('rotation.members.after.done');
      if (!_vaultRotationIsVisible(
        vaultId: vault.id,
        userId: userId,
        targetRole: expectedTargetRole,
        targetState: revoke ? 'revoked' : 'active',
        currentActorRole: transferOwnership ? 'editor' : 'owner',
        epoch: nextEpoch,
        version: nextVersion,
        key: nextVaultKey,
        displayNameEnvelope: nextDisplayNameEnvelope,
      )) {
        throw FormatException(currentL10n.theServerCommittedTheMemberRotation);
      }
      errorMessage = null;
      _setNotice(
        transferOwnership
            ? currentL10n.vaultOwnershipWasTransferredThisAccount
            : revoke
            ? pendingInvitations == 0
                  ? currentL10n.memberAccessWasRevokedAndThe3
                  : currentL10n.memberAccessWasRevokedAndThe
            : pendingInvitations == 0
            ? currentL10n.theMemberRoleWasUpdatedAnd
            : currentL10n.theMemberRoleWasUpdatedAnd2,
      );
    } catch (error) {
      _traceSafeTeamLifecycle('rotation.error', error);
      originalError = true;
      if (requestSubmitted && nextVaultKey != null) {
        try {
          final remoteVault = (await _requireApi().vaults())
              .where((item) => item.id == vault.id)
              .firstOrNull;
          final oldEpoch = int.parse(vault.activeKeyEpoch);
          final oldVersion = int.parse(vault.membershipVersion);
          final remoteEpoch = int.tryParse(remoteVault?.activeKeyEpoch ?? '');
          final remoteVersion = int.tryParse(
            remoteVault?.membershipVersion ?? '',
          );
          if (remoteEpoch == oldEpoch && remoteVersion == oldVersion) {
            try {
              await refreshVaultMembers(vaultId: vault.id);
            } catch (_) {}
          } else if (remoteEpoch == oldEpoch + 1 &&
              remoteVersion == oldVersion + 1) {
            await _reloadVaultsForMembershipHintInternal();
            await refreshVaultMembers(vaultId: vault.id);
            if (!_vaultRotationIsVisible(
              vaultId: vault.id,
              userId: userId,
              targetRole: expectedTargetRole!,
              targetState: revoke ? 'revoked' : 'active',
              currentActorRole: transferOwnership ? 'editor' : 'owner',
              epoch: oldEpoch + 1,
              version: oldVersion + 1,
              key: nextVaultKey,
              displayNameEnvelope: nextDisplayNameEnvelope!,
            )) {
              throw FormatException(
                currentL10n.serverCommittedTheRotationButThe,
              );
            }
            errorMessage = null;
            _setNotice(
              transferOwnership
                  ? currentL10n.theServerCommittedTheVaultOwnership
                  : revoke
                  ? currentL10n.memberAccessWasRevokedAndThe2
                  : currentL10n.memberRoleUpdatedTheServerCommitted,
            );
            originalError = false;
          } else {
            throw FormatException(
              currentL10n.serverStateAdvancedUnexpectedlyDuringRotation,
            );
          }
        } catch (_) {
          await _clearLocalAuthenticatedState();
          final recoveryError = currentL10n.theMemberRotationResultCantBe;
          errorMessage = recoveryError;
          notifyListeners();
          throw StateError(recoveryError);
        }
      }
      if (originalError) {
        errorMessage = friendlyError(error);
        notifyListeners();
        rethrow;
      }
    } finally {
      _traceSafeTeamLifecycle('rotation.finally.start');
      if (nextVaultKey != null)
        nextVaultKey.fillRange(0, nextVaultKey.length, 0);
      final deferredSyncHint = _deferredSyncHintDuringMembershipChange;
      _deferredSyncHintDuringMembershipChange = null;
      _vaultMembershipChangeActive = false;
      vaultMembershipBusy = false;
      _automaticSync.start();
      notifyListeners();
      if (deferredSyncHint != null &&
          authenticated &&
          stage == ClientStage.workspace) {
        final replay = _replayDeferredSyncHint(deferredSyncHint);
        _deferredSyncHintReplayFuture = replay;
        unawaited(replay);
      }
      _traceSafeTeamLifecycle('rotation.finally.done');
    }
  }

  bool _vaultRotationIsVisible({
    required String vaultId,
    required String userId,
    required String targetRole,
    required String targetState,
    required String currentActorRole,
    required int epoch,
    required int version,
    required Uint8List key,
    required Map<String, Object?> displayNameEnvelope,
  }) {
    final descriptor = _vaultDescriptors
        .where((item) => item.id == vaultId)
        .firstOrNull;
    if (descriptor == null ||
        descriptor.role != currentActorRole ||
        descriptor.activeKeyEpoch != '$epoch' ||
        descriptor.membershipVersion != '$version' ||
        descriptor.encryptedDisplayNameEnvelope == null ||
        canonicalJson(descriptor.encryptedDisplayNameEnvelope) !=
            canonicalJson(displayNameEnvelope)) {
      return false;
    }
    final loadedKey =
        _vaultEpochKeys[vaultId]?[_vaultVersionKey('$epoch', '$version')];
    if (loadedKey == null || !_sameArchiveBytes(loadedKey, key)) return false;
    final member = vaultMembers
        .where((item) => item['user_id'] == userId)
        .firstOrNull;
    return member != null &&
        member['role'] == targetRole &&
        member['state'] == targetState;
  }

  int? _membershipCounter(Object? value) {
    if (value is int && value > 0) return value;
    if (value is num && value.isFinite && value > 0 && value == value.round()) {
      return value.toInt();
    }
    return null;
  }

  Future<void> acceptVaultInvitation(String token) async {
    _assertEditsAllowed();
    final invitationToken = token.trim();
    if (invitationToken.isEmpty) {
      throw FormatException(currentL10n.enterTheInvitationToken);
    }
    if (session == null || identity == null || account == null) {
      throw StateError(currentL10n.signInAndUnlockTheAccount);
    }
    if (_vaultInvitationAcceptanceCompletion != null) {
      throw StateError(currentL10n.anotherVaultMemberInvitationIsBeing);
    }
    // Membership hints can start a sync even while AutoSync's timers are
    // stopped. Hold their handlers for the entire acceptance transaction so
    // no request can retain the old Personal Vault repository between the
    // invite response and the selected-Vault pull.
    final acceptance = Completer<void>();
    _vaultInvitationAcceptanceCompletion = acceptance;
    _automaticSync.stop();
    try {
      // Preserve pending writes before changing the active Vault. synchronize
      // serializes with a pass that was already running when acceptance began.
      await synchronize();
      final accepted = await _requireApi().acceptInvitation(
        invitationToken,
        const {},
      );
      final acceptedVaultId = accepted['vault_id'] as String?;
      if (acceptedVaultId == null || acceptedVaultId.isEmpty) {
        throw FormatException(currentL10n.theServerDidntReturnTheVault);
      }
      await _loadVaults(session!, preferredVaultId: acceptedVaultId);
      if (!_vaultDescriptors.any((vault) => vault.id == acceptedVaultId)) {
        throw StateError(currentL10n.theInvitationWasAcceptedButThis2);
      }
      await selectVault(acceptedVaultId);
      if (activeVault?.id != acceptedVaultId ||
          _repository?.vaultId != acceptedVaultId) {
        throw StateError(currentL10n.theInvitationWasAcceptedButThis);
      }
      await synchronize(background: true);
      _setNotice(currentL10n.memberInvitationAcceptedTheVaultIs);
    } finally {
      if (identical(_vaultInvitationAcceptanceCompletion, acceptance)) {
        _vaultInvitationAcceptanceCompletion = null;
      }
      if (!acceptance.isCompleted) acceptance.complete();
      _automaticSync.start();
    }
  }

  Future<String> createDeviceEnrollmentRequest({
    required String username,
    String name = 'Atermius Web',
  }) async {
    final client = _requireApi();
    if (username.trim().isEmpty) {
      throw FormatException(currentL10n.enterTheAccountEmailUserName);
    }
    final prelogin = await client.prelogin(username.trim());
    final accountId = prelogin['account_id'] as String?;
    if (accountId == null || accountId.isEmpty) {
      throw FormatException(currentL10n.theServerDidntReturnAnAccount);
    }
    final capabilityReportsSupported =
        instance?.capabilities.contains('device_capability_reports') ?? false;
    final pending = DeviceIdentity.create(sodium);
    await secureStore.savePendingDevice(
      client.baseUrl,
      pending,
      accountId: accountId,
    );
    final proof = pending.registrationProof(
      sodium,
      accountId: accountId,
      name: name.trim().isEmpty ? 'Atermius Web' : name.trim(),
    );
    final capabilityReport = capabilityReportsSupported
        ? _signDeviceCapabilityReport({
            'account_id': accountId,
            'device_id': pending.deviceId,
            'revision': _clientDeviceCapabilityRevision,
            'max_record_schema': _clientMaxRecordSchema,
            'host_attachment_manifest_versions':
                _clientAttachmentManifestVersions,
            'max_attachment_bytes': _clientMaxAttachmentBytes,
          }, pending)
        : null;
    final enrollment = {
      'format': 'atermius-device-enrollment-v1',
      'account_id': accountId,
      'device': proof,
      if (capabilityReport != null) 'capability_report': capabilityReport,
    };
    pending.dispose();
    return const JsonEncoder.withIndent('  ').convert(enrollment);
  }

  Future<String> approveDeviceEnrollment(String enrollmentJson) async {
    _assertEditsAllowed();
    if (_vaultDescriptors.any((vault) => vault.status == 'deleting')) {
      throw StateError(currentL10n.aVaultIsInItsDeletion);
    }
    final decoded = jsonDecode(enrollmentJson);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'atermius-device-enrollment-v1' ||
        decoded['account_id'] != account?.accountId ||
        decoded['device'] is! Map) {
      throw FormatException(currentL10n.theDeviceRequestIsMalformedOr);
    }
    final accountId = account!.accountId;
    final currentInstanceId = instance?.instanceId;
    if (currentInstanceId == null) {
      throw StateError(currentL10n.noServerInstanceIsConfiguredYet);
    }
    final publicCard = crypto.verifyDeviceProof(
      accountId: accountId,
      instanceId: currentInstanceId,
      device: Map<String, dynamic>.from(decoded['device'] as Map),
    );
    final device = Map<String, dynamic>.from(publicCard.device);
    final rawCapabilityReport = decoded['capability_report'];
    final capabilityReport = rawCapabilityReport is Map
        ? Map<String, Object?>.from(rawCapabilityReport)
        : null;

    final certificatePayload = <String, Object?>{
      'account_id': accountId,
      'approver_device_id': identity!.deviceId,
      'device': device,
    };
    final certificate = sodium.crypto.sign.detached(
      message: Uint8List.fromList(
        utf8.encode(canonicalJson(certificatePayload)),
      ),
      secretKey: identity!.signing.secretKey,
    );
    final recipientId = publicCard.deviceId;
    final recipientEncryptionKey = publicCard.encryptionPublicKey;
    final envelopes = <Map<String, Object?>>[];
    var expectedEnvelopeCount = 0;
    for (final vault in _vaultDescriptors) {
      final epochKeys =
          _vaultEpochKeys[vault.id] ?? const <String, Uint8List>{};
      final heldByApprover = vault.keyEnvelopes
          .where((item) => item['recipient_device_id'] == identity!.deviceId)
          .toList(growable: false);
      if (!heldByApprover.any(
        (item) => item['key_epoch']?.toString() == vault.activeKeyEpoch,
      )) {
        throw StateError(currentL10n.theCurrentKeyEpochOfVault(vault.id));
      }
      expectedEnvelopeCount += heldByApprover.length;
      for (final heldEnvelope in heldByApprover) {
        final epoch =
            (heldEnvelope['key_epoch'] as num?)?.toInt() ??
            int.parse(vault.activeKeyEpoch);
        final membershipVersion =
            (heldEnvelope['membership_version'] as num?)?.toInt() ??
            int.parse(vault.membershipVersion);
        final key = epochKeys[_vaultVersionKey('$epoch', '$membershipVersion')];
        if (key == null) {
          throw StateError(
            currentL10n.theEpochEpochKeyForVault(vault.id, epoch),
          );
        }
        envelopes.add(
          crypto.createDeviceKeyEnvelope(
            vaultId: vault.id,
            vaultKey: key,
            keyEpoch: epoch,
            membershipVersion: membershipVersion,
            recipientDeviceId: recipientId,
            recipientEncryptionPublicKey: recipientEncryptionKey,
            signer: identity!,
          ),
        );
      }
    }
    if (envelopes.length != expectedEnvelopeCount ||
        expectedEnvelopeCount < _vaultDescriptors.length) {
      throw StateError(currentL10n.thisDeviceDoesntHaveKeysFor);
    }
    await _requireApi().registerDevice({
      'device': device,
      if (capabilityReport != null) 'capability_report': capabilityReport,
      'approver_device_id': identity!.deviceId,
      'certificate_signature': encodeBase64Url(certificate),
      'vault_key_envelopes': envelopes,
    });
    _setNotice(currentL10n.deviceAddedGiveTheApprovalResult);
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'atermius-device-approval-v1',
      'account_id': accountId,
      'device': device,
      if (capabilityReport != null) 'capability_report': capabilityReport,
      'approver_device_id': identity!.deviceId,
      'certificate_signature': encodeBase64Url(certificate),
      'vault_key_envelopes': envelopes,
    });
  }

  Future<void> importDeviceApproval(String approvalJson) async {
    final decoded = jsonDecode(approvalJson);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'atermius-device-approval-v1' ||
        decoded['device'] is! Map ||
        decoded['vault_key_envelopes'] is! List) {
      throw FormatException(currentL10n.theDeviceApprovalFileHasAn);
    }
    final client = _requireApi();
    final pending = await secureStore.loadPendingDevice(client.baseUrl, crypto);
    if (pending == null) {
      throw StateError(currentL10n.thisBrowserHasNoDeviceKey);
    }
    final accountId = await secureStore.pendingAccountId(client.baseUrl);
    try {
      final device = Map<String, dynamic>.from(decoded['device'] as Map);
      final instanceId = instance?.instanceId;
      if (accountId == null ||
          instanceId == null ||
          decoded['account_id'] != accountId) {
        throw FormatException(currentL10n.theApprovalFileBelongsToA);
      }
      final card = crypto.verifyDeviceProof(
        accountId: accountId,
        instanceId: instanceId,
        device: device,
      );
      if (card.deviceId != pending.deviceId ||
          !listEquals(card.signingPublicKey, pending.signing.publicKey) ||
          !listEquals(card.encryptionPublicKey, pending.encryption.publicKey)) {
        throw FormatException(currentL10n.theApprovalFileDoesntMatchThe);
      }
      final approverId = decoded['approver_device_id'];
      final certificate = decoded['certificate_signature'];
      if (approverId is! String ||
          !_isCanonicalUuid(approverId) ||
          approverId == pending.deviceId ||
          certificate is! String ||
          decodeBase64Url(certificate).length != 64) {
        throw FormatException(
          currentL10n.theApproverCertificateFieldsAreInvalid,
        );
      }
      final envelopes = decoded['vault_key_envelopes'] as List;
      final uniqueContexts = <String>{};
      for (final rawEnvelope in envelopes) {
        if (rawEnvelope is! Map) {
          throw FormatException(currentL10n.theVaultKeyEnvelopeInThe2);
        }
        final envelope = Map<String, dynamic>.from(rawEnvelope);
        final vaultId = envelope['vault_id'];
        final epoch = envelope['key_epoch'];
        final version = envelope['membership_version'];
        final signature = envelope['signature'];
        final boxed = envelope['envelope'];
        if (vaultId is! String ||
            !_isCanonicalUuid(vaultId) ||
            envelope['recipient_device_id'] != pending.deviceId ||
            epoch is! int ||
            epoch < 1 ||
            version is! int ||
            version < 1 ||
            signature is! String ||
            decodeBase64Url(signature).length != 64 ||
            boxed is! Map ||
            boxed['version'] != 1 ||
            boxed['suite'] != 'crypto_box_seal' ||
            boxed['ciphertext'] is! String) {
          throw FormatException(currentL10n.theVaultKeyEnvelopeContextIn);
        }
        if (!uniqueContexts.add('$vaultId:$epoch:$version')) {
          throw FormatException(
            currentL10n.theApprovalFileContainsDuplicateVault,
          );
        }
      }
      await secureStore.savePendingDeviceApproval(client.baseUrl, approvalJson);
      try {
        await secureStore.saveDevice(client.baseUrl, pending);
      } catch (_) {
        await secureStore.clearPendingDeviceApproval(client.baseUrl);
        rethrow;
      }
      stage = ClientStage.login;
      _setNotice(currentL10n.theApprovalFileIsStagedAfter);
    } finally {
      pending.dispose();
    }
  }

  Future<void> revokeDevice(String deviceId) async {
    if (deviceId == identity?.deviceId) {
      throw StateError(currentL10n.youCantRevokeThisDeviceFrom);
    }
    await _requireApi().revokeDevice(deviceId);
    await refreshDevices();
    if (activeVault != null) await refreshVaultDeviceRows();
    _setNotice(currentL10n.deviceRevoked2);
  }

  /// Creates the signed, device-encrypted payload for a migration destination
  /// without sending it to the server. The source LocalVault journal must
  /// durably stage this exact payload before [createOrResumeMigrationVault]
  /// performs the first network write.
  Future<({String vaultId, String payloadJson})> prepareMigrationVaultCreation(
    String name,
  ) async {
    _assertEditsAllowed();
    final currentAccount = account;
    final currentIdentity = identity;
    if (!authenticated || currentAccount == null || currentIdentity == null) {
      throw StateError(currentL10n.signInAndUnlockTheSync);
    }
    if (name.trim().isEmpty) {
      throw FormatException(currentL10n.enterANameForTheNew);
    }
    final material = await crypto.createInitialVault(
      accountId: currentAccount.accountId,
      name: name.trim(),
      identity: currentIdentity,
    );
    try {
      return (
        vaultId: material.vaultId,
        payloadJson: canonicalJson(material.payload),
      );
    } finally {
      material.vaultKey.fillRange(0, material.vaultKey.length, 0);
    }
  }

  /// Ensures a staged new-Vault payload exists on the server. If the create
  /// request had an uncertain response, the method lists Vaults and verifies
  /// the exact signed membership, name envelope, and this device's key
  /// envelope before accepting the existing result. It never generates a
  /// replacement Vault ID or submits different creation bytes.
  Future<void> createOrResumeMigrationVault({
    required String vaultId,
    required String payloadJson,
  }) async {
    _assertEditsAllowed();
    if (!_isCanonicalUuid(vaultId)) {
      throw FormatException(currentL10n.invalidMigrationDestinationVaultId);
    }
    final currentSession = session;
    final currentAccount = account;
    final currentIdentity = identity;
    if (!authenticated ||
        currentSession == null ||
        currentAccount == null ||
        currentIdentity == null) {
      throw StateError(currentL10n.signInAndUnlockTheSync);
    }
    final decoded = jsonDecode(payloadJson);
    if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
      throw FormatException(currentL10n.theStagedVaultCreationDataHas);
    }
    final payload = Map<String, Object?>.from(decoded);
    if (payload['vault_id'] != vaultId ||
        payload['key_epoch'] != 1 ||
        payload['membership_version'] != 1 ||
        payload['name_envelope'] is! Map ||
        payload['key_envelope'] is! Map ||
        payload['membership'] is! Map) {
      throw FormatException(currentL10n.theStagedVaultCreationDataDoesnt);
    }
    final client = _requireApi();
    var exists = await _matchesStagedMigrationVault(client, vaultId, payload);
    if (!exists) {
      try {
        final response = await client.createVault(payload);
        if (response['vault_id'] != vaultId) {
          throw FormatException(
            currentL10n.theServerReturnedADifferentMigration,
          );
        }
      } on FormatException {
        rethrow;
      } on Object catch (createError, stackTrace) {
        // POST can commit even when its response is lost. Reconcile against
        // the exact signed creation material before deciding whether a retry
        // is safe. A missing Vault leaves the journal resumable; a mismatch
        // fails closed and is never overwritten.
        try {
          exists = await _matchesStagedMigrationVault(client, vaultId, payload);
        } on FormatException {
          rethrow;
        } on Object {
          throw StateError(currentL10n.theVaultCreationResultCantBe);
        }
        if (!exists) Error.throwWithStackTrace(createError, stackTrace);
      }
    }

    if (!exists) {
      exists = await _matchesStagedMigrationVault(client, vaultId, payload);
      if (!exists) {
        throw StateError(currentL10n.vaultCreationReturnedSuccessButThe);
      }
    }

    await _loadVaults(currentSession);
    final verified = _vaultDescriptors
        .where((item) => item.id == vaultId)
        .firstOrNull;
    if (verified == null ||
        verified.role != 'owner' ||
        !verified.canWrite ||
        verified.status != 'active') {
      throw StateError(currentL10n.theMigrationDestinationVaultCouldntBe);
    }
    await selectVault(vaultId);
    if (activeVault?.id != vaultId || _repository?.vaultId != vaultId) {
      throw StateError(currentL10n.theMigrationDestinationVaultCouldntBe2);
    }
  }

  Future<bool> _matchesStagedMigrationVault(
    ApiClient client,
    String vaultId,
    Map<String, Object?> payload,
  ) async {
    final listed = await client.vaults();
    final matches = listed.where((item) => item.id == vaultId).toList();
    if (matches.isEmpty) return false;
    if (matches.length != 1) {
      throw FormatException(
        currentL10n.theServerReturnedDuplicateMigrationDestination,
      );
    }
    final descriptor = matches.single;
    if (descriptor.status != 'active' ||
        descriptor.role != 'owner' ||
        !descriptor.canWrite ||
        canonicalJson(descriptor.encryptedDisplayNameEnvelope) !=
            canonicalJson(payload['name_envelope'])) {
      throw FormatException(currentL10n.aVaultWithThisIdAlready);
    }

    final expectedKey = Map<String, dynamic>.from(
      payload['key_envelope']! as Map,
    );
    final matchingKeyEnvelopes = descriptor.keyEnvelopes.where((envelope) {
      for (final field in const [
        'recipient_device_id',
        'key_epoch',
        'membership_version',
        'envelope',
        'signature',
      ]) {
        if (canonicalJson(envelope[field]) !=
            canonicalJson(expectedKey[field])) {
          return false;
        }
      }
      return true;
    });
    if (!matchingKeyEnvelopes.any(
      (envelope) => envelope['recipient_device_id'] == identity?.deviceId,
    )) {
      throw FormatException(currentL10n.theServerVaultKeyEnvelopeDoesnt);
    }

    final membershipResponse = await client.membership(vaultId);
    final rawManifests = membershipResponse['manifests'];
    if (rawManifests is! List ||
        rawManifests.isEmpty ||
        rawManifests.first is! Map) {
      throw FormatException(currentL10n.theMigrationDestinationVaultIsMissing);
    }
    final serverMembership = Map<String, dynamic>.from(
      rawManifests.first as Map,
    );
    if (serverMembership['membership_version'] != 1) {
      throw FormatException(currentL10n.theServerMembershipChainBelongsTo);
    }
    final expectedMembership = Map<String, dynamic>.from(
      payload['membership']! as Map,
    );
    final expectedManifestBody = expectedMembership['manifest'];
    final rawServerRecord = serverMembership['manifest'];
    if (expectedManifestBody is! Map ||
        expectedManifestBody.keys.any((key) => key is! String) ||
        rawServerRecord is! Map ||
        rawServerRecord.keys.any((key) => key is! String)) {
      throw FormatException(currentL10n.theServersInitialVaultMembershipRecord);
    }
    // The membership API wraps each signed record in a page row whose
    // `manifest` field is itself the signed wrapper. Compare that complete
    // inner record with the durably staged creation material; comparing the
    // outer `manifest` map directly to the raw body rejects every new Vault.
    final expectedSignedRecord = <String, Object?>{
      'vault_id': vaultId,
      'membership_version': expectedMembership['membership_version'],
      'previous_digest': expectedMembership['previous_digest'],
      'manifest': expectedManifestBody,
      'signature': expectedMembership['signature'],
    };
    final actualSignedRecord = Map<String, Object?>.from(rawServerRecord);
    if (serverMembership['membership_version'] !=
            expectedMembership['membership_version'] ||
        serverMembership['previous_digest'] !=
            expectedMembership['previous_digest'] ||
        serverMembership['signature'] != expectedMembership['signature'] ||
        serverMembership['signer_device_id'] !=
            expectedManifestBody['signer_device_id'] ||
        canonicalJson(actualSignedRecord) !=
            canonicalJson(expectedSignedRecord)) {
      throw FormatException(currentL10n.theServerVaultMembershipChainDoesnt);
    }
    return true;
  }

  /// Encrypts one local business record under the active migration target
  /// Vault. The caller must stage the returned exact envelope in the source
  /// journal before inserting it into the destination outbox.
  Future<Map<String, Object?>> encryptMigrationRecord({
    required String targetVaultId,
    required String recordId,
    required Map<String, Object?> plaintext,
  }) async {
    _assertEditsAllowed(requireWritableVault: true);
    if (activeVault?.id != targetVaultId ||
        _repository?.vaultId != targetVaultId ||
        activeVault?.status != 'active') {
      throw StateError(currentL10n.theSyncVaultWasSwitchedOr);
    }
    if (!_isCanonicalUuid(recordId)) {
      throw FormatException(currentL10n.invalidMigrationRecordId);
    }
    return _requireRepository().encryptOperation(
      recordId: recordId,
      plaintext: plaintext,
      baseRevisionId: null,
      operation: 'create',
    );
  }

  /// Replays a source-journaled exact encrypted create into the target outbox.
  /// This deliberately avoids normal saveRecord compaction and is safe to call
  /// after crashes, ambiguous network responses, or a prior successful commit.
  Future<ExactCreateOperationResult> enqueueMigrationEnvelope({
    required String targetVaultId,
    required Map<String, Object?> envelope,
  }) async {
    _assertEditsAllowed(requireWritableVault: true);
    final currentIdentity = identity;
    if (activeVault?.id != targetVaultId ||
        _repository?.vaultId != targetVaultId ||
        currentIdentity == null ||
        activeVault?.status != 'active') {
      throw StateError(currentL10n.theSyncVaultWasSwitchedOr);
    }
    final result = await database.putExactCreateOperation(
      vaultId: targetVaultId,
      deviceId: currentIdentity.deviceId,
      envelope: envelope,
      instanceId: _requireRepository().instanceId,
      serverSpaceId: _requireRepository().serverSpaceId,
    );
    await refreshSyncStatus();
    if (result != ExactCreateOperationResult.committed) {
      _automaticSync.scheduleEdit();
    }
    notifyListeners();
    return result;
  }

  Future<void> createVault(String name) async {
    await createVaultInScope(name);
  }

  /// Creates a Vault for the signed-in session that started the call and
  /// selects it unless the user requested another selection meanwhile.
  ///
  /// The client, account and device are captured before any await. If the
  /// session ends or the server/account changes before dispatch, nothing is
  /// sent; if it changes while the request is in flight, the generated key
  /// is wiped and nothing is installed into the newer session
  /// ([OperationScopeEndedException.serverCommitted] reports the created
  /// Vault honestly). `selection` is the token of this call's own selection
  /// ([vaultSelectionToken]) or null when it did not select the Vault.
  Future<({String vaultId, Object? selection})> createVaultInScope(
    String name,
  ) async {
    _assertEditsAllowed();
    if (name.trim().isEmpty) throw FormatException(currentL10n.enterAVaultName);
    final client = _requireApi();
    final currentAccount = account!;
    final currentIdentity = identity!;
    final auth = authScopeToken;
    final selectionAtStart = vaultSelectionToken;
    bool sessionIsCurrent() =>
        !_controllerDisposed &&
        identical(api, client) &&
        authScopeToken == auth &&
        account?.accountId == currentAccount.accountId &&
        identity?.deviceId == currentIdentity.deviceId;
    final material = await crypto.createInitialVault(
      accountId: currentAccount.accountId,
      name: name.trim(),
      identity: currentIdentity,
    );
    void wipe() => material.vaultKey.fillRange(0, material.vaultKey.length, 0);
    if (!sessionIsCurrent()) {
      wipe();
      throw const OperationScopeEndedException(serverCommitted: false);
    }
    try {
      await client.createVault(material.payload);
    } catch (_) {
      wipe();
      rethrow;
    }
    if (!sessionIsCurrent()) {
      wipe();
      throw const OperationScopeEndedException(serverCommitted: true);
    }
    final payload = material.payload;
    final descriptor = VaultDescriptor(
      id: material.vaultId,
      role: 'owner',
      activeKeyEpoch: '1',
      membershipVersion: '1',
      encryptedDisplayNameEnvelope: Map<String, dynamic>.from(
        payload['name_envelope'] as Map,
      ),
      keyEnvelopes: [Map<String, dynamic>.from(payload['key_envelope'] as Map)],
    );
    _vaultKeys[material.vaultId] = material.vaultKey;
    _vaultEpochKeys[material.vaultId] = {
      _vaultVersionKey('1', '1'): material.vaultKey,
    };
    _knownNames[material.vaultId] = name.trim();
    _vaultDescriptors = [..._vaultDescriptors, descriptor];
    unawaited(_refreshRecoveryContextsAndUpload());
    _setNotice(currentL10n.vaultCreatedItsKeyWasGenerated);
    // Never select the new Vault over a selection the user requested while
    // the Vault was being created.
    if (vaultSelectionToken != selectionAtStart) {
      return (vaultId: material.vaultId, selection: null);
    }
    return (
      vaultId: material.vaultId,
      selection: await selectVaultForOperation(material.vaultId),
    );
  }

  Future<VaultDescriptor> scheduleVaultDeletion({
    required String vaultId,
    required String username,
    required String password,
  }) => _changeVaultDeletionState(
    vaultId: vaultId,
    username: username,
    password: password,
    cancel: false,
  );

  Future<VaultDescriptor> cancelVaultDeletion({
    required String vaultId,
    required String username,
    required String password,
  }) => _changeVaultDeletionState(
    vaultId: vaultId,
    username: username,
    password: password,
    cancel: true,
  );

  Future<AccountMfaStatus> refreshAccountMfaStatus() async {
    final currentAccount = account;
    final currentSession = session;
    if (currentAccount == null ||
        currentSession == null ||
        currentAccount.accountId != currentSession.accountId) {
      throw StateError(currentL10n.signInBeforeViewingMfaSettings);
    }
    if (accountMfaBusy) {
      throw StateError(currentL10n.mfaSettingsAreBeingProcessed);
    }
    accountMfaBusy = true;
    notifyListeners();
    try {
      final status = await _requireApi().accountMfaStatus();
      accountMfaEnabled = status.enabled;
      accountMfaRecoveryCodesRemaining = status.recoveryCodesRemaining;
      return status;
    } finally {
      accountMfaBusy = false;
      notifyListeners();
    }
  }

  Future<MfaTotpSetup> beginMfaTotpSetup({required String currentPassword}) =>
      _withCurrentMfaVerifier(
        currentPassword,
        (client, verifier) => client.setupMfaTotp(verifier),
      );

  Future<MfaRecoveryCodes> confirmMfaTotp({
    required String currentPassword,
    required String totpCode,
  }) async {
    final result = await _withCurrentMfaVerifier(
      currentPassword,
      (client, verifier) => client.confirmMfaTotp(
        currentLoginVerifier: verifier,
        totpCode: totpCode,
      ),
    );
    accountMfaEnabled = true;
    accountMfaRecoveryCodesRemaining = result.codes.length;
    notifyListeners();
    return result;
  }

  Future<MfaRecoveryCodes> rotateMfaRecoveryCodes({
    required String currentPassword,
    required String totpCode,
  }) async {
    final result = await _withCurrentMfaVerifier(
      currentPassword,
      (client, verifier) => client.rotateMfaRecoveryCodes(
        currentLoginVerifier: verifier,
        totpCode: totpCode,
      ),
    );
    accountMfaEnabled = true;
    accountMfaRecoveryCodesRemaining = result.codes.length;
    notifyListeners();
    return result;
  }

  Future<void> disableMfaTotp({
    required String currentPassword,
    required String totpCode,
  }) async {
    final status = await _withCurrentMfaVerifier(
      currentPassword,
      (client, verifier) => client.disableMfaTotp(
        currentLoginVerifier: verifier,
        totpCode: totpCode,
      ),
    );
    accountMfaEnabled = status.enabled;
    accountMfaRecoveryCodesRemaining = status.recoveryCodesRemaining;
    notifyListeners();
  }

  Future<T> _withCurrentMfaVerifier<T>(
    String currentPassword,
    Future<T> Function(ApiClient client, String verifier) action,
  ) async {
    final currentAccount = account;
    final currentSession = session;
    final username = authenticatedUsername;
    if (currentAccount == null ||
        currentSession == null ||
        username == null ||
        currentAccount.accountId != currentSession.accountId) {
      throw StateError(currentL10n.signInBeforeChangingMfaSettings);
    }
    if (currentPassword.length < 12) {
      throw FormatException(currentL10n.enterTheCurrentMasterPassword);
    }
    if (accountMfaBusy || accountRecoveryBusy || accountLifecycleBusy) {
      throw StateError(currentL10n.accountSecuritySettingsAreBeingProcessed);
    }
    accountMfaBusy = true;
    errorMessage = null;
    noticeMessage = null;
    notifyListeners();
    KdfParameters? params;
    Uint8List? verifierBytes;
    try {
      final client = _requireApi();
      final prelogin = await client.prelogin(username);
      if (prelogin['account_id'] != currentAccount.accountId) {
        throw FormatException(
          currentL10n.theCurrentAccountVerificationDetailsDont,
        );
      }
      params = KdfParameters.fromJson(
        Map<String, dynamic>.from(prelogin['kdf'] as Map),
      );
      verifierBytes = await crypto.deriveLoginVerifier(currentPassword, params);
      return await action(client, encodeBase64Url(verifierBytes));
    } finally {
      verifierBytes?.fillRange(0, verifierBytes.length, 0);
      params?.salt.fillRange(0, params.salt.length, 0);
      accountMfaBusy = false;
      notifyListeners();
    }
  }

  Future<void> changeAccountPassword({
    required String currentPassword,
    required String newPassword,
    required String confirmationPassword,
  }) async {
    if (accountPasswordChangeBusy) {
      throw StateError(currentL10n.aMasterPasswordChangeIsIn2);
    }
    if (_pendingAccountPasswordChange != null) {
      throw StateError(currentL10n.aMasterPasswordChangeIsWaiting);
    }
    if (accountLifecycleBusy) {
      throw StateError(currentL10n.anAccountStateActionIsIn);
    }
    if (syncing || snapshotRecoveryActive) {
      throw StateError(currentL10n.theMasterPasswordCantBeChanged);
    }
    if (currentPassword.length < 12) {
      throw FormatException(currentL10n.theCurrentMasterPasswordMustBe);
    }
    if (newPassword.length < 12) {
      throw FormatException(currentL10n.theNewMasterPasswordMustBe);
    }
    if (newPassword != confirmationPassword) {
      throw FormatException(currentL10n.theNewMasterPasswordsDontMatch);
    }
    if (newPassword == currentPassword) {
      throw FormatException(currentL10n.theNewMasterPasswordMustDiffer);
    }

    final currentAccount = account;
    final currentSession = session;
    final username = authenticatedUsername;
    if (currentAccount == null || currentSession == null || username == null) {
      throw StateError(currentL10n.theresNoSignedInAccountWhose);
    }

    accountPasswordChangeBusy = true;
    errorMessage = null;
    noticeMessage = null;
    notifyListeners();
    KdfParameters? currentParams;
    KdfParameters? newParams;
    Uint8List? currentVerifier;
    Uint8List? newVerifier;
    Uint8List? accountKey;
    try {
      final client = _requireApi();
      final prelogin = await client.prelogin(username);
      if (prelogin['account_id'] != currentAccount.accountId) {
        throw FormatException(currentL10n.thisAccountNameDoesntMatchThe);
      }
      currentParams = KdfParameters.fromJson(
        Map<String, dynamic>.from(prelogin['kdf'] as Map),
      );
      currentVerifier = await crypto.deriveLoginVerifier(
        currentPassword,
        currentParams,
      );
      try {
        accountKey = await crypto.unwrapAccountKey(
          password: currentPassword,
          params: currentParams,
          envelope: currentAccount.accountKeyEnvelope,
        );
      } catch (_) {
        throw FormatException(currentL10n.theCurrentMasterPasswordOrAccount);
      }
      if (accountKey.length != 32) {
        throw FormatException(currentL10n.invalidAccountKeyLengthTheMaster);
      }

      newParams = KdfParameters.defaults(sodium);
      newVerifier = await crypto.deriveLoginVerifier(newPassword, newParams);
      final newEnvelope = await crypto.wrapAccountKey(
        password: newPassword,
        params: newParams,
        accountKey: accountKey,
      );
      final operationId = _uuid.v4().toLowerCase();
      final request = Map<String, Object?>.unmodifiable({
        'operation_id': operationId,
        'current_login_verifier': encodeBase64Url(currentVerifier),
        'new_kdf': Map<String, Object?>.unmodifiable(newParams.toJson()),
        'new_login_verifier': encodeBase64Url(newVerifier),
        'account_key_envelope': Map<String, Object?>.unmodifiable(
          Map<String, Object?>.from(newEnvelope),
        ),
      });
      final pending = _PendingAccountPasswordChange(
        accountId: currentAccount.accountId,
        deviceId: currentSession.deviceId,
        previousCredentialVersion: currentAccount.accountKeyEnvelopeVersion,
        operationId: operationId,
        request: request,
      );
      _pendingAccountPasswordChange = pending;
      notifyListeners();
      await _submitPendingAccountPasswordChange(pending);
    } catch (error) {
      errorMessage = _accountPasswordChangeFriendlyError(error);
      noticeMessage = null;
      notifyListeners();
      rethrow;
    } finally {
      currentVerifier?.fillRange(0, currentVerifier.length, 0);
      newVerifier?.fillRange(0, newVerifier.length, 0);
      accountKey?.fillRange(0, accountKey.length, 0);
      if (currentParams != null) {
        currentParams.salt.fillRange(0, currentParams.salt.length, 0);
      }
      if (newParams != null) {
        newParams.salt.fillRange(0, newParams.salt.length, 0);
      }
      accountPasswordChangeBusy = false;
      notifyListeners();
    }
  }

  Future<void> retryAccountPasswordChange() async {
    if (accountPasswordChangeBusy) {
      throw StateError(currentL10n.aMasterPasswordChangeIsIn2);
    }
    final pending = _pendingAccountPasswordChange;
    if (pending == null) {
      throw StateError(currentL10n.theresNoMasterPasswordChangeWaiting);
    }
    if (account?.accountId != pending.accountId ||
        session?.deviceId != pending.deviceId) {
      throw StateError(currentL10n.theSignedInAccountChangedSign);
    }
    accountPasswordChangeBusy = true;
    errorMessage = null;
    noticeMessage = null;
    notifyListeners();
    try {
      await _submitPendingAccountPasswordChange(pending);
    } catch (error) {
      errorMessage = _accountPasswordChangeFriendlyError(error);
      noticeMessage = null;
      notifyListeners();
      rethrow;
    } finally {
      accountPasswordChangeBusy = false;
      notifyListeners();
    }
  }

  Future<AccountRecoveryPreparation> prepareFullAccountRecovery({
    required String username,
    required String recoveryCode,
    required String newPassword,
    required String confirmationPassword,
    required String deviceName,
  }) async {
    if (session != null) {
      throw StateError(currentL10n.signOutBeforeStartingFullAccount);
    }
    if (_pendingFullAccountRecovery != null) {
      throw StateError(currentL10n.aRecoveryConfirmationIsAlreadyPending);
    }
    final normalizedUsername = username.trim().toLowerCase();
    if (normalizedUsername.isEmpty) {
      throw FormatException(currentL10n.enterTheAccountName);
    }
    if (newPassword.length < 12) {
      throw FormatException(currentL10n.theNewMasterPasswordMustContain);
    }
    if (newPassword != confirmationPassword) {
      throw FormatException(currentL10n.theNewMasterPasswordsDoNot);
    }
    if (accountRecoveryBusy) {
      throw StateError(currentL10n.accountRecoveryIsBusy);
    }
    accountRecoveryBusy = true;
    errorMessage = null;
    noticeMessage = null;
    notifyListeners();
    RecoveryIdentity? oldIdentity;
    RecoveryIdentity? nextIdentity;
    DeviceIdentity? newDevice;
    Uint8List? newAccountKey;
    Uint8List? newVerifier;
    KdfParameters? newParams;
    final recoveredVaultKeys = <String, Uint8List>{};
    try {
      final client = _requireApi();
      final start = await client.startAccountRecovery(normalizedUsername);
      final accountId = start['account_id'];
      final instanceId = start['instance_id'];
      final serverSpaceId = start['server_space_id'];
      final generationValue = start['recovery_generation'];
      final challengeId = start['challenge_id'];
      final challenge = start['challenge'];
      final expiresAtText = start['expires_at'];
      final recoverySigningPublic = start['recovery_public_signing_key'];
      final recoveryEncryptionPublic = start['recovery_public_encryption_key'];
      final recoveryEnvelope = start['recovery_envelope'];
      if (accountId is! String ||
          !_isCanonicalUuid(accountId) ||
          instanceId is! String ||
          !_isCanonicalUuid(instanceId) ||
          serverSpaceId is! String ||
          !_isCanonicalUuid(serverSpaceId) ||
          generationValue is! num ||
          generationValue < 1 ||
          challengeId is! String ||
          !_isCanonicalUuid(challengeId) ||
          challenge is! String ||
          expiresAtText is! String ||
          recoverySigningPublic is! String ||
          recoveryEncryptionPublic is! String ||
          recoveryEnvelope is! Map) {
        throw FormatException(currentL10n.recoveryCouldNotBeStartedCheck);
      }
      final generation = generationValue.toInt();
      final challengeBytes = decodeBase64Url(challenge);
      if (challengeBytes.length != 32 ||
          encodeBase64Url(challengeBytes) != challenge) {
        challengeBytes.fillRange(0, challengeBytes.length, 0);
        throw FormatException(currentL10n.recoveryCouldNotBeStartedCheck);
      }
      challengeBytes.fillRange(0, challengeBytes.length, 0);
      final expiry = DateTime.tryParse(expiresAtText)?.toUtc();
      if (expiry == null || !expiry.isAfter(DateTime.now().toUtc())) {
        throw FormatException(
          currentL10n.theRecoveryChallengeExpiredStartAgain,
        );
      }
      final configuredInstance = instance;
      if (configuredInstance == null ||
          configuredInstance.instanceId != instanceId ||
          configuredInstance.serverSpaceId != serverSpaceId) {
        throw FormatException(currentL10n.thisRecoveryCodeBelongsToAnother);
      }
      final descriptorHash = await recoveryCrypto.recoveryDescriptorHash(
        accountId: accountId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        generation: generation,
        signingPublicKey: recoverySigningPublic,
        encryptionPublicKey: recoveryEncryptionPublic,
      );
      oldIdentity = await recoveryCrypto.openIdentityWithRecoveryCode(
        envelope: Map<String, dynamic>.from(recoveryEnvelope),
        recoveryCode: recoveryCode,
        accountId: accountId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        generation: generation,
      );
      if (oldIdentity.signingPublicKey != recoverySigningPublic ||
          oldIdentity.encryptionPublicKey != recoveryEncryptionPublic) {
        throw FormatException(currentL10n.theRecoveryCodeOrServerDescriptor);
      }
      final inspectPayload = <String, Object?>{
        'protocol': 'atermius-account-recovery-inspect-v1',
        'account_id': accountId,
        'instance_id': instanceId,
        'server_space_id': serverSpaceId,
        'recovery_generation': generation,
        'challenge_id': challengeId,
        'challenge': challenge,
        'recovery_descriptor_hash': descriptorHash,
      };
      final inspectSignature = recoveryCrypto.detachedSignature(
        identity: oldIdentity,
        payload: inspectPayload,
      );
      final inspected = await client.inspectAccountRecovery({
        'account_id': accountId,
        'instance_id': instanceId,
        'server_space_id': serverSpaceId,
        'recovery_generation': generation,
        'challenge_id': challengeId,
        'challenge': challenge,
        'recovery_signature': encodeBase64Url(inspectSignature),
      });
      if (inspected['account_id'] != accountId ||
          inspected['recovery_generation'] != generation ||
          inspected['recovery_descriptor_hash'] != descriptorHash ||
          inspected['recovery_status'] is! String ||
          inspected['required_contexts'] is! List ||
          inspected['present_contexts'] is! List) {
        throw FormatException(currentL10n.theRecoveryResponseDidNotMatch);
      }
      final requiredContexts = (inspected['required_contexts'] as List)
          .map(
            (item) => AccountRecoveryContext.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(growable: false);
      final candidates = (inspected['present_contexts'] as List)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList(growable: false);
      for (final context in requiredContexts) {
        final matching = candidates.where((candidate) {
          return candidate['vault_id'] == context.vaultId &&
              (candidate['key_epoch'] as num?)?.toInt() == context.keyEpoch;
        });
        Uint8List? openedKey;
        for (final candidate in matching) {
          try {
            final box = candidate['envelope'];
            if (box is! Map ||
                candidate['uploader_device_id'] is! String ||
                candidate['recovery_signature'] is! String) {
              continue;
            }
            openedKey = await recoveryCrypto.openKeyEnvelope(
              identity: oldIdentity,
              vaultId: context.vaultId,
              keyEpoch: context.keyEpoch,
              envelope: Map<String, dynamic>.from(box),
              uploaderDeviceId: candidate['uploader_device_id'] as String,
              recoverySignature: candidate['recovery_signature'] as String,
              expectedEnvelopeSha256: candidate['envelope_sha256'] as String?,
            );
            break;
          } catch (_) {
            // Try the next signed candidate for this logical context.
          }
        }
        if (openedKey == null) {
          throw FormatException(currentL10n.aRequiredVaultKeyCouldNot);
        }
        recoveredVaultKeys[context.logicalKey] = openedKey;
      }

      newParams = KdfParameters.defaults(sodium);
      newVerifier = await crypto.deriveLoginVerifier(newPassword, newParams);
      newAccountKey = crypto.randomBytes(32);
      final accountKeyEnvelope = await crypto.wrapAccountKey(
        password: newPassword,
        params: newParams,
        accountKey: newAccountKey,
      );
      newDevice = DeviceIdentity.create(sodium);
      final deviceProof = newDevice.registrationProof(
        sodium,
        accountId: accountId,
        name: deviceName.trim().isEmpty
            ? currentL10n.recoveredDevice
            : deviceName.trim(),
      );
      // CompletionDevice is a strict server DTO. The device self-proof is
      // still signed over account_id, but that account binding is supplied by
      // the top-level completion request and must not be repeated in the
      // nested device object.
      final completionDevice = <String, Object?>{
        'device_id': deviceProof['device_id'],
        'name': deviceProof['name'],
        'signing_public_key': deviceProof['signing_public_key'],
        'encryption_public_key': deviceProof['encryption_public_key'],
        'signature': deviceProof['signature'],
      };
      final nextGeneration = generation + 1;
      nextIdentity = recoveryCrypto.createIdentity(
        accountId: accountId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        generation: nextGeneration,
      );
      final nextCode = recoveryCrypto.createRecoveryCode();
      final nextCodeEnvelope = await recoveryCrypto
          .sealIdentityWithRecoveryCode(
            identity: nextIdentity,
            recoveryCode: nextCode,
          );
      final nextIdentityEnvelope = await recoveryCrypto
          .sealIdentityWithAccountKey(
            identity: nextIdentity,
            accountKey: newAccountKey,
          );
      final nextDescriptorHash = await recoveryCrypto.recoveryDescriptorHash(
        accountId: accountId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        generation: nextGeneration,
        signingPublicKey: nextIdentity.signingPublicKey,
        encryptionPublicKey: nextIdentity.encryptionPublicKey,
      );
      final nextCodeEnvelopeHash = await recoveryCrypto.sha256Hex(
        Uint8List.fromList(utf8.encode(canonicalJson(nextCodeEnvelope))),
      );
      final nextIdentityEnvelopeHash = await recoveryCrypto.sha256Hex(
        Uint8List.fromList(utf8.encode(canonicalJson(nextIdentityEnvelope))),
      );
      final identityProof = recoveryCrypto.detachedSignature(
        identity: nextIdentity,
        payload: {
          'protocol': 'atermius-account-recovery-identity-v1',
          'account_id': accountId,
          'instance_id': instanceId,
          'server_space_id': serverSpaceId,
          'recovery_generation': nextGeneration,
          'recovery_descriptor_hash': nextDescriptorHash,
          'recovery_envelope_sha256': nextCodeEnvelopeHash,
          'recovery_identity_envelope_sha256': nextIdentityEnvelopeHash,
        },
      );
      final nextBoxes = <Map<String, Object?>>[];
      final deviceBoxes = <Map<String, Object?>>[];
      for (final context in requiredContexts) {
        final vaultKey = recoveredVaultKeys[context.logicalKey]!;
        final membershipVersion = context.membershipVersion;
        if (membershipVersion == null || membershipVersion < 1) {
          throw FormatException(currentL10n.aVaultRecoveryContextHasNo);
        }
        final deviceBox = crypto.createDeviceKeyEnvelope(
          vaultId: context.vaultId,
          vaultKey: vaultKey,
          keyEpoch: context.keyEpoch,
          membershipVersion: membershipVersion,
          recipientDeviceId: newDevice.deviceId,
          recipientEncryptionPublicKey: newDevice.encryption.publicKey,
          signer: newDevice,
        );
        final roundTripDeviceKey = await crypto.openVaultKeyEnvelope(
          vaultId: context.vaultId,
          deviceId: newDevice.deviceId,
          identity: newDevice,
          keyEnvelope: Map<String, dynamic>.from(deviceBox),
          signerPublicKey: newDevice.signing.publicKey,
        );
        if (!_constantTimeBytesEqual(vaultKey, roundTripDeviceKey)) {
          roundTripDeviceKey.fillRange(0, roundTripDeviceKey.length, 0);
          throw FormatException(currentL10n.aNewDeviceKeyEnvelopeFailed);
        }
        roundTripDeviceKey.fillRange(0, roundTripDeviceKey.length, 0);
        deviceBoxes.add(Map<String, Object?>.from(deviceBox));
        final recoveryBox = await recoveryCrypto.buildKeyEnvelope(
          identity: nextIdentity,
          uploaderDeviceId: newDevice.deviceId,
          vaultId: context.vaultId,
          keyEpoch: context.keyEpoch,
          vaultKey: vaultKey,
        );
        final roundTripRecoveryKey = await recoveryCrypto.openKeyEnvelope(
          identity: nextIdentity,
          vaultId: context.vaultId,
          keyEpoch: context.keyEpoch,
          envelope: Map<String, dynamic>.from(recoveryBox['envelope']! as Map),
          uploaderDeviceId: newDevice.deviceId,
          recoverySignature: recoveryBox['recovery_signature']! as String,
          expectedEnvelopeSha256: recoveryBox['envelope_sha256']! as String,
        );
        if (!_constantTimeBytesEqual(vaultKey, roundTripRecoveryKey)) {
          roundTripRecoveryKey.fillRange(0, roundTripRecoveryKey.length, 0);
          throw FormatException(currentL10n.aNewRecoveryKeyboxFailedIts);
        }
        roundTripRecoveryKey.fillRange(0, roundTripRecoveryKey.length, 0);
        nextBoxes.add(recoveryBox);
      }
      final nextRecovery = <String, Object?>{
        'recovery_public_signing_key': nextIdentity.signingPublicKey,
        'recovery_public_encryption_key': nextIdentity.encryptionPublicKey,
        'recovery_envelope': nextCodeEnvelope,
        'recovery_identity_envelope': nextIdentityEnvelope,
        'key_envelopes': nextBoxes,
        'recovery_identity_proof_signature': encodeBase64Url(identityProof),
      };
      final unsigned = <String, Object?>{
        'operation_id': _uuid.v4().toLowerCase(),
        'account_id': accountId,
        'instance_id': instanceId,
        'server_space_id': serverSpaceId,
        'recovery_generation': generation,
        'challenge_id': challengeId,
        'challenge': challenge,
        'new_kdf': newParams.toJson(),
        'new_login_verifier': encodeBase64Url(newVerifier),
        'account_key_envelope': accountKeyEnvelope,
        'device': completionDevice,
        'vault_key_envelopes': deviceBoxes,
        'next_recovery': nextRecovery,
      };
      final completionSignature = recoveryCrypto.detachedSignature(
        identity: oldIdentity,
        payload: {
          'protocol': 'atermius-account-recovery-complete-v1',
          'request': unsigned,
        },
      );
      final request = <String, Object?>{
        ...unsigned,
        'recovery_signature': encodeBase64Url(completionSignature),
      };
      await secureStore.savePendingFullAccountRecovery(
        baseUrl: client.baseUrl,
        request: request,
        device: newDevice,
        challengeExpiresAt: expiry,
        completionAttempted: false,
      );
      _pendingFullAccountRecovery = _PendingFullAccountRecovery(
        request: request,
        device: newDevice,
        baseUrl: client.baseUrl,
        challengeExpiresAt: expiry,
      );
      newDevice = null;
      return AccountRecoveryPreparation(
        recoveryCode: nextCode,
        recoveredContexts: requiredContexts.length,
      );
    } catch (error) {
      errorMessage = friendlyError(error);
      rethrow;
    } finally {
      for (final key in recoveredVaultKeys.values) {
        key.fillRange(0, key.length, 0);
      }
      oldIdentity?.dispose();
      nextIdentity?.dispose();
      newDevice?.dispose();
      newAccountKey?.fillRange(0, newAccountKey.length, 0);
      newVerifier?.fillRange(0, newVerifier.length, 0);
      newParams?.salt.fillRange(0, newParams.salt.length, 0);
      accountRecoveryBusy = false;
      notifyListeners();
    }
  }

  Future<void> completePreparedAccountRecovery() async {
    final pending = _pendingFullAccountRecovery;
    if (pending == null) {
      throw StateError(currentL10n.noAccountRecoveryIsAwaitingConfirmation);
    }
    final client = _requireApi();
    if (client.baseUrl != pending.baseUrl || session != null) {
      throw StateError(currentL10n.theServerOrAuthenticationStateChanged);
    }
    accountRecoveryBusy = true;
    notifyListeners();
    try {
      await secureStore.savePendingFullAccountRecovery(
        baseUrl: pending.baseUrl,
        request: pending.request,
        device: pending.device,
        challengeExpiresAt: pending.challengeExpiresAt,
        completionAttempted: true,
      );
      _pendingFullAccountRecoveryCompletionAttempted = true;
      final receipt = await client.completeAccountRecovery(pending.request);
      if (receipt['status'] != 'recovered' ||
          receipt['device_id'] != pending.device.deviceId) {
        throw FormatException(
          currentL10n.theRecoveryCompletionReceiptIsInvalid,
        );
      }
      await secureStore.saveDevice(pending.baseUrl, pending.device);
      await secureStore.clearPendingFullAccountRecovery(pending.baseUrl);
      _pendingFullAccountRecovery = null;
      _pendingFullAccountRecoveryCompletionAttempted = false;
      pending.dispose();
      stage = ClientStage.login;
      accountRecoveryStatus = 'current';
      _setNotice(currentL10n.accountRecoveredSignInWithThe2);
    } finally {
      accountRecoveryBusy = false;
      notifyListeners();
    }
  }

  /// Restores only an already-submitted recovery request after restart. An
  /// unsubmitted preparation is discarded because its one-time code was
  /// intentionally never persisted and cannot be shown again.
  Future<void> restorePendingFullAccountRecovery() async {
    final currentApi = api;
    final currentInstance = instance;
    if (currentApi == null || currentInstance == null || session != null) {
      return;
    }
    final currentIdentity = identity;
    final apiGeneration = _apiGeneration;
    final authContextGeneration = _authContextGeneration;
    bool restoreScopeIsCurrent() =>
        !_controllerDisposed &&
        identical(api, currentApi) &&
        identical(instance, currentInstance) &&
        identical(identity, currentIdentity) &&
        session == null &&
        apiGeneration == _apiGeneration &&
        authContextGeneration == _authContextGeneration;

    final inMemory = _pendingFullAccountRecovery;
    if (inMemory != null && inMemory.baseUrl == currentApi.baseUrl) return;
    PendingAccountRecoveryStorageData? stored;
    try {
      stored = await secureStore.loadPendingFullAccountRecovery(
        currentApi.baseUrl,
      );
    } catch (_) {
      if (!restoreScopeIsCurrent()) return;
      rethrow;
    }
    // A server replacement can happen while secure storage is resolving. The
    // result belongs to the captured API/instance context and must not install
    // recovery state into a later server, including another client at the same
    // base URL.
    if (!restoreScopeIsCurrent()) return;
    if (stored == null) return;
    if (!stored.completionAttempted) {
      try {
        await secureStore.clearPendingFullAccountRecovery(currentApi.baseUrl);
      } catch (_) {
        if (!restoreScopeIsCurrent()) return;
        rethrow;
      }
      if (!restoreScopeIsCurrent()) return;
      return;
    }

    DeviceIdentity? restoredDevice;
    try {
      final request = Map<String, Object?>.from(stored.request);
      final accountId = request['account_id'];
      final requestInstance = request['instance_id'];
      final requestSpace = request['server_space_id'];
      final generation = request['recovery_generation'];
      final challengeId = request['challenge_id'];
      final challenge = request['challenge'];
      final operationId = request['operation_id'];
      final requestDevice = request['device'];
      final nextRecovery = request['next_recovery'];
      if (accountId is! String ||
          !_isCanonicalUuid(accountId) ||
          requestInstance != currentInstance.instanceId ||
          requestSpace != currentInstance.serverSpaceId ||
          generation is! num ||
          generation < 1 ||
          challengeId is! String ||
          !_isCanonicalUuid(challengeId) ||
          challenge is! String ||
          request['recovery_signature'] is! String ||
          operationId is! String ||
          !_isCanonicalUuid(operationId) ||
          requestDevice is! Map ||
          nextRecovery is! Map) {
        throw FormatException(currentL10n.storedRecoveryRequestDoesNotMatch);
      }
      final challengeBytes = decodeBase64Url(challenge);
      final validChallenge =
          challengeBytes.length == 32 &&
          encodeBase64Url(challengeBytes) == challenge;
      challengeBytes.fillRange(0, challengeBytes.length, 0);
      if (!validChallenge) {
        throw FormatException(currentL10n.storedRecoveryChallengeIsInvalid);
      }
      final next = Map<String, dynamic>.from(nextRecovery);
      if (next['recovery_public_signing_key'] is! String ||
          next['recovery_public_encryption_key'] is! String ||
          next['recovery_envelope'] is! Map ||
          next['recovery_identity_envelope'] is! Map ||
          next['key_envelopes'] is! List ||
          next['recovery_identity_proof_signature'] is! String) {
        throw FormatException(currentL10n.storedNextRecoveryPackageIsInvalid);
      }

      restoredDevice = DeviceIdentity.fromStorage(sodium, stored.device);
      final proof = Map<String, dynamic>.from(requestDevice);
      final proofPayload = <String, Object?>{
        'account_id': accountId,
        'device_id': restoredDevice.deviceId,
        'signing_public_key': restoredDevice.signingPublicKey,
        'encryption_public_key': restoredDevice.encryptionPublicKey,
      };
      final signingPublicFromSecret = sodium.crypto.sign.skToPk(
        restoredDevice.signing.secretKey,
      );
      if (!_constantTimeBytesEqual(
        signingPublicFromSecret,
        restoredDevice.signing.publicKey,
      )) {
        throw FormatException(currentL10n.storedRecoveryDeviceKeyIsInvalid);
      }
      final probe = sodium.randombytes.buf(32);
      Uint8List? sealedProbe;
      Uint8List? openedProbe;
      try {
        sealedProbe = sodium.crypto.box.seal(
          message: probe,
          publicKey: restoredDevice.encryption.publicKey,
        );
        openedProbe = sodium.crypto.box.sealOpen(
          cipherText: sealedProbe,
          publicKey: restoredDevice.encryption.publicKey,
          secretKey: restoredDevice.encryption.secretKey,
        );
        if (!_constantTimeBytesEqual(probe, openedProbe)) {
          throw FormatException(currentL10n.storedRecoveryDeviceKeyIsInvalid);
        }
      } finally {
        probe.fillRange(0, probe.length, 0);
        sealedProbe?.fillRange(0, sealedProbe.length, 0);
        openedProbe?.fillRange(0, openedProbe.length, 0);
      }
      final proofSignature = proof['signature'];
      if ((proof.containsKey('account_id') &&
              proof['account_id'] != accountId) ||
          proof['device_id'] != restoredDevice.deviceId ||
          proof['signing_public_key'] != restoredDevice.signingPublicKey ||
          proof['encryption_public_key'] !=
              restoredDevice.encryptionPublicKey ||
          proofSignature is! String) {
        throw FormatException(currentL10n.storedRecoveryDeviceProofIsInvalid);
      }
      final proofBytes = decodeBase64Url(proofSignature);
      final validProof =
          encodeBase64Url(proofBytes) == proofSignature &&
          sodium.crypto.sign.verifyDetached(
            message: Uint8List.fromList(
              utf8.encode(canonicalJson(proofPayload)),
            ),
            signature: proofBytes,
            publicKey: restoredDevice.signing.publicKey,
          );
      proofBytes.fillRange(0, proofBytes.length, 0);
      if (!validProof) {
        throw FormatException(currentL10n.storedRecoveryDeviceProofIsInvalid);
      }
      if (!restoreScopeIsCurrent()) return;
      final pending = _PendingFullAccountRecovery(
        request: request,
        device: restoredDevice,
        baseUrl: currentApi.baseUrl,
        challengeExpiresAt: stored.challengeExpiresAt,
      );
      restoredDevice = null;
      _pendingFullAccountRecovery = pending;
      _pendingFullAccountRecoveryCompletionAttempted = true;
      notifyListeners();
    } finally {
      restoredDevice?.dispose();
    }
  }

  Future<void> cancelPreparedAccountRecovery({
    bool force = false,
    bool clearStoredPending = true,
  }) async {
    if (_pendingFullAccountRecoveryCompletionAttempted && !force) return;
    final wasCompletionAttempted =
        _pendingFullAccountRecoveryCompletionAttempted;
    final pending = _pendingFullAccountRecovery;
    _pendingFullAccountRecovery = null;
    _pendingFullAccountRecoveryCompletionAttempted = false;
    pending?.dispose();
    if (pending != null && clearStoredPending && !wasCompletionAttempted) {
      try {
        await secureStore.clearPendingFullAccountRecovery(pending.baseUrl);
      } catch (_) {
        // Startup discards any persisted request that was never submitted.
      }
    }
  }

  Future<AccountRecoverySetupResult> configureAccountRecovery({
    required String currentPassword,
  }) async {
    if (accountRecoveryBusy) {
      throw StateError(currentL10n.accountRecoverySettingsAreBeingProcessed);
    }
    final currentAccount = account;
    final currentSession = session;
    final currentDevice = identity;
    final accountKey = _accountKey;
    final username = authenticatedUsername;
    final instanceInfo = instance;
    if (currentAccount == null ||
        currentSession == null ||
        currentDevice == null ||
        accountKey == null ||
        username == null ||
        instanceInfo == null ||
        currentSession.accountId != currentAccount.accountId ||
        currentSession.deviceId != currentDevice.deviceId) {
      throw StateError(currentL10n.signInToThisAccountAnd);
    }
    if (currentPassword.length < 12) {
      throw FormatException(currentL10n.enterTheCurrentMasterPassword);
    }
    accountRecoveryBusy = true;
    errorMessage = null;
    noticeMessage = null;
    notifyListeners();
    KdfParameters? params;
    Uint8List? verifier;
    RecoveryIdentity? nextIdentity;
    RecoveryIdentity? oldIdentity;
    var installed = false;
    try {
      final client = _requireApi();
      final prelogin = await client.prelogin(username);
      if (prelogin['account_id'] != currentAccount.accountId) {
        throw FormatException(
          currentL10n.theCurrentAccountVerificationDetailsDont,
        );
      }
      params = KdfParameters.fromJson(
        Map<String, dynamic>.from(prelogin['kdf'] as Map),
      );
      verifier = await crypto.deriveLoginVerifier(currentPassword, params);
      final snapshot = await client.accountRecoveryContexts();
      if (snapshot.status != 'disabled') {
        if (snapshot.generation < 1) {
          throw FormatException(currentL10n.theEnabledRecoveryIdentityHasAn);
        }
        oldIdentity = _recoveryIdentity;
        if (oldIdentity == null ||
            oldIdentity.generation != snapshot.generation) {
          final oldEnvelope = snapshot.identityEnvelope;
          if (oldEnvelope == null) {
            throw FormatException(currentL10n.theServerIsMissingTheExisting);
          }
          oldIdentity = await recoveryCrypto.openIdentityWithAccountKey(
            envelope: oldEnvelope,
            accountKey: accountKey,
            accountId: currentAccount.accountId,
            instanceId: instanceInfo.instanceId,
            serverSpaceId: instanceInfo.serverSpaceId,
            generation: snapshot.generation,
          );
        }
        final oldDescriptorHash = await recoveryCrypto.recoveryDescriptorHash(
          accountId: oldIdentity.accountId,
          instanceId: oldIdentity.instanceId,
          serverSpaceId: oldIdentity.serverSpaceId,
          generation: oldIdentity.generation,
          signingPublicKey: oldIdentity.signingPublicKey,
          encryptionPublicKey: oldIdentity.encryptionPublicKey,
        );
        if (snapshot.recoveryPublicSigningKey != oldIdentity.signingPublicKey ||
            snapshot.recoveryPublicEncryptionKey !=
                oldIdentity.encryptionPublicKey ||
            snapshot.descriptorHash != oldDescriptorHash) {
          throw FormatException(
            currentL10n.theExistingRecoveryDescriptorDoesNot,
          );
        }
      } else if (snapshot.identityEnvelope != null ||
          snapshot.recoveryPublicSigningKey != null ||
          snapshot.recoveryPublicEncryptionKey != null ||
          snapshot.descriptorHash != null ||
          snapshot.present.isNotEmpty ||
          snapshot.keyEnvelopes.isNotEmpty) {
        throw FormatException(
          currentL10n.aDisabledRecoveryAccountReturnedActive,
        );
      }
      final nextGeneration = snapshot.generation + 1;
      nextIdentity = recoveryCrypto.createIdentity(
        accountId: currentAccount.accountId,
        instanceId: instanceInfo.instanceId,
        serverSpaceId: instanceInfo.serverSpaceId,
        generation: nextGeneration,
      );
      final recoveryCode = recoveryCrypto.createRecoveryCode();
      final codeEnvelope = await recoveryCrypto.sealIdentityWithRecoveryCode(
        identity: nextIdentity,
        recoveryCode: recoveryCode,
      );
      final identityEnvelope = await recoveryCrypto.sealIdentityWithAccountKey(
        identity: nextIdentity,
        accountKey: accountKey,
      );
      final keyEnvelopes = await _buildRecoveryBoxesForSetup(
        snapshot: snapshot,
        nextIdentity: nextIdentity,
        oldIdentity: oldIdentity,
        deviceId: currentDevice.deviceId,
      );
      final nextDescriptorHash = await recoveryCrypto.recoveryDescriptorHash(
        accountId: nextIdentity.accountId,
        instanceId: nextIdentity.instanceId,
        serverSpaceId: nextIdentity.serverSpaceId,
        generation: nextIdentity.generation,
        signingPublicKey: nextIdentity.signingPublicKey,
        encryptionPublicKey: nextIdentity.encryptionPublicKey,
      );
      final codeEnvelopeHash = await recoveryCrypto.sha256Hex(
        Uint8List.fromList(utf8.encode(canonicalJson(codeEnvelope))),
      );
      final identityEnvelopeHash = await recoveryCrypto.sha256Hex(
        Uint8List.fromList(utf8.encode(canonicalJson(identityEnvelope))),
      );
      final selfProof = recoveryCrypto.detachedSignature(
        identity: nextIdentity,
        payload: {
          'protocol': 'atermius-account-recovery-identity-v1',
          'account_id': nextIdentity.accountId,
          'instance_id': nextIdentity.instanceId,
          'server_space_id': nextIdentity.serverSpaceId,
          'recovery_generation': nextIdentity.generation,
          'recovery_descriptor_hash': nextDescriptorHash,
          'recovery_envelope_sha256': codeEnvelopeHash,
          'recovery_identity_envelope_sha256': identityEnvelopeHash,
        },
      );
      String? previousProof;
      if (oldIdentity != null) {
        final oldDescriptorHash = await recoveryCrypto.recoveryDescriptorHash(
          accountId: oldIdentity.accountId,
          instanceId: oldIdentity.instanceId,
          serverSpaceId: oldIdentity.serverSpaceId,
          generation: oldIdentity.generation,
          signingPublicKey: oldIdentity.signingPublicKey,
          encryptionPublicKey: oldIdentity.encryptionPublicKey,
        );
        previousProof = encodeBase64Url(
          recoveryCrypto.detachedSignature(
            identity: oldIdentity,
            payload: {
              'protocol': 'atermius-account-recovery-rotate-v1',
              'account_id': oldIdentity.accountId,
              'instance_id': oldIdentity.instanceId,
              'server_space_id': oldIdentity.serverSpaceId,
              'old_recovery_generation': oldIdentity.generation,
              'new_recovery_generation': nextIdentity.generation,
              'old_recovery_descriptor_hash': oldDescriptorHash,
              'new_recovery_descriptor_hash': nextDescriptorHash,
            },
          ),
        );
      }
      final unsigned = <String, Object?>{
        'operation_id': _uuid.v4().toLowerCase(),
        'current_login_verifier': encodeBase64Url(verifier),
        'recovery_generation': nextGeneration,
        'recovery_public_signing_key': nextIdentity.signingPublicKey,
        'recovery_public_encryption_key': nextIdentity.encryptionPublicKey,
        'recovery_identity_proof_signature': encodeBase64Url(selfProof),
        if (previousProof != null) 'previous_recovery_signature': previousProof,
        'recovery_envelope': codeEnvelope,
        'recovery_identity_envelope': identityEnvelope,
        'key_envelopes': keyEnvelopes,
      };
      final proof = sodium.crypto.sign.detached(
        message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
        secretKey: currentDevice.signing.secretKey,
      );
      final receipt = await client.configureAccountRecovery({
        ...unsigned,
        'proof_signature': encodeBase64Url(proof),
      });
      if (receipt['recovery_generation'] != nextGeneration ||
          !const {
            'current',
            'stale',
            'incomplete',
          }.contains(receipt['recovery_status'])) {
        throw FormatException(currentL10n.theServerReturnedAnInvalidRecovery);
      }
      final previousIdentity = _recoveryIdentity;
      _recoveryIdentity = nextIdentity;
      nextIdentity = null;
      if (!identical(previousIdentity, oldIdentity)) {
        previousIdentity?.dispose();
      }
      if (!identical(oldIdentity, _recoveryIdentity)) oldIdentity?.dispose();
      accountRecoveryStatus = receipt['recovery_status'] as String;
      accountRecoveryRequiredContexts = snapshot.required;
      accountRecoveryPresentContexts = keyEnvelopes
          .map(
            (item) => AccountRecoveryContext(
              vaultId: item['vault_id']! as String,
              keyEpoch: item['key_epoch']! as int,
            ),
          )
          .toList(growable: false);
      installed = true;
      notifyListeners();
      unawaited(_refreshRecoveryContextsAndUpload());
      return AccountRecoverySetupResult(
        recoveryCode: recoveryCode,
        status: accountRecoveryStatus,
        coveredContexts: keyEnvelopes.length,
        requiredContexts: snapshot.required.length,
      );
    } catch (error) {
      errorMessage = friendlyError(error);
      notifyListeners();
      rethrow;
    } finally {
      verifier?.fillRange(0, verifier.length, 0);
      params?.salt.fillRange(0, params.salt.length, 0);
      nextIdentity?.dispose();
      if (!installed && !identical(oldIdentity, _recoveryIdentity)) {
        oldIdentity?.dispose();
      }
      accountRecoveryBusy = false;
      notifyListeners();
    }
  }

  Future<List<Map<String, Object?>>> _buildRecoveryBoxesForSetup({
    required AccountRecoveryContexts snapshot,
    required RecoveryIdentity nextIdentity,
    required RecoveryIdentity? oldIdentity,
    required String deviceId,
  }) async {
    final oldBoxes = <String, List<Map<String, dynamic>>>{};
    for (final box in snapshot.keyEnvelopes) {
      final vaultId = box['vault_id'];
      final epoch = box['key_epoch'];
      if (vaultId is String && epoch is num) {
        oldBoxes.putIfAbsent('$vaultId:${epoch.toInt()}', () => []).add(box);
      }
    }
    final output = <Map<String, Object?>>[];
    final previouslyPresent = snapshot.present
        .map((item) => item.logicalKey)
        .toSet();
    for (final context in snapshot.required) {
      Uint8List? vaultKey;
      final localVersions = _vaultEpochKeys[context.vaultId];
      final local = localVersions?.entries
          .where((entry) => entry.key.startsWith('${context.keyEpoch}:'))
          .map((entry) => entry.value)
          .toList(growable: false);
      if (local != null && local.isNotEmpty) {
        if (!local
            .skip(1)
            .any(
              (candidate) => !_constantTimeBytesEqual(local.first, candidate),
            )) {
          vaultKey = Uint8List.fromList(local.first);
        }
      }
      if (vaultKey == null && oldIdentity != null) {
        final oldCandidates = oldBoxes[context.logicalKey] ?? const [];
        for (final oldBox in oldCandidates) {
          if (oldBox['envelope'] is! Map ||
              oldBox['uploader_device_id'] is! String ||
              oldBox['recovery_signature'] is! String) {
            continue;
          }
          Uint8List? candidateKey;
          try {
            candidateKey = await recoveryCrypto.openKeyEnvelope(
              identity: oldIdentity,
              vaultId: context.vaultId,
              keyEpoch: context.keyEpoch,
              envelope: Map<String, dynamic>.from(oldBox['envelope'] as Map),
              uploaderDeviceId: oldBox['uploader_device_id'] as String,
              recoverySignature: oldBox['recovery_signature'] as String,
              expectedEnvelopeSha256: oldBox['envelope_sha256'] as String?,
            );
          } catch (_) {
            // A context may have more than one candidate. Ignore malformed
            // candidates only when another candidate opens and verifies.
            continue;
          }
          if (vaultKey == null) {
            vaultKey = candidateKey;
          } else {
            final matches = _constantTimeBytesEqual(vaultKey, candidateKey);
            candidateKey.fillRange(0, candidateKey.length, 0);
            if (!matches) {
              vaultKey.fillRange(0, vaultKey.length, 0);
              vaultKey = null;
              throw FormatException(
                currentL10n.conflictingSignedRecoveryKeyboxesExistFor,
              );
            }
          }
        }
      }
      if (vaultKey == null) {
        if (previouslyPresent.contains(context.logicalKey)) {
          throw FormatException(currentL10n.anExistingRecoveryKeyboxCouldNot);
        }
        continue;
      }
      try {
        output.add(
          await recoveryCrypto.buildKeyEnvelope(
            identity: nextIdentity,
            uploaderDeviceId: deviceId,
            vaultId: context.vaultId,
            keyEpoch: context.keyEpoch,
            vaultKey: vaultKey,
          ),
        );
      } finally {
        vaultKey.fillRange(0, vaultKey.length, 0);
      }
    }
    return output;
  }

  Future<void> disableAccountRecovery({required String currentPassword}) async {
    if (accountRecoveryBusy) {
      throw StateError(currentL10n.accountRecoverySettingsAreBeingProcessed);
    }
    final currentAccount = account;
    final username = authenticatedUsername;
    if (currentAccount == null || username == null) {
      throw StateError(currentL10n.signInFirst);
    }
    accountRecoveryBusy = true;
    notifyListeners();
    KdfParameters? params;
    Uint8List? verifier;
    try {
      final client = _requireApi();
      final prelogin = await client.prelogin(username);
      if (prelogin['account_id'] != currentAccount.accountId) {
        throw FormatException(
          currentL10n.theCurrentAccountVerificationDetailsDont,
        );
      }
      params = KdfParameters.fromJson(
        Map<String, dynamic>.from(prelogin['kdf'] as Map),
      );
      verifier = await crypto.deriveLoginVerifier(currentPassword, params);
      await client.disableAccountRecovery({
        'operation_id': _uuid.v4().toLowerCase(),
        'current_login_verifier': encodeBase64Url(verifier),
      });
      _clearRecoveryIdentity();
      notifyListeners();
    } finally {
      verifier?.fillRange(0, verifier.length, 0);
      params?.salt.fillRange(0, params.salt.length, 0);
      accountRecoveryBusy = false;
      notifyListeners();
    }
  }

  Future<void> refreshAccountRecoveryState() =>
      _refreshRecoveryContextsAndUpload();

  Future<void> _submitPendingAccountPasswordChange(
    _PendingAccountPasswordChange pending,
  ) async {
    if (!identical(_pendingAccountPasswordChange, pending)) {
      throw StateError(currentL10n.thePendingMasterPasswordChangeRequest);
    }
    final apiClient = _requireApi();
    final receipt = await apiClient.changePassword(pending.request);
    if (receipt.operationId != pending.operationId ||
        receipt.credentialVersion <= pending.previousCredentialVersion) {
      throw FormatException(currentL10n.theServerReturnedAnInvalidMaster);
    }
    final refreshedProfile = await apiClient.accountProfile();
    if (refreshedProfile.accountId != pending.accountId ||
        refreshedProfile.deviceId != pending.deviceId ||
        refreshedProfile.accountKeyEnvelopeVersion !=
            receipt.credentialVersion) {
      throw FormatException(currentL10n.theMasterPasswordWasCommittedBut);
    }
    if (!identical(_pendingAccountPasswordChange, pending)) {
      throw StateError(currentL10n.thePendingMasterPasswordChangeRequest);
    }
    account = refreshedProfile;
    if (!isInstanceAdmin) _resetInstanceAdminOverview();
    _pendingAccountPasswordChange = null;
    errorMessage = null;
    noticeMessage = receipt.alreadyApplied
        ? currentL10n.thePreviouslySubmittedMasterPasswordChange
        : currentL10n.masterPasswordChangedOtherSignIn;
    final currentSession = session;
    final username = _authenticatedUsername;
    if (currentSession != null && username != null) {
      try {
        await _saveSessionCredentials(
          apiClient.baseUrl,
          username,
          currentSession,
        );
        _sessionAccessExpiresAt = _sessionCredentialsFor(currentSession)
            .accessExpiresAt;
        _sessionCredentialsAdoptedAt = DateTime.now().toUtc();
        _signalSessionUpdate(
          apiClient.baseUrl,
          _sessionCredentialsFor(currentSession),
          SessionUpdateKind.updated,
        );
      } catch (_) {
        noticeMessage = currentL10n.noticemessageThisDeviceCouldntSaveThe(
          '$noticeMessage',
        );
      }
    }
    notifyListeners();
  }

  String _accountPasswordChangeFriendlyError(Object error) {
    if (error is ApiException) {
      if (error.code == 'REAUTH_REQUIRED') {
        return currentL10n.theCurrentMasterPasswordCouldntBe;
      }
      if (error.code == 'IDEMPOTENCY_KEY_REUSED') {
        return currentL10n.thePasswordChangeOperationStateConflicts;
      }
    }
    return friendlyError(error);
  }

  Future<AccountDeletionState> scheduleAccountDeletion({
    required String username,
    required String password,
  }) async {
    if (accountLifecycleBusy) {
      throw StateError(currentL10n.anAccountStateActionIsIn);
    }
    if (accountPasswordChangeBusy) {
      throw StateError(currentL10n.aMasterPasswordChangeIsIn);
    }
    if (_pendingAccountPasswordChange != null) {
      throw StateError(currentL10n.retryThePendingMasterPasswordChange);
    }
    if (syncing || snapshotRecoveryActive) {
      throw StateError(currentL10n.theAccountCantBeDeletedDuring);
    }
    final currentAccount = account;
    final currentSession = session;
    if (currentAccount == null || currentSession == null) {
      throw StateError(currentL10n.noAccountIsSignedIn);
    }
    final normalizedUsername = username.trim().toLowerCase();
    if (normalizedUsername.isEmpty || password.isEmpty) {
      throw FormatException(currentL10n.enterTheCurrentAccountNameAnd);
    }
    if (_authenticatedUsername != null &&
        normalizedUsername != _authenticatedUsername) {
      throw FormatException(currentL10n.theReVerifiedAccountMustMatch);
    }
    if (password.length < 12) {
      throw FormatException(currentL10n.theMasterPasswordMustBeAt3);
    }

    accountLifecycleBusy = true;
    _automaticSync.stop();
    _syncHints.stop();
    errorMessage = null;
    noticeMessage = null;
    notifyListeners();
    Uint8List? verifier;
    AccountDeletionState? lifecycle;
    var accepted = false;
    var refreshTokenCleanupFailed = false;
    var localCleanupFailed = false;
    try {
      final client = _requireApi();
      final prelogin = await client.prelogin(normalizedUsername);
      if (prelogin['account_id'] != currentAccount.accountId) {
        throw FormatException(currentL10n.thisAccountNameDoesntMatchThe);
      }
      final params = KdfParameters.fromJson(
        Map<String, dynamic>.from(prelogin['kdf'] as Map),
      );
      verifier = await crypto.deriveLoginVerifier(password, params);
      final response = await client.deleteAccount({
        'login_verifier': encodeBase64Url(verifier),
      });
      // A successful HTTP response means the server has already revoked this
      // session, even if its lifecycle DTO is malformed.
      accepted = true;
      lifecycle = AccountDeletionState.fromJson(response);
      if (lifecycle.status != 'deleting' ||
          !lifecycle.canCancel ||
          !_validRfc3339(lifecycle.requestedAt) ||
          !_validRfc3339(lifecycle.purgeAfter)) {
        throw FormatException(currentL10n.theServerAcceptedTheDeletionRequest2);
      }
      accountDeletionPurgeAfter = lifecycle.purgeAfter;
      return lifecycle;
    } catch (error) {
      errorMessage = friendlyError(error);
      rethrow;
    } finally {
      verifier?.fillRange(0, verifier.length, 0);
      try {
        if (accepted) {
          final endingSession = session;
          final endingBaseUrl = api?.baseUrl;
          if (endingSession != null && endingBaseUrl != null) {
            _signalSessionUpdate(
              endingBaseUrl,
              _sessionCredentialsFor(endingSession),
              SessionUpdateKind.removed,
            );
          }
          api?.accessToken = null;
          try {
            final baseUrl = api?.baseUrl;
            if (baseUrl != null) {
              await secureStore.deleteRefreshToken(baseUrl, normalizedUsername);
            }
          } catch (_) {
            refreshTokenCleanupFailed = true;
          }
          try {
            await _clearLocalAuthenticatedState(signalRemoved: false);
          } catch (_) {
            // The server has already revoked this session. Preserve that
            // result even if a local cleanup adapter unexpectedly fails.
            localCleanupFailed = true;
          } finally {
            // Idempotent fallback guarantees the client cannot remain in an
            // authenticated workspace after a successful server deletion.
            await _forceClearLocalAuthenticatedState();
          }
          final deadline = lifecycle?.purgeAfter;
          noticeMessage = deadline == null
              ? currentL10n.theServerAcceptedTheDeletionRequest
              : currentL10n.theAccountEnteredItsDeletionGrace(
                  deadline,
                  refreshTokenCleanupFailed
                      ? currentL10n.thisDevicesSecureStorageCouldntDelete
                      : '',
                  localCleanupFailed
                      ? currentL10n.someLocalStateCleanupHitAn
                      : '',
                );
        } else if (session != null && stage == ClientStage.workspace) {
          _automaticSync.start();
          _startSyncHints();
        }
      } finally {
        // Keep the dialog and controller from remaining busy even if any
        // best-effort cleanup step above throws.
        accountLifecycleBusy = false;
        notifyListeners();
      }
    }
  }

  Future<AccountDeletionState> cancelAccountDeletion({
    required String username,
    required String password,
  }) async {
    if (accountLifecycleBusy) {
      throw StateError(currentL10n.anAccountStateActionIsIn);
    }
    if (session != null) {
      throw StateError(currentL10n.toCancelAccountDeletionSignOut);
    }
    final normalizedUsername = username.trim().toLowerCase();
    if (normalizedUsername.isEmpty || password.isEmpty) {
      throw FormatException(currentL10n.enterTheAccountNameAndMaster);
    }
    if (password.length < 12) {
      throw FormatException(currentL10n.theMasterPasswordMustBeAt3);
    }

    final client = _requireApi();
    accountLifecycleBusy = true;
    errorMessage = null;
    noticeMessage = null;
    // The cancel route is intentionally sessionless; discard any stale token
    // before prelogin so no later request can accidentally reuse it.
    client.accessToken = null;
    notifyListeners();
    Uint8List? verifier;
    var accepted = false;
    AccountDeletionState? lifecycle;
    var refreshTokenCleanupFailed = false;
    try {
      final prelogin = await client.prelogin(normalizedUsername);
      final params = KdfParameters.fromJson(
        Map<String, dynamic>.from(prelogin['kdf'] as Map),
      );
      verifier = await crypto.deriveLoginVerifier(password, params);
      final response = await client.cancelAccountDeletion(
        username: normalizedUsername,
        body: {'login_verifier': encodeBase64Url(verifier)},
      );
      accepted = true;
      lifecycle = AccountDeletionState.fromJson(response);
      if (lifecycle.status != 'active' ||
          lifecycle.requestedAt != null ||
          lifecycle.purgeAfter != null ||
          lifecycle.canCancel) {
        throw FormatException(currentL10n.theAccountRevocationStateReturnedBy);
      }
      try {
        await secureStore.deleteRefreshToken(
          client.baseUrl,
          normalizedUsername,
        );
      } catch (_) {
        refreshTokenCleanupFailed = true;
      }
      accountDeletionPurgeAfter = null;
      stage = ClientStage.login;
      session = null;
      account = null;
      _resetInstanceAdminOverview();
      identity?.dispose();
      identity = null;
      _authenticatedUsername = null;
      noticeMessage = currentL10n.theAccountDeletionWasCancelledThe(
        refreshTokenCleanupFailed
            ? currentL10n.thisDevicesSecureStorageCouldntDelete
            : '',
      );
      errorMessage = null;
      notifyListeners();
      return lifecycle;
    } catch (error) {
      errorMessage = friendlyError(error);
      rethrow;
    } finally {
      verifier?.fillRange(0, verifier.length, 0);
      if (accepted) {
        // Do not trust response shape to recreate a session after the server
        // accepted a sessionless restore request.
        _vaultLoadsBlocked = true;
        ++_authContextGeneration;
        ++_vaultLoadGeneration;
        await _waitForVaultLoadCompletions();
        session = null;
        account = null;
        _resetInstanceAdminOverview();
        identity?.dispose();
        identity = null;
        _vaultLoadsBlocked = false;
        _authenticatedUsername = null;
        stage = ClientStage.login;
        client.accessToken = null;
        noticeMessage ??= currentL10n.theServerAcceptedTheRevocationRequest;
      }
      accountLifecycleBusy = false;
      notifyListeners();
    }
  }

  Future<void> refreshVaultLifecycle() async {
    _assertEditsAllowed();
    final remoteVaults = await _requireApi().vaults();
    final remoteById = {for (final vault in remoteVaults) vault.id: vault};
    final updated = <VaultDescriptor>[];
    final currentDescriptors = _vaultDescriptors.isEmpty && activeVault != null
        ? [activeVault!]
        : _vaultDescriptors;
    for (final local in currentDescriptors) {
      final remote = remoteById[local.id];
      updated.add(
        remote == null
            ? VaultDescriptor(
                id: local.id,
                role: local.role,
                activeKeyEpoch: local.activeKeyEpoch,
                membershipVersion: local.membershipVersion,
                encryptedDisplayNameEnvelope:
                    local.encryptedDisplayNameEnvelope,
                keyEnvelopes: local.keyEnvelopes,
                status: 'unavailable',
                canCancel: false,
                canWrite: false,
              )
            : local.withLifecycleFrom(remote),
      );
    }
    _vaultDescriptors = updated;
    final selected = activeVault;
    if (selected != null) {
      activeVault = updated
          .where((vault) => vault.id == selected.id)
          .firstOrNull;
    }
    final currentVault = activeVault;
    if (currentVault != null) {
      await _repository?.updateVaultAccess(
        canWrite: currentVault.canWrite,
        deletionPending: currentVault.status == 'deleting',
      );
    }
    notifyListeners();
  }

  Future<VaultDescriptor> _changeVaultDeletionState({
    required String vaultId,
    required String username,
    required String password,
    required bool cancel,
  }) async {
    _assertEditsAllowed();
    if (vaultLifecycleBusy) throw StateError(currentL10n.aVaultStateActionIsIn);
    final vault =
        _vaultDescriptors.where((item) => item.id == vaultId).firstOrNull ??
        (activeVault?.id == vaultId ? activeVault : null);
    if (vault == null) {
      throw StateError(currentL10n.theVaultOnThisDeviceCouldnt);
    }
    if (vault.role != 'owner') {
      throw StateError(currentL10n.onlyTheVaultOwnerCanManage);
    }
    if (cancel) {
      if (vault.status != 'deleting' || !vault.canCancel) {
        throw StateError(currentL10n.thisVaultHasNoDeletionSchedule);
      }
    } else if (vault.status != 'active' || !vault.canWrite) {
      throw StateError(currentL10n.thisVaultIsntCurrentlyInAn);
    }
    final normalizedUsername = username.trim().toLowerCase();
    if (normalizedUsername.isEmpty || password.isEmpty) {
      throw FormatException(currentL10n.enterTheCurrentAccountNameAnd);
    }
    if (_authenticatedUsername != null &&
        normalizedUsername != _authenticatedUsername) {
      throw FormatException(currentL10n.theReVerifiedAccountMustMatch);
    }
    if (account == null) {
      throw StateError(currentL10n.theCurrentAccountIdentityIsUnavailable);
    }
    if (password.length < 12) {
      throw FormatException(currentL10n.theMasterPasswordMustBeAt3);
    }

    vaultLifecycleBusy = true;
    notifyListeners();
    Uint8List? verifier;
    var submittedRequest = false;
    try {
      final client = _requireApi();
      final prelogin = await client.prelogin(normalizedUsername);
      if (prelogin['account_id'] != account!.accountId) {
        throw FormatException(currentL10n.thisAccountNameDoesntMatchThe);
      }
      final params = KdfParameters.fromJson(
        Map<String, dynamic>.from(prelogin['kdf'] as Map),
      );
      verifier = await crypto.deriveLoginVerifier(password, params);
      final body = <String, Object?>{
        'login_verifier': encodeBase64Url(verifier),
      };
      submittedRequest = true;
      final response = cancel
          ? await client.cancelVaultDeletion(vaultId, body)
          : await client.deleteVault(vaultId, body);
      final updated = vault.withLifecycleResponse(response);
      if (updated.role != 'owner') {
        throw FormatException(currentL10n.theVaultOwnerStateReturnedBy);
      }
      if (cancel) {
        if (updated.status != 'active' ||
            !updated.canWrite ||
            updated.requestedAt != null ||
            updated.purgeAfter != null) {
          throw FormatException(currentL10n.theRevocationStateReturnedByThe);
        }
      } else {
        if (updated.status != 'deleting' ||
            updated.canWrite ||
            !updated.canCancel ||
            !_validRfc3339(updated.requestedAt) ||
            !_validRfc3339(updated.purgeAfter)) {
          throw FormatException(currentL10n.theServerDidntReturnAValid);
        }
      }
      _replaceVaultDescriptor(updated);
      if (activeVault?.id == updated.id) {
        await _repository?.updateVaultAccess(
          canWrite: updated.canWrite,
          deletionPending: updated.status == 'deleting',
        );
        if (cancel) _automaticSync.scheduleEdit();
      }
      errorMessage = null;
      _setNotice(
        cancel
            ? currentL10n.theVaultDeletionScheduleWasCancelled
            : currentL10n.theVaultDeletionScheduleWasCreated,
      );
      return updated;
    } catch (error) {
      if (submittedRequest &&
          !(error is ApiException && error.code == 'REAUTH_REQUIRED')) {
        try {
          await refreshVaultLifecycle();
        } catch (_) {
          // The action error remains visible; a later manual refresh retries.
        }
      }
      errorMessage = friendlyError(error);
      notifyListeners();
      rethrow;
    } finally {
      verifier?.fillRange(0, verifier.length, 0);
      vaultLifecycleBusy = false;
      notifyListeners();
    }
  }

  void _replaceVaultDescriptor(VaultDescriptor updated) {
    final index = _vaultDescriptors.indexWhere((item) => item.id == updated.id);
    if (index < 0) {
      _vaultDescriptors = [..._vaultDescriptors, updated];
    } else {
      final copy = [..._vaultDescriptors];
      copy[index] = updated;
      _vaultDescriptors = copy;
    }
    if (activeVault?.id == updated.id) activeVault = updated;
  }

  bool _validRfc3339(String? value) =>
      value != null && DateTime.tryParse(value)?.isUtc == true;

  Future<void> connectHost(HostRecord host) async {
    if (host.protocol != HostProtocol.ssh) {
      await disconnectAllTerminalTabs();
      return openTerminalTab(host);
    }
    // Keep the historical one-connection behavior for callers that have not
    // adopted the tab API yet. New workspace UI opens tabs explicitly.
    final resolution = resolveHostCredential(
      host: host,
      groupId: host.groupId,
      hostCredentialId: host.credentialId,
    );
    if (!resolution.isResolved) throw StateError(resolution.connectionError);
    // Resolve the full bounded route before disconnecting any existing tabs.
    _resolveJumpHostConnection(host);
    await disconnectAllTerminalTabs();
    await openTerminalTab(host);
  }

  List<_ResolvedJumpHop> _resolveJumpHostConnection(HostRecord host) {
    final hostsById = <String, HostRecord>{
      for (final candidate in hosts) candidate.id: candidate,
      host.id: host,
    };
    final routeIssue = _jumpHostRouteIssueFor(host, hostsById);
    if (routeIssue != null) throw StateError(routeIssue);
    final reverseRoute = <_ResolvedJumpHop>[];
    var nextId = host.jumpHostId;
    while (nextId != null) {
      final jumpHost = hostsById[nextId]!;
      final resolution = resolveHostCredential(
        host: jumpHost,
        groupId: jumpHost.groupId,
        hostCredentialId: jumpHost.credentialId,
      );
      final jumpCredential = resolution.credential;
      if (jumpCredential == null) {
        throw StateError(
          currentL10n.couldntResolveTheSshCredentialFor(
            jumpHost.name,
            resolution.connectionError,
          ),
        );
      }
      reverseRoute.add((host: jumpHost, credential: jumpCredential));
      nextId = jumpHost.jumpHostId;
    }
    return reverseRoute.reversed.toList(growable: false);
  }

  Future<String> _fingerprintConnectionCredential(
    CredentialRecord credential,
  ) async {
    final digest = await cryptography.Sha256().hash(
      utf8.encode(canonicalJson(credential.toJson())),
    );
    return base64Url.encode(digest.bytes);
  }

  TerminalTabSession _addDeviceTab(HostRecord host) {
    if (workspaceLocked || stage != ClientStage.workspace) {
      throw StateError(currentL10n.unlockTheWorkspaceFirst);
    }
    if (_terminalTabs.length >= maxTerminalTabs) {
      throw StateError(currentL10n.closeASessionTabFirst);
    }
    final tab = _createTerminalTab(id: _uuid.v4(), host: host);
    _terminalTabs[tab.id] = tab;
    _terminalTabOrder.add(tab.id);
    _activeTerminalTabId = tab.id;
    selectedHost = host;
    page = WorkspacePage.terminal;
    return tab;
  }

  Future<void> _openDesktopTab(
    HostRecord host, {
    void Function(String)? onTabOpened,
  }) async {
    final client = _requireApi();
    final deviceId = identity?.deviceId;
    if (!DesktopSession.supportsDirect(host.protocol) &&
        (deviceId == null || session == null)) {
      throw StateError(currentL10n.remoteDesktopRequiresASignIn);
    }
    final issue = host.validate();
    if (issue != null) throw StateError(issue);
    final tab = _addDeviceTab(host);
    final reviewedVault = activeVault?.id;
    final reviewedAccount = session?.accountId;
    final reviewedDevice = identity?.deviceId;
    bool current() =>
        _isTerminalTabOpen(tab) &&
        !workspaceLocked &&
        stage == ClientStage.workspace &&
        activeVault?.id == reviewedVault &&
        session?.accountId == reviewedAccount &&
        identity?.deviceId == reviewedDevice;
    final desktop = DesktopSession(
      saveRdpCertificate: (reviewed, pin) async {
        final saved = await RdpCertificatePersistence.saveCloud(
          controller: this,
          reviewed: reviewed,
          pin: pin,
          isCurrent: current,
        );
        if (!current()) throw StateError(currentL10n.theWorkspaceChanged);
        tab.host = saved;
        return saved;
      },
      // In-session display changes persist at the current Host revision and
      // only while the same vault/account/device workspace is active.
      saveDisplaySettings: (updated) async {
        final saved = await DesktopDisplayPersistence.saveCloud(
          controller: this,
          updated: updated,
          isCurrent: current,
        );
        if (!current()) throw StateError(currentL10n.theWorkspaceChanged);
        tab.host = saved;
        _notifyListenersIfAlive();
        return saved;
      },
    );
    tab.desktop = desktop;
    desktop.addListener(() {
      if (!_isTerminalTabOpen(tab)) return;
      tab.state = desktop.state;
      tab.errorMessage = desktop.error;
      _notifyListenersIfAlive();
    });
    onTabOpened?.call(tab.id);
    notifyListeners();
    if (DesktopSession.supportsDirect(host.protocol)) {
      await desktop.connectLocal(host);
    } else {
      await desktop.connect(client, deviceId!, host);
    }
  }

  /// Opens a plaintext Telnet terminal tab (RFC 854) for [host].
  ///
  /// Login is interactive in the terminal: no credential is resolved, no
  /// saved password or key is sent and login prompts are never parsed.
  /// Native platforms connect directly over TCP; browsers use the
  /// authenticated server Relay (same ticket, allowlist and audit policy as
  /// SSH) and fail with an explicit unsupported error without one.
  Future<void> _openTelnetTab(
    HostRecord host, {
    String? expectedVaultId,
    void Function(String tabId)? onTabOpened,
  }) async {
    final issue = host.validate();
    if (issue != null) throw StateError(issue);
    // Saved-workspace restore binds the request to the Vault it was prepared
    // for and to a Host that still exists there (same guard as SSH).
    if (expectedVaultId != null) {
      if (activeVault?.id != expectedVaultId) {
        throw StateError(currentL10n.theVaultWasSwitchedWhilePreparing);
      }
      if (!hosts.any((candidate) => candidate.id == host.id)) {
        throw StateError(currentL10n.theWorkspaceHostWasRemovedFrom);
      }
    }
    final testConnector = telnetConnectorForTesting;
    final client = api;
    final deviceId = identity?.deviceId;
    final useRelay = testConnector == null && !telnetDirectTcpSupported;
    if (useRelay && (client == null || deviceId == null || session == null)) {
      throw const TelnetException(TelnetFailure.unsupportedPlatform);
    }
    final tab = _addDeviceTab(host);
    final reviewedVault = activeVault?.id;
    final reviewedAccount = session?.accountId;
    final reviewedDevice = identity?.deviceId;
    bool current() =>
        _isTerminalTabOpen(tab) &&
        !workspaceLocked &&
        stage == ClientStage.workspace &&
        activeVault?.id == reviewedVault &&
        session?.accountId == reviewedAccount &&
        identity?.deviceId == reviewedDevice;
    final cancellation = TelnetConnectCancellation();
    tab.telnetCancellation = cancellation;
    tab.connectionCancellation = null;
    tab.log = sessionLogs.begin(host: host, viaJump: false);
    tab.terminal.write(telnetPlaintextTerminalNotice(host.endpoint));
    onTabOpened?.call(tab.id);
    notifyListeners();
    try {
      final telnet = await TelnetSession.connect(
        host: host.address,
        port: host.port,
        connector:
            testConnector ??
            (useRelay
                ? (address, port) => connectTelnetViaRelay(
                    api: client!,
                    deviceId: deviceId!,
                    host: address,
                    port: port,
                  )
                : connectTelnetDirect),
        cancellation: cancellation,
        columns: tab.terminal.viewWidth,
        rows: tab.terminal.viewHeight,
      );
      if (!current() || cancellation.isCancelled) {
        // Closed, locked or switched scope while connecting: never attach a
        // late connection to a stale or reused tab.
        await telnet.close();
        if (_isTerminalTabOpen(tab)) {
          tab.telnetCancellation = null;
          tab.state = 'failed';
          tab.errorMessage = currentL10n.theWorkspaceChanged;
          _notifyListenersIfAlive();
        }
        return;
      }
      tab.telnet = telnet;
      tab.telnetCancellation = null;
      tab.state = 'connected';
      tab.errorMessage = null;
      tab.log?.markConnected();
      tab.outputSubscription = telnet.output.listen(
        (text) {
          // Queued output must not publish after the tab closed or the
          // workspace scope changed.
          if (!current() || !identical(tab.telnet, telnet)) return;
          tab.terminal.write(text);
          tab.log?.output(text);
          tab.outputListener?.call(text);
          tab.publishOutputToFanout(text);
          if (_activeTerminalTabId == tab.id) {
            _legacyTerminalOutputListener?.call(text);
          }
        },
        onError: (Object error) =>
            _handleTelnetConnectionEnded(tab, telnet, error: error),
        onDone: () => _handleTelnetConnectionEnded(tab, telnet),
      );
      // The view may have been laid out while connecting.
      telnet.resize(tab.terminal.viewWidth, tab.terminal.viewHeight);
      _setNotice(currentL10n.telnetConnectedToEndpoint(host.endpoint));
      notifyListeners();
    } catch (error) {
      if (!_isTerminalTabOpen(tab)) return;
      tab.telnetCancellation = null;
      tab.log?.markFailed(error);
      tab.state = 'failed';
      tab.errorMessage = friendlyError(error);
      _setError(friendlyError(error));
      rethrow;
    }
  }

  void _handleTelnetConnectionEnded(
    TerminalTabSession tab,
    TelnetSession telnet, {
    Object? error,
  }) {
    if (!_isTerminalTabOpen(tab) || !identical(tab.telnet, telnet)) return;
    final subscription = tab.outputSubscription;
    tab.outputSubscription = null;
    tab.telnet = null;
    tab.state = 'disconnected';
    tab.log?.markClosed(
      error == null ? SessionLogEndReason.remote : SessionLogEndReason.error,
      error: error,
    );
    if (error != null) tab.errorMessage = friendlyError(error);
    tab.terminal.write(currentL10n.telnetConnectionClosedTerminal);
    if (_terminalShareHosts.containsKey(tab.id)) {
      unawaited(stopTerminalShareFor(tab.id));
    }
    _notifyListenersIfAlive();
    unawaited(() async {
      try {
        await subscription?.cancel();
      } catch (_) {}
      await telnet.close();
    }());
  }

  /// Test seam: replaces the native PTY / serial console opener.
  @visibleForTesting
  LocalConsole Function({
    LocalShellLaunch? shell,
    String? serialPort,
    int baudRate,
  })?
  localConsoleOpenerForTesting;

  /// Opens a local shell (no [serialPort]) or a Windows COM console. The
  /// signature is kept for MCP/quick-connect callers; see [openLocalShellTab].
  Future<void> openConsoleTab({
    String? serialPort,
    int baudRate = 115200,
  }) async {
    if (serialPort == null) {
      await openLocalShellTab();
    } else {
      await _openConsoleTab(serialPort: serialPort, baudRate: baudRate);
    }
  }

  /// Starts an embedded local shell in its own PTY and returns the new tab id
  /// (null when the tab could not be created). Startup failures leave a
  /// disconnected tab with a sanitized, localized reason.
  Future<String?> openLocalShellTab({
    LocalShellLaunch launch = LocalShellLaunch.systemDefault,
  }) => _openConsoleTab(shell: launch);

  /// Opens an independent copy of a Console tab: a serial console reopens the
  /// same COM port/baud (never a shell), and a local shell reuses its shell
  /// kind and the shell's current (or launch) working directory.
  Future<String?> duplicateConsoleTab(String id) async {
    final source = _terminalTabs[id];
    if (source == null || source.closed || source.console == null) return null;
    final serialPort = source.consoleSerialPort;
    if (serialPort != null) {
      return _openConsoleTab(
        serialPort: serialPort,
        baudRate: source.consoleBaudRate ?? 115200,
      );
    }
    var launch = source.consoleShell ?? LocalShellLaunch.systemDefault;
    if (source.console case final LocalConsoleWorkingDirectory probe) {
      final cwd = await probe
          .currentWorkingDirectory()
          .timeout(const Duration(seconds: 1), onTimeout: () => null)
          .catchError((Object _) => null);
      if (cwd != null && isPlausibleLocalShellWorkingDirectory(cwd)) {
        launch = launch.copyWith(workingDirectory: cwd);
      }
    }
    if (!_isTerminalTabOpen(source)) return null;
    return _openConsoleTab(shell: launch);
  }

  Future<String?> _openConsoleTab({
    LocalShellLaunch? shell,
    String? serialPort,
    int baudRate = 115200,
  }) async {
    if (!localConsoleSupported && localConsoleOpenerForTesting == null) {
      throw UnsupportedError(currentL10n.theLocalConsoleRequiresTheDesktop);
    }
    final launch = serialPort == null
        ? shell ?? LocalShellLaunch.systemDefault
        : null;
    final tab = _addDeviceTab(
      HostRecord(
        id: _uuid.v4(),
        name: serialPort != null
            ? '$serialPort · $baudRate'
            : localShellTabTitle(currentL10n, launch!),
        address: 'localhost',
      ),
    );
    tab.consoleSerialPort = serialPort;
    tab.consoleBaudRate = serialPort == null ? null : baudRate;
    tab.consoleShell = launch;
    notifyListeners();
    try {
      final opener = localConsoleOpenerForTesting;
      final console = opener != null
          ? opener(shell: launch, serialPort: serialPort, baudRate: baudRate)
          : serialPort == null
          ? openLocalConsole(launch: launch!)
          : openSerialConsole(serialPort, baudRate: baudRate);
      if (!_isTerminalTabOpen(tab)) {
        // The tab was closed (or the workspace reset) while starting.
        unawaited(console.close().catchError((Object _) {}));
        return null;
      }
      tab.console = console;
      tab.state = 'connected';
      tab.outputSubscription = console.output.listen(
        (text) {
          if (_isTerminalTabOpen(tab)) tab.terminal.write(text);
        },
        onError: (_) {
          if (_isTerminalTabOpen(tab)) {
            tab.state = 'disconnected';
            tab.errorMessage = currentL10n.theConsoleOutputStreamClosed;
            _notifyListenersIfAlive();
          }
        },
        cancelOnError: true,
      );
      unawaited(
        console.exitCode.then((code) {
          if (!_isTerminalTabOpen(tab) || !identical(tab.console, console)) {
            return;
          }
          tab.state = 'disconnected';
          tab.terminal.write(currentL10n.consoleExitedCode(code));
          _notifyListenersIfAlive();
        }, onError: (Object _) {}),
      );
    } on LocalShellException catch (error) {
      tab.state = 'disconnected';
      tab.errorMessage = localShellIssueMessage(currentL10n, error.issue);
      tab.terminal.write('\r\n[${tab.errorMessage}]\r\n');
    } catch (_) {
      tab.state = 'disconnected';
      tab.errorMessage = currentL10n.couldntStartTheLocalShell;
      tab.terminal.write('\r\n[${tab.errorMessage}]\r\n');
    }
    _notifyListenersIfAlive();
    return tab.id;
  }

  /// Opens and connects an SSH tab through the normal credential, Jump Host
  /// and known-host flow. [onTabOpened] receives the new tab id as soon as
  /// the tab exists (before authentication), so a caller can bind follow-up
  /// work (for example a forwarding start) to exactly this tab.
  Future<void> openTerminalTab(
    HostRecord host, {
    void Function(String tabId)? onTabOpened,
  }) => _openTerminalTab(host, onTabOpened: onTabOpened);

  Future<void> _openTerminalTab(
    HostRecord host, {
    String? expectedVaultId,
    void Function(String tabId)? onTabOpened,
  }) async {
    if (host.protocol == HostProtocol.telnet) {
      return _openTelnetTab(
        host,
        expectedVaultId: expectedVaultId,
        onTabOpened: onTabOpened,
      );
    }
    if (host.protocol != HostProtocol.ssh) {
      return _openDesktopTab(host, onTabOpened: onTabOpened);
    }
    final initialKnownHostAccountId = session?.accountId;
    final initialKnownHostDeviceId = identity?.deviceId;
    final initialKnownHostVaultId = activeVault?.id;
    if (_terminalTabs.length >= maxTerminalTabs) {
      throw StateError(
        currentL10n.upToMaxterminaltabsSshTerminalTabs(maxTerminalTabs),
      );
    }
    final resolution = resolveHostCredential(
      host: host,
      groupId: host.groupId,
      hostCredentialId: host.credentialId,
    );
    final credential = resolution.credential;
    if (credential == null) throw StateError(resolution.connectionError);
    final hostSnapshot = canonicalJson(host.toJson());
    final targetCredentialSnapshot = canonicalJson(credential.toJson());
    final jumpRoute = _resolveJumpHostConnection(host);
    final jumpRouteSnapshots = jumpRoute
        .map(
          (hop) => (
            canonicalJson(hop.host.toJson()),
            canonicalJson(hop.credential.toJson()),
          ),
        )
        .toList(growable: false);
    final connectionCredentialFingerprints = <String, String>{
      host.id: await _fingerprintConnectionCredential(credential),
      for (final hop in jumpRoute)
        hop.host.id: await _fingerprintConnectionCredential(hop.credential),
    };
    final currentHost = hosts
        .where((candidate) => candidate.id == host.id)
        .firstOrNull;
    if (expectedVaultId != null && activeVault?.id != expectedVaultId) {
      throw StateError(currentL10n.theVaultWasSwitchedWhilePreparing);
    }
    if (expectedVaultId != null && currentHost == null) {
      throw StateError(currentL10n.theWorkspaceHostWasRemovedFrom);
    }
    if (currentHost != null &&
        canonicalJson(currentHost.toJson()) != hostSnapshot) {
      throw StateError(currentL10n.theHostOrJumpHostRoute);
    }
    final currentTargetCredential = resolveHostCredential(
      groupId: currentHost == null ? host.groupId : currentHost.groupId,
      hostCredentialId: currentHost == null
          ? host.credentialId
          : currentHost.credentialId,
    ).credential;
    if (currentTargetCredential == null ||
        canonicalJson(currentTargetCredential.toJson()) !=
            targetCredentialSnapshot) {
      throw StateError(currentL10n.theTargetHostsSshCredentialChanged);
    }
    final currentRoute = _resolveJumpHostConnection(currentHost ?? host);
    if (currentRoute.length != jumpRoute.length) {
      throw StateError(currentL10n.theJumpHostRouteChangedWhile);
    }
    for (var index = 0; index < currentRoute.length; index++) {
      if (canonicalJson(currentRoute[index].host.toJson()) !=
              jumpRouteSnapshots[index].$1 ||
          canonicalJson(currentRoute[index].credential.toJson()) !=
              jumpRouteSnapshots[index].$2 ||
          !connectionCredentialFingerprints.containsKey(
            currentRoute[index].host.id,
          )) {
        throw StateError(currentL10n.theJumpHostRouteOrCredential);
      }
    }
    if (jumpRoute.length > 1 &&
        (sshConnectorForTesting != null ||
            sshConnectorWithJumpForTesting != null) &&
        sshConnectorWithRouteForTesting == null &&
        sshConnectorWithUserInfoForTesting == null &&
        sshConnectorWithCancellationForTesting == null) {
      throw StateError(currentL10n.theCurrentTestSshConnectorDoesnt2);
    }
    final hasTestConnector =
        sshConnectorForTesting != null ||
        sshConnectorWithJumpForTesting != null ||
        sshConnectorWithRouteForTesting != null ||
        sshConnectorWithUserInfoForTesting != null ||
        sshConnectorWithCancellationForTesting != null;
    final client = hasTestConnector ? api : _requireApi();
    if (session == null || identity == null) {
      throw StateError(currentL10n.unlockTheVaultFirst2);
    }
    selectedHost = host;
    page = WorkspacePage.terminal;
    final id = _uuid.v4();
    final tab = _createTerminalTab(id: id, host: host);
    tab.connectionCredentialFingerprints.addAll(
      connectionCredentialFingerprints,
    );
    tab.connectionHostSnapshots[host.id] = hostSnapshot;
    for (var index = 0; index < jumpRoute.length; index++) {
      tab.connectionHostSnapshots[jumpRoute[index].host.id] =
          jumpRouteSnapshots[index].$1;
    }
    _terminalTabs[id] = tab;
    _terminalTabOrder.add(id);
    _activeTerminalTabId = id;
    tab.log = sessionLogs.begin(host: host, viaJump: jumpRoute.isNotEmpty);
    tab.shellHistoryRestoration = _restoreTerminalShellHistory(tab);
    unawaited(tab.shellHistoryRestoration);
    onTabOpened?.call(id);
    notifyListeners();
    SshHostKeyFailure? hostKeyFailure;
    KnownHostApprovalRequest? hostKeyDecisionToResolve;
    // A full SSH retry starts at the first Jump Host again. Keep each
    // endpoint proof only for this bounded route setup so a later-hop review
    // does not force already reviewed earlier hops through another Vault sync.
    // This map is local to this openTerminalTab call and cannot authorize a
    // later tab or connection attempt.
    final verifiedHostKeyProofs = <String, _VerifiedTerminalHostKeyProof>{};
    try {
      Future<bool> verifyHostKeyFor(
        HostRecord keyHost,
        String type,
        String fingerprint,
      ) async {
        try {
          if (!_isTerminalTabOpen(tab)) return false;
          final canonicalHost = canonicalizeKnownHost(keyHost.address);
          final presentedProof = VerifiedTerminalHostKey(
            host: canonicalHost,
            port: keyHost.port,
            algorithm: type,
            fingerprint: fingerprint,
          );
          // Reuse only a proof for this exact canonical endpoint, algorithm,
          // and fingerprint while this route setup is in progress. Recheck
          // the current account/device/Vault scope and the authenticated local
          // KnownHost projection for every handshake. An unrelated repository
          // rebuild may advance the decision generation during approval of a
          // later hop; revalidate the exact endpoint in the current repository
          // instead of forcing every earlier hop through another full route
          // restart.
          final verifiedProof = verifiedHostKeyProofs[presentedProof.proofKey];
          if (verifiedProof != null) {
            final verifiedRepository = verifiedProof.repository;
            final usingTestTrust = knownHostTrustStatusForTesting != null;
            final testProofStillCurrent =
                usingTestTrust &&
                (verifiedRepository == null ||
                    identical(_repository, verifiedRepository)) &&
                verifiedProof.generation == _knownHostDecisionGeneration;
            final scopeStillCurrent =
                verifiedProof.hostKey.proofKey == presentedProof.proofKey &&
                verifiedProof.accountId == session?.accountId &&
                verifiedProof.deviceId == identity?.deviceId &&
                verifiedProof.deviceId == session?.deviceId &&
                verifiedProof.vaultId == activeVault?.id;
            void requestFreshDecision() {
              hostKeyDecisionToResolve = KnownHostApprovalRequest(
                host: canonicalHost,
                port: keyHost.port,
                algorithm: type,
                fingerprint: fingerprint,
                previouslyRevoked: false,
              );
            }

            if (!scopeStillCurrent) {
              verifiedHostKeyProofs.remove(presentedProof.proofKey);
              throw StateError(currentL10n.sshHostKeyApprovalProofAccount);
            }
            if (usingTestTrust) {
              if (!testProofStillCurrent) {
                verifiedHostKeyProofs.remove(presentedProof.proofKey);
                requestFreshDecision();
                return false;
              }
            } else {
              if (_knownHostStateTransitionPending) {
                verifiedHostKeyProofs.remove(presentedProof.proofKey);
                requestFreshDecision();
                return false;
              }
              _ensureKnownHostDecisionCurrent();
              _ensureKnownHostDecisionScopeCurrent(
                accountId: verifiedProof.accountId,
                deviceId: verifiedProof.deviceId,
                vaultId: verifiedProof.vaultId,
              );
              final currentRepository = _repository;
              if (currentRepository == null) {
                verifiedHostKeyProofs.remove(presentedProof.proofKey);
                requestFreshDecision();
                return false;
              }
              final generationBeforeTrustRead = _knownHostDecisionGeneration;
              // A route proof may be reused across hops/retries, but local
              // KnownHost state can change without rebuilding the Repository
              // (for example, a revocation queued from another route). Recheck
              // the authenticated local projection and exact outbox state
              // without holding this SSH handshake open for a network pull.
              final cachedTrust = await currentRepository
                  .cachedKnownHostTrustSnapshot(
                    host: canonicalHost,
                    port: keyHost.port,
                    algorithm: type,
                    fingerprint: fingerprint,
                  );
              if (verifiedProof.accountId != session?.accountId ||
                  verifiedProof.deviceId != identity?.deviceId ||
                  verifiedProof.deviceId != session?.deviceId ||
                  verifiedProof.vaultId != activeVault?.id) {
                verifiedHostKeyProofs.remove(presentedProof.proofKey);
                throw StateError(currentL10n.sshHostKeyApprovalProofAccount);
              }
              if (!identical(_repository, currentRepository) ||
                  _knownHostStateTransitionPending ||
                  generationBeforeTrustRead != _knownHostDecisionGeneration) {
                verifiedHostKeyProofs.remove(presentedProof.proofKey);
                requestFreshDecision();
                return false;
              }
              if (cachedTrust.status != KnownHostTrustStatus.trusted) {
                verifiedHostKeyProofs.remove(presentedProof.proofKey);
                requestFreshDecision();
                return false;
              }
              if (!identical(verifiedRepository, currentRepository) ||
                  verifiedProof.generation != generationBeforeTrustRead) {
                // The proof remains valid only because the exact current
                // endpoint/fingerprint is still trusted in the current
                // authenticated projection. Refresh its route-local binding
                // so subsequent hops do not restart this route again.
                verifiedHostKeyProofs[presentedProof.proofKey] =
                    _VerifiedTerminalHostKeyProof(
                      hostKey: presentedProof,
                      repository: currentRepository,
                      generation: generationBeforeTrustRead,
                      accountId: verifiedProof.accountId,
                      deviceId: verifiedProof.deviceId,
                      vaultId: verifiedProof.vaultId,
                    );
              }
            }
            tab.verifiedHostKeys[presentedProof.key] = presentedProof;
            return true;
          }
          // End this SSH handshake before pulling the Vault. SSH servers
          // commonly enforce a short LoginGraceTime, so even an already
          // trusted key must not hold the transport open during sync. The
          // outer loop resolves the current trust state, then retries with a
          // route-scoped proof bound to that exact key and Vault scope.
          hostKeyDecisionToResolve = KnownHostApprovalRequest(
            host: canonicalHost,
            port: keyHost.port,
            algorithm: type,
            fingerprint: fingerprint,
            previouslyRevoked: false,
          );
          return false;
        } catch (error) {
          rethrow;
        }
      }

      Future<bool> verifyHostKey(String type, String fingerprint) =>
          verifyHostKeyFor(host, type, fingerprint);
      final sshJumpHops = jumpRoute
          .map(
            (hop) => SshJumpHop(
              host: hop.host,
              credential: hop.credential,
              verifyHostKey: (type, fingerprint) =>
                  verifyHostKeyFor(hop.host, type, fingerprint),
            ),
          )
          .toList(growable: false);
      Future<bool> verifyLegacyJumpHostKey(String type, String fingerprint) =>
          jumpRoute.isEmpty
          ? Future<bool>.value(false)
          : verifyHostKeyFor(jumpRoute.last.host, type, fingerprint);

      final connector = sshConnectorForTesting;
      final jumpConnector = sshConnectorWithJumpForTesting;
      final routeConnector = sshConnectorWithRouteForTesting;
      final userInfoConnector = sshConnectorWithUserInfoForTesting;
      final cancellationConnector = sshConnectorWithCancellationForTesting;
      final connectCancellation = tab.connectionCancellation!;
      final maxHostKeyRestarts = (jumpRoute.length + 1) * 2;
      var hostKeyRestartCount = 0;
      late SshConnection connection;
      while (true) {
        hostKeyDecisionToResolve = null;
        SshConnection? attemptConnection;
        try {
          attemptConnection = cancellationConnector != null
              ? await cancellationConnector(
                  host: host,
                  credential: credential,
                  verifyHostKey: verifyHostKey,
                  jumpHops: sshJumpHops,
                  cancellation: connectCancellation,
                  onUserInfoRequest: (challengeHost, request) =>
                      _requestSshUserInfo(tab, challengeHost, request),
                )
              : userInfoConnector != null
              ? await userInfoConnector(
                  host: host,
                  credential: credential,
                  verifyHostKey: verifyHostKey,
                  jumpHops: sshJumpHops,
                  onUserInfoRequest: (challengeHost, request) =>
                      _requestSshUserInfo(tab, challengeHost, request),
                )
              : routeConnector != null
              ? await routeConnector(
                  host: host,
                  credential: credential,
                  verifyHostKey: verifyHostKey,
                  jumpHops: sshJumpHops,
                )
              : jumpConnector != null
              ? await jumpConnector(
                  host: host,
                  credential: credential,
                  verifyHostKey: verifyHostKey,
                  jumpHost: jumpRoute.isEmpty ? null : jumpRoute.last.host,
                  jumpCredential: jumpRoute.isEmpty
                      ? null
                      : jumpRoute.last.credential,
                  verifyJumpHostKey: jumpRoute.isEmpty
                      ? null
                      : verifyLegacyJumpHostKey,
                )
              : connector != null && jumpRoute.isEmpty
              ? await connector(
                  host: host,
                  credential: credential,
                  verifyHostKey: verifyHostKey,
                )
              : connector != null
              ? throw StateError(currentL10n.theCurrentTestSshConnectorDoesnt)
              : await SshService(
                  api: client!,
                  deviceId: identity!.deviceId,
                  knownHostDecisionLock: _knownHostDecisionLock,
                ).connect(
                  host: host,
                  credential: credential,
                  verifyHostKey: verifyHostKey,
                  jumpHops: sshJumpHops,
                  knownHostDecisionScope:
                      _requireRepository().knownHostDecisionScope,
                  cancellation: connectCancellation,
                  onUserInfoRequest: (challengeHost, request) =>
                      _requestSshUserInfo(tab, challengeHost, request),
                );
        } catch (_) {
          if (hostKeyDecisionToResolve == null) rethrow;
        }

        final request = hostKeyDecisionToResolve;
        if (request == null) {
          connection = attemptConnection!;
          break;
        }
        await attemptConnection?.close();
        if (++hostKeyRestartCount > maxHostKeyRestarts) {
          throw StateError(currentL10n.tooManySshHostKeyChecks);
        }
        if (!_isTerminalTabOpen(tab)) return;
        var decision = await _knownHostTrustDecision(
          host: request.host,
          port: request.port,
          algorithm: request.algorithm,
          fingerprint: request.fingerprint,
        );
        if (!_isTerminalTabOpen(tab)) return;
        final usingTestTrust = knownHostTrustStatusForTesting != null;
        if (!usingTestTrust) {
          _ensureKnownHostDecisionScopeCurrent(
            accountId: initialKnownHostAccountId,
            deviceId: initialKnownHostDeviceId,
            vaultId: initialKnownHostVaultId,
          );
        } else if (decision.generation != _knownHostDecisionGeneration) {
          throw StateError(currentL10n.sshHostKeyTestDecisionBecame);
        }
        if (decision.status == KnownHostTrustStatus.changed ||
            decision.status == KnownHostTrustStatus.conflict) {
          hostKeyFailure = SshHostKeyFailure.changed;
          throw SshHostKeyVerificationException(hostKeyFailure!);
        }

        if (decision.status != KnownHostTrustStatus.trusted) {
          final approvalRequest = KnownHostApprovalRequest(
            host: request.host,
            port: request.port,
            algorithm: request.algorithm,
            fingerprint: request.fingerprint,
            previouslyRevoked: decision.status == KnownHostTrustStatus.revoked,
            offlineTransportUnavailable: decision.offlineTransportUnavailable,
          );
          final confirmDetailed = askTrustHostApproval;
          final confirmLegacy = askTrustHost;
          final approved = confirmDetailed != null
              ? await confirmDetailed(approvalRequest)
              : confirmLegacy != null
              ? await confirmLegacy(
                  endpointKey(host: request.host, port: request.port),
                  request.fingerprint,
                )
              : false;
          if (!_isTerminalTabOpen(tab) || !approved) {
            hostKeyFailure = SshHostKeyFailure.rejected;
            throw SshHostKeyVerificationException(hostKeyFailure!);
          }
          var approvalWasQueuedOffline = false;
          await approveKnownHost(
            host: approvalRequest.host,
            port: approvalRequest.port,
            algorithm: approvalRequest.algorithm,
            fingerprint: approvalRequest.fingerprint,
            offlineFirstApprovalWasConfirmed:
                approvalRequest.offlineTransportUnavailable,
            onOfflineApprovalQueued: () => approvalWasQueuedOffline = true,
          );
          if (approvalWasQueuedOffline) {
            // A queued local record is not yet a Vault-confirmed SSH trust.
            // The current handshake always stops; a later retry must sync and
            // resolve any concurrent approval or revocation first.
            throw const KnownHostApprovalQueuedException();
          }
          // Approval performs a Vault pull/push/readback, which may replace
          // the repository or advance the decision generation while the
          // review dialog is open. Resolve trust again after that sync so
          // the route-scoped SSH proof is bound to the confirmed current state.
          try {
            decision = await _knownHostTrustDecision(
              host: approvalRequest.host,
              port: approvalRequest.port,
              algorithm: approvalRequest.algorithm,
              fingerprint: approvalRequest.fingerprint,
            );
          } on StateError {
            if (_knownHostStateTransitionPending ||
                _vaultMembershipChangeActive) {
              continue;
            }
            rethrow;
          }
          if (decision.status == KnownHostTrustStatus.changed ||
              decision.status == KnownHostTrustStatus.conflict) {
            hostKeyFailure = SshHostKeyFailure.changed;
            throw SshHostKeyVerificationException(hostKeyFailure!);
          }
          if (decision.status != KnownHostTrustStatus.trusted) {
            throw StateError(currentL10n.vaultSyncDidNotConfirmThe);
          }
        }

        if (!usingTestTrust) {
          _ensureKnownHostDecisionScopeCurrent(
            accountId: initialKnownHostAccountId,
            deviceId: initialKnownHostDeviceId,
            vaultId: initialKnownHostVaultId,
          );
          // Membership and snapshot refreshes can begin after a successful
          // preflight (for example, while a reviewed approval is syncing).
          // Keep the transport closed and resolve the decision again on the
          // next bounded pass instead of failing the user's connection or
          // carrying a proof across the transition.
          if (_knownHostStateTransitionPending ||
              _vaultMembershipChangeActive) {
            continue;
          }
          _ensureKnownHostDecisionCurrent();
        }
        if ((decision.repository != null &&
                !identical(_repository, decision.repository)) ||
            decision.generation != _knownHostDecisionGeneration) {
          if (!usingTestTrust) continue;
          throw StateError(currentL10n.sshHostKeyTestDecisionBecame);
        }
        final verifiedProof = VerifiedTerminalHostKey(
          host: request.host,
          port: request.port,
          algorithm: request.algorithm,
          fingerprint: request.fingerprint,
        );
        verifiedHostKeyProofs[verifiedProof.proofKey] =
            _VerifiedTerminalHostKeyProof(
              hostKey: verifiedProof,
              repository: decision.repository,
              generation: decision.generation,
              accountId: session?.accountId,
              deviceId: identity?.deviceId,
              vaultId: activeVault?.id,
            );
        if (!_isTerminalTabOpen(tab)) return;
      }

      if (!_isTerminalTabOpen(tab)) {
        await connection.close();
        return;
      }
      tab.connection = connection;
      transferSshConnectOwnership(connection);
      tab.connectionCancellation = null;
      tab.state = 'connected';
      tab.errorMessage = null;
      tab.log?.markConnected();
      tab.outputSubscription = connection.output.listen(
        (text) {
          tab.terminal.write(text);
          tab.log?.output(text);
          tab.outputListener?.call(text);
          tab.publishOutputToFanout(text);
          if (_activeTerminalTabId == tab.id) {
            _legacyTerminalOutputListener?.call(text);
          }
        },
        onError: (Object error) {
          _handleTerminalConnectionEnded(tab, connection, error: error);
        },
        onDone: () {
          _handleTerminalConnectionEnded(tab, connection);
        },
      );
      _setNotice(currentL10n.sshConnectedToEndpoint(host.endpoint));
      notifyListeners();
    } catch (error) {
      if (!_isTerminalTabOpen(tab)) return;
      tab.cancelPendingSshAuthentication();
      tab.log?.markFailed(
        hostKeyFailure == null
            ? error
            : SshHostKeyVerificationException(hostKeyFailure!),
      );
      tab.state = 'failed';
      tab.errorMessage = friendlyError(
        hostKeyFailure == null
            ? error
            : SshHostKeyVerificationException(hostKeyFailure!),
      );
      final failure = hostKeyFailure;
      _setError(
        friendlyError(
          failure == null ? error : SshHostKeyVerificationException(failure),
        ),
      );
      rethrow;
    }
  }

  void _handleTerminalConnectionEnded(
    TerminalTabSession tab,
    SshConnection connection, {
    Object? error,
  }) {
    if (!_isTerminalTabOpen(tab) || !identical(tab.connection, connection)) {
      return;
    }
    final subscription = tab.outputSubscription;
    tab.outputSubscription = null;
    final tmuxHandle = _tmuxAttachHandles.remove(tab.id);
    tmuxHandle?.close();
    _tmuxOperationCancellations.remove(tab.id)?.cancel();
    _clearShellIntegrationFor(tab);
    tab.connection = null;
    tab.sftp = null;
    tab.sftpOpening = null;
    tab.state = 'disconnected';
    tab.log?.markClosed(
      error == null ? SessionLogEndReason.remote : SessionLogEndReason.error,
      error: error,
    );
    if (error != null) tab.errorMessage = friendlyError(error);
    if (_terminalShareHosts.containsKey(tab.id)) {
      unawaited(stopTerminalShareFor(tab.id));
    }
    _notifyListenersIfAlive();
    unawaited(_cleanupEndedTerminalConnection(subscription, connection));
  }

  Future<void> _cleanupEndedTerminalConnection(
    StreamSubscription<String>? subscription,
    SshConnection connection,
  ) async {
    try {
      await subscription?.cancel();
    } catch (_) {
      // The stream has already ended; a cancellation race is harmless here.
    }
    try {
      await connection.close();
    } catch (_) {
      // Do not turn an already-reported stream failure into an unhandled error.
    }
  }

  bool _isTerminalTabOpen(TerminalTabSession tab) =>
      !tab.closed && identical(_terminalTabs[tab.id], tab);

  Future<List<String>?> _requestSshUserInfo(
    TerminalTabSession tab,
    HostRecord host,
    SSHUserInfoRequest request,
  ) async {
    if (!_isTerminalTabOpen(tab)) {
      throw const SshKeyboardInteractiveCancelled();
    }
    final ask = askSshUserInfo;
    if (ask == null) throw const SshKeyboardInteractiveCancelled();
    final cancelled = tab.sshAuthenticationCancelled.future;
    final responses = await Future.any<List<String>?>([
      ask(host, request, cancelled),
      cancelled.then<List<String>?>((_) => null),
    ]);
    if (!_isTerminalTabOpen(tab) ||
        responses == null ||
        responses.length != request.prompts.length) {
      throw const SshKeyboardInteractiveCancelled();
    }
    return responses;
  }

  TerminalTabSession _createTerminalTab({
    required String id,
    required HostRecord? host,
  }) {
    final tab = TerminalTabSession(
      id: id,
      host: host,
      shellHistoryVaultId: activeVault?.id,
      onShellHistoryChanged: _notifyListenersIfAlive,
    );
    tab.shellHistoryRepository = _newShellHistoryRepository();
    tab.onShellCommandsCompleted = (commands) {
      tab.shellHistoryPersistenceQueue = tab.shellHistoryPersistenceQueue
          .then((_) => _persistTerminalShellHistory(tab, commands))
          .catchError((Object _) {});
    };
    tab.terminal.onOutput = (text) => sendTerminalInputFor(id, text);
    tab.terminal.onResize = (columns, rows, _, _) =>
        resizeTerminalFor(id, columns, rows);
    return tab;
  }

  EncryptedShellHistoryRepository? _newShellHistoryRepository() {
    final currentSession = session;
    final currentIdentity = identity;
    final baseUrl = api?.baseUrl ?? serverUrl;
    if (currentSession == null || currentIdentity == null || baseUrl == null) {
      return null;
    }
    try {
      return EncryptedShellHistoryRepository(
        database: database,
        crypto: crypto,
        identity: currentIdentity,
        baseUrl: baseUrl,
        accountId: currentSession.accountId,
      );
    } on Object {
      // A malformed or unavailable namespace must not interrupt SSH setup.
      return null;
    }
  }

  Future<void> _restoreTerminalShellHistory(TerminalTabSession tab) async {
    final repository = tab.shellHistoryRepository;
    final hostId = tab.host?.id;
    if (repository == null || hostId == null) return;
    final restorationGeneration = tab.shellHistoryRestorationGeneration;
    try {
      final persisted = await repository.load(hostId: hostId);
      if (!_isTerminalTabOpen(tab) ||
          !identical(tab.shellHistoryRepository, repository) ||
          tab.shellHistoryRestorationGeneration != restorationGeneration) {
        return;
      }
      final combined = <String, ShellIntegrationCompletedCommand>{};
      for (final entry in persisted) {
        final command = entry.commandEvent;
        combined[_shellHistoryEventKey(command)] = command;
      }
      for (final command in tab.shellIntegrationHistory) {
        combined[_shellHistoryEventKey(command)] = command;
      }
      final ordered = combined.values.toList()
        ..sort((left, right) {
          final time = left.completedAt.compareTo(right.completedAt);
          return time == 0 ? left.command.compareTo(right.command) : time;
        });
      tab.replaceShellIntegrationHistory(ordered);
    } on Object {
      // History is a convenience feature. A corrupt local row must not block
      // an SSH connection or leak command/ciphertext details to diagnostics.
    }
  }

  Future<void> _persistTerminalShellHistory(
    TerminalTabSession tab,
    List<ShellIntegrationCompletedCommand> commands,
  ) async {
    final repository = tab.shellHistoryRepository;
    final hostId = tab.host?.id;
    final currentSession = session;
    final currentIdentity = identity;
    final currentBaseUrl = api?.baseUrl ?? serverUrl;
    if (repository == null ||
        hostId == null ||
        currentSession == null ||
        currentIdentity == null ||
        currentBaseUrl == null ||
        currentSession.accountId != repository.accountId ||
        currentIdentity.deviceId != repository.deviceId ||
        repository.serverNamespace != secureStorageNamespace(currentBaseUrl)) {
      return;
    }
    for (final command in commands) {
      try {
        final entryId = await repository.record(
          hostId: hostId,
          command: command,
        );
        final vaultId = tab.shellHistoryVaultId;
        final currentIdentity = identity;
        final currentRepository = _repository;
        if ((_shellHistorySyncEnabled || _shellHistorySyncEnableInProgress) &&
            vaultId != null &&
            activeVault?.id == vaultId &&
            currentIdentity != null &&
            currentRepository?.vaultId == vaultId) {
          await _enqueueShellHistoryVaultRecord(
            repository: currentRepository!,
            vaultId: vaultId,
            record: ShellHistoryRecord(
              id: entryId,
              hostRecordId: hostId,
              command: command.command,
              exitStatus: command.exitStatus,
              startedAtMs: command.startedAt.toUtc().millisecondsSinceEpoch,
              completedAtMs: command.completedAt.toUtc().millisecondsSinceEpoch,
              sourceDeviceId: currentIdentity.deviceId,
            ),
          );
        }
      } on Object {
        // Never log shell command contents or ciphertext. The live tab history
        // remains usable even if local persistence is temporarily unavailable.
      }
    }
  }

  Future<void> _enqueueShellHistoryVaultRecord({
    required SyncRepository repository,
    required String vaultId,
    required ShellHistoryRecord record,
  }) {
    final previous = _shellHistorySyncWriteQueue;
    final next = previous.then((_) async {
      if ((!_shellHistorySyncEnabled && !_shellHistorySyncEnableInProgress) ||
          activeVault?.id != vaultId ||
          !identical(_repository, repository) ||
          repository.vaultId != vaultId ||
          repository.canWrite != true ||
          repository.deletionPending ||
          activeVault?.canWrite != true ||
          activeVault?.status != 'active' ||
          !hosts.any((host) => host.id == record.hostRecordId)) {
        return;
      }
      final cached = await database.cachedEnvelope(
        vaultId,
        record.id,
        instanceId: repository.instanceId,
        serverSpaceId: repository.serverSpaceId,
      );
      final pending = await database.allPendingOperations(
        vaultId,
        instanceId: repository.instanceId,
        serverSpaceId: repository.serverSpaceId,
      );
      if (cached != null || pending.any((item) => item.recordId == record.id)) {
        return;
      }
      if ((!_shellHistorySyncEnabled && !_shellHistorySyncEnableInProgress) ||
          activeVault?.id != vaultId ||
          !identical(_repository, repository)) {
        return;
      }
      await repository.saveRecord(
        recordId: record.id,
        plaintext: record.toJson(),
        operation: 'create',
      );
      _automaticSync.scheduleEdit();
    });
    _shellHistorySyncWriteQueue = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next;
  }

  String _shellHistoryEventKey(ShellIntegrationCompletedCommand command) =>
      canonicalJson({
        'command': command.command,
        'exit_status': command.exitStatus,
        'started_at_ms': command.startedAt.toUtc().millisecondsSinceEpoch,
        'completed_at_ms': command.completedAt.toUtc().millisecondsSinceEpoch,
      });

  TerminalTabSession? _compatibilityTerminalTab({bool create = false}) {
    final active = activeTerminalTab;
    if (active != null) return active;
    if (!create) return null;
    final id = 'legacy-${_uuid.v4()}';
    final tab = _createTerminalTab(id: id, host: selectedHost);
    tab.state = 'disconnected';
    _terminalTabs[id] = tab;
    _terminalTabOrder.add(id);
    _activeTerminalTabId = id;
    tab.shellHistoryRestoration = _restoreTerminalShellHistory(tab);
    unawaited(tab.shellHistoryRestoration);
    return tab;
  }

  List<TerminalTabSession> get visibleTerminalTabs =>
      List.unmodifiable(terminalTabs.where((tab) => !tab.detached));

  void reorderTerminalTab(String id, String? beforeId) {
    if (id == beforeId || !_terminalTabOrder.contains(id)) return;
    if (beforeId != null && !_terminalTabOrder.contains(beforeId)) return;
    _terminalTabOrder.remove(id);
    final index = beforeId == null
        ? _terminalTabOrder.length
        : _terminalTabOrder.indexOf(beforeId);
    _terminalTabOrder.insert(index, id);
    _notifyListenersIfAlive();
  }

  void markTerminalDetached(String id, bool detached) {
    final tab = _terminalTabs[id];
    if (tab == null || tab.closed) return;
    tab.detached = detached;
    if (detached && _activeTerminalTabId == id) {
      _activeTerminalTabId = visibleTerminalTabs.lastOrNull?.id;
    } else if (!detached) {
      _activeTerminalTabId = id;
    }
    _notifyListenersIfAlive();
  }

  void activateTerminalTab(String id) {
    if (!_terminalTabs.containsKey(id) || _terminalTabs[id]!.closed) return;
    if (_activeTerminalTabId == id) return;
    _activeTerminalTabId = id;
    notifyListeners();
  }

  Future<void> closeTerminalTab(String id) async {
    if (_terminalTabs[id]?.desktop != null) {
      // Main and per-monitor desktop renderers end before the session.
      await DesktopTabWindows.closeAll(
        windows: ApplicationWindows.instance,
        owner: this,
        tabId: id,
      );
    } else {
      await ApplicationWindows.instance.closeSession(this, id);
    }
    await stopTerminalShareFor(id);
    final tab = _terminalTabs.remove(id);
    if (tab == null) return;
    _terminalShareStatuses.remove(id);
    final previousIndex = _terminalTabOrder.indexOf(id);
    _terminalTabOrder.remove(id);
    for (final workspaceId in _workspacePaneTerminalTabIds.keys.toList()) {
      final bindings = _workspacePaneTerminalTabIds[workspaceId]!;
      bindings.removeWhere((_, tabId) => tabId == id);
      if (bindings.isEmpty) _workspacePaneTerminalTabIds.remove(workspaceId);
    }
    tab.closed = true;
    tab.state = 'closed';
    tab.cancelPendingSshAuthentication();
    if (_activeTerminalTabId == id) {
      final visibleIds = visibleTerminalTabs.map((tab) => tab.id).toSet();
      _activeTerminalTabId =
          _terminalTabOrder
              .take(previousIndex)
              .where(visibleIds.contains)
              .lastOrNull ??
          _terminalTabOrder.where(visibleIds.contains).firstOrNull;
    }
    notifyListeners();
    await _closeTerminalTabResources(tab);
  }

  Future<void> disconnectAllTerminalTabs() async {
    await ApplicationWindows.instance.closeOwner(this);
    await _stopAllTerminalCollaboration();
    final tabs = terminalTabs;
    _terminalTabs.clear();
    _terminalTabOrder.clear();
    _activeTerminalTabId = null;
    _workspacePaneTerminalTabIds.clear();
    _legacySftpEntries = [];
    _legacySftpPath = '/';
    for (final tab in tabs) {
      tab.closed = true;
      tab.state = 'closed';
      tab.cancelPendingSshAuthentication();
    }
    _notifyListenersIfAlive();
    await Future.wait<void>(tabs.map(_closeTerminalTabResources));
  }

  Future<void> _closeTerminalTabResources(TerminalTabSession tab) async {
    tab.log?.markClosed(SessionLogEndReason.user);
    final desktop = tab.desktop;
    tab.desktop = null;
    await desktop?.close();
    desktop?.dispose();
    final console = tab.console;
    tab.console = null;
    await console?.close();
    tab.telnetCancellation?.cancel();
    tab.telnetCancellation = null;
    final telnet = tab.telnet;
    tab.telnet = null;
    await telnet?.close();
    _clearShellIntegrationFor(tab, clearHistory: true);
    await tab.shellHistoryPersistenceQueue.timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
    tab.shellHistoryRepository?.close();
    tab.shellHistoryRepository = null;
    tab.onShellCommandsCompleted = null;
    final connectCancellation = tab.connectionCancellation;
    tab.connectionCancellation = null;
    _tmuxOperationCancellations.remove(tab.id)?.cancel();
    final tmuxHandle = _tmuxAttachHandles.remove(tab.id);
    final subscription = tab.outputSubscription;
    final connection = tab.connection;
    tab.outputSubscription = null;
    tab.connection = null;
    // SFTP channels are children of the SSHClient, so closing the client also
    // closes an active or still-opening SFTP channel. The opening future checks
    // the tab identity after it completes and can never reattach itself.
    tab.sftp = null;
    tab.sftpOpening = null;
    try {
      await connectCancellation?.cancel();
      if (subscription != null) await subscription.cancel();
    } finally {
      try {
        tmuxHandle?.close();
      } finally {
        try {
          if (connection != null) await connection.close();
        } finally {
          await tab.terminal.closeMirror();
        }
      }
    }
  }

  void Function(String text)? _legacyTerminalOutputListener;
  void attachTerminalOutput(void Function(String text)? listener) {
    final tab = activeTerminalTab;
    if (tab == null) {
      _legacyTerminalOutputListener = listener;
    } else {
      tab.outputListener = listener;
    }
  }

  void sendTerminalInput(String input) =>
      sendTerminalInputFor(_activeTerminalTabId, input);
  void sendTerminalInputFor(String? id, String input) {
    if (_controllerDisposed || workspaceLocked) return;
    final tmuxHandle = _tmuxAttachHandles[id];
    if (tmuxHandle != null) {
      final bytes = Uint8List.fromList(utf8.encode(input));
      unawaited(
        tmuxHandle
            .input(bytes)
            .whenComplete(() => bytes.fillRange(0, bytes.length, 0))
            .catchError((Object _) {}),
      );
      return;
    }
    _terminalTabs[id]?.console?.input(input);
    if (_terminalTabs[id]?.telnet?.input(input) ==
        TelnetInputResult.tooLarge) {
      // Oversized paste: rejected whole, never sent truncated.
      _setError(currentL10n.telnetInputTooLarge);
    }
    _terminalTabs[id]?.connection?.input(input);
  }

  void resizeTerminal(int columns, int rows) =>
      resizeTerminalFor(_activeTerminalTabId, columns, rows);
  void resizeTerminalFor(String? id, int columns, int rows) {
    if (_controllerDisposed || workspaceLocked) return;
    final tmuxHandle = _tmuxAttachHandles[id];
    if (tmuxHandle != null) {
      tmuxHandle.resize(columns, rows);
    } else {
      _terminalTabs[id]?.console?.resize(columns, rows);
      _terminalTabs[id]?.telnet?.resize(columns, rows);
      _terminalTabs[id]?.connection?.resize(columns, rows);
    }
    if (id != null) {
      final runtime = _terminalShareHosts[id];
      if (runtime != null) {
        _enqueueTerminalShareResize(id, runtime, columns, rows);
      }
    }
  }

  Future<void> disconnectTerminal() async {
    final id = _activeTerminalTabId;
    if (id != null) await closeTerminalTab(id);
  }

  TerminalTabSession _sftpTab([String? id]) {
    final tab = id == null ? activeTerminalTab : _terminalTabs[id];
    if (tab == null || tab.closed || tab.connection == null) {
      throw StateError(currentL10n.connectToAnSshHostFirst);
    }
    return tab;
  }

  Future<SftpClient> _sftpClientFor(TerminalTabSession tab) async {
    if (!_isTerminalTabOpen(tab) || tab.connection == null) {
      throw StateError(currentL10n.sshSessionClosed);
    }
    final existing = tab.sftp;
    if (existing != null) return existing;
    final pending = tab.sftpOpening ??= tab.connection!.client.sftp();
    late final SftpClient sftp;
    try {
      sftp = await pending;
    } catch (_) {
      if (identical(tab.sftpOpening, pending)) tab.sftpOpening = null;
      rethrow;
    }
    if (!_isTerminalTabOpen(tab) || tab.connection == null) {
      throw StateError(currentL10n.sshSessionClosed);
    }
    tab.sftp ??= sftp;
    tab.sftpOpening = null;
    return tab.sftp!;
  }

  Future<List<SftpName>> _listSftpForTab(
    TerminalTabSession tab,
    String path,
  ) async {
    final nextPath = path.isEmpty ? '/' : path;
    final entries = visibleSftpEntries(
      await (await _sftpClientFor(tab)).listdir(nextPath),
    );
    if (!_isTerminalTabOpen(tab)) {
      throw StateError(currentL10n.sshSessionClosed);
    }
    tab.sftpEntries = entries;
    tab.sftpPath = nextPath;
    notifyListeners();
    return entries;
  }

  Future<List<SftpName>> listSftp(String path, {String? sessionId}) =>
      _listSftpForTab(_sftpTab(sessionId), path);

  Future<void> makeSftpDirectory(String name, {String? sessionId}) async {
    final safeName = name.trim();
    if (!isSafeSftpBasename(safeName)) {
      throw FormatException(currentL10n.invalidFolderNameFormat);
    }
    final tab = _sftpTab(sessionId);
    final directory = tab.sftpPath;
    await (await _sftpClientFor(tab)).mkdir(sftpChildPath(directory, safeName));
    await _listSftpForTab(tab, directory);
  }

  Future<void> uploadSftpFile({String? sessionId}) async {
    final tab = _sftpTab(sessionId);
    final directory = tab.sftpPath;
    // Open the browser's native file chooser directly from the Upload tap.
    // Waiting for the SSH/SFTP futures first can consume transient browser
    // activation, causing the hidden file input to return without a selection.
    final file = await pickSftpFile();
    if (file == null) return;
    try {
      if (!_isTerminalTabOpen(tab)) {
        throw StateError(currentL10n.sshSessionClosed);
      }
      if (!isSafeSftpBasename(file.name)) {
        throw FormatException(currentL10n.theLocalFileNameIsntA);
      }
      final sftp = await _sftpClientFor(tab);
      final handshake = await sftp.handshake;
      if (!_isTerminalTabOpen(tab)) {
        throw StateError(currentL10n.sshSessionClosed);
      }
      if (!supportsSftpExclusiveCreate(handshake.version)) {
        throw StateError(currentL10n.theSftpServerVersionDoesntSupport);
      }
      final target = sftpChildPath(directory, file.name);
      await writeSftpFileWithoutOverwrite(
        remotePath: target,
        bytes: file.bytes,
        createExclusive: () async {
          try {
            // The pinned dartssh2 rename() uses posix-rename when advertised,
            // whose POSIX semantics replace an existing destination. Open the
            // final path with SFTP v3 EXCL instead: the server atomically rejects
            // a collision and we never truncate prior remote bytes.
            final remote = await sftp.open(
              target,
              mode: sftpExclusiveCreateMode,
            );
            return DartSftpUploadHandle(remote);
          } on SftpStatusError catch (error) {
            throw StateError(
              currentL10n.couldntSafelyCreateRemoteFileName(file.name, error),
            );
          }
        },
        removePartial: () => sftp.remove(target),
      );
      _setNotice(currentL10n.uploadedName(file.name));
      await _listSftpForTab(tab, directory);
    } finally {
      file.bytes.fillRange(0, file.bytes.length, 0);
    }
  }

  Future<SftpTextDocument> openSftpTextFile(
    String name, {
    String? sessionId,
  }) async {
    if (!isSafeSftpBasename(name)) {
      throw FormatException(currentL10n.invalidRemoteFileNameFormat);
    }
    final tab = _sftpTab(sessionId);
    final service = await _sftpTextEditorService(tab);
    final document = await service.open(sftpChildPath(tab.sftpPath, name));
    if (!_isTerminalTabOpen(tab)) {
      document.dispose();
      throw StateError(currentL10n.sshSessionClosed);
    }
    return document;
  }

  Future<SftpTextSaveResult> saveSftpTextFile(
    SftpTextDocument document,
    String text, {
    Uint8List? expectedRemoteBytes,
    String? saveAsName,
    String? sessionId,
  }) async {
    final documentSessionId = document.sessionId;
    if (sessionId != null &&
        documentSessionId != null &&
        sessionId != documentSessionId) {
      throw StateError(currentL10n.theSftpDocumentBelongsToA);
    }
    final tab = _sftpTab(documentSessionId ?? sessionId);
    final service = await _sftpTextEditorService(tab);
    if (!_isTerminalTabOpen(tab)) {
      throw StateError(currentL10n.sshSessionClosed);
    }
    final result = saveAsName == null
        ? await service.save(
            document,
            text,
            expectedRemoteBytes: expectedRemoteBytes,
          )
        : await service.saveAs(
            sftpChildPath(tab.sftpPath, saveAsName),
            text,
            permissionBits: document.permissionBits,
          );
    if (!_isTerminalTabOpen(tab)) {
      if (result is SftpTextSaveSuccess) result.document.dispose();
      if (result is SftpTextRemoteChanged) result.latestDocument.dispose();
      throw StateError(currentL10n.sshSessionClosed);
    }
    if (result is SftpTextSaveSuccess) {
      _setNotice(
        result.permissionRestoreFailed
            ? currentL10n.savedNameButCouldntConfirmThe(result.document.name)
            : currentL10n.savedName(result.document.name),
      );
      try {
        await _listSftpForTab(tab, tab.sftpPath);
      } catch (error) {
        // The atomic remote replacement has already succeeded. Do not turn a
        // subsequent directory refresh error into a false save failure.
        _setError(currentL10n.theFileWasSavedButThe(friendlyError(error)));
      }
    }
    return result;
  }

  Future<SftpTextEditorService> _sftpTextEditorService(
    TerminalTabSession tab,
  ) async {
    final sftp = await _sftpClientFor(tab);
    final handshake = await sftp.handshake;
    if (!_isTerminalTabOpen(tab)) {
      throw StateError(currentL10n.sshSessionClosed);
    }
    if (!supportsSftpExclusiveCreate(handshake.version)) {
      throw StateError(currentL10n.theSftpServerVersionIsBelow);
    }
    final supportsAtomicReplace =
        handshake.extensions['posix-rename@openssh.com'] == '1';
    return SftpTextEditorService(
      filesystem: DartSftpTextFileSystem(
        sftp,
        supportsAtomicReplaceExtension: supportsAtomicReplace,
      ),
      sessionId: tab.id,
    );
  }

  Future<void> downloadSftpFile(
    String name, {
    String? sessionId,
    String? remotePath,
    int? maximumBytes,
  }) async {
    if (remotePath != null &&
        (remotePath.isEmpty ||
            remotePath.length > 4096 ||
            containsSftpControlCharacters(remotePath))) {
      throw FormatException(currentL10n.invalidRemoteFilePathFormat);
    }
    if (maximumBytes != null &&
        (maximumBytes < 1 || maximumBytes > 16 * 1024 * 1024)) {
      throw FormatException(currentL10n.invalidCompatibleDownloadSizeLimit);
    }
    if (!isSafeSftpBasename(name)) {
      throw FormatException(currentL10n.invalidRemoteFileNameFormat);
    }
    final tab = _sftpTab(sessionId);
    final remote = await (await _sftpClientFor(tab))
        .open(remotePath ?? sftpChildPath(tab.sftpPath, name));
    late Uint8List bytes;
    try {
      bytes = await remote.readBytes(
        length: maximumBytes == null ? null : maximumBytes + 1,
      );
    } finally {
      await remote.close();
    }
    if (maximumBytes != null && bytes.length > maximumBytes) {
      bytes.fillRange(0, bytes.length, 0);
      throw FormatException(
        currentL10n.compatibleSftpDownloadsOnlySupportFiles,
      );
    }
    if (!_isTerminalTabOpen(tab)) {
      bytes.fillRange(0, bytes.length, 0);
      throw StateError(currentL10n.sshSessionClosed);
    }
    await saveAttachmentFile(
      fileName: name,
      mediaType: 'application/octet-stream',
      bytes: bytes,
    );
  }

  Future<void> deleteSftpEntry(SftpName item, {String? sessionId}) async {
    if (!isSafeSftpBasename(item.filename)) {
      throw FormatException(currentL10n.invalidRemoteFileNameFormat);
    }
    final tab = _sftpTab(sessionId);
    final path = sftpChildPath(tab.sftpPath, item.filename);
    final sftp = await _sftpClientFor(tab);
    if (item.attr.isDirectory == true) {
      await sftp.rmdir(path);
    } else {
      await sftp.remove(path);
    }
    await _listSftpForTab(tab, tab.sftpPath);
  }

  PreparedSnippetExecution prepareSnippetExecution(
    SnippetRecord snippet, {
    String? terminalTabId,
  }) {
    final tab = terminalTabId == null
        ? activeTerminalTab
        : _terminalTabs[terminalTabId];
    final connection = tab?.connection;
    final host = tab?.host;
    if (tab == null ||
        tab.closed ||
        tab.state != 'connected' ||
        connection == null ||
        host == null) {
      throw StateError(currentL10n.connectToAnSshHostFirst);
    }
    validateSnippetDefinition(snippet);
    final credentialSnapshots = <String, CredentialRecord>{};
    final referencedParameterNames = snippet.arguments
        .map((argument) => argument.parameter)
        .whereType<String>()
        .toSet();
    for (final parameter in snippet.parameters) {
      if (parameter.type != SnippetParameterType.credentialSecret ||
          !referencedParameterNames.contains(parameter.name)) {
        continue;
      }
      final credential = credentials
          .where((item) => item.id == parameter.credentialId)
          .firstOrNull;
      if (credential == null ||
          credential.kind != AuthKind.password ||
          (credential.secret ?? '').isEmpty) {
        throw FormatException(
          currentL10n.credentialReferenceNameIsMissingOr(parameter.name),
        );
      }
      credentialSnapshots[credential.id] = credential;
    }
    if (snippet.executionMode == SnippetExecutionMode.script &&
        snippet.body.trim().isEmpty) {
      throw FormatException(currentL10n.snippetScriptIsEmpty);
    }
    return PreparedSnippetExecution(
      snippetId: snippet.id,
      terminalTabId: tab.id,
      connectionIdentity: connection,
      hostId: host.id,
      hostName: host.name,
      endpoint: host.endpoint,
      shell: snippet.shell,
      hostSnapshot: canonicalJson(host.toJson()),
      definitionSnapshot: canonicalJson(snippet.toJson()),
      credentialSnapshots: credentialSnapshots,
    );
  }

  SnippetInvocationPreview previewSnippetExecution(
    SnippetRecord snippet, {
    Map<String, String> values = const {},
  }) {
    final availableCredentialParameters = <String>{};
    for (final parameter in snippet.parameters) {
      if (parameter.type != SnippetParameterType.credentialSecret) continue;
      final credential = credentials
          .where((item) => item.id == parameter.credentialId)
          .firstOrNull;
      if (credential != null &&
          credential.kind == AuthKind.password &&
          (credential.secret ?? '').isNotEmpty) {
        availableCredentialParameters.add(parameter.name);
      }
    }
    return previewSnippetInvocation(
      snippet,
      values: values,
      credentialParametersAvailable: availableCredentialParameters,
    );
  }

  Future<List<SnippetBatchTargetOutcome>> executeSnippetBatch({
    required SnippetRecord snippet,
    required List<PreparedSnippetExecution> targets,
    required SnippetInvocationPreview confirmedPreview,
    Map<String, String> values = const {},
    required SshExecCancellation cancellation,
    void Function(int index, PreparedSnippetExecution target)? onTargetStarted,
  }) async {
    if (snippet.executionMode != SnippetExecutionMode.bashCommand) {
      throw StateError(currentL10n.batchExecutionIsOnlySupportedFor);
    }
    final reviewedTargets = List<PreparedSnippetExecution>.unmodifiable(
      targets,
    );
    final reviewedValues = Map<String, String>.unmodifiable(values);
    if (reviewedTargets.length < 2 ||
        reviewedTargets.length > maxTerminalTabs) {
      throw StateError(
        currentL10n.chooseBetweenTwoAndMaxterminaltabsConnected(
          maxTerminalTabs,
        ),
      );
    }
    final tabIds = reviewedTargets
        .map((target) => target.terminalTabId)
        .toSet();
    final hostIds = reviewedTargets.map((target) => target.hostId).toSet();
    if (tabIds.length != reviewedTargets.length ||
        hostIds.length != reviewedTargets.length) {
      throw StateError(currentL10n.batchTargetsMustBeDistinctConnected);
    }
    try {
      for (final target in reviewedTargets) {
        if (cancellation.isCancelled) {
          throw const _SnippetBatchPreflightCancelled();
        }
        await _validateSnippetBatchTarget(
          snippet,
          target,
          confirmedPreview: confirmedPreview,
          values: reviewedValues,
          cancellation: cancellation,
        );
      }
    } on _SnippetBatchPreflightCancelled {
      for (final target in reviewedTargets) {
        target.discard();
      }
      return List<SnippetBatchTargetOutcome>.unmodifiable(
        reviewedTargets.map(
          (target) => _skippedSnippetBatchTarget(
            target,
            currentL10n.notStartedBecauseBatchCancellationWas,
          ),
        ),
      );
    } catch (_) {
      for (final target in reviewedTargets) {
        target.discard();
      }
      rethrow;
    }

    final outcomes = <SnippetBatchTargetOutcome>[];
    for (var index = 0; index < reviewedTargets.length; index++) {
      final target = reviewedTargets[index];
      if (cancellation.isCancelled) {
        for (final skipped in reviewedTargets.skip(index)) {
          skipped.discard();
          outcomes.add(
            _skippedSnippetBatchTarget(
              skipped,
              currentL10n.notStartedBecauseBatchCancellationWas2,
            ),
          );
        }
        break;
      }
      onTargetStarted?.call(index, target);
      var remoteDispatchStarted = false;
      try {
        await _validateSnippetBatchConnectionCredentials(target);
        final result = await executeSnippet(
          snippet,
          prepared: target,
          confirmedPreview: confirmedPreview,
          values: reviewedValues,
          cancellation: cancellation,
          onRemoteExecDispatch: () => remoteDispatchStarted = true,
        );
        if (result == null) {
          throw StateError(currentL10n.theHostDidNotReturnA);
        }
        outcomes.add(
          SnippetBatchTargetOutcome(
            hostId: target.hostId,
            hostName: target.hostName,
            endpoint: target.endpoint,
            result: result,
          ),
        );
        final completedSuccessfully =
            result.exitCode == 0 &&
            result.exitSignal == null &&
            !result.cancelled &&
            !result.timedOut &&
            !result.outputTruncated &&
            !result.bashUnavailable &&
            !result.execOpenPending;
        if (!completedSuccessfully) {
          for (final skipped in reviewedTargets.skip(index + 1)) {
            skipped.discard();
            outcomes.add(
              _skippedSnippetBatchTarget(
                skipped,
                currentL10n.notStartedBecauseThePreviousHost,
              ),
            );
          }
          break;
        }
      } catch (error) {
        target.discard();
        outcomes.add(
          SnippetBatchTargetOutcome(
            hostId: target.hostId,
            hostName: target.hostName,
            endpoint: target.endpoint,
            error: remoteDispatchStarted
                ? currentL10n.theSshExecRequestFailedAfter
                : friendlyError(error),
            completionUnknown: remoteDispatchStarted,
          ),
        );
        for (final skipped in reviewedTargets.skip(index + 1)) {
          skipped.discard();
          outcomes.add(
            _skippedSnippetBatchTarget(
              skipped,
              currentL10n.notStartedBecauseThePreviousHost2,
            ),
          );
        }
        break;
      }
    }
    return List.unmodifiable(outcomes);
  }

  SnippetBatchTargetOutcome _skippedSnippetBatchTarget(
    PreparedSnippetExecution prepared,
    String reason,
  ) => SnippetBatchTargetOutcome(
    hostId: prepared.hostId,
    hostName: prepared.hostName,
    endpoint: prepared.endpoint,
    error: reason,
    skipped: true,
  );

  Future<void> _validateSnippetBatchTarget(
    SnippetRecord snippet,
    PreparedSnippetExecution prepared, {
    required SnippetInvocationPreview confirmedPreview,
    required Map<String, String> values,
    required SshExecCancellation cancellation,
  }) async {
    void checkCancellation() {
      if (cancellation.isCancelled) {
        throw const _SnippetBatchPreflightCancelled();
      }
    }

    checkCancellation();
    final tab = _terminalTabs[prepared.terminalTabId];
    final connection = tab?.connection;
    final host = tab?.host;
    final currentSnippet = snippets
        .where((item) => item.id == prepared.snippetId)
        .firstOrNull;
    if (tab == null ||
        tab.closed ||
        tab.state != 'connected' ||
        connection == null ||
        !identical(connection, prepared.connectionIdentity) ||
        host == null ||
        host.id != prepared.hostId ||
        host.name != prepared.hostName ||
        host.endpoint != prepared.endpoint ||
        canonicalJson(host.toJson()) != prepared.hostSnapshot ||
        hosts.every((item) => item.id != prepared.hostId) ||
        canonicalJson(
              hosts.firstWhere((item) => item.id == prepared.hostId).toJson(),
            ) !=
            prepared.hostSnapshot ||
        snippet.id != prepared.snippetId ||
        currentSnippet == null ||
        canonicalJson(currentSnippet.toJson()) != prepared.definitionSnapshot ||
        canonicalJson(snippet.toJson()) != prepared.definitionSnapshot) {
      throw StateError(currentL10n.aSelectedHostConnectionOrSnippet);
    }
    if (connection.hasUnresolvedExecOpen) {
      throw StateError(
        '${prepared.hostName} has an unresolved SSH exec request. Reconnect before reviewing this batch.',
      );
    }

    await _validateSnippetBatchConnectionCredentials(prepared);
    checkCancellation();
    final requiredEndpoints = <String>{
      endpointKey(host: canonicalizeKnownHost(host.address), port: host.port),
      for (final hop in _resolveJumpHostConnection(host))
        endpointKey(
          host: canonicalizeKnownHost(hop.host.address),
          port: hop.host.port,
        ),
    };
    final proofs = tab.verifiedHostKeys.values.toList(growable: false);
    if (requiredEndpoints.any(
      (endpoint) => proofs.every((proof) => proof.endpoint != endpoint),
    )) {
      throw StateError(
        currentL10n.sshHostKeyVerificationEvidenceIs(prepared.hostName),
      );
    }
    for (final proof in proofs) {
      final trust = await knownHostTrustStatus(
        host: proof.host,
        port: proof.port,
        algorithm: proof.algorithm,
        fingerprint: proof.fingerprint,
      );
      checkCancellation();
      if (trust != KnownHostTrustStatus.trusted) {
        throw StateError(
          currentL10n.sshHostKeyTrustChangedFor(prepared.hostName),
        );
      }
    }

    final referencedParameters = snippet.arguments
        .map((argument) => argument.parameter)
        .whereType<String>()
        .toSet();
    final availableCredentialParameters = <String>{};
    for (final parameter in snippet.parameters) {
      if (parameter.type != SnippetParameterType.credentialSecret ||
          !referencedParameters.contains(parameter.name)) {
        continue;
      }
      final credentialId = parameter.credentialId!;
      final reviewedCredential = prepared.credentialSnapshot(credentialId);
      final current = credentials
          .where((item) => item.id == credentialId)
          .firstOrNull;
      if (reviewedCredential == null ||
          current == null ||
          canonicalJson(current.toJson()) !=
              canonicalJson(reviewedCredential.toJson()) ||
          reviewedCredential.kind != AuthKind.password ||
          (reviewedCredential.secret ?? '').isEmpty) {
        throw StateError(currentL10n.aReferencedSnippetCredentialChangedAfter);
      }
      availableCredentialParameters.add(parameter.name);
    }
    final preview = previewSnippetInvocation(
      snippet,
      values: values,
      credentialParametersAvailable: availableCredentialParameters,
    );
    if (!preview.canExecute || !preview.matchesExactly(confirmedPreview)) {
      throw StateError(
        preview.blockedReason ??
            currentL10n.snippetArgumentsChangedAfterReviewReview,
      );
    }
  }

  Future<void> _validateSnippetBatchConnectionCredentials(
    PreparedSnippetExecution prepared,
  ) async {
    final tab = _terminalTabs[prepared.terminalTabId];
    final host = tab?.host;
    if (tab == null ||
        tab.closed ||
        tab.state != 'connected' ||
        tab.connection == null ||
        !identical(tab.connection, prepared.connectionIdentity) ||
        host == null ||
        host.id != prepared.hostId ||
        canonicalJson(host.toJson()) != prepared.hostSnapshot ||
        hosts.every((item) => item.id != prepared.hostId) ||
        canonicalJson(
              hosts.firstWhere((item) => item.id == prepared.hostId).toJson(),
            ) !=
            prepared.hostSnapshot) {
      throw StateError(
        currentL10n.theReviewedSshSessionForHostname(prepared.hostName),
      );
    }
    final currentCredential = resolveHostCredential(
      host: host,
      groupId: host.groupId,
      hostCredentialId: host.credentialId,
    ).credential;
    if (currentCredential == null) {
      throw StateError(
        currentL10n.sshCredentialForHostnameChangedBefore(prepared.hostName),
      );
    }
    final currentCredentialSnapshot = canonicalJson(currentCredential.toJson());
    final targetFingerprint = await _fingerprintConnectionCredential(
      currentCredential,
    );
    final jumpRoute = _resolveJumpHostConnection(host);
    final jumpRouteHostSnapshots = jumpRoute
        .map((hop) => canonicalJson(hop.host.toJson()))
        .toList(growable: false);
    final jumpRouteCredentialSnapshots = jumpRoute
        .map((hop) => canonicalJson(hop.credential.toJson()))
        .toList(growable: false);
    final jumpRouteFingerprints = <String, String>{};
    for (final hop in jumpRoute) {
      jumpRouteFingerprints[hop.host.id] =
          await _fingerprintConnectionCredential(hop.credential);
    }

    // Hashing is asynchronous. Re-resolve both effective credentials and the
    // route after every await so a credential replacement during hashing
    // cannot validate an obsolete immutable CredentialRecord instance.
    final latestTab = _terminalTabs[prepared.terminalTabId];
    final latestHost = latestTab?.host;
    if (latestTab == null ||
        latestTab.closed ||
        latestTab.state != 'connected' ||
        !identical(latestTab.connection, prepared.connectionIdentity) ||
        latestHost == null ||
        canonicalJson(latestHost.toJson()) != prepared.hostSnapshot ||
        hosts.every((item) => item.id != prepared.hostId) ||
        canonicalJson(
              hosts.firstWhere((item) => item.id == prepared.hostId).toJson(),
            ) !=
            prepared.hostSnapshot) {
      throw StateError(
        currentL10n.theReviewedSshSessionForHostname(prepared.hostName),
      );
    }
    final latestCredential = resolveHostCredential(
      host: latestHost,
      groupId: latestHost.groupId,
      hostCredentialId: latestHost.credentialId,
    ).credential;
    if (latestCredential == null ||
        canonicalJson(latestCredential.toJson()) != currentCredentialSnapshot ||
        latestTab.connectionCredentialFingerprints[latestHost.id] !=
            targetFingerprint) {
      throw StateError(
        currentL10n.sshCredentialForHostnameChangedBefore(prepared.hostName),
      );
    }
    final latestJumpResolution = _resolveJumpHostConnection(latestHost);
    if (latestJumpResolution.length != jumpRoute.length ||
        List<String>.generate(
              latestJumpResolution.length,
              (index) =>
                  canonicalJson(latestJumpResolution[index].host.toJson()),
            ).join('\u0000') !=
            jumpRouteHostSnapshots.join('\u0000')) {
      throw StateError(
        currentL10n.jumpHostRoutingForHostnameChanged(prepared.hostName),
      );
    }
    for (var index = 0; index < jumpRoute.length; index++) {
      final latestHop = latestJumpResolution[index];
      final latestFingerprint =
          latestTab.connectionCredentialFingerprints[latestHop.host.id];
      if (canonicalJson(latestHop.credential.toJson()) !=
              jumpRouteCredentialSnapshots[index] ||
          latestFingerprint != jumpRouteFingerprints[latestHop.host.id]) {
        throw StateError(
          currentL10n.jumpHostCredentialForHostnameChanged(prepared.hostName),
        );
      }
    }
  }

  Future<SshExecResult?> executeSnippet(
    SnippetRecord snippet, {
    required PreparedSnippetExecution prepared,
    required SnippetInvocationPreview confirmedPreview,
    Map<String, String> values = const {},
    SshExecCancellation? cancellation,
    void Function()? onRemoteExecDispatch,
  }) async {
    final tab = _terminalTabs[prepared.terminalTabId];
    final connection = tab?.connection;
    final host = tab?.host;
    if (tab == null ||
        tab.closed ||
        tab.state != 'connected' ||
        connection == null ||
        !identical(connection, prepared.connectionIdentity) ||
        host == null ||
        host.id != prepared.hostId ||
        host.name != prepared.hostName ||
        host.endpoint != prepared.endpoint ||
        canonicalJson(host.toJson()) != prepared.hostSnapshot ||
        hosts.every((item) => item.id != prepared.hostId) ||
        canonicalJson(
              hosts.firstWhere((item) => item.id == prepared.hostId).toJson(),
            ) !=
            prepared.hostSnapshot ||
        snippet.id != prepared.snippetId) {
      throw StateError(currentL10n.sshConnectionOrHostChangedAfter);
    }
    final currentSnippet = snippets
        .where((item) => item.id == prepared.snippetId)
        .firstOrNull;
    if (currentSnippet == null ||
        canonicalJson(currentSnippet.toJson()) != prepared.definitionSnapshot ||
        canonicalJson(snippet.toJson()) != prepared.definitionSnapshot) {
      throw StateError(currentL10n.snippetDefinitionChangedAfterPreviewReview);
    }
    final credentialSecrets = <String, String>{};
    Uint8List? credentialInput;
    late final String command;
    late final String bashUnavailableMarker;
    late final SnippetInvocationPreview preview;
    try {
      final referencedParameterNames = snippet.arguments
          .map((argument) => argument.parameter)
          .whereType<String>()
          .toSet();
      for (final parameter in snippet.parameters) {
        if (parameter.type != SnippetParameterType.credentialSecret ||
            !referencedParameterNames.contains(parameter.name)) {
          continue;
        }
        final credentialId = parameter.credentialId!;
        final reviewedCredential = prepared.credentialSnapshot(credentialId);
        final currentCredential = credentials
            .where((item) => item.id == credentialId)
            .firstOrNull;
        if (reviewedCredential == null ||
            currentCredential == null ||
            canonicalJson(currentCredential.toJson()) !=
                canonicalJson(reviewedCredential.toJson()) ||
            reviewedCredential.kind != AuthKind.password ||
            (reviewedCredential.secret ?? '').isEmpty) {
          throw StateError(
            currentL10n.referencedCredentialChangedAfterPreviewReview,
          );
        }
        credentialSecrets[parameter.name] = reviewedCredential.secret!;
      }
      preview = previewSnippetInvocation(
        snippet,
        values: values,
        credentialParametersAvailable: credentialSecrets.keys.toSet(),
      );
      if (!preview.matchesExactly(confirmedPreview)) {
        throw StateError(currentL10n.snippetArgumentsChangedAfterPreviewReview);
      }
      if (snippet.executionMode == SnippetExecutionMode.bashCommand &&
          connection.hasUnresolvedExecOpen) {
        throw StateError(currentL10n.aPreviousSshExecRequestIs);
      }
      if (!preview.canExecute) {
        throw StateError(
          preview.blockedReason ??
              currentL10n.commandExecutionIsUnavailableNoCommand,
        );
      }
      bashUnavailableMarker =
          '__ATERMIUS_BASH_UNAVAILABLE_${_uuid.v4().replaceAll('-', '')}__';
      command = snippet.executionMode == SnippetExecutionMode.bashCommand
          ? buildBashExecRequest(
              snippet,
              values: values,
              credentialSecrets: credentialSecrets,
              bashUnavailableMarker: bashUnavailableMarker,
            )
          : buildSnippetCommand(snippet, values: values);
      final input = buildSnippetCredentialInput(
        snippet,
        credentialSecrets: credentialSecrets,
      );
      if (input.isNotEmpty) credentialInput = input;
      if (snippet.executionMode == SnippetExecutionMode.bashCommand &&
          _snippetExecutionInProgress) {
        throw StateError(currentL10n.aCommandSnippetIsAlreadyRunning);
      }
      if (snippet.executionMode == SnippetExecutionMode.bashCommand &&
          cancellation == null) {
        throw StateError(currentL10n.bashExecutionRequiresACancellationHandle);
      }
      if (!prepared.consume()) {
        throw StateError(currentL10n.thisCommandPreviewHasAlreadyBeen);
      }
    } catch (_) {
      credentialInput?.fillRange(0, credentialInput.length, 0);
      credentialSecrets.clear();
      rethrow;
    }
    if (snippet.executionMode == SnippetExecutionMode.bashCommand) {
      final execCancellation = cancellation!;
      _snippetExecutionInProgress = true;
      try {
        notifyListeners();
        onRemoteExecDispatch?.call();
        late final SshExecResult result;
        try {
          result = await connection.executeRemoteCommand(
            command,
            cancellation: execCancellation,
            stdinData: credentialInput,
            bashUnavailableMarker: bashUnavailableMarker,
          );
        } catch (_) {
          throw const SnippetExecCompletionUnknownException();
        }
        return _redactSnippetCredentialOutput(result, credentialSecrets.values);
      } finally {
        credentialSecrets.clear();
        credentialInput?.fillRange(0, credentialInput.length, 0);
        _snippetExecutionInProgress = false;
        notifyListeners();
      }
    }
    credentialSecrets.clear();
    connection.input('$command\n');
    page = WorkspacePage.terminal;
    notifyListeners();
    return null;
  }

  SshExecResult _redactSnippetCredentialOutput(
    SshExecResult result,
    Iterable<String> secrets,
  ) {
    var stdout = result.stdout;
    var stderr = result.stderr;
    for (final secret in secrets) {
      if (secret.isEmpty) continue;
      final mask = List<String>.filled(secret.length, '*').join();
      stdout = stdout.replaceAll(secret, mask);
      stderr = stderr.replaceAll(secret, mask);
    }
    if (stdout == result.stdout && stderr == result.stderr) return result;
    return SshExecResult(
      stdout: stdout,
      stderr: stderr,
      exitCode: result.exitCode,
      exitSignal: result.exitSignal,
      cancelled: result.cancelled,
      timedOut: result.timedOut,
      outputTruncated: result.outputTruncated,
      bashUnavailable: result.bashUnavailable,
      execOpenPending: result.execOpenPending,
    );
  }

  Future<void> logout() async {
    if (vaultMembershipBusy) {
      throw StateError(currentL10n.theVaultMemberKeyRotationIs2);
    }
    if (accountPasswordChangeBusy) {
      throw StateError(currentL10n.theMasterPasswordChangeIsBeing2);
    }
    ++_authContextGeneration;
    final client = api;
    final endingSession = session;
    final endingBase = client?.baseUrl;
    final endingUsername = _authenticatedUsername;
    bool logoutScopeIsCurrent() =>
        identical(api, client) &&
        identical(session, endingSession) &&
        api?.baseUrl == endingBase &&
        _authenticatedUsername == endingUsername;
    var serverLogoutConfirmed = false;
    try {
      final recovery = _snapshotRecoveryFuture;
      if (recovery != null) await recovery;
      if (!logoutScopeIsCurrent()) return;
      // Logs of the ending session never carry into a later login (even of
      // the same account on this device).
      _sessionLogScope.retire();
      _automaticSync.stop();
      _syncHints.stop();
      if (client != null && endingSession != null && mobilePushSupported) {
        await _stopMobilePushForSession(client: client, auth: endingSession);
      }
      if (!logoutScopeIsCurrent()) return;
      if (client != null) {
        await client.logout();
        serverLogoutConfirmed = true;
      }
    } finally {
      if (logoutScopeIsCurrent() && endingBase != null) {
        try {
          await _sessionRefreshLock.run(() async {
            if (!logoutScopeIsCurrent()) return;
            await secureStore.clearSessionResumeHint(
              endingBase,
              accountId: endingSession?.accountId,
              deviceId: endingSession?.deviceId,
            );
          });
        } catch (_) {
          /* Snapshot revocation below remains authoritative. */
        }
      }
      await _clearLocalAuthenticatedState(
        signalOnStorageError: serverLogoutConfirmed,
        expectedSession: endingSession,
        expectedApi: client,
        expectedBase: endingBase,
        expectedUsername: endingUsername,
        expectedNoSession: endingSession == null,
        removeMobilePushEndpoint: false,
      );
    }
  }

  Future<bool> _clearLocalAuthenticatedState({
    bool signalRemoved = true,
    bool signalOnStorageError = false,
    AuthSession? expectedSession,
    ApiClient? expectedApi,
    String? expectedBase,
    String? expectedUsername,
    bool expectedNoSession = false,
    bool removeMobilePushEndpoint = true,
  }) async {
    bool expectedStateIsCurrent() {
      if (expectedNoSession) {
        return session == null &&
            identical(api, expectedApi) &&
            api?.baseUrl == expectedBase &&
            _authenticatedUsername == expectedUsername;
      }
      if (expectedSession == null) return true;
      return identical(session, expectedSession) &&
          identical(api, expectedApi) &&
          api?.baseUrl == expectedBase &&
          _authenticatedUsername == expectedUsername &&
          session?.accountId == expectedSession.accountId &&
          session?.deviceId == expectedSession.deviceId &&
          session?.refreshToken == expectedSession.refreshToken;
    }

    if (!expectedStateIsCurrent()) return false;
    final lockedReceiveStopGeneration = ++_lockedReceiveStopGeneration;
    _lockedReceiveStopping = true;
    void resumeLockedReceiveIfClearWasSuperseded() {
      if (_lockedReceiveStopGeneration == lockedReceiveStopGeneration) {
        _lockedReceiveStopping = false;
      }
    }

    _verifiedSignerDirectoryCache.invalidate();
    ++_authContextGeneration;
    ++_vaultLoadGeneration;
    final endingSession = session;
    final endingBaseUrl = api?.baseUrl;
    final endingUsername = _authenticatedUsername;
    final endingApi = api;
    if (endingSession != null && endingApi != null && mobilePushSupported) {
      await _stopMobilePushForSession(
        client: endingApi,
        auth: endingSession,
        removeServerEndpoint: removeMobilePushEndpoint,
        clearPreference: removeMobilePushEndpoint,
      );
      if (!expectedStateIsCurrent()) {
        resumeLockedReceiveIfClearWasSuperseded();
        _vaultLoadsBlocked = false;
        return false;
      }
    } else {
      ++_mobilePushGeneration;
      mobilePushEnabled = false;
      mobilePushBusy = false;
      _mobilePushBusyGeneration = null;
      _mobilePushBusyClient = null;
      _mobilePushBusyAccountId = null;
      _mobilePushBusyDeviceId = null;
      await _cancelMobilePushListeners();
    }
    if (!expectedStateIsCurrent()) {
      resumeLockedReceiveIfClearWasSuperseded();
      return false;
    }
    _vaultLoadsBlocked = true;
    ++_authContextGeneration;
    ++_vaultLoadGeneration;
    await _waitForVaultLoadCompletions();
    if (!expectedStateIsCurrent()) {
      resumeLockedReceiveIfClearWasSuperseded();
      _vaultLoadsBlocked = false;
      return false;
    }
    _automaticSync.stop();
    _syncHints.stop();
    await _waitForLockedReceiveCompletion();
    if (!expectedStateIsCurrent()) {
      resumeLockedReceiveIfClearWasSuperseded();
      _vaultLoadsBlocked = false;
      return false;
    }
    _stopVaultPresenceHeartbeats(clearState: true);
    _pendingAccountPasswordChange = null;
    accountPasswordChangeBusy = false;
    api?.accessToken = null;
    try {
      await disconnectAllTerminalTabs();
    } catch (_) {
      // Network/terminal shutdown cannot prevent sensitive memory cleanup.
    }
    _sessionLogScope.retire();
    // A refresh failure can be delayed behind terminal shutdown. If a new
    // login or shared-tab adoption replaced the captured session meanwhile,
    // this old cleanup must not erase it.
    if (!expectedStateIsCurrent()) {
      resumeLockedReceiveIfClearWasSuperseded();
      _vaultLoadsBlocked = false;
      return false;
    }
    await _waitForVaultLoadCompletions();
    if (!expectedStateIsCurrent()) {
      resumeLockedReceiveIfClearWasSuperseded();
      _vaultLoadsBlocked = false;
      return false;
    }
    await _waitForArchiveOperations();
    final retiringRepository = _repository;
    _repository = null;
    ++_vaultSelectionRequestGeneration;
    ++_vaultSelectionGeneration;
    ++_repositoryBuildGeneration;
    syncing = false;
    _syncAgainRequested = false;
    _activeSyncCompletion = null;
    _activeSyncRepository = null;
    _activeSyncSelectionGeneration = null;
    await _retireRepositoryAndTrack(retiringRepository);
    await _waitForRetiredRepositoryDrains();
    syncing = false;
    final recoveryRefresh = _recoverySyncFuture;
    if (recoveryRefresh != null) {
      try {
        await recoveryRefresh;
      } catch (_) {
        // Sensitive-state cleanup must finish even when best-effort recovery
        // metadata upload failed.
      }
    }
    if (!expectedStateIsCurrent()) {
      resumeLockedReceiveIfClearWasSuperseded();
      _vaultLoadsBlocked = false;
      return false;
    }
    final retiringVaultKeys = <Uint8List>{
      ..._vaultKeys.values,
      for (final versions in _vaultEpochKeys.values) ...versions.values,
      for (final buffers in _pendingVaultKeyBufferWipes.values) ...buffers,
    };
    for (final key in retiringVaultKeys) {
      key.fillRange(0, key.length, 0);
    }
    _vaultKeys.clear();
    _vaultEpochKeys.clear();
    _pendingVaultKeyBufferWipes.clear();
    _accountKey?.fillRange(0, _accountKey!.length, 0);
    _accountKey = null;
    _clearRecoveryIdentity();
    identity?.dispose();
    identity = null;
    session = null;
    workspaceLocked = false;
    _lockedReceiveRunning = false;
    lockedInboxReceivedCount = 0;
    _lockedSyncReceiver = null;
    _vaultLoadsBlocked = false;
    account = null;
    accountMfaEnabled = null;
    accountMfaRecoveryCodesRemaining = null;
    accountMfaBusy = false;
    _resetInstanceAdminOverview();
    activeVault = null;
    _vaultDescriptors = [];
    _repository = null;
    _shellHistorySyncEnabled = false;
    _shellHistorySyncEnableInProgress = false;
    _defaultWorkspaceAppliedForVault = false;
    _resetDefaultSectionConflictRepair();
    _knownNames.clear();
    _revisionIds.clear();
    hosts.clear();
    _jumpHostRouteIssues.clear();
    _hostGroupReferenceIssues.clear();
    _unavailableGroupRecordIds.clear();
    credentials.clear();
    groups.clear();
    snippets.clear();
    shellHistoryRecords.clear();
    savedWorkspaces.clear();
    activeSavedWorkspaceId = null;
    _workspacePaneTerminalTabIds.clear();
    knownHosts.clear();
    pendingKnownHostRecordIds.clear();
    preferences.clear();
    preferenceError = null;
    _resetDefaultSectionConflictRepair();
    // These collections may come from immutable API/Drift snapshots. Replace
    // the references so logout/deletion cleanup works for fixed-size lists.
    devices = [];
    _clearVaultDeviceRows();
    vaultMembers = [];
    openConflicts = [];
    feedConflictItems = [];
    _allFeedConflictItems = [];
    _resetAuditState();
    auditScope = AuditScope.account;
    sftpEntries = [];
    selectedHost = null;
    stage = ClientStage.login;
    _authenticatedUsername = null;
    _sessionAccessExpiresAt = null;
    _sessionCredentialsAdoptedAt = null;
    page = WorkspacePage.hosts;
    _defaultWorkspaceAppliedForVault = false;
    syncStatus = 'idle';
    pendingCount = 0;
    receivedCount = 0;
    conflictCount = 0;
    unavailableRecordCount = 0;
    lastSuccessfulSyncAt = null;
    syncCheckpointServerGeneration = null;
    var shouldSignalRemoved = signalOnStorageError;
    if (endingSession != null &&
        endingBaseUrl != null &&
        endingUsername != null) {
      try {
        shouldSignalRemoved = await _sessionRefreshLock.run(
          () => secureStore.deleteSessionCredentialsIfCurrent(
            endingBaseUrl,
            endingUsername,
            deviceId: endingSession.deviceId,
            expectedRefreshToken: endingSession.refreshToken,
          ),
        );
      } catch (_) {
        // Only a confirmed server logout may propagate when storage cannot
        // establish whether a newer login replaced this snapshot.
        shouldSignalRemoved = signalOnStorageError;
      }
    }
    if (signalRemoved &&
        shouldSignalRemoved &&
        endingSession != null &&
        endingBaseUrl != null) {
      _signalSessionUpdate(
        endingBaseUrl,
        _sessionCredentialsFor(endingSession),
        SessionUpdateKind.removed,
      );
    }
    notifyListeners();
    return true;
  }

  Future<void> _forceClearLocalAuthenticatedState() async {
    ++_lockedReceiveStopGeneration;
    _lockedReceiveStopping = true;
    _vaultLoadsBlocked = true;
    _verifiedSignerDirectoryCache.invalidate();
    ++_authContextGeneration;
    ++_vaultLoadGeneration;
    ++_vaultSelectionRequestGeneration;
    ++_vaultSelectionGeneration;
    ++_repositoryBuildGeneration;
    syncing = false;
    _syncAgainRequested = false;
    _activeSyncCompletion = null;
    _activeSyncRepository = null;
    _activeSyncSelectionGeneration = null;
    ++_mobilePushGeneration;
    mobilePushEnabled = false;
    mobilePushBusy = false;
    _mobilePushBusyGeneration = null;
    _mobilePushBusyClient = null;
    _mobilePushBusyAccountId = null;
    _mobilePushBusyDeviceId = null;
    unawaited(_cancelMobilePushListeners());
    final terminalShutdown = disconnectAllTerminalTabs();
    _sessionLogScope.retire();
    _automaticSync.stop();
    _syncHints.stop();
    await _waitForLockedReceiveCompletion();
    _stopVaultPresenceHeartbeats(clearState: true);
    _pendingAccountPasswordChange = null;
    cancelPreparedAccountRecovery(force: true);
    accountPasswordChangeBusy = false;
    api?.accessToken = null;
    final retiringRepository = _repository;
    _repository = null;
    _retireRepositoryAndTrack(retiringRepository);
    final retiringVaultKeys = <Uint8List>{
      ..._vaultKeys.values,
      for (final versions in _vaultEpochKeys.values) ...versions.values,
      for (final buffers in _pendingVaultKeyBufferWipes.values) ...buffers,
    };
    _vaultKeys.clear();
    _vaultEpochKeys.clear();
    _pendingVaultKeyBufferWipes.clear();
    final endingAccountKey = _accountKey;
    _accountKey = null;
    final endingRecoveryIdentity = _recoveryIdentity;
    _recoveryIdentity = null;
    accountRecoveryRequiredContexts = const [];
    accountRecoveryPresentContexts = const [];
    accountRecoveryStatus = 'disabled';
    accountMfaEnabled = null;
    accountMfaRecoveryCodesRemaining = null;
    accountMfaBusy = false;
    final endingIdentity = identity;
    identity = null;
    workspaceLocked = false;
    _lockedReceiveRunning = false;
    lockedInboxReceivedCount = 0;
    _lockedSyncReceiver = null;
    final pendingArchive = _archiveOperationDrained?.future;
    final pendingRecoveryRefresh = _recoverySyncFuture;
    final cleanupBarriers = <Future<void>>[
      ..._retiredRepositoryDrains.values,
      ..._vaultLoadCompletions.map(
        (future) => future.then<void>((_) {}, onError: (_, _) {}),
      ),
      if (pendingArchive != null) pendingArchive,
      if (pendingRecoveryRefresh != null)
        pendingRecoveryRefresh.then<void>((_) {}, onError: (_, _) {}),
      terminalShutdown.then<void>((_) {}, onError: (_, _) {}),
    ];
    void wipeRetiredSecrets() {
      for (final key in retiringVaultKeys) {
        try {
          key.fillRange(0, key.length, 0);
        } catch (_) {}
      }
      try {
        endingAccountKey?.fillRange(0, endingAccountKey.length, 0);
      } catch (_) {}
      try {
        endingRecoveryIdentity?.dispose();
      } catch (_) {}
      try {
        endingIdentity?.dispose();
      } catch (_) {}
    }

    if (cleanupBarriers.isEmpty) {
      wipeRetiredSecrets();
    } else {
      unawaited(
        Future.wait<void>(cleanupBarriers).then<void>(
          (_) => wipeRetiredSecrets(),
          // An unresolved drain cannot certify that a repository stopped
          // reading these buffers. Preserve the secrets rather than wiping
          // memory that a live operation may still access.
          onError: (_, _) {},
        ),
      );
    }
    session = null;
    account = null;
    _resetInstanceAdminOverview();
    activeVault = null;
    _vaultDescriptors = [];
    _repository = null;
    _shellHistorySyncEnabled = false;
    _shellHistorySyncEnableInProgress = false;
    _defaultWorkspaceAppliedForVault = false;
    stage = ClientStage.login;
    _authenticatedUsername = null;
    _sessionAccessExpiresAt = null;
    _sessionCredentialsAdoptedAt = null;
    page = WorkspacePage.hosts;
    _knownNames.clear();
    _revisionIds.clear();
    hosts.clear();
    _jumpHostRouteIssues.clear();
    _hostGroupReferenceIssues.clear();
    _unavailableGroupRecordIds.clear();
    credentials.clear();
    groups.clear();
    snippets.clear();
    shellHistoryRecords.clear();
    savedWorkspaces.clear();
    activeSavedWorkspaceId = null;
    _workspacePaneTerminalTabIds.clear();
    knownHosts.clear();
    pendingKnownHostRecordIds.clear();
    preferences.clear();
    preferenceError = null;
    _resetDefaultSectionConflictRepair();
    devices = [];
    _clearVaultDeviceRows();
    vaultMembers = [];
    openConflicts = [];
    feedConflictItems = [];
    _allFeedConflictItems = [];
    _resetAuditState();
    auditScope = AuditScope.account;
    sftpEntries = [];
    selectedHost = null;
    connectedHost = null;
    syncStatus = 'idle';
    pendingCount = 0;
    receivedCount = 0;
    conflictCount = 0;
    unavailableRecordCount = 0;
    lastSuccessfulSyncAt = null;
    syncCheckpointServerGeneration = null;
  }

  void showWorkspacePage(WorkspacePage value) {
    if (value == WorkspacePage.terminal &&
        activeTerminalTab?.detached == true) {
      _activeTerminalTabId = visibleTerminalTabs.lastOrNull?.id;
    }
    if (stage == ClientStage.workspace) _defaultWorkspaceAppliedForVault = true;
    page = value;
    if (value == WorkspacePage.devices) {
      unawaited(refreshDevices(background: true));
      if (activeVault != null) {
        unawaited(refreshVaultDeviceRows(background: true));
      }
    }
    if (value == WorkspacePage.audit) unawaited(loadAudit(reset: true));
    notifyListeners();
  }

  void selectHost(HostRecord? host) {
    selectedHost = host;
    notifyListeners();
  }

  void setStage(ClientStage value) {
    stage = value;
    notifyListeners();
  }

  Future<String> publicKeyFingerprint(String encodedKey) async {
    final digest = await cryptography.Sha256().hash(
      decodeBase64Url(encodedKey),
    );
    return 'SHA256:${base64Encode(digest.bytes).replaceAll('=', '')}';
  }

  /// Locks the decrypted workspace while keeping the authenticated account
  /// session available for pull-only encrypted change receipt. Use [logout]
  /// for explicit sign-out or server-side session revocation.
  Future<void> lock() => _lockWorkspace();

  Future<void> _lockWorkspace({bool forgetRememberedKey = true}) async {
    if (workspaceLocked || session == null) return;
    if (vaultMembershipBusy || _vaultMembershipChangeActive) {
      throw StateError(currentL10n.theVaultMemberKeyRotationIs);
    }
    if (accountPasswordChangeBusy) {
      throw StateError(currentL10n.theMasterPasswordChangeIsBeing);
    }
    if (archiveBusy) {
      throw StateError(currentL10n.lockTheWorkspaceAfterTheArchive);
    }

    final recovery = _snapshotRecoveryFuture;
    if (recovery != null) await recovery;
    if (session == null || workspaceLocked) return;

    final lockingSession = session!;
    final lockingAuthGeneration = _authContextGeneration;
    workspaceLocked = true;
    final lockingClient = api;
    var rememberedKeyRevocationFailed = false;
    bool lockScopeIsCurrent() =>
        identical(api, lockingClient) &&
        _authContextGeneration == lockingAuthGeneration &&
        session?.accountId == lockingSession.accountId &&
        session?.deviceId == lockingSession.deviceId;
    if (forgetRememberedKey && lockingClient != null) {
      try {
        await _sessionRefreshLock.run(() async {
          final username = _authenticatedUsername;
          if (username != null) {
            try {
              final latest = await secureStore.readSessionCredentials(
                lockingClient.baseUrl,
                username,
                lockingSession.deviceId,
              );
              if (latest != null &&
                  latest.refreshToken != lockingSession.refreshToken) {
                return;
              }
            } catch (_) {
              // Still write the independent revocation veto if keychain reads
              // fail; clearRememberedAccountKey handles this failure path.
            }
          }
          if (!lockScopeIsCurrent()) return;
          await secureStore.clearRememberedAccountKey(
            lockingClient.baseUrl,
            accountId: lockingSession.accountId,
            deviceId: lockingSession.deviceId,
          );
        });
      } catch (_) {
        rememberedKeyRevocationFailed = true;
        // Complete RAM retirement before reporting a durable revocation failure.
      }
    }
    if (!lockScopeIsCurrent()) return;
    final lockGeneration = ++_lockedReceiveStopGeneration;
    _lockedReceiveStopping = true;
    workspaceLocked = true;
    syncStatus = 'locked_receiving';
    errorMessage = null;
    _automaticSync.stop();
    _syncHints.stop();
    _stopVaultPresenceHeartbeats();
    ++_repositoryBuildGeneration;
    ++_vaultLoadGeneration;
    _vaultLoadsBlocked = true;
    ++_knownHostDecisionGeneration;
    ++_mobilePushGeneration;
    mobilePushEnabled = false;
    mobilePushBusy = false;
    _mobilePushBusyGeneration = null;
    _mobilePushBusyClient = null;
    _mobilePushBusyAccountId = null;
    _mobilePushBusyDeviceId = null;
    await _cancelMobilePushListeners();

    final retiringRepository = _repository;
    _repository = null;
    _activeSyncCompletion = null;
    _activeSyncRepository = null;
    _activeSyncSelectionGeneration = null;
    _syncAgainRequested = false;
    try {
      await disconnectAllTerminalTabs();
    } catch (_) {
      // Terminal shutdown cannot prevent the key cleanup below.
    }
    // Session logs follow the unlocked workspace scope.
    _sessionLogScope.retire();
    await _waitForVaultLoadCompletions();
    await _waitForArchiveOperations();
    await _retireRepositoryAndTrack(retiringRepository);
    await _waitForRetiredRepositoryDrains();
    syncing = false;
    final recoveryRefresh = _recoverySyncFuture;
    if (recoveryRefresh != null) {
      try {
        await recoveryRefresh;
      } catch (_) {
        // Recovery metadata upload is best effort; keys are still retired.
      }
    }

    final retiringKeys = <Uint8List>{
      ..._vaultKeys.values,
      for (final versions in _vaultEpochKeys.values) ...versions.values,
      for (final buffers in _pendingVaultKeyBufferWipes.values) ...buffers,
    };
    for (final key in retiringKeys) {
      key.fillRange(0, key.length, 0);
    }
    _vaultKeys.clear();
    _vaultEpochKeys.clear();
    _pendingVaultKeyBufferWipes.clear();
    final accountKey = _accountKey;
    _accountKey = null;
    accountKey?.fillRange(0, accountKey.length, 0);
    _clearRecoveryIdentity();
    identity?.dispose();
    identity = null;
    _knownNames.clear();
    _clearVaultWorkspaceProjection();
    sftpEntries = [];
    selectedHost = null;
    connectedHost = null;
    if (session?.accountId != lockingSession.accountId ||
        session?.deviceId != lockingSession.deviceId ||
        _lockedReceiveStopGeneration != lockGeneration) {
      notifyListeners();
      return;
    }
    _lockedReceiveStopping = false;
    _lockedReceiveRunning = false;
    lockedInboxReceivedCount = 0;
    _lockedSyncReceiver = _createLockedSyncReceiver();
    syncStatus = activeVault == null ? 'locked_no_vault' : 'locked_ready';
    _startSyncHints();
    if (activeVault != null) _automaticSync.start();
    if (rememberedKeyRevocationFailed) {
      errorMessage = currentL10n.theWorkspaceIsLockedButThis;
    }
    notifyListeners();
  }

  LockedSyncReceiver? _createLockedSyncReceiver() {
    final client = api;
    final info = instance;
    final vault = activeVault;
    if (client == null ||
        info == null ||
        vault == null ||
        workspaceLocked == false) {
      return null;
    }
    return LockedSyncReceiver(
      api: client,
      database: database,
      crypto: crypto,
      instanceId: info.instanceId,
      serverSpaceId: info.serverSpaceId,
      vaultId: vault.id,
      serverGeneration: info.generation,
      trustedInstanceSigningPublicKey: info.signingPublicKey,
    );
  }

  /// Restores local keys for the existing authenticated session after the user
  /// re-enters the account password. Unlock does not create a new login; it may
  /// safely rotate the existing refresh token when the session needs refresh.
  Future<void> unlockLockedWorkspace({required String password}) async {
    if (!workspaceLocked || session == null) {
      throw StateError(currentL10n.theWorkspaceIsntLockedRightNow);
    }
    if (password.isEmpty) {
      throw FormatException(currentL10n.enterTheAccountPassword);
    }
    final client = _requireApi();
    final username = _authenticatedUsername;
    final auth = session!;
    if (username == null) {
      throw StateError(currentL10n.theCurrentSessionIsMissingThe);
    }
    if (_lockedUnlockInProgress) return;
    _lockedUnlockInProgress = true;
    _syncHints.stop();
    final activeRefresh = _activeSessionRefreshForSyncHint;
    final inFlightHintRefresh =
        activeRefresh != null &&
            activeRefresh.matches(
              candidateClient: client,
              candidateBase: client.baseUrl,
              candidateUsername: username,
              candidateSession: auth,
            )
        ? activeRefresh.future
        : null;
    _automaticSync.stop();
    _setBusy(true);
    DeviceIdentity? loadedIdentity;
    KdfParameters? params;
    Uint8List? accountKey;
    try {
      await _waitForLockedReceiveCompletion();
      if (session?.accountId != auth.accountId ||
          session?.deviceId != auth.deviceId ||
          !workspaceLocked) {
        throw StateError(currentL10n.theAccountSessionChangedSignIn);
      }
      final hintRefreshSucceeded = inFlightHintRefresh == null
          ? false
          : await inFlightHintRefresh;
      if (!hintRefreshSucceeded &&
          !await _refreshSessionForSyncHint(duringUnlock: true)) {
        throw ApiException(
          statusCode: 401,
          code: 'AUTH_REQUIRED',
          message: currentL10n.currentAccountSessionExpired,
          details: {},
        );
      }
      final prelogin = await client.prelogin(username);
      params = KdfParameters.fromJson(
        Map<String, dynamic>.from(prelogin['kdf'] as Map),
      );
      final profile = await client.accountProfile();
      if (profile.accountId != auth.accountId) {
        throw FormatException(currentL10n.theAccountResponseDoesntMatchThe);
      }
      accountKey = await crypto.unwrapAccountKey(
        password: password,
        params: params,
        envelope: profile.accountKeyEnvelope,
      );
      if (accountKey.length != 32) {
        throw FormatException(currentL10n.invalidAccountKeyLength);
      }
      loadedIdentity = await secureStore.loadDevice(client.baseUrl, crypto);
      if (loadedIdentity == null || loadedIdentity.deviceId != auth.deviceId) {
        throw FormatException(currentL10n.theCurrentDeviceKeyIsMissing);
      }
      account = profile;
      identity?.dispose();
      identity = loadedIdentity;
      loadedIdentity = null;
      _replaceAccountKey(accountKey);
      accountKey = null;
      accountRecoveryStatus = profile.recoveryStatus;
      _vaultLoadsBlocked = false;
      _lockedSyncReceiver = null;
      await _loadVaults(auth, preferredVaultId: activeVault?.id);
      workspaceLocked = false;
      unawaited(_refreshRecoveryContextsAndUpload());
      await _afterUnlock(password, params, auth, tryUnwrapAccountKey: false);
      lockedInboxReceivedCount = 0;
      errorMessage = null;
    } catch (error) {
      final stillAuthenticated =
          session?.accountId == auth.accountId &&
          session?.deviceId == auth.deviceId;
      workspaceLocked = stillAuthenticated;
      _vaultLoadsBlocked = stillAuthenticated;
      final retiringRepository = _repository;
      _repository = null;
      await _retireRepositoryAndTrack(retiringRepository);
      await _waitForRetiredRepositoryDrains();
      final keys = <Uint8List>{
        ..._vaultKeys.values,
        for (final versions in _vaultEpochKeys.values) ...versions.values,
        for (final buffers in _pendingVaultKeyBufferWipes.values) ...buffers,
      };
      for (final key in keys) {
        key.fillRange(0, key.length, 0);
      }
      _vaultKeys.clear();
      _vaultEpochKeys.clear();
      _accountKey?.fillRange(0, _accountKey!.length, 0);
      _accountKey = null;
      identity?.dispose();
      identity = null;
      _clearVaultWorkspaceProjection();
      if (stillAuthenticated) {
        _lockedSyncReceiver ??= _createLockedSyncReceiver();
        if (activeVault != null) _automaticSync.start();
      } else {
        _lockedSyncReceiver = null;
      }
      errorMessage = friendlyError(error);
      rethrow;
    } finally {
      loadedIdentity?.dispose();
      accountKey?.fillRange(0, accountKey.length, 0);
      params?.salt.fillRange(0, params.salt.length, 0);
      _lockedUnlockInProgress = false;
      _setBusy(false);
      if (authenticated) _startSyncHints();
    }
  }

  Future<void> setBusy(Future<void> Function() action) async {
    _setBusy(true);
    errorMessage = null;
    try {
      await action();
    } catch (error) {
      _setError(friendlyError(error));
      rethrow;
    } finally {
      _setBusy(false);
    }
  }

  ApiClient _requireApi() =>
      api ?? (throw StateError(currentL10n.configureTheServerAddressFirst));
  SyncRepository _requireRepository() =>
      _repository ?? (throw StateError(currentL10n.unlockTheVaultFirst));
  String friendlyError(Object error) {
    if (error is DatabaseRecoveryRequiredException) {
      return error.toString();
    }
    if (error is SnapshotBootstrapLimitException) {
      return error.toString();
    }
    if (error is SnapshotRedactionResurrectionException) {
      return currentL10n.theServerSnapshotContainsRecordsThis;
    }
    final sshMessage = sshConnectionFriendlyError(error);
    if (sshMessage != null) return sshMessage;
    if (error is ApiException) {
      switch (error.code) {
        case 'AUTH_REQUIRED':
          return currentL10n.theSignInStateExpiredSign;
        case 'DEVICE_REVOKED':
          return currentL10n.thisDeviceWasRevokedSignIn;
        case 'VAULT_CLIENT_CAPABILITY_REQUIRED':
        case 'DEVICE_CAPABILITY_REQUIRED':
          return currentL10n.someActiveDevicesInTheVault;
        case 'REAUTH_REQUIRED':
          return currentL10n.masterPasswordVerificationFailedTheDeletion;
        case 'VAULT_DELETION_WINDOW_EXPIRED':
          return currentL10n.theVaultDeletionGracePeriodHas;
        case 'VAULT_DELETION_PENDING':
          return currentL10n.thisVaultIsInItsDeletion;
        case 'ACCOUNT_OWNS_SHARED_VAULT':
          return currentL10n.theAccountIsStillTheOwner;
        case 'ACCOUNT_DELETION_PENDING':
          return currentL10n.theAccountAlreadyHasAPending;
        case 'ACCOUNT_DELETION_WINDOW_EXPIRED':
          return currentL10n.theAccountDeletionGracePeriodHas;
        case 'ACCOUNT_DELETION_TRANSITION_CONFLICT':
          return currentL10n.theAccountStateJustChangedSign;
        case 'SETUP_CLOSED':
          return currentL10n.theInstanceIsAlreadyInitializedFirst;
        case 'REVISION_CONFLICT':
          return currentL10n.thisRecordWasUpdatedOnAnother;
        case 'RECORD_RESTORE_EXPIRED':
          final rawDeadline =
              error.details['restore_until'] ??
              error.details['restore_expires_at'];
          final deadline = rawDeadline is String
              ? DateTime.tryParse(rawDeadline)
              : null;
          final dateText = deadline == null
              ? ''
              : currentL10n.restoreDeadlineFormat(
                  DateFormat.yMMMd().add_jm().format(deadline.toLocal()),
                );
          return currentL10n.thisDeletedRecordIsPastThe(dateText);
        case 'RECORD_TOMBSTONED':
          return currentL10n.thisRecordIdIsReservedBy;
        case 'CURSOR_EXPIRED':
        case 'SNAPSHOT_EXPIRED':
        case 'SERVER_GENERATION_CHANGED':
          return currentL10n.theServerSyncCursorExpiredA;
        case 'RATE_LIMITED':
          return currentL10n.tooManyRequestsTryAgainLater;
        case 'RELAY_GROUP_NAME_TAKEN':
          return currentL10n.aServerAccessGroupWithThe;
        case 'RELAY_GROUP_CONFLICT':
        case 'RELAY_GROUP_MEMBERSHIP_CONFLICT':
        case 'RELAY_GROUP_POLICY_CONFLICT':
          return currentL10n.theServerAccessGroupWasUpdated;
        case 'PG_ADMIN_ACTION_UNSUPPORTED':
          return currentL10n.theCurrentPostgresqlModeSupportsInstance;
      }
      return currentL10n.messageCode(error.message, error.code);
    }
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  String friendlyMfaSettingsError(Object error) {
    if (error is ApiException && error.code == 'REAUTH_REQUIRED') {
      return currentL10n.theCurrentMasterPasswordOrSix;
    }
    return friendlyError(error);
  }

  String friendlyMfaLoginError(Object error) {
    if (error is ApiException && error.code == 'AUTH_REQUIRED') {
      return currentL10n.mfaVerificationFailedTheCodeIs;
    }
    return friendlyError(error);
  }

  void _setBusy(bool value) {
    busy = value;
    notifyListeners();
  }

  void _assertEditsAllowed({bool requireWritableVault = false}) {
    if (workspaceLocked) {
      throw StateError(currentL10n.localChangesAreBlockedWhileThe);
    }
    if (snapshotRecoveryActive) {
      throw StateError(currentL10n.localChangesArePausedDuringSnapshot);
    }
    if (_membershipRefreshActive) {
      throw StateError(currentL10n.refreshingVaultMembershipTryChangingIt);
    }
    if (vaultMembershipBusy || _vaultMembershipChangeActive) {
      throw StateError(currentL10n.localChangesArePausedDuringThe);
    }
    if (requireWritableVault && activeVault?.canWrite == false) {
      throw StateError(currentL10n.thisVaultIsInItsDeletion2);
    }
  }

  void _setNotice(String value) {
    noticeMessage = value;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Device-local automatic sync choice and manual "Sync now".
  // ---------------------------------------------------------------------------

  final SyncPreferenceStore _syncPreferenceStore;
  AutomaticSyncPreferenceState automaticSyncPreference;

  /// The device's automatic-sync choice. Only in effect while
  /// [automaticSyncPreference] is ready; defaults to on.
  bool automaticSyncEnabled = true;

  /// A write of the current choice is in flight.
  bool automaticSyncSaving = false;

  /// The latest choice applies to this session but could not be stored; it
  /// will not survive a restart until a retry succeeds.
  bool automaticSyncSaveFailed = false;

  /// Whether automatic triggers (edit debounce, periodic, realtime/push
  /// hints, foreground resume, locked receive) may transfer Vault content.
  bool get automaticSyncActive =>
      automaticSyncPreference == AutomaticSyncPreferenceState.ready &&
      automaticSyncEnabled;

  /// A manual Sync now action is running.
  bool syncNowRunning = false;

  int _automaticSyncPreferenceRevision = 0;
  Future<void> _automaticSyncWrites = Future<void>.value();
  Future<SyncNowResult>? _syncNowInFlight;

  Future<void> _synchronizeAutomatically() =>
      _synchronizeMarked(automatic: true, background: true);

  Future<void> _synchronizeMarked({
    required bool automatic,
    required bool background,
    bool suppressSuccessNotice = false,
  }) {
    // synchronize() reads the marker before its first await; always clear it
    // so it can never leak into a later explicit call.
    _nextSyncIsAutomatic = automatic;
    try {
      return synchronize(
        background: background,
        suppressSuccessNotice: suppressSuccessNotice,
      );
    } finally {
      _nextSyncIsAutomatic = false;
    }
  }

  void _applyAutomaticSyncGate() =>
      _automaticSync.setUserEnabled(automaticSyncActive);

  Future<void> _loadAutomaticSyncPreference() async {
    final revision = ++_automaticSyncPreferenceRevision;
    if (automaticSyncPreference != AutomaticSyncPreferenceState.loading) {
      automaticSyncPreference = AutomaticSyncPreferenceState.loading;
      _applyAutomaticSyncGate();
      notifyListeners();
    }
    bool? stored;
    var failed = false;
    try {
      stored = await _syncPreferenceStore.readAutomaticSync();
    } on Object {
      failed = true;
    }
    // An explicit user choice made while the read was in flight wins.
    if (_controllerDisposed || revision != _automaticSyncPreferenceRevision) {
      return;
    }
    if (failed) {
      automaticSyncPreference = AutomaticSyncPreferenceState.readFailed;
    } else {
      automaticSyncEnabled = stored ?? true;
      automaticSyncPreference = AutomaticSyncPreferenceState.ready;
    }
    _applyAutomaticSyncGate();
    notifyListeners();
  }

  /// Stores and applies this device's automatic sync choice. The choice takes
  /// effect immediately for this session (turning it off stops automatic
  /// transfer even if storing fails); queued encrypted edits stay in the
  /// outbox either way. Writes are serialized so the stored value always
  /// matches the latest choice. Returns whether the latest choice was stored.
  Future<bool> setAutomaticSyncEnabled(bool enabled) async {
    if (_controllerDisposed) return false;
    final revision = ++_automaticSyncPreferenceRevision;
    automaticSyncEnabled = enabled;
    automaticSyncPreference = AutomaticSyncPreferenceState.ready;
    automaticSyncSaving = true;
    automaticSyncSaveFailed = false;
    _applyAutomaticSyncGate();
    notifyListeners();
    final write = _automaticSyncWrites.then(
      (_) => _syncPreferenceStore.writeAutomaticSync(enabled),
    );
    _automaticSyncWrites = write.then<void>((_) {}, onError: (Object _) {});
    var stored = true;
    try {
      await write;
    } on Object {
      stored = false;
    }
    if (_controllerDisposed || revision != _automaticSyncPreferenceRevision) {
      return stored;
    }
    automaticSyncSaving = false;
    automaticSyncSaveFailed = !stored;
    notifyListeners();
    return stored;
  }

  /// Retries whatever failed last: re-reads an unreadable stored choice, or
  /// re-stores the current choice after a failed save.
  Future<void> retryAutomaticSyncPreference() async {
    if (_controllerDisposed) return;
    if (automaticSyncPreference == AutomaticSyncPreferenceState.readFailed) {
      await _loadAutomaticSyncPreference();
    } else if (automaticSyncSaveFailed && !automaticSyncSaving) {
      await setAutomaticSyncEnabled(automaticSyncEnabled);
    }
  }

  Object? _syncNowScope() => (
    api,
    session?.accountId,
    identity?.deviceId,
    activeVault?.id,
    _vaultSelectionGeneration,
  );

  /// Manual "Sync now". Works whether or not automatic sync is on. The result
  /// is bound to the account/device/Vault scope captured at the start; if that
  /// changes while the pass runs, the result is [SyncNowOutcome.superseded]
  /// and nothing is reported for the new scope.
  Future<SyncNowResult> syncNow() {
    final inFlight = _syncNowInFlight;
    if (inFlight != null) return inFlight;
    final run = _runSyncNow();
    _syncNowInFlight = run;
    return run.whenComplete(() {
      if (identical(_syncNowInFlight, run)) _syncNowInFlight = null;
    });
  }

  Future<SyncNowResult> _runSyncNow() async {
    if (_controllerDisposed || !authenticated) {
      return const SyncNowResult(SyncNowOutcome.signInRequired);
    }
    final scope = _syncNowScope();
    final passesBefore = _syncPassCompletions;
    syncNowRunning = true;
    notifyListeners();
    Object? failure;
    try {
      await synchronize(suppressSuccessNotice: true);
    } on Object catch (error) {
      failure = error;
    } finally {
      syncNowRunning = false;
      if (!_controllerDisposed) notifyListeners();
    }
    if (_controllerDisposed || _syncNowScope() != scope) {
      return const SyncNowResult(SyncNowOutcome.superseded);
    }
    if (!authenticated) {
      return const SyncNowResult(SyncNowOutcome.signInRequired);
    }
    if (failure != null) {
      return SyncNowResult(SyncNowOutcome.notCompleted, error: failure);
    }
    // synchronize() returns quietly when it cannot start (no repository yet,
    // recovery or membership change in progress, size limit). Never present
    // that as a completed sync.
    if (_syncPassCompletions == passesBefore) {
      return const SyncNowResult(SyncNowOutcome.notCompleted);
    }
    if (workspaceLocked) {
      return SyncNowResult(
        syncStatus == 'locked_ready'
            ? SyncNowOutcome.completed
            : SyncNowOutcome.notCompleted,
      );
    }
    if (syncStatus == 'idle' || syncStatus == 'pending') {
      return SyncNowResult(
        pendingCount > 0
            ? SyncNowOutcome.completedWithPending
            : SyncNowOutcome.completed,
      );
    }
    return const SyncNowResult(SyncNowOutcome.notCompleted);
  }

  void _setError(String value) {
    errorMessage = value;
    notifyListeners();
  }

  void _onDatabaseQuarantineChanged() {
    if (!databaseRecoveryRequired) return;
    _automaticSync.stop();
    _syncHints.stop();
    _stopVaultPresenceHeartbeats(clearState: true);
    _syncAgainRequested = false;
    errorMessage = const DatabaseRecoveryRequiredException().toString();
    notifyListeners();
  }

  String _vaultVersionKey(String epoch, String membershipVersion) =>
      '$epoch:$membershipVersion';

  Future<void> _disposeComplete = Future<void>.value();

  /// Stops this window's cloud activity before opening another workspace mode.
  Future<void>? _workspaceClose;
  Future<void> closeWorkspace() => _workspaceClose ??= _closeWorkspace();
  Future<void> _closeWorkspace() async {
    dispose();
    await _disposeComplete;
    await database.close();
  }

  @override
  void dispose() {
    if (_controllerDisposed) return;
    final pendingSync = _activeSyncCompletion?.future;
    _controllerDisposed = true;
    _sessionLogScope.dispose();
    _vaultLoadsBlocked = true;
    _verifiedSignerDirectoryCache.invalidate();
    ++_authContextGeneration;
    ++_vaultLoadGeneration;
    _recoverySyncRequested = false;
    ++_vaultSelectionRequestGeneration;
    ++_vaultSelectionGeneration;
    ++_repositoryBuildGeneration;
    syncing = false;
    _syncAgainRequested = false;
    _activeSyncCompletion = null;
    _activeSyncRepository = null;
    _activeSyncSelectionGeneration = null;
    ++_mobilePushGeneration;
    mobilePushEnabled = false;
    mobilePushBusy = false;
    _mobilePushBusyGeneration = null;
    _mobilePushBusyClient = null;
    _mobilePushBusyAccountId = null;
    _mobilePushBusyDeviceId = null;
    final pushShutdown = _cancelMobilePushListeners();
    _discardPendingInstanceIdentityRecovery();
    databaseQuarantineRegistry.removeListener(_onDatabaseQuarantineChanged);
    _automaticSync.stop();
    _syncHints.stop();
    _stopVaultPresenceHeartbeats(clearState: true);
    _resetAdminRestoreStage();
    _resetAdminAccountRelayPolicy();
    _resetInstanceAdminMetricsCredential();
    final observerShutdown = _sessionCredentialsObserver.dispose();
    _sessionUpdateNotifier.dispose();
    final terminalShutdown = disconnectAllTerminalTabs();
    final recoveryShutdown = cancelPreparedAccountRecovery(
      force: true,
      clearStoredPending: false,
    );
    final retiredRepository = _repository;
    _repository = null;
    _retireRepositoryAndTrack(retiredRepository);
    final retiredVaultKeys = <Uint8List>{
      ..._vaultKeys.values,
      for (final versions in _vaultEpochKeys.values) ...versions.values,
      for (final buffers in _pendingVaultKeyBufferWipes.values) ...buffers,
    };
    _vaultKeys.clear();
    _vaultEpochKeys.clear();
    _pendingVaultKeyBufferWipes.clear();
    final retiredAccountKey = _accountKey;
    _accountKey = null;
    final retiredRecoveryIdentity = _recoveryIdentity;
    _recoveryIdentity = null;
    final retiredIdentity = identity;
    identity = null;
    final activeApi = api;
    activeApi?.close();
    final pendingArchive = _archiveOperationDrained?.future;
    final pendingRecoveryRefresh = _recoverySyncFuture;
    final cleanupBarriers = <Future<void>>[
      if (pendingSync != null)
        pendingSync.then<void>((_) {}, onError: (_, _) {}),
      pushShutdown.then<void>((_) {}, onError: (_, _) {}),
      observerShutdown.then<void>((_) {}, onError: (_, _) {}),
      recoveryShutdown.then<void>((_) {}, onError: (_, _) {}),
      ..._retiredRepositoryDrains.values,
      ..._vaultLoadCompletions.map(
        (future) => future.then<void>((_) {}, onError: (_, _) {}),
      ),
      if (pendingArchive != null) pendingArchive,
      if (pendingRecoveryRefresh != null)
        pendingRecoveryRefresh.then<void>((_) {}, onError: (_, _) {}),
      terminalShutdown.then<void>((_) {}, onError: (_, _) {}),
    ];
    void wipeDisposedSecrets() {
      for (final key in retiredVaultKeys) {
        try {
          key.fillRange(0, key.length, 0);
        } catch (_) {}
      }
      try {
        retiredAccountKey?.fillRange(0, retiredAccountKey.length, 0);
      } catch (_) {}
      try {
        retiredRecoveryIdentity?.dispose();
      } catch (_) {}
      try {
        retiredIdentity?.dispose();
      } catch (_) {}
    }

    if (cleanupBarriers.isEmpty) {
      wipeDisposedSecrets();
    } else {
      _disposeComplete = Future.wait<void>(cleanupBarriers)
          .then<void>((_) => wipeDisposedSecrets());
      // Keep disposal safe for synchronous Widget.dispose callers as well.
      unawaited(_disposeComplete.catchError((Object _) {}));
    }
    super.dispose();
  }
}
