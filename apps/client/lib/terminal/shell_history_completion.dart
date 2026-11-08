/// An immutable command captured from a completed shell-history event.
///
/// [id] must be stable for the lifetime of this history entry. Command text is
/// treated as data: this provider only returns suggestions and never executes
/// them.
final class ShellHistoryCompletionEntry {
  const ShellHistoryCompletionEntry({
    required this.id,
    required this.command,
    required this.completedAt,
  });

  final String id;
  final String command;
  final DateTime completedAt;
}

/// An immutable, already-rendered command preview from a saved Snippet.
///
/// Snippets have no completion time, so matching history entries rank ahead
/// of them when their other ranking fields are equal.
final class ShellHistorySnippetPreview {
  const ShellHistorySnippetPreview({required this.id, required this.command});

  final String id;
  final String command;
}

/// Builds deterministic, non-executing command suggestions from history,
/// saved Snippet previews, and a local POSIX/Bash command-name dictionary.
///
/// Matching is case-insensitive. Deduplication trims only leading and
/// trailing whitespace and preserves case and internal whitespace: shell
/// quoting can make internal whitespace significant, so this deliberately
/// avoids rewriting or conflating it. Results are ordered by prefix match,
/// newest history completion, source family, normalized command text, and ID.
final class ShellHistoryCompletionProvider {
  const ShellHistoryCompletionProvider();

  static const int defaultLimit = 10;
  static const int maxLimit = 50;

  // Keep this deliberately curated and made only of command names. It gives
  // the Web terminal useful local completion before the user has history,
  // while selection still inserts plain text and does not submit a command.
  static const List<String> _commandNames = <String>[
    'alias',
    'awk',
    'basename',
    'bash',
    'bg',
    'break',
    'builtin',
    'caller',
    'cat',
    'cd',
    'chmod',
    'chown',
    'clear',
    'cmp',
    'command',
    'comm',
    'cp',
    'curl',
    'cut',
    'date',
    'df',
    'diff',
    'dirname',
    'du',
    'docker',
    'echo',
    'env',
    'eval',
    'exec',
    'exit',
    'export',
    'false',
    'fg',
    'file',
    'find',
    'free',
    'getopts',
    'git',
    'grep',
    'gunzip',
    'gzip',
    'head',
    'help',
    'history',
    'hostname',
    'id',
    'jobs',
    'jq',
    'kill',
    'less',
    'ln',
    'local',
    'ls',
    'make',
    'man',
    'mkdir',
    'mktemp',
    'more',
    'mount',
    'mv',
    'nc',
    'netstat',
    'nice',
    'nl',
    'nohup',
    'nproc',
    'nslookup',
    'node',
    'npm',
    'od',
    'openssl',
    'printf',
    'python',
    'python3',
    'ps',
    'pwd',
    'read',
    'readlink',
    'readonly',
    'realpath',
    'return',
    'rm',
    'rmdir',
    'rsync',
    'scp',
    'sed',
    'seq',
    'set',
    'shift',
    'shopt',
    'sleep',
    'sort',
    'source',
    'ssh',
    'stat',
    'stdbuf',
    'sudo',
    'tail',
    'tar',
    'tee',
    'test',
    'time',
    'timeout',
    'top',
    'touch',
    'tr',
    'true',
    'type',
    'ulimit',
    'umask',
    'unalias',
    'uname',
    'uniq',
    'unset',
    'uptime',
    'wc',
    'whereis',
    'which',
    'whoami',
    'xargs',
  ];

  /// Returns command text only. Selecting a candidate is left to the caller
  /// and must not send it to an SSH session or run it.
  List<String> suggest({
    required Iterable<ShellHistoryCompletionEntry> history,
    required Iterable<ShellHistorySnippetPreview> snippets,
    required String query,
    int limit = defaultLimit,
  }) {
    if (limit < 1) return const <String>[];

    final normalizedQuery = _normalize(query);
    if (normalizedQuery.isEmpty) return const <String>[];
    final foldedQuery = normalizedQuery.toLowerCase();
    final candidates = <_Candidate>[];

    for (final entry in history) {
      final command = _normalize(entry.command);
      if (entry.id.trim().isEmpty || command.isEmpty) continue;
      final foldedCommand = command.toLowerCase();
      if (!foldedCommand.contains(foldedQuery)) continue;
      candidates.add(
        _Candidate(
          id: entry.id,
          command: command,
          foldedCommand: foldedCommand,
          completedAt: entry.completedAt,
          source: _CandidateSource.history,
        ),
      );
    }

    for (final snippet in snippets) {
      final command = _normalize(snippet.command);
      if (snippet.id.trim().isEmpty || command.isEmpty) continue;
      final foldedCommand = command.toLowerCase();
      if (!foldedCommand.contains(foldedQuery)) continue;
      candidates.add(
        _Candidate(
          id: snippet.id,
          command: command,
          foldedCommand: foldedCommand,
          completedAt: null,
          source: _CandidateSource.snippet,
        ),
      );
    }

    for (final command in _commandNames) {
      if (!command.startsWith(foldedQuery)) continue;
      candidates.add(
        _Candidate(
          id: 'dictionary:$command',
          command: command,
          foldedCommand: command,
          completedAt: null,
          source: _CandidateSource.dictionary,
        ),
      );
    }

    candidates.sort(
      (left, right) => _compareCandidates(left, right, foldedQuery),
    );
    final uniqueCommands = <String>{};
    final result = <String>[];
    final boundedLimit = limit > maxLimit ? maxLimit : limit;
    for (final candidate in candidates) {
      if (!uniqueCommands.add(candidate.command)) continue;
      result.add(candidate.command);
      if (result.length == boundedLimit) break;
    }
    return List<String>.unmodifiable(result);
  }
}

class _Candidate {
  const _Candidate({
    required this.id,
    required this.command,
    required this.foldedCommand,
    required this.completedAt,
    required this.source,
  });

  final String id;
  final String command;
  final String foldedCommand;
  final DateTime? completedAt;
  final _CandidateSource source;
}

enum _CandidateSource { history, snippet, dictionary }

String _normalize(String command) => command.trim();

int _compareCandidates(_Candidate left, _Candidate right, String foldedQuery) {
  final leftPrefix = left.foldedCommand.startsWith(foldedQuery);
  final rightPrefix = right.foldedCommand.startsWith(foldedQuery);
  final prefixOrder = (rightPrefix ? 1 : 0).compareTo(leftPrefix ? 1 : 0);
  if (prefixOrder != 0) return prefixOrder;

  final leftCompletedAt = left.completedAt;
  final rightCompletedAt = right.completedAt;
  if (leftCompletedAt != null || rightCompletedAt != null) {
    if (leftCompletedAt == null) return 1;
    if (rightCompletedAt == null) return -1;
    final newestFirst = rightCompletedAt.compareTo(leftCompletedAt);
    if (newestFirst != 0) return newestFirst;
  }

  // Keep user-authored snippets ahead of static dictionary entries when the
  // command text and history recency do not otherwise decide the order.
  final sourceOrder = left.source.index.compareTo(right.source.index);
  if (sourceOrder != 0) return sourceOrder;

  final commandOrder = left.command.compareTo(right.command);
  if (commandOrder != 0) return commandOrder;

  // Stable IDs are expected to be unique within each input family. This last
  // tie-break keeps malformed/colliding inputs deterministic too.
  return left.id.compareTo(right.id);
}
