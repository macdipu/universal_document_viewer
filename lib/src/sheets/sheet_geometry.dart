import '../engines/sheets/workbook.dart';

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
  /// the file froze (a reader's "freeze header row").
  SheetGeometry(Worksheet sheet, {required int rowCount, required int columnCount, int minFrozenRows = 0})
      : visibleRows = [
          for (var r = 0; r < rowCount; r++)
            if (!sheet.layout.hiddenRows.contains(r)) r,
        ],
        visibleColumns = [
          for (var c = 0; c < columnCount; c++)
            if (!sheet.layout.hiddenColumns.contains(c)) c,
        ] {
    _rowStarts = _prefixSums([for (final r in visibleRows) rowHeightOf(sheet.layout.rowHeight(r))]);
    _columnStarts = _prefixSums([for (final c in visibleColumns) columnWidthOf(sheet.layout.columnWidth(c))]);
    final frozenRows = sheet.frozenRows > minFrozenRows ? sheet.frozenRows : minFrozenRows;
    frozenRowCount = visibleRows.where((r) => r < frozenRows).length;
    frozenColumnCount = visibleColumns.where((c) => c < sheet.frozenColumns).length;
  }

  /// A default-width column (8.43 characters) and a default-height row
  /// (15 pt) on screen; other sizes scale from these. Roomier than Excel's
  /// 64 x 20 px, for touch.
  static const double defaultColumnWidth = 110;
  static const double defaultRowHeight = 36;

  /// A column width in characters -> logical pixels. Excel draws `w`
  /// characters as `7w + 5` px with the default font (Calibri 11).
  static double columnWidthOf(double characters) {
    if (characters <= 0) return 0;
    return _round(defaultColumnWidth * (characters * 7 + 5) / (8.43 * 7 + 5));
  }

  /// A row height in points -> logical pixels.
  static double rowHeightOf(double points) => points <= 0 ? 0 : _round(defaultRowHeight * points / 15);

  /// To 0.01 px, so a default size comes out exact.
  static double _round(double pixels) => (pixels * 100).roundToDouble() / 100;

  /// Sheet indices of the rows/columns on screen, in order.
  final List<int> visibleRows;
  final List<int> visibleColumns;

  /// How many of the visible rows/columns are frozen (always on screen).
  late final int frozenRowCount;
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

  double rowHeight(int visibleRow) => _rowStarts[visibleRow + 1] - _rowStarts[visibleRow];
  double columnWidth(int visibleColumn) => _columnStarts[visibleColumn + 1] - _columnStarts[visibleColumn];

  /// Height/width of the frozen rows/columns.
  double get frozenHeight => _rowStarts[frozenRowCount];
  double get frozenWidth => _columnStarts[frozenColumnCount];

  // Scrolling covers only the unfrozen part, so scroll offsets count from
  // the first unfrozen row/column.

  /// Scroll offset that brings [visibleRow] to the top (0 for frozen rows).
  double scrollOffsetOfRow(int visibleRow) =>
      visibleRow < frozenRowCount ? 0 : _rowStarts[visibleRow] - frozenHeight;

  double scrollOffsetOfColumn(int visibleColumn) =>
      visibleColumn < frozenColumnCount ? 0 : _columnStarts[visibleColumn] - frozenWidth;

  /// The visible row at the top when scrolled to [offset].
  int visibleRowAtScrollOffset(double offset) => _indexAt(_rowStarts, offset + frozenHeight, frozenRowCount);

  int visibleColumnAtScrollOffset(double offset) =>
      _indexAt(_columnStarts, offset + frozenWidth, frozenColumnCount);

  /// The visible index of sheet row [row], or null when it's hidden or past
  /// the end.
  int? visibleIndexOfRow(int row) => _search(visibleRows, row);
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
