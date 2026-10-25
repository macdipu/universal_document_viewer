import 'number_format.dart';

/// A spreadsheet as read from an `.xlsx` or CSV file: its sheets in
/// workbook order, hidden ones included (a reader decides whether to show
/// them).
///
/// Plain data all the way down, so a workbook parsed in a background
/// isolate can be sent back to the UI isolate.
class Workbook {
  /// Creates a workbook from its [sheets].
  const Workbook(this.sheets, {this.date1904 = false});

  /// The sheets in workbook (tab) order, hidden ones included.
  final List<Worksheet> sheets;

  /// Whether date serials count from 1904-01-01 (old Mac Excel files)
  /// rather than 1900-01-00. Cell text already accounts for it.
  final bool date1904;

  /// The sheets' names, in workbook order.
  List<String> get sheetNames => [for (final sheet in sheets) sheet.name];

  /// The first sheet named [name] (case-sensitive), or null if none is.
  Worksheet? operator [](String name) {
    for (final sheet in sheets) {
      if (sheet.name == name) return sheet;
    }
    return null;
  }
}

/// Whether a sheet's tab is shown, from `<sheet state>` in the workbook.
enum SheetVisibility {
  /// Shown (no `state`, or `visible`).
  visible,

  /// Hidden by the author; Excel's "Unhide" lists it.
  hidden,

  /// Hidden so that Excel's "Unhide" doesn't list it.
  veryHidden,
}

/// One sheet of a [Workbook]: its cells, layout, merges, links and notes.
class Worksheet {
  /// Creates a sheet; everything but [name] and [rows] defaults to empty.
  const Worksheet({
    required this.name,
    required this.rows,
    this.visibility = SheetVisibility.visible,
    this.frozenRows = 0,
    this.frozenColumns = 0,
    this.layout = SheetLayout.standard,
    this.merges = const [],
    this.hyperlinks = const {},
    this.comments = const {},
  });

  /// The tab name, from `<sheet name>` (`SheetN` when the file has none).
  final String name;

  /// Whether the author hid the sheet.
  final SheetVisibility visibility;

  /// Column widths, row heights and what the author hid.
  final SheetLayout layout;

  /// Merged areas: each shows its top-left cell across the whole range.
  final List<CellRange> merges;

  /// Link targets by cell: a URL, or a place in the workbook (`Sheet2!A1`).
  final Map<CellAddress, String> hyperlinks;

  /// Notes (Excel's comments) by cell.
  final Map<CellAddress, CellComment> comments;

  /// Rows from the first (index 0 = row 1) to the last one holding a cell.
  /// Rows have different lengths: each stops at its own last cell, and a
  /// missing cell is null.
  final List<List<SheetCell?>> rows;

  /// Rows frozen at the top by the author (a frozen `<pane>`'s `ySplit`);
  /// 0 for none.
  final int frozenRows;

  /// Columns frozen at the left by the author (a frozen `<pane>`'s
  /// `xSplit`); 0 for none.
  final int frozenColumns;

  /// Width of the widest row.
  int get columnCount {
    var widest = 0;
    for (final row in rows) {
      if (row.length > widest) widest = row.length;
    }
    return widest;
  }
}

/// A note on a cell (Excel's "comment"; a threaded comment shows as the
/// thread's text, as older Excel shows it).
class CellComment {
  /// Creates a note with its [text] and optional [author].
  const CellComment(this.text, {this.author});

  /// The note's plain text.
  final String text;

  /// Who wrote it, from the comments part's `<authors>`; null when unknown
  /// or when it names a threaded comment (`tc=...`).
  final String? author;
}

/// A zero-based cell position.
typedef CellAddress = ({int row, int column});

/// A rectangle of cells, zero-based and inclusive (`A1:B2` is rows 0-1,
/// columns 0-1).
class CellRange {
  /// Creates a range from its zero-based, inclusive corners.
  const CellRange({required this.firstRow, required this.firstColumn, required this.lastRow, required this.lastColumn});

  /// Zero-based index of the top row.
  final int firstRow;

  /// Zero-based index of the left column.
  final int firstColumn;

  /// Zero-based index of the bottom row (inclusive).
  final int lastRow;

  /// Zero-based index of the right column (inclusive).
  final int lastColumn;

  /// Whether the zero-based cell at [row], [column] lies in this range.
  bool contains(int row, int column) =>
      row >= firstRow && row <= lastRow && column >= firstColumn && column <= lastColumn;

  @override
  bool operator ==(Object other) =>
      other is CellRange &&
      other.firstRow == firstRow &&
      other.firstColumn == firstColumn &&
      other.lastRow == lastRow &&
      other.lastColumn == lastColumn;

  @override
  int get hashCode => Object.hash(firstRow, firstColumn, lastRow, lastColumn);

  @override
  String toString() => 'CellRange($firstRow,$firstColumn..$lastRow,$lastColumn)';
}

/// How a sheet's rows and columns are sized, in the file's own units:
/// column widths in characters of the default font's digit width (Excel's
/// "8.43"), row heights in points.
class SheetLayout {
  /// Creates a layout; anything not given uses Excel's defaults.
  const SheetLayout({
    this.defaultColumnWidth = 8.43,
    this.defaultRowHeight = 15,
    this.columnWidths = const {},
    this.rowHeights = const {},
    this.hiddenColumns = const {},
    this.hiddenRows = const {},
  });

  /// Excel's defaults: 8.43-character columns, 15 pt rows, nothing hidden.
  static const standard = SheetLayout();

  /// Width in characters of a column without its own, from
  /// `<sheetFormatPr defaultColWidth>` (or `baseColWidth` + 0.43).
  final double defaultColumnWidth;

  /// Height in points of a row without its own, from
  /// `<sheetFormatPr defaultRowHeight>`.
  final double defaultRowHeight;

  /// Widths in characters by zero-based column, from `<col width>`.
  final Map<int, double> columnWidths;

  /// Heights in points by zero-based row, from `<row ht>`.
  final Map<int, double> rowHeights;

  /// Zero-based columns the author hid (`<col hidden>`).
  final Set<int> hiddenColumns;

  /// Zero-based rows the author hid (`<row hidden>`).
  final Set<int> hiddenRows;

  /// Width in characters of the zero-based [column].
  double columnWidth(int column) => columnWidths[column] ?? defaultColumnWidth;

  /// Height in points of the zero-based [row].
  double rowHeight(int row) => rowHeights[row] ?? defaultRowHeight;
}

/// One cell: its value, formatting and any data bar.
class SheetCell {
  /// Creates a cell holding [value] (null for a formatting-only cell).
  const SheetCell(this.value, {this.style = CellStyle.plain, this.date1904 = false, this.dataBar});

  /// Null for a cell that only carries formatting (e.g. a fill colour).
  final CellValue? value;

  /// The cell's format, with what conditional formatting applies to it
  /// already folded in.
  final CellStyle style;

  /// A conditional-formatting data bar drawn behind the value, or null.
  final DataBar? dataBar;

  /// Copied from the [Workbook], so [text] can place date serials.
  final bool date1904;

  /// What a reader shows: numbers and dates formatted with the cell's
  /// number format, and for a formula its saved result. A formula saved
  /// without a result (some generators skip it) shows the formula, marked
  /// with `=`.
  String get text => switch (value) {
    null => '',
    TextValue(:final text) => text,
    final NumberValue number => _formatNumber(number),
    BoolValue(:final value) => value ? 'TRUE' : 'FALSE',
    ErrorValue(:final code) => code,
    FormulaValue(:final formula, :final cached) => switch (cached) {
      null || TextValue(text: '') => formula.isEmpty ? '' : '=$formula',
      final cached => SheetCell(cached, style: style, date1904: date1904).text,
    },
  };

  /// The formula as Excel's formula bar shows it (`=SUM(A1:A3)`, an array
  /// formula in braces); null when the cell has none.
  String? get formulaText => switch (value) {
    FormulaValue(:final formula, :final array) when formula.isNotEmpty => array ? '{=$formula}' : '=$formula',
    _ => null,
  };

  /// The cell's number, for a selection's Sum/Average: a number cell, or a
  /// formula whose saved result is one. Text that looks numeric isn't
  /// counted, as in Excel's status bar.
  num? get number => switch (value) {
    NumberValue(:final value) => value,
    FormulaValue(cached: NumberValue(:final value)) => value,
    _ => null,
  };

  String _formatNumber(NumberValue number) {
    if (number.text case final text? when style.numberFormat.isGeneral) return text;
    return style.numberFormat.format(number.value, date1904: date1904);
  }
}

/// A cell's content.
sealed class CellValue {
  /// Lets subclasses be const.
  const CellValue();
}

/// A text value (a shared, inline or formula string, or CSV text).
class TextValue extends CellValue {
  /// Creates a text value.
  const TextValue(this.text);

  /// The text as stored.
  final String text;
}

/// A number. Dates and times are numbers too (days since the workbook's
/// epoch, as Excel stores them); the cell's number format shows them as
/// dates.
class NumberValue extends CellValue {
  /// Creates a number, with its original spelling [text] for CSV.
  const NumberValue(this.value, {this.text});

  /// The stored number (a date serial for dates and times).
  final num value;

  /// The number as written in the file, for CSV: shown as-is under the
  /// General format so `007` or `1.50` keep their look.
  final String? text;
}

/// A boolean, shown as `TRUE` or `FALSE`.
class BoolValue extends CellValue {
  /// Creates a boolean value.
  const BoolValue(this.value);

  /// The stored boolean.
  final bool value;
}

/// An error result such as `#DIV/0!` or `#N/A`.
class ErrorValue extends CellValue {
  /// Creates an error value.
  const ErrorValue(this.code);

  /// The error as Excel shows it, e.g. `#DIV/0!`.
  final String code;
}

/// A formula and the result Excel saved with it ([cached]; null when the
/// file has none).
class FormulaValue extends CellValue {
  /// Creates a formula with its saved result [cached].
  const FormulaValue(this.formula, {this.cached, this.array = false});

  /// Without the leading `=`. A formula filled across cells is stored once
  /// in the file; each cell gets its own copy, references moved as Excel
  /// moves them.
  final String formula;

  /// The result Excel saved (`<v>`); null when the file has none.
  final CellValue? cached;

  /// An array (CSE) formula, which Excel shows in braces.
  final bool array;
}

/// A bar across part of a cell's width, as conditional formatting draws
/// it: [fraction] (0-1) of the width, in [color] (0xAARRGGBB).
class DataBar {
  /// Creates a bar covering [fraction] of the cell in [color].
  const DataBar(this.fraction, this.color);

  /// Share of the cell's width the bar covers, 0-1.
  final double fraction;

  /// Bar colour as 0xAARRGGBB.
  final int color;
}

/// A cell's horizontal alignment, from `<alignment horizontal>`.
enum HorizontalAlignment {
  /// Excel's default: text left, numbers and dates right, booleans and
  /// errors centred.
  general,

  /// Left-aligned.
  left,

  /// Centred in the cell.
  center,

  /// Right-aligned.
  right,

  /// Excel's `fill`: the text repeated to fill the cell.
  fill,

  /// Justified across the cell's width.
  justify,

  /// Excel's "Center Across Selection": centred across this cell and empty
  /// neighbours to its right.
  centerContinuous,

  /// Excel's `distributed`: spread evenly across the cell.
  distributed,
}

/// A cell's vertical alignment, from `<alignment vertical>`.
enum VerticalAlignment {
  /// At the top of the cell.
  top,

  /// Centred vertically.
  center,

  /// At the bottom of the cell (Excel's default).
  bottom,

  /// Justified from top to bottom.
  justify,

  /// Spread evenly from top to bottom.
  distributed,
}

/// The parts of a cell's formatting a reader shows.
class CellStyle {
  /// Creates a style; every part defaults to Excel's.
  const CellStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.fontSize,
    this.textColor,
    this.fillColor,
    this.horizontalAlignment = HorizontalAlignment.general,
    this.verticalAlignment = VerticalAlignment.bottom,
    this.wrapText = false,
    this.numberFormat = NumberFormat.general,
    this.borders = CellBorders.none,
  });

  /// No formatting: Excel's defaults.
  static const plain = CellStyle();

  /// Bold text (`<b>` in the cell's font).
  final bool bold;

  /// Italic text (`<i>`).
  final bool italic;

  /// Underlined text (`<u>` with any `val` but `none`).
  final bool underline;

  /// Struck-through text (`<strike>`).
  final bool strikethrough;

  /// In points; null for the workbook's default (11 pt in Office).
  final double? fontSize;

  /// Text colour as 0xAARRGGBB; null for automatic (black on white).
  final int? textColor;

  /// Solid background as 0xAARRGGBB, or null for none.
  final int? fillColor;

  /// Horizontal alignment; [HorizontalAlignment.general] by default.
  final HorizontalAlignment horizontalAlignment;

  /// Vertical alignment; [VerticalAlignment.bottom] by default.
  final VerticalAlignment verticalAlignment;

  /// Whether text wraps onto more lines within the cell
  /// (`<alignment wrapText>`).
  final bool wrapText;

  /// How numbers and dates are shown (the cell's `numFmt`).
  final NumberFormat numberFormat;

  /// Lines the author drew on the cell's sides.
  final CellBorders borders;

  /// This style with conditional formatting's overrides on top.
  CellStyle overriddenBy({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strikethrough,
    int? textColor,
    int? fillColor,
  }) => CellStyle(
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    strikethrough: strikethrough ?? this.strikethrough,
    fontSize: fontSize,
    textColor: textColor ?? this.textColor,
    fillColor: fillColor ?? this.fillColor,
    horizontalAlignment: horizontalAlignment,
    verticalAlignment: verticalAlignment,
    wrapText: wrapText,
    numberFormat: numberFormat,
    borders: borders,
  );
}

/// Excel's line styles. A reader draws the dashed and dotted ones solid;
/// [width] is their weight in logical pixels.
enum BorderLineStyle {
  /// Excel's `hair`: the finest line.
  hair(0.5),

  /// Excel's `thin`.
  thin(1),

  /// Excel's `dotted`.
  dotted(1),

  /// Excel's `dashed`.
  dashed(1),

  /// Excel's `dashDot`.
  dashDot(1),

  /// Excel's `dashDotDot`.
  dashDotDot(1),

  /// Excel's `medium`.
  medium(2),

  /// Excel's `mediumDashed`.
  mediumDashed(2),

  /// Excel's `mediumDashDot`.
  mediumDashDot(2),

  /// Excel's `mediumDashDotDot`.
  mediumDashDotDot(2),

  /// Excel's `slantDashDot`.
  slantDashDot(2),

  /// Excel's `thick`.
  thick(3),

  /// Excel's `double`.
  doubleLine(3);

  const BorderLineStyle(this.width);

  /// Line weight in logical pixels.
  final double width;
}

/// One side's line: its style, and colour as 0xAARRGGBB (null for
/// automatic, which is black on white paper).
class BorderLine {
  /// Creates a line in [style] and optional [color].
  const BorderLine(this.style, {this.color});

  /// The line's style, which sets its weight.
  final BorderLineStyle style;

  /// Line colour as 0xAARRGGBB; null for automatic (black).
  final int? color;
}

/// The lines on a cell's four sides; null where there's none.
class CellBorders {
  /// Creates borders from the given sides.
  const CellBorders({this.left, this.right, this.top, this.bottom});

  /// No lines on any side.
  static const none = CellBorders();

  /// The left side's line, or null.
  final BorderLine? left;

  /// The right side's line, or null.
  final BorderLine? right;

  /// The top side's line, or null.
  final BorderLine? top;

  /// The bottom side's line, or null.
  final BorderLine? bottom;

  /// Whether no side has a line.
  bool get isEmpty => left == null && right == null && top == null && bottom == null;
}
