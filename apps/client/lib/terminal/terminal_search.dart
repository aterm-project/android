import 'package:xterm/xterm.dart';

import '../l10n/l10n.dart';

const terminalSearchMaxQueryGraphemes = 256;
const terminalSearchMaxQueryCodeUnits = 1024;

/// One literal search hit in the current xterm buffer. End positions are
/// exclusive, matching xterm's highlight ranges.
class TerminalSearchMatch {
  const TerminalSearchMatch({required this.start, required this.end});

  final CellOffset start;
  final CellOffset end;
}

/// The bounded results of searching a terminal buffer.
class TerminalSearchResult {
  const TerminalSearchResult({
    required this.matches,
    required this.truncated,
    required this.scannedCells,
    this.queryTooLong = false,
  });

  final List<TerminalSearchMatch> matches;

  /// True if rows, cells, or hits were omitted by a configured limit.
  final bool truncated;

  /// Number of physical xterm cells examined, including wide-glyph
  /// continuation cells.
  final int scannedCells;

  /// True when the defensive query code-unit cap rejected the query.
  final bool queryTooLong;
}

/// Formats the search bar's accessible and visible status text.
String terminalSearchCountLabel({
  required int matchCount,
  required int selectedIndex,
  required bool truncated,
  required bool searching,
  bool queryTooLong = false,
}) {
  final l10n = currentL10n;
  if (queryTooLong) return l10n.terminalSearchQueryTooLong;
  if (searching) return l10n.terminalSearchSearching;
  final count = l10n.terminalSearchMatchCount(matchCount, selectedIndex + 1);
  return truncated ? l10n.terminalSearchLimitedCount(count) : count;
}

/// Searches the terminal's current bounded buffer with fixed work and result
/// limits. It reads parsed cells, so ANSI escape sequences are already absent.
/// Rows marked as wrapped are joined; ordinary row boundaries are kept as
/// newlines. Zero-codepoint width-zero cells are skipped only when they
/// immediately follow a width-two lead cell; other empty cells search as
/// spaces. Nonzero width-zero cells are combining runes and map to their base
/// cell.
TerminalSearchResult searchTerminalBuffer(
  Terminal terminal,
  String query, {
  int maxRows = 10000,
  int maxScannedCells = 1000000,
  int maxMatches = 1000,
  int maxQueryCodeUnits = terminalSearchMaxQueryCodeUnits,
}) {
  if (query.length > maxQueryCodeUnits) {
    return const TerminalSearchResult(
      matches: [],
      truncated: false,
      scannedCells: 0,
      queryTooLong: true,
    );
  }
  final needle = _caseFold(query);
  if (needle.isEmpty ||
      maxRows <= 0 ||
      maxScannedCells <= 0 ||
      maxMatches <= 0) {
    return const TerminalSearchResult(
      matches: [],
      truncated: false,
      scannedCells: 0,
    );
  }

  final buffer = terminal.buffer;
  final lines = buffer.lines;
  if (lines.length == 0) {
    return const TerminalSearchResult(
      matches: [],
      truncated: false,
      scannedCells: 0,
    );
  }

  final firstRow = (lines.length - maxRows).clamp(0, lines.length);
  final rowCount = lines.length - firstRow;
  final stride = terminal.viewWidth + 1;
  final text = StringBuffer();
  // A packed row/column map avoids allocating one CellOffset for every cell.
  // `-1` marks a hard line break, which can never be part of a match.
  final positions = <int>[];
  var scannedCells = 0;
  var truncated = firstRow > 0;
  var cellLimitReached = false;
  var lastOccupiedPacked = -1;

  for (var localRow = 0; localRow < rowCount; localRow++) {
    final row = firstRow + localRow;
    final line = lines[row];
    // xterm marks a row that continues a previous row as wrapped.
    if (localRow > 0 && !line.isWrapped) {
      text.write('\n');
      positions.add(-1);
      lastOccupiedPacked = -1;
    }
    final trimmedLength = line.getTrimmedLength(terminal.viewWidth);
    for (var column = 0; column < trimmedLength; column++) {
      if (scannedCells >= maxScannedCells) {
        cellLimitReached = true;
        truncated =
            truncated ||
            _hasUnscannedContent(
              lines,
              firstRow: firstRow,
              rowCount: rowCount,
              localRow: localRow,
              nextColumn: column,
              viewWidth: terminal.viewWidth,
            );
        break;
      }
      scannedCells++;

      final codePoint = line.getCodePoint(column);
      final width = line.getWidth(column);
      // Only the zero-codepoint cell directly after a width-two lead is a
      // wide-glyph continuation. Other empty cells represent searchable
      // spaces, including cells left blank by cursor movement or erase ops.
      final isWideGlyphContinuation =
          codePoint == 0 &&
          width == 0 &&
          column > 0 &&
          line.getWidth(column - 1) == 2;
      if (isWideGlyphContinuation) continue;

      final character = codePoint == 0 ? ' ' : String.fromCharCode(codePoint);
      final folded = _caseFold(character);
      text.write(folded);
      final packed = codePoint != 0 && width == 0 && lastOccupiedPacked >= 0
          ? lastOccupiedPacked
          : localRow * stride + column;
      for (var i = 0; i < folded.length; i++) {
        positions.add(packed);
      }
      if (codePoint == 0) {
        // An erased gap breaks the local base cell for following combining
        // runes; do not map them back to a glyph before that gap.
        lastOccupiedPacked = -1;
      } else if (width > 0) {
        lastOccupiedPacked = localRow * stride + column;
      }
    }
    if (cellLimitReached) break;
  }

  final searchable = text.toString();
  final matches = <TerminalSearchMatch>[];
  final failure = _buildFailureTable(needle);
  var matched = 0;
  for (var index = 0; index < searchable.length; index++) {
    // A hard row break cannot be part of a query, including a direct helper
    // call whose query contains a newline. Resetting prevents cross-row hits.
    if (positions[index] < 0) {
      matched = 0;
      continue;
    }

    final codeUnit = searchable.codeUnitAt(index);
    while (matched > 0 && codeUnit != needle.codeUnitAt(matched)) {
      matched = failure[matched - 1];
    }
    if (codeUnit == needle.codeUnitAt(matched)) matched++;
    if (matched != needle.length) continue;

    if (matches.length == maxMatches) {
      truncated = true;
      break;
    }
    final matchStart = index - needle.length + 1;
    final firstPacked = positions[matchStart];
    final lastPacked = positions[index];
    final startRow = firstPacked ~/ stride;
    final startColumn = firstPacked % stride;
    final endRow = lastPacked ~/ stride;
    final endColumn = lastPacked % stride;
    final endLine = lines[firstRow + endRow];
    final endCellWidth = endLine.getWidth(endColumn).clamp(1, 2);
    matches.add(
      TerminalSearchMatch(
        start: CellOffset(startColumn, firstRow + startRow),
        end: CellOffset(endColumn + endCellWidth, firstRow + endRow),
      ),
    );
    // Failure fallback preserves overlapping literal matches while keeping
    // total comparison work linear in the searchable text length.
    matched = failure[matched - 1];
  }

  return TerminalSearchResult(
    matches: List.unmodifiable(matches),
    truncated: truncated,
    scannedCells: scannedCells,
  );
}

List<int> _buildFailureTable(String pattern) {
  final failure = List<int>.filled(pattern.length, 0);
  var prefixLength = 0;
  for (var index = 1; index < pattern.length; index++) {
    final codeUnit = pattern.codeUnitAt(index);
    while (prefixLength > 0 && codeUnit != pattern.codeUnitAt(prefixLength)) {
      prefixLength = failure[prefixLength - 1];
    }
    if (codeUnit == pattern.codeUnitAt(prefixLength)) prefixLength++;
    failure[index] = prefixLength;
  }
  return failure;
}

String _caseFold(String value) {
  // Dart's locale-independent toLowerCase uses the simple mapping for capital
  // sigma (Σ -> σ), while a lowercase final sigma (ς) remains distinct.
  // Unicode caseless matching treats both sigma forms as the same character.
  return value.toLowerCase().replaceAll('\u03C2', '\u03C3');
}

bool _hasUnscannedContent(
  dynamic lines, {
  required int firstRow,
  required int rowCount,
  required int localRow,
  required int nextColumn,
  required int viewWidth,
}) {
  final currentLine = lines[firstRow + localRow];
  if (nextColumn < currentLine.getTrimmedLength(viewWidth)) return true;
  for (var row = localRow + 1; row < rowCount; row++) {
    if (lines[firstRow + row].getTrimmedLength(viewWidth) > 0) return true;
  }
  return false;
}
