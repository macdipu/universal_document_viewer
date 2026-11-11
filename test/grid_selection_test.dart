import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/spreadsheet.dart';
import 'package:universal_document_viewer/src/spreadsheet/sheet_geometry.dart';

void main() {
  group('GridSelection', () {
    test('a cell and a range contain what they cover, whichever way they were dragged', () {
      const cell = GridSelection.cell(2, 3);
      expect(cell.contains(2, 3), isTrue);
      expect(cell.contains(2, 4), isFalse);
      // Anchor bottom-right, active top-left.
      const range = GridSelection.range(anchorRow: 4, anchorColumn: 3, activeRow: 1, activeColumn: 1);
      expect(range.contains(1, 1), isTrue);
      expect(range.contains(4, 3), isTrue);
      expect(range.contains(5, 3), isFalse);
      expect(range.contains(2, 0), isFalse);
    });

    test('rows, columns and all span the sheet', () {
      expect(const GridSelection.row(2).contains(2, 99), isTrue);
      expect(const GridSelection.row(2).contains(3, 0), isFalse);
      expect(const GridSelection.column(1).contains(99, 1), isTrue);
      expect(const GridSelection.all().contains(7, 7), isTrue);
      final bounds = const GridSelection.column(1).bounds(rowCount: 10, columnCount: 4);
      expect((bounds.firstRow, bounds.lastRow, bounds.firstColumn, bounds.lastColumn), (0, 9, 1, 1));
    });

    test('addresses read as Excel writes them', () {
      String a(GridSelection s) => s.address(rowCount: 20, columnCount: 30);
      expect(a(const GridSelection.cell(1, 1)), 'B2');
      expect(a(const GridSelection.range(anchorRow: 4, anchorColumn: 3, activeRow: 1, activeColumn: 1)), 'B2:D5');
      expect(a(const GridSelection.row(2)), '3:3');
      expect(a(const GridSelection.column(27)), 'AB:AB');
      expect(a(const GridSelection.all()), 'A1:AD20');
      expect(columnLabel(0), 'A');
      expect(columnLabel(25), 'Z');
      expect(columnLabel(26), 'AA');
    });

    test('cell count and dimensions come from the bounds', () {
      const range = GridSelection.range(anchorRow: 1, anchorColumn: 1, activeRow: 4, activeColumn: 3);
      expect(range.cellCount(rowCount: 100, columnCount: 100), 12);
      expect(const GridSelection.all().cellCount(rowCount: 10, columnCount: 3), 30);
    });

    test('extending keeps the anchor and turns back into a cell on the anchor', () {
      const start = GridSelection.cell(2, 2);
      final grown = start.extendedTo(4, 0);
      expect(grown.kind, GridSelectionKind.range);
      expect((grown.anchorRow, grown.anchorColumn, grown.activeRow, grown.activeColumn), (2, 2, 4, 0));
      expect(grown.extendedTo(2, 2), const GridSelection.cell(2, 2));
      expect(grown.extendedTo(0, 5).anchorRow, 2, reason: 'the anchor never moves');
    });
  });

  group('SheetGeometry lookups by position', () {
    test('a position maps to the visible row or column under it, clamped', () {
      final sheet = Worksheet(
        name: 'S',
        rows: [
          for (var r = 0; r < 5; r++) [for (var c = 0; c < 4; c++) SheetCell(NumberValue(r * 4 + c.toDouble()))],
        ],
      );
      final grid = SheetGeometry(sheet, rowCount: 5, columnCount: 4);
      expect(grid.visibleRowAtY(0), 0);
      expect(grid.visibleRowAtY(SheetGeometry.defaultRowHeight + 1), 1);
      expect(grid.visibleRowAtY(1e9), 4);
      expect(grid.visibleColumnAtX(SheetGeometry.defaultColumnWidth * 2 + 1), 2);
      expect(grid.contentHeight, closeTo(5 * SheetGeometry.defaultRowHeight, 0.01));
    });
  });
}
