import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/sync/known_host_decision_lock.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/l10n_fixture.dart';

const _testEcPrivateKey = '''-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIJhRXAi/dEpIS6ywVfmAy6DESiGdmEalpujaDEuNXy77oAoGCCqGSM49
AwEHoUQDQgAEbG+9rtBrkd3rlhF/dDKBEOTLJaSEMw3aUHwIs/4GOxPzBLGPrYIa
EnNEA6tk4cu6J+hrvX1U2HiIav0JBVRYwA==
-----END EC PRIVATE KEY-----
''';

const _testEncryptedEd25519PrivateKey = '''-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABC0l9Iobg
dIkpFRXIVcSMo9AAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIDl6gJA/mTwGajQU
GysVNxbg5DLxNkxNMr1N6nMqmILLAAAAoAheLDCmikMrd30h6Z3ug4h7WsK8TjBYToUkhO
1fu5qRd6pgCCeQt0C5eeJMkCSNTP+HZyWT9Vc67VCvzaECjFfXYJUsRYdknAXEO4oFc9fg
v8qGMQTFoIajXQk8Gk9QLqGQ0nupn4fZ3BhHhMoDIx7DWLhlvHddSJzgkORIt4bV8ntzh8
AK9jJFzpo0q4FnYkalW4fo/nosGUM/bq5LR2M=
-----END OPENSSH PRIVATE KEY-----
''';

void main() {
  useAppLocaleFixture('zh');
  test('Desktop Hosts cannot enter SSH or Jump Host transport', () async {
    final api = _RecordingRelayApi();
    final service = SshService(api: api, deviceId: 'device-id', useRelay: true);
    const credential = CredentialRecord(
      id: 'credential',
      name: 'Test',
      username: 'test',
    );
    for (final protocol in [HostProtocol.rdp, HostProtocol.vnc]) {
      final desktop = HostRecord(
        id: 'desktop',
        name: 'Desktop',
        address: '192.0.2.10',
        protocol: protocol,
      );
      await expectLater(
        service.connect(
          host: desktop,
          credential: credential,
          verifyHostKey: (_, _) async => true,
        ),
        throwsArgumentError,
      );
      await expectLater(
        service.connect(
          host: const HostRecord(id: 'ssh', name: 'SSH', address: '192.0.2.11'),
          credential: credential,
          verifyHostKey: (_, _) async => true,
          jumpHops: [
            SshJumpHop(
              host: desktop,
              credential: credential,
              verifyHostKey: (_, _) async => true,
            ),
          ],
        ),
        throwsArgumentError,
      );
    }
    expect(api.targets, isEmpty);
  });

  test(
    'Jump Host configuration is checked before requesting a Relay ticket',
    () async {
      final api = _RecordingRelayApi();
      var relayConnected = false;
      final service = SshService(
        api: api,
        deviceId: 'device-id',
        useRelay: true,
        relaySocketConnector: (_, _) async {
          relayConnected = true;
          return _FakeSshSocket();
        },
      );

      await expectLater(
        service.connect(
          host: const HostRecord(
            id: 'target-id',
            name: 'Target',
            address: '10.0.0.8',
            username: 'target-user',
          ),
          credential: const CredentialRecord(
            id: 'target-credential',
            name: 'Target credential',
            username: 'target-user',
          ),
          verifyHostKey: (_, _) async => true,
          jumpHost: const HostRecord(
            id: 'bastion-id',
            name: 'Bastion',
            address: '192.0.2.10',
            username: 'bastion-user',
          ),
        ),
        throwsArgumentError,
      );
      expect(api.targets, isEmpty);
      expect(relayConnected, isFalse);
    },
  );

  test('Jump Host route bounds and cycles fail before opening Relay', () async {
    final api = _RecordingRelayApi();
    var relayConnected = false;
    final service = SshService(
      api: api,
      deviceId: 'device-id',
      useRelay: true,
      relaySocketConnector: (_, _) async {
        relayConnected = true;
        return _FakeSshSocket();
      },
    );
    final tooDeep = List<SshJumpHop>.generate(
      maxJumpHostHops + 1,
      (index) => SshJumpHop(
        host: HostRecord(
          id: 'hop-$index',
          name: 'Hop $index',
          address: '192.0.2.${index + 1}',
        ),
        credential: CredentialRecord(
          id: 'credential-$index',
          name: 'Hop $index',
          username: 'relay',
        ),
        verifyHostKey: (_, _) async => true,
      ),
    );
    const target = HostRecord(
      id: 'target-id',
      name: 'Target',
      address: '10.0.0.8',
    );
    const targetCredential = CredentialRecord(
      id: 'target-credential',
      name: 'Target',
      username: 'deploy',
    );
    await expectLater(
      service.connect(
        host: target,
        credential: targetCredential,
        verifyHostKey: (_, _) async => true,
        jumpHops: tooDeep,
      ),
      throwsArgumentError,
    );
    await expectLater(
      service.connect(
        host: target,
        credential: targetCredential,
        verifyHostKey: (_, _) async => true,
        jumpHops: [tooDeep.first, tooDeep.first],
      ),
      throwsArgumentError,
    );
    expect(api.targets, isEmpty);
    expect(relayConnected, isFalse);
  });

  test(
    'Jump Host uses an independently verified SSH forward to the target',
    () async {
      final events = <String>[];
      final bastionSocket = _OrderedSshSocket('bastion:socket', events);
      final forwardedChannel = _TestForwardChannel(events);
      final api = _RecordingRelayApi();
      final clients = <String, _TestSshClient>{};
      final callbackResults = <String>[];
      final service = SshService(
        api: api,
        deviceId: 'device-id',
        useRelay: true,
        relaySocketConnector: (_, _) async {
          events.add('relay:connect');
          return bastionSocket;
        },
        sshClientFactory:
            ({
              required socket,
              required username,
              required identities,
              required onPasswordRequest,
              required onUserInfoRequest,
              required onVerifyHostKey,
              required handshakeTimeout,
              required authTimeout,
            }) {
              final label = username == 'bastion-user' ? 'bastion' : 'target';
              expect(onUserInfoRequest, isNull);
              events.add('$label:client');
              final client = _TestSshClient(
                label: label,
                events: events,
                authenticate: () async {
                  events.add('$label:host-key');
                  final accepted = await onVerifyHostKey(
                    'ssh-ed25519',
                    Uint8List.fromList(utf8.encode('$label-fingerprint')),
                  );
                  callbackResults.add('$label:$accepted');
                  if (!accepted) throw SSHAuthFailError('private auth detail');
                  events.add('$label:authenticated');
                },
                forward: (address, port) async {
                  events.add('bastion:forward:$address:$port');
                  return forwardedChannel;
                },
                session: _TestSshSession(events),
              );
              clients[label] = client;
              expect(handshakeTimeout, const Duration(seconds: 90));
              expect(authTimeout, const Duration(seconds: 20));
              if (label == 'bastion') {
                expect(username, 'bastion-user');
                expect(onPasswordRequest?.call(), 'bastion-secret');
                expect(socket, same(bastionSocket));
              } else {
                expect(username, 'target-host-user');
                expect(onPasswordRequest?.call(), 'target-secret');
                expect(socket, same(forwardedChannel));
              }
              return client;
            },
      );

      final connection = await service.connect(
        host: const HostRecord(
          id: 'target-id',
          name: 'Target',
          address: 'target.internal',
          port: 2222,
          username: 'target-host-user',
        ),
        credential: const CredentialRecord(
          id: 'target-credential',
          name: 'Target password',
          username: '',
          secret: 'target-secret',
        ),
        verifyHostKey: (_, fingerprint) async {
          events.add('target:verify-callback:$fingerprint');
          return fingerprint == 'target-fingerprint';
        },
        jumpHost: const HostRecord(
          id: 'bastion-id',
          name: 'Bastion',
          address: '192.0.2.10',
          port: 22,
          username: 'bastion-host-user',
        ),
        jumpCredential: const CredentialRecord(
          id: 'bastion-credential',
          name: 'Bastion password',
          username: 'bastion-user',
          secret: 'bastion-secret',
        ),
        verifyJumpHostKey: (_, fingerprint) async {
          events.add('bastion:verify-callback:$fingerprint');
          return fingerprint == 'bastion-fingerprint';
        },
      );

      expect(api.targets, [('192.0.2.10', 22)]);
      expect(callbackResults, ['bastion:true', 'target:true']);
      expect(
        events,
        containsAllInOrder([
          'relay:connect',
          'bastion:client',
          'bastion:host-key',
          'bastion:verify-callback:bastion-fingerprint',
          'bastion:authenticated',
          'bastion:forward:target.internal:2222',
          'target:client',
          'target:host-key',
          'target:verify-callback:target-fingerprint',
          'target:authenticated',
          'target:shell',
        ]),
      );
      expect(events, isNot(contains('relay:connect:target.internal')));
      expect(connection.client, same(clients['target']));

      await connection.close();
      expect(events.sublist(events.indexOf('target:shell') + 1), [
        'target:session.close',
        'target:client.close',
        'forwarded:channel.close',
        'bastion:client.close',
        'bastion:socket.close',
      ]);
    },
  );

  test(
    'KnownHost decision lock stays held through SSH authentication',
    () async {
      final lock = createKnownHostDecisionLock();
      const scope = KnownHostDecisionScope(
        serverSpaceId: 'server-space-a',
        vaultId: 'vault-a',
      );
      final socket = _OrderedSshSocket('target:socket', <String>[]);
      final hostKeyAccepted = Completer<void>();
      final releaseAuthentication = Completer<void>();
      final api = _RecordingRelayApi();
      var revocationStarted = false;
      final service = SshService(
        api: api,
        deviceId: 'device-id',
        useRelay: true,
        knownHostDecisionLock: lock,
        relaySocketConnector: (_, _) async => socket,
        sshClientFactory:
            ({
              required socket,
              required username,
              required identities,
              required onPasswordRequest,
              required onUserInfoRequest,
              required onVerifyHostKey,
              required handshakeTimeout,
              required authTimeout,
            }) => _TestSshClient(
              label: 'target',
              events: <String>[],
              authenticate: () async {
                final accepted = await onVerifyHostKey(
                  'ssh-ed25519',
                  Uint8List.fromList(utf8.encode('target-fingerprint')),
                );
                expect(accepted, isTrue);
                hostKeyAccepted.complete();
                await releaseAuthentication.future;
              },
              forward: (_, _) async =>
                  throw StateError('Target should not forward.'),
              session: _TestSshSession(<String>[]),
            ),
      );

      final connecting = service.connect(
        host: const HostRecord(
          id: 'target-id',
          name: 'Target',
          address: 'target.internal',
          username: 'deploy',
        ),
        credential: const CredentialRecord(
          id: 'target-credential',
          name: 'Target password',
          username: 'deploy',
          secret: 'synthetic-secret',
        ),
        verifyHostKey: (_, _) async => true,
        knownHostDecisionScope: scope,
      );
      await hostKeyAccepted.future;

      final revocation = lock.run(scope, () async {
        revocationStarted = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        revocationStarted,
        isFalse,
        reason: 'trust revocation must wait while this hop authenticates',
      );

      releaseAuthentication.complete();
      final connection = await connecting;
      await revocation;
      expect(revocationStarted, isTrue);
      await connection.close();
      api.close();
    },
  );

  test(
    'Jump Host setup failure closes every acquired resource in reverse order',
    () async {
      final events = <String>[];
      final bastionSocket = _OrderedSshSocket('bastion:socket', events);
      final forwardedChannel = _TestForwardChannel(events);
      final clients = <String, _TestSshClient>{};
      final service = SshService(
        api: _RecordingRelayApi(),
        deviceId: 'device-id',
        useRelay: true,
        relaySocketConnector: (_, _) async => bastionSocket,
        sshClientFactory:
            ({
              required socket,
              required username,
              required identities,
              required onPasswordRequest,
              required onUserInfoRequest,
              required onVerifyHostKey,
              required handshakeTimeout,
              required authTimeout,
            }) {
              final label = username == 'bastion-user' ? 'bastion' : 'target';
              final client = _TestSshClient(
                label: label,
                events: events,
                authenticate: () async {
                  if (label == 'target') {
                    throw SSHAuthFailError('private authentication detail');
                  }
                  await onVerifyHostKey(
                    'ssh-ed25519',
                    Uint8List.fromList(utf8.encode('accepted')),
                  );
                },
                forward: (_, _) async => forwardedChannel,
                session: _TestSshSession(events),
              );
              clients[label] = client;
              return client;
            },
      );

      await expectLater(
        service.connect(
          host: const HostRecord(
            id: 'target-id',
            name: 'Target',
            address: '10.0.0.8',
            username: 'target-user',
          ),
          credential: const CredentialRecord(
            id: 'target-credential',
            name: 'Target credential',
            username: 'target-user',
          ),
          verifyHostKey: (_, _) async => true,
          jumpHost: const HostRecord(
            id: 'bastion-id',
            name: 'Bastion',
            address: '192.0.2.10',
            username: 'bastion-user',
          ),
          jumpCredential: const CredentialRecord(
            id: 'bastion-credential',
            name: 'Bastion credential',
            username: 'bastion-user',
          ),
          verifyJumpHostKey: (_, _) async => true,
        ),
        throwsA(isA<SSHAuthError>()),
      );

      expect(events.where((event) => event.endsWith('.close')), [
        'target:client.close',
        'forwarded:channel.close',
        'bastion:client.close',
        'bastion:socket.close',
      ]);
      expect(clients.keys, containsAll(['bastion', 'target']));
    },
  );

  test(
    'two Jump Hosts form nested SSH channels with reverse cleanup',
    () async {
      final events = <String>[];
      final outerSocket = _OrderedSshSocket('outer:socket', events);
      final outerChannel = _TestForwardChannel(events, label: 'outer:channel');
      final innerChannel = _TestForwardChannel(events, label: 'inner:channel');
      final api = _RecordingRelayApi();
      final socketByClient = <String, SSHSocket>{};
      final clients = <String, _TestSshClient>{};
      final outerHost = const HostRecord(
        id: 'outer-id',
        name: 'Outer',
        address: '192.0.2.10',
        port: 22,
      );
      final innerHost = const HostRecord(
        id: 'inner-id',
        name: 'Inner',
        address: '10.0.0.20',
        port: 2222,
      );
      final targetHost = const HostRecord(
        id: 'target-id',
        name: 'Target',
        address: 'target.internal',
        port: 2200,
      );
      final expectedRequests = <SSHUserInfoRequest>[];
      final callbackCalls = <(HostRecord, SSHUserInfoRequest)>[];
      final service = SshService(
        api: api,
        deviceId: 'device-id',
        useRelay: true,
        relaySocketConnector: (_, _) async => outerSocket,
        sshClientFactory:
            ({
              required socket,
              required username,
              required identities,
              required onPasswordRequest,
              required onUserInfoRequest,
              required onVerifyHostKey,
              required handshakeTimeout,
              required authTimeout,
            }) {
              final label = switch (username) {
                'outer-user' => 'outer',
                'inner-user' => 'inner',
                _ => 'target',
              };
              final challengeHost = switch (label) {
                'outer' => outerHost,
                'inner' => innerHost,
                _ => targetHost,
              };
              socketByClient[label] = socket;
              final client = _TestSshClient(
                label: label,
                events: events,
                authenticate: () async {
                  events.add('$label:host-key');
                  final accepted = await onVerifyHostKey(
                    'ssh-ed25519',
                    Uint8List.fromList(utf8.encode('$label-fingerprint')),
                  );
                  if (!accepted) throw SSHAuthFailError('private auth detail');
                  expect(onUserInfoRequest, isNotNull);
                  for (var round = 1; round <= 2; round++) {
                    final request = SSHUserInfoRequest(
                      '$label round $round',
                      'Enter $label answer $round',
                      [
                        SSHUserInfoPrompt(
                          '$label challenge $round',
                          round == 1,
                        ),
                      ],
                    );
                    expectedRequests.add(request);
                    final responses = await onUserInfoRequest!(request);
                    expect(responses, ['${challengeHost.id}:${request.name}']);
                  }
                  events.add('$label:authenticated');
                },
                forward: (address, port) async {
                  events.add('$label:forward:$address:$port');
                  return label == 'outer' ? outerChannel : innerChannel;
                },
                session: _TestSshSession(events),
              );
              clients[label] = client;
              return client;
            },
      );

      final connection = await service.connect(
        host: targetHost,
        credential: const CredentialRecord(
          id: 'target-credential',
          name: 'Target',
          username: 'target-user',
          secret: 'target-secret',
        ),
        verifyHostKey: (_, fingerprint) async =>
            fingerprint == 'target-fingerprint',
        onUserInfoRequest: (challengeHost, request) async {
          callbackCalls.add((challengeHost, request));
          return ['${challengeHost.id}:${request.name}'];
        },
        jumpHops: [
          SshJumpHop(
            host: outerHost,
            credential: const CredentialRecord(
              id: 'outer-credential',
              name: 'Outer',
              username: 'outer-user',
              secret: 'outer-secret',
            ),
            verifyHostKey: (_, fingerprint) async =>
                fingerprint == 'outer-fingerprint',
          ),
          SshJumpHop(
            host: innerHost,
            credential: const CredentialRecord(
              id: 'inner-credential',
              name: 'Inner',
              username: 'inner-user',
              secret: 'inner-secret',
            ),
            verifyHostKey: (_, fingerprint) async =>
                fingerprint == 'inner-fingerprint',
          ),
        ],
      );

      expect(api.targets, [('192.0.2.10', 22)]);
      expect(socketByClient['outer'], same(outerSocket));
      expect(socketByClient['inner'], same(outerChannel));
      expect(socketByClient['target'], same(innerChannel));
      final expectedHosts = [
        outerHost,
        outerHost,
        innerHost,
        innerHost,
        targetHost,
        targetHost,
      ];
      expect(callbackCalls, hasLength(6));
      expect(expectedRequests, hasLength(6));
      for (var index = 0; index < expectedHosts.length; index++) {
        expect(
          identical(callbackCalls[index].$1, expectedHosts[index]),
          isTrue,
        );
        expect(
          identical(callbackCalls[index].$2, expectedRequests[index]),
          isTrue,
        );
        expect(
          callbackCalls[index].$2.name,
          contains('round ${index % 2 + 1}'),
        );
        expect(
          callbackCalls[index].$2.instruction,
          contains(expectedHosts[index].name.toLowerCase()),
        );
        expect(callbackCalls[index].$2.prompts.single.echo, index.isEven);
      }
      expect(
        events,
        containsAllInOrder([
          'outer:host-key',
          'outer:authenticated',
          'outer:forward:10.0.0.20:2222',
          'inner:host-key',
          'inner:authenticated',
          'inner:forward:target.internal:2200',
          'target:host-key',
          'target:authenticated',
          'target:shell',
        ]),
      );

      await connection.close();
      expect(events.sublist(events.indexOf('target:shell') + 1), [
        'target:session.close',
        'target:client.close',
        'inner:channel.close',
        'inner:client.close',
        'outer:channel.close',
        'outer:client.close',
        'outer:socket.close',
      ]);
    },
  );

  test('eight Jump Hosts authenticate and forward in order, then close in reverse', () async {
    final events = <String>[];
    final outerSocket = _OrderedSshSocket('relay:socket', events);
    final channels = List<_TestForwardChannel>.generate(
      maxJumpHostHops,
      (index) => _TestForwardChannel(events, label: 'hop-${index + 1}:channel'),
    );
    final jumpHosts = List<HostRecord>.generate(
      maxJumpHostHops,
      (index) => HostRecord(
        id: 'hop-${index + 1}',
        name: 'Hop ${index + 1}',
        address: '192.0.2.${index + 1}',
        port: 2201 + index,
      ),
    );
    const targetHost = HostRecord(
      id: 'eight-hop-target',
      name: 'Eight-hop Target',
      address: 'target.internal',
      port: 2299,
    );
    final nextHosts = <HostRecord>[...jumpHosts.skip(1), targetHost];
    final api = _RecordingRelayApi();
    final socketByClient = <String, SSHSocket>{};
    final verificationOrder = <String>[];
    final clients = <String, _TestSshClient>{};
    final service = SshService(
      api: api,
      deviceId: 'device-id',
      useRelay: true,
      relaySocketConnector: (_, _) async => outerSocket,
      sshClientFactory:
          ({
            required socket,
            required username,
            required identities,
            required onPasswordRequest,
            required onUserInfoRequest,
            required onVerifyHostKey,
            required handshakeTimeout,
            required authTimeout,
          }) {
            final label = username == 'target-user'
                ? 'target'
                : 'hop-${int.parse(username.substring('hop-'.length, username.length - '-user'.length))}';
            final expectedFingerprint = '$label-fingerprint';
            socketByClient[label] = socket;
            final client = _TestSshClient(
              label: label,
              events: events,
              authenticate: () async {
                events.add('$label:host-key');
                final accepted = await onVerifyHostKey(
                  'ssh-ed25519',
                  Uint8List.fromList(utf8.encode(expectedFingerprint)),
                );
                verificationOrder.add('$label:$accepted');
                if (!accepted) {
                  throw SSHAuthFailError('unexpected host-key decision');
                }
                events.add('$label:authenticated');
              },
              forward: (address, port) async {
                if (label == 'target') {
                  throw StateError('the target must not open another hop');
                }
                final hopIndex = int.parse(label.substring('hop-'.length)) - 1;
                final nextHost = nextHosts[hopIndex];
                events.add('$label:forward:$address:$port');
                expect((address, port), (nextHost.address, nextHost.port));
                return channels[hopIndex];
              },
              session: _TestSshSession(events),
            );
            clients[label] = client;
            return client;
          },
    );

    final route = List<SshJumpHop>.generate(maxJumpHostHops, (index) {
      final hopNumber = index + 1;
      return SshJumpHop(
        host: jumpHosts[index],
        credential: CredentialRecord(
          id: 'hop-$hopNumber-credential',
          name: 'Hop $hopNumber credential',
          username: 'hop-$hopNumber-user',
          secret: 'hop-$hopNumber-secret',
        ),
        verifyHostKey: (type, fingerprint) async {
          final accepted =
              type == 'ssh-ed25519' &&
              fingerprint == 'hop-$hopNumber-fingerprint';
          events.add('hop-$hopNumber:trust-$accepted');
          return accepted;
        },
      );
    });

    final connection = await service.connect(
      host: targetHost,
      credential: const CredentialRecord(
        id: 'target-credential',
        name: 'Target',
        username: 'target-user',
        secret: 'target-secret',
      ),
      verifyHostKey: (type, fingerprint) async {
        final accepted =
            type == 'ssh-ed25519' && fingerprint == 'target-fingerprint';
        events.add('target:trust-$accepted');
        return accepted;
      },
      jumpHops: route,
    );

    expect(route, hasLength(maxJumpHostHops));
    expect(api.targets, [(jumpHosts.first.address, jumpHosts.first.port)]);
    expect(socketByClient['hop-1'], same(outerSocket));
    for (var index = 1; index < maxJumpHostHops; index++) {
      expect(socketByClient['hop-${index + 1}'], same(channels[index - 1]));
    }
    expect(socketByClient['target'], same(channels.last));
    expect(clients.keys.toSet(), {
      ...List<String>.generate(maxJumpHostHops, (index) => 'hop-${index + 1}'),
      'target',
    });
    expect(verificationOrder, [
      ...List<String>.generate(
        maxJumpHostHops,
        (index) => 'hop-${index + 1}:true',
      ),
      'target:true',
    ]);

    final expectedConnectionEvents = <String>[];
    for (var index = 0; index < maxJumpHostHops; index++) {
      final hopLabel = 'hop-${index + 1}';
      final nextHost = nextHosts[index];
      expectedConnectionEvents.addAll([
        '$hopLabel:host-key',
        '$hopLabel:trust-true',
        '$hopLabel:authenticated',
        '$hopLabel:forward:${nextHost.address}:${nextHost.port}',
      ]);
    }
    expectedConnectionEvents.addAll([
      'target:host-key',
      'target:trust-true',
      'target:authenticated',
      'target:shell',
    ]);
    expect(events, expectedConnectionEvents);

    await connection.close();
    expect(events.sublist(expectedConnectionEvents.length), [
      'target:session.close',
      'target:client.close',
      for (var index = maxJumpHostHops - 1; index >= 0; index--) ...[
        'hop-${index + 1}:channel.close',
        'hop-${index + 1}:client.close',
      ],
      'relay:socket.close',
    ]);
  });

  test(
    'Jump credential parsing failure closes the acquired bastion socket',
    () async {
      final socket = _FakeSshSocket();
      var clientCreated = false;
      final service = SshService(
        api: _RecordingRelayApi(),
        deviceId: 'device-id',
        useRelay: true,
        relaySocketConnector: (_, _) async => socket,
        sshClientFactory:
            ({
              required socket,
              required username,
              required identities,
              required onPasswordRequest,
              required onUserInfoRequest,
              required onVerifyHostKey,
              required handshakeTimeout,
              required authTimeout,
            }) {
              clientCreated = true;
              return _TestSshClient(
                label: 'unused',
                events: <String>[],
                authenticate: () async {},
                forward: (_, _) async => _TestForwardChannel(<String>[]),
                session: _TestSshSession(<String>[]),
              );
            },
      );

      await expectLater(
        service.connect(
          host: const HostRecord(
            id: 'target-id',
            name: 'Target',
            address: '10.0.0.8',
            username: 'target-user',
          ),
          credential: const CredentialRecord(
            id: 'target-credential',
            name: 'Target credential',
            username: 'target-user',
          ),
          verifyHostKey: (_, _) async => true,
          jumpHost: const HostRecord(
            id: 'bastion-id',
            name: 'Bastion',
            address: '192.0.2.10',
            username: 'bastion-user',
          ),
          jumpCredential: const CredentialRecord(
            id: 'bastion-credential',
            name: 'Broken key',
            username: 'bastion-user',
            kind: AuthKind.privateKey,
            privateKey: 'invalid private key material',
          ),
          verifyJumpHostKey: (_, _) async => true,
        ),
        throwsA(isA<SshCredentialException>()),
      );
      expect(socket.closeCount, 1);
      expect(clientCreated, isFalse);
    },
  );

  test('SSH setup failure closes an already acquired relay socket', () async {
    final socket = _FakeSshSocket();
    final service = SshService(
      api: _RelayApi(),
      deviceId: 'device-id',
      useRelay: true,
      relaySocketConnector: (_, _) async => socket,
    );

    await expectLater(
      service.connect(
        host: const HostRecord(
          id: 'host-id',
          name: 'Host',
          address: '10.0.0.4',
          username: 'operator',
          credentialId: 'credential-id',
        ),
        credential: const CredentialRecord(
          id: 'credential-id',
          name: 'Broken key',
          username: 'operator',
          kind: AuthKind.privateKey,
          privateKey: 'not a valid SSH private key',
        ),
        verifyHostKey: (_, _) async => true,
      ),
      throwsA(isA<SshCredentialException>()),
    );

    expect(socket.closeCount, 1);
  });

  test(
    'a pre-cancelled token does not request a Relay ticket or open a socket',
    () async {
      final api = _RecordingRelayApi();
      var relayConnected = false;
      final cancellation = SshConnectCancellation();
      await cancellation.cancel();
      final service = SshService(
        api: api,
        deviceId: 'device-id',
        useRelay: true,
        relaySocketConnector: (_, _) async {
          relayConnected = true;
          return _FakeSshSocket();
        },
      );

      await expectLater(
        service.connect(
          host: const HostRecord(
            id: 'host-id',
            name: 'Host',
            address: '10.0.0.4',
            username: 'operator',
          ),
          credential: const CredentialRecord(
            id: 'credential-id',
            name: 'Test credential',
            username: 'operator',
          ),
          verifyHostKey: (_, _) async => true,
          cancellation: cancellation,
        ),
        throwsA(isA<SshConnectCancelledException>()),
      );

      expect(api.targets, isEmpty);
      expect(relayConnected, isFalse);
    },
  );

  test(
    'cancelling during SSH KEX closes the acquired Relay socket and client',
    () async {
      final events = <String>[];
      final socket = _FakeSshSocket();
      final clientCreated = Completer<_TestSshClient>();
      final neverAuthenticated = Completer<void>();
      final cancellation = SshConnectCancellation();
      final service = SshService(
        api: _RelayApi(),
        deviceId: 'device-id',
        useRelay: true,
        relaySocketConnector: (_, _) async => socket,
        sshClientFactory:
            ({
              required socket,
              required username,
              required identities,
              required onPasswordRequest,
              required onUserInfoRequest,
              required onVerifyHostKey,
              required handshakeTimeout,
              required authTimeout,
            }) {
              final client = _TestSshClient(
                label: 'target',
                events: events,
                authenticate: () => neverAuthenticated.future,
                forward: (_, _) async => throw StateError('unused'),
                session: _TestSshSession(events),
              );
              clientCreated.complete(client);
              return client;
            },
      );
      final connecting = service.connect(
        host: const HostRecord(
          id: 'host-id',
          name: 'Host',
          address: '10.0.0.4',
          username: 'operator',
        ),
        credential: const CredentialRecord(
          id: 'credential-id',
          name: 'Test credential',
          username: 'operator',
        ),
        verifyHostKey: (_, _) async => true,
        cancellation: cancellation,
      );
      final cancelledConnect = expectLater(
        connecting,
        throwsA(isA<SshConnectCancelledException>()),
      );
      await clientCreated.future;

      await cancellation.cancel();
      await cancelledConnect;
      expect(events, contains('target:client.close'));
      expect(socket.closeCount, 1);
    },
  );

  test(
    'a Relay socket resolving after cancellation is closed immediately',
    () async {
      final socketResult = Completer<SSHSocket>();
      final connectorStarted = Completer<void>();
      final cancellation = SshConnectCancellation();
      final service = SshService(
        api: _RelayApi(),
        deviceId: 'device-id',
        useRelay: true,
        relaySocketConnector: (_, _) {
          connectorStarted.complete();
          return socketResult.future;
        },
      );
      final connecting = service.connect(
        host: const HostRecord(
          id: 'host-id',
          name: 'Host',
          address: '10.0.0.4',
          username: 'operator',
        ),
        credential: const CredentialRecord(
          id: 'credential-id',
          name: 'Test credential',
          username: 'operator',
        ),
        verifyHostKey: (_, _) async => true,
        cancellation: cancellation,
      );
      final cancelledConnect = expectLater(
        connecting,
        throwsA(isA<SshConnectCancelledException>()),
      );
      await connectorStarted.future;

      await cancellation.cancel();
      await cancelledConnect;
      final lateSocket = _FakeSshSocket();
      socketResult.complete(lateSocket);
      await lateSocket.closed.future;
      expect(lateSocket.closeCount, 1);
    },
  );

  test('a failed host-key attempt does not cancel the retry token', () async {
    final events = <String>[];
    final sockets = <_FakeSshSocket>[];
    var clientCount = 0;
    final cancellation = SshConnectCancellation();
    final service = SshService(
      api: _RelayApi(),
      deviceId: 'device-id',
      useRelay: true,
      relaySocketConnector: (_, _) async {
        final socket = _FakeSshSocket();
        sockets.add(socket);
        return socket;
      },
      sshClientFactory:
          ({
            required socket,
            required username,
            required identities,
            required onPasswordRequest,
            required onUserInfoRequest,
            required onVerifyHostKey,
            required handshakeTimeout,
            required authTimeout,
          }) {
            final attempt = ++clientCount;
            return _TestSshClient(
              label: 'attempt-$attempt',
              events: events,
              authenticate: () async {
                final accepted = await onVerifyHostKey(
                  'ssh-ed25519',
                  Uint8List.fromList(utf8.encode('host-fingerprint')),
                );
                if (!accepted) throw SSHAuthFailError('host key not approved');
              },
              forward: (_, _) async => throw StateError('unused'),
              session: _TestSshSession(events),
            );
          },
    );
    const host = HostRecord(
      id: 'host-id',
      name: 'Host',
      address: '10.0.0.4',
      username: 'operator',
    );
    const credential = CredentialRecord(
      id: 'credential-id',
      name: 'Test credential',
      username: 'operator',
    );

    await expectLater(
      service.connect(
        host: host,
        credential: credential,
        verifyHostKey: (_, _) async => false,
        cancellation: cancellation,
      ),
      throwsA(isA<SSHAuthFailError>()),
    );
    expect(cancellation.isCancelled, isFalse);
    expect(sockets.single.closeCount, 1);

    final connection = await service.connect(
      host: host,
      credential: credential,
      verifyHostKey: (_, _) async => true,
      cancellation: cancellation,
    );
    expect(cancellation.isCancelled, isFalse);
    expect(clientCount, 2);
    expect(sockets.last.closeCount, 0);
    await connection.close();
    expect(sockets.last.closeCount, 1);
    await cancellation.cancel();
  });

  test(
    'empty optional passphrase sends SSH identification over the socket',
    () async {
      await _serviceStartsSshAndParsesBanner(_testEcPrivateKey, '');
    },
  );

  test('encrypted key with its passphrase sends SSH identification', () async {
    await _serviceStartsSshAndParsesBanner(
      _testEncryptedEd25519PrivateKey,
      '123456',
    );
  });

  test('relay policy and host-key failures have distinct user messages', () {
    final disabled = sshConnectionFriendlyError(
      const ApiException(
        statusCode: 503,
        code: 'RELAY_DISABLED',
        message: 'policy disabled',
      ),
    );
    final denied = sshConnectionFriendlyError(
      const ApiException(
        statusCode: 403,
        code: 'TARGET_DENIED',
        message: 'outside allowlist',
      ),
    );
    final invalidTarget = sshConnectionFriendlyError(
      const ApiException(
        statusCode: 400,
        code: 'INVALID_TARGET',
        message: 'target must be an IP literal',
      ),
    );
    final rejected = sshConnectionFriendlyError(
      const SshHostKeyVerificationException(SshHostKeyFailure.rejected),
    );
    final changed = sshConnectionFriendlyError(
      const SshHostKeyVerificationException(SshHostKeyFailure.changed),
    );

    expect(disabled, contains('尚未启用'));
    expect(denied, contains('allowlist'));
    expect(invalidTarget, contains('DNS 主机名'));
    expect(rejected, contains('已拒绝'));
    expect(changed, contains('指纹不同'));
    expect(disabled, isNot(denied));
    expect(rejected, isNot(changed));
  });

  test(
    'SSH protocol, authentication and credential errors are classified safely',
    () {
      final credential = sshConnectionFriendlyError(
        const SshCredentialException(),
      );
      final handshake = sshConnectionFriendlyError(
        SSHHandshakeError('private parser detail'),
      );
      final authentication = sshConnectionFriendlyError(
        SSHAuthFailError('server-specific authentication detail'),
      );
      final hostKeyAbort = sshConnectionFriendlyError(
        SSHAuthAbortError(
          'private transport detail',
          SSHHostkeyError('private host-key detail'),
        ),
      );
      final interruptedBeforeAuthentication = sshConnectionFriendlyError(
        SSHAuthAbortError('private transport detail'),
      );
      final session = sshConnectionFriendlyError(
        const SshStageException(SshFailureStage.session),
      );
      final cancelledInteractive = sshConnectionFriendlyError(
        SSHAuthAbortError(
          'internal detail',
          SSHInternalError(const SshKeyboardInteractiveCancelled()),
        ),
      );

      expect(credential, contains('私钥无法解析'));
      expect(handshake, contains('SSH 握手失败'));
      expect(authentication, contains('SSH 身份验证失败'));
      expect(hostKeyAbort, contains('SSH 主机密钥验证失败'));
      expect(hostKeyAbort, isNot(contains('private host-key detail')));
      expect(interruptedBeforeAuthentication, contains('身份验证完成前中断'));
      expect(
        interruptedBeforeAuthentication,
        isNot(contains('private transport detail')),
      );
      expect(session, contains('打开终端会话'));
      expect(cancelledInteractive, contains('authentication was cancelled'));
      expect(cancelledInteractive, isNot(contains('internal detail')));
      expect(handshake, isNot(contains('private parser detail')));
      expect(authentication, isNot(contains('server-specific')));
    },
  );
}

Future<void> _serviceStartsSshAndParsesBanner(
  String privateKey,
  String passphrase,
) async {
  final socket = _RecordingSshSocket();
  final service = SshService(
    api: _RelayApi(),
    deviceId: 'device-id',
    useRelay: true,
    relaySocketConnector: (_, _) async => socket,
  );

  final connecting = service.connect(
    host: const HostRecord(
      id: 'host-id',
      name: 'Host',
      address: '10.0.0.4',
      username: 'operator',
      credentialId: 'credential-id',
    ),
    credential: CredentialRecord(
      id: 'credential-id',
      name: 'Disposable test key',
      username: 'operator',
      kind: AuthKind.privateKey,
      privateKey: privateKey,
      passphrase: passphrase,
    ),
    verifyHostKey: (_, _) async => true,
  );
  Object? connectionError;
  final connectionSettled = connecting.then<void>(
    (_) {},
    onError: (Object error, StackTrace _) {
      connectionError = error.runtimeType;
    },
  );

  final reachedClient = await Future.any<bool>([
    socket.firstClientBanner.future.then((_) => true),
    connectionSettled.then((_) => false),
  ]);
  expect(
    reachedClient,
    isTrue,
    reason: 'connection stopped at $connectionError',
  );
  expect(socket.outboundPackets, isNotEmpty);
  expect(
    latin1.decode(socket.outboundPackets.first),
    startsWith('SSH-2.0-DartSSH_2.0\r\n'),
  );

  // A minimal SSH server identification line proves the inbound byte path is
  // attached before the client waits for key exchange packets.
  socket.addInbound(latin1.encode('SSH-2.0-TestServer_1.0\r\n'));
  await Future<void>.delayed(const Duration(milliseconds: 20));
  await socket.close();
  await connectionSettled;
}

class _RelayApi extends ApiClient {
  _RelayApi() : super(baseUrl: 'https://relay.example.test/tenant');

  @override
  Future<RelayTicket> createRelayTicket({
    required String deviceId,
    required String targetHost,
    required int targetPort,
  }) async => RelayTicket(
    value: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    expiresAt: DateTime.now().toUtc().add(const Duration(seconds: 20)),
  );

  @override
  Uri relayUri() =>
      Uri.parse('wss://relay.example.test/tenant/relay/v1/connect');
}

class _RecordingRelayApi extends ApiClient {
  _RecordingRelayApi() : super(baseUrl: 'https://relay.example.test/tenant');

  final targets = <(String, int)>[];

  @override
  Future<RelayTicket> createRelayTicket({
    required String deviceId,
    required String targetHost,
    required int targetPort,
  }) async {
    targets.add((targetHost, targetPort));
    return RelayTicket(
      value: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      expiresAt: DateTime.now().toUtc().add(const Duration(seconds: 20)),
    );
  }

  @override
  Uri relayUri() =>
      Uri.parse('wss://relay.example.test/tenant/relay/v1/connect');
}

class _TestSshClient implements SSHClient {
  _TestSshClient({
    required this.label,
    required this.events,
    required Future<void> Function() authenticate,
    required this.forward,
    required this.session,
  }) : _authenticated = authenticate();

  final String label;
  final List<String> events;
  final Future<void> _authenticated;
  final Future<SSHForwardChannel> Function(String address, int port) forward;
  final SSHSession session;

  @override
  Future<void> get authenticated => _authenticated;

  @override
  Future<SSHForwardChannel> forwardLocal(
    String remoteHost,
    int remotePort, {
    String localHost = 'localhost',
    int localPort = 0,
  }) => forward(remoteHost, remotePort);

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async {
    events.add('$label:shell');
    return session;
  }

  @override
  Future<void> close() async {
    events.add('$label:client.close');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestSshSession implements SSHSession {
  _TestSshSession(this.events);

  final List<String> events;

  @override
  Stream<Uint8List> get stdout => const Stream<Uint8List>.empty();

  @override
  void close() => events.add('target:session.close');

  @override
  void write(Uint8List data) {}

  @override
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestForwardChannel implements SSHForwardChannel {
  _TestForwardChannel(this.events, {this.label = 'forwarded:channel'});

  final List<String> events;
  final String label;
  final _stream = StreamController<Uint8List>();
  final _sink = StreamController<List<int>>();
  final _closed = Completer<void>();

  @override
  Stream<Uint8List> get stream => _stream.stream;

  @override
  StreamSink<List<int>> get sink => _sink.sink;

  @override
  Future<void> get done => _closed.future;

  @override
  Future<void> close() async {
    events.add('$label.close');
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  void destroy() {
    events.add('$label.destroy');
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> flush() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OrderedSshSocket implements SSHSocket {
  _OrderedSshSocket(this.label, this.events);

  final String label;
  final List<String> events;
  final _stream = StreamController<Uint8List>();
  final _sink = StreamController<List<int>>();
  final _closed = Completer<void>();

  @override
  Stream<Uint8List> get stream => _stream.stream;

  @override
  StreamSink<List<int>> get sink => _sink.sink;

  @override
  Future<void> get done => _closed.future;

  @override
  Future<void> close() async {
    events.add('$label.close');
    if (!_stream.isClosed) await _stream.close();
    if (!_sink.isClosed) await _sink.close();
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  void destroy() {
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> flush() async {}
}

class _FakeSshSocket implements SSHSocket {
  final closed = Completer<void>();
  int closeCount = 0;

  @override
  Stream<Uint8List> get stream => const Stream.empty();

  @override
  StreamSink<List<int>> get sink => StreamController<List<int>>().sink;

  @override
  Future<void> get done => closed.future;

  @override
  Future<void> close() async {
    closeCount++;
    if (!closed.isCompleted) closed.complete();
  }

  @override
  void destroy() {
    if (!closed.isCompleted) closed.complete();
  }

  @override
  Future<void> flush() async {}
}

class _RecordingSshSocket implements SSHSocket {
  final inbound = StreamController<Uint8List>();
  final closed = Completer<void>();
  final firstClientBanner = Completer<void>();
  final outboundPackets = <Uint8List>[];
  final outgoing = StreamController<List<int>>(sync: true);
  int closeCount = 0;
  bool _closing = false;

  _RecordingSshSocket() {
    outgoing.stream.listen((packet) {
      final bytes = Uint8List.fromList(packet);
      outboundPackets.add(bytes);
      if (!firstClientBanner.isCompleted &&
          latin1.decode(bytes, allowInvalid: true).startsWith('SSH-2.0-')) {
        firstClientBanner.complete();
      }
    });
  }

  void addInbound(List<int> bytes) => inbound.add(Uint8List.fromList(bytes));

  @override
  Stream<Uint8List> get stream => inbound.stream;

  @override
  StreamSink<List<int>> get sink => outgoing.sink;

  @override
  Future<void> get done => closed.future;

  @override
  Future<void> close() async {
    closeCount++;
    if (_closing) return;
    _closing = true;
    if (!inbound.isClosed) await inbound.close();
    if (!outgoing.isClosed) await outgoing.close();
    if (!closed.isCompleted) closed.complete();
  }

  @override
  void destroy() {
    if (_closing) return;
    _closing = true;
    if (!inbound.isClosed) unawaited(inbound.close());
    if (!outgoing.isClosed) unawaited(outgoing.close());
    if (!closed.isCompleted) closed.complete();
  }

  @override
  Future<void> flush() async {}
}
