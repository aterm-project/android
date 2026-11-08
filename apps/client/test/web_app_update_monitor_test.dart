import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/web_update/web_app_update_monitor.dart';

void main() {
  test('a matching bundle stays current and never reloads', () async {
    var reloads = 0;
    final monitor = WebAppUpdateMonitor(
      currentBuildId: 'build-a',
      probeBuildId: () async => 'build-a',
      reload: () async => reloads++,
      checkInterval: const Duration(days: 1),
    );
    addTearDown(monitor.dispose);

    await monitor.checkNow();

    expect(monitor.lastCheckSucceeded, isTrue);
    expect(monitor.hasUpdate, isFalse);
    await monitor.applyUpdate();
    expect(reloads, 0);
  });

  test(
    'a different bundle is reported and only explicit apply reloads',
    () async {
      var reloads = 0;
      final monitor = WebAppUpdateMonitor(
        currentBuildId: 'build-a',
        probeBuildId: () async => 'build-b',
        reload: () async => reloads++,
        checkInterval: const Duration(days: 1),
      );
      addTearDown(monitor.dispose);

      await monitor.checkNow();

      expect(monitor.hasUpdate, isTrue);
      expect(monitor.availableBuildId, 'build-b');
      expect(reloads, 0);
      await monitor.applyUpdate();
      expect(reloads, 1);
    },
  );

  test(
    'failed probes expose no error and clear stale update availability',
    () async {
      var fail = false;
      final monitor = WebAppUpdateMonitor(
        currentBuildId: 'build-a',
        probeBuildId: () async {
          if (fail) throw StateError('private network detail');
          return 'build-b';
        },
        reload: () async {},
        checkInterval: const Duration(days: 1),
      );
      addTearDown(monitor.dispose);

      await monitor.checkNow();
      expect(monitor.hasUpdate, isTrue);
      fail = true;
      await monitor.checkNow();

      expect(monitor.lastCheckSucceeded, isFalse);
      expect(monitor.hasUpdate, isFalse);
      expect(monitor.toString(), isNot(contains('private network detail')));
    },
  );
}
