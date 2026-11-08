/// Bounded RFC 4180 CSV reader and writer used by the Termius transfer.
///
/// The reader accepts a UTF-8 BOM, CRLF/LF/CR record separators, quoted
/// commas, quoted line breaks and doubled quotes. It never evaluates cell
/// contents. Errors carry positions only, never cell values, so a malformed
/// password cell cannot leak into a diagnostic.
library;

/// Maximum accepted CSV size in UTF-8 bytes (enforced by [TermiusCsv.parse]
/// for strings too, not only by file pickers).
const maxTermiusCsvBytes = 4 * 1024 * 1024;

/// Maximum number of records, including the header record.
const maxTermiusCsvRecords = 2001;

/// Maximum number of fields in one record.
const maxTermiusCsvFields = 64;

/// Maximum UTF-16 length of one field. Inline private keys are the largest
/// legitimate values (the Host login limit is 256 KiB).
const maxTermiusCsvFieldChars = 262144;

enum TermiusCsvErrorCode {
  tooLarge,
  tooManyRecords,
  tooManyFields,
  fieldTooLong,
  unterminatedQuote,
  strayQuote,
  nulCharacter,
}

/// A structural CSV failure. [line] is the 1-based physical line.
class TermiusCsvException implements Exception {
  const TermiusCsvException(this.code, {required this.line});

  final TermiusCsvErrorCode code;
  final int line;

  @override
  String toString() => 'TermiusCsvException(${code.name}, line $line)';
}

/// One parsed CSV record with the physical line on which it starts.
class TermiusCsvRecord {
  const TermiusCsvRecord({required this.line, required this.fields});

  final int line;
  final List<String> fields;

  /// True for a physically empty line (a single empty, unquoted field).
  bool get isBlank => fields.length == 1 && fields.single.isEmpty;
}

class TermiusCsv {
  const TermiusCsv._();

  /// Parses [source] strictly. Throws [TermiusCsvException] on any structural
  /// problem. Blank lines are returned as blank records so callers can keep
  /// accurate row numbering; most callers skip them.
  static List<TermiusCsvRecord> parse(String source) {
    if (utf8EncodedLength(source) > maxTermiusCsvBytes) {
      throw const TermiusCsvException(TermiusCsvErrorCode.tooLarge, line: 1);
    }
    var index = source.startsWith('﻿') ? 1 : 0;
    final records = <TermiusCsvRecord>[];
    final fields = <String>[];
    final field = StringBuffer();
    var line = 1;
    var recordLine = 1;
    var quoted = false;
    var fieldWasQuoted = false;
    var afterClosingQuote = false;
    var quoteLine = 1;

    void checkFieldLength() {
      if (field.length > maxTermiusCsvFieldChars) {
        throw TermiusCsvException(
          TermiusCsvErrorCode.fieldTooLong,
          line: line,
        );
      }
    }

    void endField() {
      fields.add(field.toString());
      field.clear();
      fieldWasQuoted = false;
      afterClosingQuote = false;
      if (fields.length > maxTermiusCsvFields) {
        throw TermiusCsvException(
          TermiusCsvErrorCode.tooManyFields,
          line: recordLine,
        );
      }
    }

    void endRecord() {
      endField();
      records.add(
        TermiusCsvRecord(
          line: recordLine,
          fields: List.unmodifiable(List<String>.of(fields)),
        ),
      );
      fields.clear();
      if (records.length > maxTermiusCsvRecords) {
        throw TermiusCsvException(
          TermiusCsvErrorCode.tooManyRecords,
          line: recordLine,
        );
      }
    }

    final length = source.length;
    while (index < length) {
      final unit = source.codeUnitAt(index);
      if (unit == 0) {
        throw TermiusCsvException(TermiusCsvErrorCode.nulCharacter, line: line);
      }
      if (quoted) {
        if (unit == 0x22) {
          if (index + 1 < length && source.codeUnitAt(index + 1) == 0x22) {
            field.writeCharCode(0x22);
            index += 2;
            checkFieldLength();
            continue;
          }
          quoted = false;
          afterClosingQuote = true;
          index++;
          continue;
        }
        if (unit == 0x0D) {
          // Keep embedded line breaks exactly as written.
          field.writeCharCode(unit);
          if (index + 1 < length && source.codeUnitAt(index + 1) == 0x0A) {
            field.writeCharCode(0x0A);
            index++;
          }
          line++;
          index++;
          checkFieldLength();
          continue;
        }
        if (unit == 0x0A) line++;
        field.writeCharCode(unit);
        index++;
        checkFieldLength();
        continue;
      }

      if (unit == 0x2C) {
        endField();
        index++;
        continue;
      }
      if (unit == 0x0D || unit == 0x0A) {
        endRecord();
        if (unit == 0x0D &&
            index + 1 < length &&
            source.codeUnitAt(index + 1) == 0x0A) {
          index++;
        }
        index++;
        line++;
        recordLine = line;
        continue;
      }
      if (afterClosingQuote) {
        // `"abc"x` is not valid RFC 4180 and hides a quoting mistake.
        throw TermiusCsvException(TermiusCsvErrorCode.strayQuote, line: line);
      }
      if (unit == 0x22) {
        if (field.isNotEmpty || fieldWasQuoted) {
          throw TermiusCsvException(TermiusCsvErrorCode.strayQuote, line: line);
        }
        quoted = true;
        fieldWasQuoted = true;
        quoteLine = line;
        index++;
        continue;
      }
      field.writeCharCode(unit);
      index++;
      checkFieldLength();
    }
    if (quoted) {
      throw TermiusCsvException(
        TermiusCsvErrorCode.unterminatedQuote,
        line: quoteLine,
      );
    }
    // A trailing record separator does not create an extra empty record.
    if (fields.isNotEmpty || field.isNotEmpty || fieldWasQuoted) {
      endRecord();
    }
    return List.unmodifiable(records);
  }

  /// Encodes [rows] as RFC 4180 CSV with CRLF separators and a UTF-8 BOM
  /// marker (as a leading U+FEFF) so spreadsheet tools detect UTF-8.
  static String encode(
    List<List<String>> rows, {
    bool byteOrderMark = true,
    String lineEnding = '\r\n',
  }) {
    final buffer = StringBuffer();
    if (byteOrderMark) buffer.write('﻿');
    for (final row in rows) {
      for (var index = 0; index < row.length; index++) {
        if (index > 0) buffer.write(',');
        buffer.write(quoteField(row[index]));
      }
      buffer.write(lineEnding);
    }
    return buffer.toString();
  }

  /// Quotes one field when it contains a delimiter, quote, line break, or
  /// leading/trailing whitespace (so passwords keep exact whitespace in tools
  /// that trim unquoted cells).
  static String quoteField(String value) {
    final needsQuotes =
        value.contains(RegExp(r'[",\r\n]')) ||
        (value.isNotEmpty && (value.trim().length != value.length));
    if (!needsQuotes) return value;
    return '"${value.replaceAll('"', '""')}"';
  }
}

/// UTF-8 byte length of [value] without allocating the encoded bytes.
/// Unpaired surrogates count as U+FFFD (3 bytes), matching `utf8.encode`.
int utf8EncodedLength(String value) {
  var bytes = 0;
  final length = value.length;
  for (var index = 0; index < length; index++) {
    final unit = value.codeUnitAt(index);
    if (unit < 0x80) {
      bytes += 1;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit >= 0xD800 &&
        unit <= 0xDBFF &&
        index + 1 < length &&
        (value.codeUnitAt(index + 1) & 0xFC00) == 0xDC00) {
      bytes += 4;
      index++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

/// True when a spreadsheet application could evaluate [value] as a formula.
/// Export never alters such values (they may be credentials); it reports them.
bool isSpreadsheetFormulaRisk(String value) =>
    value.isNotEmpty && const {'=', '+', '-', '@', '\t', '\r'}.contains(value[0]);
