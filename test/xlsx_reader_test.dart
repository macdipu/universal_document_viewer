import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/sheets.dart';
import 'package:universal_document_viewer/testing.dart';

void main() {
  Uint8List fixture(String name) => File('test/fixtures/sheets/$name').readAsBytesSync();

  group('openpyxl fixture', () {
    late Workbook book;
    setUpAll(() => book = XlsxReader.read(fixture('features.xlsx')));
    String text(String address, [String sheet = 'Summary']) {
      final column = address.codeUnitAt(0) - 65;
      final row = int.parse(address.substring(1)) - 1;
      final rows = book[sheet]!.rows;
      if (row >= rows.length || column >= rows[row].length) return '';
      return rows[row][column]?.text ?? '';
    }

    SheetCell? cell(String address) {
      final column = address.codeUnitAt(0) - 65;
      final row = int.parse(address.substring(1)) - 1;
      final rows = book['Summary']!.rows;
      return column < rows[row].length ? rows[row][column] : null;
    }

    test('sheets in order, with visibility', () {
      expect(book.sheetNames, ['Summary', 'Secret', 'VeryHidden', 'Later']);
      expect([for (final s in book.sheets) s.visibility],
          [SheetVisibility.visible, SheetVisibility.hidden, SheetVisibility.veryHidden, SheetVisibility.visible]);
      expect(text('B3', 'Later'), 'alice again');
    });

    test('values as Excel shows them', () {
      expect(text('A1'), 'Name');
      expect(text('B2'), '97');
      expect(text('B3'), '81.25');
      expect(text('C2'), '2024-01-15');
      expect(text('C3'), '7/4/2023 18:30');
      expect(text('D2'), '25.6%');
      expect(text('D3'), '-5%');
      expect(text('E2'), '1,234.50');
      expect(text('E3'), r'($42.00)');
      expect(text('F2'), 'TRUE');
      expect(text('F3'), 'FALSE');
      expect(text('A4'), '=SUM(B2:B3)');
      expect(text('A5'), 'Rich text');
      expect(text('A7'), '#N/A');
      expect(text('A10'), 'merged');
      expect(text('H12'), 'far corner');
    });

    test('numbers for Sum/Average', () {
      expect(cell('B2')!.number, 97);
      expect(cell('A1')!.number, isNull);
    });

    test('formatting', () {
      expect(cell('A1')!.style.bold, isTrue);
      expect(cell('A6')!.style.italic, isTrue);
      expect(cell('B6')!.style.fillColor, 0xFFFFC000);
      // openpyxl's theme is Office 2007's: Accent 1 (4F81BD) lightened 40%.
      expect(cell('C6')!.style.fillColor, 0xFF95B3D7);
      expect(cell('D6')!.style.fillColor, 0xFFFF0000);
      expect(cell('E6')!.value, isNull);
      expect(cell('E6')!.style.fillColor, 0xFF92D050);
    });

    test('layout: widths, heights, hidden rows and columns, merges', () {
      final sheet = book['Summary']!;
      expect(sheet.layout.columnWidth(0), 20);
      expect(sheet.layout.columnWidth(1), 8.43);
      expect(sheet.layout.hiddenColumns, {6});
      expect(sheet.layout.rowHeight(7), 30);
      expect(sheet.layout.rowHeight(0), 15);
      expect(sheet.layout.hiddenRows, {8});
      expect(sheet.merges, [
        const CellRange(firstRow: 9, firstColumn: 0, lastRow: 9, lastColumn: 2),
        const CellRange(firstRow: 12, firstColumn: 1, lastRow: 12, lastColumn: 3),
      ]);
    });

    test('text formatting, alignment and links', () {
      final red = cell('B7')!.style;
      expect(red.textColor, 0xFFC00000);
      expect(red.underline, isTrue);
      expect(red.fontSize, 14);
      expect(cell('C7')!.style.strikethrough, isTrue);
      expect(cell('D7')!.style.horizontalAlignment, HorizontalAlignment.center);
      expect(cell('D7')!.style.verticalAlignment, VerticalAlignment.top);
      expect(cell('E7')!.style.wrapText, isTrue);
      expect(cell('A1')!.style.textColor, isNull, reason: 'automatic colour');
      expect(book['Summary']!.hyperlinks, {
        (row: 10, column: 1): 'https://example.com/',
        (row: 10, column: 3): '#Later!B3',
      });
    });

    test('frozen panes and size', () {
      final sheet = book['Summary']!;
      expect(sheet.frozenRows, 1);
      expect(sheet.frozenColumns, 1);
      expect(sheet.rows.length, 13);
      expect(sheet.columnCount, 8);
    });
  });

  test('a 6440-row sheet', () {
    final watch = Stopwatch()..start();
    final sheet = XlsxReader.read(fixture('large.xlsx')).sheets.single;
    watch.stop();
    expect(sheet.rows.length, 6440);
    expect(sheet.columnCount, 8);
    expect(sheet.rows[6439][1]!.text, 'Person 6439');
    expect(sheet.rows[1][4]!.text, isNot(contains('.')), reason: 'a date, not a serial');
    // ignore: avoid_print
    print('large.xlsx parsed in ${watch.elapsedMilliseconds} ms');
  });

  group('built in memory', () {
    test('formula results, inline formatting, sparse rows', () {
      final book = XlsxReader.read(buildXlsx([
        const XlsxTestSheet('S', {
          'A1': XlsxTestFormula('SUM(B1:B2)', cached: 2200),
          'A2': XlsxTestFormula('B3&"!"', cached: 'Done!'),
          'A3': XlsxTestFormula('B9'),
          'B5': XlsxTestCell(1234.5, numberFormat: '#,##0.0', bold: true, fill: '00B0F0'),
          'A9': 'a & b < c',
        }, frozenRows: 2),
      ]));
      final rows = book.sheets.single.rows;
      expect(rows[0][0]!.text, '2200');
      expect(rows[0][0]!.number, 2200);
      expect(rows[1][0]!.text, 'Done!');
      expect(rows[2][0]!.text, '=B9');
      expect(rows[3], isEmpty);
      expect(rows[4][1]!.text, '1,234.5');
      expect(rows[4][1]!.style.bold, isTrue);
      expect(rows[4][1]!.style.fillColor, 0xFF00B0F0);
      expect(rows[8][0]!.text, 'a & b < c');
      expect(book.sheets.single.frozenRows, 2);
    });

    test('not a workbook', () {
      expect(() => XlsxReader.read(Uint8List.fromList([1, 2, 3])), throwsA(isA<XlsxFormatException>()));
      expect(() => XlsxReader.read(buildPptx([titleShape('x')])), throwsA(isA<XlsxFormatException>()));
    });
  });
}
