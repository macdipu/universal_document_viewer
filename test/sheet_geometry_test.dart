import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/sheets.dart';

void main() {
  const sheet = Worksheet(
    name: 'S',
    rows: [],
    frozenRows: 1,
    frozenColumns: 1,
    layout: SheetLayout(
      columnWidths: {1: 20},
      rowHeights: {2: 30},
      hiddenColumns: {2},
      hiddenRows: {3},
    ),
  );
  final geometry = SheetGeometry(sheet, rowCount: 6, columnCount: 4);

  test('sizes scale from the defaults', () {
    expect(SheetGeometry.columnWidthOf(8.43), SheetGeometry.defaultColumnWidth);
    expect(SheetGeometry.rowHeightOf(15), SheetGeometry.defaultRowHeight);
    expect(geometry.rowHeight(2), SheetGeometry.defaultRowHeight * 2);
    expect(geometry.columnWidth(1), closeTo(110 * 145 / 64.01, 0.01));
  });

  test('hidden rows and columns are left out', () {
    expect(geometry.visibleRows, [0, 1, 2, 4, 5]);
    expect(geometry.visibleColumns, [0, 1, 3]);
    expect(geometry.visibleIndexOfRow(4), 3);
    expect(geometry.visibleIndexOfRow(3), isNull);
    expect(geometry.visibleIndexOfColumn(3), 2);
  });

  test('frozen panes, and offsets counted past them', () {
    expect(geometry.frozenRowCount, 1);
    expect(geometry.frozenHeight, 36);
    expect(geometry.scrollOffsetOfRow(0), 0);
    expect(geometry.scrollOffsetOfRow(1), 0);
    expect(geometry.scrollOffsetOfRow(3), 36 + 72);
    expect(geometry.visibleRowAtScrollOffset(0), 1);
    expect(geometry.visibleRowAtScrollOffset(36 + 72), 3);
    expect(geometry.visibleRowAtScrollOffset(36 + 71), 2);
    expect(geometry.visibleRowAtScrollOffset(1e9), 4);
  });
}
