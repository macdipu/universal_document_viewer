import 'package:flutter/foundation.dart';

import '../engines/spreadsheet/workbook.dart';

/// What a [GridSelection] covers.
enum GridSelectionKind {
  /// One cell.
  cell,

  /// A rectangle of cells, from an anchor to an active cell.
  range,

  /// A whole row, picked from its number.
  row,

  /// A whole column, picked from its letter.
  column,

  /// Every cell of the sheet's used range.
  all,
}

/// The cells the reader has selected. Always in *sheet* coordinates (zero
/// based), never pixels, so scrolling, zooming and virtualization can't
/// move it.
///
/// A [cell] or [range] selection has an [anchor](anchorRow) where it
/// started and an active cell where it was last extended to; Shift+arrows
/// and Shift+click move the active cell and keep the anchor. A [row],
/// [column] or [all] selection spans the sheet.
@immutable
class GridSelection {
  /// Selects the one cell at [row], [column].
  const GridSelection.cell(int row, int column)
    : kind = GridSelectionKind.cell,
      anchorRow = row,
      anchorColumn = column,
      activeRow = row,
      activeColumn = column;

  /// Selects the rectangle between the anchor and the active cell.
  const GridSelection.range({
    required this.anchorRow,
    required this.anchorColumn,
    required this.activeRow,
    required this.activeColumn,
  }) : kind = GridSelectionKind.range;

  /// Selects the sheet row [index].
  const GridSelection.row(int index)
    : kind = GridSelectionKind.row,
      anchorRow = index,
      anchorColumn = 0,
      activeRow = index,
      activeColumn = 0;

  /// Selects the sheet column [index].
  const GridSelection.column(int index)
    : kind = GridSelectionKind.column,
      anchorRow = 0,
      anchorColumn = index,
      activeRow = 0,
      activeColumn = index;

  /// Selects the whole used range.
  const GridSelection.all()
    : kind = GridSelectionKind.all,
      anchorRow = 0,
      anchorColumn = 0,
      activeRow = 0,
      activeColumn = 0;

  /// What is selected.
  final GridSelectionKind kind;

  /// Where the selection started (row, zero based).
  final int anchorRow;

  /// Where the selection started (column, zero based).
  final int anchorColumn;

  /// The cell the keyboard acts from (row, zero based).
  final int activeRow;

  /// The cell the keyboard acts from (column, zero based).
  final int activeColumn;

  /// Whether a row is selected; false for anything else.
  bool get isRow => kind == GridSelectionKind.row;

  /// Whether a column is selected.
  bool get isColumn => kind == GridSelectionKind.column;

  /// Zero-based sheet index of the selected row or column.
  int get index => isRow ? anchorRow : anchorColumn;

  /// Whether exactly one cell is selected.
  bool get isSingleCell => kind == GridSelectionKind.cell;

  /// Whether the zero-based cell at [row], [column] is selected.
  bool contains(int row, int column) => switch (kind) {
    GridSelectionKind.cell => row == activeRow && column == activeColumn,
    GridSelectionKind.range =>
      row >= _min(anchorRow, activeRow) &&
          row <= _max(anchorRow, activeRow) &&
          column >= _min(anchorColumn, activeColumn) &&
          column <= _max(anchorColumn, activeColumn),
    GridSelectionKind.row => row == anchorRow,
    GridSelectionKind.column => column == anchorColumn,
    GridSelectionKind.all => true,
  };

  /// The selection as a rectangle; a row, column or [all] selection is cut
  /// to the sheet's [rowCount] by [columnCount] cells.
  CellRange bounds({required int rowCount, required int columnCount}) => switch (kind) {
    GridSelectionKind.row => CellRange(
      firstRow: anchorRow,
      firstColumn: 0,
      lastRow: anchorRow,
      lastColumn: _max(columnCount - 1, 0),
    ),
    GridSelectionKind.column => CellRange(
      firstRow: 0,
      firstColumn: anchorColumn,
      lastRow: _max(rowCount - 1, 0),
      lastColumn: anchorColumn,
    ),
    GridSelectionKind.all => CellRange(
      firstRow: 0,
      firstColumn: 0,
      lastRow: _max(rowCount - 1, 0),
      lastColumn: _max(columnCount - 1, 0),
    ),
    _ => CellRange(
      firstRow: _min(anchorRow, activeRow),
      firstColumn: _min(anchorColumn, activeColumn),
      lastRow: _max(anchorRow, activeRow),
      lastColumn: _max(anchorColumn, activeColumn),
    ),
  };

  /// How many cells are selected.
  int cellCount({required int rowCount, required int columnCount}) {
    final b = bounds(rowCount: rowCount, columnCount: columnCount);
    return (b.lastRow - b.firstRow + 1) * (b.lastColumn - b.firstColumn + 1);
  }

  /// The selection with its active cell moved to [row], [column] and the
  /// anchor kept: a [range], or a [cell] when they are the same cell. A
  /// row, column or [all] selection extends from its first cell.
  GridSelection extendedTo(int row, int column) {
    final fromRow = kind == GridSelectionKind.cell || kind == GridSelectionKind.range ? anchorRow : activeRow;
    final fromColumn = kind == GridSelectionKind.cell || kind == GridSelectionKind.range ? anchorColumn : activeColumn;
    if (fromRow == row && fromColumn == column) return GridSelection.cell(row, column);
    return GridSelection.range(anchorRow: fromRow, anchorColumn: fromColumn, activeRow: row, activeColumn: column);
  }

  /// The selection in Excel's notation: `B2`, `B2:D5`, `3:3` for a row,
  /// `B:B` for a column. [rowCount] and [columnCount] size [all].
  String address({required int rowCount, required int columnCount}) {
    switch (kind) {
      case GridSelectionKind.row:
        return '${anchorRow + 1}:${anchorRow + 1}';
      case GridSelectionKind.column:
        final label = columnLabel(anchorColumn);
        return '$label:$label';
      case GridSelectionKind.cell:
        return '${columnLabel(activeColumn)}${activeRow + 1}';
      case GridSelectionKind.range || GridSelectionKind.all:
        final b = bounds(rowCount: rowCount, columnCount: columnCount);
        return '${columnLabel(b.firstColumn)}${b.firstRow + 1}:${columnLabel(b.lastColumn)}${b.lastRow + 1}';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is GridSelection &&
      other.kind == kind &&
      other.anchorRow == anchorRow &&
      other.anchorColumn == anchorColumn &&
      other.activeRow == activeRow &&
      other.activeColumn == activeColumn;

  @override
  int get hashCode => Object.hash(kind, anchorRow, anchorColumn, activeRow, activeColumn);

  @override
  String toString() => 'GridSelection($kind, anchor $anchorRow:$anchorColumn, active $activeRow:$activeColumn)';

  static int _min(int a, int b) => a < b ? a : b;
  static int _max(int a, int b) => a > b ? a : b;
}

/// A zero-based column index as Excel's letters: 0 is A, 25 is Z, 26 is AA.
String columnLabel(int index) {
  var n = index;
  var label = '';
  do {
    label = String.fromCharCode(65 + n % 26) + label;
    n = n ~/ 26 - 1;
  } while (n >= 0);
  return label;
}
