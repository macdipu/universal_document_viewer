import 'package:flutter/painting.dart';

import '../engines/spreadsheet/workbook.dart';

/// Where a sheet's rows and columns sit on screen: sizes from the sheet's
/// layout, hidden rows and columns left out, frozen panes split off.
///
/// Positions are in logical pixels at 1x zoom (multiply by the zoom to
/// draw). Rows and columns are addressed two ways: by their index in the
/// sheet (row 0 is row 1), and by their *visible* index (the n-th row on
/// screen). Lookups by offset are binary searches over prefix sums, so they
/// stay cheap on large sheets.
class SheetGeometry {
  /// [minFrozenRows] freezes at least that many top rows, on top of what
  /// the file froze (a reader's "freeze header row"). [fittedRowHeights]
  /// (1x pixels by sheet row, see [fitWrappedRows]) size rows the file gave
  /// no height.
  SheetGeometry(
    Worksheet sheet, {
    required int rowCount,
    required int columnCount,
    int minFrozenRows = 0,
    Map<int, double> fittedRowHeights = const {},
  }) : visibleRows = [
         for (var r = 0; r < rowCount; r++)
           if (!sheet.layout.hiddenRows.contains(r)) r,
       ],
       visibleColumns = [
         for (var c = 0; c < columnCount; c++)
           if (!sheet.layout.hiddenColumns.contains(c)) c,
       ] {
    _rowStarts = _prefixSums([
      for (final r in visibleRows) fittedRowHeights[r] ?? rowHeightOf(sheet.layout.rowHeight(r)),
    ]);
    _columnStarts = _prefixSums([for (final c in visibleColumns) columnWidthOf(sheet.layout.columnWidth(c))]);
    final frozenRows = sheet.frozenRows > minFrozenRows ? sheet.frozenRows : minFrozenRows;
    frozenRowCount = visibleRows.where((r) => r < frozenRows).length;
    frozenColumnCount = visibleColumns.where((c) => c < sheet.frozenColumns).length;
  }

  /// A default-width column (8.43 characters) and a default-height row
  /// (15 pt) on screen; other sizes scale from these. Roomier than Excel's
  /// 64 x 20 px, for touch.
  static const double defaultColumnWidth = 110;

  /// See [defaultColumnWidth].
  static const double defaultRowHeight = 36;

  /// A column width in characters -> logical pixels. Excel draws `w`
  /// characters as `7w + 5` px with the default font (Calibri 11).
  static double columnWidthOf(double characters) {
    if (characters <= 0) return 0;
    return _round(defaultColumnWidth * (characters * 7 + 5) / (8.43 * 7 + 5));
  }

  /// Text size in logical pixels of [points]-point text at zoom 1 (11 pt,
  /// Excel's default, is 13 px).
  static double fontPixelsOf(double? points) => (points ?? defaultFontPoints) * 13 / defaultFontPoints;

  /// Excel's default font size in points.
  static const double defaultFontPoints = 11;

  /// Space around a cell's text, at zoom 1.
  static const double cellPaddingX = 6;

  /// See [cellPaddingX].
  static const double cellPaddingY = 2;

  /// At most this many wrapped cells are measured per sheet; rows past
  /// them keep their stored or default height.
  static const int maxFittedCells = 2000;

  /// The tallest a fitted row gets: Excel's 409 pt limit.
  static double get maxFittedRowHeight => rowHeightOf(409);

  /// Heights (1x pixels, by sheet row) that show all the text of wrapped
  /// cells in rows the file gave no height, as Excel's AutoFit would; rows
  /// that need no more than their default are left out. Rows with a
  /// stored height keep it (Excel saved them already fitted, or the author
  /// set them), as do merged cells (Excel doesn't fit those either).
  static Map<int, double> fitWrappedRows(Worksheet sheet) {
    final layout = sheet.layout;
    final merged = <(int, int)>{
      for (final merge in sheet.merges)
        if (merge.lastRow - merge.firstRow < 1000 && merge.lastColumn - merge.firstColumn < 1000)
          for (var r = merge.firstRow; r <= merge.lastRow; r++)
            for (var c = merge.firstColumn; c <= merge.lastColumn; c++) (r, c),
    };
    final fitted = <int, double>{};
    final painter = TextPainter(textDirection: TextDirection.ltr);
    var measured = 0;
    try {
      for (var r = 0; r < sheet.rows.length && measured < maxFittedCells; r++) {
        if (layout.rowHeights.containsKey(r) || layout.hiddenRows.contains(r)) continue;
        final standard = rowHeightOf(layout.defaultRowHeight);
        var tallest = standard;
        final row = sheet.rows[r];
        for (var c = 0; c < row.length && measured < maxFittedCells; c++) {
          final cell = row[c];
          if (cell == null || !cell.style.wrapText || layout.hiddenColumns.contains(c) || merged.contains((r, c))) {
            continue;
          }
          final text = cell.text;
          if (text.isEmpty) continue;
          measured++;
          final style = cell.style;
          painter
            ..text = TextSpan(
              text: text,
              style: TextStyle(
                fontSize: fontPixelsOf(style.fontSize),
                fontWeight: style.bold ? FontWeight.bold : FontWeight.normal,
                fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
              ),
            )
            ..layout(maxWidth: (columnWidthOf(layout.columnWidth(c)) - 2 * cellPaddingX).clamp(1, double.infinity));
          final height = painter.height + 2 * cellPaddingY;
          if (height > tallest) tallest = height;
        }
        if (tallest > standard) fitted[r] = _round(tallest.clamp(standard, maxFittedRowHeight));
      }
    } finally {
      painter.dispose();
    }
    return fitted;
  }

  /// A row height in points -> logical pixels.
  static double rowHeightOf(double points) => points <= 0 ? 0 : _round(defaultRowHeight * points / 15);

  /// To 0.01 px, so a default size comes out exact.
  static double _round(double pixels) => (pixels * 100).roundToDouble() / 100;

  /// Sheet indices of the rows on screen, in order.
  final List<int> visibleRows;

  /// Sheet indices of the columns on screen, in order.
  final List<int> visibleColumns;

  /// How many of the visible rows are frozen (always on screen).
  late final int frozenRowCount;

  /// How many of the visible columns are frozen (always on screen).
  late final int frozenColumnCount;

  /// Offset of each visible row/column's start; one extra entry holds the
  /// total.
  late final List<double> _rowStarts;
  late final List<double> _columnStarts;

  static List<double> _prefixSums(List<double> sizes) {
    final sums = List<double>.filled(sizes.length + 1, 0);
    for (var i = 0; i < sizes.length; i++) {
      sums[i + 1] = sums[i] + sizes[i];
    }
    return sums;
  }

  /// Height in logical pixels of the row at visible index [visibleRow].
  double rowHeight(int visibleRow) => _rowStarts[visibleRow + 1] - _rowStarts[visibleRow];

  /// Width in logical pixels of the column at visible index
  /// [visibleColumn].
  double columnWidth(int visibleColumn) => _columnStarts[visibleColumn + 1] - _columnStarts[visibleColumn];

  /// Total height in logical pixels of the frozen rows.
  double get frozenHeight => _rowStarts[frozenRowCount];

  /// Total width in logical pixels of the frozen columns.
  double get frozenWidth => _columnStarts[frozenColumnCount];

  // Scrolling covers only the unfrozen part, so scroll offsets count from
  // the first unfrozen row/column.

  /// Scroll offset that brings [visibleRow] to the top (0 for frozen rows).
  double scrollOffsetOfRow(int visibleRow) => visibleRow < frozenRowCount ? 0 : _rowStarts[visibleRow] - frozenHeight;

  /// Scroll offset that brings [visibleColumn] to the left edge (0 for
  /// frozen columns).
  double scrollOffsetOfColumn(int visibleColumn) =>
      visibleColumn < frozenColumnCount ? 0 : _columnStarts[visibleColumn] - frozenWidth;

  /// The visible row at the top when scrolled to [offset].
  int visibleRowAtScrollOffset(double offset) => _indexAt(_rowStarts, offset + frozenHeight, frozenRowCount);

  /// The visible column at the left edge when scrolled to [offset].
  int visibleColumnAtScrollOffset(double offset) => _indexAt(_columnStarts, offset + frozenWidth, frozenColumnCount);

  /// Where the row at visible index [visibleRow] starts, from the top of
  /// the first row (frozen rows included), in 1x logical pixels.
  double rowStart(int visibleRow) => _rowStarts[visibleRow];

  /// Where the column at visible index [visibleColumn] starts, from the
  /// left of the first column (frozen columns included), in 1x logical
  /// pixels.
  double columnStart(int visibleColumn) => _columnStarts[visibleColumn];

  /// Height in logical pixels of every visible row.
  double get contentHeight => _rowStarts.last;

  /// Width in logical pixels of every visible column.
  double get contentWidth => _columnStarts.last;

  /// The visible row under [y], a position from the top of the first row
  /// (frozen rows included) in 1x logical pixels; clamped to the rows that
  /// exist.
  int visibleRowAtY(double y) => _indexAt(_rowStarts, y, 0);

  /// The visible column under [x], a position from the left of the first
  /// column (frozen columns included) in 1x logical pixels; clamped to the
  /// columns that exist.
  int visibleColumnAtX(double x) => _indexAt(_columnStarts, x, 0);

  /// The visible index of sheet row [row], or null when it's hidden or past
  /// the end.
  int? visibleIndexOfRow(int row) => _search(visibleRows, row);

  /// The visible index of sheet column [column], or null when it's hidden
  /// or past the end.
  int? visibleIndexOfColumn(int column) => _search(visibleColumns, column);

  /// The last index whose start is at or before [offset], not before [min].
  static int _indexAt(List<double> starts, double offset, int min) {
    final count = starts.length - 1;
    if (count <= 0) return 0;
    var low = min;
    var high = count - 1;
    if (low > high) return high;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (starts[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  static int? _search(List<int> sorted, int value) {
    var low = 0;
    var high = sorted.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final v = sorted[mid];
      if (v == value) return mid;
      if (v < value) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return null;
  }
}
