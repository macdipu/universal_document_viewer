import 'workbook.dart';

/// Reads CSV text (RFC 4180) into a one-sheet [Workbook].
///
/// - Fields may be quoted; inside quotes, `""` is a quote and the field
///   may hold the delimiter and line breaks.
/// - Lines end in CRLF, LF or CR. A trailing line break doesn't add a row.
/// - A leading byte-order mark is dropped.
/// - The delimiter is `,` unless the first line has more `;`, tabs or `|`
///   (spreadsheets saved in locales that use `,` for decimals write `;`).
/// - Fields that are plain numbers become numbers (so a selection can sum
///   them) but keep their written form on screen: `007` stays `007`.
abstract final class CsvReader {
  static Workbook read(String text, {String sheetName = 'Sheet1', String? delimiter}) {
    if (text.startsWith('﻿')) text = text.substring(1);
    final separator = delimiter ?? detectDelimiter(text);
    final rows = <List<SheetCell?>>[
      for (final record in parse(text, delimiter: separator)) [for (final field in record) _cell(field)],
    ];
    return Workbook([Worksheet(name: sheetName, rows: rows)]);
  }

  /// The records in [text], each a list of fields.
  static List<List<String>> parse(String text, {String delimiter = ','}) {
    final records = <List<String>>[];
    var record = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    var fieldStarted = false;
    final length = text.length;

    void endField() {
      record.add(field.toString());
      field.clear();
      fieldStarted = false;
    }

    void endRecord() {
      endField();
      records.add(record);
      record = <String>[];
    }

    for (var i = 0; i < length; i++) {
      final char = text[i];
      if (inQuotes) {
        if (char == '"') {
          if (i + 1 < length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(char);
        }
      } else if (char == '"' && !fieldStarted) {
        inQuotes = true;
        fieldStarted = true;
      } else if (char == delimiter) {
        endField();
      } else if (char == '\r' || char == '\n') {
        if (char == '\r' && i + 1 < length && text[i + 1] == '\n') i++;
        endRecord();
      } else {
        // Text after a closing quote (`"a"b`) is kept, as spreadsheets do.
        field.write(char);
        fieldStarted = true;
      }
    }
    if (fieldStarted || field.isNotEmpty || record.isNotEmpty || inQuotes) endRecord();
    return records;
  }

  /// `,`, `;`, tab or `|`: whichever appears most on the first line,
  /// outside quotes.
  static String detectDelimiter(String text) {
    const candidates = [',', ';', '\t', '|'];
    final counts = {for (final c in candidates) c: 0};
    var inQuotes = false;
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (!inQuotes && (char == '\n' || char == '\r')) {
        break;
      } else if (!inQuotes && counts.containsKey(char)) {
        counts[char] = counts[char]! + 1;
      }
    }
    var best = ',';
    for (final c in candidates) {
      if (counts[c]! > counts[best]!) best = c;
    }
    return best;
  }

  static final _number = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$');

  static SheetCell? _cell(String field) {
    if (field.isEmpty) return null;
    if (_number.hasMatch(field)) {
      final value = num.tryParse(field);
      if (value != null) return SheetCell(NumberValue(value, text: field));
    }
    return SheetCell(TextValue(field));
  }
}
