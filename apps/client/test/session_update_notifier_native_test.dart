import 'dart:async';
import 'dart:io';
import 'package:aterm_client/auth/session_credentials.dart';
import 'package:aterm_client/auth/session_update_notifier_native.dart';
import 'package:aterm_client/platform/native_coordination.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native generation signals contain no identities and follow active scope',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'session-signals-',
      );
      coordinationDirectory = () async => directory;
      final first = createSessionUpdateNotifier();
      final second = createSessionUpdateNotifier();
      const scope = SessionScope(
        serverNamespace: 'secret-server',
        accountId: 'secret-account',
        deviceId: 'secret-device',
      );
      final received = Completer<SessionUpdateEvent>();
      final subscription = second.updates.listen((event) {
        if (!received.isCompleted) received.complete(event);
      });
      (second as ScopedSessionUpdateNotifier).watchScope(scope);
      // Give the first poll time to establish an empty baseline.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      first.signal(
        const SessionUpdateEvent(scope: scope, kind: SessionUpdateKind.removed),
      );
      final event = await received.future.timeout(const Duration(seconds: 3));
      expect(event.scope, scope);
      expect(event.kind, SessionUpdateKind.removed);
      final files = await directory
          .list()
          .where((entry) => entry is File)
          .cast<File>()
          .toList();
      expect(files, hasLength(1));
      expect(files.single.path, isNot(contains('secret')));
      expect(await files.single.readAsString(), isNot(contains('secret')));
      // Reopening a scope must baseline an old terminal marker, not replay it.
      final reopened = createSessionUpdateNotifier();
      var staleReplayed = false;
      final staleSubscription = reopened.updates.listen(
        (_) => staleReplayed = true,
      );
      (reopened as ScopedSessionUpdateNotifier).watchScope(scope);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(staleReplayed, isFalse);
      reopened.dispose();
      await staleSubscription.cancel();
      (second as ScopedSessionUpdateNotifier).watchScope(null);
      first.dispose();
      second.dispose();
      await subscription.cancel();
      await directory.delete(recursive: true);
    },
  );
}
