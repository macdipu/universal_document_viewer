import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/src/spreadsheet/sheet_geometry.dart';
import 'package:universal_document_viewer/testing.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

/// CR-EXCEL-READER-AUDIT S4: rows the file gave no height grow to show
/// their wrapped text, as Excel's AutoFit would.
void main() {
  const wrap = CellStyle(wrapText: true);
  final long = List.filled(12, 'wrapped words').join(' ');

  Worksheet sheet(
    List<List<SheetCell?>> rows, {
    SheetLayout layout = SheetLayout.standard,
    List<CellRange> merges = const [],
  }) => Worksheet(name: 'S', rows: rows, layout: layout, merges: merges);

  final standard = SheetGeometry.rowHeightOf(15);

  test('a wrapped cell in a row with no stored height grows the row', () {
    final fitted = SheetGeometry.fitWrappedRows(
      sheet([
        [SheetCell(TextValue(long), style: wrap)],
      ]),
    );
    expect(fitted[0], greaterThan(standard));
  });

  test('more lines need more height; a line break counts', () {
    final one = SheetGeometry.fitWrappedRows(
      sheet([
        [const SheetCell(TextValue('a\nb'), style: wrap)],
      ]),
    );
    final many = SheetGeometry.fitWrappedRows(
      sheet([
        [const SheetCell(TextValue('a\nb\nc\nd\ne\nf'), style: wrap)],
      ]),
    );
    expect(many[0], greaterThan(one[0] ?? standard));
  });

  test('left alone: short wrapped text, text that is not wrapped, stored heights, merged and hidden cells', () {
    final fitted = SheetGeometry.fitWrappedRows(
      sheet(
        [
          [const SheetCell(TextValue('short'), style: wrap)],
          [SheetCell(TextValue(long))],
          [SheetCell(TextValue(long), style: wrap)],
          [SheetCell(TextValue(long), style: wrap)],
          [SheetCell(TextValue(long), style: wrap)],
        ],
        layout: const SheetLayout(rowHeights: {2: 15}, hiddenRows: {4}),
        merges: const [CellRange(firstRow: 3, firstColumn: 0, lastRow: 3, lastColumn: 2)],
      ),
    );
    expect(fitted, isEmpty);
  });

  test('a wider column needs fewer lines', () {
    double heightAt(double width) =>
        SheetGeometry.fitWrappedRows(
          sheet([
            [SheetCell(TextValue(long), style: wrap)],
          ], layout: SheetLayout(columnWidths: {0: width})),
        )[0] ??
        standard;
    expect(heightAt(40), lessThan(heightAt(10)));
  });

  test('capped at Excel\'s 409 pt and at a measuring budget', () {
    final huge = SheetGeometry.fitWrappedRows(
      sheet([
        [SheetCell(TextValue(List.filled(400, 'line').join('\n')), style: wrap)],
      ]),
    );
    expect(huge[0], SheetGeometry.maxFittedRowHeight);

    final many = SheetGeometry.fitWrappedRows(
      sheet([
        for (var r = 0; r < SheetGeometry.maxFittedCells + 50; r++)
          [const SheetCell(TextValue('a\nb\nc'), style: wrap)],
      ]),
    );
    expect(many.length, SheetGeometry.maxFittedCells);
  });

  test('the geometry uses fitted heights only where given', () {
    final s = sheet([
      [SheetCell(TextValue(long), style: wrap)],
      [const SheetCell(TextValue('x'))],
    ]);
    final grid = SheetGeometry(s, rowCount: 2, columnCount: 1, fittedRowHeights: {0: 120});
    expect(grid.rowStart(1), 120);
    expect(grid.contentHeight, 120 + standard);
  });

  testWidgets('on screen: the whole wrapped text fits inside its row', (tester) async {
    // Every cell in this workbook wraps: the default style gets wrapText.
    final archive = ZipDecoder().decodeBytes(
      buildXlsx([
        XlsxTestSheet('S', {'A1': long, 'A2': 'next row'}),
      ]),
    );
    final out = Archive();
    for (final file in archive) {
      var bytes = file.content as List<int>;
      if (file.name == 'xl/styles.xml') {
        final xml = utf8.decode(bytes);
        expect(xml, contains('<xf numFmtId="0" fontId="0" fillId="0"/>'));
        bytes = utf8.encode(
          xml.replaceFirst(
            '<xf numFmtId="0" fontId="0" fillId="0"/>',
            '<xf numFmtId="0" fontId="0" fillId="0" applyAlignment="1"><alignment wrapText="1"/></xf>',
          ),
        );
      }
      out.addFile(ArchiveFile.bytes(file.name, bytes));
    }
    final controller = SpreadsheetController();
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.loadBytes(Uint8List.fromList(ZipEncoder().encodeBytes(out))));
    expect(controller.currentRows[0][0]?.style.wrapText, isTrue);

    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SpreadsheetView(controller: controller)),
      ),
    );
    await tester.pump();

    final text = tester.getRect(find.text(long));
    final next = tester.getRect(find.text('next row'));
    expect(text.height, greaterThan(standard), reason: 'it wraps onto several lines');
    expect(next.top, greaterThanOrEqualTo(text.bottom), reason: 'the next row starts below all of it');
  });
}
