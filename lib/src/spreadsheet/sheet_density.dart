/// How roomy the grid is: [touch] for fingers, [compact] for a mouse.
enum SheetDensity {
  /// Taller rows and headers, bigger padding: comfortable to tap.
  touch,

  /// Excel-like rows and headers: more cells on a desktop screen.
  compact,
}

/// The sizes the grid draws at, at zoom 1, for one [SheetDensity].
class SheetMetrics {
  const SheetMetrics._({
    required this.columnWidth,
    required this.rowHeight,
    required this.headerHeight,
    required this.rowHeaderWidth,
    required this.paddingX,
    required this.paddingY,
  });

  /// Touch: 44 px headers (a comfortable target), 36 px rows.
  static const touch = SheetMetrics._(
    columnWidth: 96,
    rowHeight: 36,
    headerHeight: 44,
    rowHeaderWidth: 40,
    paddingX: 8,
    paddingY: 4,
  );

  /// Mouse: 28 px rows and headers, Excel-like.
  static const compact = SheetMetrics._(
    columnWidth: 100,
    rowHeight: 28,
    headerHeight: 28,
    rowHeaderWidth: 44,
    paddingX: 6,
    paddingY: 2,
  );

  /// The metrics for [density].
  static SheetMetrics of(SheetDensity density) => switch (density) {
    SheetDensity.touch => touch,
    SheetDensity.compact => compact,
  };

  /// Width of a column with Excel's default width (8.43 characters).
  final double columnWidth;

  /// Height of a row with Excel's default height (15 pt).
  final double rowHeight;

  /// Height of the column-letter row.
  final double headerHeight;

  /// Width of the row-number column.
  final double rowHeaderWidth;

  /// Space left and right of a cell's text.
  final double paddingX;

  /// Space above and below a cell's text.
  final double paddingY;

  /// A column width in characters -> logical pixels. Excel draws `w`
  /// characters as `7w + 5` px with the default font (Calibri 11).
  double columnWidthOf(double characters) {
    if (characters <= 0) return 0;
    return _round(columnWidth * (characters * 7 + 5) / (8.43 * 7 + 5));
  }

  /// A row height in points -> logical pixels.
  double rowHeightOf(double points) => points <= 0 ? 0 : _round(rowHeight * points / 15);

  /// To 0.01 px, so a default size comes out exact.
  static double _round(double pixels) => (pixels * 100).roundToDouble() / 100;
}
