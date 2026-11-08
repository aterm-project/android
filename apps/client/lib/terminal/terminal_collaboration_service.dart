import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/api_client.dart';
import '../crypto/vault_crypto.dart'
    show DeviceIdentity, VaultCrypto, decodeBase64Url, encodeBase64Url;
import 'terminal_collaboration_crypto.dart';
import 'terminal_collaboration_websocket.dart';

const _maxObservers = 8;
const _maxOutputBytes = 16 * 1024;
const _maxWebSocketMessageBytes = 64 * 1024;
const _maxWebSocketBufferedBytes = 128 * 1024;
const _webSocketBufferPollInterval = Duration(milliseconds: 20);
const _defaultUplinkWaitTimeout = Duration(seconds: 3);
const _handshakeTimeout = Duration(seconds: 10);
const _maxInputBytes = 8 * 1024;
const _maxQueuedControllerInputBytes = 1024 * 1024;
// The server uses integer-second buckets. A stricter sliding window stays
// below its 64 KiB ciphertext-byte and 128-frame limits across bucket edges.
const _maxControllerBytesPerSecond = 60 * 1024;
const _maxControllerFramesPerSecond = 120;
const _controllerRateWindow = Duration(seconds: 1);
const _uuid = Uuid();

/// A current active Vault device selected for an observer grant.
class TerminalShareRecipient {
  TerminalShareRecipient._({
    required this.userId,
    required this.deviceId,
    required Uint8List encryptionPublicKey,
    Uint8List? signingPublicKey,
  }) : encryptionPublicKey = Uint8List.fromList(encryptionPublicKey),
       signingPublicKey = signingPublicKey == null
           ? null
           : Uint8List.fromList(signingPublicKey);

  factory TerminalShareRecipient.fromVaultDevice(Map<String, dynamic> row) {
    final userId = row['user_id'];
    final deviceId = row['device_id'];
    final encryptionText = row['encryption_public_key'];
    final signingText = row['signing_public_key'];
    if (row['status'] != 'active' ||
        row['membership_status'] != 'active' ||
        userId is! String ||
        deviceId is! String ||
        encryptionText is! String) {
      throw const FormatException(
        'Terminal observer must be an active Vault device.',
      );
    }
    _requireUuid(userId, 'user_id');
    _requireUuid(deviceId, 'device_id');
    final key = _canonicalBytes(encryptionText, expectedBytes: 32);
    Uint8List? signingKey;
    if (signingText is String) {
      try {
        signingKey = _canonicalBytes(signingText, expectedBytes: 32);
      } on FormatException {
        // V1 observer sharing does not depend on this field. V2 controller
        // grants fail closed when the registered signing key is unavailable.
      }
    }
    return TerminalShareRecipient._(
      userId: userId,
      deviceId: deviceId,
      encryptionPublicKey: key,
      signingPublicKey: signingKey,
    );
  }

  final String userId;
  final String deviceId;
  final Uint8List encryptionPublicKey;
  final Uint8List? signingPublicKey;
}

class TerminalCollaborationEvent {
  const TerminalCollaborationEvent.output(this.output)
    : kind = 'output',
      cols = null,
      rows = null,
      leaseId = null,
      controlEpoch = null,
      expiresAt = null,
      reason = null;

  const TerminalCollaborationEvent.resize({
    required this.cols,
    required this.rows,
  }) : kind = 'resize',
       output = null,
       leaseId = null,
       controlEpoch = null,
       expiresAt = null,
       reason = null;

  const TerminalCollaborationEvent.controllerGranted({
    required this.leaseId,
    required this.controlEpoch,
    required this.expiresAt,
  }) : kind = 'controller_granted',
       output = null,
       cols = null,
       rows = null,
       reason = null;

  const TerminalCollaborationEvent.controllerEnded({
    required this.leaseId,
    required this.reason,
  }) : kind = 'controller_ended',
       output = null,
       cols = null,
       rows = null,
       controlEpoch = null,
       expiresAt = null;

  final String kind;
  final String? output;
  final int? cols;
  final int? rows;
  final String? leaseId;
  final int? controlEpoch;
  final DateTime? expiresAt;
  final String? reason;
}

/// Host-side controller activity. Input byte arrays are transient; the host
/// should pass them directly to its SSH input sink and clear them afterwards.
class TerminalCollaborationHostEvent {
  const TerminalCollaborationHostEvent.input({
    required this.bytes,
    required this.leaseId,
    required this.controlEpoch,
    required this.controllerUserId,
    required this.controllerDeviceId,
  }) : kind = 'input',
       reason = null;

  const TerminalCollaborationHostEvent.controllerEnded({
    required this.leaseId,
    required this.reason,
  }) : kind = 'controller_ended',
       bytes = null,
       controlEpoch = null,
       controllerUserId = null,
       controllerDeviceId = null;

  final String kind;
  final Uint8List? bytes;
  final String leaseId;
  final int? controlEpoch;
  final String? controllerUserId;
  final String? controllerDeviceId;
  final String? reason;
}

class TerminalControllerLease {
  const TerminalControllerLease({
    required this.leaseId,
    required this.controlEpoch,
    required this.expiresAt,
    required this.controllerUserId,
    required this.controllerDeviceId,
    this.isPending = false,
  });

  final String leaseId;
  final int controlEpoch;
  final DateTime expiresAt;
  final String controllerUserId;
  final String controllerDeviceId;
  final bool isPending;
}

/// Owns the short-lived HTTPS control requests and authenticated collaboration
/// WebSockets used by one currently active Vault.
///
/// The service never writes tickets, keyboxes or the session secret to storage.
/// Keep each returned handle scoped to its active terminal tab and close it on
/// stop, tab close, sign-out, or Vault switch.
class TerminalCollaborationService {
  TerminalCollaborationService({
    required this.api,
    required this.crypto,
    required this.identity,
    required this.accountId,
    required this.vaultId,
    required this.membershipVersion,
    @visibleForTesting WebSocketChannel Function(Uri)? channelFactory,
    @visibleForTesting int? Function(WebSocketChannel)? bufferedAmountProvider,
    @visibleForTesting Duration uplinkWaitTimeout = _defaultUplinkWaitTimeout,
    @visibleForTesting DateTime Function()? now,
  }) : _crypto = TerminalCollaborationCrypto(crypto.sodium),
       _channelFactory =
           channelFactory ?? createTerminalCollaborationWebSocketChannel,
       _bufferedAmountProvider =
           bufferedAmountProvider ??
           terminalCollaborationWebSocketBufferedAmount,
       _uplinkWaitTimeout = uplinkWaitTimeout,
       _now = now ?? DateTime.now {
    _requireUuid(accountId, 'accountId');
    _requireUuid(vaultId, 'vaultId');
    _requireUuid(identity.deviceId, 'deviceId');
    if (membershipVersion < 1) {
      throw ArgumentError.value(membershipVersion, 'membershipVersion');
    }
    if (uplinkWaitTimeout <= Duration.zero) {
      throw ArgumentError.value(uplinkWaitTimeout, 'uplinkWaitTimeout');
    }
  }

  final ApiClient api;
  final VaultCrypto crypto;
  final DeviceIdentity identity;
  final String accountId;
  final String vaultId;
  final int membershipVersion;
  final TerminalCollaborationCrypto _crypto;
  final WebSocketChannel Function(Uri) _channelFactory;
  final int? Function(WebSocketChannel) _bufferedAmountProvider;
  final Duration _uplinkWaitTimeout;
  final DateTime Function() _now;

  /// Creates a fixed observer roster and waits for the one-use host ticket to
  /// authenticate before returning. Host output is never sent before the
  /// `authenticated` acknowledgement.
  Future<TerminalShareHostSession> startHost({
    required String sessionId,
    required DateTime expiresAt,
    required List<TerminalShareRecipient> observers,
    bool allowInput = false,
  }) async {
    _requireUuid(sessionId, 'sessionId');
    final now = _now().toUtc();
    if (!expiresAt.isUtc ||
        !expiresAt.isAfter(now) ||
        expiresAt.isAfter(now.add(const Duration(minutes: 15)))) {
      throw ArgumentError.value(
        expiresAt,
        'expiresAt',
        'Must be a UTC time within the next 15 minutes.',
      );
    }
    if (observers.isEmpty || observers.length > _maxObservers) {
      throw ArgumentError.value(observers.length, 'observers');
    }
    final seen = <String>{};
    for (final observer in observers) {
      if (observer.deviceId == identity.deviceId ||
          !seen.add('${observer.userId}/${observer.deviceId}')) {
        throw const FormatException(
          'Terminal observer devices must be unique and cannot include the host device.',
        );
      }
    }

    await _verifyCurrentRecipients(observers);
    final observerContexts = <_HostObserverContext>[];
    var createdOnServer = false;
    try {
      final expiresAtText = expiresAt.toIso8601String();
      final observerRequests = <Map<String, Object?>>[];
      for (final observer in observers) {
        final observerSecret = _crypto.createSessionSecret();
        final context = _context(
          sessionId: sessionId,
          observerUserId: observer.userId,
          observerDeviceId: observer.deviceId,
        );
        observerContexts.add(
          _HostObserverContext(observer, context, observerSecret),
        );
        final keybox = _crypto.createKeybox(
          sessionSecret: observerSecret,
          hostIdentity: identity,
          observerEncryptionPublicKey: observer.encryptionPublicKey,
          context: context,
          expiresAt: expiresAt,
        );
        observerRequests.add({
          'user_id': observer.userId,
          'device_id': observer.deviceId,
          'keybox': keybox,
        });
      }
      final response = await api.createTerminalCollaborationSession(vaultId, {
        'protocol_version': allowInput ? 2 : 1,
        'session_id': sessionId,
        'expires_at': expiresAtText,
        'observers': observerRequests,
      });
      createdOnServer = true;
      final ticket = _ticketResponse(
        response,
        sessionId: sessionId,
        requestedExpiresAt: expiresAt,
        expectedRole: 'host',
      );
      final channel = _channelFactory(
        api.terminalCollaborationWebSocketUri(ticket.connectPath),
      );
      late final TerminalShareHostSession host;
      final socket = _TerminalCollaborationSocket(
        channel: channel,
        sessionId: sessionId,
        role: 'host',
        bufferedAmount: () => _bufferedAmountProvider(channel),
        uplinkWaitTimeout: _uplinkWaitTimeout,
        onMessage: (message) => host._onServerMessage(message),
        onDone: () => host._onSocketDone(),
      );
      host = TerminalShareHostSession._(
        service: this,
        sessionId: sessionId,
        expiresAt: expiresAt,
        allowInput: allowInput,
        observers: observerContexts,
        socket: socket,
      );
      await socket.authenticate(ticket.ticket);
      return host;
    } catch (_) {
      for (final observer in observerContexts) {
        observer.clearSecret();
      }
      if (createdOnServer) {
        try {
          await api
              .stopTerminalCollaborationSession(
                vaultId: vaultId,
                sessionId: sessionId,
              )
              .timeout(const Duration(seconds: 3));
        } on Object {
          // Host WebSocket teardown also ends a room if DELETE is unavailable.
        }
      }
      rethrow;
    }
  }

  /// Obtains and validates the host-signed device keybox before connecting.
  /// The observer object intentionally has no input, resize-request, or command
  /// API; the server also rejects all observer application frames.
  Future<TerminalShareObserverSession> joinObserver({
    required String sessionId,
  }) async {
    _requireUuid(sessionId, 'sessionId');
    final response = await api.terminalCollaborationTicket(
      vaultId: vaultId,
      sessionId: sessionId,
    );
    final ticket = _observerTicketResponse(response);
    final keybox = Map<String, dynamic>.from(response['keybox'] as Map);
    final hostUserId = keybox['host_user_id'];
    final hostDeviceId = keybox['host_device_id'];
    if (hostUserId is! String || hostDeviceId is! String) {
      throw const FormatException('Terminal collaboration keybox is invalid.');
    }
    _requireUuid(hostUserId, 'host_user_id');
    _requireUuid(hostDeviceId, 'host_device_id');
    final host = await _activeVaultDevice(hostUserId, hostDeviceId);
    final signingKeyText = host['signing_public_key'];
    if (signingKeyText is! String) {
      throw const FormatException(
        'Terminal collaboration host key is unavailable.',
      );
    }
    final hostSigningPublicKey = _canonicalBytes(
      signingKeyText,
      expectedBytes: 32,
    );
    Uint8List? sessionSecret;
    _TerminalCollaborationSocket? socket;
    late final TerminalShareObserverSession observer;
    var ownershipTransferred = false;
    try {
      final context = _context(
        sessionId: sessionId,
        observerUserId: accountId,
        observerDeviceId: identity.deviceId,
        hostUserId: hostUserId,
        hostDeviceId: hostDeviceId,
      );
      final openedSecret = _crypto.openKeybox(
        keybox: keybox,
        observerIdentity: identity,
        hostSigningPublicKey: hostSigningPublicKey,
        expectedContext: context,
        now: _now().toUtc(),
      );
      sessionSecret = openedSecret;
      final channel = _channelFactory(
        api.terminalCollaborationWebSocketUri(ticket.connectPath),
      );
      final activeSocket = _TerminalCollaborationSocket(
        channel: channel,
        sessionId: sessionId,
        role: 'observer',
        bufferedAmount: () => _bufferedAmountProvider(channel),
        uplinkWaitTimeout: _uplinkWaitTimeout,
        onMessage: (message) => observer._onServerMessage(
          message,
          context: context,
          sessionSecret: openedSecret,
          hostSigningPublicKey: hostSigningPublicKey,
        ),
        onDone: () => observer._onSocketDone(),
      );
      socket = activeSocket;
      observer = TerminalShareObserverSession._(
        service: this,
        sessionId: sessionId,
        socket: activeSocket,
        sessionSecret: openedSecret,
        context: context,
        roomExpiresAt: DateTime.parse(keybox['expires_at'] as String),
        hostSigningPublicKey: hostSigningPublicKey,
        crypto: _crypto,
      );
      ownershipTransferred = true;
      await activeSocket.authenticate(ticket.ticket);
      return observer;
    } catch (_) {
      if (ownershipTransferred) {
        observer._clearSecret();
      } else {
        sessionSecret?.fillRange(0, sessionSecret.length, 0);
        hostSigningPublicKey.fillRange(0, hostSigningPublicKey.length, 0);
      }
      await socket?.close();
      rethrow;
    }
  }

  Future<TerminalShareControllerSession> _joinController(
    TerminalShareObserverSession observer,
  ) async {
    observer._requireControlJoinReady();
    final grant = observer._controllerGrant!;
    final response = await api.terminalControllerTicket(
      vaultId: vaultId,
      sessionId: observer.sessionId,
    );
    observer._requireControlJoinReady();
    if (observer.controllerGrant?.leaseId != grant.leaseId) {
      throw const FormatException(
        'Terminal controller lease is no longer active.',
      );
    }
    if (response.keys.toSet().length != 7 ||
        !response.keys.toSet().containsAll(const {
          'ticket',
          'role',
          'lease_id',
          'control_epoch',
          'control_keybox',
          'ticket_expires_at',
          'connect_path',
        }) ||
        response['ticket'] is! String ||
        response['role'] != 'controller' ||
        response['lease_id'] != grant.leaseId ||
        response['control_epoch'] is! int ||
        response['control_epoch'] != grant.controlEpoch ||
        response['control_keybox'] is! Map ||
        response['ticket_expires_at'] is! String ||
        response['connect_path'] is! String) {
      throw const FormatException(
        'Invalid terminal controller ticket response.',
      );
    }
    final ticketExpiry = DateTime.tryParse(
      response['ticket_expires_at'] as String,
    );
    final ticketExpiryText = response['ticket_expires_at'] as String;
    final now = _now().toUtc();
    if (ticketExpiry == null ||
        !ticketExpiry.isUtc ||
        !_isServerUtcWholeSecondTimestamp(ticketExpiryText, ticketExpiry) ||
        !ticketExpiry.isAfter(now) ||
        ticketExpiry.isAfter(now.add(const Duration(seconds: 31))) ||
        ticketExpiry.isAfter(grant.expiresAt)) {
      throw const FormatException('Invalid terminal controller ticket expiry.');
    }
    final ticket = response['ticket'] as String;
    _validateTicket(ticket);
    final connectPath = response['connect_path'] as String;
    final socketUri = api.terminalCollaborationWebSocketUri(connectPath);
    final hostSigningKey = observer._copyHostSigningPublicKey();
    final context = TerminalControlContext(
      sessionId: observer.sessionId,
      vaultId: observer.context.vaultId,
      membershipVersion: observer.context.membershipVersion,
      hostUserId: observer.context.hostUserId,
      hostDeviceId: observer.context.hostDeviceId,
      controllerUserId: accountId,
      controllerDeviceId: identity.deviceId,
      leaseId: grant.leaseId,
      controlEpoch: grant.controlEpoch,
    );
    Uint8List? controlSecret;
    _TerminalCollaborationSocket? socket;
    TerminalShareControllerSession? createdController;
    try {
      final keybox = Map<String, dynamic>.from(
        response['control_keybox'] as Map,
      );
      final openedSecret = _crypto.openControlKeybox(
        keybox: keybox,
        controllerIdentity: identity,
        hostSigningPublicKey: hostSigningKey,
        expectedContext: context,
        now: now,
      );
      final keyboxExpiresAt = DateTime.parse(keybox['expires_at'] as String);
      if (!keyboxExpiresAt.isAtSameMomentAs(grant.expiresAt) ||
          keyboxExpiresAt.isAfter(observer.roomExpiresAt) ||
          observer.controllerGrant?.leaseId != grant.leaseId ||
          !observer.isConnected) {
        openedSecret.fillRange(0, openedSecret.length, 0);
        throw const FormatException('Controller lease context is invalid.');
      }
      controlSecret = openedSecret;
      final channel = _channelFactory(socketUri);
      late final TerminalShareControllerSession controller;
      final activeSocket = _TerminalCollaborationSocket(
        channel: channel,
        sessionId: observer.sessionId,
        role: 'controller',
        expectedLeaseId: grant.leaseId,
        expectedControlEpoch: grant.controlEpoch,
        bufferedAmount: () => _bufferedAmountProvider(channel),
        uplinkWaitTimeout: _uplinkWaitTimeout,
        onMessage: (_) => throw const FormatException(
          'Unexpected server message on terminal controller socket.',
        ),
        onDone: () => controller._onSocketDone(),
      );
      socket = activeSocket;
      controller = TerminalShareControllerSession._(
        service: this,
        sessionId: observer.sessionId,
        context: context,
        socket: activeSocket,
        controlSecret: openedSecret,
        expiresAt: keyboxExpiresAt,
      );
      createdController = controller;
      controlSecret = null;
      await activeSocket.authenticate(ticket);
      hostSigningKey.fillRange(0, hostSigningKey.length, 0);
      return controller;
    } catch (_) {
      controlSecret?.fillRange(0, controlSecret.length, 0);
      createdController?._clearSecret();
      hostSigningKey.fillRange(0, hostSigningKey.length, 0);
      await socket?.close();
      rethrow;
    }
  }

  Future<void> _verifyCurrentRecipients(
    List<TerminalShareRecipient> observers,
  ) async {
    final directory = await api.vaultDevices(vaultId);
    final byIdentity = <String, Map<String, dynamic>>{
      for (final device in directory)
        if (device['user_id'] is String && device['device_id'] is String)
          '${device['user_id']}/${device['device_id']}': device,
    };
    for (final observer in observers) {
      final row = byIdentity['${observer.userId}/${observer.deviceId}'];
      if (row == null ||
          row['status'] != 'active' ||
          row['membership_status'] != 'active' ||
          row['encryption_public_key'] is! String ||
          row['encryption_public_key'] !=
              encodeBase64Url(observer.encryptionPublicKey)) {
        throw const FormatException(
          'A selected terminal observer is no longer an active Vault device.',
        );
      }
    }
  }

  Future<Map<String, dynamic>> _activeVaultDevice(
    String userId,
    String deviceId,
  ) async {
    final devices = await api.vaultDevices(vaultId);
    for (final device in devices) {
      if (device['user_id'] == userId && device['device_id'] == deviceId) {
        if (device['status'] != 'active' ||
            device['membership_status'] != 'active') {
          throw const FormatException(
            'Terminal collaboration host is not an active Vault device.',
          );
        }
        return device;
      }
    }
    throw const FormatException(
      'Terminal collaboration host is not in the active Vault device directory.',
    );
  }

  TerminalCollaborationContext _context({
    required String sessionId,
    required String observerUserId,
    required String observerDeviceId,
    String? hostUserId,
    String? hostDeviceId,
  }) => TerminalCollaborationContext(
    sessionId: sessionId,
    vaultId: vaultId,
    membershipVersion: membershipVersion,
    hostUserId: hostUserId ?? accountId,
    hostDeviceId: hostDeviceId ?? identity.deviceId,
    observerUserId: observerUserId,
    observerDeviceId: observerDeviceId,
  );

  _TerminalCollaborationTicket _ticketResponse(
    Map<String, dynamic> response, {
    required String sessionId,
    required DateTime requestedExpiresAt,
    required String expectedRole,
  }) {
    if (response.keys.toSet().length != 4 ||
        !response.keys.toSet().containsAll(const {
          'session_id',
          'expires_at',
          'host_ticket',
          'connect_path',
        }) ||
        response['session_id'] != sessionId ||
        response['expires_at'] is! String ||
        response['host_ticket'] is! String ||
        response['connect_path'] is! String) {
      throw const FormatException(
        'Invalid terminal collaboration host response.',
      );
    }
    final expiresAt = DateTime.tryParse(response['expires_at'] as String);
    if (expiresAt == null ||
        !expiresAt.isUtc ||
        !expiresAt.isAtSameMomentAs(requestedExpiresAt)) {
      throw const FormatException(
        'Invalid terminal collaboration session expiry.',
      );
    }
    final ticket = response['host_ticket'] as String;
    _validateTicket(ticket);
    final connectPath = response['connect_path'] as String;
    // Validate before any ticket is offered to a WebSocket implementation.
    api.terminalCollaborationWebSocketUri(connectPath);
    return _TerminalCollaborationTicket(
      ticket: ticket,
      connectPath: connectPath,
      expiresAt: expiresAt,
      role: expectedRole,
    );
  }

  _TerminalCollaborationTicket _observerTicketResponse(
    Map<String, dynamic> response,
  ) {
    if (response.keys.toSet().length != 5 ||
        !response.keys.toSet().containsAll(const {
          'ticket',
          'role',
          'keybox',
          'ticket_expires_at',
          'connect_path',
        }) ||
        response['ticket'] is! String ||
        response['role'] != 'observer' ||
        response['keybox'] is! Map ||
        response['ticket_expires_at'] is! String ||
        response['connect_path'] is! String) {
      throw const FormatException(
        'Invalid terminal collaboration ticket response.',
      );
    }
    final expiresAt = DateTime.tryParse(
      response['ticket_expires_at'] as String,
    );
    final now = _now().toUtc();
    if (expiresAt == null ||
        !expiresAt.isUtc ||
        !expiresAt.isAfter(now) ||
        expiresAt.isAfter(now.add(const Duration(seconds: 31)))) {
      throw const FormatException(
        'Invalid terminal collaboration ticket expiry.',
      );
    }
    final ticket = response['ticket'] as String;
    _validateTicket(ticket);
    final connectPath = response['connect_path'] as String;
    api.terminalCollaborationWebSocketUri(connectPath);
    return _TerminalCollaborationTicket(
      ticket: ticket,
      connectPath: connectPath,
      expiresAt: expiresAt,
      role: 'observer',
    );
  }
}

class TerminalShareHostSession {
  TerminalShareHostSession._({
    required this.service,
    required this.sessionId,
    required this.expiresAt,
    required this.allowInput,
    required this._observers,
    required this._socket,
  });

  final TerminalCollaborationService service;
  final String sessionId;
  final DateTime expiresAt;
  final bool allowInput;
  final List<_HostObserverContext> _observers;
  final _TerminalCollaborationSocket _socket;
  final Map<String, int> _sequence = {};
  Future<void> _sendQueue = Future<void>.value();
  int _queuedBytes = 0;
  final StreamController<TerminalCollaborationHostEvent> _events =
      StreamController<TerminalCollaborationHostEvent>.broadcast();
  _ControlLeaseState? _controllerLease;
  _ControlLeaseState? _pendingControllerLease;
  Timer? _controllerExpiryTimer;
  int _lastControlEpoch = 0;
  int _lastInputSequence = 0;
  final Set<String> _endedLeaseIds = {};
  final Map<String, int> _endedLeaseEpochs = {};
  bool _grantEpochUncertain = false;
  bool _closing = false;
  bool _closed = false;
  Future<void>? _closeFuture;

  bool get isConnected => _socket.isAuthenticated && !_isClosed && !_closing;
  bool get _isClosed => _closed;
  Future<void> get connected => _socket.authenticated;
  Future<void> get done => _socket.done;
  Stream<TerminalCollaborationHostEvent> get events => _events.stream;
  TerminalControllerLease? get controllerLease {
    final active = _controllerLease;
    final lease = active ?? _pendingControllerLease;
    if (lease == null || !lease.expiresAt.isAfter(service._now().toUtc())) {
      return null;
    }
    return lease.publicLease(isPending: active == null);
  }

  /// Grants one already-approved observer a short-lived input lease. A failed
  /// HTTP response retains the exact pending body and secret so a retry is
  /// idempotent if the server committed before the response was lost.
  Future<TerminalControllerLease> grantController({
    required TerminalShareRecipient controller,
    required DateTime expiresAt,
  }) async {
    _requireConnected();
    if (!allowInput) {
      throw StateError('This terminal collaboration session is read-only.');
    }
    if (_grantEpochUncertain) {
      throw StateError(
        'The last controller grant outcome is unknown; restart the room before granting again.',
      );
    }
    final now = service._now().toUtc();
    final rosterMatch = _observers.where(
      (observer) =>
          observer.recipient.userId == controller.userId &&
          observer.recipient.deviceId == controller.deviceId,
    );
    if (rosterMatch.length != 1 ||
        controller.deviceId == service.identity.deviceId) {
      throw const FormatException(
        'Terminal controller must be an explicitly approved observer device.',
      );
    }
    final approvedRecipient = rosterMatch.single.recipient;
    if (controller.signingPublicKey == null ||
        !_constantTimeBytesEqual(
          controller.encryptionPublicKey,
          approvedRecipient.encryptionPublicKey,
        ) ||
        approvedRecipient.signingPublicKey == null ||
        !_constantTimeBytesEqual(
          controller.signingPublicKey!,
          approvedRecipient.signingPublicKey!,
        )) {
      throw const FormatException(
        'Controller keys do not match the approved observer device.',
      );
    }
    if (!expiresAt.isUtc) {
      throw ArgumentError.value(
        expiresAt,
        'expiresAt',
        'Must be within five minutes and before the session expiry.',
      );
    }
    // The server validates lease expiries as UTC whole-second timestamps.
    // Normalize once at this boundary so the signed keybox, POST body, local
    // timer/state, and exact response check all use the same value.
    final leaseExpiresAt = DateTime.utc(
      expiresAt.year,
      expiresAt.month,
      expiresAt.day,
      expiresAt.hour,
      expiresAt.minute,
      expiresAt.second,
    );
    if (!leaseExpiresAt.isAfter(now) ||
        leaseExpiresAt.isAfter(now.add(const Duration(minutes: 5))) ||
        leaseExpiresAt.isAfter(this.expiresAt)) {
      throw ArgumentError.value(
        expiresAt,
        'expiresAt',
        'Must be within five minutes and before the session expiry.',
      );
    }
    final active = _controllerLease;
    if (active != null && active.expiresAt.isAfter(now)) {
      if (active.controllerUserId == controller.userId &&
          active.controllerDeviceId == controller.deviceId &&
          active.expiresAt.isAtSameMomentAs(leaseExpiresAt)) {
        return active.publicLease();
      }
      throw StateError('A terminal controller lease is already active.');
    }
    if (active != null) _clearControllerLease(active, reason: 'expired');

    var pending = _pendingControllerLease;
    if (pending != null &&
        (pending.controllerUserId != controller.userId ||
            pending.controllerDeviceId != controller.deviceId ||
            !pending.expiresAt.isAtSameMomentAs(leaseExpiresAt))) {
      throw StateError(
        'A previous controller grant is unresolved; retry or revoke it first.',
      );
    }
    if (pending == null) {
      if (controller.signingPublicKey == null) {
        throw const FormatException(
          'Controller device signing key is unavailable.',
        );
      }
      final current = await service._activeVaultDevice(
        controller.userId,
        controller.deviceId,
      );
      final directorySigningKey = current['signing_public_key'];
      if (directorySigningKey is! String ||
          directorySigningKey !=
              encodeBase64Url(approvedRecipient.signingPublicKey!) ||
          current['encryption_public_key'] !=
              encodeBase64Url(approvedRecipient.encryptionPublicKey)) {
        throw const FormatException(
          'Controller device signing key changed; refresh the Vault device list.',
        );
      }
      final leaseId = _uuid.v4();
      final epoch = _lastControlEpoch + 1;
      final context = TerminalControlContext(
        sessionId: sessionId,
        vaultId: service.vaultId,
        membershipVersion: service.membershipVersion,
        hostUserId: service.accountId,
        hostDeviceId: service.identity.deviceId,
        controllerUserId: controller.userId,
        controllerDeviceId: controller.deviceId,
        leaseId: leaseId,
        controlEpoch: epoch,
      );
      final secret = service._crypto.createControlSecret();
      try {
        final keybox = service._crypto.createControlKeybox(
          controlSecret: secret,
          hostIdentity: service.identity,
          controllerEncryptionPublicKey: controller.encryptionPublicKey,
          context: context,
          expiresAt: leaseExpiresAt,
        );
        final body = <String, Object?>{
          'controller_user_id': controller.userId,
          'controller_device_id': controller.deviceId,
          'lease_id': leaseId,
          'control_epoch': epoch,
          'expires_at': leaseExpiresAt.toIso8601String(),
          'keybox': keybox,
        };
        pending = _ControlLeaseState(
          recipient: controller,
          context: context,
          controllerSigningPublicKey: approvedRecipient.signingPublicKey!,
          secret: secret,
          expiresAt: leaseExpiresAt,
          requestBody: body,
        );
        _pendingControllerLease = pending;
        _lastInputSequence = 0;
        _controllerExpiryTimer?.cancel();
        _controllerExpiryTimer = Timer(
          leaseExpiresAt.difference(service._now().toUtc()),
          () => _clearControllerLease(pending!, reason: 'expired'),
        );
      } on Object {
        secret.fillRange(0, secret.length, 0);
        rethrow;
      }
    }

    final response = await service.api.createTerminalControllerLease(
      vaultId: service.vaultId,
      sessionId: sessionId,
      body: pending.requestBody,
    );
    if (response.keys.toSet().length != 3 ||
        !response.keys.toSet().containsAll(const {
          'lease_id',
          'control_epoch',
          'expires_at',
        }) ||
        response['lease_id'] != pending.context.leaseId ||
        response['control_epoch'] != pending.context.controlEpoch ||
        response['expires_at'] != leaseExpiresAt.toIso8601String()) {
      throw const FormatException(
        'Invalid terminal controller lease response.',
      );
    }
    if (!identical(_pendingControllerLease, pending) ||
        pending._secret == null ||
        _endedLeaseIds.contains(pending.context.leaseId) ||
        !pending.expiresAt.isAfter(service._now().toUtc())) {
      throw StateError(
        'Terminal controller lease ended before grant completed.',
      );
    }
    _pendingControllerLease = null;
    _controllerLease = pending;
    _lastControlEpoch = pending.context.controlEpoch;
    _grantEpochUncertain = false;
    _controllerExpiryTimer?.cancel();
    _controllerExpiryTimer = Timer(
      leaseExpiresAt.difference(service._now().toUtc()),
      () => _clearControllerLease(pending!, reason: 'expired'),
    );
    return pending.publicLease();
  }

  /// Revokes the active lease while keeping the host WebSocket and SSH session
  /// alive. Local key material is cleared after the server confirms revoke.
  Future<void> revokeController() async {
    final active = _controllerLease ?? _pendingControllerLease;
    if (!allowInput) {
      throw StateError('This terminal collaboration session is read-only.');
    }
    await service.api.revokeTerminalControllerLease(
      vaultId: service.vaultId,
      sessionId: sessionId,
    );
    if (active != null) {
      _clearControllerLease(active, reason: 'revoked');
    }
  }

  Future<void> _onServerMessage(Map<String, dynamic> message) async {
    if (message['type'] == 'controller_lease_ended') {
      if (!allowInput ||
          message.keys.toSet().length != 3 ||
          !message.keys.toSet().containsAll(const {
            'type',
            'lease_id',
            'reason',
          }) ||
          message['lease_id'] is! String ||
          message['reason'] is! String ||
          !const {
            'revoked',
            'expired',
            'controller_disconnected',
            'observer_disconnected',
          }.contains(message['reason'])) {
        throw const FormatException(
          'Invalid terminal controller lifecycle event.',
        );
      }
      final leaseId = message['lease_id'] as String;
      _requireUuid(leaseId, 'lease_id');
      final current = _controllerLease ?? _pendingControllerLease;
      if (current?.context.leaseId == leaseId) {
        if (current!.context.controlEpoch > _lastControlEpoch) {
          _lastControlEpoch = current.context.controlEpoch;
        }
        _clearControllerLease(
          current,
          reason: message['reason'] as String,
          outcomeKnown: true,
        );
      } else if (!_endedLeaseIds.contains(leaseId)) {
        throw const FormatException('Unknown terminal controller lease ended.');
      } else {
        final endedEpoch = _endedLeaseEpochs[leaseId];
        if (endedEpoch != null && endedEpoch > _lastControlEpoch) {
          _lastControlEpoch = endedEpoch;
          _grantEpochUncertain = false;
        }
      }
      return;
    }
    if (!allowInput ||
        message.keys.toSet().length != 2 ||
        !message.keys.toSet().containsAll(const {'type', 'frame'}) ||
        message['type'] != 'input' ||
        message['frame'] is! Map) {
      throw const FormatException(
        'Unexpected terminal collaboration host message.',
      );
    }
    final lease = _controllerLease ?? _pendingControllerLease;
    if (lease == null || !lease.expiresAt.isAfter(service._now().toUtc())) {
      throw const FormatException('Terminal controller lease is not active.');
    }
    final frame = Map<String, dynamic>.from(message['frame'] as Map);
    final sequence = frame['sequence'];
    if (sequence is! int || sequence != _lastInputSequence + 1) {
      throw const FormatException('Terminal input sequence is invalid.');
    }
    final signingKey = lease.controllerSigningPublicKey;
    final secretCopy = Uint8List.fromList(lease.secret);
    late final Uint8List bytes;
    try {
      bytes = await service._crypto.decryptInputFrame(
        controlSecret: secretCopy,
        controllerSigningPublicKey: signingKey,
        expectedContext: lease.context,
        frame: frame,
        expectedSequence: sequence,
      );
    } finally {
      secretCopy.fillRange(0, secretCopy.length, 0);
    }
    final stillActive = _controllerLease ?? _pendingControllerLease;
    if (!identical(stillActive, lease) ||
        !lease.expiresAt.isAfter(service._now().toUtc())) {
      bytes.fillRange(0, bytes.length, 0);
      return;
    }
    _lastInputSequence = sequence;
    if (!_events.isClosed) {
      _events.add(
        TerminalCollaborationHostEvent.input(
          bytes: bytes,
          leaseId: lease.context.leaseId,
          controlEpoch: lease.context.controlEpoch,
          controllerUserId: lease.context.controllerUserId,
          controllerDeviceId: lease.context.controllerDeviceId,
        ),
      );
    } else {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  /// Publishes raw SSH terminal output in bounded UTF-8 chunks. It has no API
  /// for host terminal input or observer-to-host data.
  Future<void> publishOutput(String output) {
    _requireConnected();
    if (output.isEmpty) return Future<void>.value();
    final encodedBytes = utf8.encode(output).length;
    return _enqueue(encodedBytes, () => _publishOutput(output));
  }

  /// Sends the host's authoritative terminal dimensions to every approved
  /// observer; observers cannot ask the host terminal to resize.
  Future<void> publishResize(int cols, int rows) {
    _requireConnected();
    final plaintext = TerminalCollaborationCrypto.resizePlaintext(
      cols: cols,
      rows: rows,
    );
    final bytes = plaintext.length;
    return _enqueue(bytes, () async {
      try {
        for (final observer in _observers) {
          await _publish(observer, kind: 'resize', plaintext: plaintext);
        }
      } finally {
        plaintext.fillRange(0, plaintext.length, 0);
      }
    });
  }

  Future<void> _publishOutput(String output) async {
    for (final chunk in _splitOutput(output)) {
      try {
        for (final observer in _observers) {
          await _publish(observer, kind: 'output', plaintext: chunk);
        }
      } finally {
        chunk.fillRange(0, chunk.length, 0);
      }
    }
  }

  Future<void> _enqueue(int plaintextBytes, Future<void> Function() work) {
    final estimate = plaintextBytes * _observers.length;
    if (estimate < 0 || estimate > 1024 * 1024 - _queuedBytes) {
      unawaited(_abort());
      return Future<void>.error(
        StateError('Terminal collaboration output queue exceeded its limit.'),
      );
    }
    _queuedBytes += estimate;
    final operation = _sendQueue.then((_) async {
      _requireConnected();
      await work();
    });
    // Keep the serial chain usable after a failed send, but fail the operation
    // returned to its caller and close the room so later frames never reuse a
    // sequence number or follow an uncertain write.
    _sendQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        unawaited(_abort());
      },
    );
    return operation.whenComplete(() {
      _queuedBytes -= estimate;
    });
  }

  Future<void> _abort() async {
    try {
      await close();
    } on Object {
      // The WebSocket close still ends the room if the control-plane DELETE
      // cannot be reached. Do not turn cleanup into an unhandled async error.
    }
  }

  Future<void> _publish(
    _HostObserverContext observer, {
    required String kind,
    required Uint8List plaintext,
  }) async {
    final secret = observer.sessionSecret;
    if (secret == null || !_socket.isAuthenticated) {
      throw StateError('Terminal collaboration session is closed.');
    }
    final sequenceKey = '${observer.recipient.deviceId}/$kind';
    final priorSequence = _sequence[sequenceKey] ?? 0;
    if (priorSequence >= 9007199254740991) {
      await close();
      throw StateError('Terminal collaboration sequence limit reached.');
    }
    final sequence = priorSequence + 1;
    final frame = await service._crypto.encryptFrame(
      sessionSecret: secret,
      hostIdentity: service.identity,
      context: observer.context,
      sequence: sequence,
      kind: kind,
      plaintext: plaintext,
    );
    final message = jsonEncode({'type': 'frame', 'frame': frame});
    if (utf8.encode(message).length > _maxWebSocketMessageBytes) {
      throw StateError('Terminal collaboration frame exceeded the wire limit.');
    }
    _sequence[sequenceKey] = sequence;
    await _socket.send(message);
  }

  Future<void> close() {
    _closing = true;
    return _closeFuture ??= _close();
  }

  Future<void> _close() async {
    // Close the host transport and clear every per-observer key before any
    // control-plane request can block. WebSocket loss itself ends the room.
    _clearSecret();
    _controllerExpiryTimer?.cancel();
    await _socket.close();
    try {
      await service.api
          .stopTerminalCollaborationSession(
            vaultId: service.vaultId,
            sessionId: sessionId,
          )
          .timeout(const Duration(seconds: 3));
    } on Object {
      // The host socket is already closed, which ends the ephemeral room.
    }
  }

  void _onSocketDone() {
    _closing = true;
    _clearSecret();
    _controllerExpiryTimer?.cancel();
    if (!_events.isClosed) unawaited(_events.close());
  }

  void _clearSecret() {
    if (_closed) return;
    _closed = true;
    for (final observer in _observers) {
      observer.clearSecret();
    }
    final lease = _controllerLease;
    if (lease != null) lease.clearSecret();
    final pending = _pendingControllerLease;
    if (pending != null && !identical(pending, lease)) pending.clearSecret();
    _controllerLease = null;
    _pendingControllerLease = null;
    if (!_events.isClosed) unawaited(_events.close());
  }

  void _clearControllerLease(
    _ControlLeaseState lease, {
    required String reason,
    bool outcomeKnown = false,
  }) {
    if (_endedLeaseIds.contains(lease.context.leaseId)) return;
    if (identical(_pendingControllerLease, lease) &&
        reason == 'expired' &&
        !outcomeKnown) {
      _grantEpochUncertain = true;
    }
    if (identical(_controllerLease, lease)) _controllerLease = null;
    if (identical(_pendingControllerLease, lease)) {
      _pendingControllerLease = null;
    }
    _controllerExpiryTimer?.cancel();
    _controllerExpiryTimer = null;
    lease.clearSecret();
    _endedLeaseIds.add(lease.context.leaseId);
    _endedLeaseEpochs[lease.context.leaseId] = lease.context.controlEpoch;
    if (_endedLeaseIds.length > 32) {
      final oldest = _endedLeaseIds.first;
      _endedLeaseIds.remove(oldest);
      _endedLeaseEpochs.remove(oldest);
    }
    if (!_events.isClosed) {
      _events.add(
        TerminalCollaborationHostEvent.controllerEnded(
          leaseId: lease.context.leaseId,
          reason: reason,
        ),
      );
    }
  }

  void _requireConnected() {
    if (!isConnected) {
      throw StateError('Terminal collaboration session is not connected.');
    }
  }

  static Iterable<Uint8List> _splitOutput(String output) sync* {
    if (output.isEmpty) return;
    final current = StringBuffer();
    var byteCount = 0;
    for (final rune in output.runes) {
      final character = String.fromCharCode(rune);
      final characterBytes = utf8.encode(character).length;
      if (byteCount > 0 && byteCount + characterBytes > _maxOutputBytes) {
        yield Uint8List.fromList(utf8.encode(current.toString()));
        current.clear();
        byteCount = 0;
      }
      current.write(character);
      byteCount += characterBytes;
    }
    if (byteCount > 0) {
      yield Uint8List.fromList(utf8.encode(current.toString()));
    }
  }
}

class TerminalShareObserverSession {
  TerminalShareObserverSession._({
    required this.service,
    required this.sessionId,
    required this._socket,
    required this._sessionSecret,
    required this.context,
    required this.roomExpiresAt,
    required this._hostSigningPublicKey,
    required this._crypto,
  });

  final TerminalCollaborationService service;
  final String sessionId;
  final _TerminalCollaborationSocket _socket;
  final TerminalCollaborationContext context;
  final DateTime roomExpiresAt;
  final TerminalCollaborationCrypto _crypto;
  Uint8List? _sessionSecret;
  Uint8List? _hostSigningPublicKey;
  final Map<String, int> _lastSequence = {};
  final StreamController<TerminalCollaborationEvent> _events =
      StreamController<TerminalCollaborationEvent>();
  Future<void>? _closeFuture;
  TerminalControllerLease? _controllerGrant;
  TerminalShareControllerSession? _controllerSession;
  int _lastControllerEpoch = 0;
  final Set<String> _endedControllerLeaseIds = {};

  Stream<TerminalCollaborationEvent> get events => _events.stream;
  bool get isConnected => _socket.isAuthenticated && _sessionSecret != null;
  Future<void> get connected => _socket.authenticated;
  Future<void> get done => _socket.done;
  TerminalControllerLease? get controllerGrant {
    final grant = _controllerGrant;
    if (grant == null ||
        !grant.expiresAt.isAfter(service._now().toUtc()) ||
        !isConnected) {
      return null;
    }
    return grant;
  }

  /// Opens the separate input-only socket for the lease announced to this
  /// already-connected observer. Output continues on [events].
  Future<TerminalShareControllerSession> joinController() async {
    final existing = _controllerSession;
    if (existing != null && existing.isConnected) {
      throw StateError('This device already has an active controller socket.');
    }
    try {
      final controller = await service._joinController(this);
      _controllerSession = controller;
      return controller;
    } on Object {
      _controllerGrant = null;
      rethrow;
    }
  }

  Future<void> _onServerMessage(
    Map<String, dynamic> message, {
    required TerminalCollaborationContext context,
    required Uint8List sessionSecret,
    required Uint8List hostSigningPublicKey,
  }) async {
    if (message['type'] == 'controller_lease_ended') {
      const eventFields = {'type', 'lease_id', 'reason'};
      if (message.keys.toSet().length != eventFields.length ||
          !message.keys.toSet().containsAll(eventFields) ||
          message['lease_id'] is! String ||
          message['reason'] is! String ||
          !const {
            'revoked',
            'expired',
            'controller_disconnected',
            'observer_disconnected',
          }.contains(message['reason'])) {
        throw const FormatException(
          'Invalid terminal controller lifecycle event.',
        );
      }
      final leaseId = message['lease_id'] as String;
      _requireUuid(leaseId, 'lease_id');
      final grant = _controllerGrant;
      if (grant == null || grant.leaseId != leaseId) {
        if (_endedControllerLeaseIds.contains(leaseId)) return;
        throw const FormatException('Unknown terminal controller lease ended.');
      }
      _controllerGrant = null;
      _endedControllerLeaseIds.add(leaseId);
      if (_endedControllerLeaseIds.length > 16) {
        _endedControllerLeaseIds.remove(_endedControllerLeaseIds.first);
      }
      final controller = _controllerSession;
      if (controller?.leaseId == leaseId) {
        _controllerSession = null;
        unawaited(controller!.close());
      }
      if (!_events.isClosed) {
        _events.add(
          TerminalCollaborationEvent.controllerEnded(
            leaseId: leaseId,
            reason: message['reason'] as String,
          ),
        );
      }
      return;
    }
    if (message['type'] == 'controller_lease_granted') {
      const eventFields = {
        'type',
        'session_id',
        'lease_id',
        'control_epoch',
        'expires_at',
      };
      if (message.keys.toSet().length != eventFields.length ||
          !message.keys.toSet().containsAll(eventFields) ||
          message['session_id'] != sessionId ||
          message['lease_id'] is! String ||
          message['control_epoch'] is! int ||
          message['expires_at'] is! String) {
        throw const FormatException('Invalid terminal controller grant event.');
      }
      final leaseId = message['lease_id'] as String;
      final epoch = message['control_epoch'] as int;
      final expiryText = message['expires_at'] as String;
      final expiresAt = DateTime.tryParse(expiryText);
      final now = service._now().toUtc();
      if (!_isCanonicalUuid(leaseId) ||
          epoch < 1 ||
          expiresAt == null ||
          !expiresAt.isUtc ||
          expiresAt.toIso8601String() != expiryText ||
          !expiresAt.isAfter(now) ||
          expiresAt.isAfter(now.add(const Duration(minutes: 5))) ||
          expiresAt.isAfter(roomExpiresAt)) {
        throw const FormatException(
          'Invalid terminal controller grant expiry.',
        );
      }
      final existingGrant = _controllerGrant;
      if (epoch == _lastControllerEpoch &&
          existingGrant?.leaseId == leaseId &&
          existingGrant?.expiresAt.isAtSameMomentAs(expiresAt) == true) {
        return;
      }
      if (epoch <= _lastControllerEpoch) {
        throw const FormatException('Terminal controller epoch is stale.');
      }
      final grant = TerminalControllerLease(
        leaseId: leaseId,
        controlEpoch: epoch,
        expiresAt: expiresAt,
        controllerUserId: context.observerUserId,
        controllerDeviceId: context.observerDeviceId,
      );
      _controllerGrant = grant;
      _lastControllerEpoch = epoch;
      if (!_events.isClosed) {
        _events.add(
          TerminalCollaborationEvent.controllerGranted(
            leaseId: leaseId,
            controlEpoch: epoch,
            expiresAt: expiresAt,
          ),
        );
      }
      return;
    }
    if (message.keys.toSet().length != 2 ||
        !message.keys.toSet().containsAll(const {'type', 'frame'}) ||
        message['type'] != 'frame' ||
        message['frame'] is! Map) {
      throw const FormatException('Unexpected terminal observer message.');
    }
    final frame = Map<String, dynamic>.from(message['frame'] as Map);
    final kind = frame['kind'];
    final sequence = frame['sequence'];
    if ((kind != 'output' && kind != 'resize') ||
        sequence is! int ||
        sequence < 1) {
      throw const FormatException('Invalid terminal collaboration sequence.');
    }
    final previous = _lastSequence[kind as String];
    if (previous != null && sequence != previous + 1) {
      throw const FormatException(
        'Terminal collaboration frame was replayed or dropped.',
      );
    }
    final cleartext = await _crypto.decryptFrame(
      sessionSecret: sessionSecret,
      hostSigningPublicKey: hostSigningPublicKey,
      expectedContext: context,
      frame: frame,
      expectedSequence: sequence,
      expectedKind: kind,
    );
    try {
      final event = switch (kind) {
        'output' => TerminalCollaborationEvent.output(
          utf8.decode(cleartext, allowMalformed: false),
        ),
        'resize' => TerminalCollaborationEvent.resize(
          cols: TerminalCollaborationCrypto.decodeResize(cleartext)['cols']!,
          rows: TerminalCollaborationCrypto.decodeResize(cleartext)['rows']!,
        ),
        _ => throw const FormatException('Unsupported terminal event.'),
      };
      _lastSequence[kind] = sequence;
      if (!_events.isClosed) _events.add(event);
    } finally {
      cleartext.fillRange(0, cleartext.length, 0);
    }
  }

  Future<void> close() => _closeFuture ??= _close();

  void _requireControlJoinReady() {
    if (!isConnected) {
      throw StateError(
        'An active observer connection is required to join terminal control.',
      );
    }
    if (controllerGrant == null) {
      throw StateError('No active controller grant is available.');
    }
  }

  Uint8List _copyHostSigningPublicKey() {
    final key = _hostSigningPublicKey;
    if (key == null || !isConnected) {
      throw StateError('The observer host trust context is unavailable.');
    }
    return Uint8List.fromList(key);
  }

  Future<void> _close() async {
    _clearSecret();
    await _socket.close();
    if (!_events.isClosed) await _events.close();
  }

  void _onSocketDone() {
    _clearSecret();
    if (!_events.isClosed) unawaited(_events.close());
  }

  void _clearSecret() {
    final secret = _sessionSecret;
    if (secret != null) secret.fillRange(0, secret.length, 0);
    _sessionSecret = null;
    final hostKey = _hostSigningPublicKey;
    if (hostKey != null) hostKey.fillRange(0, hostKey.length, 0);
    _hostSigningPublicKey = null;
    _controllerGrant = null;
    final controller = _controllerSession;
    _controllerSession = null;
    if (controller != null) unawaited(controller.close());
  }
}

/// A separate, input-only controller connection. The existing observer handle
/// continues to receive the host's encrypted output stream.
class TerminalShareControllerSession {
  TerminalShareControllerSession._({
    required this.service,
    required this.sessionId,
    required this.context,
    required this._socket,
    required this._controlSecret,
    required this.expiresAt,
  }) {
    _expiryTimer = Timer(
      expiresAt.difference(service._now().toUtc()),
      () => unawaited(close()),
    );
  }

  final TerminalCollaborationService service;
  final String sessionId;
  final TerminalControlContext context;
  final _TerminalCollaborationSocket _socket;
  final DateTime expiresAt;
  Uint8List? _controlSecret;
  Timer? _expiryTimer;
  Future<void> _sendQueue = Future<void>.value();
  final Stopwatch _rateClock = Stopwatch()..start();
  final List<_RecentControllerFrame> _recentFrames = <_RecentControllerFrame>[];
  final Completer<void> _closedSignal = Completer<void>();
  int _recentFrameBytes = 0;
  int _queuedInputBytes = 0;
  int _sequence = 0;
  Future<void>? _closeFuture;

  String get leaseId => context.leaseId;
  int get controlEpoch => context.controlEpoch;
  bool get isConnected =>
      _socket.isAuthenticated &&
      _controlSecret != null &&
      expiresAt.isAfter(service._now().toUtc());
  Future<void> get connected => _socket.authenticated;
  Future<void> get done => _socket.done;

  /// Encrypts and signs raw terminal input. Writes are serialized so a caller
  /// cannot race sequence assignment or send across an uncertain write. Raw
  /// input is deliberately limited to one protocol frame; callers that have a
  /// text paste should use [sendInputText]. Invalid input is reported through
  /// the returned Future, never by a synchronous throw.
  Future<void> sendInput(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > _maxInputBytes) {
      return Future<void>.error(ArgumentError.value(bytes.length, 'bytes'));
    }
    return _queueInputChunks(<Uint8List>[Uint8List.fromList(bytes)]);
  }

  /// Splits terminal text on Unicode codepoint boundaries into frames of at
  /// most 8 KiB, preserving the paste's byte order and frame sequence. A whole
  /// paste occupies one queue entry so concurrent keyboard events cannot
  /// interleave frames in the middle of it. The one MiB cap bounds memory and
  /// pending work; excess input fails closed without partially sending it.
  Future<void> sendInputText(String text) {
    if (text.isEmpty) return Future<void>.value();
    final chunks = _splitControllerInputText(text);
    if (chunks == null) {
      return Future<void>.error(
        ArgumentError.value(
          text.length,
          'text',
          'Terminal paste exceeds the 1 MiB limit.',
        ),
      );
    }
    return _queueInputChunks(chunks);
  }

  Future<void> _queueInputChunks(List<Uint8List> chunks) {
    final totalBytes = chunks.fold<int>(
      0,
      (total, chunk) => total + chunk.length,
    );
    if (totalBytes <= 0 ||
        totalBytes > _maxQueuedControllerInputBytes - _queuedInputBytes) {
      for (final chunk in chunks) {
        chunk.fillRange(0, chunk.length, 0);
      }
      return Future<void>.error(
        ArgumentError.value(
          totalBytes,
          'bytes',
          'Queued terminal input exceeds the 1 MiB limit.',
        ),
      );
    }
    _queuedInputBytes += totalBytes;
    final operation = _sendQueue.then((_) async {
      try {
        for (final chunk in chunks) {
          _requireConnected();
          await _waitForRateCapacity(chunk.length + 16);
          await _sendInputFrame(chunk);
        }
      } finally {
        for (final chunk in chunks) {
          chunk.fillRange(0, chunk.length, 0);
        }
        _queuedInputBytes -= totalBytes;
      }
    });
    _sendQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        unawaited(close());
      },
    );
    return operation;
  }

  Future<void> _sendInputFrame(Uint8List plaintext) async {
    _requireConnected();
    if (_sequence >= 9007199254740991) {
      throw StateError('Terminal controller sequence limit reached.');
    }
    final storedSecret = _controlSecret;
    if (storedSecret == null) {
      throw StateError('Terminal controller session is not connected.');
    }
    final secret = Uint8List.fromList(storedSecret);
    final sequence = _sequence + 1;
    try {
      final frame = await service._crypto.encryptInputFrame(
        controlSecret: secret,
        controllerIdentity: service.identity,
        context: context,
        sequence: sequence,
        plaintext: plaintext,
      );
      _requireConnected();
      final message = jsonEncode({'type': 'input', 'frame': frame});
      if (utf8.encode(message).length > _maxWebSocketMessageBytes) {
        throw StateError('Terminal input frame exceeded the wire limit.');
      }
      await _socket.send(message);
      _sequence = sequence;
      _recordControllerFrame(plaintext.length + 16);
    } finally {
      secret.fillRange(0, secret.length, 0);
    }
  }

  Future<void> _waitForRateCapacity(int ciphertextBytes) async {
    while (true) {
      _requireConnected();
      final now = _rateClock.elapsed;
      _recentFrames.removeWhere((frame) {
        if (now - frame.sentAt < _controllerRateWindow) return false;
        _recentFrameBytes -= frame.ciphertextBytes;
        return true;
      });
      if (_recentFrames.length < _maxControllerFramesPerSecond &&
          _recentFrameBytes + ciphertextBytes <= _maxControllerBytesPerSecond) {
        return;
      }
      final oldest = _recentFrames.first;
      final wait = oldest.sentAt + _controllerRateWindow - now;
      final closed = await Future.any<bool>(<Future<bool>>[
        Future<void>.delayed(wait).then((_) => false),
        _closedSignal.future.then((_) => true),
      ]);
      if (closed) _requireConnected();
    }
  }

  void _recordControllerFrame(int ciphertextBytes) {
    _recentFrames.add(
      _RecentControllerFrame(_rateClock.elapsed, ciphertextBytes),
    );
    _recentFrameBytes += ciphertextBytes;
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _clearSecret();
    await _socket.close();
  }

  void _onSocketDone() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _clearSecret();
  }

  void _clearSecret() {
    if (!_closedSignal.isCompleted) _closedSignal.complete();
    final secret = _controlSecret;
    if (secret != null) secret.fillRange(0, secret.length, 0);
    _controlSecret = null;
  }

  void _requireConnected() {
    if (!isConnected) {
      throw StateError('Terminal controller session is not connected.');
    }
  }
}

List<Uint8List>? _splitControllerInputText(String text) {
  final chunks = <Uint8List>[];
  final current = Uint8List(_maxInputBytes);
  var currentLength = 0;
  var totalLength = 0;
  for (final rune in text.runes) {
    final encodedRune = Uint8List.fromList(
      utf8.encode(String.fromCharCode(rune)),
    );
    if (totalLength + encodedRune.length > _maxQueuedControllerInputBytes) {
      encodedRune.fillRange(0, encodedRune.length, 0);
      current.fillRange(0, current.length, 0);
      for (final chunk in chunks) {
        chunk.fillRange(0, chunk.length, 0);
      }
      return null;
    }
    if (currentLength + encodedRune.length > current.length) {
      chunks.add(Uint8List.fromList(current.sublist(0, currentLength)));
      current.fillRange(0, current.length, 0);
      currentLength = 0;
    }
    current.setRange(
      currentLength,
      currentLength + encodedRune.length,
      encodedRune,
    );
    currentLength += encodedRune.length;
    totalLength += encodedRune.length;
    encodedRune.fillRange(0, encodedRune.length, 0);
  }
  if (currentLength > 0) {
    chunks.add(Uint8List.fromList(current.sublist(0, currentLength)));
  }
  current.fillRange(0, current.length, 0);
  return chunks;
}

class _RecentControllerFrame {
  const _RecentControllerFrame(this.sentAt, this.ciphertextBytes);

  final Duration sentAt;
  final int ciphertextBytes;
}

class _HostObserverContext {
  _HostObserverContext(this.recipient, this.context, Uint8List sessionSecret)
    : _sessionSecret = sessionSecret;

  final TerminalShareRecipient recipient;
  final TerminalCollaborationContext context;
  Uint8List? _sessionSecret;

  Uint8List? get sessionSecret => _sessionSecret;

  void clearSecret() {
    final secret = _sessionSecret;
    if (secret != null) secret.fillRange(0, secret.length, 0);
    _sessionSecret = null;
  }
}

class _ControlLeaseState {
  _ControlLeaseState({
    required this.recipient,
    required this.context,
    required Uint8List controllerSigningPublicKey,
    required this._secret,
    required this.expiresAt,
    required this.requestBody,
  }) : _controllerSigningPublicKey = Uint8List.fromList(
         controllerSigningPublicKey,
       );

  final TerminalShareRecipient recipient;
  final TerminalControlContext context;
  Uint8List? _secret;
  final Uint8List _controllerSigningPublicKey;
  final DateTime expiresAt;
  final Map<String, Object?> requestBody;

  String get controllerUserId => context.controllerUserId;
  String get controllerDeviceId => context.controllerDeviceId;
  Uint8List get controllerSigningPublicKey => _controllerSigningPublicKey;
  Uint8List get secret =>
      _secret ?? (throw StateError('Terminal controller lease is closed.'));
  TerminalControllerLease publicLease({bool isPending = false}) =>
      TerminalControllerLease(
        leaseId: context.leaseId,
        controlEpoch: context.controlEpoch,
        expiresAt: expiresAt,
        controllerUserId: controllerUserId,
        controllerDeviceId: controllerDeviceId,
        isPending: isPending,
      );

  void clearSecret() {
    final secret = _secret;
    if (secret != null) secret.fillRange(0, secret.length, 0);
    _secret = null;
    _controllerSigningPublicKey.fillRange(
      0,
      _controllerSigningPublicKey.length,
      0,
    );
  }
}

class _TerminalCollaborationTicket {
  const _TerminalCollaborationTicket({
    required this.ticket,
    required this.connectPath,
    required this.expiresAt,
    required this.role,
  });

  final String ticket;
  final String connectPath;
  final DateTime expiresAt;
  final String role;
}

class _TerminalCollaborationSocket {
  _TerminalCollaborationSocket({
    required this.channel,
    required this.sessionId,
    required this.role,
    this.expectedLeaseId,
    this.expectedControlEpoch,
    required this.bufferedAmount,
    required this.uplinkWaitTimeout,
    required this.onMessage,
    required this.onDone,
  });

  final WebSocketChannel channel;
  final String sessionId;
  final String role;
  final String? expectedLeaseId;
  final int? expectedControlEpoch;
  final int? Function() bufferedAmount;
  final Duration uplinkWaitTimeout;
  final Future<void> Function(Map<String, dynamic>) onMessage;
  final void Function() onDone;
  final Completer<void> _authenticated = Completer<void>();
  final Completer<void> _done = Completer<void>();
  bool _isAuthenticated = false;
  bool _closing = false;
  Future<void>? _closeFuture;

  bool get isAuthenticated => _isAuthenticated && !_closing;
  Future<void> get authenticated => _authenticated.future;
  Future<void> get done => _done.future;

  Future<void> authenticate(String ticket) async {
    _validateTicket(ticket);
    try {
      await channel.ready.timeout(_handshakeTimeout);
      // Attach the reader before sending the one-use ticket so a fast server
      // acknowledgement cannot race subscription setup.
      unawaited(_readMessages());
      channel.sink.add(jsonEncode({'type': 'authenticate', 'ticket': ticket}));
      await _authenticated.future.timeout(_handshakeTimeout);
      // An acknowledgement and EOF can already be queued in the same socket
      // turn. Give the reader one event-loop turn to observe that EOF before
      // returning a session that appears authenticated but is already dead.
      await Future<void>.delayed(Duration.zero);
      if (!isAuthenticated || _done.isCompleted) {
        throw StateError(
          'Terminal collaboration socket closed immediately after authentication.',
        );
      }
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> send(String text) async {
    final messageBytes = utf8.encode(text).length;
    if (!isAuthenticated || messageBytes > _maxWebSocketMessageBytes) {
      throw StateError('Terminal collaboration socket is not writable.');
    }

    var queuedBytes = bufferedAmount();
    // Native platforms do not expose WebSocket bufferedAmount. The default
    // conditional implementation returns null there, preserving their
    // existing WebSocketChannel send path.
    if (queuedBytes == null) {
      channel.sink.add(text);
      return;
    }

    final wait = Stopwatch()..start();
    while (true) {
      if (!isAuthenticated) {
        throw StateError('Terminal collaboration socket is not writable.');
      }
      if (queuedBytes == null) {
        throw StateError(
          'Terminal collaboration uplink buffer is unavailable.',
        );
      }
      if (queuedBytes < 0) {
        throw StateError('Terminal collaboration uplink buffer is invalid.');
      }
      if (queuedBytes <= _maxWebSocketBufferedBytes - messageBytes) break;
      final remaining = uplinkWaitTimeout - wait.elapsed;
      if (remaining <= Duration.zero) {
        throw StateError(
          'Terminal collaboration uplink remained backpressured.',
        );
      }
      await Future<void>.delayed(
        remaining < _webSocketBufferPollInterval
            ? remaining
            : _webSocketBufferPollInterval,
      );
      queuedBytes = bufferedAmount();
      if (queuedBytes == null) {
        // Once a measurable browser channel becomes unavailable, fail closed
        // instead of silently reverting to an unbounded write path.
        throw StateError(
          'Terminal collaboration uplink buffer is unavailable.',
        );
      }
    }
    if (!isAuthenticated) {
      throw StateError('Terminal collaboration socket is not writable.');
    }
    channel.sink.add(text);
  }

  Future<void> _readMessages() async {
    try {
      await for (final raw in channel.stream) {
        if (raw is! String ||
            utf8.encode(raw).length > _maxWebSocketMessageBytes) {
          throw const FormatException(
            'Invalid terminal collaboration message.',
          );
        }
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException(
            'Invalid terminal collaboration message.',
          );
        }
        if (!_isAuthenticated) {
          final expectedFields = role == 'controller'
              ? const {
                  'type',
                  'role',
                  'session_id',
                  'lease_id',
                  'control_epoch',
                }
              : const {'type', 'role', 'session_id'};
          if (decoded.keys.toSet().length != expectedFields.length ||
              !decoded.keys.toSet().containsAll(expectedFields) ||
              decoded['type'] != 'authenticated' ||
              decoded['role'] != role ||
              decoded['session_id'] != sessionId ||
              (role == 'controller' &&
                  (expectedLeaseId == null ||
                      expectedControlEpoch == null ||
                      decoded['lease_id'] != expectedLeaseId ||
                      decoded['control_epoch'] != expectedControlEpoch))) {
            throw const FormatException(
              'Terminal collaboration authentication acknowledgement is invalid.',
            );
          }
          _isAuthenticated = true;
          if (!_authenticated.isCompleted) _authenticated.complete();
          continue;
        }
        await onMessage(decoded);
      }
      if (!_closing) {
        throw const FormatException('Terminal collaboration socket closed.');
      }
    } on Object catch (error, stackTrace) {
      if (!_authenticated.isCompleted) {
        _authenticated.completeError(error, stackTrace);
      }
      if (!_closing) {
        _closing = true;
        try {
          await channel.sink.close(1002, 'Invalid collaboration message');
        } on Object {
          // The remote may already have closed the socket.
        }
      }
    } finally {
      _isAuthenticated = false;
      onDone();
      if (!_done.isCompleted) _done.complete();
    }
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closing) {
      await _done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
      return;
    }
    _closing = true;
    _isAuthenticated = false;
    if (!_authenticated.isCompleted) {
      _authenticated.completeError(
        StateError(
          'Terminal collaboration socket closed before authentication.',
        ),
      );
    }
    try {
      await channel.sink
          .close(1000, 'Collaboration session closed')
          .timeout(const Duration(seconds: 2));
    } on Object {
      // Close is best effort, and secret clearing does not depend on a peer.
    }
    if (!_done.isCompleted) _done.complete();
  }
}

void _validateTicket(String ticket) {
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(ticket)) {
    throw const FormatException('Invalid terminal collaboration ticket.');
  }
  final bytes = _canonicalBytes(ticket, expectedBytes: 32);
  bytes.fillRange(0, bytes.length, 0);
}

Uint8List _canonicalBytes(String value, {required int expectedBytes}) {
  try {
    final bytes = decodeBase64Url(value);
    if (bytes.length != expectedBytes || encodeBase64Url(bytes) != value) {
      bytes.fillRange(0, bytes.length, 0);
      throw const FormatException('Invalid terminal collaboration encoding.');
    }
    return bytes;
  } on FormatException {
    rethrow;
  } on Object {
    throw const FormatException('Invalid terminal collaboration encoding.');
  }
}

void _requireUuid(String value, String field) {
  if (!RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  ).hasMatch(value)) {
    throw FormatException('Invalid terminal collaboration $field.');
  }
}

bool _isCanonicalUuid(String value) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
).hasMatch(value);

bool _isServerUtcWholeSecondTimestamp(String text, DateTime parsed) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+00:00$').hasMatch(text) ||
      !parsed.isUtc ||
      parsed.millisecond != 0 ||
      parsed.microsecond != 0) {
    return false;
  }
  final canonical =
      '${parsed.year.toString().padLeft(4, '0')}-'
      '${parsed.month.toString().padLeft(2, '0')}-'
      '${parsed.day.toString().padLeft(2, '0')}T'
      '${parsed.hour.toString().padLeft(2, '0')}:'
      '${parsed.minute.toString().padLeft(2, '0')}:'
      '${parsed.second.toString().padLeft(2, '0')}+00:00';
  return text == canonical;
}

bool _constantTimeBytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}
