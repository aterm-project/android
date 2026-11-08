import 'dart:convert';

/// RFC 8785 JSON Canonicalization Scheme for protocol JSON values.
///
/// Protocol counters are decimal strings and wire headers use integers, strings,
/// booleans, nulls, arrays and maps. This encoder rejects non-finite values and
/// integers outside the interoperable IEEE-754 safe range.
String canonicalJson(Object? value) => _canonical(value);

String _canonical(Object? value) {
  if (value == null || value is bool || value is String)
    return jsonEncode(value);
  if (value is int) {
    if (value.abs() > 9007199254740991) {
      throw ArgumentError(
        'Use decimal strings for integers outside the JCS safe range',
      );
    }
    return value.toString();
  }
  if (value is double) {
    if (!value.isFinite)
      throw ArgumentError('JCS does not allow non-finite numbers');
    if (value == 0) return '0';
    final encoded = jsonEncode(value);
    return encoded.replaceFirst(RegExp(r'\.0(?=[eE]|$)'), '').replaceAllMapped(
      RegExp(r'E([+-]?)(\d+)'),
      (m) {
        final sign = m[1] == '-' ? '-' : '';
        final exponent = int.parse(m[2]!);
        return 'e$sign$exponent';
      },
    );
  }
  if (value is List) return '[${value.map(_canonical).join(',')}]';
  if (value is Map) {
    final entries = value.entries.toList()
      ..sort((a, b) => (a.key as String).compareTo(b.key as String));
    return '{${entries.map((entry) {
      if (entry.key is! String) throw ArgumentError('JCS object keys must be strings');
      return '${jsonEncode(entry.key)}:${_canonical(entry.value)}';
    }).join(',')}}';
  }
  throw ArgumentError('Unsupported JCS value: ${value.runtimeType}');
}
