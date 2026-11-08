import '../domain/models.dart';

enum TerminalToolsSection { search, commands, history }

bool isSafeTerminalCommand(String value) =>
    value.trim().isNotEmpty &&
    value.length <= 4096 &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]').hasMatch(value);

class TerminalCommandItem {
  const TerminalCommandItem({
    required this.id,
    required this.title,
    required this.command,
  });
  final String id, title, command;
}

List<TerminalCommandItem> terminalQuickCommands(
  Iterable<SnippetRecord> snippets,
) => [
  for (final s in snippets)
    if (s.shell == 'bash' &&
        s.executionMode == SnippetExecutionMode.script &&
        s.parameters.isEmpty &&
        isSafeTerminalCommand(s.body))
      TerminalCommandItem(id: s.id, title: s.title, command: s.body),
];

/// Query history is deliberately bounded and lives only with its terminal tab.
class TerminalSearchHistory {
  static const limit = 20;
  final _items = <String>[];
  List<String> get items => List.unmodifiable(_items);
  void remember(String query) {
    if (query.trim().isEmpty || query.length > 512) return;
    _items.remove(query);
    _items.insert(0, query);
    if (_items.length > limit) _items.removeLast();
  }

  void remove(String query) => _items.remove(query);
  void clear() => _items.clear();
}

SnippetRecord updateTerminalQuickCommand(
  SnippetRecord? original,
  SnippetRecord draft,
) => SnippetRecord(
  id: draft.id,
  title: draft.title,
  body: draft.body,
  shell: 'bash',
  tags: original?.tags ?? const [],
  revisionId: original?.revisionId,
  manifest: original?.manifest,
);
