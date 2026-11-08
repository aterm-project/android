import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/terminal/terminal_collaboration_crypto.dart';
import 'package:aterm_client/terminal/terminal_collaboration_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _hostUserId = '11111111-1111-4111-8111-111111111111';
const _observerUserId = '22222222-2222-4222-8222-222222222222';
const _vaultId = '33333333-3333-4333-8333-333333333333';
const _sessionId = '44444444-4444-4444-8444-444444444444';

void main() {
  late SodiumSumo sodium;
  late VaultCrypto vaultCrypto;
  late TerminalCollaborationCrypto collaborationCrypto;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    vaultCrypto = VaultCrypto(sodium);
    collaborationCrypto = TerminalCollaborationCrypto(sodium);
  });

  test(
    'host room sequences bounded frames and closes on stalled Web uplink',
    () async {
      final host = DeviceIdentity.create(sodium);
      final observer = DeviceIdentity.create(sodium);
      final observer2 = DeviceIdentity.create(sodium);
      const hostDeviceId = '55555555-5555-4555-8555-555555555555';
      const observerDeviceId = '66666666-6666-4666-8666-666666666666';
      const observer2DeviceId = '77777777-7777-4777-8777-777777777777';
      // The identities created by Sodium carry their own random IDs; use these
      // IDs in directory fixtures and the service caller exactly.
      final actualHost = DeviceIdentity(
        deviceId: hostDeviceId,
        signing: host.signing,
        encryption: host.encryption,
      );
      final actualObserver = DeviceIdentity(
        deviceId: observerDeviceId,
        signing: observer.signing,
        encryption: observer.encryption,
      );
      final actualObserver2 = DeviceIdentity(
        deviceId: observer2DeviceId,
        signing: observer2.signing,
        encryption: observer2.encryption,
      );
      const testMaxBufferedBytes = 128 * 1024;
      var simulateSlowUplink = false;
      var forceBlockedUplink = false;
      var simulatedBufferedBytes = 0;
      var highWaterPollCount = 0;
      var slowUplinkWaitCount = 0;
      var maximumObservedBufferedBytes = 0;
      final socket = _TestWebSocketChannel(
        onFrameSent: (message) {
          if (!simulateSlowUplink) return;
          simulatedBufferedBytes += utf8.encode(message).length;
          if (simulatedBufferedBytes > maximumObservedBufferedBytes) {
            maximumObservedBufferedBytes = simulatedBufferedBytes;
          }
        },
      );
      final observedBodies = <Map<String, dynamic>>[];
      final openedObserverSecrets = <Uint8List>[];
      var stopRequests = 0;
      final api = ApiClient(
        baseUrl: 'https://terminal.example.test/proxy/root',
        client: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer active-token');
          if (request.method == 'GET') {
            expect(
              request.url.path,
              '/proxy/root/api/v1/vaults/$_vaultId/devices',
            );
            return http.Response(
              jsonEncode({
                'devices': [
                  {
                    'user_id': _observerUserId,
                    'device_id': actualObserver.deviceId,
                    'encryption_public_key': actualObserver.encryptionPublicKey,
                    'status': 'active',
                    'membership_status': 'active',
                  },
                  {
                    'user_id': _hostUserId,
                    'device_id': actualObserver2.deviceId,
                    'encryption_public_key':
                        actualObserver2.encryptionPublicKey,
                    'status': 'active',
                    'membership_status': 'active',
                  },
                ],
              }),
              200,
            );
          }
          if (request.method == 'POST') {
            expect(
              request.url.path,
              '/proxy/root/api/v1/vaults/$_vaultId/terminal-sessions',
            );
            final body = Map<String, dynamic>.from(
              jsonDecode(request.body) as Map,
            );
            observedBodies.add(body);
            expect(body.keys.toSet(), {
              'protocol_version',
              'session_id',
              'expires_at',
              'observers',
            });
            expect(body['protocol_version'], 1);
            expect(body['session_id'], _sessionId);
            final grants = (body['observers'] as List).cast<Map>();
            expect(grants, hasLength(2));
            final targets = [actualObserver, actualObserver2];
            for (var index = 0; index < grants.length; index++) {
              final grant = grants[index];
              final target = targets[index];
              final observerUserId = index == 0 ? _observerUserId : _hostUserId;
              expect(grant['user_id'], observerUserId);
              expect(grant['device_id'], target.deviceId);
              final context = TerminalCollaborationContext(
                sessionId: _sessionId,
                vaultId: _vaultId,
                membershipVersion: 3,
                hostUserId: _hostUserId,
                hostDeviceId: actualHost.deviceId,
                observerUserId: observerUserId,
                observerDeviceId: target.deviceId,
              );
              final openedSecret = collaborationCrypto.openKeybox(
                keybox: Map<String, dynamic>.from(grant['keybox'] as Map),
                observerIdentity: target,
                hostSigningPublicKey: actualHost.signing.publicKey,
                expectedContext: context,
                now: DateTime.now().toUtc(),
              );
              openedObserverSecrets.add(openedSecret);
              expect(
                request.body,
                isNot(contains(encodeBase64Url(openedSecret))),
              );
            }
            expect(openedObserverSecrets[0], isNot(openedObserverSecrets[1]));
            return http.Response(
              jsonEncode({
                'session_id': _sessionId,
                'expires_at': body['expires_at'],
                'host_ticket': _ticket(),
                'connect_path': '/collaboration/v1/connect',
              }),
              200,
            );
          }
          stopRequests++;
          expect(request.method, 'DELETE');
          expect(
            request.url.path,
            '/proxy/root/api/v1/vaults/$_vaultId/terminal-sessions/$_sessionId',
          );
          return http.Response('{}', 200);
        }),
      )..accessToken = 'active-token';
      final service = TerminalCollaborationService(
        api: api,
        crypto: vaultCrypto,
        identity: actualHost,
        accountId: _hostUserId,
        vaultId: _vaultId,
        membershipVersion: 3,
        bufferedAmountProvider: (_) {
          if (!simulateSlowUplink) return null;
          if (!forceBlockedUplink &&
              simulatedBufferedBytes > testMaxBufferedBytes - 32 * 1024) {
            highWaterPollCount++;
            if (highWaterPollCount >= 2) {
              // Simulate a slow browser uplink that makes progress only after
              // the host has waited through multiple high-water samples.
              simulatedBufferedBytes = 0;
              highWaterPollCount = 0;
              slowUplinkWaitCount++;
            }
          }
          return simulatedBufferedBytes;
        },
        uplinkWaitTimeout: const Duration(milliseconds: 150),
        channelFactory: (uri) {
          expect(
            uri.toString(),
            'wss://terminal.example.test/proxy/root/collaboration/v1/connect',
          );
          socket.role = 'host';
          return socket;
        },
      );
      try {
        final recipient = TerminalShareRecipient.fromVaultDevice({
          'user_id': _observerUserId,
          'device_id': actualObserver.deviceId,
          'encryption_public_key': actualObserver.encryptionPublicKey,
          'status': 'active',
          'membership_status': 'active',
        });
        final recipient2 = TerminalShareRecipient.fromVaultDevice({
          'user_id': _hostUserId,
          'device_id': actualObserver2.deviceId,
          'encryption_public_key': actualObserver2.encryptionPublicKey,
          'status': 'active',
          'membership_status': 'active',
        });
        final hostSession = await service.startHost(
          sessionId: _sessionId,
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
          observers: [recipient, recipient2],
        );
        expect(socket.sent.first, {
          'type': 'authenticate',
          'ticket': _ticket(),
        });
        expect(hostSession.isConnected, isTrue);

        final first = hostSession.publishOutput('first');
        final second = hostSession.publishOutput('second');
        await Future.wait([first, second]);
        await hostSession.publishResize(160, 48);

        final frames = socket.sent
            .whereType<Map<String, dynamic>>()
            .where((value) => value['type'] == 'frame')
            .map((value) => Map<String, dynamic>.from(value['frame'] as Map))
            .toList();
        expect(frames.map((frame) => frame['sequence']).toList(), [
          1,
          1,
          2,
          2,
          1,
          1,
        ]);
        expect(frames.map((frame) => frame['kind']).toList(), [
          'output',
          'output',
          'output',
          'output',
          'resize',
          'resize',
        ]);
        expect(frames.first['recipient_user_id'], _observerUserId);
        expect(frames.first['recipient_device_id'], actualObserver.deviceId);
        expect(jsonEncode(frames.first), isNot(contains('first')));

        final longOutput = 'x' * (16 * 1024 + 1);
        await hostSession.publishOutput(longOutput);
        final outputFrames = socket.sent
            .whereType<Map<String, dynamic>>()
            .where((value) => value['type'] == 'frame')
            .map((value) => Map<String, dynamic>.from(value['frame'] as Map))
            .where((frame) => frame['kind'] == 'output')
            .toList();
        expect(outputFrames.length, 8);
        expect(outputFrames.map((frame) => frame['sequence']).toList(), [
          1,
          1,
          2,
          2,
          3,
          3,
          4,
          4,
        ]);
        expect(
          decodeBase64Url(outputFrames[4]['ciphertext']! as String),
          hasLength(16 * 1024 + 16),
        );
        expect(
          decodeBase64Url(outputFrames[5]['ciphertext']! as String),
          hasLength(16 * 1024 + 16),
        );
        expect(
          decodeBase64Url(outputFrames[6]['ciphertext']! as String),
          hasLength(17),
        );
        expect(
          decodeBase64Url(outputFrames[7]['ciphertext']! as String),
          hasLength(17),
        );
        expect(observedBodies.single['observers'], hasLength(2));

        simulateSlowUplink = true;
        await hostSession.publishOutput('s' * (7 * 16 * 1024 + 1));
        expect(
          maximumObservedBufferedBytes,
          lessThanOrEqualTo(testMaxBufferedBytes),
        );
        expect(slowUplinkWaitCount, greaterThan(0));

        forceBlockedUplink = true;
        simulatedBufferedBytes = testMaxBufferedBytes;
        await expectLater(
          hostSession.publishOutput('blocked uplink'),
          throwsA(isA<StateError>()),
        );
        // Await the same close started by the send-queue error path. It clears
        // the collaboration keys and deletes the ephemeral room while leaving
        // the SSH session outside this service untouched.
        await hostSession.close();
        expect(hostSession.isConnected, isFalse);
        expect(stopRequests, 1);
        expect(socket.sink.closeCode, 1000);
      } finally {
        api.close();
        for (final secret in openedObserverSecrets) {
          secret.fillRange(0, secret.length, 0);
        }
        actualHost.dispose();
        actualObserver.dispose();
        actualObserver2.dispose();
      }
    },
  );

  test(
    'observer opens keybox and renders only signed, ordered frames',
    () async {
      final hostIdentity = DeviceIdentity.create(sodium);
      final observerIdentity = DeviceIdentity.create(sodium);
      final secret = collaborationCrypto.createSessionSecret();
      final now = DateTime.now().toUtc();
      final expiry = now.add(const Duration(minutes: 5));
      const leaseId = 'abababab-abab-4bab-8bab-abababababab';
      final controlExpiry = now.add(const Duration(minutes: 3));
      final controlSecret = collaborationCrypto.createControlSecret();
      final controlContext = TerminalControlContext(
        sessionId: _sessionId,
        vaultId: _vaultId,
        membershipVersion: 3,
        hostUserId: _hostUserId,
        hostDeviceId: hostIdentity.deviceId,
        controllerUserId: _observerUserId,
        controllerDeviceId: observerIdentity.deviceId,
        leaseId: leaseId,
        controlEpoch: 1,
      );
      final controlKeybox = collaborationCrypto.createControlKeybox(
        controlSecret: controlSecret,
        hostIdentity: hostIdentity,
        controllerEncryptionPublicKey: observerIdentity.encryption.publicKey,
        context: controlContext,
        expiresAt: controlExpiry,
      );
      final context = TerminalCollaborationContext(
        sessionId: _sessionId,
        vaultId: _vaultId,
        membershipVersion: 3,
        hostUserId: _hostUserId,
        hostDeviceId: hostIdentity.deviceId,
        observerUserId: _observerUserId,
        observerDeviceId: observerIdentity.deviceId,
      );
      final keybox = collaborationCrypto.createKeybox(
        sessionSecret: secret,
        hostIdentity: hostIdentity,
        observerEncryptionPublicKey: observerIdentity.encryption.publicKey,
        context: context,
        expiresAt: expiry,
      );
      final socket = _TestWebSocketChannel()..role = 'observer';
      final controllerSocket = _TestWebSocketChannel()
        ..role = 'controller'
        ..leaseId = leaseId
        ..controlEpoch = 1;
      final api = ApiClient(
        baseUrl: 'https://terminal.example.test',
        client: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer observer-token');
          if (request.method == 'POST' &&
              request.url.path.endsWith('/controller-lease/ticket')) {
            expect(request.body, isEmpty);
            return http.Response(
              jsonEncode({
                'ticket': _ticket(),
                'role': 'controller',
                'lease_id': leaseId,
                'control_epoch': 1,
                'control_keybox': controlKeybox,
                'ticket_expires_at': _serverUtcWholeSecondExpiry(
                  DateTime.now().toUtc().add(const Duration(seconds: 20)),
                ),
                'connect_path': '/collaboration/v1/connect',
              }),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/ticket')) {
            expect(request.body, isEmpty);
            return http.Response(
              jsonEncode({
                'ticket': _ticket(),
                'role': 'observer',
                'keybox': keybox,
                'ticket_expires_at': DateTime.now()
                    .toUtc()
                    .add(const Duration(seconds: 20))
                    .toIso8601String(),
                'connect_path': '/collaboration/v1/connect',
              }),
              200,
            );
          }
          expect(request.method, 'GET');
          return http.Response(
            jsonEncode({
              'devices': [
                {
                  'user_id': _hostUserId,
                  'device_id': hostIdentity.deviceId,
                  'signing_public_key': hostIdentity.signingPublicKey,
                  'status': 'active',
                  'membership_status': 'active',
                },
              ],
            }),
            200,
          );
        }),
      )..accessToken = 'observer-token';
      var channelCount = 0;
      final service = TerminalCollaborationService(
        api: api,
        crypto: vaultCrypto,
        identity: observerIdentity,
        accountId: _observerUserId,
        vaultId: _vaultId,
        membershipVersion: 3,
        channelFactory: (_) => channelCount++ == 0 ? socket : controllerSocket,
        now: () => now,
      );
      Uint8List? inputCleartext;
      try {
        final observer = await service.joinObserver(sessionId: _sessionId);
        expect(observer.isConnected, isTrue);
        final output = Uint8List.fromList(utf8.encode('verified output\r\n'));
        final frame = await collaborationCrypto.encryptFrame(
          sessionSecret: secret,
          hostIdentity: hostIdentity,
          context: context,
          sequence: 9,
          kind: 'output',
          plaintext: output,
        );
        final observerEvents = StreamIterator(observer.events);
        socket.receive({'type': 'frame', 'frame': frame});
        expect(await observerEvents.moveNext(), isTrue);
        expect(observerEvents.current.output, 'verified output\r\n');

        socket.receive({
          'type': 'controller_lease_granted',
          'session_id': _sessionId,
          'lease_id': leaseId,
          'control_epoch': 1,
          'expires_at': controlExpiry.toIso8601String(),
        });
        expect(await observerEvents.moveNext(), isTrue);
        final grantEvent = observerEvents.current;
        expect(grantEvent.leaseId, leaseId);
        expect(observer.controllerGrant?.controlEpoch, 1);

        final controller = await observer.joinController();
        expect(controller.isConnected, isTrue);
        final controllerInput = Uint8List.fromList([0x03, 0x78, 0x0d]);
        await controller.sendInput(controllerInput);
        final sentInput = controllerSocket.sent.whereType<Map>().firstWhere(
          (message) => message['type'] == 'input',
        );
        final encryptedFrame = Map<String, dynamic>.from(
          sentInput['frame'] as Map,
        );
        inputCleartext = await collaborationCrypto.decryptInputFrame(
          controlSecret: controlSecret,
          controllerSigningPublicKey: observerIdentity.signing.publicKey,
          expectedContext: controlContext,
          frame: encryptedFrame,
          expectedSequence: 1,
        );
        expect(inputCleartext, controllerInput);
        inputCleartext.fillRange(0, inputCleartext.length, 0);
        inputCleartext = null;

        // Put a four-byte codepoint immediately after the first frame's last
        // available ASCII byte. The split must preserve UTF-8 bytes and use
        // one sequence number per bounded frame.
        final paste = '${List<String>.filled(8191, 'a').join()}🙂z';
        await controller.sendInputText(paste);
        final inputMessages = controllerSocket.sent
            .whereType<Map>()
            .where((message) => message['type'] == 'input')
            .toList();
        expect(inputMessages, hasLength(3));
        final pastedBytes = <int>[];
        final pastedFrameLengths = <int>[];
        for (var index = 1; index < inputMessages.length; index++) {
          final inputMessage = Map<String, dynamic>.from(inputMessages[index]);
          final frame = Map<String, dynamic>.from(inputMessage['frame'] as Map);
          final cleartext = await collaborationCrypto.decryptInputFrame(
            controlSecret: controlSecret,
            controllerSigningPublicKey: observerIdentity.signing.publicKey,
            expectedContext: controlContext,
            frame: frame,
            expectedSequence: index + 1,
          );
          pastedFrameLengths.add(cleartext.length);
          pastedBytes.addAll(cleartext);
          cleartext.fillRange(0, cleartext.length, 0);
        }
        expect(pastedFrameLengths, <int>[8191, 5]);
        expect(pastedFrameLengths.every((length) => length <= 8192), isTrue);
        expect(pastedBytes, utf8.encode(paste));
        await expectLater(
          controller.sendInput(Uint8List(8193)),
          throwsArgumentError,
        );
        controllerInput.fillRange(0, controllerInput.length, 0);
        await controller.close();
        socket.receive({
          'type': 'controller_lease_ended',
          'lease_id': leaseId,
          'reason': 'observer_disconnected',
        });
        expect(await observerEvents.moveNext(), isTrue);
        expect(observerEvents.current.reason, 'observer_disconnected');

        final badFrame = Map<String, dynamic>.from(frame)..['sequence'] = 11;
        socket.receive({'type': 'frame', 'frame': badFrame});
        await observer.done.timeout(const Duration(seconds: 1));
        expect(socket.sink.closeCode, 1002);
        await observer.close();
        await observerEvents.cancel();
      } finally {
        secret.fillRange(0, secret.length, 0);
        controlSecret.fillRange(0, controlSecret.length, 0);
        inputCleartext?.fillRange(0, inputCleartext.length, 0);
        api.close();
        hostIdentity.dispose();
        observerIdentity.dispose();
      }
    },
  );

  test(
    'controller authentication rejects EOF immediately after acknowledgement',
    () async {
      final hostIdentity = DeviceIdentity.create(sodium);
      final observerIdentity = DeviceIdentity.create(sodium);
      final secret = collaborationCrypto.createSessionSecret();
      final controlSecret = collaborationCrypto.createControlSecret();
      final now = DateTime.now().toUtc();
      final roomExpiry = now.add(const Duration(minutes: 5));
      final controlExpiry = now.add(const Duration(minutes: 3));
      const leaseId = 'abababab-abab-4bab-8bab-abababababab';
      final context = TerminalCollaborationContext(
        sessionId: _sessionId,
        vaultId: _vaultId,
        membershipVersion: 3,
        hostUserId: _hostUserId,
        hostDeviceId: hostIdentity.deviceId,
        observerUserId: _observerUserId,
        observerDeviceId: observerIdentity.deviceId,
      );
      final keybox = collaborationCrypto.createKeybox(
        sessionSecret: secret,
        hostIdentity: hostIdentity,
        observerEncryptionPublicKey: observerIdentity.encryption.publicKey,
        context: context,
        expiresAt: roomExpiry,
      );
      final controlContext = TerminalControlContext(
        sessionId: _sessionId,
        vaultId: _vaultId,
        membershipVersion: 3,
        hostUserId: _hostUserId,
        hostDeviceId: hostIdentity.deviceId,
        controllerUserId: _observerUserId,
        controllerDeviceId: observerIdentity.deviceId,
        leaseId: leaseId,
        controlEpoch: 1,
      );
      final controlKeybox = collaborationCrypto.createControlKeybox(
        controlSecret: controlSecret,
        hostIdentity: hostIdentity,
        controllerEncryptionPublicKey: observerIdentity.encryption.publicKey,
        context: controlContext,
        expiresAt: controlExpiry,
      );
      final observerSocket = _TestWebSocketChannel()..role = 'observer';
      final controllerSocket = _TestWebSocketChannel()
        ..role = 'controller'
        ..leaseId = leaseId
        ..controlEpoch = 1
        ..closeAfterAuthenticationAcknowledgement = true;
      final api = ApiClient(
        baseUrl: 'https://terminal.example.test',
        client: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer observer-token');
          if (request.method == 'POST' &&
              request.url.path.endsWith('/controller-lease/ticket')) {
            return http.Response(
              jsonEncode({
                'ticket': _ticket(),
                'role': 'controller',
                'lease_id': leaseId,
                'control_epoch': 1,
                'control_keybox': controlKeybox,
                'ticket_expires_at': _serverUtcWholeSecondExpiry(
                  now.add(const Duration(seconds: 20)),
                ),
                'connect_path': '/collaboration/v1/connect',
              }),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/ticket')) {
            return http.Response(
              jsonEncode({
                'ticket': _ticket(),
                'role': 'observer',
                'keybox': keybox,
                'ticket_expires_at': _serverUtcWholeSecondExpiry(
                  now.add(const Duration(seconds: 20)),
                ),
                'connect_path': '/collaboration/v1/connect',
              }),
              200,
            );
          }
          expect(request.method, 'GET');
          return http.Response(
            jsonEncode({
              'devices': [
                {
                  'user_id': _hostUserId,
                  'device_id': hostIdentity.deviceId,
                  'signing_public_key': hostIdentity.signingPublicKey,
                  'status': 'active',
                  'membership_status': 'active',
                },
              ],
            }),
            200,
          );
        }),
      )..accessToken = 'observer-token';
      var channelCount = 0;
      final service = TerminalCollaborationService(
        api: api,
        crypto: vaultCrypto,
        identity: observerIdentity,
        accountId: _observerUserId,
        vaultId: _vaultId,
        membershipVersion: 3,
        channelFactory: (_) =>
            channelCount++ == 0 ? observerSocket : controllerSocket,
        now: () => now,
      );
      TerminalShareObserverSession? observer;
      StreamIterator<TerminalCollaborationEvent>? events;
      try {
        observer = await service.joinObserver(sessionId: _sessionId);
        final eventIterator = StreamIterator<TerminalCollaborationEvent>(
          observer.events,
        );
        events = eventIterator;
        observerSocket.receive({
          'type': 'controller_lease_granted',
          'session_id': _sessionId,
          'lease_id': leaseId,
          'control_epoch': 1,
          'expires_at': controlExpiry.toIso8601String(),
        });
        expect(await eventIterator.moveNext(), isTrue);
        expect(eventIterator.current.kind, 'controller_granted');

        await expectLater(observer.joinController(), throwsStateError);
        expect(
          controllerSocket.sent.whereType<Map>().any(
            (message) => message['type'] == 'authenticate',
          ),
          isTrue,
        );
        expect(controllerSocket.closeCode, 1002);
        expect(observer.controllerGrant, isNull);
      } finally {
        await events?.cancel();
        await observer?.close();
        api.close();
        secret.fillRange(0, secret.length, 0);
        controlSecret.fillRange(0, controlSecret.length, 0);
        hostIdentity.dispose();
        observerIdentity.dispose();
      }
    },
  );

  test(
    'recipient factory rejects revoked, nonmember, and noncanonical keys',
    () {
      expect(
        () => TerminalShareRecipient.fromVaultDevice({
          'user_id': _observerUserId,
          'device_id': '77777777-7777-4777-8777-777777777777',
          'encryption_public_key': encodeBase64Url(Uint8List(32)),
          'status': 'revoked',
          'membership_status': 'active',
        }),
        throwsFormatException,
      );
      expect(
        () => TerminalShareRecipient.fromVaultDevice({
          'user_id': _observerUserId,
          'device_id': '77777777-7777-4777-8777-777777777777',
          'encryption_public_key': encodeBase64Url(Uint8List(32)),
          'status': 'active',
          'membership_status': 'revoked',
        }),
        throwsFormatException,
      );
      expect(
        () => TerminalShareRecipient.fromVaultDevice({
          'user_id': _observerUserId,
          'device_id': '77777777-7777-4777-8777-777777777777',
          'encryption_public_key': 'not-canonical',
          'status': 'active',
          'membership_status': 'active',
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'v2 host accepts pending input, revokes, and resets sequence on regrant',
    () async {
      final hostBase = DeviceIdentity.create(sodium);
      final controllerIdentity = DeviceIdentity.create(sodium);
      final hostIdentity = DeviceIdentity(
        deviceId: 'abababab-abab-4bab-8bab-abababababab',
        signing: hostBase.signing,
        encryption: hostBase.encryption,
      );
      final wallClockNow = DateTime.now().toUtc();
      final now = DateTime.utc(
        wallClockNow.year,
        wallClockNow.month,
        wallClockNow.day,
        wallClockNow.hour,
        wallClockNow.minute,
        wallClockNow.second,
        123,
      );
      final roomExpiry = now.add(const Duration(minutes: 10));
      final hostSocket = _TestWebSocketChannel()..role = 'host';
      final leaseRequestSeen = Completer<void>();
      final releaseFirstLeaseResponse = Completer<void>();
      final thirdLeaseRequestSeen = Completer<void>();
      final releaseThirdLeaseResponse = Completer<void>();
      var leaseRequestCount = 0;
      final leaseBodies = <Map<String, dynamic>>[];
      final leaseResponses = <Map<String, dynamic>>[];
      final approvedDevice = {
        'user_id': _observerUserId,
        'device_id': controllerIdentity.deviceId,
        'encryption_public_key': controllerIdentity.encryptionPublicKey,
        'signing_public_key': controllerIdentity.signingPublicKey,
        'status': 'active',
        'membership_status': 'active',
      };
      final api = ApiClient(
        baseUrl: 'https://terminal.example.test',
        client: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer host-token');
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'devices': [approvedDevice],
              }),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path ==
                  '/api/v1/vaults/$_vaultId/terminal-sessions') {
            final body = Map<String, dynamic>.from(
              jsonDecode(request.body) as Map,
            );
            expect(body['protocol_version'], 2);
            expect(body['session_id'], _sessionId);
            return http.Response(
              jsonEncode({
                'session_id': _sessionId,
                'expires_at': body['expires_at'],
                'host_ticket': _ticket(),
                'connect_path': '/collaboration/v1/connect',
              }),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/controller-lease')) {
            final body = Map<String, dynamic>.from(
              jsonDecode(request.body) as Map,
            );
            leaseBodies.add(body);
            leaseRequestCount++;
            if (leaseRequestCount == 1 || leaseRequestCount == 3) {
              final requestSeen = leaseRequestCount == 1
                  ? leaseRequestSeen
                  : thirdLeaseRequestSeen;
              final releaseResponse = leaseRequestCount == 1
                  ? releaseFirstLeaseResponse
                  : releaseThirdLeaseResponse;
              if (!requestSeen.isCompleted) requestSeen.complete();
              await releaseResponse.future;
            }
            final response = <String, dynamic>{
              'lease_id': body['lease_id'],
              'control_epoch': body['control_epoch'],
              'expires_at': body['expires_at'],
            };
            leaseResponses.add(response);
            return http.Response(jsonEncode(response), 200);
          }
          if (request.method == 'DELETE' &&
              request.url.path.endsWith('/controller-lease')) {
            return http.Response('{}', 200);
          }
          if (request.method == 'DELETE' &&
              request.url.path ==
                  '/api/v1/vaults/$_vaultId/terminal-sessions/$_sessionId') {
            return http.Response('{}', 200);
          }
          fail(
            'Unexpected collaboration request ${request.method} ${request.url}',
          );
        }),
      )..accessToken = 'host-token';
      final service = TerminalCollaborationService(
        api: api,
        crypto: vaultCrypto,
        identity: hostIdentity,
        accountId: _hostUserId,
        vaultId: _vaultId,
        membershipVersion: 3,
        channelFactory: (_) => hostSocket,
        now: () => now,
      );
      final recipient = TerminalShareRecipient.fromVaultDevice(approvedDevice);
      TerminalShareHostSession? host;
      final openedControlSecrets = <Uint8List>[];
      try {
        final hostSession = await service.startHost(
          sessionId: _sessionId,
          expiresAt: roomExpiry,
          observers: [recipient],
          allowInput: true,
        );
        host = hostSession;
        final firstExpiry = DateTime.utc(
          now.year,
          now.month,
          now.day,
          now.hour,
          now.minute + 3,
          now.second,
          987,
        );
        expect(firstExpiry.millisecond, 987);
        final grantFuture = hostSession.grantController(
          controller: recipient,
          expiresAt: firstExpiry,
        );
        await leaseRequestSeen.future.timeout(const Duration(seconds: 1));
        final pendingLease = hostSession.controllerLease!;
        expect(pendingLease.isPending, isTrue);
        expect(pendingLease.controlEpoch, 1);

        final firstBody = leaseBodies.single;
        final firstKeybox = Map<String, dynamic>.from(
          firstBody['keybox'] as Map,
        );
        final normalizedFirstExpiry = DateTime.utc(
          firstExpiry.year,
          firstExpiry.month,
          firstExpiry.day,
          firstExpiry.hour,
          firstExpiry.minute,
          firstExpiry.second,
        );
        final normalizedFirstExpiryText = normalizedFirstExpiry
            .toIso8601String();
        expect(firstBody['expires_at'], normalizedFirstExpiryText);
        expect(firstKeybox['expires_at'], normalizedFirstExpiryText);
        final firstContext = _controlContextFromBody(firstBody);
        final firstSecret = collaborationCrypto.openControlKeybox(
          keybox: firstKeybox,
          controllerIdentity: controllerIdentity,
          hostSigningPublicKey: hostIdentity.signing.publicKey,
          expectedContext: firstContext,
          now: now,
        );
        openedControlSecrets.add(firstSecret);
        final firstInput = Uint8List.fromList([0x03, 0x0d, 0x0a]);
        final firstFrame = await collaborationCrypto.encryptInputFrame(
          controlSecret: firstSecret,
          controllerIdentity: controllerIdentity,
          context: firstContext,
          sequence: 1,
          plaintext: firstInput,
        );
        final firstEventFuture = hostSession.events.first;
        hostSocket.receive({'type': 'input', 'frame': firstFrame});
        final firstEvent = await firstEventFuture.timeout(
          const Duration(seconds: 1),
        );
        expect(firstEvent.kind, 'input');
        expect(firstEvent.bytes, firstInput);
        firstEvent.bytes!.fillRange(0, firstEvent.bytes!.length, 0);
        firstInput.fillRange(0, firstInput.length, 0);

        releaseFirstLeaseResponse.complete();
        final firstLease = await grantFuture;
        expect(firstLease.isPending, isFalse);
        expect(hostSession.controllerLease?.isPending, isFalse);
        expect(leaseResponses.first['expires_at'], normalizedFirstExpiryText);
        expect(
          firstLease.expiresAt.isAtSameMomentAs(normalizedFirstExpiry),
          isTrue,
        );

        final endedFuture = hostSession.events.firstWhere(
          (event) => event.kind == 'controller_ended',
        );
        await hostSession.revokeController();
        final ended = await endedFuture.timeout(const Duration(seconds: 1));
        expect(ended.leaseId, firstLease.leaseId);
        expect(ended.reason, 'revoked');
        expect(hostSession.isConnected, isTrue);

        final secondExpiry = now.add(const Duration(seconds: 1));
        final secondLease = await hostSession.grantController(
          controller: recipient,
          expiresAt: secondExpiry,
        );
        expect(leaseBodies.last['control_epoch'], 2);
        expect(secondLease.controlEpoch, 2);
        final secondContext = _controlContextFromBody(leaseBodies.last);
        final secondSecret = collaborationCrypto.openControlKeybox(
          keybox: Map<String, dynamic>.from(leaseBodies.last['keybox'] as Map),
          controllerIdentity: controllerIdentity,
          hostSigningPublicKey: hostIdentity.signing.publicKey,
          expectedContext: secondContext,
          now: now,
        );
        openedControlSecrets.add(secondSecret);
        final secondInput = Uint8List.fromList([0x61]);
        final secondFrame = await collaborationCrypto.encryptInputFrame(
          controlSecret: secondSecret,
          controllerIdentity: controllerIdentity,
          context: secondContext,
          sequence: 1,
          plaintext: secondInput,
        );
        final secondInputEvent = hostSession.events.firstWhere(
          (event) => event.kind == 'input',
        );
        hostSocket.receive({'type': 'input', 'frame': secondFrame});
        final secondEvent = await secondInputEvent.timeout(
          const Duration(seconds: 1),
        );
        expect(secondEvent.bytes, secondInput);
        secondEvent.bytes!.fillRange(0, secondEvent.bytes!.length, 0);
        secondInput.fillRange(0, secondInput.length, 0);

        final expiredEvent = hostSession.events.firstWhere(
          (event) =>
              event.kind == 'controller_ended' &&
              event.leaseId == secondLease.leaseId,
        );
        expect(
          (await expiredEvent.timeout(const Duration(seconds: 1))).reason,
          'expired',
        );
        expect(hostSession.controllerLease, isNull);

        final thirdGrant = hostSession.grantController(
          controller: recipient,
          expiresAt: now.add(const Duration(minutes: 2)),
        );
        await thirdLeaseRequestSeen.future.timeout(const Duration(seconds: 1));
        final thirdPendingLease = hostSession.controllerLease!;
        expect(thirdPendingLease.isPending, isTrue);
        final endedBeforeResponse = hostSession.events.firstWhere(
          (event) => event.kind == 'controller_ended',
        );
        hostSocket.receive({
          'type': 'controller_lease_ended',
          'lease_id': thirdPendingLease.leaseId,
          'reason': 'observer_disconnected',
        });
        expect(
          (await endedBeforeResponse.timeout(
            const Duration(seconds: 1),
          )).reason,
          'observer_disconnected',
        );
        releaseThirdLeaseResponse.complete();
        await expectLater(thirdGrant, throwsStateError);
        expect(hostSession.controllerLease, isNull);
      } finally {
        if (!releaseFirstLeaseResponse.isCompleted) {
          releaseFirstLeaseResponse.complete();
        }
        if (!releaseThirdLeaseResponse.isCompleted) {
          releaseThirdLeaseResponse.complete();
        }
        await host?.close();
        api.close();
        for (final secret in openedControlSecrets) {
          secret.fillRange(0, secret.length, 0);
        }
        hostBase.dispose();
        controllerIdentity.dispose();
      }
    },
  );
}

String _ticket() => encodeBase64Url(Uint8List(32));

String _serverUtcWholeSecondExpiry(DateTime value) {
  final utc = value.toUtc();
  final wholeSecond = DateTime.utc(
    utc.year,
    utc.month,
    utc.day,
    utc.hour,
    utc.minute,
    utc.second,
  );
  return '${wholeSecond.toIso8601String().substring(0, 19)}+00:00';
}

TerminalControlContext _controlContextFromBody(Map<String, dynamic> body) {
  final keybox = Map<String, dynamic>.from(body['keybox'] as Map);
  return TerminalControlContext(
    sessionId: keybox['session_id'] as String,
    vaultId: keybox['vault_id'] as String,
    membershipVersion: keybox['membership_version'] as int,
    hostUserId: keybox['host_user_id'] as String,
    hostDeviceId: keybox['host_device_id'] as String,
    controllerUserId: keybox['controller_user_id'] as String,
    controllerDeviceId: keybox['controller_device_id'] as String,
    leaseId: keybox['lease_id'] as String,
    controlEpoch: keybox['control_epoch'] as int,
  );
}

class _TestWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _TestWebSocketChannel({this.onFrameSent}) {
    sink = _TestWebSocketSink(
      onAdd: _onSend,
      onClose: () async {
        if (!incoming.isClosed) await incoming.close();
      },
    );
  }

  final incoming = StreamController<dynamic>.broadcast();
  final readyCompleter = Completer<void>()..complete();
  final void Function(String message)? onFrameSent;
  String role = 'host';
  String? leaseId;
  int? controlEpoch;
  bool closeAfterAuthenticationAcknowledgement = false;

  @override
  late final _TestWebSocketSink sink;

  List<dynamic> get sent => sink.sent;

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  Future<void> get ready => readyCompleter.future;

  @override
  String? get protocol => null;

  @override
  int? get closeCode => sink.closeCode;

  @override
  String? get closeReason => sink.closeReason;

  void receive(Map<String, Object?> message) =>
      incoming.add(jsonEncode(message));

  void _onSend(Object? data) {
    if (data is! String) return;
    final decoded = jsonDecode(data);
    if (decoded is Map && decoded['type'] == 'frame') {
      onFrameSent?.call(data);
    }
    if (decoded is Map && decoded['type'] == 'authenticate') {
      scheduleMicrotask(() {
        final acknowledgement = <String, Object?>{
          'type': 'authenticated',
          'role': role,
          'session_id': _sessionId,
        };
        if (role == 'controller') {
          acknowledgement['lease_id'] = leaseId;
          acknowledgement['control_epoch'] = controlEpoch;
        }
        receive(acknowledgement);
        if (closeAfterAuthenticationAcknowledgement) {
          unawaited(incoming.close());
        }
      });
    }
  }
}

class _TestWebSocketSink implements WebSocketSink {
  _TestWebSocketSink({required this.onAdd, required this.onClose});

  final void Function(Object?) onAdd;
  final Future<void> Function() onClose;
  final sent = <dynamic>[];
  final _done = Completer<void>();
  int? closeCode;
  String? closeReason;

  @override
  Future<void> get done => _done.future;

  @override
  void add(data) {
    sent.add(data is String ? jsonDecode(data) : data);
    onAdd(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) => throw error;

  @override
  Future<void> addStream(Stream stream) async {
    await for (final item in stream) {
      add(item);
    }
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCode ??= code;
    closeReason ??= reason;
    if (!_done.isCompleted) {
      await onClose();
      _done.complete();
    }
  }
}
