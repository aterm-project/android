import 'package:aterm_client/storage/client_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _vaultId = '22222222-2222-4222-8222-222222222222';
const _instanceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _serverSpaceId = '11111111-1111-4111-8111-111111111111';
const _serverGeneration = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'generated out-of-order page responses cannot skip or regress a shared cursor',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      try {
        const pageCount = 24;
        final cursors = [for (var i = 0; i <= pageCount; i++) 'cursor-$i'];

        for (final seed in [1, 7, 19, 42, 2026, 0x5eed]) {
          await database.saveCheckpoint(
            vaultId: _vaultId,
            instanceId: _instanceId,
            serverSpaceId: _serverSpaceId,
            cursor: cursors.first,
            serverGeneration: _serverGeneration,
          );

          // Model several tabs that read a cursor, request its next page, and
          // then receive the response in a different order. Duplicate attempts
          // model a retry or a second tab applying the same page.
          final responses = [
            for (var page = 0; page < pageCount; page++)
              for (var duplicate = 0; duplicate < 3; duplicate++)
                _PageResponse(from: page, to: page + 1),
          ];
          _DeterministicRandom(seed).shuffle(responses);

          var modelCursor = 0;
          for (final response in responses) {
            final observed = await database.saveCheckpointIfCurrent(
              vaultId: _vaultId,
              instanceId: _instanceId,
              serverSpaceId: _serverSpaceId,
              expectedCursor: cursors[response.from],
              expectedServerGeneration: _serverGeneration,
              cursor: cursors[response.to],
              serverGeneration: _serverGeneration,
            );

            // A current page may advance the model. Replaying the already
            // committed page is an idempotent success; every other stale or
            // future page must be rejected.
            final alreadyApplied = response.to == modelCursor;
            final isNextPage = response.from == modelCursor;
            expect(
              observed,
              alreadyApplied || isNextPage,
              reason:
                  'seed=$seed response=${response.from}->${response.to} '
                  'modelCursor=$modelCursor',
            );
            if (isNextPage) modelCursor++;

            final checkpoint = await database.checkpoint(
              _vaultId,
              instanceId: _instanceId,
              serverSpaceId: _serverSpaceId,
            );
            expect(checkpoint?.cursor, cursors[modelCursor]);
            expect(checkpoint?.serverGeneration, _serverGeneration);
          }
        }
      } finally {
        await database.close();
      }
    },
  );

  test(
    'checkpoint write failure preserves the previous cursor for exact retry',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      try {
        const previousCursor = 'cursor-before-fault';
        const nextCursor = 'cursor-after-fault';
        await database.saveCheckpoint(
          vaultId: _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
          cursor: previousCursor,
          serverGeneration: _serverGeneration,
        );
        await database.customStatement('''
          CREATE TRIGGER reject_generated_page_checkpoint
          BEFORE UPDATE OF cursor ON sync_checkpoints
          WHEN NEW.cursor = '$nextCursor'
          BEGIN
            SELECT RAISE(ABORT, 'injected checkpoint persistence failure');
          END
        ''');

        await expectLater(
          database.saveCheckpointIfCurrent(
            vaultId: _vaultId,
            instanceId: _instanceId,
            serverSpaceId: _serverSpaceId,
            expectedCursor: previousCursor,
            expectedServerGeneration: _serverGeneration,
            cursor: nextCursor,
            serverGeneration: _serverGeneration,
          ),
          throwsA(anything),
        );
        var checkpoint = await database.checkpoint(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        );
        expect(checkpoint?.cursor, previousCursor);
        expect(checkpoint?.serverGeneration, _serverGeneration);

        await database.customStatement(
          'DROP TRIGGER reject_generated_page_checkpoint',
        );
        expect(
          await database.saveCheckpointIfCurrent(
            vaultId: _vaultId,
            instanceId: _instanceId,
            serverSpaceId: _serverSpaceId,
            expectedCursor: previousCursor,
            expectedServerGeneration: _serverGeneration,
            cursor: nextCursor,
            serverGeneration: _serverGeneration,
          ),
          isTrue,
        );
        checkpoint = await database.checkpoint(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        );
        expect(checkpoint?.cursor, nextCursor);
        expect(checkpoint?.serverGeneration, _serverGeneration);
      } finally {
        await database.close();
      }
    },
  );
}

class _PageResponse {
  const _PageResponse({required this.from, required this.to});

  final int from;
  final int to;
}

class _DeterministicRandom {
  _DeterministicRandom(int seed) : _state = seed & 0xffffffff;

  int _state;

  int _next(int max) {
    _state = (1664525 * _state + 1013904223) & 0xffffffff;
    return _state % max;
  }

  void shuffle<T>(List<T> values) {
    for (var i = values.length - 1; i > 0; i--) {
      final j = _next(i + 1);
      final value = values[i];
      values[i] = values[j];
      values[j] = value;
    }
  }
}
