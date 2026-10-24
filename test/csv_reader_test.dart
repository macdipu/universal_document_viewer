import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/sheets.dart';

void main() {
  List<List<String>> parse(String text, {String delimiter = ','}) => CsvReader.parse(text, delimiter: delimiter);

  test('RFC 4180 fields', () {
    expect(parse('a,b,c\n1,2,3\n'), [
      ['a', 'b', 'c'],
      ['1', '2', '3'],
    ]);
    expect(parse('"Doe, Jane","say ""hi""","two\nlines"'), [
      ['Doe, Jane', 'say "hi"', 'two\nlines'],
    ]);
    expect(parse('a,,c\r\n,\r\n'), [
      ['a', '', 'c'],
      ['', ''],
    ]);
    expect(parse('x\ry'), [
      ['x'],
      ['y'],
    ]);
    expect(parse(''), isEmpty);
    expect(parse('"unterminated'), [
      ['unterminated'],
    ]);
  });

  test('delimiter detection', () {
    expect(CsvReader.detectDelimiter('a;b;c\n1;2;3'), ';');
    expect(CsvReader.detectDelimiter('a\tb\n'), '\t');
    expect(CsvReader.detectDelimiter('"x;y",b,c'), ',');
    expect(CsvReader.detectDelimiter('single'), ',');
  });

  test('workbook: BOM, numbers keep their look, blanks', () {
    final sheet = CsvReader.read('﻿Name,Code,Score\nAlice,007,97.50\nBob,,x1\n').sheets.single;
    expect(sheet.rows[0][0]!.text, 'Name');
    expect(sheet.rows[1][1]!.text, '007');
    expect(sheet.rows[1][2]!.text, '97.50');
    expect(sheet.rows[1][2]!.number, 97.5);
    expect(sheet.rows[2][1], isNull);
    expect(sheet.rows[2][2]!.number, isNull);
    expect(sheet.columnCount, 3);
  });
}
