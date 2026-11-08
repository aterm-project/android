import 'package:aterm_client/terminal/shell_history_completion.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const provider = ShellHistoryCompletionProvider();

  group('ShellHistoryCompletionProvider', () {
    test('ranks prefix matches before newer substring matches', () {
      final results = provider.suggest(
        history: [
          ShellHistoryCompletionEntry(
            id: 'recent-substring',
            command: 'tail --follow app.log',
            completedAt: DateTime.utc(2026, 10, 8, 12),
          ),
          ShellHistoryCompletionEntry(
            id: 'older-prefix',
            command: 'LOGROTATE --check',
            completedAt: DateTime.utc(2026, 10, 7, 12),
          ),
        ],
        snippets: const [
          ShellHistorySnippetPreview(
            id: 'snippet-substring',
            command: 'grep error /var/log/app.log',
          ),
        ],
        query: ' log ',
      );

      expect(results, [
        'LOGROTATE --check',
        'tail --follow app.log',
        'grep error /var/log/app.log',
      ]);
    });

    test(
      'ranks by newest completion, then normalized command and stable ID',
      () {
        final completedAt = DateTime.utc(2026, 10, 8, 12);
        final history = [
          ShellHistoryCompletionEntry(
            id: 'z-id',
            command: 'git status',
            completedAt: completedAt,
          ),
          ShellHistoryCompletionEntry(
            id: 'b-id',
            command: 'git stash',
            completedAt: completedAt,
          ),
          ShellHistoryCompletionEntry(
            id: 'newest',
            command: 'git log',
            completedAt: completedAt.add(const Duration(seconds: 1)),
          ),
          ShellHistoryCompletionEntry(
            id: 'oldest',
            command: 'git branch',
            completedAt: completedAt.subtract(const Duration(seconds: 1)),
          ),
        ];

        final forward = provider.suggest(
          history: history,
          snippets: const [],
          query: 'git',
        );
        final reversed = provider.suggest(
          history: history.reversed,
          snippets: const [],
          query: 'git',
        );

        expect(forward, [
          'git log',
          'git stash',
          'git status',
          'git branch',
          'git',
        ]);
        expect(reversed, forward);
      },
    );

    test(
      'deduplicates trimmed commands without changing shell-significant text',
      () {
        final newest = DateTime.utc(2026, 10, 8, 12);
        final results = provider.suggest(
          history: [
            ShellHistoryCompletionEntry(
              id: 'older',
              command: '  printf "a  b"  ',
              completedAt: newest.subtract(const Duration(minutes: 1)),
            ),
            ShellHistoryCompletionEntry(
              id: 'newer',
              command: 'printf "a  b"',
              completedAt: newest,
            ),
            ShellHistoryCompletionEntry(
              id: 'different-case',
              command: 'Printf "a  b"',
              completedAt: newest,
            ),
            ShellHistoryCompletionEntry(
              id: 'different-internal-spacing',
              command: 'printf "a b"',
              completedAt: newest,
            ),
          ],
          snippets: const [
            ShellHistorySnippetPreview(
              id: 'same-command-snippet',
              command: 'printf "a  b"',
            ),
          ],
          query: 'printf',
        );

        expect(results, [
          'Printf "a  b"',
          'printf "a  b"',
          'printf "a b"',
          'printf',
        ]);
      },
    );

    test(
      'ignores empty candidates and returns no suggestions for blank query',
      () {
        final history = [
          ShellHistoryCompletionEntry(
            id: 'empty-command',
            command: '   ',
            completedAt: DateTime.utc(2026, 10, 8),
          ),
          ShellHistoryCompletionEntry(
            id: 'empty-id',
            command: 'echo visible',
            completedAt: DateTime.utc(2026, 10, 8),
          ),
          ShellHistoryCompletionEntry(
            id: 'valid',
            command: 'echo visible',
            completedAt: DateTime.utc(2026, 10, 8),
          ),
        ];

        expect(
          provider.suggest(history: history, snippets: const [], query: '  '),
          isEmpty,
        );
        expect(
          provider.suggest(history: history, snippets: const [], query: 'echo'),
          ['echo visible', 'echo'],
        );
        expect(
          provider.suggest(history: const [], snippets: const [], query: '  '),
          isEmpty,
        );
      },
    );

    test('matches local POSIX/Bash command names without history', () {
      expect(
        provider.suggest(history: const [], snippets: const [], query: 'GiT'),
        ['git'],
      );
      expect(
        provider.suggest(history: const [], snippets: const [], query: 'pr'),
        ['printf'],
      );
      expect(
        provider.suggest(history: const [], snippets: const [], query: 'py'),
        ['python', 'python3'],
      );
      expect(
        provider.suggest(
          history: const [],
          snippets: const [],
          query: 'not-a-command',
        ),
        isEmpty,
      );
    });

    test('merges dictionary, history, and Snippets deterministically', () {
      final newest = DateTime.utc(2026, 10, 8, 12);
      final history = [
        ShellHistoryCompletionEntry(
          id: 'older-cat-options',
          command: 'cat -n /etc/hosts',
          completedAt: newest.subtract(const Duration(minutes: 1)),
        ),
        ShellHistoryCompletionEntry(
          id: 'newer-cat',
          command: 'cat',
          completedAt: newest,
        ),
        ShellHistoryCompletionEntry(
          id: 'substring',
          command: 'printf cat',
          completedAt: newest.add(const Duration(minutes: 1)),
        ),
      ];
      const snippets = [
        ShellHistorySnippetPreview(
          id: 'duplicate-history',
          command: ' cat -n /etc/hosts ',
        ),
        ShellHistorySnippetPreview(id: 'snippet', command: 'capture'),
      ];

      final forward = provider.suggest(
        history: history,
        snippets: snippets,
        query: 'ca',
      );
      final reversed = provider.suggest(
        history: history.reversed,
        snippets: snippets.reversed,
        query: 'ca',
      );

      expect(forward, [
        'cat',
        'cat -n /etc/hosts',
        'capture',
        'caller',
        'printf cat',
      ]);
      expect(reversed, forward);
      expect(forward.where((command) => command == 'cat'), hasLength(1));
      expect(
        forward.where((command) => command == 'cat -n /etc/hosts'),
        hasLength(1),
      );
      expect(forward, everyElement(matches(RegExp(r'^[^\r\n]+$'))));
    });

    test('dictionary results remain bounded by the default limit', () {
      final results = provider.suggest(
        history: const [],
        snippets: const [],
        query: 'c',
      );

      expect(results, hasLength(ShellHistoryCompletionProvider.defaultLimit));
      expect(results, everyElement(matches(RegExp(r'^[a-z][a-z0-9._+-]*$'))));
      expect(
        results,
        provider.suggest(history: const [], snippets: const [], query: 'c'),
      );
    });

    test('bounds result count and returns an immutable text-only list', () {
      final history = List.generate(
        ShellHistoryCompletionProvider.maxLimit + 1,
        (index) => ShellHistoryCompletionEntry(
          id: 'entry-$index',
          command: 'echo item-$index',
          completedAt: DateTime.utc(2026, 10, 8).add(Duration(seconds: index)),
        ),
      );

      final results = provider.suggest(
        history: history,
        snippets: const [],
        query: 'echo',
        limit: ShellHistoryCompletionProvider.maxLimit + 1,
      );

      expect(results, hasLength(ShellHistoryCompletionProvider.maxLimit));
      expect(results.first, 'echo item-50');
      expect(results, everyElement(isA<String>()));
      expect(
        () => results.add('echo should not be inserted'),
        throwsUnsupportedError,
      );
      expect(
        provider.suggest(
          history: history,
          snippets: const [],
          query: 'echo',
          limit: 0,
        ),
        isEmpty,
      );
    });
  });
}
