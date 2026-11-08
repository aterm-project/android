import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:xterm/xterm.dart';

class MirroredTerminalChunk {
  const MirroredTerminalChunk(this.sequence, this.data);
  final int sequence;
  final String data;
}

/// Retains bounded raw VT output without taking ownership of the SSH channel.
class MirroredTerminal extends Terminal {
  MirroredTerminal({
    super.maxLines,
    super.onBell,
    super.onTitleChange,
    super.onIconChange,
    super.onOutput,
    super.onResize,
    super.platform,
    super.inputHandler,
    super.mouseHandler,
    super.onPrivateOSC,
    super.reflowEnabled,
    super.wordSeparators,
    this.maxHistoryBytes = 512 * 1024,
  }) : assert(maxHistoryBytes >= 1024);
  final int maxHistoryBytes;
  final Queue<({String data, int bytes})> _history = Queue();
  final _output = StreamController<MirroredTerminalChunk>.broadcast(sync: true);
  int _historyBytes = 0;
  int _sequence = 0;
  bool _truncated = false;
  bool _mirrorClosed = false;
  Stream<MirroredTerminalChunk> get mirroredOutput => _output.stream;
  int get sequence => _sequence;
  int get retainedBytes => _historyBytes;
  bool get historyTruncated => _truncated;
  List<String> get history =>
      _history.map((entry) => entry.data).toList(growable: false);

  @override
  void write(String data) {
    if (_mirrorClosed) return;
    // Bound each live packet as well as the replay buffer. Avoid splitting a
    // UTF-16 surrogate pair at a packet boundary.
    for (var start = 0; start < data.length;) {
      var end = (start + 4096).clamp(0, data.length);
      if (end < data.length &&
          end > start &&
          data.codeUnitAt(end - 1) >= 0xd800 &&
          data.codeUnitAt(end - 1) <= 0xdbff) {
        end--;
      }
      final part = data.substring(start, end);
      final bytes = utf8.encode(part).length;
      _history.addLast((data: part, bytes: bytes));
      _historyBytes += bytes;
      while (_historyBytes > maxHistoryBytes && _history.isNotEmpty) {
        _historyBytes -= _history.removeFirst().bytes;
        _truncated = true;
      }
      final chunk = MirroredTerminalChunk(++_sequence, part);
      if (!_output.isClosed) _output.add(chunk);
      super.write(part);
      start = end;
    }
  }

  Future<void> closeMirror() {
    if (!_mirrorClosed) {
      _mirrorClosed = true;
      _history.clear();
      _historyBytes = 0;
      mainBuffer.clear();
      altBuffer.clear();
      onOutput = null;
      onResize = null;
      onPrivateOSC = null;
    }
    return _output.close();
  }
}
