import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'support/l10n_fixture.dart';

void main() {
  useAppLocaleFixture('zh');
  test('queued host and group mutations reject a stale caller before resolving the vault', () async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = AppController(
      sodium: await SodiumSumoInit.init(),
      database: database,
      secureStore: ClientSecureStore(),
    );
    final staleScope = isA<StateError>().having(
      (error) => error.message,
      'message',
      contains('工作区已切换'),
    );
    try {
      await expectLater(
        app.saveHostAtRevision(
          const HostRecord(
            id: 'host',
            name: 'Host',
            address: 'host.test',
            username: 'u',
          ),
          expectedRevisionId: 'unused',
          isCurrentContext: () => false,
        ),
        throwsA(staleScope),
      );
      var currentScope = true;
      final groupWrite = app.saveGroup(
        const GroupRecord(id: 'group', name: 'Group'),
        isCurrentContext: () => currentScope,
      );
      currentScope = false;
      await expectLater(groupWrite, throwsA(staleScope));
    } finally {
      app.dispose();
      await database.close();
    }
  });
}
