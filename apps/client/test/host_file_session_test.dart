import 'package:aterm_client/ui/host_file_session.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Session = ({String id, String host, bool connected});

void main() {
  Future<Session?> resolve(List<Session> sessions, Future<void> Function() connect) =>
      resolveHostFileSession<Session>(
        hostId: 'target', sessions: () => sessions,
        sessionId: (s) => s.id, sessionHostId: (s) => s.host,
        isConnected: (s) => s.connected, connect: connect,
      );

  test('reuses requested authenticated host instead of unrelated active tab', () async {
    final sessions = <Session>[
      (id: 'other', host: 'other', connected: true),
      (id: 'target-live', host: 'target', connected: true),
    ];
    expect((await resolve(sessions, () async => fail('unexpected connection')))!.id,
        'target-live');
  });

  test('returns only new authenticated session for requested host', () async {
    final sessions = <Session>[(id: 'stale', host: 'target', connected: false)];
    final result = await resolve(sessions, () async {
      sessions.addAll([
        (id: 'new-other', host: 'other', connected: true),
        (id: 'new-target', host: 'target', connected: true),
      ]);
    });
    expect(result!.id, 'new-target');
    sessions.clear();
    expect(result.id, 'new-target');
  });

  test('cancelled or refused authentication never routes to another tab', () async {
    final sessions = <Session>[(id: 'active', host: 'other', connected: true)];
    expect(await resolve(sessions, () async {}), isNull);
    expect(await resolve(sessions, () async {
      sessions.add((id: 'failed', host: 'target', connected: false));
    }), isNull);
  });

  test('trust errors propagate without selecting fallback', () async {
    final sessions = <Session>[(id: 'active', host: 'other', connected: true)];
    await expectLater(resolve(sessions, () async => throw StateError('refused')),
        throwsStateError);
  });
}
