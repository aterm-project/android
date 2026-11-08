import 'dart:convert';

String guacamoleInstruction(Iterable<Object> values) =>
    '${values.map((v) {
      final s = '$v';
      return '${s.runes.length}.$s';
    }).join(',')};';

/// Incremental Unicode framing. TCP/WebSocket boundaries need not coincide
/// with an instruction or a UTF-8 code point.
class GuacamoleParser {
  String _buffer = '';
  final List<String> _elements = [];
  int _instructionLength = 0;

  List<List<String>> add(String text) {
    _buffer += text;
    if (_buffer.length > 2 * 1024 * 1024) {
      throw const FormatException('Desktop instruction exceeds limit');
    }
    final result = <List<String>>[];
    var position = 0;
    while (position < _buffer.length) {
      final dot = _buffer.indexOf('.', position);
      if (dot < 0) {
        if (_buffer.length - position > 7 ||
            !RegExp(r'^\d*$').hasMatch(_buffer.substring(position))) {
          throw const FormatException('Invalid desktop element length');
        }
        break;
      }
      final prefix = _buffer.substring(position, dot);
      if (!RegExp(r'^\d{1,7}$').hasMatch(prefix)) {
        throw const FormatException('Invalid desktop element length');
      }
      final length = int.parse(prefix);
      if (length > 1024 * 1024)
        throw const FormatException('Desktop element too large');
      var end = dot + 1;
      var count = 0;
      while (count < length && end < _buffer.length) {
        final unit = _buffer.codeUnitAt(end++);
        if (unit >= 0xD800 && unit <= 0xDBFF) {
          if (end == _buffer.length) {
            end--;
            break;
          }
          final low = _buffer.codeUnitAt(end++);
          if (low < 0xDC00 || low > 0xDFFF)
            throw const FormatException('Invalid Unicode');
        }
        count++;
      }
      if (count != length || end == _buffer.length) break;
      final delimiter = _buffer[end];
      if (delimiter != ',' && delimiter != ';')
        throw const FormatException('Invalid desktop delimiter');
      _elements.add(_buffer.substring(dot + 1, end));
      _instructionLength += end - position + 1;
      if (_elements.length > 256 || _instructionLength > 2 * 1024 * 1024) {
        throw const FormatException('Desktop instruction exceeds limit');
      }
      position = end + 1;
      if (delimiter == ';') {
        result.add(List.of(_elements));
        _elements.clear();
        _instructionLength = 0;
      }
    }
    _buffer = _buffer.substring(position);
    return result;
  }

  void finish() {
    if (_buffer.isNotEmpty || _elements.isNotEmpty)
      throw const FormatException('Truncated desktop instruction');
  }
}

Stream<List<String>> decodeGuacamole(Stream<List<int>> bytes) async* {
  final parser = GuacamoleParser();
  await for (final text in utf8.decoder.bind(bytes)) {
    yield* Stream.fromIterable(parser.add(text));
  }
  parser.finish();
}
